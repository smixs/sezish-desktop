import AppKit
import SwiftUI

/// Interactive HUD under the menu bar while a meeting records: pulsing record
/// mark, title, elapsed timer, Stop and Hide buttons. Reuses RecordingOverlay's
/// panel patterns (singleton panel, generation token, expo-out NSAnimationContext)
/// but accepts mouse events — without ever taking key focus.
@MainActor
final class RecordingPanel {
    private static let pillSize = NSSize(width: 272, height: 84)
    private static let shadowMargin: CGFloat = 16
    private static let topGap: CGFloat = 12
    private static let dropOffset: CGFloat = 8

    private var panel: NSPanel?
    private var hosting: NSHostingView<PanelContent>?
    private var generation = 0

    func show(
        startDate: Date,
        auto: Bool,
        strings: Strings,
        onStop: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        let content = PanelContent(
            startDate: startDate, auto: auto, strings: strings, onStop: onStop, onHide: onHide
        )
        let panel = ensurePanel(content)
        generation += 1
        hosting?.rootView = content

        let final = targetFrame()
        var start = final
        start.origin.y += Self.dropOffset // drop in from just above
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

    func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let expected = generation

        var up = panel.frame
        up.origin.y += Self.dropOffset
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(up, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                guard expected == self.generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    // MARK: - Panel

    private func ensurePanel(_ content: PanelContent) -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: content)
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
        panel.ignoresMouseEvents = false // the whole point: Stop/Hide are clickable
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting

        self.hosting = hosting
        self.panel = panel
        return panel
    }

    private static var panelContentSize: NSSize {
        NSSize(
            width: pillSize.width + shadowMargin * 2,
            height: pillSize.height + shadowMargin * 2
        )
    }

    private func targetFrame() -> NSRect {
        let size = Self.panelContentSize
        guard let screen = NSScreen.main else { return NSRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.maxX - Self.topGap - Self.pillSize.width - Self.shadowMargin,
            y: visible.maxY - Self.topGap - Self.pillSize.height - Self.shadowMargin,
            width: size.width,
            height: size.height
        )
    }
}

private struct PanelContent: View {
    let startDate: Date
    let auto: Bool
    let strings: Strings
    let onStop: () -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Brand.gradient)
                    .symbolEffect(.pulse, isActive: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(strings.meetingPanelTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Brand.hudText)
                    Text(auto ? strings.meetingPanelAuto : strings.meetingPanelManual)
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.hudText.opacity(0.55))
                }
                Spacer()
                TimelineView(.periodic(from: startDate, by: 1)) { timeline in
                    Text(Self.elapsed(from: startDate, to: timeline.date))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Brand.hudText)
                }
            }
            HStack(spacing: 8) {
                Button(strings.meetingStop, action: onStop)
                    .buttonStyle(BrandPrimaryButtonStyle(compact: true))
                Button(strings.meetingHide, action: onHide)
                    .buttonStyle(BrandSecondaryButtonStyle())
                Spacer()
            }
        }
        .padding(14)
        .frame(width: RecordingPanel.hudPillWidth, height: RecordingPanel.hudPillHeight)
        .background(Brand.hudBg, in: RoundedRectangle(cornerRadius: Brand.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.hudFaint, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark) // HUD is brand-dark, never follows the system
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension RecordingPanel {
    fileprivate static var hudPillWidth: CGFloat { pillSize.width }
    fileprivate static var hudPillHeight: CGFloat { pillSize.height }
}
