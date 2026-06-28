import Foundation
import CoreGraphics

// Pure diff domain — no AppKit, no Process. Takes raw `git diff` text and turns
// it into a structured, rendered document. The classification of each line and
// the assembly of a document from sections live here so they can be exercised
// with plain strings, no repository and no subprocess. AppKit styling for each
// line kind lives in an extension in GitDiffInspector.swift.

/// One titled block of raw patch text (e.g. STAGED / UNSTAGED / CONFLICT).
struct GitDiffSection: Equatable {
    let title: String
    let content: String

    var contentLines: [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

/// Semantic classification of a single rendered diff line. Pure: the
/// `init(rawLine:)` classifier, markers, and layout metadata carry no AppKit
/// dependency. Colors are added by an extension in the AppKit layer.
enum GitDiffRenderedLineKind: Equatable {
    case sectionHeader
    case fileHeader
    case meta
    case hunk
    case addition
    case deletion
    case context
    case note
    case spacer

    init(rawLine: String) {
        if rawLine.hasPrefix("diff --git") {
            self = .fileHeader
        } else if rawLine.hasPrefix("@@") {
            self = .hunk
        } else if rawLine.hasPrefix("+++") {
            self = .addition
        } else if rawLine.hasPrefix("---") {
            self = .deletion
        } else if rawLine.hasPrefix("+") {
            self = .addition
        } else if rawLine.hasPrefix("-") {
            self = .deletion
        } else if rawLine.hasPrefix("index ") ||
                    rawLine.hasPrefix("new file mode ") ||
                    rawLine.hasPrefix("deleted file mode ") ||
                    rawLine.hasPrefix("similarity index ") ||
                    rawLine.hasPrefix("rename from ") ||
                    rawLine.hasPrefix("rename to ") ||
                    rawLine.hasPrefix("Binary files ") {
            self = .meta
        } else if rawLine.isEmpty {
            self = .context
        } else {
            self = .context
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .sectionHeader: return 28
        case .spacer: return 10
        case .note: return 24
        default: return 22
        }
    }

    var showsMarker: Bool {
        self != .sectionHeader && self != .spacer
    }

    var usesEmphasis: Bool {
        self == .sectionHeader || self == .fileHeader || self == .hunk
    }

    func marker(for text: String) -> String {
        switch self {
        case .addition: return text.hasPrefix("+++") ? "++" : "+"
        case .deletion: return text.hasPrefix("---") ? "--" : "-"
        case .hunk: return "@@"
        case .fileHeader: return "F"
        case .meta: return ">"
        case .note: return "!"
        case .context: return " "
        case .sectionHeader, .spacer: return ""
        }
    }
}

struct GitDiffRenderedLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: GitDiffRenderedLineKind

    var marker: String {
        kind.marker(for: text)
    }
}

struct GitDiffDocument: Equatable {
    let lines: [GitDiffRenderedLine]
    let longestLineLength: Int

    static let empty = GitDiffDocument(lines: [], longestLineLength: 0)

    init(lines: [GitDiffRenderedLine], longestLineLength: Int? = nil) {
        self.lines = lines
        self.longestLineLength = longestLineLength ?? lines.map { $0.text.count }.max() ?? 0
    }

    static func fromSections(_ sections: [GitDiffSection]) -> GitDiffDocument {
        guard !sections.isEmpty else { return .empty }

        var lines: [GitDiffRenderedLine] = []
        lines.reserveCapacity(sections.reduce(0) { $0 + $1.contentLines.count + 2 })
        var nextID = 0

        func append(_ text: String, kind: GitDiffRenderedLineKind) {
            lines.append(GitDiffRenderedLine(id: nextID, text: text, kind: kind))
            nextID += 1
        }

        for (index, section) in sections.enumerated() {
            append(section.title, kind: .sectionHeader)
            if section.contentLines.isEmpty {
                append("No patch lines available.", kind: .note)
            } else {
                for rawLine in section.contentLines {
                    append(rawLine, kind: GitDiffRenderedLineKind(rawLine: rawLine))
                }
            }

            if index < sections.count - 1 {
                append("", kind: .spacer)
            }
        }

        return GitDiffDocument(lines: lines)
    }

    static func note(_ message: String) -> GitDiffDocument {
        let rows = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                GitDiffRenderedLine(id: index, text: String(line), kind: .note)
            }
        return GitDiffDocument(lines: rows)
    }
}
