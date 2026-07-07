import Foundation
import CoreServices

/// Watches `AgentHookInstaller.dropDirectory` for signal files written by the
/// agent hooks. Each file carries `WAVE_AGENT`, `WAVE_ACTION`, `WAVE_SID` (the
/// tab UUID) and `WAVE_PWD`, followed by the raw hook JSON. Parses them and
/// emits a typed event so the UI can route it to the right tab.
final class AgentMonitor {
    private let directory = AgentHookInstaller.dropDirectory
    private let queue = DispatchQueue(label: "com.wave.agentmonitor", qos: .utility)
    private var stream: FSEventStreamRef?

    struct Event {
        let sessionID: UUID?
        let cwd: String?
        let agent: AgentKind?
        let action: AgentAction
    }

    /// Called on the main queue for each signal file.
    var onEvent: ((Event) -> Void)?

    init() {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
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
            Unmanaged<AgentMonitor>.fromOpaque(info).takeUnretainedValue().processFiles()
        }

        stream = FSEventStreamCreate(
            nil, callback, &context,
            [directory] as CFArray,
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

    // MARK: - Private

    private func processFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return }

        for file in files {
            let filePath = (directory as NSString).appendingPathComponent(file)
            defer { try? fm.removeItem(atPath: filePath) }

            guard let data = fm.contents(atPath: filePath), !data.isEmpty,
                  let content = String(data: data, encoding: .utf8) else { continue }

            guard let event = parse(content) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    private func parse(_ content: String) -> Event? {
        let lines = content.components(separatedBy: "\n")

        func value(_ key: String) -> String? {
            let prefix = key + "="
            guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let raw = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return raw.isEmpty ? nil : raw
        }

        guard let actionRaw = value("WAVE_ACTION"),
              let action = AgentAction(rawValue: actionRaw) else { return nil }

        let agent = value("WAVE_AGENT").flatMap { AgentKind(rawValue: $0) }
        let sessionID = value("WAVE_SID").flatMap { UUID(uuidString: $0) }

        // Working directory: the WAVE_PWD trailer first, else `cwd` from the
        // trailing hook JSON (used to match non-Wave / SSH sessions by path).
        var cwd = value("WAVE_PWD")
        if cwd == nil {
            let jsonText = lines
                .filter { !$0.hasPrefix("WAVE_") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let jsonData = jsonText.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                cwd = json["cwd"] as? String
            }
        }

        return Event(sessionID: sessionID, cwd: cwd, agent: agent, action: action)
    }

    private func cleanDirectory() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for file in files {
            try? fm.removeItem(atPath: (directory as NSString).appendingPathComponent(file))
        }
    }
}
