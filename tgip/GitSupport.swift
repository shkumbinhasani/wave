import Foundation
import CoreServices

enum GitPathLookup: Equatable {
    case notRepo
    case repo(GitRepositoryInfo)
}

struct GitRepositoryInfo: Equatable, Hashable {
    let repoRoot: String
    let gitDirectory: String
}

enum GitFileStateCode: Character, Hashable {
    case added = "A"
    case copied = "C"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case typeChanged = "T"
    case updatedButUnmerged = "U"

    init?(_ value: Character?) {
        guard let value, value != "." else { return nil }
        self.init(rawValue: value)
    }

    var title: String {
        switch self {
        case .added: return "Added"
        case .copied: return "Copied"
        case .deleted: return "Deleted"
        case .modified: return "Modified"
        case .renamed: return "Renamed"
        case .typeChanged: return "Type Changed"
        case .updatedButUnmerged: return "Conflicted"
        }
    }
}

struct GitChangedFile: Identifiable, Hashable {
    let path: String
    let stagedState: GitFileStateCode?
    let unstagedState: GitFileStateCode?
    let isUntracked: Bool
    let isConflicted: Bool

    var id: String { path }
    var displayName: String { (path as NSString).lastPathComponent }

    var parentPath: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." || parent.isEmpty ? nil : parent
    }

    var hasStagedChanges: Bool { stagedState != nil }
    var hasUnstagedChanges: Bool { unstagedState != nil }

    var statusSummary: String {
        if isConflicted { return "Conflict" }
        if isUntracked { return "Untracked" }

        var parts: [String] = []
        if let stagedState {
            parts.append("Index \(stagedState.title)")
        }
        if let unstagedState {
            parts.append("Worktree \(unstagedState.title)")
        }
        return parts.isEmpty ? "Changed" : parts.joined(separator: " · ")
    }
}

struct GitRepoStatus: Equatable {
    let repoRoot: String
    let gitDirectory: String
    let changedFiles: [GitChangedFile]
    let refreshedAt: Date

    var hasChanges: Bool { !changedFiles.isEmpty }
    var dirtyCount: Int { changedFiles.count }
}

struct GitCommandResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

enum GitCLI {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    static func normalizePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func run(
        arguments: [String],
        currentDirectory: String? = nil,
        processHandler: ((Process) -> Void)? = nil
    ) throws -> GitCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_PAGER"] = "cat"
        environment["TERM"] = "dumb"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        try process.run()
        processHandler?(process)
        process.waitUntilExit()
        readGroup.wait()

        return GitCommandResult(exitCode: process.terminationStatus, stdout: stdoutData, stderr: stderrData)
    }

    static func resolveRepository(at path: String) -> GitRepositoryInfo? {
        let normalizedPath = normalizePath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        guard let result = try? run(arguments: [
            "-C", normalizedPath,
            "rev-parse",
            "--show-toplevel",
            "--absolute-git-dir"
        ]), result.exitCode == 0 else {
            return nil
        }

        let lines = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        guard lines.count >= 2 else { return nil }

        return GitRepositoryInfo(
            repoRoot: normalizePath(lines[0]),
            gitDirectory: normalizePath(lines[1])
        )
    }

    static func status(for repository: GitRepositoryInfo) -> GitRepoStatus {
        let changedFiles: [GitChangedFile]
        if let result = try? run(arguments: [
            "-C", repository.repoRoot,
            "--no-optional-locks",
            "status",
            "--porcelain=v2",
            "-z",
            "--ignore-submodules=dirty",
            "--no-renames",
            "--untracked-files=all"
        ]), result.exitCode == 0 {
            changedFiles = parseStatusRecords(result.stdout)
        } else {
            changedFiles = []
        }

        return GitRepoStatus(
            repoRoot: repository.repoRoot,
            gitDirectory: repository.gitDirectory,
            changedFiles: changedFiles,
            refreshedAt: Date()
        )
    }

    private static func parseStatusRecords(_ data: Data) -> [GitChangedFile] {
        guard !data.isEmpty else { return [] }

        var changedFiles: [GitChangedFile] = []
        changedFiles.reserveCapacity(32)

        for recordData in data.split(separator: 0) {
            let record = String(decoding: recordData, as: UTF8.self)

            if record.hasPrefix("? ") {
                changedFiles.append(GitChangedFile(
                    path: String(record.dropFirst(2)),
                    stagedState: nil,
                    unstagedState: nil,
                    isUntracked: true,
                    isConflicted: false
                ))
                continue
            }

            if record.hasPrefix("1 ") {
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                guard fields.count == 9 else { continue }
                let xy = Array(String(fields[1]))
                changedFiles.append(GitChangedFile(
                    path: String(fields[8]),
                    stagedState: GitFileStateCode(xy.first),
                    unstagedState: GitFileStateCode(xy.dropFirst().first),
                    isUntracked: false,
                    isConflicted: false
                ))
                continue
            }

            if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                guard fields.count == 11 else { continue }
                let xy = Array(String(fields[1]))
                changedFiles.append(GitChangedFile(
                    path: String(fields[10]),
                    stagedState: GitFileStateCode(xy.first),
                    unstagedState: GitFileStateCode(xy.dropFirst().first),
                    isUntracked: false,
                    isConflicted: true
                ))
            }
        }

        return changedFiles.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }
}

final class GitRepositoryService {
    private let queue = DispatchQueue(label: "com.wave.git.repository-service", qos: .userInitiated)
    private var trackedPaths: Set<String> = []
    private var lookupsByPath: [String: GitPathLookup] = [:]
    private var statusesByRoot: [String: GitRepoStatus] = [:]
    private var resolvingPaths: Set<String> = []
    private var watchers: [String: GitEventStreamMonitor] = [:]
    private var scheduledRefreshes: [String: DispatchWorkItem] = [:]
    private var refreshingRoots: Set<String> = []
    private var pendingRefreshRoots: Set<String> = []

    var onSnapshot: (([String: GitPathLookup], [String: GitRepoStatus]) -> Void)?

    func track(paths: [String]) {
        let normalized = Set(paths.map(GitCLI.normalizePath).filter { !$0.isEmpty })

        queue.async {
            self.trackedPaths = normalized
            self.lookupsByPath = self.lookupsByPath.filter { normalized.contains($0.key) }
            self.resolvingPaths = self.resolvingPaths.intersection(normalized)

            for path in normalized {
                self.resolveRepositoryIfNeeded(for: path)
            }

            self.reconcileWatchers()
            self.publishSnapshot()
        }
    }

    func refresh(repoRoot: String) {
        let normalizedRoot = GitCLI.normalizePath(repoRoot)
        queue.async {
            self.scheduleRefresh(for: normalizedRoot, delay: 0)
        }
    }

    private func resolveRepositoryIfNeeded(for path: String) {
        guard !path.isEmpty else { return }
        guard lookupsByPath[path] == nil else { return }
        guard !resolvingPaths.contains(path) else { return }

        resolvingPaths.insert(path)
        let repository = GitCLI.resolveRepository(at: path)
        resolvingPaths.remove(path)

        if let repository {
            lookupsByPath[path] = .repo(repository)
            scheduleRefresh(for: repository.repoRoot, delay: 0.05)
        } else {
            lookupsByPath[path] = .notRepo
        }

        reconcileWatchers()
        publishSnapshot()
    }

    private func reconcileWatchers() {
        let activeRepositories = Set(
            trackedPaths.compactMap { path -> GitRepositoryInfo? in
                guard case let .repo(repository)? = lookupsByPath[path] else { return nil }
                return repository
            }
        )
        let activeRoots = Set(activeRepositories.map { $0.repoRoot })

        for root in Array(watchers.keys) where !activeRoots.contains(root) {
            watchers[root]?.stop()
            watchers[root] = nil
            scheduledRefreshes[root]?.cancel()
            scheduledRefreshes[root] = nil
        }

        for repository in activeRepositories where watchers[repository.repoRoot] == nil {
            let monitor = GitEventStreamMonitor(paths: watchPaths(for: repository)) { [weak self] in
                self?.queue.async {
                    self?.scheduleRefresh(for: repository.repoRoot, delay: 0.2)
                }
            }
            monitor.start()
            watchers[repository.repoRoot] = monitor
        }
    }

    private func watchPaths(for repository: GitRepositoryInfo) -> [String] {
        if repository.gitDirectory == repository.repoRoot || repository.gitDirectory.hasPrefix(repository.repoRoot + "/") {
            return [repository.repoRoot]
        }
        return [repository.repoRoot, repository.gitDirectory]
    }

    private func scheduleRefresh(for repoRoot: String, delay: TimeInterval) {
        guard repositoryInfo(forRoot: repoRoot) != nil || statusesByRoot[repoRoot] != nil else { return }

        scheduledRefreshes[repoRoot]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshStatus(for: repoRoot)
        }
        scheduledRefreshes[repoRoot] = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func refreshStatus(for repoRoot: String) {
        scheduledRefreshes[repoRoot] = nil

        guard let repository = repositoryInfo(forRoot: repoRoot) else { return }
        if refreshingRoots.contains(repoRoot) {
            pendingRefreshRoots.insert(repoRoot)
            return
        }

        refreshingRoots.insert(repoRoot)
        let status = GitCLI.status(for: repository)
        statusesByRoot[repoRoot] = status
        refreshingRoots.remove(repoRoot)
        publishSnapshot()

        if pendingRefreshRoots.remove(repoRoot) != nil {
            scheduleRefresh(for: repoRoot, delay: 0.05)
        }
    }

    private func repositoryInfo(forRoot repoRoot: String) -> GitRepositoryInfo? {
        for lookup in lookupsByPath.values {
            if case let .repo(repository) = lookup, repository.repoRoot == repoRoot {
                return repository
            }
        }

        if let status = statusesByRoot[repoRoot] {
            return GitRepositoryInfo(repoRoot: status.repoRoot, gitDirectory: status.gitDirectory)
        }

        return nil
    }

    private func publishSnapshot() {
        let lookups = lookupsByPath
        let statuses = statusesByRoot
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(lookups, statuses)
        }
    }
}

private final class GitEventStreamMonitor {
    private let callback: () -> Void
    private let paths: [String]
    private let queue = DispatchQueue(label: "com.wave.git.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [String], callback: @escaping () -> Void) {
        self.paths = Array(Set(paths))
        self.callback = callback
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<GitEventStreamMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if !paths.isEmpty {
                monitor.callback()
            }
        }

        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagWatchRoot
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
}
