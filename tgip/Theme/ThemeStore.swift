import SwiftUI
import AppKit

// Persistence seam for the theme. The model (`SidebarTheme`) talks to a
// `ThemeStore` instead of reaching into `UserDefaults` directly, so it can be
// constructed with an in-memory store in tests and previews — no global defaults
// to boot or pollute. Two adapters justify the seam: UserDefaults in the app,
// in-memory everywhere else.

/// Which appearance a profile asks for. `system` follows the Mac's setting.
enum ThemeAppearance: String, Codable, CaseIterable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Migration from the old 0…1 brightness slider: below the midpoint was
    /// dark, above was light.
    init(legacyBrightness: Double) {
        self = legacyBrightness < 0.5 ? .dark : .light
    }
}

/// A plain snapshot of the themable values. Carries no behavior — it is the
/// unit of exchange between the model and a store.
struct ThemeSnapshot: Equatable {
    /// nil = follow the system accent color.
    var accentColor: Color?
    /// How strongly the accent tints the glass, 0…1.
    var tint: Double
    var appearance: ThemeAppearance

    /// The look the app had before theming existed: untinted glass, dark.
    static let defaults = ThemeSnapshot(
        accentColor: nil,
        tint: 0.0,
        appearance: .dark
    )
}

protocol ThemeStore {
    func load() -> ThemeSnapshot
    func save(_ snapshot: ThemeSnapshot)
}

/// Live adapter: reads/writes the `t.*` keys, converting the accent color to and
/// from RGB components. Reads the pre-0.11 keys (`t.bri`, `t.lt`) once so an
/// existing theme keeps its light/dark choice.
struct UserDefaultsThemeStore: ThemeStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ThemeSnapshot {
        var snapshot = ThemeSnapshot.defaults
        snapshot.tint = defaults.object(forKey: "t.bg") as? Double ?? snapshot.tint
        if defaults.bool(forKey: "t.sysacc") {
            snapshot.accentColor = nil
        } else if let components = defaults.array(forKey: "t.acc") as? [Double], components.count == 3 {
            snapshot.accentColor = Color(red: components[0], green: components[1], blue: components[2])
        }
        if let raw = defaults.string(forKey: "t.app"), let appearance = ThemeAppearance(rawValue: raw) {
            snapshot.appearance = appearance
        } else if let brightness = defaults.object(forKey: "t.bri") as? Double {
            snapshot.appearance = ThemeAppearance(legacyBrightness: brightness)
        }
        return snapshot
    }

    func save(_ snapshot: ThemeSnapshot) {
        defaults.set(snapshot.tint, forKey: "t.bg")
        if let accent = snapshot.accentColor, let rgb = NSColor(accent).usingColorSpace(.deviceRGB) {
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent], forKey: "t.acc")
            defaults.set(false, forKey: "t.sysacc")
        } else {
            defaults.set(true, forKey: "t.sysacc")
        }
        defaults.set(snapshot.appearance.rawValue, forKey: "t.app")
    }
}

/// Test/preview adapter: keeps the last saved snapshot in memory.
final class InMemoryThemeStore: ThemeStore {
    private(set) var saved: ThemeSnapshot

    init(_ initial: ThemeSnapshot = .defaults) {
        self.saved = initial
    }

    func load() -> ThemeSnapshot { saved }
    func save(_ snapshot: ThemeSnapshot) { saved = snapshot }
}
