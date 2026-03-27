import Foundation

struct TerminalSearchState: Equatable {
    let sessionID: UUID
    var query: String
    var totalMatches: Int?
    var selectedMatch: Int?
}

enum TerminalSearchDirection {
    case previous
    case next

    var bindingActionValue: String {
        switch self {
        case .previous:
            return "previous"
        case .next:
            return "next"
        }
    }
}
