import SwiftUI
import AppKit

struct GitDiffPresentation: Identifiable, Equatable {
    let sourcePath: String
    let repoRoot: String

    var id: String { repoRoot }
}

struct RepoDirtyBadge: View {
    let status: GitRepoStatus
    var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
            Text("\(status.dirtyCount)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.45).opacity(isFocused ? 0.96 : 0.84))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.28, green: 0.17, blue: 0.06).opacity(isFocused ? 0.85 : 0.62))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(isFocused ? 0.14 : 0.08), lineWidth: 1)
        }
    }
}

private struct InspectorButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.12 : 0.06))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct GitDiffInspector: View {
    @EnvironmentObject var manager: TerminalManager
    @StateObject private var loader: GitDiffLoader
    @FocusState private var isFocused: Bool

    let presentation: GitDiffPresentation
    let onClose: () -> Void

    init(presentation: GitDiffPresentation, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.onClose = onClose
        _loader = StateObject(wrappedValue: GitDiffLoader(repoRoot: presentation.repoRoot))
    }

    private var status: GitRepoStatus? {
        manager.gitStatus(forRepoRoot: presentation.repoRoot)
    }

    private var changedPaths: [String] {
        status?.changedFiles.map { $0.path } ?? []
    }

    private var currentFile: GitChangedFile? {
        guard let selectedPath = loader.selectedPath else { return nil }
        return status?.changedFiles.first(where: { $0.path == selectedPath })
    }

    private var repoName: String {
        let name = (presentation.repoRoot as NSString).lastPathComponent
        return name.isEmpty ? presentation.repoRoot : name
    }

    @State private var fileSidebarWidth: CGFloat = 280
    @State private var diffFocused = false
    @State private var diffScrollProxy = GitDiffScrollProxy()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.25)

            HStack(spacing: 0) {
                fileSidebar
                    .frame(width: fileSidebarWidth)

                Divider().opacity(0.2)

                diffPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 20, y: 10)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { handleArrow(.up) }
        .onKeyPress(.downArrow) { handleArrow(.down) }
        .onKeyPress(.leftArrow) { handleArrow(.left) }
        .onKeyPress(.rightArrow) { handleArrow(.right) }
        .onKeyPress(.return) { handleArrow(.right) }
        .onAppear {
            syncSelection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
        .onChange(of: changedPaths) { _, _ in
            syncSelection()
        }
    }

    private enum Arrow { case up, down, left, right }

    private func handleArrow(_ dir: Arrow) -> KeyPress.Result {
        guard let files = status?.changedFiles, !files.isEmpty else { return .ignored }

        if diffFocused {
            switch dir {
            case .up:
                diffScrollProxy.scroll(by: -80)
                return .handled
            case .down:
                diffScrollProxy.scroll(by: 80)
                return .handled
            case .left:
                diffFocused = false
                return .handled
            case .right:
                return .ignored
            }
        }

        // File list navigation
        let currentIndex = files.firstIndex(where: { $0.path == loader.selectedPath })

        switch dir {
        case .up:
            guard let idx = currentIndex, idx > 0 else { return .handled }
            loader.load(file: files[idx - 1])
            return .handled
        case .down:
            if let idx = currentIndex, idx < files.count - 1 {
                loader.load(file: files[idx + 1])
            } else if currentIndex == nil {
                loader.load(file: files[0])
            }
            return .handled
        case .right:
            diffFocused = true
            return .handled
        case .left:
            return .ignored
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.45))

                    Text(repoName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                }

                Text(presentation.repoRoot)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)

                Text(statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                InspectorButton(label: "Refresh", icon: "arrow.clockwise") {
                    manager.refreshGitStatus(forRepoRoot: presentation.repoRoot)
                    if let currentFile {
                        loader.reload(file: currentFile)
                    }
                }

                InspectorButton(label: "Back to Terminal", icon: "terminal") {
                    onClose()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.04))
        .preventWindowDrag()
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))

                Spacer()

                if let status {
                    Text("\(status.dirtyCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.44))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.22)

            if let status, !status.changedFiles.isEmpty {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(status.changedFiles.enumerated()), id: \.element.id) { index, file in
                            GitChangedFileRow(
                                file: file,
                                isSelected: loader.selectedPath == file.path
                            ) {
                                loader.load(file: file)
                            }

                            if index < status.changedFiles.count - 1 {
                                Divider().opacity(0.15).padding(.leading, 40)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                GitInspectorEmptyState(
                    title: "Working tree is clean",
                    message: "No uncommitted changes are available for this repository right now."
                )
            }
        }
        .background(Color.white.opacity(0.03))
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            if let currentFile {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentFile.displayName)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))

                        Text(currentFile.path)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.46))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(currentFile.statusSummary)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(currentFile.tintColor.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(currentFile.tintColor.opacity(0.14))
                        )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.02))

                Divider().opacity(0.22)
            }

            ZStack {
                Color.clear

                if loader.isLoading {
                    ProgressView("Loading diff...")
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.8))
                        .foregroundStyle(.white.opacity(0.68))
                } else if let errorMessage = loader.errorMessage {
                    GitInspectorEmptyState(
                        title: "Couldn't load diff",
                        message: errorMessage
                    )
                } else if loader.selectedPath == nil {
                    GitInspectorEmptyState(
                        title: "Select a file",
                        message: "Choose a changed file on the left to inspect its uncommitted patch."
                    )
                } else {
                    GitDiffCodeView(document: loader.diffDocument, scrollProxy: diffScrollProxy)
                }
            }
        }
    }

    // Background is intentionally absent — the inspector sits inside ContentView's
    // themed background (vibrancy + accent + brightness), so it stays translucent.

    private var statusLine: String {
        guard let status else { return "Resolving repository status..." }
        if status.hasChanges {
            return "\(status.dirtyCount) changed \(status.dirtyCount == 1 ? "file" : "files") in the working tree"
        }
        return "Working tree is clean"
    }

    private func syncSelection() {
        loader.syncSelection(with: status?.changedFiles ?? [])
    }
}

private struct GitChangedFileRow: View {
    let file: GitChangedFile
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: file.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(file.tintColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.75))
                        .lineLimit(1)

                    if let parentPath = file.parentPath {
                        Text(parentPath)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Text(file.statusSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(file.tintColor.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.12) :
                          hovering ? Color.white.opacity(0.06) :
                          Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct GitInspectorEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.34))

            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

class GitDiffScrollProxy {
    weak var scrollView: NSScrollView?

    func scroll(by deltaY: CGFloat) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let current = scrollView.contentView.bounds.origin
        let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        let newY = min(max(current.y + deltaY, 0), maxY)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: current.x, y: newY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

struct GitDiffCodeView: NSViewRepresentable {
    let document: GitDiffDocument
    let scrollProxy: GitDiffScrollProxy

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> GitDiffScrollView {
        let scrollView = GitDiffScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.focusRingType = .none
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.title = "Diff"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        scrollView.documentView = tableView

        context.coordinator.attach(tableView: tableView)
        let coordinator = context.coordinator
        scrollView.onLayoutChange = { [weak coordinator] availableWidth in
            coordinator?.updateColumnWidth(availableWidth: availableWidth)
        }
        context.coordinator.update(document: document, availableWidth: scrollView.contentSize.width)
        scrollProxy.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: GitDiffScrollView, context: Context) {
        context.coordinator.update(document: document, availableWidth: scrollView.contentSize.width)
        scrollProxy.scrollView = scrollView
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("git-diff")

        private let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        private var document: GitDiffDocument
        private weak var tableView: NSTableView?

        init(document: GitDiffDocument) {
            self.document = document
        }

        func attach(tableView: NSTableView) {
            self.tableView = tableView
        }

        func update(document: GitDiffDocument, availableWidth: CGFloat) {
            self.document = document
            tableView?.reloadData()
            updateColumnWidth(availableWidth: availableWidth)
        }

        func updateColumnWidth(availableWidth: CGFloat) {
            guard let tableView, let column = tableView.tableColumns.first else { return }
            let charWidth = "W".size(withAttributes: [.font: font]).width
            let preferredWidth = max(availableWidth, 72 + CGFloat(document.longestLineLength) * charWidth)
            if abs(column.width - preferredWidth) > 1 {
                column.width = preferredWidth
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            document.lines.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            document.lines[row].kind.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = GitDiffTableCellView.reuseIdentifier
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? GitDiffTableCellView
                ?? GitDiffTableCellView()
            cell.update(with: document.lines[row])
            return cell
        }
    }
}

final class GitDiffScrollView: NSScrollView {
    var onLayoutChange: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        onLayoutChange?(contentSize.width)
    }
}

private final class GitDiffTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("git-diff-cell")

    private let markerLabel = NSTextField(labelWithString: "")
    private let contentLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private let regularFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private let emphasisFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.cornerCurve = .continuous

        markerLabel.alignment = .center
        markerLabel.font = emphasisFont
        markerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        markerLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markerLabel.widthAnchor.constraint(equalToConstant: 34)
        ])

        contentLabel.lineBreakMode = .byClipping
        contentLabel.usesSingleLineMode = true
        contentLabel.allowsDefaultTighteningForTruncation = false
        contentLabel.font = regularFont
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 12
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 18)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(markerLabel)
        stackView.addArrangedSubview(contentLabel)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with line: GitDiffRenderedLine) {
        layer?.backgroundColor = line.kind.backgroundColor.cgColor
        markerLabel.stringValue = line.marker
        markerLabel.textColor = line.kind.markerColor
        contentLabel.stringValue = line.text.isEmpty ? " " : line.text
        contentLabel.textColor = line.kind.textColor
        contentLabel.font = line.kind.usesEmphasis ? emphasisFont : regularFont
        markerLabel.font = line.kind.usesEmphasis ? emphasisFont : regularFont
        markerLabel.alphaValue = line.kind.showsMarker ? 1 : 0
        contentLabel.alphaValue = line.kind == .spacer ? 0 : 1
    }
}

private struct GitDiffPayload {
    let document: GitDiffDocument
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

struct GitDiffRenderedLine: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: GitDiffRenderedLineKind

    var marker: String {
        kind.marker(for: text)
    }
}

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

    var backgroundColor: NSColor {
        switch self {
        case .sectionHeader:
            return NSColor(calibratedRed: 0.27, green: 0.19, blue: 0.07, alpha: 0.88)
        case .fileHeader:
            return NSColor(calibratedWhite: 1.0, alpha: 0.06)
        case .meta:
            return NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 0.92)
        case .hunk:
            return NSColor(calibratedRed: 0.11, green: 0.18, blue: 0.30, alpha: 0.92)
        case .addition:
            return NSColor(calibratedRed: 0.07, green: 0.24, blue: 0.16, alpha: 0.96)
        case .deletion:
            return NSColor(calibratedRed: 0.28, green: 0.10, blue: 0.11, alpha: 0.96)
        case .note:
            return NSColor(calibratedRed: 0.25, green: 0.20, blue: 0.08, alpha: 0.92)
        case .context:
            return NSColor(calibratedWhite: 1.0, alpha: 0.025)
        case .spacer:
            return .clear
        }
    }

    var textColor: NSColor {
        switch self {
        case .sectionHeader:
            return NSColor(calibratedRed: 1.0, green: 0.89, blue: 0.60, alpha: 0.98)
        case .fileHeader:
            return NSColor(calibratedWhite: 0.98, alpha: 0.92)
        case .meta:
            return NSColor(calibratedWhite: 0.78, alpha: 0.90)
        case .hunk:
            return NSColor(calibratedRed: 0.68, green: 0.83, blue: 1.0, alpha: 0.98)
        case .addition:
            return NSColor(calibratedRed: 0.76, green: 1.0, blue: 0.82, alpha: 0.98)
        case .deletion:
            return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.80, alpha: 0.98)
        case .note:
            return NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.60, alpha: 0.96)
        case .context:
            return NSColor(calibratedWhite: 0.92, alpha: 0.88)
        case .spacer:
            return .clear
        }
    }

    var markerColor: NSColor {
        switch self {
        case .addition:
            return NSColor(calibratedRed: 0.48, green: 0.98, blue: 0.65, alpha: 0.98)
        case .deletion:
            return NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.60, alpha: 0.98)
        case .hunk:
            return NSColor(calibratedRed: 0.67, green: 0.83, blue: 1.0, alpha: 0.98)
        case .meta:
            return NSColor(calibratedWhite: 0.64, alpha: 0.92)
        case .fileHeader:
            return NSColor(calibratedWhite: 0.88, alpha: 0.94)
        case .note:
            return NSColor(calibratedRed: 1.0, green: 0.89, blue: 0.60, alpha: 0.96)
        case .context:
            return NSColor(calibratedWhite: 0.45, alpha: 0.8)
        case .sectionHeader, .spacer:
            return .clear
        }
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

struct GitDiffSection {
    let title: String
    let content: String

    var contentLines: [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

final class GitDiffLoader: ObservableObject {
    @Published private(set) var selectedPath: String?
    @Published private(set) var diffDocument: GitDiffDocument = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let repoRoot: String
    private let queue = DispatchQueue(label: "com.wave.git.diff-loader", qos: .userInitiated)
    private let lock = NSLock()
    private var requestID: UInt = 0
    private var activeProcess: Process?

    init(repoRoot: String) {
        self.repoRoot = GitCLI.normalizePath(repoRoot)
    }

    deinit {
        cancelActiveProcess()
    }

    func syncSelection(with files: [GitChangedFile]) {
        guard !files.isEmpty else {
            cancelActiveProcess()
            selectedPath = nil
            diffDocument = .empty
            errorMessage = nil
            isLoading = false
            return
        }

        if let selectedPath,
           let selectedFile = files.first(where: { $0.path == selectedPath }) {
            if diffDocument.lines.isEmpty && !isLoading {
                load(file: selectedFile)
            }
            return
        }

        load(file: files[0])
    }

    func load(file: GitChangedFile) {
        performLoad(for: file)
    }

    func reload(file: GitChangedFile) {
        performLoad(for: file)
    }

    private func performLoad(for file: GitChangedFile) {
        let currentRequest = nextRequestID()
        cancelActiveProcess()

        selectedPath = file.path
        isLoading = true
        errorMessage = nil

        queue.async { [repoRoot] in
            let result = Self.composeDiff(for: file, repoRoot: repoRoot) { [weak self] process in
                self?.register(process: process, requestID: currentRequest)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.currentRequestID == currentRequest else { return }
                self.clearRegisteredProcess(requestID: currentRequest)
                self.isLoading = false

                switch result {
                case .success(let payload):
                    self.diffDocument = payload.document
                    self.errorMessage = nil
                case .failure(let error):
                    self.diffDocument = .empty
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func nextRequestID() -> UInt {
        lock.withLock {
            requestID &+= 1
            return requestID
        }
    }

    private var currentRequestID: UInt {
        lock.withLock { requestID }
    }

    private func register(process: Process, requestID: UInt) {
        lock.withLock {
            guard self.requestID == requestID else {
                process.terminate()
                return
            }

            activeProcess = process
        }
    }

    private func clearRegisteredProcess(requestID: UInt) {
        lock.withLock {
            guard self.requestID == requestID else { return }
            activeProcess = nil
        }
    }

    private func cancelActiveProcess() {
        lock.withLock {
            activeProcess?.terminate()
            activeProcess = nil
        }
    }

    private static func composeDiff(
        for file: GitChangedFile,
        repoRoot: String,
        processHandler: @escaping (Process) -> Void
    ) -> Result<GitDiffPayload, Error> {
        do {
            var sections: [GitDiffSection] = []

            if file.isConflicted {
                let diff = try runPatch(
                    arguments: [
                        "-C", repoRoot,
                        "diff",
                        "--no-ext-diff",
                        "--no-color",
                        "--cc",
                        "--unified=3",
                        "--",
                        file.path
                    ],
                    processHandler: processHandler
                )

                if diff.isEmpty {
                    return .success(GitDiffPayload(document: .note("No combined diff is available for \(file.path) right now.")))
                }

                sections.append(GitDiffSection(title: "CONFLICT", content: diff))
                return .success(GitDiffPayload(document: .fromSections(sections)))
            }

            if file.hasStagedChanges {
                let diff = try runPatch(
                    arguments: [
                        "-C", repoRoot,
                        "diff",
                        "--no-ext-diff",
                        "--no-color",
                        "--cached",
                        "--no-renames",
                        "--unified=3",
                        "--",
                        file.path
                    ],
                    processHandler: processHandler
                )

                if !diff.isEmpty {
                    sections.append(GitDiffSection(title: "STAGED", content: diff))
                }
            }

            if file.hasUnstagedChanges {
                let diff = try runPatch(
                    arguments: [
                        "-C", repoRoot,
                        "diff",
                        "--no-ext-diff",
                        "--no-color",
                        "--no-renames",
                        "--unified=3",
                        "--",
                        file.path
                    ],
                    processHandler: processHandler
                )

                if !diff.isEmpty {
                    sections.append(GitDiffSection(title: "UNSTAGED", content: diff))
                }
            }

            if file.isUntracked {
                let absolutePath = (repoRoot as NSString).appendingPathComponent(file.path)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue {
                    sections.append(GitDiffSection(
                        title: "UNTRACKED",
                        content: "\(file.path) is an untracked directory. Add or select a file inside it to inspect an exact patch."
                    ))
                } else {
                    let diff = try runPatch(
                        arguments: [
                            "-C", repoRoot,
                            "diff",
                            "--no-index",
                            "--no-color",
                            "--",
                            "/dev/null",
                            file.path
                        ],
                        processHandler: processHandler
                    )

                    if !diff.isEmpty {
                        sections.append(GitDiffSection(title: "UNTRACKED", content: diff))
                    }
                }
            }

            if sections.isEmpty {
                return .success(GitDiffPayload(document: .note("No patch is available for \(file.path).")))
            }

            return .success(GitDiffPayload(document: .fromSections(sections)))
        } catch {
            return .failure(error)
        }
    }

    private static func runPatch(
        arguments: [String],
        processHandler: @escaping (Process) -> Void
    ) throws -> String {
        let result = try GitCLI.run(arguments: arguments, processHandler: processHandler)
        guard result.exitCode == 0 || result.exitCode == 1 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitDiffError.commandFailed(stderr.isEmpty ? "Git failed to produce a diff." : stderr)
        }

        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum GitDiffError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}

private extension GitChangedFile {
    var symbolName: String {
        if isConflicted { return "exclamationmark.triangle.fill" }
        if isUntracked { return "plus.circle.fill" }
        if stagedState == .deleted || unstagedState == .deleted { return "minus.circle.fill" }
        if stagedState == .added || unstagedState == .added { return "plus.square.fill" }
        if stagedState == .renamed || unstagedState == .renamed { return "arrow.left.arrow.right.circle.fill" }
        return "pencil.circle.fill"
    }

    var tintColor: Color {
        if isConflicted { return Color(red: 1.0, green: 0.42, blue: 0.38) }
        if isUntracked { return Color(red: 0.42, green: 0.86, blue: 0.56) }
        if stagedState == .deleted || unstagedState == .deleted { return Color(red: 1.0, green: 0.5, blue: 0.42) }
        if stagedState == .added || unstagedState == .added { return Color(red: 0.42, green: 0.86, blue: 0.56) }
        if stagedState == .renamed || unstagedState == .renamed { return Color(red: 1.0, green: 0.76, blue: 0.38) }
        return Color(red: 0.48, green: 0.74, blue: 1.0)
    }
}

private extension NSLock {
    func withLock<T>(_ block: () -> T) -> T {
        lock()
        defer { unlock() }
        return block()
    }
}
