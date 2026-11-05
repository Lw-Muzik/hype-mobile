import 'dart:async';
import 'dart:io';

import 'controllers/drawer_controller.dart';

import 'routes/routes.dart';
import 'global/index.dart';
import 'themes/AppThemes.dart';
import 'controllers/app_controller.dart';
import 'controllers/band_controller.dart';
import 'package:audio_service/audio_service.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wiredash/wiredash.dart';
import 'package:firebase_core/firebase_core.dart';

import 'config/app_config.dart';
import 'controllers/player_controller.dart';
import 'controllers/playlist_controller.dart';
import 'controllers/library_controller.dart';
import 'data/library_database.dart';
import 'data/library_repository.dart';
import 'firebase_options.dart';
import 'helpers/audio_handler.dart';
import 'player/remote_command_gate.dart';
import 'services/audio_focus_service.dart';
import 'widgets/connect_volume_hud.dart';
import 'widgets/dvc_volume_overlay.dart';
import 'player/video/picture_in_picture.dart';
import 'player/video/video_mini_player.dart';
import 'player/video/video_stage.dart';
import 'player/video/video_surface.dart';
import 'services/video/video_registry.dart';
import 'services/streaming_data_guard.dart';
import 'services/library_scanner.dart';
import 'services/artwork_service.dart';
import 'services/ytmusic/yt_downloads.dart';
import 'services/share_service.dart';
import 'widgets/volume_panel_overlay.dart';
import 'services/connect/hype_connect.dart';
import 'services/connect/remote/connect_ui_host.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up the music-sharing foreground-service channel (restores the running
  // state if the service is still up from a previous session).
  await ShareService.instance.init();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FlutterError.onError = (errorDetails) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(errorDetails);
  };
  // Pass all uncaught asynchronous errors that aren't handled by the Flutter framework to Crashlytics
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };
  try {
    await [
      Permission.mediaLibrary,
      Permission.storage,
      Permission.audio,
    ].request();
  } catch (e) {
    // Asking needs an Activity. After a reboot Hype Connect's background
    // service runs this very main() with no screen at all, and the request
    // throws; the permissions were granted by an earlier launch, so carry on.
    debugPrint('Startup permission request skipped: $e');
  }

  // On iOS, ensure media library permission is fully granted before proceeding.
  // MPMediaLibrary.requestAuthorization is async — the permission_handler call
  // above may return before the user has tapped "Allow".
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    var status = await Permission.mediaLibrary.status;
    if (!status.isGranted) {
      status = await Permission.mediaLibrary.request();
      // If still not granted after the prompt, wait briefly for the system to
      // update authorization status (iOS can have a slight delay).
      if (!status.isGranted) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  // The handler is built first and wrapped in the remote-command gate, which
  // is what the platform talks to: a headset, Bluetooth, notification or lock
  // screen command passes Strict and the Bluetooth grace window before it
  // reaches the handler. The app keeps the bare handler for its own buttons.
  final handler = HypeAudioHandler();
  // Until the focus service starts (below), a play asks the system for focus
  // the way the service will: will-pause-when-ducked, and a release after a
  // refusal. A handler with nothing set plays without asking — only a test
  // should ever see that.
  handler.onActivateSession = requestPlatformAudioFocus;
  final gate = await AudioService.init<RemoteCommandGate>(
    builder: () => RemoteCommandGate(handler),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.ryanheise.bg_demo.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      // Keep the media notification visible while paused so the user can resume
      // from it (androidStopForegroundOnPause: false keeps the service
      // foregrounded, which already makes the notification non-dismissible).
      // androidNotificationOngoing must stay false here: audio_service asserts
      // it has no effect — and would crash — unless androidStopForegroundOnPause
      // is true.
      androidNotificationOngoing: false,
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidStopForegroundOnPause: false,
      androidResumeOnClick: true,
    ),
  );

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge, overlays: []);
  SystemChrome.setSystemUIOverlayStyle(overlay);
  // prevent the app from turning to landscape
  // SystemChrome.setPreferredOrientations([
  //   DeviceOrientation.portraitUp,
  //   DeviceOrientation.portraitDown,
  // ]);

  // Initialize SharedPreferences once before the app starts
  final prefs = await SharedPreferences.getInstance();

  // Initialize streaming data guard (network-aware cloud streaming)
  await StreamingDataGuard.init(prefs);

  // Video manifests left by earlier runs are stale by definition — the URLs
  // inside them last hours at most and nothing in this launch's queue points at
  // them. Swept here rather than at teardown because a process that is killed
  // never reaches its teardown. Unawaited: it is disk hygiene, not a dependency
  // of the first frame.
  unawaited(VideoRegistry.instance.sweepManifests());

  // Asks the platform whether it offers a floating window, and starts listening
  // for the mode changing. Cheap, and the answer decides whether any of the
  // picture-in-picture affordances are offered at all.
  unawaited(PictureInPicture.instance.init());

  // Local library database — the browsing UI's source of truth. Opening is
  // lazy (first query triggers it on a background isolate), so this is cheap
  // and never blocks launch. The scanner diffs MediaStore after the first
  // frame; art is resolved on demand through the same repository.
  final libraryRepo = LibraryRepository(LibraryDatabase());
  ArtworkService.instance.attachRepository(libraryRepo);
  YtDownloads.instance.attachRepository(libraryRepo);
  AppController.libraryRepo = libraryRepo;
  final libraryScanner = LibraryScanner(libraryRepo);

  // Built here rather than by a lazy provider: after a reboot Hype Connect's
  // background service runs this main() with no screen, so no widget is ever
  // built to ask for the controller, and Hype Connect would never start.
  //
  // The focus service is awaited first (it configures the audio session) and
  // reads the app's settings lazily, so it can be built before the controller
  // it answers to.
  late final AppController app;
  final audioFocus = await AudioFocusService.forPlatform(
    target: handler,
    settings: () => app.audioFocusSettings,
    hasSession: () => app.canResumePlayback(),
    // The resume after a call or a loss of focus happens in a process the
    // listener never opened too, when the music there was started on purpose.
    canResume: () => app.canResumePlayback(requireUiSeen: false),
    connectAnswerPending: () => app.connectAnswerIsPending,
    bindActivation: (activate) => handler.onActivateSession = activate,
    // Per-output profile flags (read at each focus event).
    noDuck: () => app.outputNoDuck,
    ignoreFocus: () => app.outputIgnoreFocus,
  );
  // A stop (the notification's close included) ends whatever was waiting for a
  // call to finish; it is no change of the playing state when already paused.
  handler.onStopped = audioFocus.cancelHold;
  app = AppController(prefs, handler, remote: gate, audioFocus: audioFocus);
  // Off unless the user has switched Hype Connect on; see HypeConnect.
  HypeConnect.attach(app, prefs);

  runApp(
    MultiBlocProvider(
      providers: [
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider(create: (_) => PlaylistController()),
        Provider<HypeAudioHandler>.value(value: handler),
        ChangeNotifierProvider(create: (_) => PlayerController()),
        ChangeNotifierProvider(create: (_) => DrawerProvider()),
        Provider<LibraryRepository>.value(value: libraryRepo),
        ChangeNotifierProvider(
          create: (_) => LibraryController(
            repo: libraryRepo,
            scanner: libraryScanner,
            prefs: prefs,
          ),
        ),
        BlocProvider(create: (_) => BandController()),
      ],
      child: Wiredash(
        projectId: AppConfig.wiredashProjectId,
        secret: AppConfig.wiredashSecret,
        options: const WiredashOptionsData(locale: Locale('en')),
        child: _AppLifecycleGate(
          child: MaterialApp(
            navigatorKey: ConnectUiHost.navigatorKey,
            scaffoldMessengerKey: ConnectUiHost.messengerKey,
            debugShowCheckedModeBanner: false,
            theme: AppThemes.fancyTheme,
            initialRoute: Routes.loader,
            routes: Routes.routes(),
            builder: (context, child) {
              // The mini video player rides above every route: leaving the
              // player screen should not end the video any more than it ends
              // the song. It shows itself only when the current track is a
              // video and no other host is already displaying it.
              return ValueListenableBuilder<bool>(
                valueListenable: PictureInPicture.instance.isActive,
                builder: (context, floating, _) {
                  return Stack(
                    children: [
                      // Kept mounted while floating, never rebuilt away: the
                      // system shrinks the whole app, and tearing the navigator
                      // down to show a thumbnail would lose every route the
                      // user is going to come back to.
                      //
                      // Android only. On iOS the floating window is AVKit's
                      // own, drawn from a player layer rather than from this
                      // widget tree, so there is nothing here to hide.
                      Offstage(
                        offstage: floating && !Platform.isIOS,
                        child: Stack(
                          children: [
                            child!,
                            const DvcVolumeOverlay(),
                            VolumePanelOverlay(controller: app.volumePanel),
                            const ConnectVolumeHud(),
                            const VideoMiniPlayer(),
                          ],
                        ),
                      ),
                      // In a window a few centimetres across, the player's
                      // controls and artwork are noise. Only the picture.
                      if (floating && !Platform.isIOS)
                        const Positioned.fill(
                          child: ColoredBox(
                            color: Colors.black,
                            child: VideoStage(
                              host: VideoHost.pip,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// Pauses background CPU/GPU/battery drain when the app is not in the
/// foreground. Flutter already halts vsync-driven painters while backgrounded,
/// but the native FFT/PCM tap (and any native GL loop) keep running unless we
/// explicitly stop them — this observer does that centrally for the tap.
/// projectM's GL loop is paused separately by the visualizer page itself.
class _AppLifecycleGate extends StatefulWidget {
  final Widget child;
  const _AppLifecycleGate({required this.child});

  @override
  State<_AppLifecycleGate> createState() => _AppLifecycleGateState();
}

class _AppLifecycleGateState extends State<_AppLifecycleGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Silence the native FFT/PCM tap so it stops computing and pushing
        // events into an invisible UI (a major screen-off heat/battery source).
        AppController.instanceOrNull?.suspendVisualTap();
        // Flush any debounced disk writes (e.g. play counts) before we risk
        // being killed in the background. Null-safe: the provider creates the
        // controller lazily, so a background event can fire before it exists.
        AppController.instanceOrNull?.flushPendingWrites();
        // Where the user got to, written now rather than on the next debounce
        // tick: backgrounding is the moment most likely to be followed by the
        // process being killed, and a session that never reached disk resumes
        // from wherever it last did.
        unawaited(
          AppController.instanceOrNull?.flushSession() ?? Future.value(),
        );
        break;
      case AppLifecycleState.resumed:
        AppController.instanceOrNull?.resumeVisualTap();
        // DVC held back while Hype was in the background can run now.
        AppController.instanceOrNull?.resumeDvcIfPending();
        // The global EQ service can be stopped from its notification.
        unawaited(
          AppController.instanceOrNull?.resyncGlobalEq() ?? Future.value(),
        );
        // A library scan that ran before there was a screen failed; now it can
        // work.
        unawaited(context.read<LibraryController>().retryIfFailed());
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
