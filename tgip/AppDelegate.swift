import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        moveToApplicationsIfNeeded()
        AgentHookInstaller.installAll()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Show the banner even when Wave is the active app — the caller already
    // decided the user isn't looking at the tab the notification is about.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking an agent notification focuses the tab it came from.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let raw = response.notification.request.content.userInfo["sessionID"] as? String,
           let id = UUID(uuidString: raw) {
            DispatchQueue.main.async { AppRuntime.shared.focusSession(id: id) }
        }
        completionHandler()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppRuntime.shared.shouldConfirmAppQuit() else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Wave?"
        alert.informativeText = "One or more terminal tabs still have running processes. Quitting will close them."
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
