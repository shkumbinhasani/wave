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
        // Find the session's surface view
        guard let sessionID,
              let session = manager.sessions.first(where: { $0.id == sessionID }),
              let surfaceView = session.surfaceView else {
            // No session selected — clear container
            for sub in container.subviews { sub.removeFromSuperview() }
            return
        }

        // Already showing the right view — nothing to do
        if container.subviews.first === surfaceView { return }

        // Swap: remove old, add new
        for sub in container.subviews { sub.removeFromSuperview() }
        surfaceView.frame = container.bounds
        surfaceView.autoresizingMask = [.width, .height]
        container.addSubview(surfaceView)
        container.window?.makeFirstResponder(surfaceView)
    }
}
