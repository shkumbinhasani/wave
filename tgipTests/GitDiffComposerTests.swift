import XCTest

final class GitDiffComposerTests: XCTestCase {

    /// A fake git that returns canned output by inspecting the diff flags, plus
    /// a configurable directory probe.
    private struct FakeGit {
        var conflict = ""
        var staged = ""
        var unstaged = ""
        var untracked = ""
        var directories: Set<String> = []
        var throwError: Error?

        func environment() -> GitDiffComposer.Environment {
            GitDiffComposer.Environment(
                runGit: { args in
                    if let throwError { throw throwError }
                    if args.contains("--cc") { return conflict }
                    if args.contains("--cached") { return staged }
                    if args.contains("--no-index") { return untracked }
                    return unstaged
                },
                isDirectory: { directories.contains($0) }
            )
        }
    }

    private func file(
        path: String = "src/main.swift",
        staged: GitFileStateCode? = nil,
        unstaged: GitFileStateCode? = nil,
        untracked: Bool = false,
        conflicted: Bool = false
    ) -> GitChangedFile {
        GitChangedFile(
            path: path,
            stagedState: staged,
            unstagedState: unstaged,
            isUntracked: untracked,
            isConflicted: conflicted
        )
    }

    func testStagedOnlyProducesSingleSection() throws {
        let git = FakeGit(staged: "@@ -1 +1 @@\n-old\n+new")
        let env = git.environment()
        let result = try GitDiffComposer.compose(for: file(staged: .modified), repoRoot: "/repo", env: env)
        XCTAssertEqual(result, .sections([
            GitDiffSection(title: "STAGED", content: "@@ -1 +1 @@\n-old\n+new")
        ]))
    }

    func testStagedAndUnstagedProduceTwoSectionsInOrder() throws {
        let git = FakeGit(staged: "staged-diff", unstaged: "unstaged-diff")
        let env = git.environment()
        let result = try GitDiffComposer.compose(
            for: file(staged: .modified, unstaged: .modified),
            repoRoot: "/repo",
            env: env
        )
        XCTAssertEqual(result, .sections([
            GitDiffSection(title: "STAGED", content: "staged-diff"),
            GitDiffSection(title: "UNSTAGED", content: "unstaged-diff")
        ]))
    }

    func testEmptyDiffSectionsAreOmitted() throws {
        let git = FakeGit(staged: "", unstaged: "real-diff")
        let env = git.environment()
        let result = try GitDiffComposer.compose(
            for: file(staged: .modified, unstaged: .modified),
            repoRoot: "/repo",
            env: env
        )
        XCTAssertEqual(result, .sections([
            GitDiffSection(title: "UNSTAGED", content: "real-diff")
        ]))
    }

    func testConflictedWithDiffProducesConflictSection() throws {
        let git = FakeGit(conflict: "<<<<<<< ours")
        let env = git.environment()
        let result = try GitDiffComposer.compose(for: file(conflicted: true), repoRoot: "/repo", env: env)
        XCTAssertEqual(result, .sections([GitDiffSection(title: "CONFLICT", content: "<<<<<<< ours")]))
    }

    func testConflictedWithEmptyDiffProducesNote() throws {
        let git = FakeGit(conflict: "")
        let env = git.environment()
        let result = try GitDiffComposer.compose(for: file(path: "a.txt", conflicted: true), repoRoot: "/repo", env: env)
        XCTAssertEqual(result, .note("No combined diff is available for a.txt right now."))
    }

    func testUntrackedDirectoryProducesExplanatorySection() throws {
        let git = FakeGit(directories: ["/repo/assets"])
        let env = git.environment()
        let result = try GitDiffComposer.compose(for: file(path: "assets", untracked: true), repoRoot: "/repo", env: env)
        XCTAssertEqual(result, .sections([
            GitDiffSection(
                title: "UNTRACKED",
                content: "assets is an untracked directory. Add or select a file inside it to inspect an exact patch."
            )
        ]))
    }

    func testUntrackedFileRunsNoIndexDiff() throws {
        let git = FakeGit(untracked: "new file body")
        let env = git.environment()
        let result = try GitDiffComposer.compose(for: file(path: "new.txt", untracked: true), repoRoot: "/repo", env: env)
        XCTAssertEqual(result, .sections([GitDiffSection(title: "UNTRACKED", content: "new file body")]))
    }

    func testNoChangesProducesNote() throws {
        let git = FakeGit()
        let env = git.environment()
        let result = try GitDiffComposer.compose(for: file(path: "x.txt", staged: .modified), repoRoot: "/repo", env: env)
        XCTAssertEqual(result, .note("No patch is available for x.txt."))
    }

    func testGitFailurePropagates() {
        struct Boom: Error {}
        let git = FakeGit(throwError: Boom())
        let env = git.environment()
        XCTAssertThrowsError(try GitDiffComposer.compose(for: file(staged: .modified), repoRoot: "/repo", env: env))
    }
}
