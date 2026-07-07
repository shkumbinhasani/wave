import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TerminalManager.self) var manager
    @Environment(SidebarTheme.self) private var theme
    @FocusState private var windowFocusActive: Bool

    @State private var sidebarWidth: CGFloat = 250
    @State private var sidebarHoverVisible: Bool = false
    private let minSidebarWidth: CGFloat = 180
    private let maxSidebarWidth: CGFloat = 400
    private let outerPadding: CGFloat = 10
    private var innerCornerRadius: CGFloat { WindowConfigurator.windowCornerRadius - outerPadding }

    var body: some View {
        @Bindable var manager = manager
        return ZStack {
            ZStack {
                // Blur layer — always present, controlled by blur slider
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, emphasized: false)
                    .opacity(theme.vibrancy)

                // Solid accent fill on top — tint slider controls how much it covers the blur
                theme.accentColor
                    .opacity(theme.backgroundOpacity)

                // Brightness overlay
                LinearGradient(
                    colors: [
                        Color.white.opacity(theme.brightness * 0.2),
                        Color.white.opacity(theme.brightness * 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            ZStack(alignment: .leading) {
                // Terminal or diff inspector fills the main pane
                Group {
                    if let presentedGitDiff = manager.presentedGitDiff {
                        GitDiffInspector(
                            presentation: presentedGitDiff,
                            cornerRadius: innerCornerRadius,
                            onClose: { manager.closeGitDiff() }
                        )
                        .environment(manager)
                    } else {
                        TerminalSurface(sessionID: manager.selectedSessionID, cornerRadius: innerCornerRadius)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, manager.sidebarPinned ? sidebarWidth : 0)

                // Sidebar — pinned inline or drawer overlay
                if manager.sidebarPinned || sidebarHoverVisible {
                    DraggableContainer {
                        Sidebar(
                            lightText: theme.lightText,
                            topInset: 46,
                            sidebarPinned: $manager.sidebarPinned,
                            onOpenGitDiff: { groupPath in
                                manager.openGitDiff(forGroupPath: groupPath)
                            }
                        )
                    }
                    .frame(width: sidebarWidth)
                    .background {
                            if !manager.sidebarPinned {
                                ZStack {
                                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, emphasized: false)
                                    theme.accentColor.opacity(theme.backgroundOpacity)
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(theme.brightness * 0.2),
                                            Color.white.opacity(theme.brightness * 0.06)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.3), radius: 15, x: 5)
                            }
                        }
                        .transition(.move(edge: .leading))
                        .zIndex(1)

                    // Resize handle
                    SidebarResizeHandle(width: $sidebarWidth, min: minSidebarWidth, max: maxSidebarWidth)
                        .frame(width: 8)
                        .offset(x: sidebarWidth - 4)
                        .zIndex(2)
                }

                // Hover trigger zone when sidebar is hidden
                if !manager.sidebarPinned && !sidebarHoverVisible {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    sidebarHoverVisible = true
                                }
                            }
                        }
                        .zIndex(3)
                }
            }
            .padding(outerPadding)
            // Dismiss drawer when mouse leaves sidebar area
            .onContinuousHover { phase in
                if !manager.sidebarPinned && sidebarHoverVisible {
                    switch phase {
                    case .active(let location):
                        if location.x > sidebarWidth + outerPadding + 20 {
                            withAnimation(.easeIn(duration: 0.2)) {
                                sidebarHoverVisible = false
                            }
                        }
                    case .ended:
                        break
                    }
                }
            }
        }
        .ignoresSafeArea()
        .background(WindowConfigurator(outerPadding: outerPadding))
        .frame(minWidth: 760, minHeight: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($windowFocusActive)
        .onAppear {
            if manager.selectedSessionID == nil {
                windowFocusActive = true
            }
        }
        .onChange(of: manager.selectedSessionID) { _, newValue in
            if newValue == nil {
                windowFocusActive = true
            }
        }
        .onChange(of: manager.gitIntegrationEnabled) { _, enabled in
            if !enabled { manager.closeGitDiff() }
        }
        .onKeyPress(.upArrow) {
            if manager.focusedGroupIndex != nil { manager.moveFocusUp(); return .handled }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if manager.focusedGroupIndex != nil { manager.moveFocusDown(); return .handled }
            return .ignored
        }
        .onKeyPress(.return) {
            if manager.focusedGroupIndex != nil {
                manager.confirmFocus(groups: sidebarGroups)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if manager.searchState != nil {
                manager.closeSearch()
                return .handled
            }
            if manager.presentedGitDiff != nil {
                manager.closeGitDiff()
                return .handled
            }
            if manager.focusedGroupIndex != nil { manager.cancelFocus(); return .handled }
            return .ignored
        }
    }

    /// The same group list the sidebar uses — needed for confirmFocus.
    var sidebarGroups: [(fullPath: String, sessions: [TerminalSession])] {
        buildGroups(sessions: manager.sessions, pinned: manager.pinnedPaths) {
            manager.groupAnchor(for: $0, pinned: manager.pinnedPaths)
        }
    }
}

// MARK: - Sidebar tree (subfolders within a group)

/// One rendered row inside a group: either a folder header or a session tab,
/// carrying its depth for indentation.
struct SidebarTreeRow: Identifiable {
    enum Kind { case folder(String); case tab(TerminalSession) }
    let id: String
    let kind: Kind
    let fullPath: String   // folder path (= the session's cwd for tabs)
    let depth: Int
    /// Per level (root→self): whether the node at that level is the last child of
    /// its parent. Drives the connectors — ancestors that aren't last keep a
    /// vertical spine; the last child curves and stops, others tee and continue.
    let lasts: [Bool]
}

/// Flatten a group's sessions into a folder tree relative to `anchor`. Sessions at
/// the anchor itself stay at depth 0; deeper ones nest under folder rows, with
/// single-child folder chains collapsed (so `apps/backend` is one row, not two).
func buildSidebarTree(sessions: [TerminalSession], anchor: String) -> [SidebarTreeRow] {
    final class Node {
        var children: [String: Node] = [:]
        var sessions: [TerminalSession] = []
        var order = Int.max
    }

    let root = Node()
    var counter = 0

    for session in sessions {
        let cwd = session.workingDirectory ?? anchor
        guard cwd != anchor, cwd.hasPrefix(anchor + "/") else { root.sessions.append(session); continue }
        let components = cwd.dropFirst(anchor.count + 1).split(separator: "/").map(String.init)
        var node = root
        for component in components {
            if node.children[component] == nil {
                let child = Node()
                child.order = counter; counter += 1
                node.children[component] = child
            }
            node = node.children[component]!
        }
        node.sessions.append(session)
    }

    var rows: [SidebarTreeRow] = []

    func walk(_ node: Node, path: String, depth: Int, lasts: [Bool]) {
        let folders = node.children.sorted { $0.value.order < $1.value.order }
        let total = node.sessions.count + folders.count
        var index = 0

        // Tabs first, then subfolders.
        for session in node.sessions {
            index += 1
            rows.append(SidebarTreeRow(id: "t:\(session.id)", kind: .tab(session),
                                       fullPath: path, depth: depth, lasts: lasts + [index == total]))
        }
        for (key, child) in folders {
            index += 1
            let isLast = index == total
            // Collapse single-child, session-less chains: apps -> backend becomes "apps/backend".
            var label = key, fullPath = path + "/" + key, node = child
            while node.sessions.isEmpty, node.children.count == 1, let (childKey, grandchild) = node.children.first {
                label += "/\(childKey)"; fullPath += "/\(childKey)"; node = grandchild
            }
            rows.append(SidebarTreeRow(id: "f:\(fullPath)", kind: .folder(label),
                                       fullPath: fullPath, depth: depth, lasts: lasts + [isLast]))
            walk(node, path: fullPath, depth: depth + 1, lasts: lasts + [isLast])
        }
    }

    walk(root, path: anchor, depth: 0, lasts: [])
    return rows
}

// MARK: - Shared group builder

/// Build the ordered group list: pinned groups first (always shown),
/// then any remaining groups from live sessions.
func buildGroups(
    sessions: [TerminalSession],
    pinned: [String],
    anchor: (String) -> String
) -> [(fullPath: String, sessions: [TerminalSession])] {
    let dict = Dictionary(grouping: sessions) { anchor($0.workingDirectory ?? "~") }
    var seen = Set<String>()
    var result: [(fullPath: String, sessions: [TerminalSession])] = []

    // Pinned groups first, in pinned order
    for path in pinned {
        seen.insert(path)
        result.append((fullPath: path, sessions: dict[path] ?? []))
    }

    // Remaining groups sorted alphabetically
    for key in dict.keys.sorted() where !seen.contains(key) {
        result.append((fullPath: key, sessions: dict[key]!))
    }
    return result
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(TerminalManager.self) var manager
    // Text mode is threaded in from ContentView (the main tree) rather than read
    // from the theme here. The whole sidebar lives in DraggableContainer's detached
    // NSHostingView, which re-runs view bodies on a theme change but only repaints
    // structural/input changes — a self-observed color change left tab text stale
    // until a hover. Passing lightText as an input makes the recolor a structural
    // change the host paints, with no full-subtree recreation. See foreground().
    let lightText: Bool
    @State private var showThemeEditor = false
    var topInset: CGFloat = 0
    @Binding var sidebarPinned: Bool
    var onOpenGitDiff: (String) -> Void

    init(
        lightText: Bool,
        topInset: CGFloat = 0,
        sidebarPinned: Binding<Bool> = .constant(true),
        onOpenGitDiff: @escaping (String) -> Void = { _ in }
    ) {
        self.lightText = lightText
        self.topInset = topInset
        self._sidebarPinned = sidebarPinned
        self.onOpenGitDiff = onOpenGitDiff
    }

    private func foreground(_ opacity: Double) -> Color {
        SidebarTheme.adaptiveForeground(lightText: lightText, opacity: opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Window controls row
            HStack(spacing: 8) {
                SidebarWindowControls()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarPinned.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(foreground(sidebarPinned ? 0.5 : 0.35))
                }
                .buttonStyle(.plain)
                .help(sidebarPinned ? "Hide Sidebar" : "Pin Sidebar")

                Spacer()
            }
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)

            // Groups — horizontally paginated per profile.
            // AppKit-backed pager: each page renders once into a cached layer; the
            // swipe just translates layers (GPU), so paging stays smooth no matter
            // how heavy a page is. SwiftUI re-renders a page only on data changes.
            // Every window shows the pager; switching is global. The active page
            // shows THIS window's tabs (sessions are per-window); the profile's
            // stored tab set itself lives in the primary window.
            ProfilePager(
                pageCount: manager.profiles.count,
                activeIndex: manager.activeProfileIndex,
                makePage: { index in
                    AnyView(profilePage(manager.profiles[index]).environment(manager))
                },
                onSwitch: { index in
                    guard index != manager.activeProfileIndex else { return }
                    manager.switchToProfile(index, direction: index > manager.activeProfileIndex ? .forward : .backward)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar
            HStack(spacing: 0) {
                Text("\(manager.sessions.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(foreground(0.3))
                    .frame(width: 30, alignment: .center)

                Spacer()

                ProfileBar(lightText: lightText)

                Spacer()

                Button(action: { manager.createSession() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(foreground(0.5))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit Theme...") {
                showThemeEditor = true
            }
        }
        .popover(isPresented: $showThemeEditor, arrowEdge: .trailing) {
            ThemeEditor(theme: manager.theme)
        }
    }

    // MARK: - Profile page

    @ViewBuilder
    private func profilePage(_ profile: Profile) -> some View {
        let index = manager.profiles.firstIndex(where: { $0.id == profile.id }) ?? 0
        let isActive = index == manager.activeProfileIndex

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                let profileGroups = isActive
                    ? buildGroups(sessions: manager.sessions, pinned: manager.pinnedPaths) {
                        manager.groupAnchor(for: $0, pinned: manager.pinnedPaths)
                    }
                    : buildGroups(sessions: manager.sessionsForProfile(at: index), pinned: profile.pinnedPaths) {
                        manager.groupAnchor(for: $0, pinned: profile.pinnedPaths)
                    }
                let labels = disambiguatedLabels(for: profileGroups.map { $0.fullPath })

                ForEach(Array(profileGroups.enumerated()), id: \.element.fullPath) { groupIndex, group in
                    if isActive {
                        let isFocused = manager.focusedGroupIndex == groupIndex
                        DirectoryGroup(
                            lightText: lightText,
                            directory: labels[group.fullPath] ?? group.fullPath,
                            fullPath: group.fullPath,
                            sessions: group.sessions,
                            groupIndex: groupIndex,
                            isFocused: isFocused,
                            focusedTabOffset: isFocused ? manager.focusedTabOffset : nil,
                            onOpenGitDiff: onOpenGitDiff
                        )
                    } else {
                        let meta = profile.groupMeta[group.fullPath] ?? GroupMeta()
                        InactiveGroupRow(
                            sessions: group.sessions,
                            meta: meta,
                            label: meta.displayName ?? (labels[group.fullPath] ?? group.fullPath),
                            gitStatus: manager.gitStatusForProfile(at: index, groupPath: group.fullPath),
                            lightText: profile.lightText
                        )
                    }

                    if groupIndex < profileGroups.count - 1 {
                        Divider().opacity(0.3).padding(.horizontal, 12).padding(.vertical, 4)
                    }
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
    }

    private func disambiguatedLabels(for paths: [String]) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func components(_ path: String) -> [String] {
            if path == "~" { return ["~"] }
            var p = path
            if p.hasPrefix(home) {
                let rest = String(p.dropFirst(home.count))
                p = rest.isEmpty ? "~" : "~\(rest)"
            }
            return p.split(separator: "/").map(String.init).reversed()
        }

        let parsed: [(path: String, comps: [String])] = paths.map { ($0, components($0)) }
        var result: [String: String] = [:]
        var pending = parsed
        var depth = 1
        while !pending.isEmpty && depth <= 20 {
            let groups = Dictionary(grouping: pending) { entry -> String in
                entry.comps.prefix(depth).reversed().joined(separator: "/")
            }
            var colliding: [(path: String, comps: [String])] = []
            for (label, entries) in groups {
                if entries.count == 1 { result[entries[0].path] = label }
                else { colliding.append(contentsOf: entries) }
            }
            pending = colliding
            depth += 1
        }
        for entry in pending {
            result[entry.path] = entry.comps.reversed().joined(separator: "/")
        }
        return result
    }
}

// MARK: - Inactive profile group (read-only preview)

struct InactiveGroupRow: View {
    let sessions: [TerminalSession]
    let meta: GroupMeta
    let label: String
    var gitStatus: GitRepoStatus?
    /// This profile's text mode — so the page renders in its own colors while
    /// swiping, rather than borrowing the live (active) profile's colors.
    var lightText: Bool = true

    private func foreground(_ opacity: Double) -> Color {
        SidebarTheme.adaptiveForeground(lightText: lightText, opacity: opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                GroupIcon(meta: meta, opacity: 0.4, lightText: lightText)
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground(0.45))
                    .lineLimit(1)
                Spacer()
                if let gitStatus {
                    RepoDirtyBadge(lightText: lightText, status: gitStatus, isFocused: false)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.isRunning ? Color.green.opacity(0.5) : Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(session.title)
                        .font(.system(size: 14))
                        .foregroundStyle(foreground(0.4))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Directory Group

struct DirectoryGroup: View {
    @Environment(TerminalManager.self) var manager
    let lightText: Bool
    private func foreground(_ opacity: Double) -> Color {
        SidebarTheme.adaptiveForeground(lightText: lightText, opacity: opacity)
    }
    let directory: String
    let fullPath: String
    let sessions: [TerminalSession]
    let groupIndex: Int
    let isFocused: Bool
    let focusedTabOffset: Int?
    let onOpenGitDiff: (String) -> Void
    private var meta: GroupMeta { manager.meta(for: fullPath) }
    private var label: String { meta.displayName ?? directory }
    private var gitStatus: GitRepoStatus? { manager.gitStatus(forGroupPath: fullPath) }

    private static let iconChoices = [
        "folder", "folder.fill", "terminal", "server.rack",
        "cloud", "hammer", "wrench.and.screwdriver", "shippingbox",
        "cpu", "externaldrive", "globe", "lock.shield",
        "leaf", "flame", "bolt", "star",
        "heart", "flag", "bookmark", "tag",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Group header
            HStack(spacing: 8) {
                GroupIcon(meta: meta, opacity: isFocused ? 0.85 : 0.55, lightText: lightText)

                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground(isFocused ? 0.9 : 0.65))
                    .lineLimit(1)

                Spacer()

                if let gitStatus {
                    Button {
                        onOpenGitDiff(fullPath)
                    } label: {
                        RepoDirtyBadge(lightText: lightText, status: gitStatus, isFocused: isFocused)
                    }
                    .buttonStyle(.plain)
                    .help("Open uncommitted diff")
                }

                if groupIndex < 9 {
                    Text("\u{2318}\(groupIndex + 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(foreground(isFocused ? 0.55 : 0.3))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(foreground(isFocused ? 0.12 : 0.04))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused ? foreground(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if sessions.isEmpty {
                    manager.createSession(in: fullPath)
                }
            }
            .contextMenu {
                Button("New Tab Here") {
                    manager.createSession(in: fullPath)
                }

                if gitStatus != nil {
                    Button("Show Uncommitted Diff") {
                        onOpenGitDiff(fullPath)
                    }
                }

                Divider()
                // Icon picker
                Menu("Icon") {
                    ForEach(Self.iconChoices, id: \.self) { icon in
                        Button {
                            manager.setIcon(icon, for: fullPath)
                        } label: {
                            Label(icon, systemImage: icon)
                        }
                    }
                }

                Button("Choose Image...") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image, .png, .jpeg, .ico]
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose an icon image for this group"
                    panel.directoryURL = URL(fileURLWithPath: (fullPath as NSString).expandingTildeInPath)
                    if panel.runModal() == .OK, let url = panel.url {
                        manager.setImage(url.path, for: fullPath)
                    }
                }

                if meta.imagePath != nil {
                    Button("Remove Image") {
                        manager.setImage(nil, for: fullPath)
                    }
                }

                // Rename
                Button("Rename...") {
                    let alert = NSAlert()
                    alert.messageText = "Rename Group"
                    alert.informativeText = "Display name for \(directory)"
                    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                    field.stringValue = meta.displayName ?? ""
                    field.placeholderString = directory
                    alert.accessoryView = field
                    alert.addButton(withTitle: "OK")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        manager.setDisplayName(field.stringValue, for: fullPath)
                    }
                }

                Divider()

                Button(manager.isPinned(fullPath) ? "Unpin" : "Pin") {
                    manager.togglePin(path: fullPath)
                }
            }

            // Tabs — nested by subfolder relative to the group anchor.
            // Zero spacing so each row's connector is flush with the next and the
            // tree spine stays continuous (row padding lives inside the rows).
            if !sessions.isEmpty {
                let rows = buildSidebarTree(sessions: sessions, anchor: fullPath)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 0) {
                            treeConnector(depth: row.depth, lasts: row.lasts)
                            switch row.kind {
                            case .folder(let label):
                                folderRow(label: label)
                            case .tab(let session):
                                let originalIndex = sessions.firstIndex(where: { $0.id == session.id }) ?? 0
                                TabRow(
                                    lightText: lightText,
                                    session: session,
                                    directory: row.fullPath,
                                    isTabFocused: isFocused && focusedTabOffset == originalIndex,
                                    isLast: row.id == rows.last?.id
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static let treeIndent: CGFloat = 14

    /// Dotted tree connectors: a continuing vertical spine for ancestors that
    /// aren't the last child, and a curved elbow into each row's element.
    @ViewBuilder
    private func treeConnector(depth: Int, lasts: [Bool]) -> some View {
        let indent = Self.treeIndent
        Canvas { ctx, size in
            let dash = StrokeStyle(lineWidth: 1, lineCap: .round)
            let shading = GraphicsContext.Shading.color(foreground(0.28))
            let midY = size.height / 2
            let radius: CGFloat = 5
            func centerX(_ level: Int) -> CGFloat { CGFloat(level) * indent + indent / 2 }

            // Ancestor spines — only where that ancestor still has siblings below.
            for level in 0..<depth where level < lasts.count && !lasts[level] {
                var p = Path()
                p.move(to: CGPoint(x: centerX(level), y: 0))
                p.addLine(to: CGPoint(x: centerX(level), y: size.height))
                ctx.stroke(p, with: shading, style: dash)
            }

            // Elbow into this element.
            let x = centerX(depth)
            let isLast = lasts.last ?? true
            var elbow = Path()
            elbow.move(to: CGPoint(x: x, y: 0))
            elbow.addLine(to: CGPoint(x: x, y: midY - radius))
            elbow.addQuadCurve(to: CGPoint(x: x + radius, y: midY), control: CGPoint(x: x, y: midY))
            ctx.stroke(elbow, with: shading, style: dash)

            if !isLast {   // tee: spine keeps going for the next sibling
                var down = Path()
                down.move(to: CGPoint(x: x, y: midY))
                down.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(down, with: shading, style: dash)
            }
        }
        .frame(width: CGFloat(depth + 1) * indent)
    }

    @ViewBuilder
    private func folderRow(label: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground(0.5))
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Tab Row

// Shared drag state — avoids async NSItemProvider round-trips
enum DragState {
    static var draggedSessionID: UUID?
}

struct TabRow: View {
    @Environment(TerminalManager.self) var manager
    let lightText: Bool
    private func foreground(_ opacity: Double) -> Color {
        SidebarTheme.adaptiveForeground(lightText: lightText, opacity: opacity)
    }
    var session: TerminalSession
    let directory: String
    var isTabFocused: Bool = false
    var isLast: Bool = false
    @State private var hovering = false
    @State private var isDropTarget = false
    @State private var dropAtEnd = false
    @State private var attentionPulse = false

    private var isSelected: Bool {
        manager.selectedSessionID == session.id
    }

    private var isDragging: Bool {
        DragState.draggedSessionID == session.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drop indicator line above
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 8)
                .opacity(isDropTarget && !dropAtEnd ? 1 : 0)

            HStack(spacing: 8) {
                if let agent = session.agentKind {
                    let glyphTint = session.agentStatus.isAttention
                        ? session.agentStatus.color
                        : agent.tint
                    Group {
                        if let asset = agent.assetName, !agent.logoIsTemplate {
                            // Brand-color logo (e.g. Claude) — untinted.
                            Image(asset)
                                .renderingMode(.original)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 13, height: 13)
                        } else if let asset = agent.assetName {
                            // Monochrome logo — tinted like the SF Symbols.
                            Image(asset)
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(glyphTint)
                        } else {
                            Image(systemName: agent.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(glyphTint)
                        }
                    }
                    .help("\(agent.displayName) — \(session.agentStatus.rawValue)")
                }

                Text(session.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(foreground(isSelected ? 0.95 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if hovering || isSelected {
                    Button(action: { manager.closeSession(session) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(foreground(0.4))
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(foreground(hovering ? 0.12 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        session.needsAttention ? session.agentStatus.color.opacity(attentionPulse ? 0.16 : 0.06) :
                        isSelected ? foreground(0.12) :
                        (hovering || isTabFocused) ? foreground(0.06) :
                        Color.clear
                    )
            )

            // Drop indicator line below (last tab only)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 8)
                .opacity(isDropTarget && dropAtEnd ? 1 : 0)
        }
        .opacity(isDragging ? 0.4 : 1)
        .contentShape(Rectangle())
        .preventWindowDrag()
        .onHover { hovering = $0 }
        .onTapGesture {
            manager.selectedSessionID = session.id
            manager.focusedGroupIndex = nil
        }
        .contextMenu {
            Button("Move to New Window") {
                AppRuntime.shared.tearOut(sessionID: session.id, at: nil)
            }

            Divider()

            Button("Close Tab") {
                manager.closeSession(session)
            }
        }
        .onChange(of: session.needsAttention) { _, needs in
            if needs {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    attentionPulse = true
                }
            } else {
                withAnimation(.default) {
                    attentionPulse = false
                }
            }
        }
        .onDrag {
            DragState.draggedSessionID = session.id
            // Watch for this drag ending unclaimed outside every window → tear-out.
            TearOutDetector.begin(sessionID: session.id)
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
            targetSession: session,
            directory: directory,
            manager: manager,
            isTargeted: $isDropTarget,
            dropAtEnd: $dropAtEnd,
            isLast: isLast
        ))
        .animation(.easeInOut(duration: 0.2), value: isDropTarget)
        .animation(.easeInOut(duration: 0.15), value: isSelected || isTabFocused || hovering)
    }
}

struct TabDropDelegate: DropDelegate {
    let targetSession: TerminalSession
    let directory: String
    let manager: TerminalManager
    @Binding var isTargeted: Bool
    @Binding var dropAtEnd: Bool
    var isLast: Bool = false

    func dropEntered(info: DropInfo) {
        guard let draggedID = DragState.draggedSessionID,
              draggedID != targetSession.id else { return }
        isTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedID = DragState.draggedSessionID,
              draggedID != targetSession.id else {
            return DropProposal(operation: .move)
        }

        // Only update the drop indicator here — the actual reorder happens on
        // drop. dropUpdated fires continuously on hover, so mutating the model
        // here would thrash the session list on every pointer move.
        let atEnd = isLast && info.location.y > 20
        if atEnd != dropAtEnd {
            dropAtEnd = atEnd
        }

        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dropAtEnd = false
    }

    func validateDrop(info: DropInfo) -> Bool {
        DragState.draggedSessionID != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let landAtEnd = dropAtEnd
        defer {
            isTargeted = false
            dropAtEnd = false
            DragState.draggedSessionID = nil
        }
        guard let draggedID = DragState.draggedSessionID,
              draggedID != targetSession.id else { return true }

        if manager.sessions.contains(where: { $0.id == draggedID }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if landAtEnd {
                    manager.moveSessionToEndOfGroup(draggedID, in: directory)
                } else {
                    manager.moveSession(draggedID, before: targetSession.id, in: directory)
                }
            }
        } else {
            // Dragged from another window — adopt it into this one.
            AppRuntime.shared.transferSession(draggedID, to: manager)
        }
        return true
    }
}

struct GroupDropDelegate: DropDelegate {
    let directory: String
    @Binding var isTargeted: Bool
    let manager: TerminalManager

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        DragState.draggedSessionID != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let draggedID = DragState.draggedSessionID else { return false }
        DragState.draggedSessionID = nil
        if manager.sessions.contains(where: { $0.id == draggedID }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                manager.moveSessionToEndOfGroup(draggedID, in: directory)
            }
        } else {
            AppRuntime.shared.transferSession(draggedID, to: manager)
        }
        return true
    }
}

struct GroupIcon: View {
    let meta: GroupMeta
    var opacity: Double = 0.55
    /// Text mode threaded in so the icon recolors inside the detached host.
    let lightText: Bool

    private var iconColor: Color {
        SidebarTheme.adaptiveForeground(lightText: lightText, opacity: opacity)
    }

    var body: some View {
        Group {
            if let nsImage = meta.loadImage() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: meta.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Profile Bar

struct ProfileBar: View {
    @Environment(TerminalManager.self) var manager
    let lightText: Bool
    private func foreground(_ opacity: Double) -> Color {
        SidebarTheme.adaptiveForeground(lightText: lightText, opacity: opacity)
    }
    @State private var hoveredIndex: Int?

    @State private var scrolledActiveID: UUID?
    @State private var barWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(manager.profiles.enumerated()), id: \.element.id) { index, profile in
                    let isActive = index == manager.activeProfileIndex
                    Button(action: { withAnimation(.easeInOut(duration: 0.25)) { manager.switchToProfile(index) } }) {
                        Image(systemName: profile.icon)
                            // Same size for every profile — the active one is marked by a
                            // subtle pill behind it, not by scaling up (Arc-style).
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(foreground(
                                isActive ? 0.95 : (hoveredIndex == index ? 0.6 : 0.4)
                            ))
                            .frame(width: 30, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(foreground(isActive ? 0.13 : (hoveredIndex == index ? 0.06 : 0)))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(profile.id)
                .onHover { h in
                    hoveredIndex = h ? index : nil
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .contextMenu {
                    Button("Rename Profile...") {
                        let alert = NSAlert()
                        alert.messageText = "Rename Profile"
                        alert.informativeText = "Enter a name for this profile"
                        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                        field.stringValue = profile.name
                        alert.accessoryView = field
                        alert.addButton(withTitle: "OK")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
                            manager.renameProfile(field.stringValue, at: index)
                        }
                    }

                    Menu("Icon") {
                        ForEach(Profile.iconChoices, id: \.self) { icon in
                            Button {
                                manager.setProfileIcon(icon, at: index)
                            } label: {
                                Label(icon, systemImage: icon)
                            }
                        }
                    }

                    Divider()

                    Button(profile.sshHost != nil ? "Edit SSH Connection..." : "Set SSH Host...") {
                        let alert = NSAlert()
                        alert.messageText = "SSH Connection"
                        alert.informativeText = "Password is stored securely in Keychain"
                        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
                        stack.orientation = .vertical
                        stack.spacing = 8
                        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                        hostField.stringValue = profile.sshHost ?? ""
                        hostField.placeholderString = "user@hostname"
                        let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                        passField.placeholderString = "password (optional)"
                        if let host = profile.sshHost { passField.stringValue = KeychainHelper.load(for: host) ?? "" }
                        stack.addArrangedSubview(hostField)
                        stack.addArrangedSubview(passField)
                        alert.accessoryView = stack
                        alert.addButton(withTitle: "OK")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn {
                            let oldHost = profile.sshHost
                            let newHost = hostField.stringValue.isEmpty ? nil : hostField.stringValue
                            manager.setSSHHost(newHost, at: index)
                            // Update Keychain
                            if let old = oldHost, old != newHost { KeychainHelper.delete(for: old) }
                            if let host = newHost {
                                if !passField.stringValue.isEmpty {
                                    KeychainHelper.save(password: passField.stringValue, for: host)
                                } else {
                                    KeychainHelper.delete(for: host)
                                }
                            }
                        }
                    }

                    if profile.sshHost != nil {
                        Button("Remove SSH Host") {
                            if let host = profile.sshHost { KeychainHelper.delete(for: host) }
                            manager.setSSHHost(nil, at: index)
                        }
                    }

                    Divider()

                    Button("Add New Profile") {
                        manager.addProfile()
                    }

                    if manager.profiles.count > 1 {
                        Divider()
                        Button("Delete Profile") {
                            manager.deleteProfile(at: index)
                        }
                    }
                }
            }
        }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: barWidth)
        }
        .scrollPosition(id: $scrolledActiveID, anchor: .center)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            barWidth = width
        }
        .onAppear { scrolledActiveID = manager.activeProfile.id }
        .onChange(of: manager.activeProfileIndex) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                scrolledActiveID = manager.activeProfile.id
            }
        }
        .contextMenu {
            Button("Add New Profile") {
                manager.addProfile()
            }
        }
    }
}

struct TerminalSurface: View {
    @Environment(TerminalManager.self) var manager
    @Environment(SidebarTheme.self) private var theme
    let sessionID: UUID?
    var cornerRadius: CGFloat = 10

    var body: some View {
        TerminalView(sessionID: sessionID)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.adaptiveForeground(opacity: 0.14), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if let sessionID,
                   let searchState = manager.searchState,
                   searchState.sessionID == sessionID {
                    TerminalSearchOverlay(
                        query: Binding(
                            get: { manager.searchState?.query ?? "" },
                            set: { manager.updateSearchQuery($0) }
                        ),
                        totalMatches: searchState.totalMatches,
                        selectedMatch: searchState.selectedMatch,
                        focusToken: manager.searchFocusToken,
                        onPrevious: { manager.navigateSearch(.previous) },
                        onNext: { manager.navigateSearch(.next) },
                        onClose: { manager.closeSearch() }
                    )
                    .padding(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .shadow(color: Color.black.opacity(0.10), radius: 20, y: 10)
    }
}

struct SidebarWindowControls: View {
    @Environment(TerminalManager.self) private var manager

    var body: some View {
        HStack(spacing: 8) {
            WindowDot(color: Color(red: 1.0, green: 0.37, blue: 0.33)) {
                performWindowAction { window in
                    if manager.confirmWindowClose() { window.close() }
                }
            }
            WindowDot(color: Color(red: 1.0, green: 0.74, blue: 0.18)) {
                performWindowAction { window in
                    window.styleMask.insert(.miniaturizable)

                    if let button = window.standardWindowButton(.miniaturizeButton), button.isEnabled {
                        button.performClick(nil)

                        if !window.isMiniaturized {
                            window.performMiniaturize(button)
                        }
                    } else {
                        window.performMiniaturize(nil)
                    }
                }
            }
            WindowDot(color: Color(red: 0.16, green: 0.80, blue: 0.25)) {
                performWindowAction { $0.toggleFullScreen(nil) }
            }
        }
        .preventWindowDrag()
    }

    private func performWindowAction(_ action: (NSWindow) -> Void) {
        // Act on this manager's own window — with multiple windows open, the
        // key/main window may be a different one.
        guard let window = manager.window
            ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            return
        }

        action(window)
    }
}

struct WindowDot: View {
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.opacity(hovering ? 0.98 : 0.9))
                .frame(width: 12, height: 12)
                .overlay {
                    Circle()
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.6)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 3, y: 1)
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .preventWindowDrag()
        .onHover { hovering = $0 }
    }
}
