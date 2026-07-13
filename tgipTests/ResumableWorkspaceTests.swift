import XCTest

final class ResumableWorkspaceTests: XCTestCase {
    func testMergePreservesPendingInactiveProfiles() {
        let activeProfile = UUID()
        let inactiveProfile = UUID()
        let active = record(name: "wave-1")
        let inactive = record(name: "wave-2")

        let merged = ResumableWorkspace.merging(
            pending: [inactiveProfile.uuidString: [inactive]],
            live: [activeProfile.uuidString: [active]]
        )

        XCTAssertEqual(merged[activeProfile.uuidString], [active])
        XCTAssertEqual(merged[inactiveProfile.uuidString], [inactive])
    }

    func testLiveRecordOverridesPendingCopyAcrossProfiles() {
        let oldProfile = UUID()
        let newProfile = UUID()
        let id = UUID()
        let pending = ResumableTabRecord(
            id: id,
            tmuxName: "wave-1",
            title: "Old",
            workingDirectory: "/old"
        )
        let live = ResumableTabRecord(
            id: id,
            tmuxName: "wave-1",
            title: "Current",
            workingDirectory: "/current"
        )

        let merged = ResumableWorkspace.merging(
            pending: [oldProfile.uuidString: [pending]],
            live: [newProfile.uuidString: [live]]
        )

        XCTAssertNil(merged[oldProfile.uuidString])
        XCTAssertEqual(merged[newProfile.uuidString], [live])
    }

    func testMergeDeduplicatesRepeatedLiveRecords() {
        let profile = UUID()
        let duplicate = record(name: "wave-1")

        let merged = ResumableWorkspace.merging(
            pending: [:],
            live: [profile.uuidString: [duplicate, duplicate]]
        )

        XCTAssertEqual(merged[profile.uuidString], [duplicate])
    }

    func testNameConflictDoesNotConsumeAnotherRecordID() {
        let profile = UUID()
        let first = record(id: UUID(), name: "wave-1")
        let conflictingID = UUID()
        let nameConflict = record(id: conflictingID, name: "wave-1")
        let valid = record(id: conflictingID, name: "wave-2")

        let merged = ResumableWorkspace.merging(
            pending: [:],
            live: [profile.uuidString: [first, nameConflict, valid]]
        )

        XCTAssertEqual(merged[profile.uuidString], [first, valid])
    }

    func testRemovingSuccessfulRestoreLeavesOtherProfilesPending() {
        let restoredProfile = UUID()
        let inactiveProfile = UUID()
        let restored = record(name: "wave-1")
        let inactive = record(name: "wave-2")
        let manifest = [
            restoredProfile.uuidString: [restored],
            inactiveProfile.uuidString: [inactive],
        ]

        let updated = ResumableWorkspace.removing(
            [restored],
            from: manifest,
            profileID: restoredProfile
        )

        XCTAssertNil(updated[restoredProfile.uuidString])
        XCTAssertEqual(updated[inactiveProfile.uuidString], [inactive])
    }

    func testManifestEncodingRoundTrips() throws {
        let profile = UUID()
        let manifest = [profile.uuidString: [record(name: "wave-1")]]

        let data = try XCTUnwrap(ResumableWorkspace.encode(manifest))

        XCTAssertEqual(ResumableWorkspace.decode(data), manifest)
    }

    private func record(name: String) -> ResumableTabRecord {
        record(id: UUID(), name: name)
    }

    private func record(id: UUID, name: String) -> ResumableTabRecord {
        ResumableTabRecord(
            id: id,
            tmuxName: name,
            title: name,
            workingDirectory: "/tmp"
        )
    }
}
