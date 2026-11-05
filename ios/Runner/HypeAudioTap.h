#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A track gain written by a tap's audio thread, read by DSPManager under its
/// lock when it replays an engine's state. Lives as long as the engine.
typedef struct {
    float db;
    int set;  // atomic: non-zero once a tap has applied `db` at a boundary
} HypeGainCell;

/// Atomic access: the tap writes (audio thread), DSPManager reads/clears.
static inline void HypeGainCellPost(HypeGainCell *cell, float db) {
    cell->db = db;  // published by the release store below
    __atomic_store_n(&cell->set, 1, __ATOMIC_RELEASE);
}
static inline bool HypeGainCellRead(HypeGainCell *cell, float *out) {
    if (!__atomic_load_n(&cell->set, __ATOMIC_ACQUIRE)) return false;
    *out = cell->db;
    return true;
}
static inline void HypeGainCellClear(HypeGainCell *cell) {
    __atomic_store_n(&cell->set, 0, __ATOMIC_RELEASE);
}

/// Mono audio and the stereo-only DSP engine: a mono buffer is widened to
/// stereo (L = R) before the engine and folded back, (L + R) / 2, after it.
/// Plain C so the render thread allocates nothing; the caller owns both
/// buffers (the tap's scratch is sized when the tap is made).
static inline void HypeMonoToStereo(const float *mono, float *stereo, int frames) {
    for (int i = 0; i < frames; i++) {
        stereo[i * 2]     = mono[i];
        stereo[i * 2 + 1] = mono[i];
    }
}
static inline void HypeStereoToMono(const float *stereo, float *mono, int frames) {
    for (int i = 0; i < frames; i++) {
        mono[i] = 0.5f * (stereo[i * 2] + stereo[i * 2 + 1]);
    }
}

@interface HypeAudioTap : NSObject

+ (instancetype)shared;

/// Engine registry hooks, all set by DSPManager (the one registry owner).
/// acquire: the engine for a player id (created on first use) with a reference
/// taken for the tap; NULL if it cannot be made. release: the tap let go.
/// reinitialised: dsp_reinit just ran on the engine, restore its state.
/// playerReleased: the player was disposed.
@property (nonatomic, copy, nullable) void *_Nullable (^engineAcquire)(NSString *playerId);
@property (nonatomic, copy, nullable) void (^engineRelease)(void *handle);
@property (nonatomic, copy, nullable) void (^engineReinitialised)(void *handle);
@property (nonatomic, copy, nullable) void (^playerReleased)(NSString *playerId);

/// Gapless queues: the gain cell of an engine (tap_Init resolves it once, off
/// the audio thread), and the gain waiting for the item at `uri` on an engine,
/// if DSPManager has one (`outDb` set, YES returned).
@property (nonatomic, copy, nullable) HypeGainCell *_Nullable (^engineGainCell)(void *handle);
/// How an item URL becomes the key gain messages are matched by (DSPManager).
@property (nonatomic, copy, nullable) NSString *_Nonnull (^keyNormaliser)(NSString *uri);
@property (nonatomic, copy, nullable) BOOL (^nextGainLookup)(void *handle, NSString *uri, float *outDb);

/// The gain for the item at `uri` on the engine `handle` arrived: hand it to
/// that item's tap (if it exists yet). Applied on the tap's first process call.
- (void)pushNextGainDb:(float)dB forUri:(NSString *)uri engine:(void *)handle;

- (void)releaseEngineHandle:(void *)handle;

/// Call when a just_audio player is disposed.
- (void)releasePlayer:(NSString *)playerId;

/// Install DSP processing + visualization tap on an AVPlayerItem. The tap runs
/// through the engine belonging to `playerId` (just_audio's player id).
- (void)installTapOnPlayerItem:(AVPlayerItem *)playerItem forPlayer:(NSString *)playerId;

/// Remove tap from a player item
- (void)removeTapFromPlayerItem:(AVPlayerItem *)playerItem;

/// Visualization control
@property (nonatomic, assign) BOOL visualizerEnabled;

/// Latest visualization data as raw bytes (matches Android Visualizer format)
/// Waveform: VIZ_CAPTURE_SIZE unsigned bytes [0-255], silence = 128
/// FFT: VIZ_CAPTURE_SIZE bytes, interleaved [real, imag] pairs
- (nullable NSData *)latestWaveformBytes;
- (nullable NSData *)latestFftBytes;
- (int)currentSampleRate;

/// The bass energy (below ~150 Hz, ~5.8 ms hops) captured since the last call,
/// as the float32 beat frame Dart's BeatFrame reads; nil before a tap runs.
- (nullable NSData *)takeBeatFrame;

/// Raw PCM float data for projectM feeding
- (nullable NSData *)latestPcmFloat;

@end

NS_ASSUME_NONNULL_END
