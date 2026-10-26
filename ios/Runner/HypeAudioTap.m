#import "HypeAudioTap.h"
#import <MediaToolbox/MediaToolbox.h>
#import <Accelerate/Accelerate.h>
#import <HypeDSP/dsp_bridge.h>
#import <os/lock.h>

#define VIZ_CAPTURE_SIZE 1024
#define MAX_SCRATCH_FRAMES 8192
// Bass hops kept for the main thread: ~3 s, far more than a display tick needs.
#define BASS_RING 512
// Band levels for the radial's bars, as Android's FFTVisualizer computes them:
// a 2048-point FFT of the newest full-rate mono audio, 64 power-curve bands.
#define BAND_FFT_SIZE 2048
#define BAND_LOG2N 11
#define BAND_COUNT 64
// Mono samples kept for that FFT. Room for the window plus the largest buffer
// the audio thread writes (MAX_SCRATCH_FRAMES) while the main thread reads.
#define BAND_RING 16384

// Handed to tap_Init through clientInfo: the shared DSP engine plus this
// item's URL, which identifies the track to the live-stem engine.
typedef struct {
    void *dspHandle;
    char *trackUrl;   // malloc'd; tap_Init takes ownership
} TapClientInfo;

// Context stored in each MTAudioProcessingTap
typedef struct {
    void *dspHandle;
    void *stemTap;            // live stems: this item's tap (dsp_stem_tap_*)
    float *scratchBuffer;     // interleave buffer (MAX_SCRATCH_FRAMES * 2)
    int sampleRate;
    int channels;

    // Live stems: where the next buffer starts, in frames at sampleRate.
    // AVPlayer's per-buffer asset time is only good to a source packet (a
    // 4096-frame buffer at 48 kHz moves it by 3906 or 4464), and the stem tap
    // reads any step over 64 frames as a seek, so it would restart alignment
    // on every buffer and never finish. The asset time sets the origin and
    // catches seeks; the frames themselves count the rest.
    int64_t stemNextFrame;
    int stemFrameKnown;

    // Visualization capture (lock-free: audio thread writes, main thread reads)
    uint8_t vizWaveform[VIZ_CAPTURE_SIZE];
    uint8_t vizFft[VIZ_CAPTURE_SIZE];
    int vizWaveformReady;     // atomic flag
    int vizFftReady;          // atomic flag
    int vizEnabled;           // atomic flag

    // FFT scratch buffers
    float fftInput[VIZ_CAPTURE_SIZE];
    FFTSetup fftSetup;
    float fftWindow[VIZ_CAPTURE_SIZE];
    float fftRealp[VIZ_CAPTURE_SIZE / 2];
    float fftImagp[VIZ_CAPTURE_SIZE / 2];

    // Bass hops for the radial visualizer: the energy below ~150 Hz in ~5.8 ms
    // slices, measured at full resolution before the visualizer's decimation
    // (Android's FFTVisualizer::computeBeat does the same; Dart's BassBeat
    // finds the hits). Biquads in double: a 35 Hz high-pass puts its poles
    // within 0.005 of the unit circle.
    double bassCoef[3][5];    // b0 b1 b2 a1 a2: high-pass 35, low-pass 150 x2
    double bassState[3][4];   // x1 x2 y1 y2
    double bassAcc;
    int bassFill;
    int bassHopSize;
    float bassHops[BASS_RING];
    int64_t bassWritten;      // atomic: hops written (audio thread)
    int64_t bassRead;         // hops taken (main thread only)

    // Full-rate mono audio for the band levels (audio thread writes).
    float bandRing[BAND_RING];
    int64_t bandWritten;      // atomic: samples written
} TapContext;

static void designBassBiquad(double *c, int highPass, double fc, double fs) {
    // RBJ cookbook, Q = 1/sqrt(2): a second-order Butterworth section.
    const double w0 = 2.0 * M_PI * fc / fs;
    const double cw = cos(w0);
    const double alpha = sin(w0) / (2.0 * 0.7071067811865476);
    const double a0 = 1.0 + alpha;
    if (highPass) {
        c[0] = (1.0 + cw) / 2.0 / a0; c[1] = -(1.0 + cw) / a0; c[2] = c[0];
    } else {
        c[0] = (1.0 - cw) / 2.0 / a0; c[1] = (1.0 - cw) / a0; c[2] = c[0];
    }
    c[3] = -2.0 * cw / a0;
    c[4] = (1.0 - alpha) / a0;
}

static inline double bassBiquad(double *st, const double *c, double x) {
    const double y = c[0] * x + c[1] * st[0] + c[2] * st[1] - c[3] * st[2] - c[4] * st[3];
    st[1] = st[0]; st[0] = x; st[3] = st[2]; st[2] = y;
    return y;
}

static void prepareBass(TapContext *ctx) {
    const double fs = ctx->sampleRate > 0 ? ctx->sampleRate : 44100;
    designBassBiquad(ctx->bassCoef[0], 1, 35.0, fs);
    designBassBiquad(ctx->bassCoef[1], 0, 150.0, fs);
    designBassBiquad(ctx->bassCoef[2], 0, 150.0, fs);
    memset(ctx->bassState, 0, sizeof(ctx->bassState));
    ctx->bassAcc = 0;
    ctx->bassFill = 0;
    // ~5.8 ms whatever the rate, so the detector's windows mean the same time.
    ctx->bassHopSize = (int)fmax(64.0, round(fs / 172.27));
}

static void captureBass(TapContext *ctx, const float *interleaved, int numFrames) {
    if (ctx->bassHopSize <= 0) return;
    int64_t written = __atomic_load_n(&ctx->bassWritten, __ATOMIC_RELAXED);
    const int64_t bandStart = __atomic_load_n(&ctx->bandWritten, __ATOMIC_RELAXED);
    for (int i = 0; i < numFrames; i++) {
        const float mono = (interleaved[i * 2] + interleaved[i * 2 + 1]) * 0.5f;
        ctx->bandRing[(bandStart + i) % BAND_RING] = mono;
        double y = 0.5 * ((double)interleaved[i * 2] + (double)interleaved[i * 2 + 1]);
        y = bassBiquad(ctx->bassState[0], ctx->bassCoef[0], y);
        y = bassBiquad(ctx->bassState[1], ctx->bassCoef[1], y);
        y = bassBiquad(ctx->bassState[2], ctx->bassCoef[2], y);
        ctx->bassAcc += y * y;
        if (++ctx->bassFill >= ctx->bassHopSize) {
            ctx->bassHops[written % BASS_RING] = (float)(ctx->bassAcc / ctx->bassHopSize);
            written++;
            ctx->bassAcc = 0;
            ctx->bassFill = 0;
        }
    }
    __atomic_store_n(&ctx->bandWritten, bandStart + numFrames, __ATOMIC_RELEASE);
    __atomic_store_n(&ctx->bassWritten, written, __ATOMIC_RELEASE);
}

// The newest BAND_FFT_SIZE samples' level in each of Android's 64 bands, dBFS
// (FFTVisualizer::computeBeat: same Hann window, power-curve edges and full-
// scale reference), so Dart's RadialScene draws iOS bars the way it draws
// Android's. Returns 0 until a window's worth has been heard. Main thread.
static int writeBandsDb(TapContext *ctx, float *out) {
    static FFTSetup setup;
    static float window[BAND_FFT_SIZE];
    static int edges[BAND_COUNT + 1];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        setup = vDSP_create_fftsetup(BAND_LOG2N, kFFTRadix2);
        for (int i = 0; i < BAND_FFT_SIZE; i++) {
            window[i] = 0.5f * (1.0f - cosf(2.0f * (float)M_PI * i / (BAND_FFT_SIZE - 1)));
        }
        for (int b = 0; b <= BAND_COUNT; b++) {
            const float t = (float)b / BAND_COUNT;
            edges[b] = 1 + (int)(powf(t, 2.0f) * (BAND_FFT_SIZE / 2 - 1));
        }
        for (int b = 1; b <= BAND_COUNT; b++) {
            if (edges[b] <= edges[b - 1]) edges[b] = edges[b - 1] + 1;
        }
    });
    const int64_t end = __atomic_load_n(&ctx->bandWritten, __ATOMIC_ACQUIRE);
    if (!setup || end < BAND_FFT_SIZE) return 0;

    float windowed[BAND_FFT_SIZE];
    for (int i = 0; i < BAND_FFT_SIZE; i++) {
        windowed[i] = ctx->bandRing[(end - BAND_FFT_SIZE + i) % BAND_RING] * window[i];
    }
    float realp[BAND_FFT_SIZE / 2];
    float imagp[BAND_FFT_SIZE / 2];
    DSPSplitComplex split = { realp, imagp };
    vDSP_ctoz((DSPComplex *)windowed, 2, &split, 1, BAND_FFT_SIZE / 2);
    vDSP_fft_zrip(setup, &split, 1, BAND_LOG2N, FFT_FORWARD);

    for (int b = 0; b < BAND_COUNT; b++) {
        const int lo = edges[b];
        const int hi = edges[b + 1];
        float sum = 0;
        for (int i = lo; i < hi; i++) {
            // zrip returns twice the DFT; bins 1..N/2-1 only, so no packing.
            sum += 0.5f * sqrtf(realp[i] * realp[i] + imagp[i] * imagp[i]);
        }
        const float mean = sum / (hi - lo > 1 ? hi - lo : 1);
        // A full-scale sine peaks at N/4 through a Hann window.
        out[b] = 20.0f * log10f(mean / (BAND_FFT_SIZE / 4) + 1e-9f);
    }
    return BAND_COUNT;
}

// Shared latest context (points to whichever tap is active)
static TapContext * volatile sActiveContext = NULL;
// Global enabled state — survives tap context switches
static volatile int sVizEnabledGlobal = 0;

#pragma mark - MTAudioProcessingTap Callbacks

static void tap_Init(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    TapContext *ctx = (TapContext *)calloc(1, sizeof(TapContext));
    TapClientInfo *info = (TapClientInfo *)clientInfo;
    ctx->dspHandle = info ? info->dspHandle : NULL;
    ctx->stemTap = dsp_stem_tap_create(info && info->trackUrl ? info->trackUrl : "");
    if (info) {
        free(info->trackUrl);
        free(info);
    }
    ctx->scratchBuffer = (float *)calloc(MAX_SCRATCH_FRAMES * 2, sizeof(float));
    ctx->sampleRate = 44100;
    ctx->channels = 2;

    // FFT setup
    int log2n = (int)log2f((float)VIZ_CAPTURE_SIZE);
    ctx->fftSetup = vDSP_create_fftsetup(log2n, kFFTRadix2);
    vDSP_hann_window(ctx->fftWindow, VIZ_CAPTURE_SIZE, vDSP_HANN_NORM);

    *tapStorageOut = ctx;
}

static void tap_Finalize(MTAudioProcessingTapRef tap) {
    TapContext *ctx = (TapContext *)MTAudioProcessingTapGetStorage(tap);
    if (ctx == sActiveContext) {
        sActiveContext = NULL;
    }
    if (ctx->fftSetup) vDSP_destroy_fftsetup(ctx->fftSetup);
    if (ctx->stemTap) dsp_stem_tap_destroy(ctx->stemTap);
    free(ctx->scratchBuffer);
    free(ctx);
}

static void tap_Prepare(MTAudioProcessingTapRef tap,
                         CMItemCount maxFrames,
                         const AudioStreamBasicDescription *processingFormat) {
    TapContext *ctx = (TapContext *)MTAudioProcessingTapGetStorage(tap);
    ctx->sampleRate = (int)processingFormat->mSampleRate;
    ctx->channels = (int)processingFormat->mChannelsPerFrame;

    // Reinit DSP engine for this sample rate
    if (ctx->dspHandle) {
        dsp_reinit(ctx->dspHandle, ctx->sampleRate, ctx->channels);
    }
    // Live stems work on stereo only; rate 0 keeps the tap idle otherwise.
    dsp_stem_tap_prepare(ctx->stemTap, ctx->channels == 2 ? ctx->sampleRate : 0);
    ctx->stemFrameKnown = 0;

    prepareBass(ctx);

    // Propagate global visualization state to this new context
    __atomic_store_n(&ctx->vizEnabled, sVizEnabledGlobal, __ATOMIC_RELEASE);

    sActiveContext = ctx;
}

static void tap_Unprepare(MTAudioProcessingTapRef tap) {
    TapContext *ctx = (TapContext *)MTAudioProcessingTapGetStorage(tap);
    if (ctx == sActiveContext) {
        sActiveContext = NULL;
    }
}

static void captureVisualization(TapContext *ctx, const float *interleavedData, int numFrames) {
    captureBass(ctx, interleavedData, numFrames);

    // Downsample stereo interleaved PCM to VIZ_CAPTURE_SIZE mono uint8 samples
    // Format matches Android Visualizer: unsigned bytes 0-255, silence = 128
    int step = (numFrames > VIZ_CAPTURE_SIZE) ? (numFrames / VIZ_CAPTURE_SIZE) : 1;
    int count = (numFrames > VIZ_CAPTURE_SIZE) ? VIZ_CAPTURE_SIZE : numFrames;

    for (int i = 0; i < count; i++) {
        int srcIdx = i * step * 2; // stereo interleaved
        float l = interleavedData[srcIdx];
        float r = interleavedData[srcIdx + 1];
        float mono = (l + r) * 0.5f;
        // Clamp to [-1, 1] and convert to unsigned byte [0, 255]
        if (mono < -1.0f) mono = -1.0f;
        if (mono > 1.0f) mono = 1.0f;
        ctx->vizWaveform[i] = (uint8_t)((mono + 1.0f) * 127.5f);
        ctx->fftInput[i] = mono;
    }
    // Pad remainder
    for (int i = count; i < VIZ_CAPTURE_SIZE; i++) {
        ctx->vizWaveform[i] = 128; // silence
        ctx->fftInput[i] = 0.0f;
    }
    __atomic_store_n(&ctx->vizWaveformReady, 1, __ATOMIC_RELEASE);

    // Compute FFT → magnitude bytes matching Android Visualizer format
    if (ctx->fftSetup) {
        float windowed[VIZ_CAPTURE_SIZE];
        vDSP_vmul(ctx->fftInput, 1, ctx->fftWindow, 1, windowed, 1, VIZ_CAPTURE_SIZE);

        DSPSplitComplex splitComplex = { ctx->fftRealp, ctx->fftImagp };
        vDSP_ctoz((DSPComplex *)windowed, 2, &splitComplex, 1, VIZ_CAPTURE_SIZE / 2);

        int log2n = (int)log2f((float)VIZ_CAPTURE_SIZE);
        vDSP_fft_zrip(ctx->fftSetup, &splitComplex, 1, log2n, FFT_FORWARD);

        // Convert FFT output to magnitude bytes [0-255] per frequency bin.
        // vDSP_fft_zrip output is scaled by 2x, so divide by N to normalize.
        float scale = 1.0f / (float)VIZ_CAPTURE_SIZE;
        int half = VIZ_CAPTURE_SIZE / 2;

        // First pass: find peak magnitude for adaptive normalization
        float peakMag = 0.0001f;
        for (int i = 1; i < half; i++) { // skip DC bin
            float re = ctx->fftRealp[i] * scale;
            float im = ctx->fftImagp[i] * scale;
            float mag = sqrtf(re * re + im * im);
            if (mag > peakMag) peakMag = mag;
        }

        // Second pass: normalize relative to peak, with dB mapping
        for (int i = 0; i < half; i++) {
            float re = ctx->fftRealp[i] * scale;
            float im = ctx->fftImagp[i] * scale;
            float mag = sqrtf(re * re + im * im);
            // dB relative to peak: 0 dB at peak, negative below
            float dbVal = 20.0f * log10f(mag / peakMag + 1e-10f);
            // Map [-40 dB, 0 dB] to [0, 255]
            float norm = (dbVal + 40.0f) / 40.0f;
            if (norm < 0.0f) norm = 0.0f;
            if (norm > 1.0f) norm = 1.0f;
            ctx->vizFft[i * 2]     = (uint8_t)(norm * 255.0f);
            ctx->vizFft[i * 2 + 1] = 0;
        }
        __atomic_store_n(&ctx->vizFftReady, 1, __ATOMIC_RELEASE);
    }
}

static void tap_Process(MTAudioProcessingTapRef tap,
                         CMItemCount numberFrames,
                         MTAudioProcessingTapFlags flags,
                         AudioBufferList *bufferListInOut,
                         CMItemCount *numberFramesOut,
                         MTAudioProcessingTapFlags *flagsOut) {
    TapContext *ctx = (TapContext *)MTAudioProcessingTapGetStorage(tap);

    CMTimeRange timeRange = kCMTimeRangeInvalid;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames,
                                                          bufferListInOut,
                                                          flagsOut, &timeRange, numberFramesOut);
    if (status != noErr) return;

    int frames = (int)*numberFramesOut;
    if (frames <= 0 || !ctx->dspHandle) return;

    // Which samples of the track this buffer holds, for the stem tap: counted
    // on from the last origin while the asset time agrees with the count to
    // within its packet jitter (~200 frames seen); a seek moves it further.
    // StartOfStream marks a seek too.
    const bool discontinuity = (*flagsOut & kMTAudioProcessingTapFlag_StartOfStream) != 0;
    const bool timeKnown = CMTIME_IS_NUMERIC(timeRange.start) && ctx->sampleRate > 0;
    const int64_t reported = timeKnown
        ? (int64_t)llround(CMTimeGetSeconds(timeRange.start) * (double)ctx->sampleRate) : 0;
    const int64_t resyncFrames = ctx->sampleRate / 20;  // 50 ms
    const bool stemsKnowWhere = timeKnown || ctx->stemFrameKnown;
    int64_t framePos = ctx->stemNextFrame;
    if (timeKnown && (discontinuity || !ctx->stemFrameKnown ||
                      llabs(reported - ctx->stemNextFrame) > resyncFrames)) {
        framePos = reported;
    }
    if (stemsKnowWhere) {
        ctx->stemNextFrame = framePos + frames;
        ctx->stemFrameKnown = 1;
    }

    if (bufferListInOut->mNumberBuffers == 1) {
        // Interleaved stereo float
        float *data = (float *)bufferListInOut->mBuffers[0].mData;
        if (stemsKnowWhere) dsp_stem_tap_process(ctx->stemTap, data, frames, framePos, discontinuity);
        dsp_process_float(ctx->dspHandle, data, frames);

        if (__atomic_load_n(&ctx->vizEnabled, __ATOMIC_ACQUIRE)) {
            captureVisualization(ctx, data, frames);
        }
    } else if (bufferListInOut->mNumberBuffers >= 2) {
        // Non-interleaved: separate L/R buffers
        float *left  = (float *)bufferListInOut->mBuffers[0].mData;
        float *right = (float *)bufferListInOut->mBuffers[1].mData;

        int clampedFrames = (frames > MAX_SCRATCH_FRAMES) ? MAX_SCRATCH_FRAMES : frames;

        for (int i = 0; i < clampedFrames; i++) {
            ctx->scratchBuffer[i * 2]     = left[i];
            ctx->scratchBuffer[i * 2 + 1] = right[i];
        }

        if (stemsKnowWhere) {
            dsp_stem_tap_process(ctx->stemTap, ctx->scratchBuffer, clampedFrames, framePos, discontinuity);
        }
        dsp_process_float(ctx->dspHandle, ctx->scratchBuffer, clampedFrames);

        if (__atomic_load_n(&ctx->vizEnabled, __ATOMIC_ACQUIRE)) {
            captureVisualization(ctx, ctx->scratchBuffer, clampedFrames);
        }

        for (int i = 0; i < clampedFrames; i++) {
            left[i]  = ctx->scratchBuffer[i * 2];
            right[i] = ctx->scratchBuffer[i * 2 + 1];
        }
    }
}

#pragma mark - HypeAudioTap

@implementation HypeAudioTap {
    void *_dspHandle;
}

+ (instancetype)shared {
    static HypeAudioTap *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HypeAudioTap alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _dspHandle = NULL;
    }
    return self;
}

- (void)setDspHandle:(void *)handle {
    _dspHandle = handle;
}

- (void)installTapOnPlayerItem:(AVPlayerItem *)playerItem {
    if (!_dspHandle) return;

    AVAsset *asset = playerItem.asset;
    void *handle = _dspHandle;
    NSString *trackUrl = [asset isKindOfClass:[AVURLAsset class]]
        ? ((AVURLAsset *)asset).URL.absoluteString : @"";

    [asset loadTracksWithMediaType:AVMediaTypeAudio
                 completionHandler:^(NSArray<AVAssetTrack *> * _Nullable tracks,
                                     NSError * _Nullable error) {
        if (error || tracks.count == 0) return;

        AVAssetTrack *audioTrack = tracks.firstObject;

        TapClientInfo *info = (TapClientInfo *)calloc(1, sizeof(TapClientInfo));
        info->dspHandle = handle;
        info->trackUrl = strdup(trackUrl.UTF8String ?: "");

        MTAudioProcessingTapCallbacks callbacks;
        callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
        callbacks.clientInfo = info;
        callbacks.init = tap_Init;
        callbacks.finalize = tap_Finalize;
        callbacks.prepare = tap_Prepare;
        callbacks.unprepare = tap_Unprepare;
        callbacks.process = tap_Process;

        MTAudioProcessingTapRef tap = NULL;
        OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault,
                                                      &callbacks,
                                                      kMTAudioProcessingTapCreationFlag_PostEffects,
                                                      &tap);
        if (status != noErr || !tap) {
            free(info->trackUrl);
            free(info);
            return;
        }

        AVMutableAudioMixInputParameters *params =
            [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
        params.audioTapProcessor = tap;

        AVMutableAudioMix *audioMix = [AVMutableAudioMix audioMix];
        audioMix.inputParameters = @[params];

        CFRelease(tap);

        dispatch_async(dispatch_get_main_queue(), ^{
            playerItem.audioMix = audioMix;
        });
    }];
}

- (void)removeTapFromPlayerItem:(AVPlayerItem *)playerItem {
    playerItem.audioMix = nil;
}

- (void)setVisualizerEnabled:(BOOL)enabled {
    _visualizerEnabled = enabled;
    sVizEnabledGlobal = enabled ? 1 : 0;
    TapContext *ctx = sActiveContext;
    if (ctx) {
        __atomic_store_n(&ctx->vizEnabled, enabled ? 1 : 0, __ATOMIC_RELEASE);
    }
}

- (int)currentSampleRate {
    TapContext *ctx = sActiveContext;
    return ctx ? ctx->sampleRate : 44100;
}

- (nullable NSData *)latestWaveformBytes {
    TapContext *ctx = sActiveContext;
    if (!ctx) return nil;
    if (!__atomic_exchange_n(&ctx->vizWaveformReady, 0, __ATOMIC_ACQ_REL)) {
        return nil;
    }
    return [NSData dataWithBytes:ctx->vizWaveform length:VIZ_CAPTURE_SIZE];
}

- (nullable NSData *)latestFftBytes {
    TapContext *ctx = sActiveContext;
    if (!ctx) return nil;
    if (!__atomic_exchange_n(&ctx->vizFftReady, 0, __ATOMIC_ACQ_REL)) {
        return nil;
    }
    return [NSData dataWithBytes:ctx->vizFft length:VIZ_CAPTURE_SIZE];
}

- (nullable NSData *)takeBeatFrame {
    TapContext *ctx = sActiveContext;
    if (!ctx || ctx->bassHopSize <= 0) return nil;
    const int64_t written = __atomic_load_n(&ctx->bassWritten, __ATOMIC_ACQUIRE);
    int64_t from = ctx->bassRead;
    if (written - from > BASS_RING) from = written - BASS_RING;
    if (from > written) from = written;  // a new tap started its count again
    const int n = (int)(written - from);
    ctx->bassRead = written;
    // The frame Dart's BeatFrame reads; no clock here, so unsynced. The bands
    // drive the radial's bars: without them they never move.
    NSMutableData *frame = [NSMutableData dataWithLength:(6 + n + BAND_COUNT) * sizeof(float)];
    float *f = (float *)frame.mutableBytes;
    f[0] = 1.0f;
    f[1] = (float)ctx->sampleRate;
    f[2] = (float)((double)ctx->bassHopSize / (ctx->sampleRate > 0 ? ctx->sampleRate : 44100));
    f[3] = 0.0f;
    f[4] = (float)n;
    for (int i = 0; i < n; i++) f[5 + i] = ctx->bassHops[(from + i) % BASS_RING];
    const int m = writeBandsDb(ctx, f + 6 + n);
    f[5 + n] = (float)m;
    frame.length = (6 + n + m) * sizeof(float);
    return frame;
}

// PCM float data for projectM (stereo interleaved)
- (nullable NSData *)latestPcmFloat {
    TapContext *ctx = sActiveContext;
    if (!ctx) return nil;
    // Return mono float data from the last waveform capture (VIZ_CAPTURE_SIZE floats)
    if (!ctx->vizWaveformReady) return nil;
    return [NSData dataWithBytes:ctx->fftInput length:VIZ_CAPTURE_SIZE * sizeof(float)];
}

@end
