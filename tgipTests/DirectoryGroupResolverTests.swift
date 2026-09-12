import XCTest

final class DirectoryGroupResolverTests: XCTestCase {
    func testDeepestPinWinsAndKeepsItsOriginalSpelling() {
        let resolver = DirectoryGroupResolver(
            pinned: ["~/project", "~/project/apps"],
            normalize: { $0.replacingOccurrences(of: "~", with: "/home/test") },
            repositoryRoot: { _ in "/home/test/project" }
        )
        XCTAssertEqual(resolver.anchor(for: "/home/test/project/apps/web"), "~/project/apps")
        XCTAssertEqual(resolver.anchor(for: "/home/test/project"), "~/project")
    }

    func testPinMatchesOnlyWholePathComponents() {
        let resolver = DirectoryGroupResolver(pinned: ["/project"], normalize: { $0 })
        XCTAssertEqual(resolver.anchor(for: "/project-two/src"), "/project-two/src")
        XCTAssertEqual(resolver.anchor(for: "/project/src"), "/project")
    }

    func testRepositoryLookupReceivesNormalizedPath() {
        let resolver = DirectoryGroupResolver(pinned: [], normalize: { _ in "/real/src" }) { path in
            XCTAssertEqual(path, "/real/src")
            return "/real"
        }
        XCTAssertEqual(resolver.anchor(for: "/symlink/src"), "/real")
    }

    func testNormalizesPinsAndDuplicateDirectoriesOnlyOncePerPass() {
        var calls: [String] = []
        let resolver = DirectoryGroupResolver(pinned: ["/a", "/b"], normalize: {
            calls.append($0)
            return $0
        })
        for _ in 0..<100 {
            XCTAssertEqual(resolver.anchor(for: "/a/src"), "/a")
            XCTAssertEqual(resolver.anchor(for: "/loose"), "/loose")
        }
        XCTAssertEqual(calls, ["/a", "/b", "/a/src", "/loose"])
    }

    func testDisabledGitWithoutPinsDoesNotTouchFilesystem() {
        let resolver = DirectoryGroupResolver(pinned: [], normalize: { path in
            XCTFail("No path normalization is needed")
            return path
        })
        XCTAssertEqual(resolver.anchor(for: "~/project"), "~/project")
        XCTAssertEqual(resolver.anchor(for: "ssh://host"), "ssh://host")
    }

    func testNewPassResolvesChangedSymlinkAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let oldPass = DirectoryGroupResolver(pinned: [first.path, second.path])
        XCTAssertEqual(oldPass.anchor(for: link.path), first.path)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        let newPass = DirectoryGroupResolver(pinned: [first.path, second.path])
        XCTAssertEqual(newPass.anchor(for: link.path), second.path)
    }
}
