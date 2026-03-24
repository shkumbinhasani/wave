import Foundation
import CoreServices

/// Watches `/tmp/tgip-attention/` for signal files created by Claude Code's
/// Notification hook. Each file contains the raw hook JSON; we extract `cwd`
/// to identify which tab needs attention.
final class AttentionMonitor {
    static let directory = "/tmp/tgip-attention"
    static let hookCommand = "mkdir -p /tmp/tgip-attention && cat > \"/tmp/tgip-attention/$$\""

    private let queue = DispatchQueue(label: "com.wave.attention", qos: .utility)
    private var stream: FSEventStreamRef?

    /// Called on the main queue with the working-directory path that needs attention.
    var onAttention: ((String) -> Void)?

    init() {
        try? FileManager.default.createDirectory(
            atPath: Self.directory,
            withIntermediateDirectories: true
        )
        cleanDirectory()
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<AttentionMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.processFiles()
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [Self.directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
            )
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Claude Code Hook Installation

    /// Ensures the Notification hook is present in ~/.claude/settings.json.
    /// Returns `true` if the hook was already installed, `false` if it was just added.
    @discardableResult
    static func ensureClaudeCodeHookInstalled() -> Bool {
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        // Read existing settings or start fresh
        var settings: [String: Any]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        // Check if our hook is already present
        if let hooks = settings["hooks"] as? [String: Any],
           let notifications = hooks["Notification"] as? [[String: Any]] {
            for entry in notifications {
                if let innerHooks = entry["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String, cmd.contains("tgip-attention") {
                            return true // Already installed
                        }
                    }
                }
            }
        }

        // Add our hook
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var notifications = hooks["Notification"] as? [[String: Any]] ?? []

        notifications.append([
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": hookCommand,
                "timeout": 5
            ] as [String: Any]]
        ])

        hooks["Notification"] = notifications
        settings["hooks"] = hooks

        // Ensure ~/.claude/ exists
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Write back with pretty printing
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsURL, options: .atomic)
        }

        return false
    }

    // MARK: - Private

    private func processFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.directory) else { return }

        for file in files {
            let filePath = (Self.directory as NSString).appendingPathComponent(file)
            defer { try? fm.removeItem(atPath: filePath) }

            guard let data = fm.contents(atPath: filePath), !data.isEmpty else { continue }

            // Try JSON first (Claude Code hook stdin format: {"cwd": "...", ...})
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cwd = json["cwd"] as? String, !cwd.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onAttention?(cwd)
                }
                continue
            }

            // Fall back to plain text (manual testing: echo "/path" > /tmp/tgip-attention/test)
            if let content = String(data: data, encoding: .utf8) {
                let path = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.onAttention?(path)
                    }
                }
            }
        }
    }

    private func cleanDirectory() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.directory) else { return }
        for file in files {
            try? fm.removeItem(atPath: (Self.directory as NSString).appendingPathComponent(file))
        }
    }
}
