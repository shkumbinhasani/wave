import SwiftUI

/// A coding agent Wave knows how to detect running inside a terminal tab.
/// Identity is carried structurally by the per-agent notification hooks Wave
/// installs (see `AgentHookInstaller`) — Wave never scrapes terminal output.
enum AgentKind: String, Codable, CaseIterable {
    case claude
    case codex
    case opencode
    case gemini

    /// Identify the agent from a terminal title (agents name themselves in it,
    /// e.g. OpenCode sets the title to "OpenCode"). This is the immediate,
    /// hook-independent way to know which agent is running in a tab.
    static func detect(fromTitle title: String) -> AgentKind? {
        let t = title.lowercased()
        if t.contains("opencode") { return .opencode }
        if t.contains("claude") { return .claude }
        if t.contains("codex") { return .codex }
        if t.contains("gemini") { return .gemini }
        return nil
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .gemini: return "Gemini"
        }
    }

    /// Name of a bundled brand logo in the asset catalog, if one exists.
    /// Takes precedence over `symbol`.
    var assetName: String? {
        switch self {
        case .claude: return "claude-logo"
        case .opencode: return "opencode-logo"
        case .codex, .gemini: return nil
        }
    }

    /// When true, the `assetName` logo is rendered as a single-color (template)
    /// glyph tinted like the SF Symbols — used for marks whose native colors
    /// read poorly at tab size. When false, the logo keeps its brand colors.
    var logoIsTemplate: Bool {
        // Brand logos render in their own colors. OpenCode ships light/dark
        // appearance variants so it stays legible on either background.
        false
    }

    /// SF Symbol fallback used when there's no bundled `assetName`.
    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "curlybraces"
        case .gemini: return "diamond"
        }
    }

    /// Brand-ish tint used for the agent glyph when the agent is merely running
    /// (status colors take over once the tab needs attention).
    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.32) // Claude terracotta
        case .codex: return Color(white: 0.6)
        case .opencode: return Color(red: 0.36, green: 0.66, blue: 0.98)
        case .gemini: return Color(red: 0.55, green: 0.45, blue: 0.95)
        }
    }
}

/// Where an agent is in its turn lifecycle. Drives the tab's status color and
/// whether the tab is flagged for attention.
enum AgentStatus: String {
    case idle       // no active agent (or the session just ended)
    case running    // agent is working — no attention needed
    case needsInput // blocked on the user (permission prompt / question / notification)
    case done       // finished its turn — come back and look
    case error      // finished with an error

    /// True when reaching this status should pull the user back to the tab.
    var isAttention: Bool {
        switch self {
        case .needsInput, .done, .error: return true
        case .idle, .running: return false
        }
    }

    /// Tint for the tab's status dot / highlight.
    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .error: return .red
        }
    }
}

/// The canonical lifecycle action a hook maps to, independent of each agent's
/// own event names. The `AgentHookInstaller` bakes one of these into every
/// signal file (`WAVE_ACTION=`), so `AgentMonitor` never needs per-agent logic.
enum AgentAction: String {
    case start         // session started
    case prompt        // user submitted a prompt — agent is working again
    case stop          // agent finished its turn
    case notify        // agent needs the user (permission / question / notification)
    case sessionEnd    // agent process exited

    var status: AgentStatus {
        switch self {
        case .start, .prompt: return .running
        case .stop: return .done
        case .notify: return .needsInput
        case .sessionEnd: return .idle
        }
    }

    /// Whether this action means an agent is now active in the tab.
    var marksAgentActive: Bool {
        switch self {
        case .start, .prompt, .stop, .notify: return true
        case .sessionEnd: return false
        }
    }
}
