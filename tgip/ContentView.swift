import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var manager: TerminalManager
    @StateObject private var theme = SidebarTheme.shared
    @FocusState private var windowFocusActive: Bool
    @State private var presentedGitDiff: GitDiffPresentation?

    @State private var sidebarWidth: CGFloat = 250
    @State private var sidebarHoverVisible: Bool = false
    private let minSidebarWidth: CGFloat = 180
    private let maxSidebarWidth: CGFloat = 400
    private let outerPadding: CGFloat = 10

    var body: some View {
        ZStack {
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
                    if let presentedGitDiff {
                        GitDiffInspector(
                            presentation: presentedGitDiff,
                            onClose: {
                                self.presentedGitDiff = nil
                                refocusTerminal()
                            }
                        )
                        .environmentObject(manager)
                    } else {
                        TerminalSurface(sessionID: manager.selectedSessionID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, manager.sidebarPinned ? sidebarWidth : 0)

                // Sidebar — pinned inline or drawer overlay
                if manager.sidebarPinned || sidebarHoverVisible {
                    DraggableContainer {
                        Sidebar(
                            topInset: 46,
                            sidebarPinned: $manager.sidebarPinned,
                            onOpenGitDiff: { groupPath in
                                guard let repository = manager.gitRepositoryInfo(for: groupPath) else { return }
                                manager.closeSearch()
                                presentedGitDiff = GitDiffPresentation(sourcePath: groupPath, repoRoot: repository.repoRoot)
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
        .onReceive(manager.$selectedSessionID) { newValue in
            if newValue == nil {
                windowFocusActive = true
            }
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
            if presentedGitDiff != nil {
                presentedGitDiff = nil
                refocusTerminal()
                return .handled
            }
            if manager.focusedGroupIndex != nil { manager.cancelFocus(); return .handled }
            return .ignored
        }
        .background {
            VStack {
                Button("Find") {
                    if presentedGitDiff == nil {
                        manager.showSearch()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    if presentedGitDiff == nil {
                        manager.navigateSearch(.next)
                    }
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    if presentedGitDiff == nil {
                        manager.navigateSearch(.previous)
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button("Toggle Git Diff") {
                    toggleGitDiff()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .hidden()
        }
    }

    private func refocusTerminal() {
        // Re-select the current session to trigger the terminal surface to become first responder
        let current = manager.selectedSessionID
        manager.selectedSessionID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            manager.selectedSessionID = current
        }
    }

    private func toggleGitDiff() {
        if presentedGitDiff != nil {
            presentedGitDiff = nil
            refocusTerminal()
            return
        }
        guard let session = manager.sessions.first(where: { $0.id == manager.selectedSessionID }),
              let dir = session.workingDirectory,
              let repo = manager.gitRepositoryInfo(for: dir) else {
            return
        }
        manager.closeSearch()
        presentedGitDiff = GitDiffPresentation(sourcePath: dir, repoRoot: repo.repoRoot)
    }

    /// The same group list the sidebar uses — needed for confirmFocus.
    var sidebarGroups: [(fullPath: String, sessions: [TerminalSession])] {
        buildGroups(sessions: manager.sessions, pinned: manager.pinnedPaths)
    }
}

// MARK: - Shared group builder

/// Build the ordered group list: pinned groups first (always shown),
/// then any remaining groups from live sessions.
func buildGroups(
    sessions: [TerminalSession],
    pinned: [String]
) -> [(fullPath: String, sessions: [TerminalSession])] {
    let dict = Dictionary(grouping: sessions) { $0.workingDirectory ?? "~" }
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
    @EnvironmentObject var manager: TerminalManager
    @ObservedObject private var theme = SidebarTheme.shared
    @State private var showThemeEditor = false
    @State private var scrolledProfileID: UUID?
    var topInset: CGFloat = 0
    @Binding var sidebarPinned: Bool
    var onOpenGitDiff: (String) -> Void

    init(
        topInset: CGFloat = 0,
        sidebarPinned: Binding<Bool> = .constant(true),
        onOpenGitDiff: @escaping (String) -> Void = { _ in }
    ) {
        self.topInset = topInset
        self._sidebarPinned = sidebarPinned
        self.onOpenGitDiff = onOpenGitDiff
    }

    private var activeGroups: [(fullPath: String, sessions: [TerminalSession])] {
        buildGroups(sessions: manager.sessions, pinned: manager.pinnedPaths)
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
                        .foregroundStyle(theme.adaptiveForeground(opacity: sidebarPinned ? 0.5 : 0.35))
                }
                .buttonStyle(.plain)
                .help(sidebarPinned ? "Hide Sidebar" : "Pin Sidebar")

                Spacer()
            }
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)

            // Groups — horizontally paginated per profile
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(manager.profiles) { profile in
                        profilePage(profile)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $scrolledProfileID)
            .onAppear {
                scrolledProfileID = manager.activeProfile.id
            }
            .onChange(of: scrolledProfileID) { _, newID in
                guard let newID,
                      let index = manager.profiles.firstIndex(where: { $0.id == newID }),
                      index != manager.activeProfileIndex else { return }
                manager.switchToProfile(index, direction: index > manager.activeProfileIndex ? .forward : .backward)
            }
            .onChange(of: manager.activeProfileIndex) { _, newIndex in
                let targetID = manager.profiles[newIndex].id
                guard scrolledProfileID != targetID else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    scrolledProfileID = targetID
                }
            }

            Divider().opacity(0.3).padding(.horizontal, 12)

            // Bottom bar
            HStack(spacing: 0) {
                Text("\(manager.sessions.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.adaptiveForeground(opacity: 0.3))
                    .frame(width: 30, alignment: .center)

                Spacer()

                ProfileBar()

                Spacer()

                Button(action: { manager.createSession() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.adaptiveForeground(opacity: 0.5))
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
            ThemeEditor()
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
                    ? activeGroups
                    : buildGroups(sessions: manager.sessionsForProfile(at: index), pinned: profile.pinnedPaths)
                let labels = disambiguatedLabels(for: profileGroups.map { $0.fullPath })

                ForEach(Array(profileGroups.enumerated()), id: \.element.fullPath) { groupIndex, group in
                    if isActive {
                        let isFocused = manager.focusedGroupIndex == groupIndex
                        DirectoryGroup(
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
                            gitStatus: manager.gitStatusForProfile(at: index, groupPath: group.fullPath)
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
    @ObservedObject private var theme = SidebarTheme.shared
    let sessions: [TerminalSession]
    let meta: GroupMeta
    let label: String
    var gitStatus: GitRepoStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                GroupIcon(meta: meta, opacity: 0.4)
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.adaptiveForeground(opacity: 0.45))
                    .lineLimit(1)
                Spacer()
                if let gitStatus {
                    RepoDirtyBadge(status: gitStatus, isFocused: false)
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
                        .foregroundStyle(theme.adaptiveForeground(opacity: 0.4))
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
    @EnvironmentObject var manager: TerminalManager
    @ObservedObject private var theme = SidebarTheme.shared
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
                GroupIcon(meta: meta, opacity: isFocused ? 0.85 : 0.55)

                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.adaptiveForeground(opacity: isFocused ? 0.9 : 0.65))
                    .lineLimit(1)

                Spacer()

                if let gitStatus {
                    Button {
                        onOpenGitDiff(fullPath)
                    } label: {
                        RepoDirtyBadge(status: gitStatus, isFocused: isFocused)
                    }
                    .buttonStyle(.plain)
                    .help("Open uncommitted diff")
                }

                if groupIndex < 9 {
                    Text("\u{2318}\(groupIndex + 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.adaptiveForeground(opacity: isFocused ? 0.55 : 0.3))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.adaptiveForeground(opacity: isFocused ? 0.12 : 0.04))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused ? theme.adaptiveForeground(opacity: 0.08) : Color.clear)
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

            // Tabs
            if sessions.isEmpty {
                EmptyView()
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { tabIndex, session in
                    let isTabFocused = isFocused && focusedTabOffset == tabIndex
                    TabRow(session: session, directory: fullPath, isTabFocused: isTabFocused, isLast: tabIndex == sessions.count - 1)
                }

            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Tab Row

// Shared drag state — avoids async NSItemProvider round-trips
enum DragState {
    static var draggedSessionID: UUID?
}

struct TabRow: View {
    @EnvironmentObject var manager: TerminalManager
    @ObservedObject private var theme = SidebarTheme.shared
    @ObservedObject var session: TerminalSession
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

    private var dotColor: Color {
        if session.needsAttention { return .orange }
        return session.isRunning ? .green : .gray
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
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: session.needsAttention ? .orange.opacity(attentionPulse ? 0.9 : 0.2) : .clear, radius: 4)

                Text(session.title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(theme.adaptiveForeground(opacity: isSelected ? 0.95 : 0.75))
                    .lineLimit(1)

                Spacer()

                if hovering || isSelected {
                    Button(action: { manager.closeSession(session) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.adaptiveForeground(opacity: 0.35))
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(theme.adaptiveForeground(opacity: hovering ? 0.1 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        session.needsAttention ? Color.orange.opacity(attentionPulse ? 0.14 : 0.06) :
                        isSelected ? theme.adaptiveForeground(opacity: 0.12) :
                        (hovering || isTabFocused) ? theme.adaptiveForeground(opacity: 0.06) :
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

        // On the last tab, bottom half means "after" instead of "before"
        let atEnd = isLast && info.location.y > 20
        if atEnd != dropAtEnd {
            dropAtEnd = atEnd
        }

        if atEnd {
            withAnimation(.easeInOut(duration: 0.2)) {
                manager.moveSessionToEndOfGroup(draggedID, in: directory)
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                manager.moveSession(draggedID, before: targetSession.id, in: directory)
            }
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
        isTargeted = false
        dropAtEnd = false
        DragState.draggedSessionID = nil
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
        withAnimation(.easeInOut(duration: 0.2)) {
            manager.moveSessionToEndOfGroup(draggedID, in: directory)
        }
        return true
    }
}

struct GroupIcon: View {
    @ObservedObject private var theme = SidebarTheme.shared
    let meta: GroupMeta
    var opacity: Double = 0.55

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
                    .foregroundStyle(theme.adaptiveForeground(opacity: opacity))
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Profile Bar

struct ProfileBar: View {
    @EnvironmentObject var manager: TerminalManager
    @ObservedObject private var theme = SidebarTheme.shared
    @State private var hoveredIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(manager.profiles.enumerated()), id: \.element.id) { index, profile in
                Button(action: { withAnimation(.easeInOut(duration: 0.25)) { manager.switchToProfile(index) } }) {
                    Group {
                        if index == manager.activeProfileIndex {
                            Image(systemName: profile.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.adaptiveForeground(opacity: hoveredIndex == index ? 0.9 : 0.7))
                        } else {
                            Circle()
                                .fill(theme.adaptiveForeground(opacity: hoveredIndex == index ? 0.5 : 0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .background(
            Capsule()
                .fill(theme.adaptiveForeground(opacity: 0.04))
        )
        .contextMenu {
            Button("Add New Profile") {
                manager.addProfile()
            }
        }
    }
}

struct TerminalSurface: View {
    @EnvironmentObject var manager: TerminalManager
    @ObservedObject private var theme = SidebarTheme.shared
    let sessionID: UUID?

    var body: some View {
        TerminalView(sessionID: sessionID)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
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
    var body: some View {
        HStack(spacing: 8) {
            WindowDot(color: Color(red: 1.0, green: 0.37, blue: 0.33)) {
                performWindowAction { $0.close() }
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
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
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
