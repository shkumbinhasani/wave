import SwiftUI
import GhosttyKit
import Observation

/// App-level state shared by every window: the ghostty runtime, the profiles
/// list and their stored tab sets, git monitoring, attention routing, and the
/// registry of open windows. Per-window state (sessions, selection, active
/// profile, theme, search, …) lives in TerminalManager.
@Observable
final class AppRuntime {
    static let shared = AppRuntime()

    private enum DefaultsKey {
        static let gitIntegrationEnabled = "git.enabled"
    }

    @ObservationIgnored let ghostty: GhosttyRuntime
    @ObservationIgnored private let gitRepositoryService: GitRepositoryService
    @ObservationIgnored private let attentionMonitor = AttentionMonitor()

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

        // Attention monitor — highlight tabs when external tools need input
        attentionMonitor.onAttention = { [weak self] sessionID, cwd in
            self?.handleAttention(sessionID: sessionID, cwd: cwd)
        }
        attentionMonitor.start()

        saveProfilesNow()
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
        storedSessions[id] = sessions
        storedSelectedSession[id] = selected
    }

    func takeStoredSessions(forProfileID id: UUID) -> (sessions: [TerminalSession], selected: UUID?) {
        (storedSessions[id] ?? [], storedSelectedSession[id].flatMap { $0 })
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
            manager.switchToProfile(fallback)
        }

        // Destroy the profile's stored sessions (incl. any just stashed).
        for session in storedSessions[profileID] ?? [] {
            session.surfaceView?.destroySurface()
        }
        storedSessions.removeValue(forKey: profileID)
        storedSelectedSession.removeValue(forKey: profileID)

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

    // MARK: - Attention

    private func handleAttention(sessionID: UUID?, cwd: String?) {
        if let sessionID {
            // Exact match — only highlight the specific tab
            if let (manager, session) = findSession(id: sessionID),
               session.id != manager.selectedSessionID {
                session.needsAttention = true
            }
        } else if let cwd {
            // Fallback for non-Wave terminals — match by working directory
            let normalized = GitCLI.normalizePath(cwd)
            guard !normalized.isEmpty else { return }
            for manager in windows {
                for session in manager.sessions {
                    guard let pwd = session.workingDirectory,
                          session.id != manager.selectedSessionID else { continue }
                    if GitCLI.normalizePath(pwd) == normalized {
                        session.needsAttention = true
                    }
                }
            }
        }
        updateDockBadge()
    }

    func updateDockBadge() {
        let count = windows.reduce(0) { $0 + $1.sessions.filter(\.needsAttention).count }
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
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
