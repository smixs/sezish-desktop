import AppKit
import SwiftUI

/// Brand HUD at the bottom-center of the screen while dictation runs: a single
/// round button with the S-wave glyph dancing to the mic level. When the hotkey
/// is released the glyph morphs into a spinning ring and the HUD stays up until
/// the transcript is inserted. Always dark regardless of the system theme,
/// floats above full-screen apps and every Space, never takes focus.
@MainActor
final class RecordingOverlay {
    private static let circleSize = NSSize(width: 44, height: 44)
    /// Panel is larger than the circle so the rim glow isn't clipped at the edges.
    private static let glowMargin: CGFloat = 12
    private static let riseOffset: CGFloat = 8

    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayHUD>?
    /// Bumped on every show/hide; the hide completion checks it so a quick re-show
    /// isn't torn down by the tail of the previous animation.
    private var generation = 0

    func show(meter: AudioLevelMeter) {
        let panel = ensurePanel(meter: meter)
        generation += 1
        hosting?.rootView = OverlayHUD(meter: meter, isActive: true, transcribeStart: nil)

        let final = targetFrame()
        var start = final
        start.origin.y -= Self.riseOffset
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    /// Dictation ended, transcription started: the glyph gathers into the spinner.
    /// The panel itself doesn't move — hide() comes when the transcript lands.
    func beginTranscribing() {
        guard let panel, panel.isVisible, let hosting else { return }
        hosting.rootView = OverlayHUD(
            meter: hosting.rootView.meter,
            isActive: true,
            transcribeStart: Date()
        )
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let expected = generation

        var down = panel.frame
        down.origin.y -= Self.riseOffset
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(down, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                guard expected == self.generation else { return }
                panel.orderOut(nil)
                // Pause the wave's TimelineView while nothing is visible.
                if let hosting = self.hosting {
                    hosting.rootView = OverlayHUD(
                        meter: hosting.rootView.meter,
                        isActive: false,
                        transcribeStart: nil
                    )
                }
            }
        }
    }

    // MARK: - Panel

    /// The panel is created once and reused: tearing it down mid-animation is the
    /// race the generation token exists to avoid.
    private func ensurePanel(meter: AudioLevelMeter) -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(
            rootView: OverlayHUD(meter: meter, isActive: false, transcribeStart: nil))
        hosting.frame = NSRect(origin: .zero, size: Self.panelContentSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.contentView = hosting

        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private static var panelContentSize: NSSize {
        NSSize(width: circleSize.width + glowMargin * 2, height: circleSize.height + glowMargin * 2)
    }

    private func targetFrame() -> NSRect {
        let size = Self.panelContentSize
        guard let screen = NSScreen.main else { return NSRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            // The circle bottom sits at the same +80 the old overlay used.
            y: visible.minY + 80 - Self.glowMargin,
            width: size.width,
            height: size.height
        )
    }
}

private struct OverlayHUD: View {
    let meter: AudioLevelMeter
    let isActive: Bool
    /// Non-nil once the hotkey is released: the glyph morphs into the spinner.
    let transcribeStart: Date?

    var body: some View {
        SezishWaveView(meter: meter, isActive: isActive, transcribeStart: transcribeStart)
            .frame(width: 22, height: 28)
            .frame(width: RecordingOverlay.hudDiameter, height: RecordingOverlay.hudDiameter)
            .background(Brand.hudBg, in: Circle())
            .overlay(MetalRimView(isActive: isActive))
            // Neutral elevation shadow — the HUD floats above other apps; no neon.
            .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .dark) // HUD is brand-dark, never follows the system
    }
}

extension RecordingOverlay {
    fileprivate static var hudDiameter: CGFloat { circleSize.width }
}
