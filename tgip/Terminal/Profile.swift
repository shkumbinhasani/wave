import SwiftUI

struct Profile: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String

    // Theme
    var accentColorRGB: [Double]
    var backgroundOpacity: Double
    var vibrancy: Double
    var brightness: Double
    var lightText: Bool

    // Workspace
    var pinnedPaths: [String]
    var groupMeta: [String: GroupMeta]

    static let iconChoices = [
        "chevron.left.forwardslash.chevron.right",
        "house", "briefcase", "paintbrush", "book",
        "gamecontroller", "globe", "star", "heart", "leaf",
        "terminal", "server.rack", "cloud", "hammer",
        "cpu", "flame", "bolt", "flag",
    ]

    init(
        id: UUID = UUID(),
        name: String = "Default",
        icon: String = "chevron.left.forwardslash.chevron.right"
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentColorRGB = [0.15, 0.15, 0.15]
        self.backgroundOpacity = 0.0
        self.vibrancy = 1.0
        self.brightness = 0.0
        self.lightText = true
        self.pinnedPaths = []
        self.groupMeta = [:]
    }

    mutating func captureTheme(from theme: SidebarTheme) {
        if let c = NSColor(theme.accentColor).usingColorSpace(.deviceRGB) {
            accentColorRGB = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        }
        backgroundOpacity = theme.backgroundOpacity
        vibrancy = theme.vibrancy
        brightness = theme.brightness
        lightText = theme.lightText
    }

    var accentColor: Color {
        guard accentColorRGB.count == 3 else {
            return Color(red: 0.15, green: 0.15, blue: 0.15)
        }
        return Color(red: accentColorRGB[0], green: accentColorRGB[1], blue: accentColorRGB[2])
    }
}
