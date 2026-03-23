import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var manager: TerminalManager
    @StateObject private var theme = SidebarTheme.shared
    @FocusState private var windowFocusActive: Bool

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
                // Terminal always fills the space
                TerminalSurface(sessionID: manager.selectedSessionID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, manager.sidebarPinned ? sidebarWidth : 0)

                // Sidebar — pinned inline or drawer overlay
                if manager.sidebarPinned || sidebarHoverVisible {
                    DraggableContainer {
                        Sidebar(topInset: 46, sidebarPinned: $manager.sidebarPinned)
                    }
                    .frame(width: sidebarWidth)
                    .background {
                            if !manager.sidebarPinned {
                                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, emphasized: false)
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
        .background(WindowConfigurator())
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
                manager.confirmFocus()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if manager.focusedGroupIndex != nil { manager.cancelFocus(); return .handled }
            return .ignored
        }
    }

}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var manager: TerminalManager
    @State private var showThemeEditor = false
    var topInset: CGFloat = 0
    @Binding var sidebarPinned: Bool

    init(topInset: CGFloat = 0, sidebarPinned: Binding<Bool> = .constant(true)) {
        self.topInset = topInset
        self._sidebarPinned = sidebarPinned
    }

    private var groups: [SidebarGroup] {
        manager.sidebarGroups
    }

    var body: some View {
        VStack(spacing: 0) {
            // Window controls row
            HStack(spacing: 8) {
                SidebarWindowControls()

                // Sidebar toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarPinned.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(sidebarPinned ? 0.5 : 0.35))
                }
                .buttonStyle(.plain)
                .help(sidebarPinned ? "Hide Sidebar" : "Pin Sidebar")

                Spacer()
            }
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)

            // Groups
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let labels = manager.sidebarLabels
                    ForEach(Array(groups.enumerated()), id: \.element.fullPath) { groupIndex, group in
                        let isFocused = manager.focusedGroupIndex == groupIndex
                        DirectoryGroup(
                            directory: labels[group.fullPath] ?? group.fullPath,
                            fullPath: group.fullPath,
                            sessions: group.sessions,
                            groupIndex: groupIndex,
                            isFocused: isFocused,
                            focusedTabOffset: isFocused ? manager.focusedTabOffset : nil
                        )

                        if groupIndex < groups.count - 1 {
                            Divider().opacity(0.3).padding(.horizontal, 12).padding(.vertical, 4)
                        }
                    }
                }
                .padding(.leading, 2)
                .padding(.trailing, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            Divider().opacity(0.3).padding(.horizontal, 12)

            // Bottom bar
            HStack(spacing: 12) {
                Button(action: { manager.createSession() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("New Tab")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .onHover { h in
                    if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Spacer()

                Text("\(manager.sessions.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
}

// MARK: - Directory Group

struct DirectoryGroup: View {
    @EnvironmentObject var manager: TerminalManager
    let directory: String
    let fullPath: String
    let sessions: [TerminalSession]
    let groupIndex: Int
    let isFocused: Bool
    let focusedTabOffset: Int?
    private var meta: GroupMeta { manager.meta(for: fullPath) }
    private var label: String { meta.displayName ?? directory }

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
                    .foregroundStyle(.white.opacity(isFocused ? 0.9 : 0.65))
                    .lineLimit(1)

                Spacer()

                if groupIndex < 9 {
                    Text("\u{2318}\(groupIndex + 1)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(isFocused ? 0.55 : 0.3))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(isFocused ? 0.12 : 0.04))
                        )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.08) : Color.clear)
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

enum DragState {
    enum Destination: Equatable {
        case before(UUID)
        case endOfGroup(String)
    }

    static var draggedSessionID: UUID?
    static var lastDestination: Destination?

    static func beginDrag(sessionID: UUID) {
        draggedSessionID = sessionID
        lastDestination = nil
    }

    static func reset() {
        draggedSessionID = nil
        lastDestination = nil
    }
}

struct TabRow: View {
    @EnvironmentObject var manager: TerminalManager
    @ObservedObject var session: TerminalSession
    let directory: String
    var isTabFocused: Bool = false
    var isLast: Bool = false
    @State private var hovering = false
    @State private var isDropTarget = false
    @State private var dropAtEnd = false

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
                Circle()
                    .fill(session.isRunning ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)

                Text(session.title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.75))
                    .lineLimit(1)

                Spacer()

                if hovering || isSelected {
                    Button(action: { manager.closeSession(session) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(Color.white.opacity(hovering ? 0.1 : 0))
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
                        isSelected ? Color.white.opacity(0.12) :
                        (hovering || isTabFocused) ? Color.white.opacity(0.06) :
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
        .onDrag {
            DragState.beginDrag(sessionID: session.id)
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

        let destination: DragState.Destination = atEnd
            ? .endOfGroup(directory)
            : .before(targetSession.id)

        guard destination != DragState.lastDestination else {
            return DropProposal(operation: .move)
        }

        DragState.lastDestination = destination

        if atEnd {
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                manager.moveSessionToEndOfGroup(draggedID, in: directory)
            }
        } else {
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                manager.moveSession(draggedID, before: targetSession.id, in: directory)
            }
        }

        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        dropAtEnd = false
        DragState.lastDestination = nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        DragState.draggedSessionID != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        dropAtEnd = false
        DragState.reset()
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
        DragState.lastDestination = nil
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
        defer { DragState.reset() }

        _ = withAnimation(.easeInOut(duration: 0.2)) {
            manager.moveSessionToEndOfGroup(draggedID, in: directory)
        }
        return true
    }
}

struct GroupIcon: View {
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
                    .foregroundStyle(.white.opacity(opacity))
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct TerminalSurface: View {
    @EnvironmentObject var manager: TerminalManager
    let sessionID: UUID?

    var body: some View {
        TerminalView(sessionID: sessionID)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
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

                    // Drive the hidden native minimize button first.
                    // With our custom title bar setup, direct minimize calls alone are
                    // not reliable, so keep this weird fallback chain intact.
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
                performWindowAction(performNativeFullscreen)
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

    private func performNativeFullscreen(_ window: NSWindow) {
        window.toggleFullScreen(nil)
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
