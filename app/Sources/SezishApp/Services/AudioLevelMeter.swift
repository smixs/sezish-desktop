import Foundation
import SezishCore

/// Observable bridge between the realtime mic tap and the overlay UI: the tap pushes
/// raw RMS (~12 Hz), the auto level turns it into a 0…1 target relative to this
/// speaker's recent peak, and the wave view smooths it per-frame itself.
@Observable
final class AudioLevelMeter {
    private(set) var target: Float = 0
    /// How hard the wave moves; mirrored from settings by AppState.
    var intensity: WaveIntensity = .lively
    /// Kept across takes: it has learned this microphone and this room.
    @ObservationIgnored private var auto = AutoLevel()
    @ObservationIgnored private var lastPush: ContinuousClock.Instant?

    func push(rms: Float) {
        let now = ContinuousClock.now
        // Pushes arrive every ~85 ms; the first of a take learns as one such block.
        let dt = lastPush.map { Float((now - $0) / .seconds(1)) } ?? 1.0 / 12
        lastPush = now
        target = auto.step(loudness: AudioLevel.decibels(rms: rms), dt: min(dt, 0.25))
    }

    func reset() {
        target = 0
        lastPush = nil
    }
}
