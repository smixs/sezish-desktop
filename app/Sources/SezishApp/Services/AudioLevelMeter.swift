import Foundation
import SezishCore

/// Observable bridge between the realtime mic tap and the overlay UI: the tap pushes
/// raw RMS (~12 Hz), the wave view reads a normalized 0…1 target and smooths it
/// per-frame itself.
@Observable
final class AudioLevelMeter {
    private(set) var target: Float = 0

    func push(rms: Float) {
        target = AudioLevel.normalize(rms: rms)
    }

    func reset() {
        target = 0
    }
}
