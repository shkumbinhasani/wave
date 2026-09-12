import SwiftUI

struct Profile: Identifiable, Codable {
    let id: UUID
    var name: String
    var icon: String

    // Theme
    /// nil = follow the system accent color.
    var accentColorRGB: [Double]?
    var tint: Double
    var appearance: ThemeAppearance

    // Connection
    var sshHost: String?

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
        self.accentColorRGB = nil
        self.tint = 0.0
        self.appearance = .dark
        self.sshHost = nil
        self.pinnedPaths = []
        self.groupMeta = [:]
    }

    // Profiles saved before 0.11 carried brightness/lightText/vibrancy and
    // called the tint backgroundOpacity. Read those once; new saves write the
    // current keys only.
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, accentColorRGB, tint, appearance, sshHost, pinnedPaths, groupMeta
        case legacyBackgroundOpacity = "backgroundOpacity"
        case legacyBrightness = "brightness"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        accentColorRGB = try c.decodeIfPresent([Double].self, forKey: .accentColorRGB)
        sshHost = try c.decodeIfPresent(String.self, forKey: .sshHost)
        pinnedPaths = try c.decodeIfPresent([String].self, forKey: .pinnedPaths) ?? []
        groupMeta = try c.decodeIfPresent([String: GroupMeta].self, forKey: .groupMeta) ?? [:]

        tint = try c.decodeIfPresent(Double.self, forKey: .tint)
            ?? c.decodeIfPresent(Double.self, forKey: .legacyBackgroundOpacity)
            ?? 0.0
        if let appearance = try c.decodeIfPresent(ThemeAppearance.self, forKey: .appearance) {
            self.appearance = appearance
        } else if let brightness = try c.decodeIfPresent(Double.self, forKey: .legacyBrightness) {
            appearance = ThemeAppearance(legacyBrightness: brightness)
        } else {
            appearance = .dark
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(accentColorRGB, forKey: .accentColorRGB)
        try c.encode(tint, forKey: .tint)
        try c.encode(appearance, forKey: .appearance)
        try c.encodeIfPresent(sshHost, forKey: .sshHost)
        try c.encode(pinnedPaths, forKey: .pinnedPaths)
        try c.encode(groupMeta, forKey: .groupMeta)
    }

    mutating func captureTheme(from theme: SidebarTheme) {
        if let custom = theme.customAccent, let c = NSColor(custom).usingColorSpace(.deviceRGB) {
            accentColorRGB = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        } else {
            accentColorRGB = nil
        }
        tint = theme.tint
        appearance = theme.appearance
    }

    /// The stored custom accent, or nil for the system accent.
    var customAccent: Color? {
        guard let rgb = accentColorRGB, rgb.count == 3 else { return nil }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    var accentColor: Color {
        customAccent ?? Color(nsColor: .controlAccentColor)
    }
}
