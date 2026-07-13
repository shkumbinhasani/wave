import Foundation

struct ResumableTabRecord: Codable, Equatable {
    let id: UUID
    let tmuxName: String
    let title: String
    let workingDirectory: String?
}

enum ResumableWorkspace {
    typealias Manifest = [String: [ResumableTabRecord]]

    static func decode(_ data: Data?) -> Manifest {
        guard let data,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return [:] }
        return manifest
    }

    static func encode(_ manifest: Manifest) -> Data? {
        try? JSONEncoder().encode(manifest)
    }

    /// Live tabs are authoritative. Pending records remain until a restore
    /// succeeds, but cannot duplicate or steal a live tab's identity.
    static func merging(pending: Manifest, live: Manifest) -> Manifest {
        let liveRecords = live.values.flatMap { $0 }
        let liveIDs = Set(liveRecords.map(\.id))
        let liveNames = Set(liveRecords.map(\.tmuxName))
        var result: Manifest = [:]

        for (profileID, records) in live {
            let unique = deduplicated(records)
            if !unique.isEmpty { result[profileID] = unique }
        }

        for (profileID, records) in pending {
            let retained = records.filter {
                !liveIDs.contains($0.id) && !liveNames.contains($0.tmuxName)
            }
            let unique = deduplicated((result[profileID] ?? []) + retained)
            if !unique.isEmpty { result[profileID] = unique }
        }

        return result
    }

    static func removing(
        _ records: [ResumableTabRecord],
        from manifest: Manifest,
        profileID: UUID
    ) -> Manifest {
        guard !records.isEmpty else { return manifest }
        let ids = Set(records.map(\.id))
        let names = Set(records.map(\.tmuxName))
        var updated = manifest
        let remaining = (updated[profileID.uuidString] ?? []).filter {
            !ids.contains($0.id) && !names.contains($0.tmuxName)
        }
        if remaining.isEmpty {
            updated.removeValue(forKey: profileID.uuidString)
        } else {
            updated[profileID.uuidString] = remaining
        }
        return updated
    }

    private static func deduplicated(_ records: [ResumableTabRecord]) -> [ResumableTabRecord] {
        var ids = Set<UUID>()
        var names = Set<String>()
        return records.filter {
            guard !ids.contains($0.id), !names.contains($0.tmuxName) else { return false }
            ids.insert($0.id)
            names.insert($0.tmuxName)
            return true
        }
    }
}

/// A tiny write-ahead journal for tmux sessions created off the main thread.
/// It closes the gap between `new-session` succeeding and the UI publishing
/// the tab into the normal workspace manifest.
enum ResumableCreationRecovery {
    private static let defaultsKey = "resumableWorkspace.pendingCreations"
    private static let lock = NSLock()

    static func load() -> ResumableWorkspace.Manifest {
        lock.lock()
        defer { lock.unlock() }
        return ResumableWorkspace.decode(UserDefaults.standard.data(forKey: defaultsKey))
    }

    static func add(_ record: ResumableTabRecord, profileID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var manifest = ResumableWorkspace.decode(UserDefaults.standard.data(forKey: defaultsKey))
        let key = profileID.uuidString
        if !manifest[key, default: []].contains(where: {
            $0.id == record.id || $0.tmuxName == record.tmuxName
        }) {
            manifest[key, default: []].append(record)
        }
        persist(manifest)
    }

    static func remove(_ records: [ResumableTabRecord], profileID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let manifest = ResumableWorkspace.decode(UserDefaults.standard.data(forKey: defaultsKey))
        persist(ResumableWorkspace.removing(records, from: manifest, profileID: profileID))
    }

    private static func persist(_ manifest: ResumableWorkspace.Manifest) {
        if manifest.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = ResumableWorkspace.encode(manifest) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
