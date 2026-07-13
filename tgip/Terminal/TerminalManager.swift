import SwiftUI
import GhosttyKit
import Observation

/// Per-window terminal state: this window's sessions, selection, active
/// profile, theme, sidebar, search, and diff inspector. App-wide state
/// (ghostty runtime, profiles list, git, attention) lives in AppRuntime;
/// the forwarding accessors below keep call sites uniform — views only
/// ever talk to their window's manager.
@Observable
final class TerminalManager {
    enum ProfileSwitchDirection { case forward, backward }

    @ObservationIgnored let runtime: AppRuntime
    /// This window's theme — each window styles itself from its own profile.
    @ObservationIgnored let theme = SidebarTheme()
    /// The NSWindow hosting this manager's content — set by WindowRoot.
    @ObservationIgnored weak var window: NSWindow?
    /// Whether this is the primary (first) window — the one whose tabs swap
    /// in and out on profile switches. Maintained by AppRuntime's registry.
    var isMain: Bool = false

    /// This window's active profile. Per-window: two windows can be on
    /// different profiles (Arc-style), or even show the same one.
    var activeProfileIndex: Int = 0
    /// Direction of the last profile switch — drives slide animation.
    var profileSwitchDirection: ProfileSwitchDirection = .forward

    var sessions: [TerminalSession] = []
    var selectedSessionID: UUID? {
        didSet {
            if let selectedSessionID { clearAttention(for: selectedSessionID) }
            if oldValue != selectedSessionID {
                handleSelectedSessionChange(from: oldValue, to: selectedSessionID)
            }
        }
    }

    var sidebarPinned: Bool = true

    /// Which group index is keyboard-focused (nil = none). Set by Cmd+1…9.
    var focusedGroupIndex: Int?
    /// Which tab within the focused group is highlighted. Arrow keys move this.
    var focusedTabOffset: Int = 0
    var searchState: TerminalSearchState?
    var searchFocusToken: Int = 0
    /// The uncommitted-diff inspector currently shown in the main pane (nil = terminal).
    var presentedGitDiff: GitDiffPresentation?

    @ObservationIgnored private var didTeardown = false
    @ObservationIgnored private var pendingResumableCreations = 0

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    init(runtime: AppRuntime = .shared) {
        self.runtime = runtime

        // Start on the primary window's last-used profile; tear-outs override
        // this via setActiveProfile before the window shows.
        let savedIndex = UserDefaults.standard.integer(forKey: "activeProfileIndex")
        self.activeProfileIndex = runtime.profiles.indices.contains(savedIndex) ? savedIndex : 0
        theme.apply(from: activeProfile)
        runtime.ghostty.setColorScheme(dark: theme.brightness < 0.5)

        // Theme edits in this window persist to this window's active profile.
        theme.onThemeChanged = { [weak self] in
            guard let self else { return }
            self.runtime.captureTheme(self.theme, forProfileAt: self.activeProfileIndex)
        }
        theme.onBrightnessChanged = { [weak self] value in
            self?.runtime.ghostty.setColorScheme(dark: value < 0.5)
        }
    }

    // MARK: - Forwarding: app-level state

    var ghostty: GhosttyRuntime { runtime.ghostty }

    var gitIntegrationEnabled: Bool {
        get { runtime.gitIntegrationEnabled }
        set { runtime.gitIntegrationEnabled = newValue }
    }

    var profiles: [Profile] { runtime.profiles }

    var activeProfile: Profile {
        runtime.profiles.indices.contains(activeProfileIndex)
            ? runtime.profiles[activeProfileIndex]
            : Profile()
    }

    /// This window's pinned paths — the active profile's, shared live with any
    /// other window on the same profile.
    var pinnedPaths: [String] {
        get { activeProfile.pinnedPaths }
        set { runtime.setPinnedPaths(newValue, forProfileAt: activeProfileIndex) }
    }

    var groupMeta: [String: GroupMeta] {
        get { activeProfile.groupMeta }
        set { runtime.setGroupMeta(newValue, forProfileAt: activeProfileIndex) }
    }

    func togglePin(path: String) {
        if let i = pinnedPaths.firstIndex(of: path) {
            pinnedPaths.remove(at: i)
        } else {
            pinnedPaths.append(path)
            // Auto-detect a favicon/logo on pin
            if meta(for: path).imagePath == nil,
               let found = GroupMeta.autoDetectImage(in: path) {
                setImage(found, for: path)
            }
        }
        runtime.refreshGitMonitoring()
    }

    func isPinned(_ path: String) -> Bool { pinnedPaths.contains(path) }
    func meta(for path: String) -> GroupMeta { groupMeta[path] ?? GroupMeta() }

    func setIcon(_ icon: String, for path: String) {
        var m = meta(for: path)
        m.icon = icon
        groupMeta[path] = m
    }

    func setDisplayName(_ name: String, for path: String) {
        var m = meta(for: path)
        m.displayName = name.isEmpty ? nil : name
        groupMeta[path] = m
    }

    func setImage(_ imagePath: String?, for path: String) {
        var m = meta(for: path)
        m.imagePath = imagePath
        groupMeta[path] = m
    }

    func groupAnchor(for cwd: String, pinned: [String]) -> String {
        runtime.groupAnchor(for: cwd, pinned: pinned)
    }

    func gitRepositoryInfo(for path: String) -> GitRepositoryInfo? {
        runtime.gitRepositoryInfo(for: path)
    }

    func gitStatus(forGroupPath path: String) -> GitRepoStatus? {
        runtime.gitStatus(forGroupPath: path)
    }

    func gitStatus(forRepoRoot repoRoot: String) -> GitRepoStatus? {
        runtime.gitStatus(forRepoRoot: repoRoot)
    }

    func refreshGitStatus(forRepoRoot repoRoot: String) {
        runtime.refreshGitStatus(forRepoRoot: repoRoot)
    }

    /// Git status for a group path in any profile — data is tracked globally.
    func gitStatusForProfile(at index: Int, groupPath path: String) -> GitRepoStatus? {
        runtime.gitStatus(forGroupPath: path)
    }

    func sessionsForProfile(at index: Int) -> [TerminalSession] {
        if index == activeProfileIndex { return sessions }
        return runtime.previewSessions(forProfileAt: index)
    }

    // MARK: - Profile switching (per-window)

    /// Switch THIS window to another profile. Theme and pinned groups follow
    /// the profile. Only the primary window swaps its tab set in and out of
    /// the profile's stored sessions; other windows keep their tabs.
    func switchToProfile(_ index: Int, direction: ProfileSwitchDirection? = nil) {
        guard index != activeProfileIndex, runtime.profiles.indices.contains(index) else { return }

        profileSwitchDirection = direction ?? (index > activeProfileIndex ? .forward : .backward)

        if isMain {
            // Pause rendering and stash the current profile's tab set
            for session in sessions {
                session.surfaceView?.isActiveTab = false
            }
            runtime.storeSessions(sessions, selected: selectedSessionID, forProfileID: activeProfile.id)
        }

        // Persist current theme edits into the outgoing profile
        runtime.captureTheme(theme, forProfileAt: activeProfileIndex)

        closeSearch()
        focusedGroupIndex = nil

        activeProfileIndex = index
        if isMain {
            UserDefaults.standard.set(index, forKey: "activeProfileIndex")
        }

        let newProfile = runtime.profiles[index]
        theme.apply(from: newProfile)
        runtime.ghostty.setColorScheme(dark: theme.brightness < 0.5)

        if isMain {
            let stored = runtime.takeStoredSessions(forProfileID: newProfile.id)
            sessions = stored.sessions
            selectedSessionID = stored.selected

            let profileID = newProfile.id
            restoreResumableTabs { [weak self] _ in
                guard let self, self.activeProfile.id == profileID else { return }
                self.finishProfileActivation()
            }
        }

        runtime.refreshGitMonitoring()
        runtime.saveProfilesNow()
    }

    /// Adopt a profile without touching sessions — used when a torn-out
    /// window inherits its source window's profile.
    func setActiveProfile(_ index: Int) {
        guard runtime.profiles.indices.contains(index) else { return }
        activeProfileIndex = index
        theme.apply(from: runtime.profiles[index])
    }

    func switchToNextProfile() {
        guard !profiles.isEmpty else { return }
        switchToProfile((activeProfileIndex + 1) % profiles.count, direction: .forward)
    }

    func switchToPreviousProfile() {
        guard !profiles.isEmpty else { return }
        switchToProfile((activeProfileIndex - 1 + profiles.count) % profiles.count, direction: .backward)
    }

    func addProfile() {
        let index = runtime.appendProfile()
        switchToProfile(index, direction: .forward)
    }

    func deleteProfile(at index: Int) { runtime.deleteProfile(at: index) }
    func renameProfile(_ name: String, at index: Int) { runtime.renameProfile(name, at: index) }
    func setSSHHost(_ host: String?, at index: Int) { runtime.setSSHHost(host, at: index) }
    func setProfileIcon(_ icon: String, at index: Int) { runtime.setProfileIcon(icon, at: index) }

    func shouldConfirmAppQuit() -> Bool { runtime.shouldConfirmAppQuit() }

    // MARK: - Sessions

    func createSession(in directory: String? = nil) {
        let pwd = directory ?? selectedSession?.workingDirectory
        let profile = activeProfile

        if let host = profile.sshHost {
            // SSH session
            let password = KeychainHelper.load(for: host)
            let input: String

            if let password, !password.isEmpty {
                let safe = password.replacingOccurrences(of: "'", with: "'\\''")
                let id = UUID().uuidString.prefix(8)
                let tmp = "/tmp/.wave_\(id)"
                let script = "#!/bin/sh\ntrap 'rm -f \"$0\"' EXIT\nWAVE_SSH_PASS='\(safe)'\nexport WAVE_SSH_PASS\nexec /usr/bin/expect -c 'spawn ssh \(host); expect assword:; send \"$env(WAVE_SSH_PASS)\\r\"; interact'"
                try? script.write(toFile: tmp, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp)
                input = " clear && \(tmp)\n"
            } else {
                input = " clear && ssh \(host)\n"
            }

            let session = TerminalSession(title: host)
            session.workingDirectory = "ssh://\(host)"
            let view = TerminalSurfaceView(runtime: ghostty, session: session, initialInput: input)
            appendCreatedSession(session, view: view)
        } else if runtime.resumableTabsEnabled, TmuxIntegration.isAvailable {
            createResumableSession(in: pwd)
            return
        } else {
            if runtime.resumableTabsEnabled { runtime.noteTmuxMissingOnce() }
            createPlainLocalSession(in: pwd)
        }
    }

    private func createPlainLocalSession(in directory: String?) {
        let session = TerminalSession(title: "Terminal \(sessions.count + 1)")
        session.workingDirectory = directory
        let view = TerminalSurfaceView(runtime: ghostty, session: session, workingDirectory: directory)
        appendCreatedSession(session, view: view)
    }

    private func createResumableSession(in directory: String?) {
        let tabID = UUID()
        pendingResumableCreations += 1
        let title = "Terminal \(sessions.count + pendingResumableCreations)"
        let profileID = activeProfile.id
        let knownNames = runtime.knownTmuxSessionNames()
        let runtime = runtime

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TmuxIntegration.createSession(
                tabID: tabID,
                workingDirectory: directory,
                avoiding: knownNames
            ) { name in
                ResumableCreationRecovery.add(
                    ResumableTabRecord(
                        id: tabID,
                        tmuxName: name,
                        title: title,
                        workingDirectory: directory
                    ),
                    profileID: profileID
                )
            }
            let recoveryRecord: ResumableTabRecord?
            switch result {
            case let .ready(name, _), let .cleanupRequired(name):
                recoveryRecord = ResumableTabRecord(
                    id: tabID,
                    tmuxName: name,
                    title: title,
                    workingDirectory: directory
                )
            case .failed:
                recoveryRecord = nil
            }

            DispatchQueue.main.async {
                self?.pendingResumableCreations -= 1
                guard !runtime.isTerminating else { return }
                guard let self, !self.didTeardown,
                      runtime.profiles.contains(where: { $0.id == profileID })
                else {
                    if let recoveryRecord {
                        runtime.requestTmuxSessionDeletion(
                            name: recoveryRecord.tmuxName,
                            tabID: recoveryRecord.id,
                            title: recoveryRecord.title,
                            workingDirectory: recoveryRecord.workingDirectory,
                            profileID: profileID
                        )
                    }
                    return
                }

                let tmuxName: String?
                let command: String?
                switch result {
                case let .ready(name, preparedCommand):
                    tmuxName = name
                    command = preparedCommand
                case let .cleanupRequired(name):
                    runtime.requestTmuxSessionDeletion(
                        name: name,
                        tabID: tabID,
                        title: title,
                        workingDirectory: directory,
                        profileID: profileID
                    )
                    tmuxName = nil
                    command = nil
                case .failed:
                    tmuxName = nil
                    command = nil
                }

                let session = TerminalSession(
                    title: title,
                    id: tabID,
                    tmuxSessionName: tmuxName
                )
                session.workingDirectory = directory
                let view = TerminalSurfaceView(
                    runtime: self.ghostty,
                    session: session,
                    workingDirectory: directory,
                    spawnCommand: command
                )
                session.surfaceView = view

                if !self.isMain || self.activeProfile.id == profileID {
                    self.appendCreatedSession(session, view: view)
                } else {
                    runtime.appendStoredSession(session, forProfileID: profileID)
                }
                if tmuxName != nil {
                    runtime.saveResumableManifestNow()
                    if let recoveryRecord {
                        ResumableCreationRecovery.remove([recoveryRecord], profileID: profileID)
                    }
                }
            }
        }
    }

    private func appendCreatedSession(_ session: TerminalSession, view: TerminalSurfaceView) {
        session.surfaceView = view
        sessions.append(session)
        selectedSessionID = session.id

        focusedGroupIndex = nil
        runtime.refreshGitMonitoring()
    }

    /// Existing resumable sessions restore regardless of the creation toggle;
    /// that preference controls new tabs only.
    func restoreResumableTabs(completion: @escaping (Bool) -> Void = { _ in }) {
        let profileID = activeProfile.id
        guard TmuxIntegration.isAvailable else { completion(false); return }
        guard let records = runtime.claimResumableRecords(forProfileID: profileID) else {
            runtime.whenResumableRecordsClaimAvailable(forProfileID: profileID) { [weak self] in
                guard let self, !self.didTeardown, self.activeProfile.id == profileID else {
                    completion(false)
                    return
                }
                self.restoreResumableTabs(completion: completion)
            }
            return
        }
        guard !records.isEmpty else {
            runtime.releaseResumableRecordsClaim(forProfileID: profileID)
            completion(false)
            return
        }
        let runtime = runtime

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var attachable: [(ResumableTabRecord, String)] = []
            var discardable: [ResumableTabRecord] = []

            for record in records {
                switch TmuxIntegration.sessionMatch(record.tmuxName, tabID: record.id) {
                case .owned:
                    if let command = TmuxIntegration.prepareRestoreCommand(
                        sessionName: record.tmuxName, tabID: record.id
                    ) {
                        attachable.append((record, command))
                    }
                case .missing, .foreign:
                    discardable.append(record)
                case .unavailable:
                    break
                }
            }

            DispatchQueue.main.async {
                guard let self else {
                    runtime.releaseResumableRecordsClaim(forProfileID: profileID)
                    completion(false)
                    return
                }
                guard !self.didTeardown, self.activeProfile.id == profileID else {
                    runtime.releaseResumableRecordsClaim(forProfileID: profileID)
                    completion(false)
                    return
                }

                var resolved = discardable
                for (record, command) in attachable {
                    if self.sessions.contains(where: {
                        $0.id == record.id || $0.tmuxSessionName == record.tmuxName
                    }) {
                        resolved.append(record)
                        continue
                    }

                    let session = TerminalSession(
                        title: record.title,
                        id: record.id,
                        tmuxSessionName: record.tmuxName
                    )
                    session.workingDirectory = record.workingDirectory
                    let view = TerminalSurfaceView(
                        runtime: self.ghostty,
                        session: session,
                        workingDirectory: record.workingDirectory,
                        spawnCommand: command
                    )
                    session.surfaceView = view
                    self.sessions.append(session)
                    resolved.append(record)
                }

                self.runtime.discardResumableRecords(resolved, forProfileID: profileID)
                if self.selectedSessionID == nil { self.selectedSessionID = self.sessions.last?.id }
                self.runtime.refreshGitMonitoring()
                if !resolved.isEmpty { self.runtime.scheduleResumableManifestSave() }
                runtime.releaseResumableRecordsClaim(forProfileID: profileID)
                completion(!attachable.isEmpty)
            }
        }
    }

    private func finishProfileActivation() {
        if sessions.isEmpty {
            createSession()
        } else if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }
        if let current = selectedSessionID {
            sessions.first { $0.id == current }?.surfaceView?.isActiveTab = true
        }
    }

    func closeSession(_ session: TerminalSession) {
        guard shouldCloseSession(session) else { return }
        closeSessionNow(session)
    }

    private func closeSessionNow(_ session: TerminalSession) {
        session.surfaceView?.destroySurface()
        // Close means close: an explicitly closed resumable tab kills its tmux
        // session (only quit/update keeps them for restore).
        if let name = session.tmuxSessionName {
            runtime.requestTmuxSessionDeletion(
                name: name,
                tabID: session.id,
                title: session.title,
                workingDirectory: session.workingDirectory,
                profileID: activeProfile.id
            )
            runtime.scheduleResumableManifestSave()
        }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
        runtime.refreshGitMonitoring()
    }

    private func shouldCloseSession(_ session: TerminalSession) -> Bool {
        guard let surface = session.surfaceView?.surface,
              ghostty_surface_needs_confirm_quit(surface) else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Close Tab?"
        alert.informativeText = "A process is still running in \"\(session.title)\". Closing this tab will terminate it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func moveSession(_ draggedID: UUID, before targetID: UUID, in directory: String) {
        guard draggedID != targetID,
              let draggedIndex = sessions.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = sessions.firstIndex(where: { $0.id == targetID }),
              sessions[draggedIndex].workingDirectory == directory,
              sessions[targetIndex].workingDirectory == directory else { return }

        let dragged = sessions.remove(at: draggedIndex)
        let adjustedTarget = draggedIndex < targetIndex ? targetIndex - 1 : targetIndex
        sessions.insert(dragged, at: adjustedTarget)
    }

    func moveSessionToEndOfGroup(_ draggedID: UUID, in directory: String) {
        guard let draggedIndex = sessions.firstIndex(where: { $0.id == draggedID }),
              sessions[draggedIndex].workingDirectory == directory else { return }

        let dragged = sessions.remove(at: draggedIndex)
        let insertionIndex = sessions.lastIndex(where: { $0.workingDirectory == directory }).map { $0 + 1 } ?? sessions.count
        sessions.insert(dragged, at: insertionIndex)
    }

    // MARK: - Tear-out / transfer

    /// Remove a session from this window without destroying its surface —
    /// the shell keeps running and the session can be adopted elsewhere.
    func detach(_ session: TerminalSession) {
        if searchState?.sessionID == session.id {
            session.surfaceView?.endSearch()
            searchState = nil
        }
        session.surfaceView?.isActiveTab = false
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
        runtime.refreshGitMonitoring()
    }

    /// Take ownership of a session detached from another window.
    func adopt(_ session: TerminalSession) {
        sessions.append(session)
        selectedSessionID = session.id
        focusedGroupIndex = nil
        runtime.refreshGitMonitoring()
        // A resumable tab may have changed profile ownership — re-snapshot.
        if session.tmuxSessionName != nil { runtime.scheduleResumableManifestSave() }
    }

    /// Profile deletion is an explicit close for every window, including
    /// secondary windows that normally keep their tabs while switching.
    func destroySessionsForProfileDeletion() {
        for session in sessions {
            session.surfaceView?.destroySurface()
            if let name = session.tmuxSessionName {
                runtime.requestTmuxSessionDeletion(
                    name: name,
                    tabID: session.id,
                    title: session.title,
                    workingDirectory: session.workingDirectory,
                    profileID: activeProfile.id
                )
            }
        }
        sessions.removeAll()
        selectedSessionID = nil
        runtime.scheduleResumableManifestSave()
        runtime.refreshGitMonitoring()
    }

    /// Destroy this window's sessions and leave the registry. Called when the
    /// window closes; idempotent.
    func teardownWindow() {
        guard !didTeardown else { return }
        didTeardown = true
        for session in sessions {
            session.surfaceView?.destroySurface()
            // Closing a window closes its tabs — kill their tmux sessions.
            // App termination (quit/update) is the exception: sessions stay
            // alive and the manifest restores them on relaunch.
            if let name = session.tmuxSessionName, !runtime.isTerminating {
                runtime.requestTmuxSessionDeletion(
                    name: name,
                    tabID: session.id,
                    title: session.title,
                    workingDirectory: session.workingDirectory,
                    profileID: activeProfile.id
                )
            }
        }
        if !runtime.isTerminating { runtime.scheduleResumableManifestSave() }
        sessions.removeAll()
        selectedSessionID = nil
        runtime.unregister(self)
    }

    /// Whether closing this window warrants a confirmation (running processes),
    /// and ask the user if so.
    func confirmWindowClose() -> Bool {
        let needsConfirm = sessions.contains {
            guard let surface = $0.surfaceView?.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
        guard needsConfirm else { return true }

        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText = "One or more tabs in this window still have running processes. Closing the window will terminate them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Group Navigation

    func focusGroup(at index: Int) {
        focusedGroupIndex = index
        focusedTabOffset = 0
    }

    func moveFocusDown() {
        focusedTabOffset += 1
    }

    func moveFocusUp() {
        focusedTabOffset = max(0, focusedTabOffset - 1)
    }

    /// Select the currently focused tab, or the first tab in the focused group.
    func confirmFocus(groups: [(fullPath: String, sessions: [TerminalSession])]) {
        guard let gi = focusedGroupIndex, gi < groups.count else { return }
        let group = groups[gi]
        if group.sessions.isEmpty {
            // Pinned group with no tabs — create one there
            createSession(in: group.fullPath)
        } else {
            let clamped = min(focusedTabOffset, group.sessions.count - 1)
            selectedSessionID = group.sessions[clamped].id
        }
        focusedGroupIndex = nil
    }

    func cancelFocus() {
        focusedGroupIndex = nil
    }

    // MARK: - Search

    func showSearch() {
        guard let selectedSession = selectedSession else { return }

        if let existing = searchState,
           existing.sessionID != selectedSession.id,
           let existingSession = session(for: existing.sessionID) {
            existingSession.surfaceView?.endSearch()
        }

        activateSearch(for: selectedSession.id, query: searchState?.sessionID == selectedSession.id ? searchState?.query ?? "" : "")
        selectedSession.surfaceView?.startSearch()
        if let query = searchState?.query, !query.isEmpty {
            selectedSession.surfaceView?.updateSearch(query)
        }
        searchFocusToken &+= 1
    }

    func updateSearchQuery(_ query: String) {
        guard let session = selectedSession else { return }

        var state = searchState ?? TerminalSearchState(sessionID: session.id, query: query)
        if state.sessionID != session.id {
            state = TerminalSearchState(sessionID: session.id, query: query)
        }
        state.query = query
        state.totalMatches = nil
        state.selectedMatch = nil
        searchState = state

        session.surfaceView?.updateSearch(query)
    }

    func navigateSearch(_ direction: TerminalSearchDirection) {
        guard let state = searchState,
              let session = session(for: state.sessionID) else {
            return
        }

        session.surfaceView?.navigateSearch(direction)
    }

    func closeSearch() {
        guard let state = searchState else { return }
        session(for: state.sessionID)?.surfaceView?.endSearch()
        clearSearchState(for: state.sessionID)
    }

    // MARK: - Git Diff Inspector

    /// Toggle the uncommitted-diff inspector for the selected session's repo.
    func toggleGitDiff() {
        if presentedGitDiff != nil {
            presentedGitDiff = nil
            refocusTerminal()
            return
        }
        guard gitIntegrationEnabled,
              let dir = selectedSession?.workingDirectory,
              let repo = gitRepositoryInfo(for: dir) else {
            return
        }
        closeSearch()
        presentedGitDiff = GitDiffPresentation(sourcePath: dir, repoRoot: repo.repoRoot)
    }

    /// Open the uncommitted-diff inspector for a specific group path.
    func openGitDiff(forGroupPath groupPath: String) {
        guard gitIntegrationEnabled,
              let repo = gitRepositoryInfo(for: groupPath) else { return }
        closeSearch()
        presentedGitDiff = GitDiffPresentation(sourcePath: groupPath, repoRoot: repo.repoRoot)
    }

    func closeGitDiff() {
        guard presentedGitDiff != nil else { return }
        presentedGitDiff = nil
        refocusTerminal()
    }

    /// Make the selected session's terminal surface first responder.
    func refocusTerminal() {
        guard let view = selectedSession?.surfaceView else { return }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }

    // MARK: - Attention

    func clearAttention(for sessionID: UUID) {
        if let session = sessions.first(where: { $0.id == sessionID }) {
            session.needsAttention = false
        }
        runtime.updateDockBadge()
    }

    // MARK: - Lookup

    private func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Selection / search internals (also driven by AppRuntime's action routing)

    private func handleSelectedSessionChange(from previous: UUID?, to current: UUID?) {
        // Pause rendering on the old tab, resume on the new one
        if let previous, let oldView = session(for: previous)?.surfaceView {
            oldView.isActiveTab = false
        }
        if let current, let newView = session(for: current)?.surfaceView {
            newView.isActiveTab = true
        }

        guard let previous,
              previous != current,
              searchState?.sessionID == previous else {
            return
        }

        session(for: previous)?.surfaceView?.endSearch()
        clearSearchState(for: previous)
    }

    func activateSearch(for sessionID: UUID, query: String) {
        if let existing = searchState,
           existing.sessionID != sessionID,
           let existingSession = session(for: existing.sessionID) {
            existingSession.surfaceView?.endSearch()
        }

        if let existing = searchState, existing.sessionID == sessionID, existing.query == query {
            return
        }

        searchState = TerminalSearchState(sessionID: sessionID, query: query)
    }

    func clearSearchState(for sessionID: UUID) {
        guard searchState?.sessionID == sessionID else { return }
        searchState = nil
    }

    func updateSearchTotal(_ total: Int?, for sessionID: UUID) {
        guard var state = searchState, state.sessionID == sessionID else { return }
        state.totalMatches = total
        searchState = state
    }

    func updateSearchSelection(_ selected: Int?, for sessionID: UUID) {
        guard var state = searchState, state.sessionID == sessionID else { return }
        state.selectedMatch = selected
        searchState = state
    }
}
