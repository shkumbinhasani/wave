import SwiftUI

extension FocusedValues {
    /// The focused window's terminal manager — menu commands act on this.
    @Entry var terminalManager: TerminalManager?
}

@main
struct tgipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var updater = UpdaterController()

    var body: some Scene {
        // Value-presenting group: normal windows carry no value (nil); torn-out
        // tabs open with a token used to claim their pending session + position.
        WindowGroup(for: UUID.self) { $tearOutToken in
            WindowRoot(tearOutToken: tearOutToken)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
            }

            TerminalCommands()
        }

        Settings {
            AppSettingsView()
                .environment(AppRuntime.shared)
        }
    }
}

// MARK: - Per-window root

/// Owns one window's TerminalManager, registers it with the AppRuntime, and
/// adopts a torn-out session (or spawns a fresh one) when the window appears.
struct WindowRoot: View {
    let tearOutToken: UUID?

    @Environment(\.openWindow) private var openWindow
    @State private var manager = TerminalManager()
    @State private var didSetup = false

    var body: some View {
        ContentView()
            .environment(manager)
            .environment(manager.theme)
            .focusedSceneValue(\.terminalManager, manager)
            .background(WindowAccessor { window in
                manager.window = window
                if let tearOutToken,
                   let point = AppRuntime.shared.claimTearOutPoint(tearOutToken) {
                    position(window, at: point)
                }
            } onClose: {
                manager.teardownWindow()
            })
            .onAppear {
                // Rebind each time — any live window's action is fine.
                AppRuntime.shared.openWindowAction = { token in
                    openWindow(value: token)
                }

                guard !didSetup else { return }
                didSetup = true
                AppRuntime.shared.register(manager)
                if let tearOutToken,
                   let session = AppRuntime.shared.claimTearOutSession(tearOutToken) {
                    // Torn-out windows inherit the source window's profile.
                    if let profileIndex = AppRuntime.shared.claimTearOutProfile(tearOutToken) {
                        manager.setActiveProfile(profileIndex)
                    }
                    manager.adopt(session)
                } else if manager.sessions.isEmpty {
                    // Reopen resumable tabs that survived the last quit/update
                    // before falling back to a fresh tab.
                    let profileID = manager.activeProfile.id
                    manager.restoreResumableTabs { _ in
                        guard manager.activeProfile.id == profileID else { return }
                        if manager.sessions.isEmpty { manager.createSession() }
                    }
                }
            }
    }

    /// Place a torn-out window so the drop point lands near its top edge,
    /// clamped to the screen it landed on.
    private func position(_ window: NSWindow, at point: NSPoint) {
        var frame = window.frame
        frame.origin = NSPoint(
            x: point.x - frame.width / 2,
            y: point.y - frame.height + 24
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.maxX - frame.width, visible.minX))
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.maxY - frame.height, visible.minY))
        }
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Hands the hosting NSWindow to SwiftUI code and reports when it closes.
private struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    var onClose: () -> Void

    final class Coordinator {
        weak var window: NSWindow?
        var closeObserver: NSObjectProtocol?

        deinit {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        let coordinator = context.coordinator
        view.onAttach = { window in
            attach(window, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        if let window = nsView.window {
            attach(window, coordinator: context.coordinator)
        }
    }

    private func attach(_ window: NSWindow, coordinator: Coordinator) {
        guard coordinator.window !== window else { return }
        if let old = coordinator.closeObserver {
            NotificationCenter.default.removeObserver(old)
        }
        coordinator.window = window
        coordinator.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            onClose()
        }
        onWindow(window)
    }
}

// MARK: - Menu commands

/// Menu commands routed to whichever window is focused. Profile switching is
/// global (it drives the main window) so it stays enabled from any window.
struct TerminalCommands: Commands {
    @FocusedValue(\.terminalManager) private var manager

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { manager?.createSession() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(manager == nil)

            Button("Close Tab") {
                if let manager, let s = manager.selectedSession { manager.closeSession(s) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(manager?.selectedSession == nil)
        }

        // Find — proper macOS menu commands (replaces hidden in-view buttons).
        CommandGroup(after: .textEditing) {
            Button("Find") {
                if let manager, manager.presentedGitDiff == nil { manager.showSearch() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(manager == nil)

            Button("Find Next") {
                if let manager, manager.presentedGitDiff == nil { manager.navigateSearch(.next) }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(manager?.searchState == nil)

            Button("Find Previous") {
                if let manager, manager.presentedGitDiff == nil { manager.navigateSearch(.previous) }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(manager?.searchState == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    manager?.sidebarPinned.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(manager == nil)

            Button("Toggle Git Diff") {
                manager?.toggleGitDiff()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(manager?.gitIntegrationEnabled != true)
        }

        CommandGroup(after: .toolbar) {
            ForEach(0..<9, id: \.self) { i in
                Button("Focus Group \(i + 1)") {
                    manager?.focusGroup(at: i)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .disabled(manager == nil)
            }

            Divider()

            Button("Next Profile") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    manager?.switchToNextProfile()
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.control])
            .disabled(manager == nil)

            Button("Previous Profile") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    manager?.switchToPreviousProfile()
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.control])
            .disabled(manager == nil)
        }
    }
}

// MARK: - Settings

private struct AppSettingsView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        @Bindable var runtime = runtime
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Git integration", isOn: $runtime.gitIntegrationEnabled)

            Text("Shows repository dirty badges and enables the uncommitted diff inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("EXPERIMENTAL")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Resumable tabs (tmux)", isOn: $runtime.resumableTabsEnabled)

            Text("New local tabs run inside tmux sessions that survive quitting or updating Wave, and can be resumed here or from Wave for iPad over SSH. Requires tmux (brew install tmux). Scrollback in these tabs uses tmux copy-mode. Closing a tab still kills its session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
