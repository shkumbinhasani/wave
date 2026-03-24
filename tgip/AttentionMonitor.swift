import Foundation
import CoreServices

/// Watches `/tmp/tgip-attention/` for signal files created by Claude Code's
/// Notification hook. Each file contains the hook JSON + a WAVE_SID trailer
/// to identify the exact terminal tab.
final class AttentionMonitor {
    static let directory = "/tmp/tgip-attention"
    static let hookCommand = "mkdir -p /tmp/tgip-attention && { cat; echo; echo \"WAVE_SID=$WAVE_SESSION_ID\"; } > \"/tmp/tgip-attention/$$\""

    private let queue = DispatchQueue(label: "com.wave.attention", qos: .utility)
    private var stream: FSEventStreamRef?

    /// Called on the main queue with (sessionID, cwd). sessionID is set when
    /// running inside Wave; cwd is the fallback from Claude Code's hook JSON.
    var onAttention: ((_ sessionID: UUID?, _ cwd: String?) -> Void)?

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

    @discardableResult
    static func ensureClaudeCodeHookInstalled() -> Bool {
        let fm = FileManager.default
        let claudeDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        var settings: [String: Any]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        // Remove any old version of our hook and re-add the current one
        var needsUpdate = true
        if let hooks = settings["hooks"] as? [String: Any],
           let notifications = hooks["Notification"] as? [[String: Any]] {
            for entry in notifications {
                if let innerHooks = entry["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String, cmd.contains("tgip-attention") {
                            if cmd.contains("WAVE_SID") {
                                return true // Already up to date
                            }
                            // Old version without session ID — will be replaced below
                            needsUpdate = true
                        }
                    }
                }
            }
        }

        // Remove old hook entries containing tgip-attention
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        if var notifications = hooks["Notification"] as? [[String: Any]] {
            notifications = notifications.filter { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return true }
                return !innerHooks.contains { ($0["command"] as? String)?.contains("tgip-attention") == true }
            }
            hooks["Notification"] = notifications
        }

        // Add current hook
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

        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsURL, options: .atomic)
        }

        return !needsUpdate
    }

    // MARK: - Private

    private func processFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.directory) else { return }

        for file in files {
            let filePath = (Self.directory as NSString).appendingPathComponent(file)
            defer { try? fm.removeItem(atPath: filePath) }

            guard let data = fm.contents(atPath: filePath), !data.isEmpty,
                  let content = String(data: data, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: "\n")

            // Look for WAVE_SID=<uuid> line
            var sessionID: UUID?
            for line in lines {
                if line.hasPrefix("WAVE_SID=") {
                    let raw = String(line.dropFirst("WAVE_SID=".count)).trimmingCharacters(in: .whitespaces)
                    sessionID = UUID(uuidString: raw)
                    break
                }
            }

            // Extract cwd from JSON (first non-empty line that looks like JSON)
            var cwd: String?
            if let jsonLine = lines.first(where: { $0.hasPrefix("{") }),
               let jsonData = jsonLine.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                cwd = json["cwd"] as? String
            }

            if sessionID != nil || cwd != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.onAttention?(sessionID, cwd)
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
