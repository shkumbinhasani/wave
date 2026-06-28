import Foundation
import Observation

@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    var title: String
    var workingDirectory: String?
    var isRunning: Bool = true
    var needsAttention: Bool = false

    /// Strong reference — the view lives as long as the session.
    /// Excluded from observation: it's an AppKit view handle, not view-driving state.
    @ObservationIgnored var surfaceView: TerminalSurfaceView?

    init(title: String = "Terminal") {
        self.title = title
    }
}
