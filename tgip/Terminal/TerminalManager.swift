import SwiftUI
import Combine
import GhosttyKit

struct SidebarGroup: Identifiable {
    let fullPath: String
    let sessions: [TerminalSession]

    var id: String { fullPath }
}

func buildSidebarGroups(
    sessions: [TerminalSession],
    pinned: [String]
) -> [SidebarGroup] {
    let groupedSessions = Dictionary(grouping: sessions) { $0.workingDirectory ?? "~" }
    var seen = Set<String>()
    var result: [SidebarGroup] = []

    for path in pinned {
        seen.insert(path)
        result.append(SidebarGroup(fullPath: path, sessions: groupedSessions[path] ?? []))
    }

    for path in groupedSessions.keys.sorted() where !seen.contains(path) {
        result.append(SidebarGroup(fullPath: path, sessions: groupedSessions[path] ?? []))
    }

    return result
}

func disambiguatedSidebarLabels(for paths: [String]) -> [String: String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    func components(for path: String) -> [String] {
        if path == "~" { return ["~"] }

        var normalizedPath = path
        if normalizedPath.hasPrefix(home) {
            let remainder = String(normalizedPath.dropFirst(home.count))
            normalizedPath = remainder.isEmpty ? "~" : "~\(remainder)"
        }

        return normalizedPath.split(separator: "/").map(String.init).reversed()
    }

    let parsedPaths = paths.map { (path: $0, components: components(for: $0)) }
    var result: [String: String] = [:]
    var pending = parsedPaths
    var depth = 1

    while !pending.isEmpty && depth <= 20 {
        let grouped = Dictionary(grouping: pending) { entry -> String in
            entry.components.prefix(depth).reversed().joined(separator: "/")
        }
        var collisions: [(path: String, components: [String])] = []

        for (label, entries) in grouped {
            if entries.count == 1 {
                result[entries[0].path] = label
            } else {
                collisions.append(contentsOf: entries)
            }
        }

        pending = collisions
        depth += 1
    }

    for entry in pending {
        result[entry.path] = entry.components.reversed().joined(separator: "/")
    }

    return result
}

class TerminalManager: ObservableObject {
    private var themeCancellable: AnyCancellable?
    private var sessionsByID: [UUID: TerminalSession] = [:]

    @Published var sessions: [TerminalSession] = [] {
        didSet {
            rebuildSessionIndex()
            rebuildSidebarModel()
        }
    }
    @Published var selectedSessionID: UUID?
    @Published private(set) var sidebarGroups: [SidebarGroup] = []
    @Published private(set) var sidebarLabels: [String: String] = [:]

    /// Pinned directory paths — always shown in sidebar, persisted across launches.
    @Published var pinnedPaths: [String] {
        didSet {
            UserDefaults.standard.set(pinnedPaths, forKey: "pinnedPaths")
            rebuildSidebarModel()
        }
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

    let ghostty: GhosttyRuntime

    var selectedSession: TerminalSession? {
        guard let selectedSessionID else { return nil }
        return sessionsByID[selectedSessionID]
    }

    init() {
        self.pinnedPaths = UserDefaults.standard.stringArray(forKey: "pinnedPaths") ?? []
        self.groupMeta = Self.loadGroupMeta()
        self.ghostty = GhosttyRuntime()
        ghostty.onAction = { [weak self] target, action in
            self?.handleAction(target: target, action: action) ?? false
        }

        // Sync theme brightness → terminal color scheme
        let theme = SidebarTheme.shared
        ghostty.setColorScheme(dark: theme.brightness < 0.5)
        themeCancellable = theme.$brightness
            .removeDuplicates()
            .sink { [weak self] val in
                self?.ghostty.setColorScheme(dark: val < 0.5)
            }

        rebuildSessionIndex()
        rebuildSidebarModel()
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
    }

    func closeSession(_ session: TerminalSession) {
        session.surfaceView?.destroySurface()
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.last?.id
        }
    }

    func moveSession(_ draggedID: UUID, before targetID: UUID, in directory: String) -> Bool {
        guard draggedID != targetID,
              let draggedIndex = sessions.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = sessions.firstIndex(where: { $0.id == targetID }),
              sessions[draggedIndex].workingDirectory == directory,
              sessions[targetIndex].workingDirectory == directory else { return false }

        let adjustedTarget = draggedIndex < targetIndex ? targetIndex - 1 : targetIndex
        guard adjustedTarget != draggedIndex else { return false }

        let dragged = sessions.remove(at: draggedIndex)
        sessions.insert(dragged, at: adjustedTarget)
        return true
    }

    func moveSessionToEndOfGroup(_ draggedID: UUID, in directory: String) -> Bool {
        guard let draggedIndex = sessions.firstIndex(where: { $0.id == draggedID }),
              sessions[draggedIndex].workingDirectory == directory,
              let lastGroupIndex = sessions.lastIndex(where: { $0.workingDirectory == directory }) else { return false }

        guard draggedIndex != lastGroupIndex else { return false }

        let dragged = sessions.remove(at: draggedIndex)
        let insertionIndex = sessions.lastIndex(where: { $0.workingDirectory == directory }).map { $0 + 1 } ?? sessions.count
        sessions.insert(dragged, at: insertionIndex)
        return true
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
        let previousImagePath = m.imagePath
        m.imagePath = imagePath
        GroupMeta.invalidateImageCache(for: previousImagePath)
        GroupMeta.invalidateImageCache(for: imagePath)
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
        guard sidebarGroups.indices.contains(index) else { return }
        focusedGroupIndex = index
        focusedTabOffset = 0
    }

    func moveFocusDown() {
        guard let focusedGroupIndex, sidebarGroups.indices.contains(focusedGroupIndex) else { return }
        let maxOffset = max(sidebarGroups[focusedGroupIndex].sessions.count - 1, 0)
        focusedTabOffset = min(focusedTabOffset + 1, maxOffset)
    }

    func moveFocusUp() {
        focusedTabOffset = max(0, focusedTabOffset - 1)
    }

    func confirmFocus() {
        guard let activeGroupIndex = focusedGroupIndex, sidebarGroups.indices.contains(activeGroupIndex) else { return }
        let group = sidebarGroups[activeGroupIndex]
        if group.sessions.isEmpty {
            let session = TerminalSession(title: "Terminal \(sessions.count + 1)")
            session.workingDirectory = group.fullPath
            let view = TerminalSurfaceView(runtime: ghostty, session: session, workingDirectory: group.fullPath)
            session.surfaceView = view
            sessions.append(session)
            selectedSessionID = session.id
        } else {
            let clamped = min(focusedTabOffset, group.sessions.count - 1)
            selectedSessionID = group.sessions[clamped].id
        }
        focusedGroupIndex = nil
    }

    func cancelFocus() {
        focusedGroupIndex = nil
    }

    // MARK: - Lookup

    private func findSession(for ptr: ghostty_surface_t) -> TerminalSession? {
        guard let userdata = ghostty_surface_userdata(ptr) else { return nil }
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
        return view.session
    }

    func session(for id: UUID) -> TerminalSession? {
        sessionsByID[id]
    }

    private func rebuildSessionIndex() {
        sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    private func rebuildSidebarModel() {
        let groups = buildSidebarGroups(sessions: sessions, pinned: pinnedPaths)
        sidebarGroups = groups
        sidebarLabels = disambiguatedSidebarLabels(for: groups.map(\.fullPath))

        guard let focusedGroupIndex else { return }

        if groups.isEmpty {
            self.focusedGroupIndex = nil
            focusedTabOffset = 0
            return
        }

        if focusedGroupIndex >= groups.count {
            self.focusedGroupIndex = groups.count - 1
        }

        let activeIndex = self.focusedGroupIndex ?? 0
        let maxOffset = max(groups[activeIndex].sessions.count - 1, 0)
        focusedTabOffset = min(focusedTabOffset, maxOffset)
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
                guard session.workingDirectory != pwd else { return }
                session.workingDirectory = pwd
                self.rebuildSidebarModel()
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
}
