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

struct WindowConfigurator: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var observers: [NSObjectProtocol] = []

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

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView)
        }

        if let window = nsView.window {
            registerObservers(for: window, coordinator: context.coordinator)
        }
    }

    private func configureWindow(for view: NSView) {
        guard let window = view.window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.collectionBehavior.insert(.fullScreenPrimary)

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
