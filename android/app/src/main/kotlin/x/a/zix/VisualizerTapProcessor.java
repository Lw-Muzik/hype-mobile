package x.a.zix;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import androidx.annotation.NonNull;
import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import androidx.media3.exoplayer.audio.AudioSink;
import com.ryanheise.just_audio.SinkClockListener;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import io.flutter.plugin.common.EventChannel;

/**
 * Media3 AudioProcessor that taps PCM audio for visualization.
 *
 * Two visualization paths:
 *   1. ProjectM: raw PCM via AtomicReference (existing)
 *   2. Flutter visualizers: PCM → C++ FFT → 64 log-frequency bands via EventChannel
 *
 * The C++ FFT replaces Android's Visualizer API, eliminating the need for
 * an audio session ID. PCM is tapped directly from ExoPlayer's pipeline.
 *
 * <h3>Heard time</h3>
 * The tap runs as ExoPlayer hands a buffer to the AudioTrack: ~0.3 s before
 * it is heard (280-316 ms measured on the Lenovo tablet). Drawing the newest
 * samples put every visualizer a quarter-second ahead of the music — half a
 * beat at 100 bpm, so a bounce landed between kicks. The player's sink now
 * reports its clock ({@link SinkClockListener}): the presentation time of the
 * buffers it is given and the position it is playing out. Frames are counted
 * from the first buffer after a flush, so the playing position maps onto the
 * native ring ({@link #onSinkClock}), and the viz tick reads the audio being
 * heard ({@link #heardNow}).
 *
 * <p>How far past "heard now" each output reads:
 * <ul>
 *   <li>Beat frames read {@link #BEAT_LOOKAHEAD_NS} ahead and say when their
 *   last hop will be heard; Dart holds each hit until the frame that will be
 *   on screen then (lib/visualizers/radial_scene.dart). The lookahead
 *   absorbs this thread's uneven ticks (up to ~70 ms apart, measured) and the
 *   ~70-100 ms a Flutter frame takes to reach the screen on the Lenovo.</li>
 *   <li>Bands and waveform, which every other visualizer draws as they come,
 *   read {@link #DRAW_LEAD_NS} ahead: about that drawing delay.</li>
 * </ul>
 */
public class VisualizerTapProcessor extends BaseAudioProcessor implements SinkClockListener {
    private static final String TAG = "VisualizerTap";

    // All player-attached instances
    private static final CopyOnWriteArrayList<VisualizerTapProcessor> playerInstances =
            new CopyOnWriteArrayList<>();

    // Shared PCM buffer across all instances — projectM render thread reads from here
    private static final AtomicReference<float[]> latestPcm = new AtomicReference<>(null);

    // Shared tap state — broadcast to all instances
    private static volatile boolean tapEnabledGlobal = false;

    // FFT visualization via EventChannel
    private static volatile EventChannel.EventSink fftSink;
    private static volatile EventChannel.EventSink waveformSink;
    private static volatile EventChannel.EventSink beatSink;
    private static volatile EventChannel.EventSink spectrumSink;
    private static ScheduledExecutorService vizThread;
    private static final Handler mainHandler = new Handler(Looper.getMainLooper());
    private static volatile boolean fftEnabled = false;

    // Singleton kept for ProjectMRenderer to call getLatestPcm() / setTapEnabled()
    private static VisualizerTapProcessor singleton;

    // Native FFT methods (implemented in jni_bridge.cpp)
    private static native void nativeInitFFT();
    private static native void nativeDestroyFFT();
    private static native long nativePushSamples(float[] samples, int numFrames);
    private static native float[] nativeComputeBands(long endIndex);
    private static native byte[] nativeGetWaveform(long endIndex);
    private static native float[] nativeComputeBeat(long endIndex, int sampleRate);
    private static native float[] nativeComputeSpectrum(long endIndex, int sampleRate);
    private static native void nativeSetSmoothing(float attack, float decay);
    private static native void nativeSetGain(float gain);

    static {
        System.loadLibrary("eq_app");
    }

    public static VisualizerTapProcessor getInstance() {
        if (singleton == null) {
            singleton = new VisualizerTapProcessor();
        }
        return singleton;
    }

    public static boolean hasInstance() {
        return !playerInstances.isEmpty();
    }

    /**
     * True when the in-pipeline PCM tap is capturing — either the FFT/Flutter
     * visualizer path or the projectM tap. Used to keep the legacy Android
     * {@link android.media.audiofx.Visualizer} from running at the same time
     * (single active capture path; the custom tap is primary).
     */
    public static boolean isCustomTapActive() {
        return fftEnabled || tapEnabledGlobal;
    }

    /**
     * Called by just_audio's AudioPlayer.java via reflection.
     * Each ExoPlayer gets its own instance with independent buffer state.
     */
    public static VisualizerTapProcessor createPlayerInstance() {
        VisualizerTapProcessor p = new VisualizerTapProcessor();
        playerInstances.add(p);
        Log.i(TAG, "Player instance created, total: " + playerInstances.size());
        return p;
    }

    private int sampleRate = 44100;
    private static volatile int latestSampleRate = 44100;

    // ── Heard time (see the class comment) ──

    private static final long BEAT_LOOKAHEAD_NS = 200_000_000L;
    private static final long DRAW_LEAD_NS = 70_000_000L;
    /** Past this the playhead is stale (paused, seeking): fall back to newest. */
    private static final long PLAYHEAD_MAX_AGE_NS = 500_000_000L;

    /** Where the player's output is, on the native ring, as of {@code nanos}. */
    private static final class Playhead {
        final long ringIndex;
        final long nanos;
        final int sampleRate;
        final VisualizerTapProcessor owner;

        Playhead(long ringIndex, long nanos, int sampleRate, VisualizerTapProcessor owner) {
            this.ringIndex = ringIndex;
            this.nanos = nanos;
            this.sampleRate = sampleRate;
            this.owner = owner;
        }
    }

    private static volatile Playhead playhead;
    // During a crossfade two players push into the one ring; only the one that
    // pushed last may move the playhead, so it does not flip between them.
    private static volatile VisualizerTapProcessor latestPusher;
    // One past the newest sample on the ring: reads ahead of the playhead stop
    // here, and a frame's heard time is worked out from where it really ends.
    private static volatile long ringEnd;
    // Bumped whenever the native ring is created afresh (its indices restart
    // at 0), so chunks remembered against the old ring are not looked up.
    private static volatile int ringGeneration;

    /** Presentation time of the first buffer since the last flush. */
    private long streamStartUs = C.TIME_UNSET;
    /** Frames this player has processed since the last flush. */
    private long framesSinceFlush;
    // Where recent buffers landed on the ring: frame index -> ring index.
    private static final int CHUNKS = 128;
    private final long[] chunkFrame = new long[CHUNKS];
    private final long[] chunkRing = new long[CHUNKS];
    private final int[] chunkFrames = new int[CHUNKS];
    private final int[] chunkGeneration = new int[CHUNKS];
    private int chunkNext;
    private int chunkCount;

    // Double-buffered PCM scratch (F7): eliminates the per-callback heap
    // allocation and keeps the projectM reader thread-safe. Each callback fills
    // the buffer the reader is NOT currently holding, so we never mutate an
    // array that getLatestPcm() may have handed out. Per-instance (each player
    // has its own audio thread), so no cross-instance contention.
    private float[] pcmBufA;
    private float[] pcmBufB;
    private boolean pcmToggle = false;
    // Reusable staging buffer for bulk PCM_16 -> float conversion (grow-only).
    private short[] shortScratch;

    private VisualizerTapProcessor() {}

    // ---- BaseAudioProcessor overrides ----

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        int encoding = inputAudioFormat.encoding;
        if (encoding != C.ENCODING_PCM_16BIT && encoding != C.ENCODING_PCM_FLOAT) {
            throw new UnhandledAudioFormatException(inputAudioFormat);
        }
        if (inputAudioFormat.channelCount != 2) {
            Log.w(TAG, "Non-stereo audio (" + inputAudioFormat.channelCount + "ch), passing through");
            return AudioFormat.NOT_SET;
        }

        sampleRate = inputAudioFormat.sampleRate;
        latestSampleRate = sampleRate;
        Log.i(TAG, "Configured: " + sampleRate + "Hz, encoding=" + encoding);
        return inputAudioFormat;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        if (!inputBuffer.hasRemaining()) return;

        int remaining = inputBuffer.remaining();
        int encoding = inputAudioFormat.encoding;
        int bytesPerSample = (encoding == C.ENCODING_PCM_FLOAT) ? 4 : 2;
        int numFrames = remaining / (bytesPerSample * 2); // stereo

        if (numFrames <= 0) {
            inputBuffer.position(inputBuffer.limit());
            return;
        }

        // Pass audio through unchanged via BaseAudioProcessor buffer management
        ByteBuffer outputBuffer = replaceOutputBuffer(remaining);
        outputBuffer.put(inputBuffer);
        outputBuffer.flip();

        // If either tap (projectM) or FFT (Flutter visualizer) is enabled, extract PCM
        if (tapEnabledGlobal || fftEnabled) {
            int totalSamples = numFrames * 2; // stereo interleaved

            // Fill the buffer the projectM reader is NOT holding (double-buffer).
            // Reallocate only when the frame count actually changes (rare, e.g.
            // a format switch) — steady-state playback reuses the arrays with
            // zero allocation on the audio thread. Exact sizing is required:
            // projectM consumes the whole array by length, and the bulk
            // FloatBuffer.get(array) reads exactly array.length samples.
            float[] pcm = pcmToggle ? pcmBufA : pcmBufB;
            if (pcm == null || pcm.length != totalSamples) {
                pcm = new float[totalSamples];
                if (pcmToggle) pcmBufA = pcm; else pcmBufB = pcm;
            }

            // Read a copy without disturbing the output buffer's position:
            // asShortBuffer()/asFloatBuffer() views start at the current
            // position and never advance the parent buffer.
            outputBuffer.order(ByteOrder.nativeOrder());

            if (encoding == C.ENCODING_PCM_FLOAT) {
                outputBuffer.asFloatBuffer().get(pcm);
            } else {
                // Bulk PCM_16BIT → float. Identical scaling to the previous
                // per-sample getShort() / 32768.0f, but with one bulk copy
                // instead of N bounds-checked ByteBuffer.getShort() calls.
                if (shortScratch == null || shortScratch.length < totalSamples) {
                    shortScratch = new short[totalSamples];
                }
                outputBuffer.asShortBuffer().get(shortScratch, 0, totalSamples);
                for (int i = 0; i < totalSamples; i++) {
                    pcm[i] = shortScratch[i] / 32768.0f;
                }
            }

            // ProjectM tap
            if (tapEnabledGlobal) {
                latestPcm.set(pcm);
            }

            // Push to C++ FFT ring buffer (synchronous copy — length-agnostic),
            // remembering where it landed so the clock can be mapped onto it.
            if (fftEnabled) {
                long first = nativePushSamples(pcm, numFrames);
                if (first >= 0) {
                    rememberChunk(framesSinceFlush, first, numFrames);
                    ringEnd = Math.max(ringEnd, first + numFrames);
                }
                latestPusher = this;
            }

            // Flip so the next callback writes the other buffer, giving any
            // reader a full callback period before this array is reused.
            pcmToggle = !pcmToggle;
        }
        framesSinceFlush += numFrames;
    }

    // ---- Sink clock (heard time) ----

    @Override
    public boolean wantsSinkClock() {
        // Always for the first buffer of a stream, which anchors the count.
        return fftEnabled || streamStartUs == C.TIME_UNSET;
    }

    @Override
    public void onSinkClock(long presentationTimeUs, long playingPositionUs) {
        if (streamStartUs == C.TIME_UNSET) streamStartUs = presentationTimeUs;
        if (!fftEnabled || playingPositionUs == AudioSink.CURRENT_POSITION_NOT_SET) return;
        if (latestPusher != this) return;
        // The sink counts frames from the stream's first buffer the same way:
        // what it plays out at P is frame (P - start) of what passed through here.
        long frame = (playingPositionUs - streamStartUs) * sampleRate / 1_000_000L;
        long ring = ringIndexOf(frame);
        if (ring >= 0) playhead = new Playhead(ring, System.nanoTime(), sampleRate, this);
    }

    private void rememberChunk(long frame, long ring, int frames) {
        chunkFrame[chunkNext] = frame;
        chunkRing[chunkNext] = ring;
        chunkFrames[chunkNext] = frames;
        chunkGeneration[chunkNext] = ringGeneration;
        chunkNext = (chunkNext + 1) % CHUNKS;
        if (chunkCount < CHUNKS) chunkCount++;
    }

    /** The ring index frame {@code frame} landed at, or -1 if not remembered. */
    private long ringIndexOf(long frame) {
        final int generation = ringGeneration;
        for (int k = 1; k <= chunkCount; k++) {
            int i = (chunkNext - k + CHUNKS) % CHUNKS;
            if (chunkGeneration[i] != generation) return -1;
            if (chunkFrame[i] <= frame) {
                long offset = frame - chunkFrame[i];
                return offset < chunkFrames[i] ? chunkRing[i] + offset : -1;
            }
        }
        return -1;
    }

    private void forgetStream() {
        streamStartUs = C.TIME_UNSET;
        framesSinceFlush = 0;
        chunkCount = 0;
        chunkNext = 0;
        Playhead p = playhead;
        if (p != null && p.owner == this) playhead = null;
    }

    /**
     * The ring index being heard at {@code nowNs}, or -1 when no clock is
     * known (nothing playing yet, paused, a seek in flight).
     */
    private static long heardNow(Playhead p, long nowNs) {
        if (p == null) return -1;
        long age = nowNs - p.nanos;
        if (age < 0 || age > PLAYHEAD_MAX_AGE_NS) return -1;
        return p.ringIndex + age * p.sampleRate / 1_000_000_000L;
    }

    /** {@code leadNs} past the heard position, but never past the newest sample. */
    private static long ahead(Playhead p, long heard, long leadNs) {
        return Math.min(heard + leadNs * p.sampleRate / 1_000_000_000L, ringEnd);
    }

    @Override
    protected void onFlush() {
        // Re-register if a prior onReset() removed this instance mid-life
        // (media3 can reset a still-live processor during setAudioSource
        // reconfiguration). CopyOnWriteArrayList makes contains()/add() safe.
        if (!playerInstances.contains(this)) {
            playerInstances.add(this);
        }
        // A seek or a new stream: the frame count starts again.
        forgetStream();
    }

    @Override
    protected void onReset() {
        // Prune this instance so the static list doesn't grow unbounded across
        // crossfade/stop-start cycles (just_audio disposes and recreates the
        // platform player, which reset()s each processor). onFlush() re-adds
        // it if media3 flushes this same instance again (mid-life reset).
        playerInstances.remove(this);
        // Release the per-instance PCM scratch buffers; queueInput reallocates
        // them on demand (guarded by a null/length check) if this instance is
        // ever reused. Don't clear latestPcm — it's shared static state.
        pcmBufA = null;
        pcmBufB = null;
        shortScratch = null;
        forgetStream();
        if (latestPusher == this) latestPusher = null;
    }

    // ---- ProjectM API (existing) ----

    public float[] getLatestPcm() {
        return latestPcm.getAndSet(null);
    }

    public void setTapEnabled(boolean enabled) {
        tapEnabledGlobal = enabled;
        if (!enabled) {
            latestPcm.set(null);
        }
        Log.d(TAG, "Tap " + (enabled ? "enabled" : "disabled"));
    }

    public boolean isTapEnabled() {
        return tapEnabledGlobal;
    }

    public int getSampleRate() {
        return sampleRate;
    }

    // ---- FFT Visualizer API (new) ----

    /**
     * Set the EventSink for FFT band data (64 floats, 0.0-1.0).
     * Called from EventChannel.StreamHandler in MainActivity.
     */
    public static void setFftSink(EventChannel.EventSink sink) {
        fftSink = sink;
        updateVizThread();
    }

    /**
     * Set the EventSink for bar spectrum frames (256 powers, see
     * FFTVisualizer::computeSpectrum) for the built-in bar visualizers.
     */
    public static void setSpectrumSink(EventChannel.EventSink sink) {
        spectrumSink = sink;
        updateVizThread();
    }

    /** The viz thread runs while the bands or the spectrum have a listener. */
    private static synchronized void updateVizThread() {
        if (fftSink != null || spectrumSink != null) {
            startFftVizThread();
        } else {
            stopFftVizThread();
        }
    }

    /**
     * Set the EventSink for waveform data (1024 bytes, 0-255).
     */
    public static void setWaveformSink(EventChannel.EventSink sink) {
        waveformSink = sink;
    }

    /**
     * Set the EventSink for beat frames (see FFTVisualizer::computeBeat): the
     * bass energy heard since the last tick, for the radial visualizer.
     */
    public static void setBeatSink(EventChannel.EventSink sink) {
        beatSink = sink;
    }

    // Current frame interval in ms (default 33ms ≈ 30fps)
    private static long frameIntervalMs = 33;

    /**
     * Set the visualization frame rate (15-60 fps).
     * Restarts the viz thread with the new interval.
     */
    public static void setFrameRate(int fps) {
        fps = Math.max(15, Math.min(60, fps));
        frameIntervalMs = 1000 / fps;
        // Restart thread if running to apply new rate
        if (vizThread != null) {
            stopFftVizThread();
            startFftVizThread();
        }
        Log.d(TAG, "FFT viz frame rate set to " + fps + " fps (" + frameIntervalMs + "ms)");
    }

    /**
     * Set attack/decay smoothing rates for the C++ FFT bands.
     * @param attack 0.1 (smooth) to 0.9 (snappy) — how fast bands rise
     * @param decay  0.05 (slow) to 0.5 (fast) — how fast bands fall
     */
    public static void setSmoothing(float attack, float decay) {
        nativeSetSmoothing(attack, decay);
    }

    /**
     * Set gain / beat sensitivity for the FFT output.
     * @param gain 0.5 (subtle) to 3.0 (intense)
     */
    public static void setGain(float gain) {
        nativeSetGain(gain);
    }

    private static void startFftVizThread() {
        if (vizThread != null) return;
        // The custom in-pipeline tap is primary: stop the legacy Android
        // Visualizer if it's running so only one PCM capture path is active.
        try {
            AudioVisualizer legacy = AudioVisualizer.getInstance();
            if (legacy.isActive()) {
                legacy.deactivate();
                Log.i(TAG, "Deactivated legacy Visualizer — custom FFT tap is primary");
            }
        } catch (Exception ignored) {}
        // A new ring: its indices start again at 0, so forget the old mapping
        // before anything lands on it.
        ringGeneration++;
        ringEnd = 0;
        playhead = null;
        fftEnabled = true;
        nativeInitFFT();

        vizThread = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "HypeFFTViz");
            t.setPriority(Thread.MIN_PRIORITY);
            return t;
        });

        vizThread.scheduleAtFixedRate(() -> {
            try {
                // What is being heard now; every read below ends a little past it.
                final Playhead p = playhead;
                final long nowNs = System.nanoTime();
                final long heard = heardNow(p, nowNs);
                final long drawEnd = heard < 0 ? -1 : ahead(p, heard, DRAW_LEAD_NS);

                // Compute FFT bands in C++
                float[] bands = fftSink != null ? nativeComputeBands(drawEnd) : null;
                if (bands != null) {
                    mainHandler.post(() -> {
                        try {
                            if (fftSink != null) fftSink.success(bands);
                        } catch (Exception ignored) {}
                    });
                }

                // The bass heard since the last tick, for the radial visualizer.
                if (beatSink != null) {
                    final long beatEnd = heard < 0 ? -1 : ahead(p, heard, BEAT_LOOKAHEAD_NS);
                    float[] beat = nativeComputeBeat(beatEnd, latestSampleRate);
                    if (beat != null) {
                        final java.util.HashMap<String, Object> frame = new java.util.HashMap<>(2);
                        frame.put("f", beat);
                        if (heard >= 0) {
                            // When its last hop will be heard, in µs on
                            // CLOCK_MONOTONIC — the clock Dart's Timeline.now
                            // reads — so Dart can put each hit on screen then.
                            frame.put("heard", nowNs / 1000L
                                    + (beatEnd - heard) * 1_000_000L / p.sampleRate);
                        }
                        mainHandler.post(() -> {
                            try {
                                if (beatSink != null) beatSink.success(frame);
                            } catch (Exception ignored) {}
                        });
                    }
                }

                // The bar spectrum, ending where the bands do.
                if (spectrumSink != null) {
                    float[] spectrum = nativeComputeSpectrum(drawEnd, latestSampleRate);
                    if (spectrum != null) {
                        mainHandler.post(() -> {
                            try {
                                if (spectrumSink != null) spectrumSink.success(spectrum);
                            } catch (Exception ignored) {}
                        });
                    }
                }

                // Also send waveform if listener is active
                byte[] waveform = waveformSink != null ? nativeGetWaveform(drawEnd) : null;
                if (waveform != null && waveformSink != null) {
                    mainHandler.post(() -> {
                        try {
                            if (waveformSink != null) waveformSink.success(waveform);
                        } catch (Exception ignored) {}
                    });
                }
            } catch (Exception e) {
                Log.w(TAG, "FFT viz tick error: " + e.getMessage());
            }
        }, 0, frameIntervalMs, TimeUnit.MILLISECONDS);

        Log.i(TAG, "FFT viz thread started at " + (1000 / frameIntervalMs) + " fps");
    }

    private static void stopFftVizThread() {
        // Order matters (teardown race, use-after-free):
        //  1. Clear fftEnabled FIRST so the audio thread stops calling
        //     nativePushSamples and the viz tick stops after its current pass.
        //  2. Wait for any in-flight viz tick (which may be inside
        //     nativeComputeBands / nativeGetWaveform) to finish before
        //     nativeDestroyFFT() frees the native FFT object. The C++ side
        //     also guards g_fftViz with a mutex to close the audio-thread
        //     window, but draining the viz executor here avoids the wait.
        fftEnabled = false;
        if (vizThread != null) {
            vizThread.shutdown();
            try {
                vizThread.awaitTermination(500, TimeUnit.MILLISECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            vizThread = null;
        }
        nativeDestroyFFT();
        Log.i(TAG, "FFT viz thread stopped");
    }
}
