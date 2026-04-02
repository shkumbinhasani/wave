import SwiftUI
import Combine
import GhosttyKit

class TerminalManager: ObservableObject {
    private var themeCancellable: AnyCancellable?
    private let gitRepositoryService: GitRepositoryService
    private let attentionMonitor = AttentionMonitor()
    @Published var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID? {
        didSet {
            if let selectedSessionID { clearAttention(for: selectedSessionID) }
            if oldValue != selectedSessionID {
                handleSelectedSessionChange(from: oldValue, to: selectedSessionID)
            }
        }
    }

    // MARK: - Profiles

    enum ProfileSwitchDirection { case forward, backward }

    @Published var profiles: [Profile] = []
    @Published var activeProfileIndex: Int = 0
    /// Direction of the last profile switch — drives slide animation.
    @Published var profileSwitchDirection: ProfileSwitchDirection = .forward
    /// Per-profile session storage (kept alive while profile is inactive).
    private var storedSessions: [UUID: [TerminalSession]] = [:]
    /// Per-profile selected session.
    private var storedSelectedSession: [UUID: UUID?] = [:]
    /// Suppresses didSet persistence during profile switch.
    private var isSwitchingProfile = false

    var activeProfile: Profile {
        profiles.indices.contains(activeProfileIndex) ? profiles[activeProfileIndex] : Profile()
    }

    /// Pinned directory paths — always shown in sidebar, persisted via profile.
    @Published var pinnedPaths: [String] = [] {
        didSet {
            guard !isSwitchingProfile, profiles.indices.contains(activeProfileIndex) else { return }
            profiles[activeProfileIndex].pinnedPaths = pinnedPaths
            scheduleSave()
        }
    }

    /// Per-group metadata (icon, display name). Keyed by absolute path.
    @Published var groupMeta: [String: GroupMeta] = [:] {
        didSet {
            guard !isSwitchingProfile, profiles.indices.contains(activeProfileIndex) else { return }
            profiles[activeProfileIndex].groupMeta = groupMeta
            scheduleSave()
        }
    }

    @Published var sidebarPinned: Bool = true

    /// Which group index is keyboard-focused (nil = none). Set by Cmd+N.
    @Published var focusedGroupIndex: Int?
    /// Which tab within the focused group is highlighted. Arrow keys move this.
    @Published var focusedTabOffset: Int = 0
    @Published var searchState: TerminalSearchState?
    @Published var searchFocusToken: Int = 0
    @Published private(set) var gitLookupsByPath: [String: GitPathLookup] = [:]
    @Published private(set) var gitStatusesByRoot: [String: GitRepoStatus] = [:]

    let ghostty: GhosttyRuntime

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    init() {
        self.gitRepositoryService = GitRepositoryService()
        self.ghostty = GhosttyRuntime()

        // Load profiles or migrate from legacy settings
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let loaded = try? JSONDecoder().decode([Profile].self, from: data),
           !loaded.isEmpty {
            self.profiles = loaded
            self.activeProfileIndex = min(
                max(UserDefaults.standard.integer(forKey: "activeProfileIndex"), 0),
                loaded.count - 1
            )
        } else {
            // Migration: create default profile from existing settings
            var defaultProfile = Profile()
            defaultProfile.pinnedPaths = UserDefaults.standard.stringArray(forKey: "pinnedPaths") ?? []
            defaultProfile.groupMeta = Self.loadGroupMeta()
            defaultProfile.captureTheme(from: SidebarTheme.shared)
            self.profiles = [defaultProfile]
            self.activeProfileIndex = 0
        }

        // Load active profile data
        let active = profiles[activeProfileIndex]
        self.pinnedPaths = active.pinnedPaths
        self.groupMeta = active.groupMeta

        gitRepositoryService.onSnapshot = { [weak self] lookups, statuses in
            self?.gitLookupsByPath = lookups
            self?.gitStatusesByRoot = statuses
        }
        ghostty.onAction = { [weak self] target, action in
            self?.handleAction(target: target, action: action) ?? false
        }

        // Attention monitor — highlight tabs when external tools need input
        attentionMonitor.onAttention = { [weak self] sessionID, cwd in
            self?.handleAttention(sessionID: sessionID, cwd: cwd)
        }
        attentionMonitor.start()

        // Apply theme from active profile & sync brightness → terminal color scheme
        let theme = SidebarTheme.shared
        theme.apply(from: active)
        ghostty.setColorScheme(dark: theme.brightness < 0.5)
        themeCancellable = theme.$brightness
            .removeDuplicates()
            .sink { [weak self] val in
                self?.ghostty.setColorScheme(dark: val < 0.5)
            }

        // Persist theme edits back to the active profile
        theme.onThemeChanged = { [weak self] in
            self?.saveThemeToActiveProfile()
        }

        saveProfiles()
        createSession()
    }

    // MARK: - Sessions

    /// Sessions for a given profile index (active uses live array, others use stored).
    func sessionsForProfile(at index: Int) -> [TerminalSession] {
        if index == activeProfileIndex { return sessions }
        return storedSessions[profiles[index].id] ?? []
    }

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
            session.surfaceView = view
            sessions.append(session)
            selectedSessionID = session.id
        } else {
            // Local session
            let session = TerminalSession(title: "Terminal \(sessions.count + 1)")
            session.workingDirectory = pwd
            let view = TerminalSurfaceView(runtime: ghostty, session: session, workingDirectory: pwd)
            session.surfaceView = view
            sessions.append(session)
            selectedSessionID = session.id
        }

        focusedGroupIndex = nil
        refreshGitMonitoring()
    }

    func closeSession(_ session: TerminalSession) {
        guard shouldCloseSession(session) else { return }
        closeSessionNow(session)
    }

    func shouldConfirmAppQuit() -> Bool {
        ghostty.appNeedsConfirmQuit()
    }

    private func closeSessionNow(_ session: TerminalSession) {
        session.surfaceView?.destroySurface()
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
        refreshGitMonitoring()
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

    // MARK: - Pinning

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
        refreshGitMonitoring()
    }

    func isPinned(_ path: String) -> Bool {
        pinnedPaths.contains(path)
    }

    func meta(for path: String) -> GroupMeta {
        groupMeta[path] ?? GroupMeta()
    }

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

    private static func loadGroupMeta() -> [String: GroupMeta] {
        guard let data = UserDefaults.standard.data(forKey: "groupMeta"),
              let meta = try? JSONDecoder().decode([String: GroupMeta].self, from: data) else {
            return [:]
        }
        return meta
    }

    /// Git status for a group path in any profile — data is tracked globally.
    func gitStatusForProfile(at index: Int, groupPath path: String) -> GitRepoStatus? {
        gitStatus(forGroupPath: path)
    }

    // MARK: - Profile Management

    func switchToProfile(_ index: Int, direction: ProfileSwitchDirection? = nil) {
        guard index != activeProfileIndex, profiles.indices.contains(index) else { return }

        profileSwitchDirection = direction ?? (index > activeProfileIndex ? .forward : .backward)
        isSwitchingProfile = true

        // Save current profile state
        let currentID = profiles[activeProfileIndex].id
        storedSessions[currentID] = sessions
        storedSelectedSession[currentID] = selectedSessionID
        profiles[activeProfileIndex].pinnedPaths = pinnedPaths
        profiles[activeProfileIndex].groupMeta = groupMeta
        profiles[activeProfileIndex].captureTheme(from: SidebarTheme.shared)

        // Close search if open
        if let state = searchState {
            session(for: state.sessionID)?.surfaceView?.endSearch()
            searchState = nil
        }
        focusedGroupIndex = nil

        // Switch
        activeProfileIndex = index
        UserDefaults.standard.set(index, forKey: "activeProfileIndex")

        // Load new profile — git data stays warm globally, no restore needed
        let newProfile = profiles[index]
        sessions = storedSessions[newProfile.id] ?? []
        selectedSessionID = storedSelectedSession[newProfile.id] ?? nil
        pinnedPaths = newProfile.pinnedPaths
        groupMeta = newProfile.groupMeta
        SidebarTheme.shared.apply(from: newProfile)

        isSwitchingProfile = false

        // Ensure at least one session
        if sessions.isEmpty {
            createSession()
        } else if selectedSessionID == nil {
            selectedSessionID = sessions.first?.id
        }

        refreshGitMonitoring()
        saveProfiles()
    }

    func switchToNextProfile() {
        let next = (activeProfileIndex + 1) % profiles.count
        switchToProfile(next, direction: .forward)
    }

    func switchToPreviousProfile() {
        let prev = (activeProfileIndex - 1 + profiles.count) % profiles.count
        switchToProfile(prev, direction: .backward)
    }

    func addProfile() {
        let newProfile = Profile(
            name: "Profile \(profiles.count + 1)",
            icon: Profile.iconChoices[profiles.count % Profile.iconChoices.count]
        )
        profiles.append(newProfile)
        saveProfiles()
        switchToProfile(profiles.count - 1, direction: .forward)
    }

    func deleteProfile(at index: Int) {
        guard profiles.count > 1, profiles.indices.contains(index) else { return }

        let profileID = profiles[index].id

        // Close all sessions in the deleted profile
        let sessionsToClose = storedSessions[profileID] ?? (index == activeProfileIndex ? sessions : [])
        for session in sessionsToClose {
            session.surfaceView?.destroySurface()
        }
        storedSessions.removeValue(forKey: profileID)
        storedSelectedSession.removeValue(forKey: profileID)

        if index == activeProfileIndex {
            // Switch to adjacent profile first
            let newIndex = index > 0 ? index - 1 : 1
            switchToProfile(newIndex)
            // Remove after switching (index shifted if needed)
            let removeIndex = index > 0 ? index : 0
            profiles.remove(at: removeIndex)
            activeProfileIndex = min(activeProfileIndex, profiles.count - 1)
        } else {
            profiles.remove(at: index)
            if index < activeProfileIndex {
                activeProfileIndex -= 1
            }
        }

        UserDefaults.standard.set(activeProfileIndex, forKey: "activeProfileIndex")
        saveProfiles()
    }

    func renameProfile(_ name: String, at index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].name = name
        saveProfiles()
    }

    func setSSHHost(_ host: String?, at index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].sshHost = host
        saveProfiles()
    }

    func setProfileIcon(_ icon: String, at index: Int) {
        guard profiles.indices.contains(index) else { return }
        profiles[index].icon = icon
        saveProfiles()
    }

    private var saveWorkItem: DispatchWorkItem?

    /// Immediate save — use for explicit user actions (add/delete/rename profile).
    private func saveProfiles() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    /// Debounced save — use for high-frequency changes (theme sliders, typing).
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func writeToDisk() {
        // Capture latest theme into profile before writing
        if profiles.indices.contains(activeProfileIndex) {
            profiles[activeProfileIndex].captureTheme(from: SidebarTheme.shared)
        }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
        }
    }

    private func saveThemeToActiveProfile() {
        scheduleSave()
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

    func gitRepositoryInfo(for path: String) -> GitRepositoryInfo? {
        let normalized = GitCLI.normalizePath(path)
        guard case let .repo(repository)? = gitLookupsByPath[normalized] else { return nil }
        return repository
    }

    func gitStatus(forGroupPath path: String) -> GitRepoStatus? {
        guard let repository = gitRepositoryInfo(for: path),
              let status = gitStatusesByRoot[repository.repoRoot],
              status.hasChanges else {
            return nil
        }

        return status
    }

    func gitStatus(forRepoRoot repoRoot: String) -> GitRepoStatus? {
        gitStatusesByRoot[GitCLI.normalizePath(repoRoot)]
    }

    func refreshGitStatus(forRepoRoot repoRoot: String) {
        gitRepositoryService.refresh(repoRoot: repoRoot)
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

    // MARK: - Attention

    private func handleAttention(sessionID: UUID?, cwd: String?) {
        if let sessionID {
            // Exact match — only highlight the specific tab
            if let session = sessions.first(where: { $0.id == sessionID }), session.id != selectedSessionID {
                session.needsAttention = true
            }
        } else if let cwd {
            // Fallback for non-Wave terminals — match by working directory
            let normalized = GitCLI.normalizePath(cwd)
            guard !normalized.isEmpty else { return }
            for session in sessions {
                guard let pwd = session.workingDirectory, session.id != selectedSessionID else { continue }
                if GitCLI.normalizePath(pwd) == normalized {
                    session.needsAttention = true
                }
            }
        }
        updateDockBadge()
    }

    func clearAttention(for sessionID: UUID) {
        if let session = sessions.first(where: { $0.id == sessionID }) {
            session.needsAttention = false
        }
        updateDockBadge()
    }

    private func updateDockBadge() {
        let count = sessions.filter(\.needsAttention).count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - Lookup

    private func findSession(for ptr: ghostty_surface_t) -> TerminalSession? {
        sessions.first { $0.surfaceView?.surface == ptr }
    }

    private func session(for id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    // MARK: - Actions

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let surfacePtr: ghostty_surface_t? = target.tag == GHOSTTY_TARGET_SURFACE
            ? target.target.surface : nil

        switch action.tag {
        case GHOSTTY_ACTION_RENDER:
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            let title = String(cString: action.action.set_title.title)
            DispatchQueue.main.async {
                session.title = title
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            let pwd = String(cString: action.action.pwd.pwd)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                session.workingDirectory = pwd
                self.objectWillChange.send()
                self.refreshGitMonitoring()
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async { [weak self] in self?.createSession() }
            return true

        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            DispatchQueue.main.async { [weak self] in self?.closeSession(session) }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            DispatchQueue.main.async { session.isRunning = false }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            let needle = String(cString: action.action.start_search.needle)
            DispatchQueue.main.async { [weak self] in
                self?.activateSearch(for: session.id, query: needle)
                self?.searchFocusToken &+= 1
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            DispatchQueue.main.async { [weak self] in
                self?.clearSearchState(for: session.id)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            let rawTotal = Int(action.action.search_total.total)
            DispatchQueue.main.async { [weak self] in
                self?.updateSearchTotal(rawTotal >= 0 ? rawTotal : nil, for: session.id)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            let rawSelected = Int(action.action.search_selected.selected)
            DispatchQueue.main.async { [weak self] in
                self?.updateSearchSelection(rawSelected >= 0 ? rawSelected : nil, for: session.id)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return true

        default:
            return false
        }
    }

    private func refreshGitMonitoring() {
        // Active sessions + pinned paths from all profiles (for sidebar badges)
        var allPaths = sessions.compactMap(\.workingDirectory) + pinnedPaths
        for profile in profiles {
            allPaths.append(contentsOf: profile.pinnedPaths)
        }
        gitRepositoryService.track(paths: Array(Set(allPaths)))
    }

    private func handleSelectedSessionChange(from previous: UUID?, to current: UUID?) {
        guard let previous,
              previous != current,
              searchState?.sessionID == previous else {
            return
        }

        session(for: previous)?.surfaceView?.endSearch()
        clearSearchState(for: previous)
    }

    private func activateSearch(for sessionID: UUID, query: String) {
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

    private func clearSearchState(for sessionID: UUID) {
        guard searchState?.sessionID == sessionID else { return }
        searchState = nil
    }

    private func updateSearchTotal(_ total: Int?, for sessionID: UUID) {
        guard var state = searchState, state.sessionID == sessionID else { return }
        state.totalMatches = total
        searchState = state
    }

    private func updateSearchSelection(_ selected: Int?, for sessionID: UUID) {
        guard var state = searchState, state.sessionID == sessionID else { return }
        state.selectedMatch = selected
        searchState = state
    }
}
