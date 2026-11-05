import AppKit
import SezishCore

/// Plays the brand sounds. Instances are cached; the volume comes from settings
/// and applies to the next sound played.
@MainActor
final class SoundPlayer {
    var volume: Float = 0.5
    private var cache: [SoundEvent: NSSound] = [:]

    func play(_ event: SoundEvent) {
        let sound: NSSound?
        if let cached = cache[event] {
            sound = cached
        } else if let url = moduleResources.url(forResource: event.resourceName, withExtension: "caf"),
                  let loaded = NSSound(contentsOf: url, byReference: true) {
            cache[event] = loaded
            sound = loaded
        } else {
            sound = nil
        }
        sound?.stop()
        sound?.volume = volume
        sound?.play()
    }
}
