import AppKit

/// Plays the short start chimes. Instances are cached; volume stays low — these
/// fire on every recording, so they whisper rather than announce.
@MainActor
final class SoundPlayer {
    enum Chime: String {
        case dictation = "chime-dictation"
        case meeting = "chime-meeting"
    }

    private var cache: [Chime: NSSound] = [:]

    func play(_ chime: Chime) {
        let sound: NSSound?
        if let cached = cache[chime] {
            sound = cached
        } else if let url = moduleResources.url(forResource: chime.rawValue, withExtension: "caf"),
                  let loaded = NSSound(contentsOf: url, byReference: true) {
            loaded.volume = 0.35
            cache[chime] = loaded
            sound = loaded
        } else {
            sound = nil
        }
        sound?.stop()
        sound?.play()
    }
}
