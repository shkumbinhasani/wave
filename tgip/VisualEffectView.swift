import SwiftUI
import AppKit

func configureWaveWindowChrome(_ window: NSWindow) {
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbar = nil
    window.titlebarSeparatorStyle = .none
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    window.styleMask.remove(.unifiedTitleAndToolbar)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.title = ""

    let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    let nativeButtons = buttons.compactMap { window.standardWindowButton($0) }

    // Keep the native traffic lights alive but effectively invisible.
    // Hard-hiding or removing them breaks AppKit's built-in minimize/fullscreen
    // behavior, which our custom sidebar controls still rely on.
    nativeButtons.forEach { button in
        button.isHidden = false
        button.alphaValue = 0.001
        button.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    }

    let buttonContainers = Set(nativeButtons.compactMap(\.superview))
    buttonContainers.forEach { container in
        container.isHidden = false
        container.alphaValue = 0.001
        container.setFrameOrigin(NSPoint(x: -10_000, y: container.frame.origin.y))
    }
}

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
        var pendingReconfigures: [DispatchWorkItem] = []

        func cancelPendingReconfigures() {
            pendingReconfigures.forEach { $0.cancel() }
            pendingReconfigures.removeAll()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        if context.coordinator.window !== window {
            context.coordinator.cancelPendingReconfigures()
            context.coordinator.window = window
        }

        configureWindow(window)
        scheduleReconfigure(for: window, coordinator: context.coordinator)
    }

    private func scheduleReconfigure(for window: NSWindow, coordinator: Coordinator) {
        coordinator.cancelPendingReconfigures()

        for delay in [0.0, 0.05, 0.2] {
            let workItem = DispatchWorkItem { [weak window] in
                guard let window else { return }
                configureWindow(window)
            }
            coordinator.pendingReconfigures.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        configureWaveWindowChrome(window)
    }
}
