import AppKit

/// Detects a tab drag ending on "nothing" outside every window and turns it
/// into a tear-out.
///
/// SwiftUI's `.onDrag` gives no end-of-session callback, so this polls while
/// the drag is in flight: once the mouse button is released, it waits a beat
/// for a drop delegate to claim the drag (a successful reorder or cross-window
/// drop clears `DragState.draggedSessionID` in `performDrop`). If nobody
/// claimed it and the pointer is outside every app window, the session moves
/// into its own new window at the drop point.
enum TearOutDetector {
    private static var timer: Timer?
    private static var sessionID: UUID?

    static func begin(sessionID id: UUID) {
        sessionID = id
        timer?.invalidate()
        // .common so it keeps firing inside the drag's event-tracking run loop.
        let poll = Timer(timeInterval: 0.05, repeats: true) { _ in
            tick()
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    private static func tick() {
        // Left button still down → drag still in flight.
        guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }

        timer?.invalidate()
        timer = nil
        let dropPoint = NSEvent.mouseLocation
        let id = sessionID
        sessionID = nil

        // Let drop delegates run first — they clear DragState when they accept.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let id, DragState.draggedSessionID == id else { return }
            DragState.draggedSessionID = nil

            let insideAppWindow = NSApp.windows.contains {
                $0.isVisible && $0.frame.contains(dropPoint)
            }
            guard !insideAppWindow else { return }

            AppRuntime.shared.tearOut(sessionID: id, at: dropPoint)
        }
    }
}
