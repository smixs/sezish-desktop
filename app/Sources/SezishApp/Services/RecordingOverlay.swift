import AppKit
import SwiftUI
import SezishCore

/// Brand HUD on screen while dictation runs (bottom centre by default, or at
/// the top: `placement`): a single
/// round button with the S-wave glyph dancing to the mic level. When the hotkey
/// is released the glyph morphs into a spinning ring and the HUD stays up until
/// the transcript is inserted. A take that went wrong widens the circle into a
/// pill with a few words for a moment (`showNotice`), as hex does. Always dark
/// regardless of the system theme, floats above full-screen apps and every
/// Space, never takes focus.
@MainActor
final class RecordingOverlay {
    private static let circleSize = NSSize(width: 44, height: 44)
    /// Panel is larger than the circle so the rim glow isn't clipped at the edges.
    private static let glowMargin: CGFloat = 12
    /// Where it sits; read at the next show.
    var placement: HUDPlacement = .bottom
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Reduce Motion keeps the fade and drops the travel.
    private var enterOffset: CGFloat { reduceMotion ? 0 : HUDGeometry.enterOffset(placement) }

    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayHUD>?
    /// Bumped on every show/hide; the hide completion checks it so a quick re-show
    /// isn't torn down by the tail of the previous animation.
    private var generation = 0
    private var onNoticeClick: (() -> Void)?

    func show(meter: AudioLevelMeter) {
        let panel = ensurePanel(meter: meter)
        generation += 1
        onNoticeClick = nil
        panel.ignoresMouseEvents = true
        hosting?.rootView = OverlayHUD(meter: meter, isActive: true, transcribeStart: nil)

        let final = targetFrame()
        var start = final
        start.origin.y += enterOffset
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

    /// The circle widens into a pill with `text`, holds it for `duration`, then
    /// goes. A non-nil `onClick` makes the pill a button.
    func showNotice(_ text: String, duration: TimeInterval, meter: AudioLevelMeter,
                    onClick: (() -> Void)?) {
        let panel = ensurePanel(meter: meter)
        generation += 1
        let expected = generation
        onNoticeClick = onClick
        let wide = frame(width: Self.pillWidth(for: text))
        if !panel.isVisible {
            // Nothing on screen yet (the take never started): rise in as the circle first.
            var start = targetFrame()
            start.origin.y += enterOffset
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        hosting?.rootView = OverlayHUD(meter: meter, isActive: true, transcribeStart: nil,
                                       notice: text, onClick: onClick == nil ? nil : { [weak self] in
                                           self?.noticeClicked()
                                       })
        // Clicks are taken only while there is something to click, and only on the
        // pill: the panel shrinks to it.
        panel.ignoresMouseEvents = onClick == nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(wide, display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, expected == self.generation else { return }
            self.hide()
        }
    }

    private func noticeClicked() {
        let action = onNoticeClick
        hide()
        action?()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let expected = generation
        onNoticeClick = nil
        panel.ignoresMouseEvents = true

        var down = panel.frame
        down.origin.y += enterOffset
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

    fileprivate static let noticeFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    fileprivate static let noticeIconWidth: CGFloat = 14
    fileprivate static let noticeSpacing: CGFloat = 7
    fileprivate static let noticePadding: CGFloat = 16

    /// The pill fits its text in one line, never narrower than the circle.
    private static func pillWidth(for text: String) -> CGFloat {
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: noticeFont]).width)
        return max(circleSize.width, noticePadding * 2 + noticeIconWidth + noticeSpacing + textWidth)
    }

    private func targetFrame() -> NSRect { frame(width: Self.circleSize.width) }

    /// The panel around a HUD `width` wide, where `placement` puts the circle.
    private func frame(width: CGFloat) -> NSRect {
        let size = NSSize(width: width + Self.glowMargin * 2, height: Self.panelContentSize.height)
        guard let screen = NSScreen.main else { return NSRect(origin: .zero, size: size) }
        return HUDGeometry.frame(placement: placement, panel: size, glowMargin: Self.glowMargin,
                                 screen: screen.frame, visible: screen.visibleFrame,
                                 notchHeight: screen.safeAreaInsets.top)
    }
}

private struct OverlayHUD: View {
    let meter: AudioLevelMeter
    let isActive: Bool
    /// Non-nil once the hotkey is released: the glyph morphs into the spinner.
    let transcribeStart: Date?
    /// Non-nil while the HUD is a pill saying what went wrong.
    var notice: String?
    var onClick: (() -> Void)?

    var body: some View {
        ZStack {
            if let notice {
                HStack(spacing: RecordingOverlay.noticeSpacing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.red)
                        .frame(width: RecordingOverlay.noticeIconWidth)
                    Text(notice)
                        .font(Font(RecordingOverlay.noticeFont))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, RecordingOverlay.noticePadding)
                .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
            } else {
                SezishWaveView(meter: meter, isActive: isActive, transcribeStart: transcribeStart)
                    .frame(width: 22, height: 28)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        // The capsule fills the panel: the panel's own frame animation is what
        // widens the circle into the pill.
        .frame(maxWidth: .infinity)
        .frame(height: RecordingOverlay.hudDiameter)
        .background(Brand.hudBg, in: Capsule())
        // No drop shadow (Serge, 2026-11-05): the metal rim alone separates
        // the HUD from whatever is under it.
        .overlay(MetalRimView(isActive: isActive))
        .contentShape(Capsule())
        .onTapGesture { onClick?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onClick == nil ? [] : .isButton)
        .padding(RecordingOverlay.glowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark) // HUD is brand-dark, never follows the system
    }
}

extension RecordingOverlay {
    fileprivate static var hudDiameter: CGFloat { circleSize.width }
    fileprivate static var glowInset: CGFloat { glowMargin }
}
