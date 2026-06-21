//
//  Theme.swift
//  System Monitor Dashboard
//
//  Local-only telemetry styling. Dark "terminal telemetry" aesthetic,
//  teal accent, monospace key/numbers, panel cards with thin borders.
//

import SwiftUI

enum Theme {
    // Core palette — matches Part 3.2 exactly.
    static let background    = Color(hex: 0x0a0e14)
    static let panelFill     = Color(hex: 0x111722)
    static let panelBorder   = Color(hex: 0x1f2937)
    static let primaryText   = Color(hex: 0xe6edf3)
    static let mutedText     = Color(hex: 0x7d8590)
    static let accent        = Color(hex: 0x5eead4)
    static let accentDim     = Color(hex: 0x1f5f59)
    static let warning       = Color(hex: 0xfbbf24)
    static let danger        = Color(hex: 0xfb7185)

    // Fonts. SwiftUI doesn't support per-font fallback chains, so we use
    // SF Mono / Menlo (guaranteed present) with JetBrains Mono as an
    // optional custom face via .custom when installed.
    static let mono = Font.custom("JetBrains Mono", size: 12)
    static func mono(_ size: CGFloat) -> Font {
        Font.custom("JetBrains Mono", size: size)
    }

    // Sizing constants.
    static let cornerRadius: CGFloat = 6
    static let panelPadding: CGFloat = 12
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8)  & 0xff) / 255.0
        let b = Double( hex        & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Reusable panel container

struct Panel<Content: View>: View {
    let title: String?
    let accessory: AnyView?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = nil
        self.content = content
    }

    init<TitleAccessory: View>(title: String?,
                               @ViewBuilder titleAccessory: @escaping () -> TitleAccessory,
                               @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = AnyView(titleAccessory())
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = title {
                HStack {
                    Text(title)
                        .font(Theme.mono(10).bold())
                        .tracking(1.5)
                        .foregroundColor(Theme.mutedText)
                    Spacer()
                    if let accessory = accessory { accessory }
                }
            }
            content()
        }
        .padding(Theme.panelPadding)
        .background(Theme.panelFill)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.panelBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

// MARK: - Thin progress bar

struct TelemetryBar: View {
    /// 0...1
    let value: Double
    /// Force a specific tint regardless of value thresholds.
    var forcedTint: Color? = nil
    /// Treat NaN/nil as empty.
    var enabled: Bool = true

    private var tint: Color {
        if let forcedTint = forcedTint { return forcedTint }
        let pct = value
        if pct >= 0.90 { return Theme.danger }
        if pct >= 0.70 { return Theme.warning }
        return Theme.accent
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.panelBorder)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 2)
                    .fill(enabled ? tint : Theme.panelBorder)
                    .frame(width: max(0, min(1, value)) * geo.size.width, height: 6)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Flat button style

struct FlatButton: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(10).bold())
            .tracking(0.5)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? tint.opacity(0.15) : Color.clear)
            .foregroundColor(tint)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tint.opacity(configuration.isPressed ? 0.5 : 0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Status dot

struct StatusDot: View {
    let running: Bool
    var body: some View {
        Circle()
            .fill(running ? Theme.accent : Theme.mutedText)
            .frame(width: 8, height: 8)
            .shadow(color: running ? Theme.accent.opacity(0.6) : .clear, radius: 3)
    }
}
