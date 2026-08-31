import SwiftUI

/// The sezi.sh S-wave logo, redrawn as vector geometry from the site's SVG
/// (viewBox 476×631) so it can be scaled to any size and animated per capsule.
enum SezishGlyph {
    struct CapsuleSpec {
        let rect: CGRect
        let color: Color
    }

    static let viewBox = CGSize(width: 476, height: 631)
    static let cornerRadius: CGFloat = 30.68

    static let capsules: [CapsuleSpec] = [
        CapsuleSpec(rect: CGRect(x: 0.00, y: 234.79, width: 70.80, height: 161.16), color: Color(hex: 0xFFA700)),
        CapsuleSpec(rect: CGRect(x: 99.31, y: 150.46, width: 70.80, height: 303.16), color: Color(hex: 0xFF6B00)),
        CapsuleSpec(rect: CGRect(x: 197.42, y: 400.35, width: 70.80, height: 230.36), color: Color(hex: 0xFF3600)),
        CapsuleSpec(rect: CGRect(x: 305.95, y: 94.66, width: 70.80, height: 161.16), color: Color(hex: 0xFF0044)),
        CapsuleSpec(rect: CGRect(x: 404.65, y: 221.46, width: 70.80, height: 161.16), color: Color(hex: 0xFF0087)),
    ]

    /// Capsule scaled vertically around its own centre; end caps keep the brand
    /// radius until the capsule is too short to fit it.
    static func capsulePath(_ spec: CapsuleSpec, heightScale: CGFloat) -> Path {
        let height = spec.rect.height * heightScale
        let rect = CGRect(
            x: spec.rect.minX,
            y: spec.rect.midY - height / 2,
            width: spec.rect.width,
            height: height
        )
        return Path(roundedRect: rect, cornerRadius: min(cornerRadius, height / 2))
    }

    /// The static S stroke (#FF0000): top vertical in column 3, bottom vertical in
    /// column 4, a thick diagonal bridge between them. Coordinates from the SVG
    /// with its nested transforms flattened.
    static let sPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 197.90, y: 281.03))
        p.addCurve(to: CGPoint(x: 197.03, y: 272.48),
                   control1: CGPoint(x: 197.44, y: 277.26),
                   control2: CGPoint(x: 197.03, y: 275.07))
        p.addLine(to: CGPoint(x: 197.03, y: 30.68))
        p.addCurve(to: CGPoint(x: 227.71, y: 0),
                   control1: CGPoint(x: 197.03, y: 13.75),
                   control2: CGPoint(x: 210.78, y: 0))
        p.addLine(to: CGPoint(x: 237.15, y: 0))
        p.addCurve(to: CGPoint(x: 267.83, y: 30.68),
                   control1: CGPoint(x: 254.08, y: 0),
                   control2: CGPoint(x: 267.83, y: 13.75))
        p.addLine(to: CGPoint(x: 267.83, y: 261.99))
        p.addCurve(to: CGPoint(x: 270.67, y: 274.18),
                   control1: CGPoint(x: 267.91, y: 262.55),
                   control2: CGPoint(x: 267.93, y: 271.17))
        p.addCurve(to: CGPoint(x: 304.42, y: 302.23),
                   control1: CGPoint(x: 276.77, y: 280.88),
                   control2: CGPoint(x: 291.49, y: 291.81))
        p.addLine(to: CGPoint(x: 306.13, y: 303.15))
        p.addCurve(to: CGPoint(x: 372.28, y: 371.48),
                   control1: CGPoint(x: 334.18, y: 322.47),
                   control2: CGPoint(x: 363.38, y: 348.06))
        p.addCurve(to: CGPoint(x: 377.49, y: 395.68),
                   control1: CGPoint(x: 375.15, y: 379.04),
                   control2: CGPoint(x: 377.48, y: 393.03))
        p.addCurve(to: CGPoint(x: 377.49, y: 511.55),
                   control1: CGPoint(x: 377.51, y: 395.96),
                   control2: CGPoint(x: 377.49, y: 511.55))
        p.addCurve(to: CGPoint(x: 346.81, y: 542.23),
                   control1: CGPoint(x: 377.49, y: 528.48),
                   control2: CGPoint(x: 363.74, y: 542.23))
        p.addLine(to: CGPoint(x: 337.37, y: 542.23))
        p.addCurve(to: CGPoint(x: 306.69, y: 511.55),
                   control1: CGPoint(x: 320.43, y: 542.23),
                   control2: CGPoint(x: 306.69, y: 528.48))
        p.addCurve(to: CGPoint(x: 306.95, y: 402.81),
                   control1: CGPoint(x: 306.69, y: 511.55),
                   control2: CGPoint(x: 307.14, y: 403.35))
        p.addCurve(to: CGPoint(x: 277.15, y: 369.80),
                   control1: CGPoint(x: 301.65, y: 387.97),
                   control2: CGPoint(x: 288.66, y: 378.10))
        p.addCurve(to: CGPoint(x: 214.74, y: 319.71),
                   control1: CGPoint(x: 262.95, y: 359.56),
                   control2: CGPoint(x: 223.35, y: 330.46))
        p.addCurve(to: CGPoint(x: 197.90, y: 281.03),
                   control1: CGPoint(x: 207.64, y: 310.86),
                   control2: CGPoint(x: 200.11, y: 299.14))
        p.closeSubpath()
        return p
    }()

    static let sColor = Color(hex: 0xFF0000)

    /// The capsule palette as components, in left-to-right glyph order. All five sit
    /// on one warm arc (R is FF throughout), so lerping between neighbours stays
    /// clean — no muddy in-between hues.
    private static let colorRing: [(r: Double, g: Double, b: Double)] = [
        (1, 167 / 255, 0),        // #FFA700
        (1, 107 / 255, 0),        // #FF6B00
        (1, 54 / 255, 0),         // #FF3600
        (1, 0, 68 / 255),         // #FF0044
        (1, 0, 135 / 255),        // #FF0087
    ]

    /// Colour of capsule `index` when the ring is rotated by `phase` positions:
    /// at phase 0 every capsule wears its own colour, at phase 1 its neighbour's,
    /// with a smooth blend in between. Advance phase with time for the shimmer.
    static func cycledColor(index: Int, phase: Double) -> Color {
        let n = colorRing.count
        let shifted = phase.truncatingRemainder(dividingBy: Double(n))
        let k = Int(shifted)
        let frac = shifted - Double(k)
        let from = colorRing[(index + k) % n]
        let to = colorRing[(index + k + 1) % n]
        return Color(
            red: from.r + (to.r - from.r) * frac,
            green: from.g + (to.g - from.g) * frac,
            blue: from.b + (to.b - from.b) * frac
        )
    }

    /// Orbit the capsules gather onto when the glyph morphs into the spinner.
    static let orbitCenter = CGPoint(x: 238, y: 315.5)
    static let orbitRadius: CGFloat = 190

    /// Draws the full glyph into a Canvas context scaled to `size`.
    /// The S goes down first, capsules on top — the SVG's paint order.
    /// `breathingRoom` reserves vertical margin (as a factor of the viewBox height)
    /// so animated capsules can stretch past the tight viewBox without clipping.
    /// `morph` (0…1) melts each capsule into an equal dot on the orbit and fades
    /// the S stroke; `spin` rotates the orbit — together they turn the logo into
    /// the transcription spinner without swapping shapes.
    static func draw(
        in context: GraphicsContext,
        size: CGSize,
        capsuleScales: [CGFloat],
        breathingRoom: CGFloat = 1,
        capsuleColors: [Color]? = nil,
        morph: CGFloat = 0,
        spin: Double = 0
    ) {
        var context = context
        let scale = min(size.width / viewBox.width, size.height / (viewBox.height * breathingRoom))
        context.translateBy(
            x: (size.width - viewBox.width * scale) / 2,
            y: (size.height - viewBox.height * scale) / 2
        )
        context.scaleBy(x: scale, y: scale)
        if morph < 1 {
            context.fill(sPath, with: .color(sColor.opacity(Double(1 - morph))))
        }
        for (index, spec) in capsules.enumerated() {
            let heightScale = index < capsuleScales.count ? capsuleScales[index] : 1
            let color = capsuleColors?[index] ?? spec.color
            var center = CGPoint(x: spec.rect.midX, y: spec.rect.midY)
            var height = spec.rect.height * heightScale
            var radius = min(cornerRadius, height / 2)
            if morph > 0 {
                let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(capsules.count) + spin
                let target = CGPoint(
                    x: orbitCenter.x + orbitRadius * CGFloat(cos(angle)),
                    y: orbitCenter.y + orbitRadius * CGFloat(sin(angle))
                )
                center.x += (target.x - center.x) * morph
                center.y += (target.y - center.y) * morph
                height += (spec.rect.width - height) * morph
                radius += (height / 2 - radius) * morph
            }
            let rect = CGRect(
                x: center.x - spec.rect.width / 2,
                y: center.y - height / 2,
                width: spec.rect.width,
                height: height
            )
            context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
        }
    }
}

/// Static logo mark for headers: the full glyph at rest.
struct SezishLogoMark: View {
    var body: some View {
        Canvas { context, size in
            SezishGlyph.draw(in: context, size: size, capsuleScales: [])
        }
        .aspectRatio(SezishGlyph.viewBox.width / SezishGlyph.viewBox.height, contentMode: .fit)
    }
}
