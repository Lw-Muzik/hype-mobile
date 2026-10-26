package x.a.zix;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ContentResolver;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.media.MediaMetadataRetriever;
import android.media.audiofx.Visualizer;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Log;
import android.media.MediaScannerConnection;
import android.view.KeyEvent;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.IntentSenderRequest;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.activity.EdgeToEdge;

import com.ryanheise.audioservice.AudioServiceFragmentActivity;

import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends AudioServiceFragmentActivity {
    /// Picture-in-picture: the channel the Dart side listens on, and the state
    /// needed to enter the mode when the user leaves.
    private MethodChannel pipChannel;

    /// Whether a video is playing and would be worth floating. Set by Dart, read
    /// at the one moment Android offers: the user leaving the app.
    private boolean pipWanted = false;

    /// The video's shape, so the floating window matches it instead of guessing.
    private int pipWidth = 16;
    private int pipHeight = 9;

    /// Whether the transport is playing, so the floating window's button shows
    /// the action it will perform rather than the state it is in.
    private boolean pipPlaying = true;

    /// The broadcast the floating window's buttons send back to us.
    ///
    /// PiP actions are PendingIntents fired by the system, not callbacks: the
    /// window is drawn by SystemUI and the app is not on screen, so a tap has
    /// to travel back in as an Intent. Kept package-private on purpose — an
    /// exported receiver here would let any app drive playback.
    private static final String PIP_ACTION = "x.a.zix.PIP_CONTROL";
    private static final String PIP_EXTRA = "control";

    private BroadcastReceiver pipReceiver;

    /**
     * The buttons the floating window shows.
     *
     * Without these the window is a picture and nothing else: once the app is
     * off screen there is no way to pause, and the only way to skip a track is
     * to bring the whole app back. Android's own media apps all carry these
     * three, and their absence is the difference between a video that floats
     * and a video the user can still operate.
     */
    private java.util.List<android.app.RemoteAction> pipActions() {
        java.util.List<android.app.RemoteAction> actions = new java.util.ArrayList<>();
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) {
            return actions;
        }
        actions.add(pipAction(
                android.R.drawable.ic_media_previous, "Previous", "previous", 1));
        actions.add(pipAction(
                pipPlaying ? android.R.drawable.ic_media_pause
                        : android.R.drawable.ic_media_play,
                pipPlaying ? "Pause" : "Play",
                pipPlaying ? "pause" : "play",
                2));
        actions.add(pipAction(
                android.R.drawable.ic_media_next, "Next", "next", 3));
        return actions;
    }

    private android.app.RemoteAction pipAction(
            int icon, String title, String control, int requestCode) {
        Intent intent = new Intent(PIP_ACTION)
                .setPackage(getPackageName())
                .putExtra(PIP_EXTRA, control);
        // A distinct requestCode per action: PendingIntents with equal request
        // codes and matching Intents are the SAME object, so reusing one would
        // make every button do whatever the last one registered.
        PendingIntent pending = PendingIntent.getBroadcast(
                this,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return new android.app.RemoteAction(
                android.graphics.drawable.Icon.createWithResource(this, icon),
                title,
                title,
                pending);
    }

    /** Redraws the window's buttons, for when play becomes pause. */
    private void refreshPipActions() {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return;
        if (!isInPictureInPictureMode()) return;
        try {
            setPictureInPictureParams(new android.app.PictureInPictureParams.Builder()
                    .setAspectRatio(clampRatio(pipWidth, pipHeight))
                    .setActions(pipActions())
                    .build());
        } catch (IllegalStateException | IllegalArgumentException e) {
            android.util.Log.w("MainActivity", "PiP refresh refused: " + e.getMessage());
        }
    }

    private boolean supportsPip() {
        return android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O
                && getPackageManager().hasSystemFeature(
                        android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE);
    }

    /**
     * Enters picture-in-picture, or reports that it could not.
     *
     * Android refuses aspect ratios outside roughly 1:2.39–2.39:1, and throws
     * rather than declining, so the ratio is clamped before it is offered.
     */
    private boolean enterPip(Integer width, Integer height) {
        if (!supportsPip()) return false;
        final int w = width != null && width > 0 ? width : pipWidth;
        final int h = height != null && height > 0 ? height : pipHeight;
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                android.util.Rational ratio = clampRatio(w, h);
                android.app.PictureInPictureParams params =
                        new android.app.PictureInPictureParams.Builder()
                                .setAspectRatio(ratio)
                                .setActions(pipActions())
                                .build();
                return enterPictureInPictureMode(params);
            }
        } catch (IllegalStateException | IllegalArgumentException e) {
            // The activity was not in a state that allows it — mid-teardown, or
            // the device disallows PiP for this app. Not worth a crash.
            android.util.Log.w("MainActivity", "PiP refused: " + e.getMessage());
        }
        return false;
    }

    /** A ratio Android will accept, as close to the video's as it allows. */
    private android.util.Rational clampRatio(int width, int height) {
        final double max = 2.39;
        final double min = 1 / max;
        double ratio = (double) width / (double) height;
        if (ratio > max) ratio = max;
        if (ratio < min) ratio = min;
        // Scaled to integers because Rational takes them, and 1000 is plenty of
        // precision for a window a few centimetres across.
        return new android.util.Rational((int) Math.round(ratio * 1000), 1000);
    }

    @Override
    protected void onDestroy() {
        // A receiver registered against the Activity outlives it if nobody says
        // otherwise, and Android logs that as a leak on every rotation.
        if (pipReceiver != null) {
            try {
                unregisterReceiver(pipReceiver);
            } catch (IllegalArgumentException e) {
                // Already gone. Nothing to undo.
            }
            pipReceiver = null;
        }
        super.onDestroy();
    }

    @Override
    public void onUserLeaveHint() {
        super.onUserLeaveHint();
        // The only callback Android gives for "the user pressed home", which is
        // the gesture every video app treats as "keep playing, but smaller".
        if (pipWanted) enterPip(pipWidth, pipHeight);
    }

    @Override
    public void onPictureInPictureModeChanged(
            boolean inPictureInPicture, android.content.res.Configuration config) {
        super.onPictureInPictureModeChanged(inPictureInPicture, config);
        // Flutter shrinks the whole app, so Dart has to know to draw the video
        // alone. Without this the floating window shows a miniature of the
        // entire player screen, controls and all.
        if (pipChannel != null) {
            pipChannel.invokeMethod("changed", inPictureInPicture);
        }
    }

    // static {
    // System.loadLibrary("eq_app");
    // }

    private static final String CHANNEL = "eq_app";
    private final AudioVisualizer visualizer = AudioVisualizer.getInstance();
    private MethodChannel visualizerChannel; // Define the MethodChannel here
    private ProjectMRenderer projectMRenderer;

    // Scoped-storage write state
    private ActivityResultLauncher<IntentSenderRequest> writeRequestLauncher;
    private ActivityResultLauncher<IntentSenderRequest> deleteRequestLauncher;
    private MethodChannel.Result pendingDeleteResult;
    private String pendingDeletePath;
    private MethodChannel.Result pendingWriteResult;
    // Repairing YouTube downloads: the files another app owns, waiting on one
    // consent dialog for the whole batch.
    private ActivityResultLauncher<IntentSenderRequest> batchWriteLauncher;
    private List<String[]> pendingBatch;
    private List<Uri> pendingBatchUris;
    private Map<String, Boolean> pendingBatchDone;
    private MethodChannel.Result pendingBatchResult;
    private Uri pendingWriteUri;
    private File pendingModifiedFile;
    private String pendingWriteFilePath;

    @Override
    protected void onCreate(Bundle savedInstance) {
        EdgeToEdge.enable(this);
        super.onCreate(savedInstance);
        // Tapped from the Hype Connect notification? (A re-launch arrives in onNewIntent.)
        ConnectChannel.handleLaunchIntent(getIntent());
        new HeadphoneService();
        // Initialize AudioProcessor singletons so just_audio can discover them
        RoomEffectsProcessor.getInstance();
        VisualizerTapProcessor.getInstance();

        // The floating window's buttons come back as broadcasts. Registered
        // NOT_EXPORTED so only this app can send them: an exported receiver
        // would hand any installed app control of playback.
        pipReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent == null || !PIP_ACTION.equals(intent.getAction())) return;
                final String control = intent.getStringExtra(PIP_EXTRA);
                if (control == null || pipChannel == null) return;
                pipChannel.invokeMethod("control", control);
            }
        };
        android.content.IntentFilter pipFilter = new android.content.IntentFilter(PIP_ACTION);
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipReceiver, pipFilter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(pipReceiver, pipFilter);
        }

        // Deleting a track the app does not own needs the user's consent on
        // Android 11+, and the consent arrives as an Activity result rather
        // than a return value — hence the pending fields.
        deleteRequestLauncher = registerForActivityResult(
                new ActivityResultContracts.StartIntentSenderForResult(),
                activityResult -> {
                    if (pendingDeleteResult == null) return;
                    final boolean ok = activityResult.getResultCode() == Activity.RESULT_OK;
                    if (ok && pendingDeletePath != null) {
                        TagWriter.scanFile(getApplicationContext(), pendingDeletePath);
                    }
                    pendingDeleteResult.success(ok);
                    pendingDeleteResult = null;
                    pendingDeletePath = null;
                });

        batchWriteLauncher = registerForActivityResult(
                new ActivityResultContracts.StartIntentSenderForResult(),
                activityResult -> {
                    final MethodChannel.Result res = pendingBatchResult;
                    if (res == null) return;
                    final List<String[]> batch = pendingBatch;
                    final List<Uri> uris = pendingBatchUris;
                    final Map<String, Boolean> done = pendingBatchDone;
                    pendingBatchResult = null;
                    pendingBatch = null;
                    pendingBatchUris = null;
                    pendingBatchDone = null;
                    final boolean granted = activityResult.getResultCode() == Activity.RESULT_OK;
                    new Thread(() -> {
                        for (int i = 0; i < batch.size(); i++) {
                            boolean ok = false;
                            if (granted) {
                                try {
                                    YtDownloadFinisher.copyToUri(getContentResolver(), uris.get(i),
                                            new File(batch.get(i)[1]));
                                    ok = true;
                                } catch (Exception e) {
                                    Log.w("YtDownloadFinisher", "replace failed: " + batch.get(i)[0], e);
                                }
                            }
                            done.put(batch.get(i)[0], ok);
                        }
                        finishReplace(done, res);
                    }, "replaceAudioFiles").start();
                }
        );

        // Register launcher for MediaStore write-permission dialog (Android 11+)
        writeRequestLauncher = registerForActivityResult(
                new ActivityResultContracts.StartIntentSenderForResult(),
                activityResult -> {
                    if (pendingWriteResult == null) return;
                    boolean ok = false;
                    if (activityResult.getResultCode() == Activity.RESULT_OK
                            && pendingModifiedFile != null && pendingWriteUri != null) {
                        ok = LyricsManager.writeToUri(
                                getContentResolver(), pendingWriteUri, pendingModifiedFile);
                    }
                    if (pendingModifiedFile != null) pendingModifiedFile.delete();
                    if (ok && pendingWriteFilePath != null) {
                        TagWriter.scanFile(getApplicationContext(), pendingWriteFilePath);
                    }
                    pendingWriteResult.success(ok);
                    pendingWriteResult = null;
                    pendingWriteUri = null;
                    pendingModifiedFile = null;
                    pendingWriteFilePath = null;
                }
        );
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        // Phone as a remote: the keys step the playing device's volume, not
        // this phone's silent one. Before DVC, which would otherwise take them.
        if (ConnectVolume.isRemoteKey(keyCode)
                && ConnectChannel.sendVolumeKey(
                        keyCode == KeyEvent.KEYCODE_VOLUME_UP ? "up" : "down")) {
            return true;
        }
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (DvcController.onVolumeButton("up")) return true;
        } else if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (DvcController.onVolumeButton("down")) return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    @Override
    public boolean onKeyUp(int keyCode, KeyEvent event) {
        // The matching key-up, or the system's own path still clicks and shows
        // its volume panel for the phone's stream.
        if (ConnectVolume.isRemoteKey(keyCode)) return true;
        return super.onKeyUp(keyCode, event);
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        ConnectChannel.handleLaunchIntent(intent);
    }

    @SuppressLint("NewApi")
    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

        // Hype Connect's background service channel. Also attached by
        // ConnectService itself when it creates this engine with no activity.
        ConnectChannel.attach(flutterEngine, this);

        // DVC init & EventChannel
        DvcController.init(this);
        EventChannel dvcEventChannel = new EventChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/dvc_volume_button");
        DvcController.setupEventChannel(dvcEventChannel);

        // Live stems: engine init + status events (cpp/stems)
        StemEngineBridge.init(this);
        StemEngineBridge.setupEventChannel(new EventChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/stems_events"));

        // FFT Visualizer EventChannels (replaces android.media.audiofx.Visualizer)
        EventChannel fftChannel = new EventChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/fft_bands");
        fftChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override public void onListen(Object arguments, EventChannel.EventSink events) {
                VisualizerTapProcessor.setFftSink(events);
            }
            @Override public void onCancel(Object arguments) {
                VisualizerTapProcessor.setFftSink(null);
            }
        });
        EventChannel waveformChannel = new EventChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/waveform");
        waveformChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override public void onListen(Object arguments, EventChannel.EventSink events) {
                VisualizerTapProcessor.setWaveformSink(events);
            }
            @Override public void onCancel(Object arguments) {
                VisualizerTapProcessor.setWaveformSink(null);
            }
        });
        // Bass energy timed to what is being heard: the radial visualizer's hits.
        EventChannel beatChannel = new EventChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/beat");
        beatChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override public void onListen(Object arguments, EventChannel.EventSink events) {
                VisualizerTapProcessor.setBeatSink(events);
            }
            @Override public void onCancel(Object arguments) {
                VisualizerTapProcessor.setBeatSink(null);
            }
        });

        // Screen brightness, for the swipe gesture on the video screen.
        //
        // A *window* brightness override rather than a system setting: it needs
        // no permission, it applies only while this app is in front, and Android
        // drops it the moment the window goes away — which is exactly the
        // lifetime a video player's brightness should have. Writing the system
        // brightness instead would change every other app on the phone and
        // outlive the video by however long until the user noticed.
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/screen_brightness")
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "get": {
                            float value = getWindow().getAttributes().screenBrightness;
                            // BRIGHTNESS_OVERRIDE_NONE (-1) means "whatever the
                            // system decides", which is not a number to show on a
                            // slider. Reported as null so Dart shows its own
                            // starting point rather than a negative percentage.
                            result.success(value < 0 ? null : (double) value);
                            break;
                        }
                        case "set": {
                            Double value = call.argument("value");
                            android.view.WindowManager.LayoutParams params =
                                    getWindow().getAttributes();
                            params.screenBrightness = value == null
                                    ? android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                                    : Math.max(0.01f, Math.min(1f, value.floatValue()));
                            getWindow().setAttributes(params);
                            result.success(null);
                            break;
                        }
                        case "keepAwake": {
                            // FLAG_KEEP_SCREEN_ON rather than a wake lock: it
                            // needs no permission, it is scoped to this window,
                            // and Android clears it when the window goes away —
                            // so a crash cannot leave the user's screen pinned
                            // on. Audio-only playback deliberately does not set
                            // it; only a picture nobody is touching does.
                            final Boolean on = call.argument("on");
                            final boolean keep = on != null && on;
                            runOnUiThread(() -> {
                                if (keep) {
                                    getWindow().addFlags(
                                        android.view.WindowManager.LayoutParams
                                            .FLAG_KEEP_SCREEN_ON);
                                } else {
                                    getWindow().clearFlags(
                                        android.view.WindowManager.LayoutParams
                                            .FLAG_KEEP_SCREEN_ON);
                                }
                            });
                            result.success(null);
                            break;
                        }
                        default:
                            result.notImplemented();
                    }
                });

        // The MediaStore importer, on THIS engine as well as the background one.
        //
        // It was reachable only from the flutter_foreground_task engine, which
        // hosts the sharing server's `POST /upload`. But a YouTube download runs
        // on the UI engine, so `NativeMediaStore.importAudio` found no handler
        // there and threw MissingPluginException — the file downloaded, the
        // library insert failed, and the track appeared nowhere. Attaching the
        // same handler here costs one channel and is what makes a download
        // land in the phone's music library.
        HypeMediaStoreChannel.attach(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                getApplicationContext());

        // Picture-in-picture.
        //
        // Flutter draws the whole app into one window, so entering PiP shrinks
        // *everything*. The Dart side answers that by rendering the video alone
        // while `pipChannel` reports being in the mode — which is why the state
        // is pushed back rather than merely accepted.
        pipChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(), "eq_app/pip");
        pipChannel.setMethodCallHandler((call, result) -> {
            switch (call.method) {
                case "isSupported":
                    result.success(supportsPip());
                    break;
                case "enter": {
                    final Integer width = call.argument("width");
                    final Integer height = call.argument("height");
                    result.success(enterPip(width, height));
                    break;
                }
                case "setPlaying": {
                    // Only the buttons change, never the mode: calling this
                    // while not in PiP is a no-op inside refreshPipActions.
                    final Boolean playing = call.argument("playing");
                    pipPlaying = playing == null || playing;
                    refreshPipActions();
                    result.success(null);
                    break;
                }
                case "setAutoEnter": {
                    // Remembered rather than acted on: the moment that matters
                    // is the user leaving, which arrives at onUserLeaveHint.
                    final Boolean on = call.argument("on");
                    pipWanted = on != null && on;
                    final Integer width = call.argument("width");
                    final Integer height = call.argument("height");
                    if (width != null && height != null) {
                        pipWidth = width;
                        pipHeight = height;
                    }
                    result.success(null);
                    break;
                }
                default:
                    result.notImplemented();
            }
        });

        // projectM renderer init
        projectMRenderer = new ProjectMRenderer(this, flutterEngine.getRenderer());

        visualizerChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        visualizerChannel.setMethodCallHandler(
                (call, result) -> {
                    switch (call.method) {
                        case "activate_visualizer":
                            if (visualizer.isActive()) {
                                // Answer the channel so the Dart future completes
                                // instead of dangling forever on early return.
                                result.success(null);
                                return;
                            }
                            // Single active capture path: if the custom in-pipeline
                            // tap (FFT/projectM) is running, don't also start the
                            // legacy Android Visualizer (avoids dual PCM capture).
                            if (VisualizerTapProcessor.isCustomTapActive()) {
                                result.success(null);
                                return;
                            }
                            visualizer.activate(new Visualizer.OnDataCaptureListener() {
                                @SuppressLint("NewApi")
                                @Override
                                public void onWaveFormDataCapture(Visualizer visualizer, byte[] waveform,
                                        int samplingRate) {
                                    Map<String, Object> args = new HashMap<>();
                                    args.put("waveform", waveform);
                                    args.put("sampleRate", samplingRate);

                                    // Initialize the visualization frame rate controls
                                    // Sleep for a second to slow down the rendering.
                                    visualizerChannel.invokeMethod("onWaveformVisualization", args);
                                }

                                @Override
                                public void onFftDataCapture(Visualizer visualizer, byte[] sharedFft,
                                        int samplingRate) {
                                    Map<String, Object> args = new HashMap<>();
                                    args.put("fft", sharedFft);
                                    visualizerChannel.invokeMethod("onFftVisualization", args);
                                }
                            });
                            // Legacy Android Visualizer now active — answer the
                            // channel so the Dart future completes.
                            result.success(null);
                            break;

                        case "enableVisual":
                            boolean enable = Boolean.TRUE.equals(call.argument("enableVisual"));
                            visualizer.enableVisual(enable);
                            break;

                        case "getEnabled":
                            boolean eqEnabled = visualizer.isEnabled();
                            result.success(eqEnabled);
                            break;

                        case "setScalingMode":
                            boolean scale = Boolean.TRUE.equals(call.argument("scale"));
                            visualizer.setScalingMode(scale);
                            break;

                        case "setFrameRate":
                            int frameRate = call.argument("frameRate");
                            VisualizerTapProcessor.setFrameRate(frameRate);
                            break;

                        case "setVizSmoothing": {
                            double attack = call.argument("attack");
                            double decay = call.argument("decay");
                            VisualizerTapProcessor.setSmoothing((float) attack, (float) decay);
                            break;
                        }

                        case "setVizGain": {
                            double gain = call.argument("gain");
                            VisualizerTapProcessor.setGain((float) gain);
                            break;
                        }

                        case "init":
                            // Legacy — EQ + MBC now handled by C++ DSP pipeline
                            break;

                        case "enableEq":
                            boolean enableEq = call.argument("enable");
                            RoomEffectsProcessor.broadcastEqEnabled(enableEq);
                            break;
                        case "isEnabled":
                            // EQ is now always available (C++ pipeline, no API level requirement)
                            result.success(true);
                            break;

                        // ==================== Preamp ====================
                        case "setPreamp":
                            double preampGain = call.argument("gain");
                            RoomEffectsProcessor.broadcastPreampGain((float) preampGain);
                            result.success(null);
                            break;
                        case "getPreamp":
                            result.success((double) RoomEffectsProcessor.getCachedPreampGain());
                            break;

                        // ==================== MBC Toggle ====================
                        case "enableMbc":
                            boolean mbcEnable = call.argument("enable");
                            RoomEffectsProcessor.broadcastMbcEnabled(mbcEnable);
                            result.success(null);
                            break;
                        case "isMbcEnabled":
                            result.success(RoomEffectsProcessor.isCachedMbcEnabled());
                            break;

                        // bassboost
                        case "initBassBoost":

                            BassEq.init(AudioManager.AUDIO_SESSION_ID_GENERATE);
                            break;

                        case "enableBassBoost":
                            boolean enableB = call.argument("enableBass");
                            BassEq.enable(enableB);
                            break;
                        case "isBassEnabled":
                            boolean isBassEnabled = BassEq.isEnabled();
                            result.success(isBassEnabled);
                            break;

                        case "bassBoostStrength":
                            int strengthB = ((int) BassEq.getStrength());
                            result.success(strengthB);
                            break;
                        case "setBassBoostStrength":
                            int strengthBB = call.argument("strength");
                            BassEq.setStrength(strengthBB);
                            break;
                        // loudnessEnhancer (legacy init — still needed for session binding)
                        case "initLoudnessEnhancer":
                            int sessionIdL = call.argument("sessionId");
                            LoudnessControl.init(sessionIdL);
                            break;
                        case "enableLoudnessEnhancer":
                            boolean enableL = call.argument("enableLoud");
                            LoudnessControl.enable(enableL);
                            break;
                        case "loudnessEnhancerEnabled":
                            boolean enabled = LoudnessControl.isEnabled();
                            result.success(enabled);
                            break;
                        case "loudnessEnhancerStrength":
                            float strengthL = LoudnessControl.getTargetGain();
                            result.success(strengthL);
                            break;
                        case "setLoudnessEnhancerStrength":
                            int strengthLL = call.argument("strength");
                            LoudnessControl.setTargetGain(strengthLL);
                            break;

                        // ==================== DVC (Direct Volume Control) ====================
                        case "enableDvc":
                            DvcController.enable(getApplicationContext());
                            result.success(null);
                            break;
                        case "disableDvc":
                            DvcController.disable(getApplicationContext());
                            result.success(null);
                            break;
                        case "setDvcGain":
                            double dvcGainDb = call.argument("gain");
                            DvcController.setGain((float) dvcGainDb);
                            result.success(null);
                            break;
                        case "getDvcGain":
                            double dvcGainVal = (double) LoudnessControl.getTargetGain();
                            result.success(dvcGainVal);
                            break;
                        case "isDvcActive":
                            result.success(DvcController.isActive());
                            break;
                        case "getSystemVolume":
                            result.success(DvcController.getCurrentSystemVolume());
                            break;
                        case "getSystemMaxVolume":
                            result.success(DvcController.getMaxVolume());
                            break;

                        // ==================== MBC Compressor Settings ====================
                        case "setDspNoiseThreshold": {
                            double noiseThreshold = call.argument("noiseThreshold");
                            RoomEffectsProcessor.broadcastMbcNoiseGate((float) noiseThreshold);
                            result.success(null);
                            break;
                        }
                        case "setPreGain": {
                            double preGain = call.argument("preGain");
                            RoomEffectsProcessor.broadcastMbcPreGain((float) preGain);
                            result.success(null);
                            break;
                        }
                        case "expandRatio": {
                            double expandRatio = call.argument("expandRatio");
                            RoomEffectsProcessor.broadcastMbcExpanderRatio((float) expandRatio);
                            result.success(null);
                            break;
                        }
                        case "kneeWidth": {
                            double kneeWidth = call.argument("kneeWidth");
                            RoomEffectsProcessor.broadcastMbcKneeWidth((float) kneeWidth);
                            result.success(null);
                            break;
                        }

                        // ==================== Tone Controls (Bass/Treble) ====================
                        case "dspSetToneEnabled": {
                            boolean en = call.argument("enabled");
                            RoomEffectsProcessor.broadcastToneEnabled(en);
                            result.success(null);
                            break;
                        }
                        case "dspSetBassGain": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastBassGain((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetBassFreq": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastBassFreq((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetBassQ": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastBassQ((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetTrebleGain": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastTrebleGain((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetTrebleFreq": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastTrebleFreq((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetTrebleQ": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastTrebleQ((float) v);
                            result.success(null);
                            break;
                        }

                        // ==================== Output Limiter ====================
                        case "dspSetLimiterEnabled": {
                            boolean en = call.argument("enabled");
                            RoomEffectsProcessor.broadcastLimiterEnabled(en);
                            result.success(null);
                            break;
                        }
                        case "dspSetLimiterCeiling": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastLimiterCeiling((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetLimiterRelease": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastLimiterRelease((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetLimiterKnee": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastLimiterKnee((float) v);
                            result.success(null);
                            break;
                        }

                        // Legacy DSP stubs — no-ops for backward compatibility
                        case "initDSPEngine":
                        case "enableDSP":
                        case "disposeDSP":
                        case "setDSPSpeakers":
                        case "setDSPXBass":
                        case "setExtraBass":
                        case "setDSPPowerBass":
                        case "setDSPXTreble":
                        case "setDSPVolume":
                        case "setTunerBass":
                        case "setCutOffFreq":
                        case "setTrebleFreq":
                        case "setTunerVocal":
                            // Removed — all DSP processing handled by C++ pipeline
                            break;
                        case "getVocalLevel":
                            result.success(0.0f);
                            break;

                        case "initPresetReverb":
                            int audioId = call.argument("priorityId");
                            ReverbEngine.initPresetReverb(audioId);
                            break;
                        case "enablePresetReverb":
                            boolean enablePreset = call.argument("enablePreset");
                            int check = ReverbEngine.enablePresetReverb(enablePreset);
                            result.success(check);
                            break;
                        case "setReverbPreset":
                            int pPreset = (int) call.argument("preset");
                            ReverbEngine.setPreset(pPreset);
                            break;

                        case "getReverbPreset":
                            short g = ReverbEngine.getPreset();
                            result.success(((short) g));
                            break;
                        case "deleteManager": {
                            String operation = call.argument("filePath");
                            if (operation == null) {
                                result.success(false);
                                break;
                            }
                            File f = new File(operation);
                            boolean folderOk = false;
                            if (f.exists() && f.isDirectory()) {
                                folderOk = DeleteManager.deleteFolder(f);
                                showMessage(folderOk
                                        ? String.format("%s deleted successfully.",
                                                operation.split("/")[
                                                        operation.split("/").length - 1])
                                        : "Failed to delete the folder.");
                            } else {
                                showMessage("Folder does not exist or is not a directory.");
                            }
                            // Previously this returned nothing at all, so the Dart
                            // future never completed and every caller awaited a
                            // delete that had already happened.
                            result.success(folderOk);
                            break;
                        }

                        // Deleting ONE track.
                        //
                        // `deleteManager` above only ever handled directories, so a
                        // track path fell into its else branch and reported that a
                        // folder did not exist. This is the per-track path, and it
                        // has to respect scoped storage: from Android 11 a file the
                        // app did not create cannot simply be unlinked, and
                        // File.delete() returns false without saying why.
                        case "deleteAudio": {
                            final String delPath = call.argument("filePath");
                            if (delPath == null) {
                                result.success(false);
                                break;
                            }
                            final File df = new File(delPath);

                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                                boolean ok = df.delete();
                                if (ok) TagWriter.scanFile(getApplicationContext(), delPath);
                                result.success(ok);
                                break;
                            }

                            final Uri delUri =
                                    LyricsManager.getMediaUri(getContentResolver(), delPath);
                            if (delUri == null) {
                                // Not in MediaStore — an app-private file, such as one
                                // of our own downloads before it is published. Ours to
                                // remove without ceremony.
                                boolean ok = df.delete();
                                result.success(ok);
                                break;
                            }

                            // Rows this app inserted itself delete without a prompt.
                            // Try that first so a downloaded track does not ask the
                            // user for permission to remove what the app just wrote.
                            try {
                                int rows = getContentResolver().delete(delUri, null, null);
                                if (rows > 0) {
                                    result.success(true);
                                    break;
                                }
                            } catch (SecurityException needsConsent) {
                                // Someone else's file: fall through and ask.
                            }

                            try {
                                pendingDeleteResult = result;
                                pendingDeletePath = delPath;
                                PendingIntent dpi = MediaStore.createDeleteRequest(
                                        getContentResolver(),
                                        Collections.singletonList(delUri));
                                deleteRequestLauncher.launch(new IntentSenderRequest.Builder(
                                        dpi.getIntentSender()).build());
                            } catch (Exception e) {
                                pendingDeleteResult = null;
                                pendingDeletePath = null;
                                android.util.Log.w("MainActivity",
                                        "delete request failed: " + e.getMessage());
                                result.success(false);
                            }
                            break;
                        }
                        case "showNativeMessage":
                            String message = call.argument("message");
                            showMessage(message);
                            break;
                        // ==================== Custom DSP Room Effects ====================
                        case "dspSetReverbEnabled": {
                            boolean en = call.argument("enabled");
                            RoomEffectsProcessor.broadcastReverbEnabled(en);
                            result.success(null);
                            break;
                        }
                        case "dspSetRoomSize": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastRoomSize((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetDecay": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastDecay((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetDamping": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastDamping((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetPreDelay": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastPreDelay((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetDiffusion": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastDiffusion((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetReverbWetDry": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastReverbWetDry((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetStereoExpandEnabled": {
                            boolean en = call.argument("enabled");
                            RoomEffectsProcessor.broadcastStereoExpandEnabled(en);
                            result.success(null);
                            break;
                        }
                        case "dspSetStereoWidth": {
                            double v = call.argument("value");
                            RoomEffectsProcessor.broadcastStereoWidth((float) v);
                            result.success(null);
                            break;
                        }
                        case "dspSetCrossfeedEnabled": {
                            boolean en = call.argument("enabled");
                            RoomEffectsProcessor.broadcastCrossfeedEnabled(en);
                            result.success(null);
                            break;
                        }
                        case "dspSetCrossfeedParams": {
                            double cutoff = call.argument("cutoff");
                            double feed = call.argument("feed");
                            RoomEffectsProcessor.broadcastCrossfeedParams((float) cutoff, (float) feed);
                            result.success(null);
                            break;
                        }

                        // ==================== 3D Surround ====================
                        case "dspSetSurround3dEnabled": {
                            boolean en = call.argument("enabled");
                            RoomEffectsProcessor.broadcastSurround3dEnabled(en);
                            result.success(null);
                            break;
                        }
                        case "dspSetSurround3dParams": {
                            double intensity = call.argument("intensity");
                            double subwoofer = call.argument("subwoofer");
                            RoomEffectsProcessor.broadcastSurround3dParams(
                                    (float) intensity, (float) subwoofer);
                            result.success(null);
                            break;
                        }
                        case "dspSetSurround3dSpeakers": {
                            RoomEffectsProcessor.broadcastSurround3dSpeakers(
                                    Boolean.TRUE.equals(call.argument("frontL")),
                                    Boolean.TRUE.equals(call.argument("frontR")),
                                    Boolean.TRUE.equals(call.argument("sideL")),
                                    Boolean.TRUE.equals(call.argument("sideR")),
                                    Boolean.TRUE.equals(call.argument("surroundL")),
                                    Boolean.TRUE.equals(call.argument("surroundR")));
                            result.success(null);
                            break;
                        }

                        // ==================== 32-Band Graphic EQ ====================
                        case "setGraphicBandGain":
                            int gBand = call.argument("band");
                            double gGain = call.argument("gain");
                            RoomEffectsProcessor.broadcastGraphicBandGain(gBand, (float) gGain);
                            result.success(null);
                            break;
                        case "getGraphicBandGain":
                            // No longer queried from DynamicsProcessing — Dart holds the state
                            result.success(0.0f);
                            break;
                        case "setGraphicAllBands":
                            ArrayList<Double> gGains = call.argument("gains");
                            if (gGains != null) {
                                float[] gainArr = new float[gGains.size()];
                                for (int gi = 0; gi < gGains.size(); gi++) {
                                    gainArr[gi] = gGains.get(gi).floatValue();
                                }
                                RoomEffectsProcessor.broadcastGraphicAllBands(gainArr);
                            }
                            result.success(null);
                            break;
                        case "getGraphicAllBands":
                            // No longer queried from DynamicsProcessing — Dart holds the state
                            result.success(new ArrayList<Double>());
                            break;

                        // ==================== 32-Band Parametric EQ ====================
                        case "setParametricBand": {
                            int pBand = call.argument("band");
                            double pFreq = call.argument("freq");
                            double pGainV = call.argument("gain");
                            double pQ = call.argument("q") != null ? (double) call.argument("q") : 1.4;
                            int pFilterType = call.argument("filterType") != null ? (int) call.argument("filterType") : 0;
                            boolean pEnabled = call.argument("enabled") != null ? (boolean) call.argument("enabled") : true;
                            RoomEffectsProcessor.broadcastParametricBand(pBand, (float) pFreq,
                                    (float) pGainV, (float) pQ, pFilterType, pEnabled);
                            result.success(null);
                            break;
                        }
                        case "setParametricAllBands": {
                            ArrayList<Double> pFreqs = call.argument("freqs");
                            ArrayList<Double> pGains = call.argument("gains");
                            ArrayList<Double> pQs = call.argument("qs");
                            if (pFreqs != null && pGains != null) {
                                int pCount = pFreqs.size();
                                float[] freqArr = new float[pCount];
                                float[] pGainArr = new float[pCount];
                                float[] qArr = new float[pCount];
                                for (int pi = 0; pi < pCount; pi++) {
                                    freqArr[pi] = pFreqs.get(pi).floatValue();
                                    pGainArr[pi] = pGains.get(pi).floatValue();
                                    qArr[pi] = (pQs != null && pi < pQs.size()) ? pQs.get(pi).floatValue() : 1.4f;
                                }
                                RoomEffectsProcessor.broadcastParametricAllBands(freqArr, pGainArr, qArr, pCount);
                            }
                            result.success(null);
                            break;
                        }

                        // ==================== Speaker Correction EQ (AutoEq) ====================
                        case "setSpeakerEqEnabled": {
                            boolean spkEn = call.argument("enabled");
                            RoomEffectsProcessor.broadcastSpeakerEqEnabled(spkEn);
                            result.success(null);
                            break;
                        }
                        case "setSpeakerEqBands": {
                            ArrayList<Double> spkFreqs = call.argument("freqs");
                            ArrayList<Double> spkGains = call.argument("gains");
                            ArrayList<Double> spkQs = call.argument("qs");
                            ArrayList<Integer> spkTypes = call.argument("types");
                            if (spkFreqs != null && spkGains != null && spkQs != null && spkTypes != null) {
                                int spkCount = spkFreqs.size();
                                float[] sf = new float[spkCount];
                                float[] sg = new float[spkCount];
                                float[] sq = new float[spkCount];
                                int[] st = new int[spkCount];
                                for (int si = 0; si < spkCount; si++) {
                                    sf[si] = spkFreqs.get(si).floatValue();
                                    sg[si] = spkGains.get(si).floatValue();
                                    sq[si] = spkQs.get(si).floatValue();
                                    st[si] = spkTypes.get(si);
                                }
                                RoomEffectsProcessor.broadcastSpeakerEqBands(sf, sg, sq, st, spkCount);
                            }
                            result.success(null);
                            break;
                        }
                        case "clearSpeakerEq": {
                            RoomEffectsProcessor.broadcastClearSpeakerEq();
                            result.success(null);
                            break;
                        }

                        // ==================== Live Stems ====================
                        case "stemsLoadModel": {
                            StemEngineBridge.loadModel(call.argument("dir"), result);
                            break;
                        }
                        case "stemsUnloadModel": {
                            StemEngineBridge.unloadModel();
                            result.success(null);
                            break;
                        }
                        case "stemsBenchmark": {
                            StemEngineBridge.benchmark(result);
                            break;
                        }
                        case "stemsSetArmed": {
                            Boolean armed = call.argument("armed");
                            StemEngineBridge.setArmed(armed != null && armed);
                            result.success(null);
                            break;
                        }
                        case "stemsSetLevels": {
                            Number lv = call.argument("vocals");
                            Number ld = call.argument("drums");
                            Number li = call.argument("instruments");
                            StemEngineBridge.setLevels(
                                    lv == null ? 1f : lv.floatValue(),
                                    ld == null ? 1f : ld.floatValue(),
                                    li == null ? 1f : li.floatValue());
                            result.success(null);
                            break;
                        }
                        case "stemsProvideStream": {
                            StemEngineBridge.provideStream(call.argument("url"), call.argument("path"));
                            result.success(null);
                            break;
                        }
                        case "stemsGetStatus": {
                            result.success(StemEngineBridge.statusMap());
                            break;
                        }

                        // ==================== Global EQ (System-Wide) ====================
                        case "enableGlobalEq": {
                            boolean globalOn = call.argument("enable");
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                                result.success(false);
                                break;
                            }
                            if (globalOn) {
                                String preset = call.argument("preset");
                                if (preset != null) GlobalEqService.updatePreset(preset);
                                Intent svc = new Intent(getApplicationContext(), GlobalEqService.class);
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    startForegroundService(svc);
                                } else {
                                    startService(svc);
                                }
                            } else {
                                stopService(new Intent(getApplicationContext(), GlobalEqService.class));
                            }
                            result.success(true);
                            break;
                        }
                        case "isGlobalEqEnabled":
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                result.success(GlobalEqSessionManager.isEnabled());
                            } else {
                                result.success(false);
                            }
                            break;
                        case "isGlobalEqAvailable":
                            result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P);
                            break;

                        case "updateGlobalEqPreset": {
                            String preset = call.argument("preset");
                            if (preset != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                GlobalEqService.updatePreset(preset);
                            }
                            result.success(true);
                            break;
                        }

                        case "getPlayingApps": {
                            PackageManager pm = getPackageManager();
                            List<String> pkgList = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
                                    ? GlobalEqService.getPlayingApps()
                                    : new ArrayList<>();
                            List<Map<String, String>> appInfoList = new ArrayList<>();
                            for (String pkg : pkgList) {
                                Map<String, String> info = new HashMap<>();
                                info.put("package", pkg);
                                try {
                                    ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                                    info.put("name", pm.getApplicationLabel(ai).toString());
                                } catch (PackageManager.NameNotFoundException e) {
                                    info.put("name", pkg.contains(".")
                                            ? pkg.substring(pkg.lastIndexOf('.') + 1)
                                            : pkg);
                                }
                                appInfoList.add(info);
                            }
                            result.success(appInfoList);
                            break;
                        }
                        case "getAppIcon": {
                            String iconPkg = call.argument("package");
                            if (iconPkg == null) { result.success(null); break; }
                            final String finalPkg = iconPkg;
                            new Thread(() -> {
                                try {
                                    PackageManager ipm = getPackageManager();
                                    Drawable drawable = ipm.getApplicationIcon(finalPkg);
                                    Bitmap bitmap = drawableToBitmap(drawable);
                                    ByteArrayOutputStream baos = new ByteArrayOutputStream();
                                    bitmap.compress(Bitmap.CompressFormat.PNG, 90, baos);
                                    byte[] bytes = baos.toByteArray();
                                    new Handler(Looper.getMainLooper()).post(() -> result.success(bytes));
                                } catch (Exception e) {
                                    new Handler(Looper.getMainLooper()).post(() -> result.success(null));
                                }
                            }).start();
                            break;
                        }

                        // ==================== Battery Optimization ====================
                        case "isBatteryOptimizationDisabled": {
                            android.os.PowerManager pm =
                                    (android.os.PowerManager) getSystemService(POWER_SERVICE);
                            result.success(pm != null &&
                                    pm.isIgnoringBatteryOptimizations(getPackageName()));
                            break;
                        }
                        case "requestDisableBatteryOptimization": {
                            try {
                                Intent batteryIntent = new Intent(
                                        android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                                batteryIntent.setData(android.net.Uri.parse("package:" + getPackageName()));
                                startActivity(batteryIntent);
                                result.success(true);
                            } catch (Exception e) {
                                result.success(false);
                            }
                            break;
                        }

                        // ==================== Device Detection ====================
                        case "isDynamicsProcessingAvailable":
                            // Always true — C++ DSP pipeline has no API level requirement
                            result.success(true);
                            break;
                        case "getAudioOutputType":
                            String outputType = AudioOutputDetector.getAudioOutputType(getApplicationContext());
                            result.success(outputType);
                            break;

                        // ==================== Audio Metadata Extraction ====================
                        case "extractAudioMetadata": {
                            String metaUrl = call.argument("url");
                            Map<String, String> metaHeaders = call.argument("headers");
                            String artPath = call.argument("artworkPath");
                            if (metaHeaders == null) metaHeaders = new HashMap<>();
                            final Map<String, String> finalHeaders = metaHeaders;

                            // AtomicBoolean prevents double result.success() from
                            // both the worker thread and the timeout handler.
                            final AtomicBoolean completed = new AtomicBoolean(false);
                            final Handler mainHandler = new Handler(Looper.getMainLooper());

                            // MMR is created up front and shared with the timeout
                            // handler. MMR.setDataSource(url) is a blocking native
                            // call with no read timeout and is NOT interruptible via
                            // Thread.interrupt(); releasing the retriever from
                            // another thread is what aborts the stuck native call.
                            // releaseOnce guards against the worker's finally and the
                            // timeout both releasing the same native retriever.
                            final MediaMetadataRetriever mmr = new MediaMetadataRetriever();
                            final AtomicBoolean released = new AtomicBoolean(false);
                            final Runnable releaseOnce = () -> {
                                if (released.compareAndSet(false, true)) {
                                    try { mmr.release(); } catch (Exception ignored) {}
                                }
                            };
                            // Holder so the worker can cancel the pending timeout.
                            final Runnable[] timeoutRef = new Runnable[1];

                            // Run on background thread — MMR does network I/O
                            Thread worker = new Thread(() -> {
                                Map<String, Object> metadata = new HashMap<>();
                                boolean success = false;
                                try {
                                    mmr.setDataSource(metaUrl, finalHeaders);
                                    success = true; // setDataSource didn't throw

                                    String title = mmr.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_TITLE);
                                    String artist = mmr.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_ARTIST);
                                    String album = mmr.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_ALBUM);
                                    String durationStr = mmr.extractMetadata(
                                            MediaMetadataRetriever.METADATA_KEY_DURATION);

                                    if (title != null) metadata.put("title", title);
                                    if (artist != null) metadata.put("artist", artist);
                                    if (album != null) metadata.put("album", album);
                                    if (durationStr != null) {
                                        try {
                                            metadata.put("durationMs",
                                                    Integer.parseInt(durationStr));
                                        } catch (NumberFormatException ignored) {}
                                    }

                                    // Extract embedded artwork
                                    byte[] art = mmr.getEmbeddedPicture();
                                    if (art != null && artPath != null) {
                                        try (FileOutputStream fos =
                                                     new FileOutputStream(artPath)) {
                                            fos.write(art);
                                            metadata.put("hasArtwork", true);
                                        } catch (Exception ignored) {}
                                    }
                                } catch (Exception e) {
                                    e.printStackTrace();
                                } finally {
                                    releaseOnce.run();
                                }

                                // Return result on main thread (required by Flutter).
                                // success=true → return metadata map (even if empty — file
                                // has no tags). success=false → return null (extraction
                                // failed, should retry later).
                                final boolean ok = success;
                                final Map<String, Object> md = metadata;
                                if (completed.compareAndSet(false, true)) {
                                    // Cancel the pending timeout so it doesn't linger
                                    // for 15s (and can't fire after we've answered).
                                    Runnable pending = timeoutRef[0];
                                    if (pending != null) mainHandler.removeCallbacks(pending);
                                    mainHandler.post(() -> result.success(ok ? md : null));
                                }
                            });
                            worker.start();

                            // 15-second timeout — MMR has no internal read timeout
                            // and can hang indefinitely on slow/stalled connections.
                            final Runnable timeout = () -> {
                                if (completed.compareAndSet(false, true)) {
                                    // Releasing the retriever aborts the blocked
                                    // native setDataSource so the worker thread +
                                    // native retriever + socket don't linger.
                                    releaseOnce.run();
                                    worker.interrupt();
                                    result.success(null); // null = failed, retry later
                                }
                            };
                            timeoutRef[0] = timeout;
                            mainHandler.postDelayed(timeout, 15000);
                            break;
                        }

                        // ==================== Audio Fingerprinting ====================
                        case "generateFingerprint": {
                            String fpPath = call.argument("filePath");
                            final AtomicBoolean fpDone = new AtomicBoolean(false);
                            final Handler fpHandler = new Handler(Looper.getMainLooper());

                            Thread fpWorker = new Thread(() -> {
                                Map<String, Object> fpResult = FingerprintEngine.generateFingerprint(fpPath);
                                if (fpDone.compareAndSet(false, true)) {
                                    fpHandler.post(() -> result.success(fpResult));
                                }
                            });
                            fpWorker.start();

                            // 30-second timeout for decoding + fingerprinting
                            fpHandler.postDelayed(() -> {
                                if (fpDone.compareAndSet(false, true)) {
                                    fpWorker.interrupt();
                                    result.success(null);
                                }
                            }, 30000);
                            break;
                        }

                        // ==================== Tag Writing ====================
                        case "writeTags": {
                            String wtPath = call.argument("filePath");
                            Map<String, String> wtTags = call.argument("tags");
                            String wtArtwork = call.argument("artworkPath");

                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                                // Android 10 and below: direct file write
                                boolean ok = TagWriter.writeTagsDirect(wtPath, wtTags, wtArtwork);
                                if (ok) TagWriter.scanFile(getApplicationContext(), wtPath);
                                result.success(ok);
                            } else {
                                // Android 11+: scoped storage via MediaStore
                                File modified = TagWriter.prepareModifiedFile(
                                        getCacheDir(), wtPath, wtTags, wtArtwork);
                                if (modified == null) {
                                    result.success(false);
                                    break;
                                }
                                Uri uri = LyricsManager.getMediaUri(getContentResolver(), wtPath);
                                if (uri == null) {
                                    modified.delete();
                                    result.success(false);
                                    break;
                                }
                                pendingWriteResult = result;
                                pendingWriteUri = uri;
                                pendingModifiedFile = modified;
                                pendingWriteFilePath = wtPath;
                                try {
                                    PendingIntent pi = MediaStore.createWriteRequest(
                                            getContentResolver(), Collections.singletonList(uri));
                                    IntentSenderRequest req = new IntentSenderRequest.Builder(
                                            pi.getIntentSender()).build();
                                    writeRequestLauncher.launch(req);
                                } catch (Exception e) {
                                    e.printStackTrace();
                                    modified.delete();
                                    pendingWriteResult = null;
                                    pendingWriteUri = null;
                                    pendingModifiedFile = null;
                                    pendingWriteFilePath = null;
                                    result.success(false);
                                }
                            }
                            break;
                        }
                        // ==================== YouTube downloads ====================
                        case "finishYtDownload": {
                            final String ytSrc = call.argument("src");
                            final String ytDst = call.argument("dst");
                            final Map<String, Object> ytTags = call.argument("tags");
                            new Thread(() -> {
                                String error = YtDownloadFinisher.finish(ytSrc, ytDst,
                                        ytTags == null ? new HashMap<>() : ytTags);
                                if (error != null) Log.w("YtDownloadFinisher", "finish failed: " + error);
                                // true, or the reason it failed (Dart logs it).
                                runOnUiThread(() -> result.success(error == null ? (Object) Boolean.TRUE : error));
                            }, "YtDownloadFinisher").start();
                            break;
                        }
                        case "replaceAudioFiles": {
                            List<Map<String, String>> ytFiles = call.argument("files");
                            replaceAudioFiles(ytFiles, result);
                            break;
                        }
                        case "scanMediaFile": {
                            String scanPath = call.argument("filePath");
                            TagWriter.scanFile(getApplicationContext(), scanPath);
                            result.success(null);
                            break;
                        }

                        // ==================== Sharing ====================
                        // The system share sheet, for a song's link or the song
                        // itself. A file goes by its MediaStore uri with a read
                        // grant — the receiving app has no access to the path —
                        // and the uri is set as ClipData too, which is what
                        // carries the grant through the chooser to the app
                        // picked from it.
                        case "shareText": {
                            String shareText = call.argument("text");
                            Intent sendText = new Intent(Intent.ACTION_SEND);
                            sendText.setType("text/plain");
                            sendText.putExtra(Intent.EXTRA_TEXT, shareText);
                            startActivity(Intent.createChooser(sendText, null));
                            result.success(true);
                            break;
                        }
                        case "shareAudio": {
                            String sharePath = call.argument("filePath");
                            Uri shareUri = sharePath == null ? null
                                    : LyricsManager.getMediaUri(getContentResolver(), sharePath);
                            if (shareUri == null) {
                                result.success(false);
                                break;
                            }
                            String shareMime = getContentResolver().getType(shareUri);
                            Intent sendAudio = new Intent(Intent.ACTION_SEND);
                            sendAudio.setType(shareMime != null ? shareMime : "audio/*");
                            sendAudio.putExtra(Intent.EXTRA_STREAM, shareUri);
                            sendAudio.setClipData(ClipData.newRawUri("", shareUri));
                            sendAudio.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                            startActivity(Intent.createChooser(sendAudio, null));
                            result.success(true);
                            break;
                        }

                        // ==================== Lyrics ====================
                        case "readLyrics": {
                            String lyrFilePath = call.argument("filePath");
                            String lyrText = LyricsManager.readLyrics(lyrFilePath);
                            result.success(lyrText);
                            break;
                        }
                        case "writeLyrics": {
                            String lyrFilePath = call.argument("filePath");
                            String lyrContent = call.argument("lyrics");

                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                                // Android 9 and below: direct file access
                                result.success(LyricsManager.writeLyricsDirect(lyrFilePath, lyrContent));
                            } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                                // Android 10: requestLegacyExternalStorage=true allows direct access
                                result.success(LyricsManager.writeLyricsDirect(lyrFilePath, lyrContent));
                            } else {
                                // Android 11+: MediaStore + createWriteRequest
                                File modified = LyricsManager.prepareModifiedFile(
                                        getCacheDir(), lyrFilePath, lyrContent);
                                if (modified == null) {
                                    result.success(false);
                                    break;
                                }
                                Uri uri = LyricsManager.getMediaUri(getContentResolver(), lyrFilePath);
                                if (uri == null) {
                                    modified.delete();
                                    result.success(false);
                                    break;
                                }
                                // Store pending state and request write permission
                                pendingWriteResult = result;
                                pendingWriteUri = uri;
                                pendingModifiedFile = modified;
                                try {
                                    PendingIntent pi = MediaStore.createWriteRequest(
                                            getContentResolver(), Collections.singletonList(uri));
                                    IntentSenderRequest req = new IntentSenderRequest.Builder(
                                            pi.getIntentSender()).build();
                                    writeRequestLauncher.launch(req);
                                } catch (Exception e) {
                                    e.printStackTrace();
                                    modified.delete();
                                    pendingWriteResult = null;
                                    pendingWriteUri = null;
                                    pendingModifiedFile = null;
                                    result.success(false);
                                }
                            }
                            break;
                        }

                        // ==================== projectM Visualizer ====================
                        case "projectm_init": {
                            int pmWidth = call.argument("width");
                            int pmHeight = call.argument("height");
                            long textureId = projectMRenderer.init(pmWidth, pmHeight);
                            result.success(textureId);
                            break;
                        }
                        case "projectm_start": {
                            projectMRenderer.start();
                            result.success(null);
                            break;
                        }
                        case "projectm_stop": {
                            projectMRenderer.stop();
                            result.success(null);
                            break;
                        }
                        case "projectm_release": {
                            projectMRenderer.release();
                            result.success(null);
                            break;
                        }
                        case "projectm_set_preset": {
                            String presetPath = call.argument("path");
                            projectMRenderer.loadPreset(presetPath);
                            result.success(null);
                            break;
                        }
                        case "projectm_next_preset": {
                            projectMRenderer.nextPreset();
                            result.success(projectMRenderer.getCurrentPresetName());
                            break;
                        }
                        case "projectm_prev_preset": {
                            projectMRenderer.previousPreset();
                            result.success(projectMRenderer.getCurrentPresetName());
                            break;
                        }
                        case "projectm_load_preset_index": {
                            int pmIndex = call.argument("index");
                            projectMRenderer.loadPresetByIndex(pmIndex);
                            result.success(projectMRenderer.getCurrentPresetName());
                            break;
                        }
                        case "projectm_list_presets": {
                            result.success(new ArrayList<>(projectMRenderer.getPresetNames()));
                            break;
                        }
                        case "projectm_current_preset": {
                            result.success(projectMRenderer.getCurrentPresetName());
                            break;
                        }
                        case "projectm_set_fps": {
                            int pmFps = call.argument("fps");
                            projectMRenderer.setFps(pmFps);
                            result.success(null);
                            break;
                        }
                        case "projectm_set_beat_sensitivity": {
                            double pmSens = call.argument("sensitivity");
                            projectMRenderer.setBeatSensitivity((float) pmSens);
                            result.success(null);
                            break;
                        }
                        case "projectm_set_preset_duration": {
                            double pmDur = call.argument("duration");
                            projectMRenderer.setPresetDuration(pmDur);
                            result.success(null);
                            break;
                        }
                        case "projectm_set_preset_locked": {
                            boolean pmLocked = call.argument("locked");
                            projectMRenderer.setPresetLocked(pmLocked);
                            result.success(null);
                            break;
                        }
                        case "projectm_set_size": {
                            int pmW = call.argument("width");
                            int pmH = call.argument("height");
                            projectMRenderer.setSize(pmW, pmH);
                            result.success(null);
                            break;
                        }
                        case "projectm_set_mesh_size": {
                            int meshW = call.argument("width");
                            int meshH = call.argument("height");
                            projectMRenderer.setMeshSize(meshW, meshH);
                            result.success(null);
                            break;
                        }

                        default:
                            result.notImplemented();
                            break;
                    }
                });
    }

    protected void showMessage(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    private class HeadphoneService extends BroadcastReceiver {
        private static final long DOUBLE_CLICK_TIME_THRESHOLD = 500; // Time threshold for a double click in
                                                                     // milliseconds
        private long lastClickTime = 0;

        @Override
        public void onReceive(Context context, Intent intent) {
            if (intent.getAction() != null && intent.getAction().equals(AudioManager.ACTION_HEADSET_PLUG)) {
                long currentTime = System.currentTimeMillis();

                // Check for a double click by comparing the time between two clicks
                if (currentTime - lastClickTime < DOUBLE_CLICK_TIME_THRESHOLD) {
                    // Double click detected, perform your action here (e.g., play the next track)
                    playNextTrack();
                }

                lastClickTime = currentTime;
            }
        }

        private void playNextTrack() {
            // Add your logic to play the next track here
            Toast.makeText(getApplicationContext(), "Playing next track", Toast.LENGTH_SHORT).show();
            // Implement the code to start playing the next track, e.g., with a media player
            // or your audio playback logic.
        }
    }

    private static Bitmap drawableToBitmap(Drawable drawable) {
        if (drawable instanceof BitmapDrawable) {
            Bitmap bmp = ((BitmapDrawable) drawable).getBitmap();
            if (bmp != null) return bmp;
        }
        int w = Math.max(drawable.getIntrinsicWidth(), 1);
        int h = Math.max(drawable.getIntrinsicHeight(), 1);
        Bitmap bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, canvas.getWidth(), canvas.getHeight());
        drawable.draw(canvas);
        return bitmap;
    }


    /**
     * Writes each {@code replacement} over its {@code path}: directly where this
     * app owns the MediaStore item, after one consent dialog for the rest
     * (Android 11+). Answers a map of path to success once the media scanner
     * has re-read them, so the library shows the new tags.
     */
    private void replaceAudioFiles(List<Map<String, String>> files, MethodChannel.Result result) {
        if (files == null || files.isEmpty()) {
            result.success(new HashMap<String, Boolean>());
            return;
        }
        new Thread(() -> {
            final Map<String, Boolean> done = new HashMap<>();
            final List<String[]> needConsent = new ArrayList<>();
            final List<Uri> consentUris = new ArrayList<>();
            final ContentResolver resolver = getContentResolver();
            for (Map<String, String> f : files) {
                String path = f.get("path");
                String replacement = f.get("replacement");
                if (path == null || replacement == null) continue;
                File source = new File(replacement);
                Uri uri = LyricsManager.getMediaUri(resolver, path);
                if (uri == null) {
                    done.put(path, YtDownloadFinisher.copyFile(source, new File(path)));
                    continue;
                }
                try {
                    YtDownloadFinisher.copyToUri(resolver, uri, source);
                    done.put(path, true);
                } catch (SecurityException e) {
                    needConsent.add(new String[]{path, replacement});
                    consentUris.add(uri);
                } catch (Exception e) {
                    Log.w("YtDownloadFinisher", "replace failed: " + path, e);
                    done.put(path, false);
                }
            }
            if (needConsent.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                for (String[] p : needConsent) done.put(p[0], false);
                finishReplace(done, result);
                return;
            }
            runOnUiThread(() -> {
                pendingBatch = needConsent;
                pendingBatchUris = consentUris;
                pendingBatchDone = done;
                pendingBatchResult = result;
                try {
                    PendingIntent pi = MediaStore.createWriteRequest(resolver, consentUris);
                    batchWriteLauncher.launch(new IntentSenderRequest.Builder(pi.getIntentSender()).build());
                } catch (Exception e) {
                    Log.w("YtDownloadFinisher", "write request failed", e);
                    pendingBatchResult = null;
                    pendingBatch = null;
                    pendingBatchUris = null;
                    pendingBatchDone = null;
                    for (String[] p : needConsent) done.put(p[0], false);
                    new Thread(() -> finishReplace(done, result)).start();
                }
            });
        }, "replaceAudioFiles").start();
    }

    /** Off the main thread: rescans what was written, then answers. */
    private void finishReplace(Map<String, Boolean> done, MethodChannel.Result result) {
        List<String> written = new ArrayList<>();
        for (Map.Entry<String, Boolean> e : done.entrySet()) {
            if (Boolean.TRUE.equals(e.getValue())) written.add(e.getKey());
        }
        if (!written.isEmpty()) {
            CountDownLatch scanned = new CountDownLatch(written.size());
            MediaScannerConnection.scanFile(getApplicationContext(),
                    written.toArray(new String[0]), null, (p, u) -> scanned.countDown());
            try {
                scanned.await(15, TimeUnit.SECONDS);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }
        runOnUiThread(() -> result.success(done));
    }
}
