import Foundation

// Original AppRuntime.groupAnchor with gitIntegrationEnabled == false.
private func legacyAnchor(_ cwd: String, pinned: [String]) -> String {
    let path = GitCLI.normalizePath(cwd)
    guard !path.isEmpty else { return cwd }
    var bestPin: String?
    var bestLength = -1
    for pin in pinned {
        let normalized = GitCLI.normalizePath(pin)
        guard !normalized.isEmpty else { continue }
        if (path == normalized || path.hasPrefix(normalized + "/")), normalized.count > bestLength {
            bestPin = pin
            bestLength = normalized.count
        }
    }
    return bestPin ?? cwd
}

@main
struct GroupingBenchmark {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wave-grouping-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = (0..<12).map { root.appendingPathComponent("project-\($0)").path }
        for pin in pinned {
            try FileManager.default.createDirectory(atPath: pin + "/src", withIntermediateDirectories: true)
        }
        let directories = (0..<60).map { pinned[$0 % pinned.count] + "/src" }
        let expected = directories.map { legacyAnchor($0, pinned: pinned) }
        let resolver = DirectoryGroupResolver(pinned: pinned)
        precondition(directories.map(resolver.anchor(for:)) == expected)
        var results: [[String: Any]] = []
        for pins in [pinned, []] {
            var before: [Double] = [], after: [Double] = []
            let expected = directories.map { legacyAnchor($0, pinned: pins) }
            func sample(legacy: Bool) -> Double {
                let start = DispatchTime.now().uptimeNanoseconds
                // Include a fresh resolver each pass: no persistent warm cache.
                let resolver = DirectoryGroupResolver(pinned: legacy ? [] : pins)
                let actual = directories.map { legacy ? legacyAnchor($0, pinned: pins) : resolver.anchor(for: $0) }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                precondition(actual == expected)
                return ms
            }
            _ = sample(legacy: true); _ = sample(legacy: false)
            for i in 0..<15 {
                if i.isMultiple(of: 2) {
                    before.append(sample(legacy: true)); after.append(sample(legacy: false))
                } else {
                    after.append(sample(legacy: false)); before.append(sample(legacy: true))
                }
            }
            results.append(["tabs": directories.count, "pins": pins.count,
                            "before_ms": before, "after_ms": after,
                            "before_median_ms": before.sorted()[7], "after_median_ms": after.sorted()[7]])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
    }
}
