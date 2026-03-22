import SwiftUI
import AppKit

struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let min: CGFloat
    let max: CGFloat

    func makeNSView(context: Context) -> ResizeHandleView {
        let view = ResizeHandleView()
        view.onDrag = { delta in
            let new = width + delta
            width = Swift.min(self.max, Swift.max(self.min, new))
        }
        return view
    }

    func updateNSView(_ nsView: ResizeHandleView, context: Context) {
        nsView.onDrag = { delta in
            let new = width + delta
            width = Swift.min(self.max, Swift.max(self.min, new))
        }
    }
}

/// An NSView that handles mouse dragging for resize.
/// Returns false from mouseDownCanMoveWindow so the window
/// drag doesn't steal the gesture.
class ResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        let delta = x - lastX
        lastX = x
        onDrag?(delta)
    }
}
