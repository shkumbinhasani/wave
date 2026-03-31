import SwiftUI

@main
struct tgipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = TerminalManager()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
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

            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager.sidebarPinned.toggle()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                ForEach(0..<9, id: \.self) { i in
                    Button("Focus Group \(i + 1)") {
                        manager.focusGroup(at: i)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }
}
