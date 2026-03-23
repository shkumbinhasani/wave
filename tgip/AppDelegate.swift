import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installWindowChromeObservers()
        reconfigureAllWindows()
        moveToApplicationsIfNeeded()
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "Quit Wave?"
        alert.informativeText = "All terminal sessions will be closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Move to /Applications

    private func moveToApplicationsIfNeeded() {
        let bundle = Bundle.main
        let currentPath = bundle.bundlePath
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "wave"
        let targetPath = "/Applications/\(appName).app"

        // Already in /Applications
        if currentPath == targetPath { return }

        // Already moved before (user declined)
        if UserDefaults.standard.bool(forKey: "declinedMoveToApplications") { return }

        // Don't prompt during development (running from Xcode DerivedData)
        if currentPath.contains("DerivedData") || currentPath.contains("Build/Products") { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "Wave is running from \(shortenPath(currentPath)). Move it to /Applications for the best experience?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performMove(from: currentPath, to: targetPath)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "declinedMoveToApplications")
        default:
            break
        }
    }

    private func installWindowChromeObservers() {
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExposeNotification,
            NSWindow.didResizeNotification
        ]

        for name in notifications {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { notification in
                guard let window = notification.object as? NSWindow else { return }
                self.reconfigure(window: window)
            }
            windowObservers.append(observer)
        }
    }

    private func reconfigureAllWindows() {
        for delay in [0.0, 0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.windows.forEach { self.reconfigure(window: $0) }
            }
        }
    }

    private func reconfigure(window: NSWindow) {
        configureWaveWindowChrome(window)
        DispatchQueue.main.async {
            configureWaveWindowChrome(window)
        }
    }

    private func performMove(from source: String, to target: String) {
        let fm = FileManager.default

        do {
            // Remove existing app at target if present
            if fm.fileExists(atPath: target) {
                try fm.removeItem(atPath: target)
            }
            try fm.moveItem(atPath: source, toPath: target)

            // Relaunch from new location
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = [target]
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't move to Applications"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
