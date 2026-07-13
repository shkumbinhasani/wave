import Foundation
import Observation

@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    var workingDirectory: String?
    var isRunning: Bool = true

    /// Local tmux session backing this tab (resumable tabs only). When set,
    /// the tab's shell lives in tmux and survives the app; closing the tab
    /// kills the session, quitting the app does not.
    let tmuxSessionName: String?

    /// Unseen-attention flag: set when an agent finishes or needs input while
    /// this tab isn't focused; cleared when the user views the tab. Drives the
    /// dock badge and tab highlight.
    var needsAttention: Bool = false

    /// Which coding agent is running in this tab (nil if none detected). Drives
    /// the tab's agent glyph.
    var agentKind: AgentKind? {
        didSet { if agentKind != nil && agentStatus == .idle { agentStatus = .running } }
    }

    /// The agent's current lifecycle status. Drives the status color.
    var agentStatus: AgentStatus = .idle

    /// Strong reference — the view lives as long as the session.
    /// Excluded from observation: it's an AppKit view handle, not view-driving state.
    @ObservationIgnored var surfaceView: TerminalSurfaceView?

    var title: String {
        didSet { if let kind = AgentKind.detect(fromTitle: title) { agentKind = kind } }
    }

    /// `id` is injectable so a restored resumable tab keeps its original
    /// identity — agent hooks route notifications by this UUID (it rides the
    /// tmux session environment, fixed at session creation).
    init(title: String = "Terminal", id: UUID = UUID(), tmuxSessionName: String? = nil) {
        self.id = id
        self.title = title
        self.tmuxSessionName = tmuxSessionName
        self.agentKind = AgentKind.detect(fromTitle: title)
    }
}
