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
        }
    }

    /// Pinned directory paths — always shown in sidebar, persisted across launches.
    @Published var pinnedPaths: [String] {
        didSet { UserDefaults.standard.set(pinnedPaths, forKey: "pinnedPaths") }
    }

    /// Per-group metadata (icon, display name). Keyed by absolute path.
    @Published var groupMeta: [String: GroupMeta] {
        didSet { saveGroupMeta() }
    }

    @Published var sidebarPinned: Bool = true

    /// Which group index is keyboard-focused (nil = none). Set by Cmd+N.
    @Published var focusedGroupIndex: Int?
    /// Which tab within the focused group is highlighted. Arrow keys move this.
    @Published var focusedTabOffset: Int = 0
    @Published private(set) var gitLookupsByPath: [String: GitPathLookup] = [:]
    @Published private(set) var gitStatusesByRoot: [String: GitRepoStatus] = [:]

    let ghostty: GhosttyRuntime

    var selectedSession: TerminalSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    init() {
        self.gitRepositoryService = GitRepositoryService()
        self.pinnedPaths = UserDefaults.standard.stringArray(forKey: "pinnedPaths") ?? []
        self.groupMeta = Self.loadGroupMeta()
        self.ghostty = GhosttyRuntime()
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

        // Sync theme brightness → terminal color scheme
        let theme = SidebarTheme.shared
        ghostty.setColorScheme(dark: theme.brightness < 0.5)
        themeCancellable = theme.$brightness
            .removeDuplicates()
            .sink { [weak self] val in
                self?.ghostty.setColorScheme(dark: val < 0.5)
            }

        createSession()
    }

    // MARK: - Sessions

    func createSession(in directory: String? = nil) {
        let pwd = directory ?? selectedSession?.workingDirectory
        let session = TerminalSession(title: "Terminal \(sessions.count + 1)")
        session.workingDirectory = pwd
        let view = TerminalSurfaceView(runtime: ghostty, session: session, workingDirectory: pwd)
        session.surfaceView = view
        sessions.append(session)
        selectedSessionID = session.id
        focusedGroupIndex = nil
        refreshGitMonitoring()
    }

    func closeSession(_ session: TerminalSession) {
        session.surfaceView?.destroySurface()
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
        refreshGitMonitoring()
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

    private func saveGroupMeta() {
        if let data = try? JSONEncoder().encode(groupMeta) {
            UserDefaults.standard.set(data, forKey: "groupMeta")
        }
    }

    private static func loadGroupMeta() -> [String: GroupMeta] {
        guard let data = UserDefaults.standard.data(forKey: "groupMeta"),
              let meta = try? JSONDecoder().decode([String: GroupMeta].self, from: data) else {
            return [:]
        }
        return meta
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
        sessions = sessions
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                session.title = title
                self.sessions = self.sessions
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            let pwd = String(cString: action.action.pwd.pwd)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                session.workingDirectory = pwd
                self.sessions = self.sessions
                self.refreshGitMonitoring()
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async { [weak self] in self?.createSession() }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            DispatchQueue.main.async { [weak self] in self?.closeSession(session) }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let surfacePtr, let session = findSession(for: surfacePtr) else { return true }
            DispatchQueue.main.async { session.isRunning = false }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return true

        default:
            return false
        }
    }

    private func refreshGitMonitoring() {
        let trackedPaths = sessions.compactMap(\.workingDirectory) + pinnedPaths
        gitRepositoryService.track(paths: trackedPaths)
    }
}
