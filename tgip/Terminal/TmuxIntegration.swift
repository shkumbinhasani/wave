import Foundation
import Darwin

/// Local tmux plumbing for resumable tabs.
///
/// A resumable tab's shell runs inside a tmux session named `wave-<N>` on this
/// machine. Ghostty still renders everything — tmux is only the persistence
/// layer, which is what lets the session outlive the app (quit, crash, update)
/// and be attached from Wave for iPad over SSH.
///
/// The `wave-` namespace is shared with the mobile app: both sides allocate
/// the next free integer and list with the same prefix, so sessions created on
/// either device remain visible to the other.
enum TmuxIntegration {
    enum SessionMatch {
        case owned
        case missing
        case foreign
        case unavailable
    }

    enum CreationResult {
        case ready(name: String, command: String)
        case cleanupRequired(name: String)
        case failed
    }

    static let sessionPrefix = "wave-"
    /// Matches the history-limit the mobile app installs.
    static let historyLimit = 10_000
    private static let commandTimeout: TimeInterval = 3
    private static let allocationLock = NSLock()
    private static var reservedNames = Set<String>()
    private static let workQueue = DispatchQueue(label: "com.wave.tmux", qos: .utility)

    /// Resolved tmux binary. macOS ships none, so look in the usual Homebrew /
    /// MacPorts locations. nil ⇒ tmux is not installed.
    static let binaryPath: String? = {
        var candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/tmux" }
        candidates.append(contentsOf: pathCandidates)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Captured before any surface temporarily injects its tab environment.
    /// Every management command uses this clean environment so starting the
    /// default tmux server cannot leak a Wave tab ID into unrelated sessions.
    private static let processEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "WAVE_SESSION_ID")
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        environment.removeValue(forKey: "GHOSTTY_RESOURCES_DIR")
        environment.removeValue(forKey: "GHOSTTY_BIN_DIR")
        environment.removeValue(forKey: "TERMINFO")
        environment.removeValue(forKey: "TERMINFO_DIRS")
        if let path = environment["PATH"] {
            environment["PATH"] = path.split(separator: ":")
                .map(String.init)
                .filter { $0 != AgentHookInstaller.shimDirectory }
                .joined(separator: ":")
        }
        return environment
    }()
    private static let ghosttySessionEnvironment: [String: String] = {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "TERMINFO", "TERMINFO_DIRS"]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            environment[key].map { (key, $0) }
        })
    }()

    static var isAvailable: Bool { binaryPath != nil }

    // MARK: - Queries

    /// Names of all live `wave-*` sessions on the local server.
    static func liveSessionNames() -> [String] {
        guard let out = run(["list-sessions", "-F", "#{session_name}"]) else { return [] }
        return out.split(separator: "\n").map(String.init).filter { $0.hasPrefix(sessionPrefix) }
    }

    /// Confirm that a manifest record still points to the tmux session Wave
    /// created. The environment fallback recognizes sessions from early builds
    /// before the explicit ownership option was added.
    static func sessionMatch(_ name: String, tabID: UUID) -> SessionMatch {
        guard name.hasPrefix(sessionPrefix) else { return .foreign }
        guard let existence = runResult(["has-session", "-t", "=\(name)"], captureOutput: false)
        else { return .unavailable }
        guard existence.status == 0 else {
            return existence.status == 1 ? .missing : .unavailable
        }

        guard let option = runResult([
            "show-options", "-qv", "-t", "=\(name):", "@wave-tab-id",
        ]) else { return .unavailable }
        let optionOwner = option.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !optionOwner.isEmpty {
            return optionOwner == tabID.uuidString ? .owned : .foreign
        }

        guard let environment = runResult([
            "show-environment", "-t", "=\(name)", "WAVE_SESSION_ID",
        ]) else { return .unavailable }
        guard environment.status == 0 else {
            return environment.status == 1 ? .foreign : .unavailable
        }
        let owner = environment.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "WAVE_SESSION_ID=", with: "")
        guard owner == tabID.uuidString else { return .foreign }
        guard runStatus([
            "set-option", "-t", "=\(name):", "@wave-tab-id", tabID.uuidString,
        ]) == 0 else { return .unavailable }
        return .owned
    }

    /// Next free `wave-<N>` across every live session — the same allocation
    /// rule the mobile app uses, so both devices share one namespace.
    static func allocateSessionName(avoiding reserved: Set<String> = []) -> String {
        let liveNames = Set(liveSessionNames())
        allocationLock.lock()
        defer { allocationLock.unlock() }
        let taken = liveNames.union(reserved).union(reservedNames)
        var n = 1
        while taken.contains("\(sessionPrefix)\(n)") { n += 1 }
        let name = "\(sessionPrefix)\(n)"
        reservedNames.insert(name)
        return name
    }

    static func releaseSessionName(_ name: String) {
        allocationLock.lock()
        reservedNames.remove(name)
        allocationLock.unlock()
    }

    /// One batched read of pane identity for all `wave-*` sessions:
    /// session name → (current path, current command). Used to keep cwd
    /// grouping and titles honest — OSC 7 from the shell is consumed by the
    /// tmux server and never reaches Ghostty.
    static func paneIdentities() -> [String: (path: String, command: String)] {
        guard let out = run([
            "list-panes", "-a", "-F",
            "#{session_name}\t#{window_active}\t#{pane_active}\t#{pane_current_path}\t#{pane_current_command}",
        ]) else { return [:] }
        var result: [String: (path: String, command: String)] = [:]
        var fallback: [String: (path: String, command: String)] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0].hasPrefix(sessionPrefix) else { continue }
            let name = String(parts[0])
            let identity = (path: String(parts[3]), command: String(parts[4]))
            if fallback[name] == nil { fallback[name] = identity }
            if parts[1] == "1", parts[2] == "1" {
                result[name] = identity
            }
        }
        for (name, identity) in fallback where result[name] == nil { result[name] = identity }
        return result
    }

    // MARK: - Lifecycle

    static func killSession(
        _ name: String,
        tabID: UUID,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard name.hasPrefix(sessionPrefix) else { completion?(true); return }
        workQueue.async {
            let initial = sessionMatch(name, tabID: tabID)
            guard initial == .owned else {
                let complete = initial == .missing || initial == .foreign
                if complete { releaseSessionName(name) }
                if let completion {
                    DispatchQueue.main.async { completion(complete) }
                }
                return
            }
            let format = "#{==:#{@wave-tab-id},\(tabID.uuidString)}"
            _ = runStatus([
                "if-shell", "-t", "\(name):", "-F", format,
                "kill-session -t \(name)", "",
            ])
            let final = sessionMatch(name, tabID: tabID)
            let complete = final == .missing || final == .foreign
            if complete {
                releaseSessionName(name)
            }
            if let completion {
                DispatchQueue.main.async { completion(complete) }
            }
        }
    }

    /// Atomically claim a name by creating the detached tmux session before a
    /// tab is exposed in the UI. Cross-process/mobile allocation races simply
    /// retry with the next available name.
    static func createSession(
        tabID: UUID,
        workingDirectory: String?,
        avoiding reserved: Set<String>,
        onSessionCreated: (String) -> Void
    ) -> CreationResult {
        for _ in 0..<5 {
            let name = allocateSessionName(avoiding: reserved)
            let suffix = tabID.uuidString.prefix(8)
            let bootstrapWindow = "wave-bootstrap-\(suffix)"
            let shellWindow = "wave-shell-\(suffix)"
            var args = ["new-session", "-d", "-n", bootstrapWindow]
            args += [
                "-e", "WAVE_SESSION_ID=\(tabID.uuidString)",
                "-e", "PATH=\(sessionPath)",
            ]
            for (key, value) in ghosttySessionEnvironment.sorted(by: { $0.key < $1.key }) {
                args += ["-e", "\(key)=\(value)"]
            }
            args += [
                "-s", name, "/usr/bin/sleep 30",
                ";", "set-option", "-t", "=\(name):",
                "@wave-tab-id", tabID.uuidString,
                ";", "set-option", "-t", "=\(name):",
                "destroy-unattached", "off",
                ";", "set-option", "-t", "=\(name):",
                "history-limit", "\(historyLimit)",
                ";", "new-window", "-d", "-t", "=\(name):", "-n", shellWindow,
            ]
            if let workingDirectory { args += ["-c", workingDirectory] }
            args += [";", "kill-window", "-t", "\(name):\(bootstrapWindow)"]

            if runStatus(args) != 0 {
                switch sessionMatch(name, tabID: tabID) {
                case .owned, .unavailable:
                    onSessionCreated(name)
                    return .cleanupRequired(name: name)
                case .missing, .foreign:
                    releaseSessionName(name)
                    continue
                }
            }
            onSessionCreated(name)
            guard configureOwnedSession(name, tabID: tabID) else {
                return .cleanupRequired(name: name)
            }
            guard let command = launchCommand(sessionName: name, tabID: tabID) else {
                return .cleanupRequired(name: name)
            }
            return .ready(name: name, command: command)
        }
        return .failed
    }

    static func prepareRestoreCommand(sessionName: String, tabID: UUID) -> String? {
        guard configureOwnedSession(sessionName, tabID: tabID) else { return nil }
        return launchCommand(sessionName: sessionName, tabID: tabID)
    }

    private static func configureOwnedSession(_ name: String, tabID: UUID) -> Bool {
        guard sessionMatch(name, tabID: tabID) == .owned else { return false }
        guard runStatus([
            "set-environment", "-t", "=\(name)", "WAVE_SESSION_ID", tabID.uuidString,
        ]) == 0 else { return false }
        guard runStatus([
            "set-environment", "-t", "=\(name)", "PATH", sessionPath,
        ]) == 0 else { return false }

        // All options are targeted. Failures are non-fatal for compatibility
        // with older tmux versions, but no user's global options are changed.
        _ = runStatus(["set-option", "-t", "=\(name):", "status", "off"])
        _ = runStatus(["set-option", "-t", "=\(name):", "destroy-unattached", "off"])
        _ = runStatus(["set-option", "-t", "=\(name):", "set-titles", "on"])
        _ = runStatus([
            "set-option", "-t", "=\(name):", "set-titles-string",
            "#{?#{!=:#{pane_title},#{host}},#{pane_title},#{b:pane_current_path}}",
        ])
        _ = runStatus(["set-option", "-t", "=\(name):", "history-limit", "\(historyLimit)"])
        _ = runStatus(["set-option", "-w", "-t", "=\(name):", "window-size", "latest"])
        _ = runStatus(["set-option", "-w", "-t", "=\(name):", "aggressive-resize", "on"])
        _ = runStatus(["set-option", "-w", "-t", "=\(name):", "allow-passthrough", "on"])
        return true
    }

    /// The command a resumable tab's surface runs instead of the bare shell:
    /// a tiny launcher script (a single argv token, immune to Ghostty's
    /// word-splitting) that configures the server and attaches the session.
    ///
    /// The script verifies ownership before attaching, so stale names can
    /// never adopt another tab's session.
    static func launchCommand(sessionName: String, tabID: UUID) -> String? {
        guard let tmux = binaryPath else { return nil }

        let script = """
        #!/bin/sh
        tmux=\(shellQuote(tmux))
        name=\(shellQuote(sessionName))
        tab_id=\(shellQuote(tabID.uuidString))
        unset WAVE_SESSION_ID
        unset TMUX TMUX_PANE

        if ! "$tmux" has-session -t "=$name" 2>/dev/null; then
            exit 72
        fi
        format="#{==:#{@wave-tab-id},$tab_id}"
        exec "$tmux" if-shell -t "$name:" -F "$format" \
            "attach-session -t $name" "run-shell 'exit 73'"
        """

        let dir = scriptsDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/\(sessionName).sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            return nil
        }
        return path
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static var sessionPath: String {
        let basePath = processEnvironment["PATH"] ?? ""
        return basePath.isEmpty
            ? AgentHookInstaller.shimDirectory
            : "\(AgentHookInstaller.shimDirectory):\(basePath)"
    }

    private static var scriptsDirectory: String {
        // Caches, not Application Support: Ghostty passes `command` through
        // the shell unquoted, so the path must be space-free ("Application
        // Support" breaks it). Scripts are regenerated before every attach,
        // so cache eviction is harmless.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.path ?? NSTemporaryDirectory()
        return "\(base)/wave/tmux"
    }

    // MARK: - Process plumbing

    /// Run tmux with `args`; stdout on success (exit 0), nil otherwise.
    private static func run(_ args: [String]) -> String? {
        guard let result = runResult(args), result.status == 0 else { return nil }
        return result.output
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static func runStatus(_ args: [String]) -> Int32? {
        runResult(args, captureOutput: false)?.status
    }

    private static func runResult(
        _ args: [String],
        captureOutput: Bool = true
    ) -> ProcessResult? {
        guard let tmux = binaryPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = args
        process.environment = processEnvironment
        let pipe = captureOutput ? Pipe() : nil
        let collector = OutputCollector()
        if let handle = pipe?.fileHandleForReading {
            handle.readabilityHandler = { readable in
                let chunk = readable.availableData
                if chunk.isEmpty {
                    readable.readabilityHandler = nil
                } else {
                    collector.append(chunk)
                }
            }
        }
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        if finished.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.25)
            }
            pipe?.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        if let handle = pipe?.fileHandleForReading {
            handle.readabilityHandler = nil
            collector.append(handle.readDataToEndOfFile())
        }
        let data = collector.value()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
