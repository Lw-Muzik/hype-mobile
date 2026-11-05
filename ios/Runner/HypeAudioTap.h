#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

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
