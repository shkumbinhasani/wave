import AppKit
import GhosttyKit

// Isolated host for the real TerminalSurfaceView. It runs /bin/cat with an
// explicit config, without launching Wave, tmux, shell startup files, or hooks.
final class TerminalSession {}

final class GhosttyRuntime {
    private var app: ghostty_app_t?
    private let config: ghostty_config_t
    private var wakeup: CoalescedAction?

    init(configPath: String) {
        precondition(ghostty_init(0, nil) == 0)
        config = ghostty_config_new()!
        ghostty_config_load_file(config, configPath)
        ghostty_config_finalize(config)
        precondition(ghostty_config_diagnostics_count(config) == 0)
        wakeup = CoalescedAction { [weak self] in
            if let app = self?.app { ghostty_app_tick(app) }
        }
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.wakeup_cb = { pointer in
            guard let pointer else { return }
            Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue().wakeup?.schedule()
        }
        runtime.action_cb = { _, _, _ in true }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }
        app = ghostty_app_new(&runtime, config)
        precondition(app != nil)
    }

    func createSurface(for view: TerminalSurfaceView) {
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        config.scale_factor = Double(view.window?.backingScaleFactor ?? 2)
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        "/bin/cat".withCString { command in
            config.command = command
            view.surface = ghostty_surface_new(app, &config)
        }
        precondition(view.surface != nil)
    }

    deinit {
        if let app { ghostty_app_free(app) }
        ghostty_config_free(config)
    }
}

private func cpuSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func pump(for seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let event = NSApp.nextEvent(matching: .any,
                                       until: min(end, Date().addingTimeInterval(0.02)),
                                       inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
}

private func visibleText(_ surface: ghostty_surface_t) -> String {
    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
        top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
        bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
        rectangle: false
    )
    precondition(ghostty_surface_read_text(surface, selection, &text))
    defer { ghostty_surface_free_text(surface, &text) }
    return text.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(text.text_len)), as: UTF8.self) } ?? ""
}

@main
struct RenderingBenchmark {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let duration = Double(env["WAVE_BENCH_SECONDS"] ?? "4")!
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let runtime = GhosttyRuntime(configPath: env["WAVE_BENCH_CONFIG"]!)
        let session = TerminalSession()
        let view = TerminalSurfaceView(runtime: runtime, session: session)
        view.isActiveTab = true
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 500),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Wave performance benchmark"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump(for: 1)
        precondition(window.occlusionState.contains(.visible), "Benchmark window must be visible")
        let surface = view.surface!
        ghostty_surface_set_focus(surface, true)

        func send(_ value: String) {
            value.withCString { ghostty_surface_text(surface, $0, UInt(value.utf8.count)) }
        }
        send("WAVE_BENCH_READY\r")
        pump(for: 0.5)
        precondition(visibleText(surface).contains("WAVE_BENCH_READY"))

        var rows: [[String: Any]] = []
        var sent = 0
        let payload = String(repeating: "0123456789 benchmark terminal output abcdefghijklmnopqrstuvwxyz\r", count: 12)
        var producer: Timer?
        func measure(_ name: String, output: Bool) {
            if output {
                producer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                    payload.withCString { ghostty_surface_text(surface, $0, UInt(payload.utf8.count)) }
                    sent += payload.utf8.count
                }
            }
            pump(for: 0.5)
            let bytesBefore = sent
            let cpuBefore = cpuSeconds()
            let start = DispatchTime.now().uptimeNanoseconds
            pump(for: duration)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let cpu = cpuSeconds() - cpuBefore
            producer?.invalidate()
            producer = nil
            rows.append(["scenario": name, "seconds": elapsed, "cpu_percent": cpu / elapsed * 100,
                         "input_bytes": sent - bytesBefore])
        }

        measure("visible_idle", output: false)
        measure("visible_output", output: true)
        // A real tab switch deactivates and detaches the surface.
        view.isActiveTab = false
        view.removeFromSuperview()
        measure("hidden_output", output: true)
        window.contentView = view
        view.isActiveTab = true
        window.makeFirstResponder(view)
        pump(for: 0.5)
        send("WAVE_BENCH_RESUMED\r")
        pump(for: 0.5)
        precondition(visibleText(surface).contains("WAVE_BENCH_RESUMED"), "Hidden output must survive tab switching")
        window.setContentSize(NSSize(width: 940, height: 600))
        pump(for: 0.3)
        send("WAVE_BENCH_RESIZED\r")
        pump(for: 0.3)
        precondition(visibleText(surface).contains("WAVE_BENCH_RESIZED"))

        if let screenshotPath = env["WAVE_BENCH_SCREENSHOT"],
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: screenshotPath))
        }
        let version = ghostty_info()
        let report: [String: Any] = [
            "ghostty_version": String(cString: version.version),
            "checks": ["initial_output", "output_after_reattach", "output_after_resize"],
            "samples": rows,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        view.destroySurface()
        window.close()
        withExtendedLifetime(runtime) {}
    }
}
