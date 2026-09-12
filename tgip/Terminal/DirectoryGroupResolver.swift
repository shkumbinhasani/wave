import Foundation

/// One resolver per sidebar grouping pass. Normalizes each pin and distinct
/// working directory once, without retaining stale symlink results across UI
/// updates. Resolving paths touches the filesystem, even with Git disabled.
final class DirectoryGroupResolver {
    private let pins: [(original: String, normalized: String, length: Int)]
    private let normalize: (String) -> String
    private let repositoryRoot: ((String) -> String?)?
    private var anchors: [String: String] = [:]

    init(
        pinned: [String],
        normalize: @escaping (String) -> String = GitCLI.normalizePath,
        repositoryRoot: ((String) -> String?)? = nil
    ) {
        self.normalize = normalize
        self.repositoryRoot = repositoryRoot
        self.pins = pinned.compactMap { pin in
            let path = normalize(pin)
            return path.isEmpty ? nil : (pin, path, path.count)
        }
    }

    func anchor(for cwd: String) -> String {
        if let cached = anchors[cwd] { return cached }
        // Loose directories need no filesystem work when Git is switched off.
        guard !pins.isEmpty || repositoryRoot != nil else { return cwd }
        let path = normalize(cwd)
        guard !path.isEmpty else { return cwd }

        var bestPin: String?
        var bestLength = -1
        for pin in pins where pin.length > bestLength {
            if path == pin.normalized || path.hasPrefix(pin.normalized + "/") {
                bestPin = pin.original
                bestLength = pin.length
            }
        }
        let result = bestPin ?? repositoryRoot?(path) ?? cwd
        anchors[cwd] = result
        return result
    }
}
