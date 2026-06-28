import SwiftUI
import AppKit

// Persistence seam for the theme. The model (`SidebarTheme`) talks to a
// `ThemeStore` instead of reaching into `UserDefaults` directly, so it can be
// constructed with an in-memory store in tests and previews — no global defaults
// to boot or pollute. Two adapters justify the seam: UserDefaults in the app,
// in-memory everywhere else.

/// A plain snapshot of the five themable values. Carries no behavior — it is the
/// unit of exchange between the model and a store.
struct ThemeSnapshot: Equatable {
    var accentColor: Color
    var backgroundOpacity: Double
    var vibrancy: Double
    var brightness: Double
    var lightText: Bool

    /// The look the app had before theming existed.
    static let defaults = ThemeSnapshot(
        accentColor: Color(red: 0.15, green: 0.15, blue: 0.15),
        backgroundOpacity: 0.0,
        vibrancy: 1.0,
        brightness: 0.0,
        lightText: true
    )
}

protocol ThemeStore {
    func load() -> ThemeSnapshot
    func save(_ snapshot: ThemeSnapshot)
}

/// Live adapter: reads/writes the `t.*` keys, converting the accent color to and
/// from RGB components.
struct UserDefaultsThemeStore: ThemeStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ThemeSnapshot {
        var snapshot = ThemeSnapshot.defaults
        snapshot.backgroundOpacity = defaults.object(forKey: "t.bg") as? Double ?? snapshot.backgroundOpacity
        snapshot.vibrancy = defaults.object(forKey: "t.vib") as? Double ?? snapshot.vibrancy
        snapshot.brightness = defaults.object(forKey: "t.bri") as? Double ?? snapshot.brightness
        if let components = defaults.array(forKey: "t.acc") as? [Double], components.count == 3 {
            snapshot.accentColor = Color(red: components[0], green: components[1], blue: components[2])
        }
        snapshot.lightText = defaults.object(forKey: "t.lt") as? Bool ?? snapshot.lightText
        return snapshot
    }

    func save(_ snapshot: ThemeSnapshot) {
        defaults.set(snapshot.backgroundOpacity, forKey: "t.bg")
        defaults.set(snapshot.vibrancy, forKey: "t.vib")
        defaults.set(snapshot.brightness, forKey: "t.bri")
        if let rgb = NSColor(snapshot.accentColor).usingColorSpace(.deviceRGB) {
            defaults.set([rgb.redComponent, rgb.greenComponent, rgb.blueComponent], forKey: "t.acc")
        }
        defaults.set(snapshot.lightText, forKey: "t.lt")
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
