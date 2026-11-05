/// The one loaded copy of the local model, shared by dictation and meetings.
///
/// A copy costs ~600 MB, and it lives as long as anything holds it. Before this, a meeting
/// cached its own reference forever: a rebuild of dictation (language, mode, smart mode)
/// loaded a second copy next to it, and in cloud dictation the meeting's copy never left.
/// Model: specs/tla/LocalEngine.tla.
public struct LocalEngineSlot<Key: Equatable, Engine> {
    private var current: (key: Key, engine: Engine)?
    /// The copy a meeting job runs on, and how many jobs do. Kept reachable so switching
    /// the model there and back mid-meeting finds it instead of loading a twin.
    private var pinned: (key: Key, engine: Engine)?
    private var pins = 0

    public init() {}

    /// Which model the slot holds, nil when it holds none.
    public var loadedKey: Key? { current?.key }

    /// The copy of `key` already in memory, or a fresh one from `load`. A different model
    /// replaces the held one; a failed load leaves the slot empty for the next try.
    public mutating func engine(for key: Key, load: () -> Engine?) -> Engine? {
        if let current, current.key == key { return current.engine }
        if let pinned, pinned.key == key {
            current = pinned
            return pinned.engine
        }
        current = nil
        guard let engine = load() else { return nil }
        current = (key, engine)
        return engine
    }

    /// The copy a meeting job (live take, retry, salvage) runs on; held until `unpin`.
    public mutating func pin(for key: Key, load: () -> Engine?) -> Engine? {
        guard let engine = engine(for: key, load: load) else { return nil }
        pinned = (key, engine)
        pins += 1
        return engine
    }

    /// A meeting job is done with its copy.
    public mutating func unpin(dictationIsLocal: Bool) {
        pins = max(pins - 1, 0)
        if pins == 0 { pinned = nil }
        releaseIfIdle(dictationIsLocal: dictationIsLocal)
    }

    /// Lets the copy go when neither dictation nor a meeting job runs on it.
    public mutating func releaseIfIdle(dictationIsLocal: Bool) {
        guard !dictationIsLocal, pins == 0 else { return }
        current = nil
    }
}
