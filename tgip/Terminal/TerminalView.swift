import SwiftUI
import GhosttyKit

/// A single NSViewRepresentable that keeps a container NSView alive.
/// It swaps which session's TerminalSurfaceView is displayed by
/// adding/removing children — the surface views themselves are never
/// destroyed on tab switch.
struct TerminalView: NSViewRepresentable {
    @EnvironmentObject var manager: TerminalManager
    let sessionID: UUID?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let sessionID,
              let session = manager.session(for: sessionID),
              let surfaceView = session.surfaceView else {
            if !container.subviews.isEmpty {
                for sub in container.subviews { sub.removeFromSuperview() }
            }
            return
        }

        if container.subviews.first === surfaceView { return }

        for sub in container.subviews { sub.removeFromSuperview() }
        surfaceView.frame = container.bounds
        surfaceView.autoresizingMask = [.width, .height]
        container.addSubview(surfaceView)
        container.window?.makeFirstResponder(surfaceView)
    }
}
