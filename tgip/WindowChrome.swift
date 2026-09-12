import SwiftUI
import AppKit

/// The blurred layer behind the whole window.
///
/// On macOS 26 this is Liquid Glass, shaped to the window's own corners so the
/// glass rim follows the system radius. Older systems keep the HUD blur.
struct WindowBackdrop: View {
    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: ConcentricRectangle())
        } else {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, emphasized: false)
        }
    }
}

/// Glass for panels that float inside the window (the sidebar drawer).
struct PanelBackdrop: View {
    var cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, emphasized: false)
        }
    }
}

extension View {
    /// Clips a main pane (terminal, diff inspector) and draws its hairline border.
    ///
    /// On macOS 26 the corners are concentric with the window: the radius comes
    /// from the window's shape minus the pane's distance to the edge, so it
    /// tracks whatever radius the system uses. `fallbackRadius` is the floor
    /// (used in full screen, where the window has square corners) and the fixed
    /// radius on older systems.
    @ViewBuilder
    func paneChrome(fallbackRadius: CGFloat, border: Color, lineWidth: CGFloat = 1) -> some View {
        if #available(macOS 26, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(fallbackRadius)), isUniform: true)
            self
                .clipShape(shape)
                .overlay {
                    shape
                        .stroke(border, lineWidth: lineWidth)
                        .padding(lineWidth / 2)
                }
        } else {
            let shape = RoundedRectangle(cornerRadius: fallbackRadius, style: .continuous)
            self
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(border, lineWidth: lineWidth)
                }
        }
    }
}
