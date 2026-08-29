import Foundation
import Observation

/// Samples CPU and memory for Wave itself and for every process running
/// inside its tabs, so a high Wave number in Activity Monitor can be split
/// into "the terminal" vs "what the tabs run". Activity Monitor can't draw
/// that line: its rows don't say which tab owns a shell, and a resumable
/// tab's processes descend from the tmux server, not from Wave.
///
/// Attribution:
/// - Resumable tabs: their pane pids come from one batched tmux query; the
///   subtree under each pane is the tab's workload. The tab's attach client
///   (a direct Wave child) is matched by the session name in its argv and
///   merged in.
/// - Plain tabs: the shell is a direct Wave child, matched to a tab by
///   working directory.
/// - Anything left over (SSH helpers, unmatched shells, the tmux server)
///   shows under "Other" rather than being guessed at.
@Observable
final class ActivityMonitor {

    struct ProcessRow: Identifiable {
        let id: pid_t
        let name: String
        let cpuPercent: Double
        let memoryBytes: UInt64
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let cpuPercent: Double
        let memoryBytes: UInt64
        let processes: [ProcessRow]
    }

    struct AppSample {
        let cpuPercent: Double
        let memoryBytes: UInt64
        let threads: [ProcessActivity.ThreadReading]
    }

    private(set) var app: AppSample?
    private(set) var tabs: [Group] = []
    private(set) var other: [Group] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var samplingInFlight = false
    @ObservationIgnored private let queue = DispatchQueue(label: "com.wave.activity", qos: .utility)
    /// Previous cumulative CPU per pid — touched only on `queue`.
    @ObservationIgnored private var history: [pid_t: (startedAt: UInt64, cpuTimeNs: UInt64)] = [:]
    @ObservationIgnored private var lastSampleAt: UInt64 = 0

    static let sampleInterval: TimeInterval = 2.0

    // MARK: - Lifecycle (panel visibility drives sampling)

    func start() {
        guard timer == nil else { return }
        sampleNow()
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Sampling

    private struct TabRef {
        let id: UUID
        let title: String
        let directory: String?
        let tmuxName: String?
        let agentName: String?
    }

    /// Tabs across every window and every profile's stored set — inactive
    /// profiles' tmux sessions keep running and burning CPU.
    private func tabSnapshot() -> [TabRef] {
        let runtime = AppRuntime.shared
        var refs: [TabRef] = []
        var seen = Set<UUID>()
        func add(_ session: TerminalSession) {
            guard seen.insert(session.id).inserted else { return }
            refs.append(TabRef(
                id: session.id,
                title: session.title,
                directory: session.workingDirectory,
                tmuxName: session.tmuxSessionName,
                agentName: session.agentKind?.displayName
            ))
        }
        for manager in runtime.windows {
            manager.sessions.forEach(add)
        }
        for index in runtime.profiles.indices {
            runtime.previewSessions(forProfileAt: index).forEach(add)
        }
        return refs
    }

    private func sampleNow() {
        guard !samplingInFlight else { return }
        samplingInFlight = true
        let refs = tabSnapshot()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.collect(refs: refs)
            DispatchQueue.main.async {
                self.samplingInFlight = false
                self.app = result.app
                self.tabs = result.tabs
                self.other = result.other
            }
        }
    }

    private func collect(refs: [TabRef]) -> (app: AppSample?, tabs: [Group], other: [Group]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = lastSampleAt == 0 ? 0 : now &- lastSampleAt
        lastSampleAt = now
        var nextHistory: [pid_t: (startedAt: UInt64, cpuTimeNs: UInt64)] = [:]

        // CPU% of one core over the interval since the previous sample. A pid
        // seen for the first time (or reborn under a reused number) reads 0
        // until the next tick.
        func cpuPercent(_ reading: ProcessActivity.Reading) -> Double {
            defer { nextHistory[reading.pid] = (reading.startedAt, reading.cpuTimeNs) }
            guard elapsedNs > 0,
                  let previous = history[reading.pid],
                  previous.startedAt == reading.startedAt,
                  reading.cpuTimeNs >= previous.cpuTimeNs
            else { return 0 }
            return Double(reading.cpuTimeNs - previous.cpuTimeNs) / Double(elapsedNs) * 100
        }

        let parents = ProcessActivity.parentByPid()
        let children = ProcessActivity.childrenByParent(parents)
        let panePids = TmuxIntegration.isAvailable ? TmuxIntegration.panePids() : [:]
        let wavePid = getpid()

        // Resumable tabs: everything under their panes.
        var pidsByTab: [UUID: Set<pid_t>] = [:]
        var tabByTmuxName: [String: UUID] = [:]
        for ref in refs {
            guard let name = ref.tmuxName else { continue }
            tabByTmuxName[name] = ref.id
            for pane in panePids[name] ?? [] {
                pidsByTab[ref.id, default: []]
                    .formUnion(ProcessActivity.descendants(of: pane, children: children))
            }
        }

        // Plain tabs claim a Wave child by working directory, one child per
        // tab. Two tabs in the same directory pair off arbitrarily — the
        // totals stay right even if two identical rows swap.
        var plainTabsByDirectory: [String: [UUID]] = [:]
        for ref in refs where ref.tmuxName == nil {
            guard let directory = ref.directory else { continue }
            plainTabsByDirectory[normalize(directory), default: []].append(ref.id)
        }

        // Longest-first so "wave-10" can't be claimed by its "wave-1" prefix.
        let tmuxNeedles = tabByTmuxName.keys.sorted { $0.count > $1.count }

        var unattributed: [[pid_t]] = []
        for child in (children[wavePid] ?? []).sorted() {
            let tree = ProcessActivity.descendants(of: child, children: children)

            // A resumable tab's attach client carries its session name in
            // argv (the launcher script path, and tmux's -t argument).
            let argvMatch = tree.prefix(8).lazy
                .compactMap { ProcessActivity.firstArgumentMatch(in: $0, needles: tmuxNeedles) }
                .first
            if let argvMatch, let tabID = tabByTmuxName[argvMatch] {
                pidsByTab[tabID, default: []].formUnion(tree)
                continue
            }

            if let cwd = ProcessActivity.workingDirectory(of: child),
               !plainTabsByDirectory[normalize(cwd), default: []].isEmpty {
                let tabID = plainTabsByDirectory[normalize(cwd)]!.removeFirst()
                pidsByTab[tabID, default: []].formUnion(tree)
                continue
            }

            // Wave's own short-lived tmux management calls (identity polling,
            // this sampler) — noise, not workload.
            if tree.count == 1,
               ProcessActivity.reading(for: child)?.name == "tmux" {
                continue
            }

            unattributed.append(tree)
        }

        func rows(for pids: some Collection<pid_t>) -> [ProcessRow] {
            pids.compactMap { ProcessActivity.reading(for: $0) }
                .map { ProcessRow(
                    id: $0.pid,
                    name: $0.name,
                    cpuPercent: cpuPercent($0),
                    memoryBytes: $0.memoryBytes
                ) }
                .sorted { $0.cpuPercent > $1.cpuPercent }
        }

        var tabGroups: [Group] = []
        for ref in refs {
            let processRows = rows(for: pidsByTab[ref.id] ?? [])
            guard !processRows.isEmpty else { continue }
            let subtitle = [
                ref.agentName,
                ref.directory.map { ($0 as NSString).lastPathComponent },
            ].compactMap { $0 }.joined(separator: " · ")
            tabGroups.append(Group(
                id: ref.id.uuidString,
                title: ref.title,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                cpuPercent: processRows.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: processRows.reduce(0) { $0 + $1.memoryBytes },
                processes: processRows
            ))
        }
        tabGroups.sort { $0.cpuPercent > $1.cpuPercent }

        var otherGroups: [Group] = []

        // The tmux server does real work relaying tab output; it belongs to
        // no single tab, so it gets its own row.
        if let anyPane = panePids.values.first?.first,
           let serverPid = parents[anyPane],
           let reading = ProcessActivity.reading(for: serverPid) {
            let serverRow = ProcessRow(
                id: reading.pid,
                name: reading.name,
                cpuPercent: cpuPercent(reading),
                memoryBytes: reading.memoryBytes
            )
            otherGroups.append(Group(
                id: "tmux-server-\(reading.startedAt)",
                title: "tmux server",
                subtitle: "relays output for resumable tabs",
                cpuPercent: serverRow.cpuPercent,
                memoryBytes: serverRow.memoryBytes,
                processes: [serverRow]
            ))
        }

        for tree in unattributed {
            let processRows = rows(for: tree)
            guard let root = processRows.first(where: { $0.id == tree.first }) ?? processRows.first
            else { continue }
            otherGroups.append(Group(
                id: "tree-\(tree[0])",
                title: root.name,
                subtitle: ProcessActivity.workingDirectory(of: tree[0])
                    .map { ($0 as NSString).lastPathComponent },
                cpuPercent: processRows.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: processRows.reduce(0) { $0 + $1.memoryBytes },
                processes: processRows
            ))
        }

        var appSample: AppSample?
        if let reading = ProcessActivity.reading(for: wavePid) {
            appSample = AppSample(
                cpuPercent: cpuPercent(reading),
                memoryBytes: reading.memoryBytes,
                threads: ProcessActivity.ownThreads(limit: 6)
            )
        }

        history = nextHistory
        return (appSample, tabGroups, otherGroups)
    }

    /// /tmp, /var, /etc are symlinks into /private — a shell's kernel-reported
    /// cwd uses the real path while OSC 7 reports the symlinked one.
    private func normalize(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    // MARK: - Report

    /// Plain-text snapshot of the current sample, made to be pasted into a
    /// chat or bug report and read without the UI.
    func reportText() -> String {
        var lines: [String] = []
        lines.append("Wave activity report — \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("Wave \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"), \(ProcessInfo.processInfo.activeProcessorCount) cores. CPU is % of one core over a \(Int(Self.sampleInterval))s interval.")
        lines.append("")

        func metric(_ name: String, _ cpu: Double, _ memory: UInt64?, indent: Int = 0) -> String {
            let pad = String(repeating: "  ", count: indent)
            let mem = memory.map { Int64($0).formatted(.byteCount(style: .memory)) } ?? "-"
            return pad + name.padding(toLength: max(44 - pad.count, name.count), withPad: " ", startingAt: 0)
                + String(format: "%7.1f%%  ", cpu) + mem
        }

        if let app {
            lines.append(metric("Wave (terminal, rendering, UI)", app.cpuPercent, app.memoryBytes))
            for thread in app.threads where thread.cpuPercent > 0 {
                lines.append(metric(thread.name, thread.cpuPercent, nil, indent: 1))
            }
            lines.append("")
        }

        func append(_ groups: [Group], header: String) {
            guard !groups.isEmpty else { return }
            lines.append(header)
            for group in groups {
                let title = group.subtitle.map { "\(group.title) (\($0))" } ?? group.title
                lines.append(metric(title, group.cpuPercent, group.memoryBytes))
                for process in group.processes {
                    lines.append(metric("\(process.name) [pid \(process.id)]", process.cpuPercent, process.memoryBytes, indent: 1))
                }
            }
            lines.append("")
        }
        append(tabs, header: "Tabs:")
        append(other, header: "Other:")

        return lines.joined(separator: "\n")
    }
}
