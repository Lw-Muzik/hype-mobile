import Foundation

/// Per-player values (track gain) kept by player id. A value set before the
/// player's engine exists is still stored, so it is applied when the engine is
/// created; a released id is remembered so a late set cannot bring it back.
/// Not thread-safe: the owner serialises access.
struct PlayerValueBook {
    private var values: [String: Float] = [:]
    private var released: Set<String> = []

    mutating func set(_ value: Float, for id: String) {
        if released.contains(id) { return }
        values[id] = value
    }

    func value(for id: String) -> Float? { values[id] }

    mutating func release(_ id: String) {
        released.insert(id)
        values[id] = nil
    }
}

/// Remembers the last value of every DSP setting so a freshly created engine
/// can be brought to the current state. Re-recording a key replaces its
/// closure in place, so replay order is the order keys were first recorded and
/// the log never grows past the number of distinct settings.
///
/// Pure Foundation: the closures take an opaque engine handle, which keeps the
/// log testable on the host with a fake engine.
final class DSPReplayLog {
    private var keys: [String] = []
    private var actions: [String: (UnsafeMutableRawPointer) -> Void] = [:]
    private let lock = NSLock()

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }

    func record(key: String, apply: @escaping (UnsafeMutableRawPointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if actions[key] == nil { keys.append(key) }
        actions[key] = apply
    }

    /// Drops every setting whose key starts with `prefix`. Used when one call
    /// supersedes a family of earlier ones (set-all-bands over set-one-band),
    /// so the superseding call replays after whatever is recorded later.
    func removeAll(withPrefix prefix: String) {
        lock.lock(); defer { lock.unlock() }
        keys.removeAll { $0.hasPrefix(prefix) }
        for k in actions.keys where k.hasPrefix(prefix) { actions[k] = nil }
    }

    func replay(onto engine: UnsafeMutableRawPointer) {
        lock.lock()
        let snapshot = keys.compactMap { actions[$0] }
        lock.unlock()
        for apply in snapshot { apply(engine) }
    }
}
