import SwiftUI
import AppKit

/// The blurred layer behind the whole window, tinted by the theme's accent.
///
/// On macOS 26 this is Liquid Glass, shaped to the window's own corners so the
/// glass rim follows the system radius. Older systems keep the sidebar material
/// with a flat accent wash on top.
struct WindowBackdrop: View {
    var accent: Color
    /// 0 = untinted glass, 1 = the accent shows through as much as the glass allows.
    var tint: Double
    /// The window's own corner radius, read from AppKit, so the glass rim
    /// matches the corner the system clips the window to.
    var cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular.tint(accent.opacity(tint)), in: .rect(cornerRadius: cornerRadius))
        } else {
            ZStack {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow, emphasized: true)
                accent.opacity(tint * 0.6)
            }
        }
    }
}

/// Glass for panels that float inside the window (the sidebar drawer, the
/// search bar, the diff inspector).
struct PanelBackdrop: View {
    var cornerRadius: CGFloat
    var accent: Color = .clear
    var tint: Double = 0

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular.tint(accent.opacity(tint)), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            ZStack {
                VisualEffectView(material: .popover, blendingMode: .withinWindow, emphasized: false)
                accent.opacity(tint * 0.6)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    /// Clips a main pane (terminal, diff inspector) and draws its hairline
    /// border. The caller passes a radius already made concentric with the
    /// window (window radius minus the pane's inset).
    func paneChrome(cornerRadius: CGFloat, lineWidth: CGFloat = 1) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.separator, lineWidth: lineWidth)
            }
    }
}

extension Color {
    /// The system label color at a given opacity — for fills and strokes that
    /// need a Color rather than a ShapeStyle. Follows the window's appearance,
    /// so it reads on light and dark glass alike.
    static func label(_ opacity: Double) -> Color {
        Color(nsColor: .labelColor).opacity(min(max(opacity, 0), 1))
    }
}

/// Glass for a selectable sidebar control (tab row, group header, profile
/// button), applied to the control itself so the pointer reaches it: idle
/// draws nothing, hovered is a plain glass capsule, selected a capsule tinted
/// with the accent. On macOS 26 the glass is interactive, so it lifts under
/// the pointer and presses on click the way system controls do. Older
/// systems draw the same states as flat capsule fills.
enum SelectionState { case idle, hovered, selected }

private struct SelectionGlassModifier: ViewModifier {
    var state: SelectionState
    var accent: Color

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            let glass: Glass = switch state {
            case .idle: .identity
            case .hovered: .regular.interactive()
            case .selected: .regular.tint(accent.opacity(0.4)).interactive()
            }
            content.glassEffect(glass, in: .capsule)
        } else {
            let fill: Color = switch state {
            case .idle: .clear
            case .hovered: Color.label(0.06)
            case .selected: Color.label(0.12)
            }
            content.background { Capsule(style: .continuous).fill(fill) }
        }
    }
}

extension View {
    func selectionGlass(_ state: SelectionState, accent: Color) -> some View {
        modifier(SelectionGlassModifier(state: state, accent: accent))
    }
}

/// Wraps a run of selection-glass controls so they sample one shared
/// backdrop and morph into each other when adjacent. No-op before macOS 26.
struct SidebarGlassContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 6) { content }
        } else {
            content
        }
    }
}
