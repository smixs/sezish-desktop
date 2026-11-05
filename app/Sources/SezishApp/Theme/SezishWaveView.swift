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

    /// Radians of lag per column; ~1 rad puts a bit over half a wavelength across
    /// the five capsules, so one rolling crest is always visible. The crest's speed
    /// and height come from the meter's `WaveIntensity` and grow with the voice.
    private static let phaseStep: Double = 1.05
    /// Per-capsule share of the swing: near-uniform keeps the travelling waveform
    /// clean; the tall capsule swings a touch less so it doesn't dominate.
    private static let weights: [Double] = [1.0, 0.73, 0.91, 1.0, 0.91]
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
                    let intensity = meter.intensity
                    let step = min(max(dt, 0), 0.1)
                    let level = clock.level(target: meter.target, dt: step, intensity: intensity)
                    // Integrate the phase so a speed change never jumps the crest.
                    clock.phase += 2 * .pi * intensity.frequency(level: Double(level)) * Double(step)

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
                        let osc = sin(clock.phase - Self.phaseStep * Double(i))
                        let scale = intensity.capsuleScale(level: Double(level) * Self.weights[i], oscillation: osc)
                        return 1 + (CGFloat(scale) - 1) * (1 - morph)
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
    var phase: Double = 0
    private var intensity: WaveIntensity?
    private var follower = LevelSmoother()

    /// Steps the level follower, rebuilt with the intensity's attack and release
    /// whenever the setting changes.
    func level(target: Float, dt: Float, intensity: WaveIntensity) -> Float {
        if self.intensity != intensity {
            self.intensity = intensity
            follower = LevelSmoother(attackTau: intensity.attack, releaseTau: intensity.release)
        }
        return follower.step(target: target, dt: dt)
    }
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
