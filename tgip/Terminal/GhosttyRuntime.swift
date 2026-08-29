import AppKit
import GhosttyKit

class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
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
            // Coalesce rapid wakeups into a single tick per runloop cycle
            DispatchQueue.main.async {
                guard !runtime.tickPending else { return }
                runtime.tickPending = true
                DispatchQueue.main.async {
                    runtime.tickPending = false
                    runtime.tick()
                }
            }
        }

        rt.action_cb = { appPtr, target, action in
            guard let appPtr else { return false }
            guard let ud = ghostty_app_userdata(appPtr) else { return false }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
            return runtime.onAction?(target, action) ?? false
        }

        // Clipboard callbacks receive the SURFACE's userdata (the TerminalSurfaceView ptr),
        // not the runtime's userdata.

        // Wave serves plain text from the standard pasteboard only, and
        // auto-confirms reads (no permission prompt).

        rt.read_clipboard_cb = { surfaceUD, location, state, mimes, mimesLen, list in
            guard let surfaceUD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(surfaceUD).takeUnretainedValue()
            guard let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
            guard let string = NSPasteboard.general.string(forType: .string) else {
                return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
            }
            GhosttyRuntime.completeClipboardRequest(surface, text: string, state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        rt.confirm_read_clipboard_cb = { surfaceUD, confirm, state, request in
            guard let surfaceUD, let confirm else { return }
            let view = Unmanaged<TerminalSurfaceView>.fromOpaque(surfaceUD).takeUnretainedValue()
            guard let surface = view.surface else { return }
            // Echo the pending contents back approved; the confirm payload's
            // pointers stay valid for the duration of this callback.
            var complete = ghostty_clipboard_complete_s(
                contents: confirm.pointee.contents,
                contents_len: confirm.pointee.contents_len,
                available: confirm.pointee.available,
                available_len: confirm.pointee.available_len,
                confirmed: true,
                remember: false
            )
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
        }

        rt.write_clipboard_cb = { surfaceUD, location, contents, len, confirm in
            guard let contents, len > 0 else { return }
            for i in 0..<len {
                let entry = contents[i]
                guard let data = entry.data,
                      entry.mime.map({ String(cString: $0) }) ?? "text/plain" == "text/plain"
                else { continue }
                // Data is length-delimited, not NUL-terminated.
                let string = String(decoding: UnsafeRawBufferPointer(
                    start: data, count: entry.len
                ), as: UTF8.self)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
                break
            }
        }

        rt.close_surface_cb = { surfaceUD, processAlive in
            // Handled via GHOSTTY_ACTION_CLOSE_WINDOW in the action callback
        }

        guard let ghosttyApp = ghostty_app_new(&rt, cfg) else {
            NSLog("ghostty_app_new failed"); return
        }
        self.app = ghosttyApp
    }

    /// Serve one text/plain entry to a pending clipboard read. Everything is
    /// copied into C-visible memory only for the duration of the call —
    /// libghostty copies what it keeps.
    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        text: String,
        state: UnsafeMutableRawPointer?
    ) {
        text.withCString { dataPtr in
            "text/plain".withCString { mimePtr in
                withUnsafePointer(to: ghostty_clipboard_content_s(
                    mime: mimePtr,
                    data: dataPtr,
                    len: text.utf8.count
                )) { contentPtr in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentPtr,
                        contents_len: 1,
                        available: nil,
                        available_len: 0,
                        confirmed: false,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
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

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func appNeedsConfirmQuit() -> Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }

    func createSurface(for view: TerminalSurfaceView) {
        guard let app else { return }

        // Inject session ID so child shell (and tools like Claude Code) can identify this tab
        let sessionID = view.session?.id.uuidString ?? ""
        setenv("WAVE_SESSION_ID", sessionID, 1)
        defer { unsetenv("WAVE_SESSION_ID") }

        // Prepend our agent-shim dir so the `claude` shim (which injects
        // notification hooks) wins on PATH. Restore afterwards so the app's own
        // PATH is untouched.
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        let shimDir = AgentHookInstaller.shimDirectory
        if let originalPath {
            setenv("PATH", "\(shimDir):\(originalPath)", 1)
        } else {
            setenv("PATH", shimDir, 1)
        }
        defer {
            if let originalPath { setenv("PATH", originalPath, 1) }
            else { unsetenv("PATH") }
        }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(view).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))
        cfg.scale_factor = Double(view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0)

        // Ghostty copies config strings during surface_new; the duplicates
        // only need to outlive the call.
        let pwdPtr = view.initialWorkingDirectory.map { strdup($0) }
        let inputPtr = view.initialInput.map { strdup($0) }
        let commandPtr = view.spawnCommand.map { strdup($0) }
        defer {
            pwdPtr.map { free($0) }
            inputPtr.map { free($0) }
            commandPtr.map { free($0) }
        }
        if let pwdPtr { cfg.working_directory = UnsafePointer(pwdPtr) }
        if let inputPtr { cfg.initial_input = UnsafePointer(inputPtr) }
        if let commandPtr { cfg.command = UnsafePointer(commandPtr) }

        view.surface = ghostty_surface_new(app, &cfg)
    }
}
