import Foundation
import GhosttyKit
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
        /// Tabs only: shown in its window right now.
        var isSelected = false
    }

    struct AppSample {
        let cpuPercent: Double
        let memoryBytes: UInt64
        /// Busiest threads first, cut off at `threadLimit`.
        let threads: [ProcessActivity.ThreadReading]
        let threadCount: Int
        let memory: ProcessActivity.MemoryBreakdown?
        let uptime: TimeInterval
    }

    /// Facts about the running Wave that don't change between samples but
    /// decide what a number means: a render-heavy report from a Debug build
    /// or a low-power laptop reads differently from a Release build on mains.
    struct Environment {
        let appVersion: String
        let buildNumber: String
        let ghosttyVersion: String
        let ghosttyBuildMode: String
        let debugBuild: Bool
        let macOSVersion: String
        let cpuBrand: String
        let coreCount: Int
        let lowPowerMode: Bool
        let thermalState: String
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
    static let threadLimit = 8

    // MARK: - Lifecycle (panel visibility drives sampling)

    func start() {
        guard timer == nil else { return }
        #if DEBUG
        scheduleReportDump()
        #endif
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

    #if DEBUG
    /// Debug builds write the report to `$WAVE_ACTIVITY_REPORT_FILE` once
    /// two samples are in — CPU rates need two — so the text can be checked
    /// without driving the UI.
    private func scheduleReportDump() {
        guard let path = ProcessInfo.processInfo.environment["WAVE_ACTIVITY_REPORT_FILE"],
              !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sampleInterval * 2.5) { [weak self] in
            guard let self else { return }
            try? self.reportText().write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    #endif

    // MARK: - Sampling

    private struct TabRef {
        let id: UUID
        let title: String
        let directory: String?
        let tmuxName: String?
        let agentName: String?
        /// The tab shown in its window right now. Ghostty renders only these;
        /// a hidden tab's renderer thread should read ~0%.
        let isSelected: Bool
        /// Whether the tab's window is on screen at all (not minimized, not
        /// fully covered, not a stashed inactive profile).
        let windowVisible: Bool
        /// The tab's surface has been created — a restored tab that never
        /// got a surface costs Wave nothing.
        let hasSurface: Bool
    }

    /// Counts that frame the Wave row: how many surfaces exist, how many are
    /// on screen and should be rendering.
    struct SurfaceCensus {
        let windows: Int
        let surfaces: Int
        let visibleSurfaces: Int
        /// Tabs of profiles that aren't live in any window. Their processes
        /// still run; their surfaces don't render.
        let stashedTabs: Int
    }
    private(set) var census = SurfaceCensus(windows: 0, surfaces: 0, visibleSurfaces: 0, stashedTabs: 0)

    /// Tabs across every window and every profile's stored set — inactive
    /// profiles' tmux sessions keep running and burning CPU.
    private func tabSnapshot() -> [TabRef] {
        let runtime = AppRuntime.shared
        var refs: [TabRef] = []
        var seen = Set<UUID>()
        var stashed = 0
        func add(_ session: TerminalSession, selected: Bool, windowVisible: Bool) {
            guard seen.insert(session.id).inserted else { return }
            refs.append(TabRef(
                id: session.id,
                title: session.title,
                directory: session.workingDirectory,
                tmuxName: session.tmuxSessionName,
                agentName: session.agentKind?.displayName,
                isSelected: selected,
                windowVisible: windowVisible,
                hasSurface: session.surfaceView?.surface != nil
            ))
        }
        for manager in runtime.windows {
            let window = manager.window
            let visible = (window?.occlusionState.contains(.visible) ?? false)
                && window?.isMiniaturized == false
            for session in manager.sessions {
                add(session, selected: session.id == manager.selectedSessionID, windowVisible: visible)
            }
        }
        for index in runtime.profiles.indices {
            for session in runtime.previewSessions(forProfileAt: index) where !seen.contains(session.id) {
                stashed += 1
                add(session, selected: false, windowVisible: false)
            }
        }
        census = SurfaceCensus(
            windows: runtime.windows.count,
            surfaces: refs.filter(\.hasSurface).count,
            visibleSurfaces: refs.filter { $0.hasSurface && $0.isSelected && $0.windowVisible }.count,
            stashedTabs: stashed
        )
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
                processes: processRows,
                isSelected: ref.isSelected && ref.windowVisible
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
            let threads = ProcessActivity.ownThreads()
                .sorted { $0.cpuPercent > $1.cpuPercent }
            appSample = AppSample(
                cpuPercent: cpuPercent(reading),
                memoryBytes: reading.memoryBytes,
                threads: Array(threads.prefix(Self.threadLimit)),
                threadCount: threads.count,
                memory: ProcessActivity.ownMemory(),
                uptime: ProcessActivity.uptime(of: reading)
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

    /// Facts read once; none of them change while Wave runs.
    static let environment: Environment = {
        let bundle = Bundle.main
        let info = ghostty_info()
        let ghosttyVersion = String(
            decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)),
            as: UTF8.self
        )
        let buildMode: String
        switch info.build_mode {
        case GHOSTTY_BUILD_MODE_DEBUG: buildMode = "Debug"
        case GHOSTTY_BUILD_MODE_RELEASE_SAFE: buildMode = "ReleaseSafe"
        case GHOSTTY_BUILD_MODE_RELEASE_FAST: buildMode = "ReleaseFast"
        case GHOSTTY_BUILD_MODE_RELEASE_SMALL: buildMode = "ReleaseSmall"
        default: buildMode = "unknown"
        }
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        let process = ProcessInfo.processInfo
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return Environment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            ghosttyVersion: ghosttyVersion,
            ghosttyBuildMode: buildMode,
            debugBuild: debugBuild,
            macOSVersion: process.operatingSystemVersionString,
            cpuBrand: ProcessActivity.cpuBrand() ?? "unknown CPU",
            coreCount: process.activeProcessorCount,
            lowPowerMode: process.isLowPowerModeEnabled,
            thermalState: thermal
        )
    }()

    /// Plain-text snapshot of the current sample, made to be pasted into a
    /// chat or bug report and read without the UI. Every line a reader would
    /// otherwise have to ask about — build, machine, how many surfaces are
    /// rendering, where Wave's memory goes, which thread id to look for in
    /// `sample` — is in the header so the paste stands on its own.
    func reportText() -> String {
        let env = Self.environment
        var lines: [String] = []
        lines.append("Wave activity report — \(Date().formatted(date: .abbreviated, time: .standard))")

        var build = "Wave \(env.appVersion) (\(env.buildNumber))"
        if env.debugBuild { build += " DEBUG BUILD" }
        build += ", Ghostty \(env.ghosttyVersion) \(env.ghosttyBuildMode)"
        lines.append(build)

        var machine = "\(env.cpuBrand), \(env.coreCount) cores, macOS \(env.macOSVersion)"
        if env.lowPowerMode { machine += ", Low Power Mode on" }
        if env.thermalState != "nominal" { machine += ", thermal state \(env.thermalState)" }
        lines.append(machine)

        if let app {
            lines.append("Wave up \(Self.formatDuration(app.uptime)). "
                + "\(census.windows) window\(census.windows == 1 ? "" : "s"), "
                + "\(census.surfaces) terminal surface\(census.surfaces == 1 ? "" : "s"), "
                + "\(census.visibleSurfaces) on screen"
                + (census.stashedTabs > 0 ? ", \(census.stashedTabs) tab\(census.stashedTabs == 1 ? "" : "s") in inactive profiles" : "")
                + ".")
        }
        lines.append("CPU is % of one core over a \(Int(Self.sampleInterval))s interval; thread CPU is the kernel's recent-usage estimate. Thread ids match the Thread_<id> labels in `sample` and Instruments.")
        lines.append("")

        func metric(_ name: String, _ cpu: Double, _ memory: UInt64?, indent: Int = 0) -> String {
            let pad = String(repeating: "  ", count: indent)
            let mem = memory.map { Self.formatBytes($0) } ?? "-"
            return pad + name.padding(toLength: max(52 - pad.count, name.count), withPad: " ", startingAt: 0)
                + String(format: "%7.1f%%  ", cpu) + mem
        }

        if let app {
            lines.append(metric("Wave (terminal, rendering, UI)", app.cpuPercent, app.memoryBytes))
            let shown = app.threads.filter { $0.cpuPercent > 0 }
            for thread in shown {
                lines.append(metric(Self.threadLabel(thread), thread.cpuPercent, nil, indent: 1))
            }
            let idle = app.threadCount - shown.count
            if idle > 0 {
                lines.append("  \(idle) more thread\(idle == 1 ? "" : "s") idle")
            }
            if let memory = app.memory {
                var parts = ["anonymous \(Self.formatBytes(memory.anonymous))"]
                if memory.compressed > 0 { parts.append("compressed \(Self.formatBytes(memory.compressed))") }
                if memory.graphics > 0 { parts.append("graphics \(Self.formatBytes(memory.graphics))") }
                parts.append("peak \(Self.formatBytes(memory.peakFootprint))")
                lines.append("  memory: " + parts.joined(separator: ", "))
            }
            lines.append("")
        }

        func append(_ groups: [Group], header: String) {
            guard !groups.isEmpty else { return }
            lines.append(header)
            for group in groups {
                var title = group.subtitle.map { "\(group.title) (\($0))" } ?? group.title
                if group.isSelected { title = "▶ " + title }
                lines.append(metric(title, group.cpuPercent, group.memoryBytes))
                for process in group.processes {
                    lines.append(metric("\(process.name) [pid \(process.id)]", process.cpuPercent, process.memoryBytes, indent: 1))
                }
            }
            lines.append("")
        }
        append(tabs, header: "Tabs (▶ = shown on screen; only these render):")
        append(other, header: "Other:")

        lines.append("Reading this:")
        lines.append("- Each terminal surface owns a `renderer`, `io`, `io-reader` and `cf_release` thread; the row order above is by CPU, so a busy `renderer` is the on-screen tab redrawing. A `renderer` above a few % while all tabs are idle means something keeps invalidating that surface.")
        lines.append("- `Main thread` is AppKit and SwiftUI: sidebar, tab bar, this panel. Threads named com.wave.* are Wave's own background queues.")
        lines.append("- Wave's memory is mostly scrollback and glyph atlases; `graphics` is Metal textures. Compare `peak` with the current footprint to tell a leak from a spike.")
        lines.append("- To see what a hot thread is doing: `sample wave 3 -file /tmp/wave.sample.txt`, then look for Thread_<id> in the call graph.")

        return lines.joined(separator: "\n")
    }

    /// "renderer [tid 1624989]", "Main thread", or "Thread [tid N]" when the
    /// thread neither set a name nor was on a dispatch queue.
    static func threadLabel(_ thread: ProcessActivity.ThreadReading) -> String {
        let base: String
        switch thread.name {
        case "com.apple.main-thread": base = "Main thread"
        case "": base = "Thread"
        default: base = thread.name
        }
        return "\(base) [tid \(thread.id)]"
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory))
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
