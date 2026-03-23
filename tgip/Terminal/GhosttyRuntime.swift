import AppKit
import GhosttyKit

class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private let tickStateQueue = DispatchQueue(label: "wave.ghostty.tick")
    private var tickScheduled = false
    private var tickPending = false

    var onAction: ((_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool)?

    init() {
        Self.configureGhosttyEnvironment()

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            NSLog("ghostty_init failed"); return
        }
        guard let cfg = ghostty_config_new() else {
            NSLog("ghostty_config_new failed"); return
        }
        self.config = cfg
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_cli_args(cfg)
        ghostty_config_load_recursive_files(cfg)

        if let bundledConfig = Bundle.main.path(forResource: "ghostty", ofType: "config") {
            ghostty_config_load_file(cfg, bundledConfig)
        }

        ghostty_config_finalize(cfg)

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true

        rt.wakeup_cb = { ud in
            guard let ud else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
            runtime.scheduleTick()
        }

        rt.action_cb = { appPtr, target, action in
            guard let appPtr else { return false }
            guard let ud = ghostty_app_userdata(appPtr) else { return false }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
            return runtime.onAction?(target, action) ?? false
        }

        // Clipboard callbacks receive the SURFACE's userdata (the TerminalSurfaceView ptr),
        // not the runtime's userdata.

        rt.read_clipboard_cb = { surfaceUD, location, state in
            guard let surfaceUD else { return false }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(surfaceUD).takeUnretainedValue()
            guard let surface = view.surface else { return false }
            guard let string = NSPasteboard.general.string(forType: .string) else { return false }
            string.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }

        rt.confirm_read_clipboard_cb = { surfaceUD, content, state, request in
            guard let surfaceUD else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(surfaceUD).takeUnretainedValue()
            guard let surface = view.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        rt.write_clipboard_cb = { surfaceUD, location, content, len, confirm in
            guard let content, len > 0, let data = content.pointee.data else { return }
            let string = String(cString: data)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        rt.close_surface_cb = { surfaceUD, processAlive in
            // Handled via GHOSTTY_ACTION_CLOSE_WINDOW in the action callback
        }

        guard let ghosttyApp = ghostty_app_new(&rt, cfg) else {
            NSLog("ghostty_app_new failed"); return
        }
        self.app = ghosttyApp
    }

    private static func configureGhosttyEnvironment() {
        guard let resourcesPath = Bundle.main.resourcePath else { return }

        setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 1)

        let terminfoPath = "\(resourcesPath)/terminfo"
        setenv("TERMINFO", terminfoPath, 1)
        setenv("TERMINFO_DIRS", terminfoPath, 1)

        if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            setenv("GHOSTTY_BIN_DIR", executablePath, 1)
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    private func scheduleTick() {
        let shouldSchedule = tickStateQueue.sync { () -> Bool in
            tickPending = true
            guard !tickScheduled else { return false }
            tickScheduled = true
            return true
        }

        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drainPendingTicks()
        }
    }

    private func drainPendingTicks() {
        while true {
            let hasWork = tickStateQueue.sync { () -> Bool in
                guard tickPending else {
                    tickScheduled = false
                    return false
                }
                tickPending = false
                return true
            }

            guard hasWork else { return }
            tick()
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func createSurface(for view: TerminalSurfaceView) {
        guard let app else { return }
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        cfg.scale_factor = Double(view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        if let pwd = view.initialWorkingDirectory {
            pwd.withCString { ptr in
                cfg.working_directory = ptr
                view.surface = ghostty_surface_new(app, &cfg)
            }
        } else {
            view.surface = ghostty_surface_new(app, &cfg)
        }
    }
}
