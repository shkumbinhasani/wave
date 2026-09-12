import SwiftUI
import Observation

/// The per-window theme: an accent (or the system's), how much it tints the
/// glass, and which appearance the window asks for. Text, separators, and
/// hover fills come from the system's semantic styles, so the window reads
/// correctly on whatever material sits behind it.
@Observable
final class SidebarTheme {
    /// Set by TerminalManager to persist theme changes back to the active profile.
    @ObservationIgnored var onThemeChanged: (() -> Void)?
    /// Fired when `appearance` changes (drives the terminal's color scheme).
    @ObservationIgnored var onAppearanceChanged: ((ThemeAppearance) -> Void)?
    /// True while loading values from a profile — suppresses change callbacks.
    @ObservationIgnored var isApplying = false
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    @ObservationIgnored private let store: ThemeStore

    /// nil = follow the system accent color.
    var customAccent: Color? { didSet { debouncedSave() } }
    /// How strongly the accent tints the glass, 0…1.
    var tint: Double { didSet { debouncedSave() } }
    var appearance: ThemeAppearance {
        didSet {
            if oldValue != appearance { onAppearanceChanged?(appearance) }
            debouncedSave()
        }
    }

    /// The accent in effect: the custom color, else the Mac's accent setting.
    var accentColor: Color {
        customAccent ?? Color(nsColor: .controlAccentColor)
    }

    var usesSystemAccent: Bool { customAccent == nil }

    static let presets: [Color] = [
        Color(red: 0.95, green: 0.65, blue: 0.75),
        Color(red: 0.7, green: 0.55, blue: 0.85),
        Color(red: 0.9, green: 0.4, blue: 0.4),
        Color(red: 1.0, green: 0.5, blue: 0.25),
        Color(red: 1.0, green: 0.78, blue: 0.25),
        Color(red: 0.25, green: 0.85, blue: 0.45),
        Color(red: 0.3, green: 0.65, blue: 1.0),
        Color(red: 0.4, green: 0.4, blue: 0.4),
    ]

    /// Inject a store to construct a theme in tests or previews without touching
    /// the shared UserDefaults. The app uses `.shared`, which defaults to the
    /// live store.
    init(store: ThemeStore = UserDefaultsThemeStore()) {
        self.store = store
        let snapshot = store.load()
        self.customAccent = snapshot.accentColor
        self.tint = snapshot.tint
        self.appearance = snapshot.appearance
    }

    func apply(from profile: Profile) {
        isApplying = true
        // Snap the appearance so text doesn't crossfade white↔black through
        // gray; animate the tint so the backdrop slides between profiles.
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) {
            appearance = profile.appearance
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            customAccent = profile.customAccent
            tint = profile.tint
        }
        isApplying = false
        flushSave()
    }

    private func debouncedSave() {
        guard !isApplying else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushSave()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func flushSave() {
        guard !isApplying else { return }
        store.save(ThemeSnapshot(
            accentColor: customAccent,
            tint: tint,
            appearance: appearance
        ))
        onThemeChanged?()
    }

    /// Index of the matching preset for the current custom accent, or nil.
    var matchingPresetIndex: Int? {
        guard let customAccent,
              let na = NSColor(customAccent).usingColorSpace(.deviceRGB) else { return nil }
        for (i, preset) in Self.presets.enumerated() {
            guard let nb = NSColor(preset).usingColorSpace(.deviceRGB) else { continue }
            if abs(na.redComponent - nb.redComponent) < 0.05
                && abs(na.greenComponent - nb.greenComponent) < 0.05
                && abs(na.blueComponent - nb.blueComponent) < 0.05 {
                return i
            }
        }
        return nil
    }
}

// MARK: - Theme Editor

/// Popover with native controls: an appearance picker, an accent row with the
/// system accent first, and a tint slider.
struct ThemeEditor: View {
    // Injected explicitly (not via environment): ThemeEditor is presented from
    // the sidebar, inside the detached NSHostingView — see note in Sidebar.
    // Each window passes its own theme instance.
    @Bindable var theme: SidebarTheme

    private var customAccentBinding: Binding<Color> {
        Binding(
            get: { theme.customAccent ?? Color(nsColor: .controlAccentColor) },
            set: { theme.customAccent = $0 }
        )
    }

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme.appearance) {
                Text("System").tag(ThemeAppearance.system)
                Text("Light").tag(ThemeAppearance.light)
                Text("Dark").tag(ThemeAppearance.dark)
            }
            .pickerStyle(.segmented)

            LabeledContent("Accent") {
                HStack(spacing: 8) {
                    accentSwatch(
                        Color(nsColor: .controlAccentColor),
                        selected: theme.usesSystemAccent,
                        help: "System accent"
                    ) {
                        theme.customAccent = nil
                    }
                    .overlay {
                        Image(systemName: "macwindow")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    let activeIndex = theme.matchingPresetIndex
                    ForEach(Array(SidebarTheme.presets.enumerated()), id: \.offset) { index, color in
                        accentSwatch(color, selected: index == activeIndex, help: nil) {
                            theme.customAccent = color
                        }
                    }

                    ColorPicker("Custom accent", selection: customAccentBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }

            LabeledContent("Tint") {
                Slider(value: $theme.tint, in: 0...1) {
                    Text("Tint")
                } minimumValueLabel: {
                    Image(systemName: "circle.dashed")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
                .labelsHidden()
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 340)
    }

    private func accentSwatch(_ color: Color, selected: Bool, help: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(.quaternary, lineWidth: 1)
                }
                .overlay {
                    if selected {
                        Circle().strokeBorder(.primary, lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}
