import XCTest

final class GitDiffModelTests: XCTestCase {

    func testLineClassification() {
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "diff --git a/x b/x"), .fileHeader)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "@@ -1,2 +1,3 @@"), .hunk)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "+++ b/x"), .addition)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "--- a/x"), .deletion)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "+added line"), .addition)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "-removed line"), .deletion)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "index 1234..5678 100644"), .meta)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "new file mode 100644"), .meta)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: "Binary files differ"), .meta)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: " unchanged context"), .context)
        XCTAssertEqual(GitDiffRenderedLineKind(rawLine: ""), .context)
    }

    func testMarkers() {
        XCTAssertEqual(GitDiffRenderedLineKind.addition.marker(for: "+x"), "+")
        XCTAssertEqual(GitDiffRenderedLineKind.addition.marker(for: "+++ b/x"), "++")
        XCTAssertEqual(GitDiffRenderedLineKind.deletion.marker(for: "-x"), "-")
        XCTAssertEqual(GitDiffRenderedLineKind.deletion.marker(for: "--- a/x"), "--")
        XCTAssertEqual(GitDiffRenderedLineKind.hunk.marker(for: "@@"), "@@")
        XCTAssertEqual(GitDiffRenderedLineKind.spacer.marker(for: ""), "")
    }

    func testFromSectionsBuildsHeaderAndClassifiedLines() {
        let doc = GitDiffDocument.fromSections([
            GitDiffSection(title: "STAGED", content: "@@ -1 +1 @@\n-old\n+new")
        ])
        let kinds = doc.lines.map(\.kind)
        XCTAssertEqual(kinds, [.sectionHeader, .hunk, .deletion, .addition])
        XCTAssertEqual(doc.lines.first?.text, "STAGED")
    }

    func testFromSectionsInsertsSpacerBetweenSectionsOnly() {
        let doc = GitDiffDocument.fromSections([
            GitDiffSection(title: "STAGED", content: "+a"),
            GitDiffSection(title: "UNSTAGED", content: "+b")
        ])
        let kinds = doc.lines.map(\.kind)
        // header, +a, spacer, header, +b — exactly one spacer, between the two.
        XCTAssertEqual(kinds, [.sectionHeader, .addition, .spacer, .sectionHeader, .addition])
        XCTAssertEqual(kinds.filter { $0 == .spacer }.count, 1)
    }

    func testEmptySectionContentRendersSingleContextLine() {
        // `"".split(omittingEmptySubsequences: false)` is [""], so contentLines is
        // never empty — an empty section yields one blank context line, not the
        // "No patch lines available." note. (Behavior preserved from pre-refactor.)
        let doc = GitDiffDocument.fromSections([GitDiffSection(title: "EMPTY", content: "")])
        XCTAssertEqual(doc.lines.map(\.kind), [.sectionHeader, .context])
    }

    func testEmptySectionsProduceEmptyDocument() {
        XCTAssertEqual(GitDiffDocument.fromSections([]), .empty)
    }

    func testNoteSplitsLines() {
        let doc = GitDiffDocument.note("line one\nline two")
        XCTAssertEqual(doc.lines.map(\.text), ["line one", "line two"])
        XCTAssertTrue(doc.lines.allSatisfy { $0.kind == .note })
    }

    func testLongestLineLengthIsComputed() {
        let doc = GitDiffDocument.fromSections([GitDiffSection(title: "S", content: "+short\n+a much longer line")])
        XCTAssertEqual(doc.longestLineLength, "+a much longer line".count)
    }

    func testRenderedLineExposesMarker() {
        let line = GitDiffRenderedLine(id: 0, text: "+added", kind: .addition)
        XCTAssertEqual(line.marker, "+")
    }
}
