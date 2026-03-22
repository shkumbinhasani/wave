import SwiftUI
import AppKit

/// An NSView that prevents window dragging so SwiftUI drag gestures work.
struct NonDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableView {
        NonDraggableView()
    }
    func updateNSView(_ nsView: NonDraggableView, context: Context) {}
}

class NonDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Modifier that places a non-draggable NSView behind the content.
struct NonDraggableModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(NonDraggableArea())
    }
}

extension View {
    func preventWindowDrag() -> some View {
        modifier(NonDraggableModifier())
    }
}
