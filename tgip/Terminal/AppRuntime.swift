import SwiftUI
import GhosttyKit
import Observation
import UserNotifications

/// App-level state shared by every window: the ghostty runtime, the profiles
/// list and their stored tab sets, git monitoring, attention routing, and the
/// registry of open windows. Per-window state (sessions, selection, active
/// profile, theme, search, …) lives in TerminalManager.
@Observable
final class AppRuntime {
    static let shared = AppRuntime()

    private enum DefaultsKey {
        static let gitIntegrationEnabled = "git.enabled"
        static let resumableTabsEnabled = "experimental.resumableTabs"
        static let resumableWorkspace = "resumableWorkspace"
        static let pendingTmuxDeletions = "resumableWorkspace.pendingDeletions"
    }

    @ObservationIgnored let ghostty: GhosttyRuntime
    @ObservationIgnored private let gitRepositoryService: GitRepositoryService
    @ObservationIgnored private let agentMonitor = AgentMonitor()

    /// Open windows' managers in creation order. The first is the "primary"
    /// window — the one whose tabs swap in and out on profile switches.
    private(set) var windows: [TerminalManager] = []

    var mainWindow: TerminalManager? { windows.first }

    /// Sessions detached for tear-out, keyed by the token passed through
    /// `openWindow(value:)` to the new window.
    @ObservationIgnored private var pendingTearOutSessions: [UUID: TerminalSession] = [:]
    /// Screen point where a torn-out window should appear.
    @ObservationIgnored private var pendingTearOutPoints: [UUID: NSPoint] = [:]
    /// Profile the torn-out window should adopt (the source window's).
    @ObservationIgnored private var pendingTearOutProfiles: [UUID: Int] = [:]
    /// Bridges `openWindow` out of the view layer so drags can spawn windows.
    @ObservationIgnored var openWindowAction: ((UUID) -> Void)?

    /// Experimental: new local tabs run inside local tmux sessions (`wave-N`)
    /// that survive quitting/updating Wave and can be resumed here or from
    /// Wave for iPad over SSH. Off = exactly the classic spawn path.
    var resumableTabsEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.resumableTabsEnabled) {
        didSet {
            guard oldValue != resumableTabsEnabled else { return }
            UserDefaults.standard.set(resumableTabsEnabled, forKey: DefaultsKey.resumableTabsEnabled)
        }
    }

    var gitIntegrationEnabled: Bool = UserDefaults.standard.object(forKey: DefaultsKey.gitIntegrationEnabled) as? Bool ?? true {
        didSet {
            guard oldValue != gitIntegrationEnabled else { return }
            UserDefaults.standard.set(gitIntegrationEnabled, forKey: DefaultsKey.gitIntegrationEnabled)
            if gitIntegrationEnabled {
                refreshGitMonitoring()
            } else {
                gitLookupsByPath = [:]
                gitStatusesByRoot = [:]
                gitRepositoryService.reset()
            }
        }
    }

    // MARK: - Profiles (global list; each window picks its own active one)

    var profiles: [Profile] = []
    /// Tab sets of profiles not currently live in the primary window.
    private var storedSessions: [UUID: [TerminalSession]] = [:]
    /// Per-profile selected session.
    private var storedSelectedSession: [UUID: UUID?] = [:]
    /// Restore records not yet attached to a live tab. They remain here across
    /// transient tmux/filesystem failures and are merged into every disk save.
    @ObservationIgnored private var pendingResumableManifest = ResumableWorkspace.merging(
        pending: ResumableWorkspace.decode(
            UserDefaults.standard.data(forKey: DefaultsKey.resumableWorkspace)
        ),
        live: ResumableCreationRecovery.load()
    )
    @ObservationIgnored private var claimedResumableProfiles = Set<UUID>()
    @ObservationIgnored private var resumableClaimWaiters: [UUID: [() -> Void]] = [:]
    @ObservationIgnored private var pendingTmuxDeletions = ResumableWorkspace.decode(
        UserDefaults.standard.data(forKey: DefaultsKey.pendingTmuxDeletions)
    )
    @ObservationIgnored private var tmuxDeletionsInFlight = Set<String>()

    private(set) var gitLookupsByPath: [String: GitPathLookup] = [:]
    private(set) var gitStatusesByRoot: [String: GitRepoStatus] = [:]

    private init() {
        self.gitRepositoryService = GitRepositoryService()
        self.ghostty = GhosttyRuntime()

        // Load profiles or migrate from legacy settings
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let loaded = try? JSONDecoder().decode([Profile].self, from: data),
           !loaded.isEmpty {
            self.profiles = loaded
        } else {
            // Migration: create default profile from existing settings
            var defaultProfile = Profile()
            defaultProfile.pinnedPaths = UserDefaults.standard.stringArray(forKey: "pinnedPaths") ?? []
            defaultProfile.groupMeta = Self.loadGroupMeta()
            defaultProfile.captureTheme(from: SidebarTheme())
            self.profiles = [defaultProfile]
        }

        gitRepositoryService.onSnapshot = { [weak self] lookups, statuses in
            guard let self else { return }
            guard self.gitIntegrationEnabled else {
                self.gitLookupsByPath = [:]
                self.gitStatusesByRoot = [:]
                return
            }
            self.gitLookupsByPath = lookups
            self.gitStatusesByRoot = statuses
        }
        ghostty.onAction = { [weak self] target, action in
            self?.handleAction(target: target, action: action) ?? false
        }

        // Agent monitor — track coding-agent lifecycle and flag tabs for attention
        agentMonitor.onEvent = { [weak self] event in
            self?.handleAgentEvent(event)
        }
        agentMonitor.start()

        saveProfilesNow()
        startTmuxIdentityPolling()
        retryPendingTmuxDeletions()
    }

    // MARK: - Window registry

    func register(_ manager: TerminalManager) {
        guard !windows.contains(where: { $0 === manager }) else { return }
        windows.append(manager)
        updateMainFlags()
    }

    func unregister(_ manager: TerminalManager) {
        windows.removeAll { $0 === manager }
        updateMainFlags()
        refreshGitMonitoring()
        updateDockBadge()
    }

    private func updateMainFlags() {
        for (index, window) in windows.enumerated() {
            window.isMain = index == 0
        }
    }

    /// The manager owning the current key window, else the primary window.
    var keyWindowManager: TerminalManager? {
        if let key = NSApp.keyWindow,
           let manager = windows.first(where: { $0.window === key }) {
            return manager
        }
        return mainWindow
    }

    func shouldConfirmAppQuit() -> Bool {
        ghostty.appNeedsConfirmQuit()
    }

    // MARK: - Session lookup across windows

    func findSession(id: UUID) -> (manager: TerminalManager, session: TerminalSession)? {
        for manager in windows {
            if let session = manager.sessions.first(where: { $0.id == id }) {
                return (manager, session)
            }
        }
        return nil
    }

    private func findSession(surface ptr: ghostty_surface_t) -> (manager: TerminalManager, session: TerminalSession)? {
        for manager in windows {
            if let session = manager.sessions.first(where: { $0.surfaceView?.surface == ptr }) {
                return (manager, session)
            }
        }
        return nil
    }

    // MARK: - Tear-out / cross-window transfer

    /// Detach a session from its window and reopen it in a fresh window,
    /// optionally positioned at a screen point (drag tear-out).
    func tearOut(sessionID: UUID, at screenPoint: NSPoint?) {
        guard let (source, session) = findSession(id: sessionID),
              let openWindowAction else { return }

        source.detach(session)
        let token = UUID()
        pendingTearOutSessions[token] = session
        pendingTearOutProfiles[token] = source.activeProfileIndex
        if let screenPoint { pendingTearOutPoints[token] = screenPoint }
        openWindowAction(token)
        closeWindowIfEmpty(source)
    }

    /// Move a session into an existing window (drag between sidebars).
    func transferSession(_ sessionID: UUID, to target: TerminalManager) {
        guard let (source, session) = findSession(id: sessionID), source !== target else { return }
        source.detach(session)
        target.adopt(session)
        closeWindowIfEmpty(source)
    }

    func claimTearOutSession(_ token: UUID) -> TerminalSession? {
        pendingTearOutSessions.removeValue(forKey: token)
    }

    func claimTearOutPoint(_ token: UUID) -> NSPoint? {
        pendingTearOutPoints.removeValue(forKey: token)
    }

    func claimTearOutProfile(_ token: UUID) -> Int? {
        pendingTearOutProfiles.removeValue(forKey: token)
    }

    private func closeWindowIfEmpty(_ manager: TerminalManager) {
        guard manager.sessions.isEmpty else { return }
        manager.window?.close()
    }

    // MARK: - Profile stored tab sets (used by the primary window's switches)

    func storeSessions(_ sessions: [TerminalSession], selected: UUID?, forProfileID id: UUID) {
        var merged = storedSessions[id] ?? []
        for session in sessions where !merged.contains(where: { $0.id == session.id }) {
            merged.append(session)
        }
        storedSessions[id] = merged
        storedSelectedSession[id] = selected
    }

    func appendStoredSession(_ session: TerminalSession, forProfileID id: UUID) {
        guard !storedSessions[id, default: []].contains(where: { $0.id == session.id }) else { return }
        storedSessions[id, default: []].append(session)
    }

    func takeStoredSessions(forProfileID id: UUID) -> (sessions: [TerminalSession], selected: UUID?) {
        let sessions = storedSessions.removeValue(forKey: id) ?? []
        let selected = storedSelectedSession.removeValue(forKey: id).flatMap { $0 }
        return (sessions, selected)
    }

    /// Read-only tab set for a profile's sidebar preview page: the primary
    /// window's live tabs if it's active there, else the stored set.
    func previewSessions(forProfileAt index: Int) -> [TerminalSession] {
        guard profiles.indices.contains(index) else { return [] }
        if let main = mainWindow, main.activeProfileIndex == index {
            return main.sessions
        }
        return storedSessions[profiles[index].id] ?? []
    }

    // MARK: - Profile list management

    /// Append a new profile and return its index (the caller switches to it).
    func appendProfile() -> Int {
        let newProfile = Profile(
            name: "Profile \(profiles.count + 1)",
            icon: Profile.iconChoices[profiles.count % Profile.iconChoices.count]
        )
        profiles.append(newProfile)
        saveProfilesNow()
        return profiles.count - 1
    }

    func deleteProfile(at index: Int) {
        guard profiles.count > 1, profiles.indices.contains(index) else { return }

        let profileID = profiles[index].id

        // Move every window that's on this profile to an adjacent one first —
        // the primary window stashes its live set into the doomed profile's
        // storage, which is destroyed below.
        let fallback = index > 0 ? index - 1 : 1
        for manager in windows where manager.activeProfileIndex == index {
            let needsReplacementSession = !manager.isMain
            if needsReplacementSession { manager.destroySessionsForProfileDeletion() }
            manager.switchToProfile(fallback)
            if needsReplacementSession, manager.sessions.isEmpty { manager.createSession() }
        }

        // Destroy the profile's stored sessions (incl. any just stashed).
        // Deleting a profile is an explicit close — its tmux sessions die too.
        for session in storedSessions[profileID] ?? [] {
            session.surfaceView?.destroySurface()
            if let name = session.tmuxSessionName {
                requestTmuxSessionDeletion(
                    name: name,
                    tabID: session.id,
                    title: session.title,
                    workingDirectory: session.workingDirectory,
                    profileID: profileID
                )
            }
        }
        storedSessions.removeValue(forKey: profileID)
        storedSelectedSession.removeValue(forKey: profileID)

        let pending = resumableRecords(forProfileID: profileID)
        for record in pending {
            requestTmuxSessionDeletion(record, profileID: profileID)
        }
        discardResumableRecords(pending, forProfileID: profileID)
        scheduleResumableManifestSave()

        profiles.remove(at: index)

        // Shift every window's index past the removed slot.
        for manager in windows where manager.activeProfileIndex > index {
            manager.activeProfileIndex -= 1
        }
        if let main = mainWindow {
            UserDefaults.standard.set(main.activeProfileIndex, forKey: "activeProfileIndex")
        }
        saveProfilesNow()
        refreshGitMonitoring()
    }

    func renameProfile(_ name: String, at index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].name = name
        saveProfilesNow()
    }

    func setSSHHost(_ host: String?, at index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].sshHost = host
        saveProfilesNow()
    }

    func setProfileIcon(_ icon: String, at index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].icon = icon
        saveProfilesNow()
    }

    // MARK: - Resumable tabs (tmux-backed)

    /// Set by the app delegate the moment termination is approved. Window
    /// teardown consults it: quit keeps tmux sessions alive, close kills them.
    @ObservationIgnored private(set) var isTerminating = false

    @ObservationIgnored private var manifestSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored private var didWarnTmuxMissing = false
    @ObservationIgnored private var didWarnTmuxUnreachable = false
    @ObservationIgnored private var tmuxPollTimer: Timer?
    @ObservationIgnored private var tmuxPollInFlight = false

    /// tmux names already claimed by live tabs in this app (any window or
    /// stored profile set) — excluded when allocating, alongside the server's
    /// own live list.
    func knownTmuxSessionNames() -> Set<String> {
        var names = Set<String>()
        for manager in windows {
            for session in manager.sessions {
                if let name = session.tmuxSessionName { names.insert(name) }
            }
        }
        for sessions in storedSessions.values {
            for session in sessions {
                if let name = session.tmuxSessionName { names.insert(name) }
            }
        }
        for records in pendingResumableManifest.values {
            for record in records { names.insert(record.tmuxName) }
        }
        return names
    }

    /// Approve termination: from here on, window teardown must not kill tmux
    /// sessions — they are the whole point. Writes the restore manifest.
    func prepareForTermination() {
        isTerminating = true
        saveResumableManifestNow()
    }

    func scheduleResumableManifestSave() {
        manifestSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveResumableManifestNow() }
        manifestSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Snapshot every live resumable tab, grouped by profile. Multi-window
    /// layouts collapse into their profile's tab list — windows aren't
    /// re-created on restore, tabs are.
    func saveResumableManifestNow() {
        manifestSaveWorkItem?.cancel()
        var live: ResumableWorkspace.Manifest = [:]

        func record(_ session: TerminalSession, profileID: UUID) {
            guard let name = session.tmuxSessionName else { return }
            live[profileID.uuidString, default: []].append(ResumableTabRecord(
                id: session.id,
                tmuxName: name,
                title: session.title,
                workingDirectory: session.workingDirectory
            ))
        }

        for manager in windows {
            let profileID = manager.activeProfile.id
            for session in manager.sessions { record(session, profileID: profileID) }
        }
        for (token, session) in pendingTearOutSessions {
            guard let profileIndex = pendingTearOutProfiles[token],
                  profiles.indices.contains(profileIndex) else { continue }
            record(session, profileID: profiles[profileIndex].id)
        }
        for (profileID, sessions) in storedSessions {
            for session in sessions { record(session, profileID: profileID) }
        }

        let manifest = ResumableWorkspace.merging(
            pending: pendingResumableManifest,
            live: live
        )
        if let data = ResumableWorkspace.encode(manifest) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.resumableWorkspace)
        }
    }

    func resumableRecords(forProfileID id: UUID) -> [ResumableTabRecord] {
        pendingResumableManifest[id.uuidString] ?? []
    }

    /// Only one window may restore a profile's pending records at a time.
    func claimResumableRecords(forProfileID id: UUID) -> [ResumableTabRecord]? {
        guard claimedResumableProfiles.insert(id).inserted else { return nil }
        return resumableRecords(forProfileID: id)
    }

    func releaseResumableRecordsClaim(forProfileID id: UUID) {
        claimedResumableProfiles.remove(id)
        let waiters = resumableClaimWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0() }
    }

    func whenResumableRecordsClaimAvailable(forProfileID id: UUID, perform action: @escaping () -> Void) {
        resumableClaimWaiters[id, default: []].append(action)
    }

    /// Records leave the pending set only after attachment succeeds or tmux
    /// definitively proves that the named session is missing/foreign.
    func discardResumableRecords(_ records: [ResumableTabRecord], forProfileID id: UUID) {
        pendingResumableManifest = ResumableWorkspace.removing(
            records,
            from: pendingResumableManifest,
            profileID: id
        )
        ResumableCreationRecovery.remove(records, profileID: id)
    }

    func requestTmuxSessionDeletion(
        name: String,
        tabID: UUID,
        title: String,
        workingDirectory: String?,
        profileID: UUID
    ) {
        requestTmuxSessionDeletion(
            ResumableTabRecord(
                id: tabID,
                tmuxName: name,
                title: title,
                workingDirectory: workingDirectory
            ),
            profileID: profileID
        )
    }

    private func requestTmuxSessionDeletion(_ record: ResumableTabRecord, profileID: UUID) {
        let key = profileID.uuidString
        if !pendingTmuxDeletions[key, default: []].contains(where: {
            $0.id == record.id || $0.tmuxName == record.tmuxName
        }) {
            pendingTmuxDeletions[key, default: []].append(record)
        }
        pendingResumableManifest = ResumableWorkspace.removing(
            [record],
            from: pendingResumableManifest,
            profileID: profileID
        )
        savePendingTmuxDeletions()
        ResumableCreationRecovery.remove([record], profileID: profileID)
        attemptTmuxSessionDeletion(record, profileID: profileID)
    }

    private func retryPendingTmuxDeletions() {
        for (rawProfileID, records) in pendingTmuxDeletions {
            guard let profileID = UUID(uuidString: rawProfileID) else { continue }
            pendingResumableManifest = ResumableWorkspace.removing(
                records,
                from: pendingResumableManifest,
                profileID: profileID
            )
            ResumableCreationRecovery.remove(records, profileID: profileID)
            for record in records {
                attemptTmuxSessionDeletion(record, profileID: profileID)
            }
        }
    }

    private func attemptTmuxSessionDeletion(_ record: ResumableTabRecord, profileID: UUID) {
        let operationID = "\(record.tmuxName):\(record.id.uuidString)"
        guard tmuxDeletionsInFlight.insert(operationID).inserted else { return }
        TmuxIntegration.killSession(record.tmuxName, tabID: record.id) { [weak self] complete in
            guard let self else { return }
            self.tmuxDeletionsInFlight.remove(operationID)
            guard complete else { return }
            self.pendingTmuxDeletions = ResumableWorkspace.removing(
                [record],
                from: self.pendingTmuxDeletions,
                profileID: profileID
            )
            self.savePendingTmuxDeletions()
        }
    }

    private func savePendingTmuxDeletions() {
        if pendingTmuxDeletions.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.pendingTmuxDeletions)
        } else if let data = ResumableWorkspace.encode(pendingTmuxDeletions) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.pendingTmuxDeletions)
        }
    }

    /// One-time notice when a resumable-tabs profile has no tmux installed.
    func noteTmuxMissingOnce() {
        guard !didWarnTmuxMissing else { return }
        didWarnTmuxMissing = true
        let alert = NSAlert()
        alert.messageText = "tmux Not Installed"
        alert.informativeText = "Resumable tabs need tmux (brew install tmux). Until then, this profile opens regular tabs."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// One-time notice when resumable sessions should exist but the tmux
    /// server didn't respond — typically a client/server protocol mismatch
    /// after tmux was upgraded while sessions were running. Without this the
    /// tabs silently fail to come back.
    func noteTmuxUnreachableOnce() {
        guard !didWarnTmuxUnreachable else { return }
        didWarnTmuxUnreachable = true
        let alert = NSAlert()
        alert.messageText = "Can't Reach tmux"
        alert.informativeText = "Your resumable tabs couldn't be restored because the tmux server didn't respond. If tmux was upgraded while sessions were running, run 'tmux kill-server' in a regular tab (this ends those sessions), then relaunch Wave. Wave will retry on the next launch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The tmux server consumes the shell's OSC 7, so `GHOSTTY_ACTION_PWD`
    /// never fires for resumable tabs. Poll pane identity in one batched
    /// query and feed the same cwd-grouping path instead.
    private func startTmuxIdentityPolling() {
        guard TmuxIntegration.isAvailable else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollTmuxIdentities()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        tmuxPollTimer = timer
    }

    private func pollTmuxIdentities() {
        retryPendingTmuxDeletions()
        guard !tmuxPollInFlight else { return }
        var flagged: [(TerminalSession, String)] = []
        for manager in windows {
            for session in manager.sessions {
                if let name = session.tmuxSessionName { flagged.append((session, name)) }
            }
        }
        guard !flagged.isEmpty else { return }
        tmuxPollInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let identities = TmuxIntegration.paneIdentities()
            DispatchQueue.main.async {
                guard let self else { return }
                self.tmuxPollInFlight = false
                var changed = false
                for (session, name) in flagged {
                    guard let identity = identities[name] else { continue }
                    if !identity.path.isEmpty, session.workingDirectory != identity.path {
                        session.workingDirectory = identity.path
                        changed = true
                    }
                }
                if changed { self.refreshGitMonitoring() }
            }
        }
    }

    // MARK: - Per-profile workspace data (written by whichever window is on it)

    func setPinnedPaths(_ paths: [String], forProfileAt index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].pinnedPaths = paths
        scheduleSave()
    }

    func setGroupMeta(_ meta: [String: GroupMeta], forProfileAt index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].groupMeta = meta
        scheduleSave()
    }

    func captureTheme(_ theme: SidebarTheme, forProfileAt index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].captureTheme(from: theme)
        scheduleSave()
    }

    // MARK: - Persistence

    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    /// Immediate save — use for explicit user actions (add/delete/rename profile).
    func saveProfilesNow() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    /// Debounced save — use for high-frequency changes (theme sliders, typing).
    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeToDisk() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
        }
    }

    private static func loadGroupMeta() -> [String: GroupMeta] {
        guard let data = UserDefaults.standard.data(forKey: "groupMeta"),
              let meta = try? JSONDecoder().decode([String: GroupMeta].self, from: data) else {
            return [:]
        }
        return meta
    }

    // MARK: - Git

    func gitRepositoryInfo(for path: String) -> GitRepositoryInfo? {
        guard gitIntegrationEnabled else { return nil }
        let normalized = GitCLI.normalizePath(path)
        guard case let .repo(repository)? = gitLookupsByPath[normalized] else { return nil }
        return repository
    }

    /// The group a session's directory belongs to: the deepest pinned ancestor,
    /// else the enclosing git repo root, else the directory itself. This keeps a
    /// `cd` into a subdirectory (e.g. `apps/backend` inside a monorepo) grouped
    /// under the project instead of detaching into its own group.
    func groupAnchor(for cwd: String, pinned: [String]) -> String {
        let path = GitCLI.normalizePath(cwd)
        guard !path.isEmpty else { return cwd }

        // 1. Deepest pinned ancestor — explicit intent wins. Return the original
        //    pinned string so it matches the pinned list used for ordering.
        var bestPin: String?
        var bestLength = -1
        for pin in pinned {
            let normalizedPin = GitCLI.normalizePath(pin)
            guard !normalizedPin.isEmpty else { continue }
            if (path == normalizedPin || path.hasPrefix(normalizedPin + "/")), normalizedPin.count > bestLength {
                bestPin = pin
                bestLength = normalizedPin.count
            }
        }
        if let bestPin { return bestPin }

        // 2. Enclosing git repo root (deepest repo — a nested submodule gets its own group).
        if let root = gitRepositoryInfo(for: cwd)?.repoRoot { return root }

        // 3. The directory itself — unchanged behavior for loose, non-repo dirs.
        return cwd
    }

    func gitStatus(forGroupPath path: String) -> GitRepoStatus? {
        guard gitIntegrationEnabled else { return nil }
        guard let repository = gitRepositoryInfo(for: path),
              let status = gitStatusesByRoot[repository.repoRoot],
              status.hasChanges else {
            return nil
        }

        return status
    }

    func gitStatus(forRepoRoot repoRoot: String) -> GitRepoStatus? {
        guard gitIntegrationEnabled else { return nil }
        return gitStatusesByRoot[GitCLI.normalizePath(repoRoot)]
    }

    func refreshGitStatus(forRepoRoot repoRoot: String) {
        guard gitIntegrationEnabled else { return }
        gitRepositoryService.refresh(repoRoot: repoRoot)
    }

    func refreshGitMonitoring() {
        guard gitIntegrationEnabled else {
            gitLookupsByPath = [:]
            gitStatusesByRoot = [:]
            gitRepositoryService.reset()
            return
        }

        // Live sessions across all windows + pinned paths from all profiles
        var allPaths: [String] = []
        for manager in windows {
            allPaths.append(contentsOf: manager.sessions.compactMap(\.workingDirectory))
        }
        for profile in profiles {
            allPaths.append(contentsOf: profile.pinnedPaths)
        }
        gitRepositoryService.track(paths: Array(Set(allPaths)))
    }

    // MARK: - Agent lifecycle

    private func handleAgentEvent(_ event: AgentMonitor.Event) {
        // A real session id always wins and is matched exactly — never fall back
        // to directory matching for it, or a closed/stale id would light up an
        // unrelated tab.
        if let sessionID = event.sessionID {
            if let (manager, session) = findSession(id: sessionID) {
                apply(event, to: session, viewing: isViewing(session, in: manager))
                updateDockBadge()
            }
            return
        }

        // No session id (a non-Wave / SSH agent): match by working directory,
        // but only when it maps to exactly one tab — otherwise it's ambiguous
        // and lighting up multiple tabs is worse than doing nothing.
        guard let cwd = event.cwd else { return }
        let normalized = GitCLI.normalizePath(cwd)
        guard !normalized.isEmpty else { return }
        let matches = windows.flatMap { manager in
            manager.sessions
                .filter { GitCLI.normalizePath($0.workingDirectory ?? "") == normalized }
                .map { (manager, $0) }
        }
        guard matches.count == 1, let (manager, session) = matches.first else { return }
        apply(event, to: session, viewing: isViewing(session, in: manager))
        updateDockBadge()
    }

    /// True when the user is actively looking at this exact tab right now.
    private func isViewing(_ session: TerminalSession, in manager: TerminalManager) -> Bool {
        session.id == manager.selectedSessionID
            && (manager.window?.isKeyWindow ?? false)
            && NSApp.isActive
    }

    private func apply(_ event: AgentMonitor.Event, to session: TerminalSession, viewing: Bool) {
        let action = event.action

        // Track which agent lives in this tab.
        if action.marksAgentActive, let agent = event.agent {
            session.agentKind = agent
        } else if action == .sessionEnd {
            session.agentKind = nil
        }
        session.agentStatus = action.status

        if action.status.isAttention {
            // Flag + notify whenever the user isn't looking right at this tab —
            // that includes Wave being focused on a *different* tab.
            session.needsAttention = !viewing
            if !viewing {
                postDesktopNotification(for: session, action: action)
            }
        } else {
            // Active again (start/prompt) or session ended — no pending badge.
            session.needsAttention = false
        }
    }

    func updateDockBadge() {
        let count = windows.reduce(0) { $0 + $1.sessions.filter(\.needsAttention).count }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    /// Bring a tab to the front (used when a notification is clicked).
    func focusSession(id: UUID) {
        guard let (manager, session) = findSession(id: id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        manager.window?.makeKeyAndOrderFront(nil)
        manager.selectedSessionID = session.id
    }

    // MARK: - Desktop notifications

    /// Post a native notification. The caller only invokes this when the user
    /// isn't looking at the tab, so this always posts; `willPresent` (in
    /// AppDelegate) makes the banner show even while Wave is frontmost.
    private func postDesktopNotification(for session: TerminalSession, action: AgentAction) {
        let content = UNMutableNotificationContent()
        let agentName = session.agentKind?.displayName ?? "Agent"
        let location = session.workingDirectory.map { ($0 as NSString).lastPathComponent }
        content.title = location.map { "\(agentName) · \($0)" } ?? agentName
        content.body = action == .notify ? "Needs your input" : "Finished"
        content.sound = .default
        content.userInfo = ["sessionID": session.id.uuidString]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Ghostty actions

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let surfacePtr: ghostty_surface_t? = target.tag == GHOSTTY_TARGET_SURFACE
            ? target.target.surface : nil
        let owner: (manager: TerminalManager, session: TerminalSession)? =
            surfacePtr.flatMap { findSession(surface: $0) }

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let (_, session) = owner else { return true }
            let title = String(cString: action.action.set_title.title)
            DispatchQueue.main.async {
                session.title = title
                // Identify the agent straight from the title. Sticky: once an
                // agent is detected we keep it even if the title later changes
                // (agents update their title as they work).
                if let kind = AgentKind.detect(fromTitle: title) {
                    if session.agentKind != kind {
                        session.agentKind = kind
                        if session.agentStatus == .idle { session.agentStatus = .running }
                    }
                }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let (_, session) = owner else { return true }
            let pwd = String(cString: action.action.pwd.pwd)
            DispatchQueue.main.async { [weak self] in
                // Under @Observable, views that read `session.workingDirectory`
                // (and `manager.sessions`) re-render automatically — no manual
                // invalidation needed.
                session.workingDirectory = pwd
                self?.refreshGitMonitoring()
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            let manager = owner?.manager
            DispatchQueue.main.async { [weak self] in
                (manager ?? self?.keyWindowManager)?.createSession()
            }
            return true

        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            guard let (manager, session) = owner else { return true }
            DispatchQueue.main.async { manager.closeSession(session) }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let (_, session) = owner else { return true }
            DispatchQueue.main.async { session.isRunning = false }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            guard let (manager, session) = owner else { return true }
            let needle = String(cString: action.action.start_search.needle)
            DispatchQueue.main.async {
                manager.activateSearch(for: session.id, query: needle)
                manager.searchFocusToken &+= 1
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let (manager, session) = owner else { return true }
            DispatchQueue.main.async {
                manager.clearSearchState(for: session.id)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let (manager, session) = owner else { return true }
            let rawTotal = Int(action.action.search_total.total)
            DispatchQueue.main.async {
                manager.updateSearchTotal(rawTotal >= 0 ? rawTotal : nil, for: session.id)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let (manager, session) = owner else { return true }
            let rawSelected = Int(action.action.search_selected.selected)
            DispatchQueue.main.async {
                manager.updateSearchSelection(rawSelected >= 0 ? rawSelected : nil, for: session.id)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return true

        default:
            return false
        }
    }
}
