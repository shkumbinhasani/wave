import SwiftUI

@main
struct tgipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager = TerminalManager()
    @State private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .environment(SidebarTheme.shared)
                .onAppear {
                    appDelegate.terminalManager = manager
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
            }

            CommandGroup(after: .newItem) {
                Button("New Tab") { manager.createSession() }
                    .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    if let s = manager.selectedSession { manager.closeSession(s) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(manager.selectedSession == nil)
            }

            // Find — proper macOS menu commands (replaces hidden in-view buttons).
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    if manager.presentedGitDiff == nil { manager.showSearch() }
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    if manager.presentedGitDiff == nil { manager.navigateSearch(.next) }
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(manager.searchState == nil)

                Button("Find Previous") {
                    if manager.presentedGitDiff == nil { manager.navigateSearch(.previous) }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(manager.searchState == nil)
            }

            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager.sidebarPinned.toggle()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Toggle Git Diff") {
                    manager.toggleGitDiff()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!manager.gitIntegrationEnabled)
            }

            CommandGroup(after: .toolbar) {
                ForEach(0..<9, id: \.self) { i in
                    Button("Focus Group \(i + 1)") {
                        manager.focusGroup(at: i)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }

                Divider()

                Button("Next Profile") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        manager.switchToNextProfile()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.control])

                Button("Previous Profile") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        manager.switchToPreviousProfile()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.control])
            }
        }

        Settings {
            AppSettingsView()
                .environment(manager)
        }
    }
}

private struct AppSettingsView: View {
    @Environment(TerminalManager.self) private var manager

    var body: some View {
        @Bindable var manager = manager
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Git integration", isOn: $manager.gitIntegrationEnabled)

            Text("Shows repository dirty badges and enables the uncommitted diff inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
