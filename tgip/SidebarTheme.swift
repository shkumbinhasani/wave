import SwiftUI

class SidebarTheme: ObservableObject {
    static let shared = SidebarTheme()

    @Published var accentColor: Color { didSet { save() } }
    @Published var backgroundOpacity: Double { didSet { save() } }
    @Published var vibrancy: Double { didSet { save() } }
    /// 0 = dark, 1 = light
    @Published var brightness: Double { didSet { save() } }

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
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(backgroundOpacity, forKey: "t.bg")
        d.set(vibrancy, forKey: "t.vib")
        d.set(brightness, forKey: "t.bri")
        if let c = NSColor(accentColor).usingColorSpace(.deviceRGB) {
            d.set([c.redComponent, c.greenComponent, c.blueComponent], forKey: "t.acc")
        }
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
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 2)
                    .frame(width: 68, height: 68)
            }
            .padding(.bottom, 14)

            // Intensity +/-
            HStack(spacing: 20) {
                Button {
                    theme.backgroundOpacity = max(0, theme.backgroundOpacity - 0.05)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    theme.backgroundOpacity = min(1, theme.backgroundOpacity + 0.05)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)

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
                                    Circle().strokeBorder(Color.white, lineWidth: 2.5)
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

            // Vibrancy knob
            HStack(spacing: 14) {
                Image(systemName: "drop")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: geo.size.width * theme.vibrancy, height: 4)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .offset(x: (geo.size.width - 14) * theme.vibrancy)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { v in
                                        theme.vibrancy = min(1, max(0, v.location.x / geo.size.width))
                                    }
                            )
                    }
                }
                .frame(height: 14)

                Image(systemName: "drop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
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
                        .fill(theme.brightness == val ? Color.white.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(theme.brightness == val ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
    }
}
