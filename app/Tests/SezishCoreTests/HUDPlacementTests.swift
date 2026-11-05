import CoreGraphics
import Foundation
import Testing
@testable import SezishCore

/// Where the dictation HUD sits: bottom centre by default, or under the menu
/// bar, or out of the notch (under the menu bar on a screen without one).
struct HUDPlacementTests {
    // A 1512×982 laptop screen, menu bar 37 pt (notch 32 pt), Dock 70 pt.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 875)
    private let panel = CGSize(width: 68, height: 68)
    private let margin: CGFloat = 12

    private func frame(_ placement: HUDPlacement, notch: CGFloat = 32) -> CGRect {
        HUDGeometry.frame(placement: placement, panel: panel, glowMargin: margin,
                          screen: screen, visible: visible, notchHeight: notch)
    }

    @Test func bottomKeepsTheCircle80ptAboveTheDock() {
        let f = frame(.bottom)
        #expect(f.minY + margin == visible.minY + 80)
        #expect(f.midX == visible.midX)
        #expect(f.size == panel)
    }

    @Test func menuBarHangsJustUnderIt() {
        let f = frame(.menuBar)
        #expect(f.maxY - margin == visible.maxY - HUDGeometry.topGap)
        #expect(f.midX == visible.midX)
    }

    @Test func notchGrowsOutOfTheNotchOrFallsBackToTheMenuBar() {
        let f = frame(.notch)
        #expect(f.maxY - margin == screen.maxY - 32 - HUDGeometry.notchGap)
        #expect(f.midX == screen.midX)
        #expect(frame(.notch, notch: 0) == frame(.menuBar, notch: 0))
    }

    @Test func itEntersFromItsOwnEdge() {
        #expect(HUDGeometry.enterOffset(.bottom) < 0)
        #expect(HUDGeometry.enterOffset(.menuBar) > 0)
        #expect(HUDGeometry.enterOffset(.notch) > 0)
    }

    @Test func theSettingDefaultsToBottom() {
        let defaults = UserDefaults(suiteName: "hud-placement-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.hudPlacement == .bottom)
        settings.hudPlacement = .notch
        #expect(settings.hudPlacement == .notch)
        defaults.set("sideways", forKey: "hudPlacement")
        #expect(settings.hudPlacement == .bottom)
    }
}
