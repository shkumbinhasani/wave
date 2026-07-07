import Foundation

/// Installs the notification hooks that let Wave know when a coding agent
/// finishes, needs input, or exits — routed to the exact tab via `WAVE_SESSION_ID`.
///
/// Modeled on how cmux does it: Claude Code is handled by a `claude` shim on
/// `PATH` that injects `--settings` (so we never rewrite the user's global
/// `~/.claude/settings.json`), while other agents get their hooks merged
/// non-destructively into their own config files. Every hook just drops a small
/// signal file into `dropDirectory`, which `AgentMonitor` watches.
enum AgentHookInstaller {
    /// Where hooks drop signal files. Watched by `AgentMonitor`.
    static let dropDirectory = "/tmp/wave-agents"

    /// Wave-managed support dir under the user's home.
    private static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wave/agents", isDirectory: true)
    }

    /// Directory prepended to each terminal's `PATH` so our `claude` shim wins.
    static var shimDirectory: String {
        supportDirectory.appendingPathComponent("shims", isDirectory: true).path
    }

    private static var claudeSettingsPath: String {
        supportDirectory.appendingPathComponent("claude-settings.json").path
    }

    /// Substring baked into every command we install, used to find & replace
    /// our own entries when re-installing (and to prune legacy ones).
    private static let ownershipMarker = dropDirectory

    // MARK: - Entry point

    /// Idempotent — safe to call on every launch.
    static func installAll() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dropDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        installClaude()
        removeLegacyGlobalClaudeHook()

        // Other agents: merge into their own config, but only if that agent
        // actually looks installed (its config dir exists), so we never create
        // config for tools the user doesn't have.
        installCodex()
        installGemini()
        installOpenCode()
    }

    // MARK: - Shared hook command

    /// A shell command that writes one signal file and always exits 0 so it can
    /// never block or fail the agent.
    private static func hookCommand(agent: AgentKind, action: AgentAction) -> String {
        // Real newlines would break the single-line shell string, so the printf
        // format uses literal \n escapes (interpreted by printf itself).
        let dir = dropDirectory
        let format = "WAVE_AGENT=%s\\nWAVE_ACTION=%s\\nWAVE_SID=%s\\nWAVE_PWD=%s\\n"
        let printf = "printf '\(format)' '\(agent.rawValue)' '\(action.rawValue)' \"${WAVE_SESSION_ID:-}\" \"$PWD\""
        return "mkdir -p \(dir) 2>/dev/null; __wf=\"$(mktemp \(dir)/evt.XXXXXXXX 2>/dev/null)\" && { \(printf); cat 2>/dev/null; } > \"$__wf\" 2>/dev/null; :"
    }

    /// A `{type,command,timeout}` hook entry.
    private static func nestedHook(agent: AgentKind, action: AgentAction, timeout: Int = 5) -> [String: Any] {
        ["type": "command", "command": hookCommand(agent: agent, action: action), "timeout": timeout]
    }

    // MARK: - Claude (shim + --settings)

    private static func installClaude() {
        writeClaudeSettings()
        writeClaudeShim()
    }

    /// The settings blob injected via `--settings`. Merges additively with the
    /// user's own Claude settings; we only add hooks + silence Claude's native
    /// notification channel so ours is the single source (matching cmux).
    private static func writeClaudeSettings() {
        let settings: [String: Any] = [
            "preferredNotifChannel": "notifications_disabled",
            "hooks": [
                "SessionStart": [["hooks": [nestedHook(agent: .claude, action: .start)]]],
                "UserPromptSubmit": [["hooks": [nestedHook(agent: .claude, action: .prompt)]]],
                "Stop": [["hooks": [nestedHook(agent: .claude, action: .stop)]]],
                "Notification": [["hooks": [nestedHook(agent: .claude, action: .notify)]]],
                "SessionEnd": [["hooks": [nestedHook(agent: .claude, action: .sessionEnd)]]],
                // Covers --dangerously-skip-permissions, where Notification never
                // fires: these two tools always mean "waiting on the user".
                "PreToolUse": [[
                    "matcher": "ExitPlanMode|AskUserQuestion",
                    "hooks": [nestedHook(agent: .claude, action: .notify)]
                ]]
            ]
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
    }

    private static func writeClaudeShim() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: shimDirectory, withIntermediateDirectories: true)

        // Resolve the real `claude` by scanning PATH (skipping our own shim dir)
        // and a few common install locations, then re-exec with our settings.
        let script = """
        #!/bin/sh
        # Wave-generated shim. Injects agent notification hooks without touching
        # your global Claude settings. Delete ~/.wave to remove.
        __wave_shim_dir='\(shimDirectory)'
        __wave_settings='\(claudeSettingsPath)'
        __wave_real=''
        __wave_oldifs=$IFS
        IFS=:
        for __p in $PATH; do
          [ "$__p" = "$__wave_shim_dir" ] && continue
          if [ -x "$__p/claude" ]; then __wave_real="$__p/claude"; break; fi
        done
        IFS=$__wave_oldifs
        if [ -z "$__wave_real" ]; then
          for __c in "$HOME/.claude/local/claude" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
            [ -x "$__c" ] && { __wave_real="$__c"; break; }
          done
        fi
        if [ -z "$__wave_real" ]; then
          echo "wave: could not find the real 'claude' on PATH" >&2
          exit 127
        fi
        exec "$__wave_real" --settings "$__wave_settings" "$@"
        """

        let shimPath = (shimDirectory as NSString).appendingPathComponent("claude")
        guard let data = script.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: shimPath), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath)
    }

    /// Remove the old global-settings Notification hook Wave used to install so
    /// it doesn't double-fire alongside the shim.
    private static func removeLegacyGlobalClaudeHook() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any],
              var notifications = hooks["Notification"] as? [[String: Any]] else { return }

        let before = notifications.count
        notifications = notifications.filter { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else { return true }
            return !inner.contains { ($0["command"] as? String)?.contains("tgip-attention") == true }
        }
        guard notifications.count != before else { return }

        if notifications.isEmpty { hooks.removeValue(forKey: "Notification") }
        else { hooks["Notification"] = notifications }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }

        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL, options: .atomic)
        }
    }

    // MARK: - Other agents (config-file merge)

    /// Merge a set of nested hooks into an agent's JSON config, replacing any
    /// hooks we previously installed but preserving everything the user added.
    /// `eventActions` maps the agent's own event names → our canonical action.
    private static func installNestedHooks(
        agent: AgentKind,
        configFile: URL,
        gateDirectory: URL,
        eventActions: [(event: String, action: AgentAction)],
        timeout: Int
    ) {
        let fm = FileManager.default
        // Only touch agents the user actually has.
        guard fm.fileExists(atPath: gateDirectory.path) else { return }

        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        }
        var hooks = config["hooks"] as? [String: Any] ?? [:]

        for (event, action) in eventActions {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Drop our previous entries (identified by the drop-dir marker).
            entries = entries.filter { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains { ($0["command"] as? String)?.contains(ownershipMarker) == true }
            }
            entries.append(["hooks": [nestedHook(agent: agent, action: action, timeout: timeout)]])
            hooks[event] = entries
        }

        config["hooks"] = hooks
        try? fm.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: configFile, options: .atomic)
        }
    }

    private static func installCodex() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
        installNestedHooks(
            agent: .codex,
            configFile: codexDir.appendingPathComponent("hooks.json"),
            gateDirectory: codexDir,
            eventActions: [
                ("SessionStart", .start),
                ("UserPromptSubmit", .prompt),
                ("Stop", .stop)
            ],
            timeout: 5
        )
        enableCodexHooksFeature(configToml: codexDir.appendingPathComponent("config.toml"))
    }

    /// Codex only runs hooks when the `hooks` feature is on. Add a `[features]`
    /// table only if the file doesn't already have one — appending a second
    /// `[features]` table would be a TOML duplicate-table error and corrupt the
    /// user's config. If they already have `[features]`, we leave it alone (they
    /// can add `hooks = true` themselves) rather than risk breaking Codex.
    private static func enableCodexHooksFeature(configToml: URL) {
        let begin = "# wave codex hooks begin"
        let end = "# wave codex hooks end"
        let block = "\n\(begin)\n[features]\nhooks = true\n\(end)\n"

        var contents = (try? String(contentsOf: configToml, encoding: .utf8)) ?? ""
        if contents.contains(begin) { return }             // already added by us
        if contents.contains("[features]") { return }      // user has their own — don't duplicate
        if contents.contains("features.hooks") { return }  // dotted form already present
        contents += block
        try? contents.write(to: configToml, atomically: true, encoding: .utf8)
    }

    private static func installGemini() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let geminiDir = home.appendingPathComponent(".gemini", isDirectory: true)
        installNestedHooks(
            agent: .gemini,
            configFile: geminiDir.appendingPathComponent("settings.json"),
            gateDirectory: geminiDir,
            eventActions: [
                ("SessionStart", .start),
                ("BeforeAgent", .prompt),
                ("AfterAgent", .stop),
                ("SessionEnd", .sessionEnd)
            ],
            timeout: 10
        )
    }

    // MARK: - OpenCode (plugin)

    private static func installOpenCode() {
        let fm = FileManager.default
        let configDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode", isDirectory: true)
        guard fm.fileExists(atPath: configDir.path) else { return }

        // 1. Write the plugin that bridges OpenCode's event bus to signal files.
        let pluginsDir = configDir.appendingPathComponent("plugins", isDirectory: true)
        try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let pluginPath = pluginsDir.appendingPathComponent("wave-session.js")
        if let data = openCodePluginSource.data(using: .utf8) {
            try? data.write(to: pluginPath, options: .atomic)
        }

        // 2. Register it in opencode.json's `plugin` array (non-destructively).
        let configFile = configDir.appendingPathComponent("opencode.json")
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: configFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = json
        }
        let spec = "./plugins/wave-session.js"
        var plugins = config["plugin"] as? [String] ?? []
        if !plugins.contains(spec) {
            plugins.append(spec)
            config["plugin"] = plugins
            if let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: configFile, options: .atomic)
            }
        }
    }

    /// OpenCode has no JSON hook table — it uses a JS plugin on its event bus.
    /// This one maps bus events to Wave signal files (session.idle == finished).
    private static var openCodePluginSource: String {
        """
        // Wave-generated OpenCode plugin. Bridges the agent lifecycle to Wave's
        // tab notifications. Delete this file (and its opencode.json entry) to remove.
        import fs from "node:fs";
        import os from "node:os";
        import path from "node:path";

        const DROP_DIR = "\(dropDirectory)";

        function signal(action) {
          try {
            fs.mkdirSync(DROP_DIR, { recursive: true });
            const sid = process.env.WAVE_SESSION_ID || "";
            const pwd = process.cwd();
            const body =
              "WAVE_AGENT=opencode\\n" +
              "WAVE_ACTION=" + action + "\\n" +
              "WAVE_SID=" + sid + "\\n" +
              "WAVE_PWD=" + pwd + "\\n";
            const file = path.join(DROP_DIR, "evt." + process.pid + "." + Date.now() + "." + Math.random().toString(36).slice(2));
            fs.writeFileSync(file, body);
          } catch (_) { /* never break the agent */ }
        }

        export const Wave = async () => ({
          event: async ({ event }) => {
            switch (event.type) {
              case "session.created": signal("start"); break;
              case "session.idle": signal("stop"); break;
              case "session.deleted": signal("sessionEnd"); break;
              case "permission.asked":
              case "question.asked": signal("notify"); break;
            }
          },
        });
        """
    }
}
