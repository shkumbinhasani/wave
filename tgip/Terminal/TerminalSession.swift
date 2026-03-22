import Foundation

class TerminalSession: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var workingDirectory: String?
    @Published var isRunning: Bool = true

    /// Strong reference — the view lives as long as the session.
    var surfaceView: TerminalSurfaceView?

    init(title: String = "Terminal") {
        self.title = title
    }
}
