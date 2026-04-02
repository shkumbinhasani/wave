import SwiftUI

class SidebarTheme: ObservableObject {
    static let shared = SidebarTheme()

    /// Set by TerminalManager to persist theme changes back to the active profile.
    var onThemeChanged: (() -> Void)?
    /// True while loading values from a profile — suppresses change callbacks.
    var isApplying = false

    @Published var accentColor: Color { didSet { refreshPaletteAndSave() } }
    @Published var backgroundOpacity: Double { didSet { refreshPaletteAndSave() } }
    @Published var vibrancy: Double { didSet { refreshPaletteAndSave() } }
    /// 0 = dark, 1 = light
    @Published var brightness: Double { didSet { refreshPaletteAndSave() } }
    @Published var lightText: Bool { didSet { save() } }

    static let presets: [Color] = [
        .white,
        Color(red: 0.95, green: 0.65, blue: 0.75),
        Color(red: 0.7, green: 0.55, blue: 0.85),
        Color(red: 0.9, green: 0.4, blue: 0.4),
        Color(red: 1.0, green: 0.5, blue: 0.25),
        Color(red: 1.0, green: 0.78, blue: 0.25),
        Color(red: 0.25, green: 0.85, blue: 0.45),
        Color(red: 0.3, green: 0.65, blue: 1.0),
        Color(red: 0.5, green: 0.45, blue: 0.78),
        Color(red: 0.4, green: 0.4, blue: 0.4),
    ]

    private init() {
        let d = UserDefaults.standard
        // Defaults match the original look before theming existed
        self.backgroundOpacity = d.object(forKey: "t.bg") as? Double ?? 0.0
        self.vibrancy = d.object(forKey: "t.vib") as? Double ?? 1.0
        self.brightness = d.object(forKey: "t.bri") as? Double ?? 0.0
        if let c = d.array(forKey: "t.acc") as? [Double], c.count == 3 {
            self.accentColor = Color(red: c[0], green: c[1], blue: c[2])
        } else {
            self.accentColor = Color(red: 0.15, green: 0.15, blue: 0.15)
        }
        self.lightText = d.object(forKey: "t.lt") as? Bool ?? true
    }

    func adaptiveForeground(opacity: Double = 1) -> Color {
        (lightText ? Color.white : Color.black).opacity(Self.clamp(opacity))
    }

    func adaptiveScrim(opacity: Double = 1) -> Color {
        (lightText ? Color.black : Color.white).opacity(Self.clamp(opacity))
    }

    func apply(from profile: Profile) {
        isApplying = true
        withAnimation(.easeInOut(duration: 0.35)) {
            accentColor = profile.accentColor
            backgroundOpacity = profile.backgroundOpacity
            vibrancy = profile.vibrancy
            brightness = profile.brightness
            lightText = profile.lightText
        }
        isApplying = false
        save()
    }

    private func refreshPaletteAndSave() {
        save()
    }

    private func save() {
        guard !isApplying else { return }
        let d = UserDefaults.standard
        d.set(backgroundOpacity, forKey: "t.bg")
        d.set(vibrancy, forKey: "t.vib")
        d.set(brightness, forKey: "t.bri")
        if let c = NSColor(accentColor).usingColorSpace(.deviceRGB) {
            d.set([c.redComponent, c.greenComponent, c.blueComponent], forKey: "t.acc")
        }
        d.set(lightText, forKey: "t.lt")

        if !isApplying {
            onThemeChanged?()
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    func colorMatches(_ a: Color, _ b: Color) -> Bool {
        guard let na = NSColor(a).usingColorSpace(.deviceRGB),
              let nb = NSColor(b).usingColorSpace(.deviceRGB) else { return false }
        return abs(na.redComponent - nb.redComponent) < 0.05
            && abs(na.greenComponent - nb.greenComponent) < 0.05
            && abs(na.blueComponent - nb.blueComponent) < 0.05
    }
}

// MARK: - Theme Editor (Arc-style visual panel)

struct ThemeEditor: View {
    @ObservedObject var theme = SidebarTheme.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Brightness mode
            HStack(spacing: 20) {
                modeButton("sparkles", val: 0.0)
                modeButton("sun.max", val: 0.5)
                modeButton("moon", val: 1.0)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Big color preview
            ZStack {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 64, height: 64)
                    .shadow(color: theme.accentColor.opacity(0.5), radius: 20)
                Circle()
                    .strokeBorder(theme.adaptiveForeground(opacity: 0.3), lineWidth: 2)
                    .frame(width: 68, height: 68)
            }
            .padding(.bottom, 14)

            // Color dots
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SidebarTheme.presets, id: \.description) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 28, height: 28)
                            .overlay {
                                Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                            }
                            .overlay {
                                if theme.colorMatches(color, theme.accentColor) {
                                    Circle().strokeBorder(theme.adaptiveForeground(), lineWidth: 2.5)
                                        .frame(width: 32, height: 32)
                                }
                            }
                            .onTapGesture { theme.accentColor = color }
                    }

                    ColorPicker("", selection: $theme.accentColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 28, height: 28)
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 16)

            // Tint slider — 0% = fully transparent glass, 100% = flat solid color
            themeSlider(
                label: "Tint",
                icon1: "circle.dashed",
                icon2: "circle.fill",
                value: $theme.backgroundOpacity
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            // Blur slider — 0% = no blur, 100% = max blur
            themeSlider(
                label: "Blur",
                icon1: "aqi.low",
                icon2: "aqi.high",
                value: $theme.vibrancy
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Text color toggle
            HStack(spacing: 10) {
                Text("Text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 0) {
                    textToggleButton("Light", isActive: theme.lightText) { theme.lightText = true }
                    textToggleButton("Dark", isActive: !theme.lightText) { theme.lightText = false }
                }
                .background(Capsule().fill(.quaternary))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
    }

    private func themeSlider(label: String, icon1: String, icon2: String, value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon1)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.adaptiveForeground(opacity: 0.08))
                        .frame(height: 4)
                    Capsule()
                        .fill(theme.adaptiveForeground(opacity: 0.3))
                        .frame(width: geo.size.width * value.wrappedValue, height: 4)
                    Circle()
                        .fill(theme.adaptiveForeground(opacity: 0.94))
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .offset(x: (geo.size.width - 14) * value.wrappedValue)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    value.wrappedValue = min(1, max(0, v.location.x / geo.size.width))
                                }
                        )
                }
            }
            .frame(height: 14)

            Image(systemName: icon2)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
        }
    }

    private func modeButton(_ icon: String, val: Double) -> some View {
        Button {
            theme.brightness = val
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 40, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.brightness == val ? theme.adaptiveForeground(opacity: 0.15) : Color.clear)
                )
                .foregroundStyle(theme.brightness == val ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
    }

    private func textToggleButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isActive ? Capsule().fill(.secondary.opacity(0.3)) : nil)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
}
