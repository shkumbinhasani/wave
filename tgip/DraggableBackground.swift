import SwiftUI
import AppKit

/// Wraps SwiftUI content in an NSView that allows window dragging.
/// The NSHostingView is embedded so mouse events that aren't handled
/// by SwiftUI controls fall through to this view's mouseDown,
/// which starts a window drag.
struct DraggableContainer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> DraggableHostView<Content> {
        DraggableHostView(content: content)
    }

    func updateNSView(_ nsView: DraggableHostView<Content>, context: Context) {
        nsView.hosting.rootView = content
    }
}

class DraggableHostView<Content: View>: NSView {
    let hosting: NSHostingView<Content>

    init(content: Content) {
        self.hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = [.intrinsicContentSize]
        }
        hosting.safeAreaRegions = []
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Start window drag from empty areas
        window?.performDrag(with: event)
    }
}
