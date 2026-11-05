import Foundation
import AVFoundation
import Flutter

/// Owns the C++ DSP engines — one per just_audio player — and fans parameter
/// updates out to all of them.
///
/// A tap (HypeAudioTap.m) asks for its player's engine through `acquireEngine`
/// the first time that player installs a tap; the engine is then reused for
/// every item the player plays. Every global setter applies to all engines and
/// records itself in a replay log, so an engine created later starts at the
/// current state. Per-player settings (track gain) are kept per player id.
class DSPManager {
    static let shared = DSPManager()

    private var sampleRate: Int = 48000
    private var channels: Int = 2

    /// One engine plus the taps still using it. A released player's record
    /// leaves `registry` at once but its engine is destroyed only when the last
    /// tap has let go, so a tap never processes through freed memory.
    private final class EngineRecord {
        let playerId: String
        let handle: UnsafeMutableRawPointer
        /// Written by a tap's audio thread at a gapless boundary (lock-free);
        /// read under the manager's lock. Freed with the engine.
        let gainCell: UnsafeMutablePointer<HypeGainCell>
        var refs = 0
        var retired = false
        init(playerId: String, handle: UnsafeMutableRawPointer) {
            self.playerId = playerId
            self.handle = handle
            gainCell = UnsafeMutablePointer<HypeGainCell>.allocate(capacity: 1)
            gainCell.initialize(to: HypeGainCell(db: 0, set: 0))
        }
    }

    /// The gain waiting for each upcoming queue item of a player, by the URL
    /// its tap carries. Latest per URL wins; a handful at most.
    private var nextGains: [String: [(uri: String, dB: Float)]] = [:]
    private let maxNextGains = 4

    /// Destroys a retired engine and frees its cell. Not under the lock.
    private func destroy(_ record: EngineRecord) {
        dsp_destroy(record.handle)
        record.gainCell.deallocate()
    }

    private let log = DSPReplayLog()
    /// One lock serialises everything that touches engines or the log: setter
    /// fan-out, replay after a reinit, engine creation. Engine setters are not
    /// themselves thread-safe, and a replay must not overwrite a newer value.
    private let lock = NSLock()
    private var registry: [String: EngineRecord] = [:]
    private var byHandle: [UnsafeMutableRawPointer: EngineRecord] = [:]
    private var trackGains = PlayerValueBook()

    // Cached preamp for getter
    private(set) var cachedPreampGain: Float = 0.0
    private(set) var cachedMbcEnabled: Bool = false

    private var volumeObservation: NSKeyValueObservation?

    private init() {}

    /// Feeds the system output volume (as dB) to every engine, now and on
    /// each volume change. Safe to call more than once.
    private func startSystemVolumeObservation() {
        if volumeObservation != nil { return }
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.initial, .new]
        ) { _, change in
            guard let v = change.newValue else { return }
            DSPManager.shared.setSystemVolumeDb(SystemVolume.db(fromOutputVolume: v))
        }
    }

    /// Records the session format and wires the tap to this registry.
    func initialize(sampleRate: Int = 48000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        let tap = HypeAudioTap.shared()
        tap.engineAcquire = { playerId in DSPManager.shared.acquireEngine(playerId: playerId) }
        tap.engineRelease = { handle in DSPManager.shared.releaseEngine(handle) }
        tap.engineReinitialised = { handle in DSPManager.shared.engineReinitialised(handle) }
        tap.playerReleased = { playerId in DSPManager.shared.releasePlayer(playerId: playerId) }
        tap.keyNormaliser = { uri in NextGainKey.normalize(uri) }
        tap.engineGainCell = { handle in DSPManager.shared.gainCell(for: handle) }
        tap.nextGainLookup = { handle, uri, out in
            DSPManager.shared.nextGain(for: handle, uri: uri, into: out)
        }
        startSystemVolumeObservation()
    }

    /// The engine for `playerId`, created on first use and brought to the
    /// current global state, with a tap reference taken. nil if the engine
    /// cannot be created (the tap then leaves audio untouched).
    func acquireEngine(playerId: String) -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        let record: EngineRecord
        if let existing = registry[playerId] {
            record = existing
        } else {
            guard let h = dsp_create(Int32(sampleRate), Int32(channels)) else { return nil }
            record = EngineRecord(playerId: playerId, handle: h)
            registry[playerId] = record
            byHandle[h] = record
            replayState(onto: record)
        }
        record.refs += 1
        return record.handle
    }

    /// A tap let go of its engine (finalized, or failed to start).
    func releaseEngine(_ handle: UnsafeMutableRawPointer) {
        lock.lock()
        guard let record = byHandle[handle] else { lock.unlock(); return }
        record.refs -= 1
        let dead = record.retired && record.refs <= 0
        if dead { byHandle[handle] = nil }
        lock.unlock()
        if dead { destroy(record) }
    }

    /// The player was disposed: forget it now; destroy once no tap uses it.
    func releasePlayer(playerId: String) {
        lock.lock()
        trackGains.release(playerId)
        nextGains[playerId] = nil
        guard let record = registry.removeValue(forKey: playerId) else { lock.unlock(); return }
        record.retired = true
        let dead = record.refs <= 0
        if dead { byHandle[record.handle] = nil }
        lock.unlock()
        if dead { destroy(record) }
    }

    /// `dsp_reinit` (run when a tap prepares for a new item) resets the EQ and
    /// crossfeed stages; put the current state back before the first buffer.
    func engineReinitialised(_ handle: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        if let record = byHandle[handle] { replayState(onto: record) }
    }

    /// Caller holds `lock`.
    private func replayState(onto record: EngineRecord) {
        log.replay(onto: record.handle)
        // A gain a tap applied at a gapless boundary is newer than the last
        // one Dart sent (setTrackGainDb clears the cell); the engine must come
        // back with the gain of the item actually playing.
        var boundaryDb: Float = 0
        if HypeGainCellRead(record.gainCell, &boundaryDb) {
            dsp_set_track_gain_db(record.handle, boundaryDb)
        } else if let gain = trackGains.value(for: record.playerId) {
            dsp_set_track_gain_db(record.handle, gain)
        }
    }

    /// Records the setting and applies it to every live engine, all under the lock.
    private func apply(key: String, _ body: @escaping (UnsafeMutableRawPointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        log.record(key: key, apply: body)
        for record in registry.values { body(record.handle) }
    }

    /// As `apply(key:)`, but first drops the recorded settings the new one
    /// carries the state of, so a replay never applies them over it.
    private func apply(key: String, superseding prefixes: [String],
                       _ body: @escaping (UnsafeMutableRawPointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        log.record(key: key, superseding: prefixes, apply: body)
        for record in registry.values { body(record.handle) }
    }

    // MARK: - Level stages

    func setHeadroomDb(_ dB: Float) {
        apply(key: "setHeadroomDb") { h in dsp_set_headroom_db(h, dB) }
    }

    func setSpeakerPreampDb(_ dB: Float) {
        apply(key: "setSpeakerPreampDb") { h in dsp_set_speaker_preamp_db(h, dB) }
    }

    func setMasterVolumeDb(_ dB: Float) {
        apply(key: "setMasterVolumeDb") { h in dsp_set_master_volume_db(h, dB) }
    }

    /// Smooth equalizer/tone gains (recorded, so a re-created engine gets it back).
    func setSmoothGains(_ enabled: Bool) {
        apply(key: "setSmoothGains") { h in dsp_set_smooth_gains(h, enabled) }
    }

    /// The output volume in dB (-96...0) the smooth gains follow.
    func setSystemVolumeDb(_ dB: Float) {
        apply(key: "setSystemVolumeDb") { h in dsp_set_system_volume_db(h, dB) }
    }

    func setMono(_ enabled: Bool) {
        apply(key: "setMono") { h in dsp_set_mono(h, enabled) }
    }

    func setBalance(_ value: Float) {
        apply(key: "setBalance") { h in dsp_set_balance(h, value) }
    }

    /// One player's track gain. Not part of the global replay log: it belongs
    /// to a single engine. Stored by id even before that engine exists (it is
    /// applied when the engine is created); ignored once the player is released.
    func setTrackGainDb(_ dB: Float, playerId: String) {
        lock.lock(); defer { lock.unlock() }
        trackGains.set(dB, for: playerId)
        // A new current gain supersedes anything announced for upcoming items;
        // Dart announces the next one again right after.
        nextGains[playerId] = nil
        if let record = registry[playerId] {
            HypeGainCellClear(record.gainCell)
            dsp_set_track_gain_db(record.handle, dB)
        }
    }

    /// The gain the item at `uri` takes where it starts in a gapless queue.
    /// Kept per player until the item's tap picks it up.
    func setNextTrackGainDb(_ dB: Float, uri: String, playerId: String) {
        lock.lock()
        let uri = NextGainKey.normalize(uri)
        var entries = nextGains[playerId] ?? []
        entries.removeAll { $0.uri == uri }
        entries.append((uri: uri, dB: dB))
        if entries.count > maxNextGains { entries.removeFirst(entries.count - maxNextGains) }
        nextGains[playerId] = entries
        let handle = registry[playerId]?.handle
        lock.unlock()
        // Outside the lock: the tap takes its own, and its init path takes ours.
        if let handle = handle {
            HypeAudioTap.shared().pushNextGainDb(dB, forUri: uri, engine: handle)
        }
    }

    // MARK: - Tap hooks (called off the audio thread)

    func gainCell(for handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<HypeGainCell>? {
        lock.lock(); defer { lock.unlock() }
        return byHandle[handle]?.gainCell
    }

    func nextGain(for handle: UnsafeMutableRawPointer, uri: String,
                  into out: UnsafeMutablePointer<Float>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let uri = NextGainKey.normalize(uri)
        guard let record = byHandle[handle],
              let entry = nextGains[record.playerId]?.last(where: { $0.uri == uri })
        else { return false }
        out.pointee = entry.dB
        return true
    }

    // MARK: - EQ

    func setEqEnabled(_ enabled: Bool) {
        apply(key: "setEqEnabled") { h in
            dsp_set_eq_enabled(h, enabled)
        }
    }

    func setPreampGain(_ dB: Float) {
        cachedPreampGain = dB
        apply(key: "setPreampGain") { h in
            dsp_set_preamp_gain(h, dB)
        }
    }

    func setGraphicBandGain(band: Int, dB: Float) {
        apply(key: "setGraphicBandGain.\(band)") { h in
            dsp_set_graphic_band_gain(h, Int32(band), dB)
        }
    }

    func setGraphicAllBands(_ gains: [Float]) {
        log.removeAll(withPrefix: "setGraphicBandGain.")
        apply(key: "setGraphicAllBands") { h in
            gains.withUnsafeBufferPointer { ptr in
            dsp_set_graphic_all_bands(h, ptr.baseAddress, Int32(gains.count))
        }
        }
    }

    /// Band centres (Hz) and gains (dB) travel together, so no block plays old
    /// gains at new centres. Supersedes earlier per-band and all-band gain
    /// calls; a later `setGraphicAllBands` replays after it. An engine created
    /// later gets the layout with these gains, then any newer gains.
    func setGraphicLayout(_ centres: [Float], gains: [Float]) {
        let n = min(centres.count, gains.count)
        guard n > 0 else { return }
        let c = Array(centres.prefix(n))
        let g = Array(gains.prefix(n))
        apply(key: "setGraphicLayout",
              superseding: ["setGraphicBandGain.", "setGraphicAllBands"]) { h in
            c.withUnsafeBufferPointer { cp in
                g.withUnsafeBufferPointer { gp in
                    dsp_set_graphic_layout(h, cp.baseAddress, gp.baseAddress, Int32(n))
                }
            }
        }
    }

    func setParametricBand(band: Int, freq: Float, gain: Float, q: Float,
                           filterType: Int, enabled: Bool) {
        apply(key: "setParametricBand.\(band)") { h in
            dsp_set_parametric_band(h, Int32(band), freq, gain, q, Int32(filterType), enabled)
        }
    }

    func setParametricAllBands(freqs: [Float], gains: [Float], qs: [Float]) {
        log.removeAll(withPrefix: "setParametricBand.")
        apply(key: "setParametricAllBands") { h in
            let count = min(freqs.count, gains.count, qs.count)
            freqs.withUnsafeBufferPointer { f in
                gains.withUnsafeBufferPointer { g in
                    qs.withUnsafeBufferPointer { q in
                        dsp_set_parametric_all_bands(h, f.baseAddress, g.baseAddress,
                                                      q.baseAddress, Int32(count))
                    }
                }
            }
        }
    }

    // MARK: - Speaker Correction EQ

    func setSpeakerEqEnabled(_ enabled: Bool) {
        apply(key: "setSpeakerEqEnabled") { h in
            dsp_set_speaker_eq_enabled(h, enabled)
        }
    }

    func setSpeakerEqBand(band: Int, freq: Float, gain: Float, q: Float,
                          filterType: Int, enabled: Bool) {
        apply(key: "setSpeakerEqBand.\(band)") { h in
            dsp_set_speaker_eq_band(h, Int32(band), freq, gain, q, Int32(filterType), enabled)
        }
    }

    func clearSpeakerEq() {
        log.removeAll(withPrefix: "setSpeakerEqBand.")
        apply(key: "clearSpeakerEq") { h in
            dsp_clear_speaker_eq(h)
        }
    }

    // MARK: - Tone Controls

    func setToneEnabled(_ enabled: Bool) {
        apply(key: "setToneEnabled") { h in
            dsp_set_tone_enabled(h, enabled)
        }
    }

    func setBassGain(_ dB: Float) {
        apply(key: "setBassGain") { h in
            dsp_set_bass_gain(h, dB)
        }
    }

    func setBassFreq(_ hz: Float) {
        apply(key: "setBassFreq") { h in
            dsp_set_bass_freq(h, hz)
        }
    }

    func setBassQ(_ q: Float) {
        apply(key: "setBassQ") { h in
            dsp_set_bass_q(h, q)
        }
    }

    func setTrebleGain(_ dB: Float) {
        apply(key: "setTrebleGain") { h in
            dsp_set_treble_gain(h, dB)
        }
    }

    func setTrebleFreq(_ hz: Float) {
        apply(key: "setTrebleFreq") { h in
            dsp_set_treble_freq(h, hz)
        }
    }

    func setTrebleQ(_ q: Float) {
        apply(key: "setTrebleQ") { h in
            dsp_set_treble_q(h, q)
        }
    }

    // MARK: - Limiter

    func setLimiterEnabled(_ enabled: Bool) {
        apply(key: "setLimiterEnabled") { h in
            dsp_set_limiter_enabled(h, enabled)
        }
    }

    func setLimiterCeiling(_ v: Float) {
        apply(key: "setLimiterCeiling") { h in
            dsp_set_limiter_ceiling(h, v)
        }
    }

    func setLimiterRelease(_ ms: Float) {
        apply(key: "setLimiterRelease") { h in
            dsp_set_limiter_release(h, ms)
        }
    }

    func setLimiterKnee(_ dB: Float) {
        apply(key: "setLimiterKnee") { h in
            dsp_set_limiter_knee(h, dB)
        }
    }

    // MARK: - MBC

    func setMbcEnabled(_ enabled: Bool) {
        cachedMbcEnabled = enabled
        apply(key: "setMbcEnabled") { h in
            dsp_set_mbc_enabled(h, enabled)
        }
    }

    func setMbcPreGain(_ dB: Float) {
        apply(key: "setMbcPreGain") { h in
            dsp_set_mbc_pre_gain(h, dB)
        }
    }

    func setMbcNoiseGate(_ dB: Float) {
        apply(key: "setMbcNoiseGate") { h in
            dsp_set_mbc_noise_gate(h, dB)
        }
    }

    func setMbcKneeWidth(_ dB: Float) {
        apply(key: "setMbcKneeWidth") { h in
            dsp_set_mbc_knee_width(h, dB)
        }
    }

    func setMbcExpanderRatio(_ ratio: Float) {
        apply(key: "setMbcExpanderRatio") { h in
            dsp_set_mbc_expander_ratio(h, ratio)
        }
    }

    func setMbcThreshold(_ dB: Float) {
        apply(key: "setMbcThreshold") { h in
            dsp_set_mbc_threshold(h, dB)
        }
    }

    func setMbcRatio(_ ratio: Float) {
        apply(key: "setMbcRatio") { h in
            dsp_set_mbc_ratio(h, ratio)
        }
    }

    func setMbcAttackTime(_ ms: Float) {
        apply(key: "setMbcAttackTime") { h in
            dsp_set_mbc_attack_time(h, ms)
        }
    }

    func setMbcReleaseTime(_ ms: Float) {
        apply(key: "setMbcReleaseTime") { h in
            dsp_set_mbc_release_time(h, ms)
        }
    }

    func setMbcPostGain(_ dB: Float) {
        apply(key: "setMbcPostGain") { h in
            dsp_set_mbc_post_gain(h, dB)
        }
    }

    // MARK: - Reverb

    func setReverbEnabled(_ enabled: Bool) {
        apply(key: "setReverbEnabled") { h in
            dsp_set_reverb_enabled(h, enabled)
        }
    }

    func setRoomSize(_ v: Float) {
        apply(key: "setRoomSize") { h in
            dsp_set_room_size(h, v)
        }
    }

    func setDecay(_ v: Float) {
        apply(key: "setDecay") { h in
            dsp_set_decay(h, v)
        }
    }

    func setDamping(_ v: Float) {
        apply(key: "setDamping") { h in
            dsp_set_damping(h, v)
        }
    }

    func setPreDelay(_ ms: Float) {
        apply(key: "setPreDelay") { h in
            dsp_set_pre_delay(h, ms)
        }
    }

    func setDiffusion(_ v: Float) {
        apply(key: "setDiffusion") { h in
            dsp_set_diffusion(h, v)
        }
    }

    func setReverbWetDry(_ v: Float) {
        apply(key: "setReverbWetDry") { h in
            dsp_set_reverb_wet_dry(h, v)
        }
    }

    // MARK: - Stereo Expand

    /// Amount 0..1 (0–100 %); 0 is off.
    func setStereoExpand(_ amount: Float) {
        apply(key: "setStereoExpand") { h in
            dsp_set_stereo_expand(h, amount)
        }
    }

    // MARK: - Crossfeed

    func setCrossfeedEnabled(_ enabled: Bool) {
        apply(key: "setCrossfeedEnabled") { h in
            dsp_set_crossfeed_enabled(h, enabled)
        }
    }

    func setCrossfeedParams(cutoff: Float, feed: Float) {
        apply(key: "setCrossfeedParams") { h in
            dsp_set_crossfeed_params(h, cutoff, feed)
        }
    }

    // MARK: - 3D Surround
    //
    // Same stage, same constants and the same channel names as Android — the
    // whole point of the port is that the two platforms sound alike, so the
    // Dart side must not need to know which one it is talking to.

    func setSurround3dEnabled(_ enabled: Bool) {
        apply(key: "setSurround3dEnabled") { h in
            dsp_set_surround3d_enabled(h, enabled)
        }
    }

    func setSurround3dParams(intensity: Float, subwoofer: Float) {
        apply(key: "setSurround3dParams") { h in
            dsp_set_surround3d_params(h, intensity, subwoofer)
        }
    }

    func setSurround3dSpeakers(frontL: Bool, frontR: Bool, sideL: Bool,
                               sideR: Bool, surroundL: Bool, surroundR: Bool) {
        apply(key: "setSurround3dSpeakers") { h in
            dsp_set_surround3d_speakers(h, frontL, frontR, sideL, sideR, surroundL, surroundR)
        }
    }
}

// MARK: - Live stems

/// Flutter side of the live-stem engine (HypeDSP/src/stems). The engine
/// separates ahead of each playhead on its own native thread; the audio taps
/// (HypeAudioTap.m) mix the result. Model loading and the speed test take
/// seconds, so they run off the main thread and answer on it.
final class StemsBridge: NSObject, FlutterStreamHandler {
    static let shared = StemsBridge()

    // Model loading runs here; ONNX Runtime's compute threads start from it.
    private let queue = DispatchQueue(label: "hype.stems.control", qos: .utility)
    private var eventSink: FlutterEventSink?
    private var attached = false

    /// Call once the Flutter engine's messenger exists.
    func attach(messenger: FlutterBinaryMessenger) {
        guard !attached else { return }
        attached = true
        let fm = FileManager.default
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stems", isDirectory: true)
        // Decoded audio from an earlier run is useless now.
        try? fm.removeItem(at: cache)
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        cache.path.withCString { dsp_stems_init($0) }
        dsp_stems_set_status_callback({ json, _ in
            guard let json = json else { return }
            let text = String(cString: json)
            DispatchQueue.main.async { StemsBridge.shared.emit(text) }
        }, nil)
        FlutterEventChannel(name: "eq_app/stems_events", binaryMessenger: messenger)
            .setStreamHandler(self)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "stemsLoadModel":
            let dir = args?["dir"] as? String ?? ""
            queue.async {
                var err = [CChar](repeating: 0, count: 512)
                let ok = dir.withCString { dsp_stems_load_model($0, &err, Int32(err.count)) }
                if !ok { NSLog("HypeStems: model load failed: %@", String(cString: err)) }
                DispatchQueue.main.async { result(ok) }
            }
        case "stemsUnloadModel":
            queue.async { dsp_stems_unload_model() }
            result(nil)
        case "stemsBenchmark":
            queue.async {
                var buf = [CChar](repeating: 0, count: 1024)
                dsp_stems_benchmark(&buf, Int32(buf.count))
                let map = StemsBridge.decode(String(cString: buf))
                DispatchQueue.main.async { result(map) }
            }
        case "stemsSetArmed":
            dsp_stems_set_armed(args?["armed"] as? Bool ?? false)
            result(nil)
        case "stemsSetLevels":
            dsp_stems_set_levels(StemsBridge.level(args?["vocals"]),
                                 StemsBridge.level(args?["drums"]),
                                 StemsBridge.level(args?["instruments"]))
            result(nil)
        case "stemsProvideStream":
            if let url = args?["url"] as? String, let path = args?["path"] as? String {
                dsp_stems_provide_stream(url, URL(fileURLWithPath: path).absoluteString)
            }
            result(nil)
        case "stemsGetStatus":
            result(StemsBridge.decode(StemsBridge.statusJson()))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: FlutterStreamHandler

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        events(StemsBridge.decode(StemsBridge.statusJson()))
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: Helpers

    private func emit(_ json: String) {
        eventSink?(StemsBridge.decode(json))
    }

    private static func statusJson() -> String {
        var buf = [CChar](repeating: 0, count: 2048)
        dsp_stems_status_json(&buf, Int32(buf.count))
        return String(cString: buf)
    }

    private static func decode(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return map
    }

    private static func level(_ value: Any?) -> Float {
        if let d = value as? Double { return Float(d) }
        if let n = value as? NSNumber { return n.floatValue }
        return 1.0
    }
}
