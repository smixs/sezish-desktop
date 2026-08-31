import SwiftUI

/// Liquid-metal ring around the recording pill — the site's record-button bezel
/// brought into the app. The flow speed is strictly constant (voice animates the
/// glyph, never the metal), capped at 24 fps, and does zero work while the
/// panel is hidden. The stroke's own color doubles as the graceful fallback if
/// the shader library fails to load.
struct MetalRimView: View {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shader time must stay SMALL: absolute epoch seconds (~3e8) exceed float32's
    /// integer precision inside the shader, `p += dir * t` swallows the per-pixel
    /// term, and the plasma collapses into one flat palette stop (the uniform
    /// green rim). Time relative to the view's birth keeps t in single digits.
    @State private var born = Date()

    // Tuned by eye: 0.15 read as frozen, 0.22 as slow metal; 0.45 flows — a touch
    // past the site's 0.4 so the ring clearly lives at HUD size.
    private static let shaderSpeed = 0.45
    /// Static frame that reads well — the metal.js reduced-motion canon.
    private static let staticTime = 7.0
    // Hairline like the reference Upgrade button on metal.jakubantalik.com —
    // the thin ring is what makes it read as a machined bezel.
    private static let lineWidth: CGFloat = 1.25

    var body: some View {
        if reduceMotion {
            ring(time: Self.staticTime)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !isActive)) { timeline in
                ring(time: timeline.date.timeIntervalSince(born) * Self.shaderSpeed + Self.staticTime)
            }
        }
    }

    private func ring(time: Double) -> some View {
        GeometryReader { geo in
            Capsule()
                .strokeBorder(Color(hex: 0x3E4046), lineWidth: Self.lineWidth)
                .colorEffect(
                    ShaderLibrary.bundle(moduleResources).metalRim(
                        .float2(geo.size),
                        .float(time)
                    )
                )
        }
    }
}
