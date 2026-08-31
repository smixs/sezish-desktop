import AppKit
import SwiftUI

/// sezi.sh design tokens. Dark values are the site palette verbatim; light values
/// are a warm-stone derivation. `red` is shared across themes, and every shadow in
/// the app is red-tinted — the brand has no neutral shadows.
enum Brand {
    static let bg = dynamic(dark: 0x0C0A09, light: 0xFAF9F7)
    static let bgSoft = dynamic(dark: 0x14110F, light: 0xF2F0EC)
    static let text = dynamic(dark: 0xF5F5F4, light: 0x0C0A09)
    static let muted = dynamic(dark: 0xF5F5F4, darkAlpha: 0.46, light: 0x0C0A09, lightAlpha: 0.50)
    /// 1px borders everywhere, per the site.
    static let faint = dynamic(dark: 0xF5F5F4, darkAlpha: 0.10, light: 0x0C0A09, lightAlpha: 0.10)
    /// Row hover wash (the site hovers rows with a faint lift, not a color shift).
    static let hover = dynamic(dark: 0xF5F5F4, darkAlpha: 0.07, light: 0x0C0A09, lightAlpha: 0.05)
    static let red = Color(hex: 0xED1C24)
    /// The only shadow tint the brand allows.
    static let glow = Color(hex: 0xED1C24, alpha: 0.4)

    /// Site canonical: linear-gradient(100deg, #FFA700 0%, #FF3600 55%, #FF0087 100%).
    static let gradientStops: [Gradient.Stop] = [
        .init(color: Color(hex: 0xFFA700), location: 0.00),
        .init(color: Color(hex: 0xFF3600), location: 0.55),
        .init(color: Color(hex: 0xFF0087), location: 1.00),
    ]
    /// ~100deg: left→right with a slight downward tip.
    static let gradient = LinearGradient(
        stops: gradientStops,
        startPoint: UnitPoint(x: 0, y: 0.30),
        endPoint: UnitPoint(x: 1, y: 0.70)
    )
    /// Solid accent for native controls that cannot take a gradient
    /// (switch tint, radio dots, 1px borders, focus). Mid-stop of the ramp.
    static let accent = Color(hex: 0xFF3600)

    // The recording overlay is a HUD: always dark regardless of the system theme.
    static let hudBg = Color(hex: 0x14110F, alpha: 0.92)
    static let hudText = Color(hex: 0xF5F5F4)
    static let hudFaint = Color(hex: 0xF5F5F4, alpha: 0.10)

    enum Radius {
        static let card: CGFloat = 16
        static let small: CGFloat = 12
        static let control: CGFloat = 10
        static let tiny: CGFloat = 8
    }

    private static func dynamic(
        dark: UInt32, darkAlpha: CGFloat = 1,
        light: UInt32, lightAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: alpha))
    }
}

extension Animation {
    /// Site easing: cubic-bezier(0.16, 1, 0.3, 1), expo-out.
    static let brandExpoOut = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.28)
    static let brandExpoOutFast = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
}
