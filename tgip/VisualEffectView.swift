import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = emphasized

        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = emphasized
    }
}

/// An NSView that reports when it lands in (or moves between) windows —
/// reliable attachment hook for window-configuring representables, unlike
/// async hops from makeNSView that race window creation.
final class WindowAttachmentView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onAttach?(window) }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var observers: [NSObjectProtocol] = []
        /// One-time window styling guard — avoids re-running configureWindow
        /// on every SwiftUI update pass.
        var didConfigure = false

        deinit {
            removeObservers()
        }

        func removeObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            window = nil
        }
    }

    var outerPadding: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        let coordinator = context.coordinator
        view.onAttach = { window in
            attach(to: window, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        if let window = nsView.window {
            attach(to: window, coordinator: context.coordinator)
        }
    }

    private func attach(to window: NSWindow, coordinator: Coordinator) {
        if !coordinator.didConfigure {
            coordinator.didConfigure = true
            configureWindow(window)
        }
        registerObservers(for: window, coordinator: coordinator)
    }

    static let windowCornerRadius: CGFloat = 20

    private func configureWindow(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.collectionBehavior.insert(.fullScreenPrimary)

        // Don't set a custom corner radius on the contentView. A `.titled` window
        // is already clipped (and shadowed) by macOS at the system corner radius;
        // overriding it with a larger radius leaves the native corner peeking out
        // behind the custom one as a thin double-border crescent. Let the OS draw
        // the single native corner.
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = true
        }

        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let nativeButtons = buttons.compactMap { window.standardWindowButton($0) }

        nativeButtons.forEach {
            $0.isHidden = false
            $0.alphaValue = 0.001
            $0.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        }

        Set(nativeButtons.compactMap(\.superview)).forEach {
            $0.isHidden = false
            $0.alphaValue = 0.001
            $0.setFrameOrigin(NSPoint(x: -10_000, y: $0.frame.origin.y))
        }
    }

    private func registerObservers(for window: NSWindow, coordinator: Coordinator) {
        guard coordinator.window !== window else { return }

        coordinator.removeObservers()
        coordinator.window = window

        let names: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification
        ]

        coordinator.observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                reconfigure(window)
            }
        }
    }

    private func reconfigure(_ window: NSWindow) {
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
                let nativeButtons = buttons.compactMap { window.standardWindowButton($0) }

                nativeButtons.forEach {
                    $0.isHidden = false
                    $0.alphaValue = 0.001
                    $0.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                }

                Set(nativeButtons.compactMap(\.superview)).forEach {
                    $0.isHidden = false
                    $0.alphaValue = 0.001
                    $0.setFrameOrigin(NSPoint(x: -10_000, y: $0.frame.origin.y))
                }
            }
        }
    }
}
