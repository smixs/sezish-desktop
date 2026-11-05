import CoreGraphics
import Foundation

/// Where the dictation HUD sits on screen.
public enum HUDPlacement: String, CaseIterable, Sendable {
    /// Bottom centre, above the Dock. The default.
    case bottom
    /// Just under the menu bar.
    case menuBar = "menu-bar"
    /// Out of the notch; under the menu bar on a screen without one.
    case notch
}

/// The HUD panel's frame for a placement. Pure geometry in screen points.
public enum HUDGeometry {
    /// Circle bottom above the visible frame's bottom edge (the Dock).
    public static let bottomLift: CGFloat = 80
    /// Circle top below the menu bar.
    public static let topGap: CGFloat = 10
    /// Circle top below the notch.
    public static let notchGap: CGFloat = 6

    /// `panel` includes `glowMargin` on every side; the circle is inside it.
    /// `notchHeight` is the screen's top safe-area inset, 0 without a notch.
    public static func frame(placement: HUDPlacement, panel: CGSize, glowMargin: CGFloat,
                             screen: CGRect, visible: CGRect, notchHeight: CGFloat) -> CGRect {
        let y: CGFloat
        var midX = visible.midX
        switch placement {
        case .notch where notchHeight > 0:
            y = screen.maxY - notchHeight - notchGap + glowMargin - panel.height
            midX = screen.midX
        case .menuBar, .notch:
            y = visible.maxY - topGap + glowMargin - panel.height
        case .bottom:
            y = visible.minY + bottomLift - glowMargin
        }
        return CGRect(x: midX - panel.width / 2, y: y, width: panel.width, height: panel.height)
    }

    /// The HUD rises in from below at the bottom and drops in from above at the top.
    public static func enterOffset(_ placement: HUDPlacement) -> CGFloat {
        placement == .bottom ? -8 : 8
    }
}
