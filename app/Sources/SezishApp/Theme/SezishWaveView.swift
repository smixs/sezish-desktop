import SwiftUI
import SezishCore

/// The animated logo: capsules breathe with the mic level. Silence keeps the glyph
/// at rest; speech modulates gentle per-capsule sine waves (±14–22 % of the base
/// height) with individual frequencies/phases, so every capsule lives but none
/// jumps. When `transcribeStart` is set the capsules gather into five equal dots
/// on a circular orbit and spin — the logo itself becomes the transcription
/// spinner — until the overlay hides.
struct SezishWaveView: View {
    let meter: AudioLevelMeter
    let isActive: Bool
    /// Moment dictation ended and transcription began; nil while listening.
    var transcribeStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = WaveClock()

    /// One shared rhythm, phase-shifted per column: the crest travels across the
    /// glyph as an actual wave instead of five bars twitching independently.
    /// Cohesion over detune — the Kowalski rule that motion should read as one
    /// gesture, not competing ones.
    private static let waveFrequency: Double = 1.1
    /// Radians of lag per column; ~1 rad puts a bit over half a wavelength across
    /// the five capsules, so one rolling crest is always visible.
    private static let phaseStep: Double = 1.05
    // Sized for a ~26 pt glyph: smaller swings vanish at that scale, smoothness
    // comes from the low frequency and the level smoothing, not tiny amplitude.
    // Near-uniform relative amplitude keeps the travelling waveform clean; the
    // tall capsule swings a touch less so it doesn't dominate.
    private static let amplitudes: [CGFloat] = [0.55, 0.40, 0.50, 0.55, 0.50]
    /// Vertical margin the glyph is drawn with, so stretched capsules never clip.
    private static let breathingRoom: CGFloat = 1.5
    /// Ring positions per second for the colour shimmer: each capsule takes ~0.8 s
    /// to melt into its neighbour's colour, a full lap of the palette in ~4 s —
    /// the shimmer is the "I'm working" signal, so it stays clearly alive.
    private static let shimmerSpeed: Double = 1.25
    /// Logo → spinner morph. Strong ease-out (~cubic-bezier(0.23, 1, 0.32, 1)):
    /// a state change must read fast, so the gather lands inside 300 ms.
    private static let morphDuration: Double = 0.3
    /// Spinner revolutions per second once the dots have gathered.
    private static let spinSpeed: Double = 1.0

    var body: some View {
        if reduceMotion {
            if transcribeStart != nil {
                // State indication survives Reduce Motion; the system spinner is
                // the canonical gentle variant.
                ProgressView()
                    .controlSize(.small)
                    .tint(Brand.hudText)
            } else {
                ReducedMotionGlyph(isActive: isActive)
            }
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: !isActive)) { timeline in
                Canvas { context, size in
                    let now = timeline.date
                    let dt = clock.lastDate.map { Float(now.timeIntervalSince($0)) } ?? 0
                    clock.lastDate = now
                    // The frame clock stops while the panel is hidden; cap dt so the
                    // first frame after a pause doesn't teleport the level.
                    let level = clock.smoother.step(target: meter.target, dt: min(max(dt, 0), 0.1))

                    var morph: CGFloat = 0
                    var spin: Double = 0
                    if let start = transcribeStart {
                        let elapsed = max(0, now.timeIntervalSince(start))
                        let raw = min(elapsed / Self.morphDuration, 1)
                        morph = CGFloat(1 - pow(1 - raw, 4))
                        // Scaling by morph eases the rotation in while the dots are
                        // still travelling, so the gather reads as one swirl.
                        spin = 2 * .pi * Self.spinSpeed * elapsed * Double(morph)
                    }

                    let t = now.timeIntervalSinceReferenceDate
                    let scales = SezishGlyph.capsules.indices.map { i -> CGFloat in
                        let osc = sin(2 * .pi * Self.waveFrequency * t - Self.phaseStep * Double(i))
                        return 1 + CGFloat(level) * Self.amplitudes[i] * osc * (1 - morph)
                    }
                    // The shimmer runs regardless of voice level — colour says
                    // "listening", height says "hearing you". The spinner keeps it:
                    // colour is also its "still working" signal.
                    let shimmerPhase = t * Self.shimmerSpeed
                    let colors = SezishGlyph.capsules.indices.map {
                        SezishGlyph.cycledColor(index: $0, phase: shimmerPhase)
                    }
                    SezishGlyph.draw(
                        in: context,
                        size: size,
                        capsuleScales: scales,
                        breathingRoom: Self.breathingRoom,
                        capsuleColors: colors,
                        morph: morph,
                        spin: spin
                    )
                }
            }
        }
    }
}

/// Frame-to-frame state the Canvas closure may mutate without invalidating the view.
private final class WaveClock {
    var lastDate: Date?
    // Softer than the defaults: the wave should swell and settle, not twitch at
    // the ~12 Hz cadence RMS targets arrive at.
    var smoother = LevelSmoother(attackTau: 0.09, releaseTau: 0.35)
}

/// Reduce Motion fallback: the glyph at rest with a soft opacity pulse.
private struct ReducedMotionGlyph: View {
    let isActive: Bool
    @State private var dimmed = false

    var body: some View {
        SezishLogoMark()
            .opacity(dimmed ? 0.65 : 1)
            .task(id: isActive) {
                guard isActive else {
                    dimmed = false
                    return
                }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}
