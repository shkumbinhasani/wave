import SwiftUI

private struct SearchOverlayButton: View {
    @ObservedObject private var theme = SidebarTheme.shared
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.adaptiveForeground(opacity: isDisabled ? 0.22 : (hovering ? 0.85 : 0.65)))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.adaptiveForeground(opacity: hovering && !isDisabled ? 0.12 : 0.04))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
    }
}

struct TerminalSearchOverlay: View {
    @ObservedObject private var theme = SidebarTheme.shared
    @Binding var query: String
    let totalMatches: Int?
    let selectedMatch: Int?
    let focusToken: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var searchFieldFocused: Bool

    private var canNavigate: Bool {
        (totalMatches ?? 0) > 0
    }

    private var statusText: String {
        if query.isEmpty {
            return "Type to search"
        }

        guard let totalMatches else {
            return "Searching..."
        }

        guard totalMatches > 0 else {
            return "No matches"
        }

        if let selectedMatch, selectedMatch > 0 {
            return "\(selectedMatch) of \(totalMatches)"
        }

        return "\(totalMatches) matches"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.adaptiveForeground(opacity: 0.5))

            TextField("Find in terminal", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.adaptiveForeground(opacity: 0.92))
                .frame(width: 220)
                .focused($searchFieldFocused)
                .onSubmit(onNext)

            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.adaptiveForeground(opacity: 0.48))
                .frame(width: 112, alignment: .trailing)
                .lineLimit(1)

            Rectangle()
                .fill(theme.adaptiveForeground(opacity: 0.08))
                .frame(width: 1, height: 16)

            SearchOverlayButton(systemImage: "chevron.up", isDisabled: !canNavigate, action: onPrevious)
            SearchOverlayButton(systemImage: "chevron.down", isDisabled: !canNavigate, action: onNext)
            SearchOverlayButton(systemImage: "xmark", isDisabled: false, action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, emphasized: false)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.adaptiveScrim(opacity: theme.lightText ? 0.2 : 0.05))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.adaptiveForeground(opacity: 0.14), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.22), radius: 18, y: 8)
        .preventWindowDrag()
        .onAppear(perform: focusField)
        .onChange(of: focusToken) { _, _ in
            focusField()
        }
        .onExitCommand(perform: onClose)
    }

    private func focusField() {
        DispatchQueue.main.async {
            searchFieldFocused = true
        }
    }
}
