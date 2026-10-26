import 'dart:math' as math;
import 'dart:ui';

import '/controllers/app_controller.dart';
import '/exports/exports.dart';
import '../helpers/visualizer_widget.dart';
import '../visualizers/circular_bar_visualizer.dart';
import '../player/remote/remote_player.dart' show RemoteBackdrop;
import '../player/remote/remote_scope.dart' show RemoteBuilder;
import 'artwork_widget.dart';

/// The extra blur that used to be a second, stacked backdrop filter.
const double kWashSigma = 200;

/// Blur for the background artwork.
///
/// The background was two Gaussian blurs stacked on top of each other — the
/// user's [blur], then a fixed [kWashSigma] to wash the cover out when nothing
/// else is drawn over it. Applying two Gaussians in sequence is the same as
/// applying one of sigma sqrt(s1^2 + s2^2), so the pair collapses to a single
/// pass with no change to the picture. Public so that equivalence is pinned by
/// a test rather than by whoever next reads the two numbers.
double backgroundBlurSigma(double blur, {required bool washed}) =>
    washed ? math.sqrt(blur * blur + kWashSigma * kWashSigma) : blur;

class Body extends StatelessWidget {
  final Widget child;
  const Body({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Stack(
      children: [
        // The artwork + full-screen blur layers are the most expensive thing on
        // this screen. They used to sit inside a Consumer<AppController> that
        // rebuilt (and re-configured both BackdropFilters) on EVERY notify —
        // play-count, lyrics-loading, EQ drag, shuffle, etc. _BodyBackground now
        // isolates them behind a Selector + RepaintBoundary so they only rebuild
        // when their actual inputs (artwork, blur amount, visual mode) change.
        const _BodyBackground(),
        // Page content — rebuilds independently of the background.
        Container(
          decoration: const BoxDecoration(
            backgroundBlendMode: BlendMode.colorBurn,
            color: Colors.black12,
          ),
          width: size.width,
          height: size.height,
          child: child,
        ),
      ],
    );
  }
}

/// Selector value for the background — only these fields trigger a rebuild.
typedef _BgData = ({
  bool hasSongs,
  String path,
  int songDbId,
  int bgQuality,
  double blur,
  bool visualInBackground,
});

class _BodyBackground extends StatelessWidget {
  const _BodyBackground();

  @override
  Widget build(BuildContext context) {
    // Another device is the player: the backdrop follows ITS track, exactly as
    // it follows local playback (RemoteBuilder is a pass-through with null
    // outside remote mode).
    return RemoteBuilder(
      builder: (context, remote) => remote == null
          ? const _LocalBodyBackground()
          : RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RemoteBackdrop(track: remote.track, fade: false),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.fromARGB(92, 0, 0, 0),
                          Color.fromARGB(179, 0, 0, 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _LocalBodyBackground extends StatelessWidget {
  const _LocalBodyBackground();

  @override
  Widget build(BuildContext context) {
    return Selector<AppController, _BgData>(
      selector: (_, c) {
        final hasSongs = c.songs.isNotEmpty;
        final song = hasSongs ? c.songs[c.songId] : null;
        return (
          hasSongs: hasSongs,
          path: song?.data ?? '',
          songDbId: song?.id ?? -1,
          bgQuality: c.bgQuality.toInt(),
          blur: c.blur,
          visualInBackground: c.isVisualInBackground,
        );
      },
      builder: (context, d, _) {
        final size = MediaQuery.of(context).size;
        // Washed out further when no visualizer is drawn over it, so the page
        // content stays readable against a busy cover.
        final washed = d.hasSongs && !d.visualInBackground;
        // A single RepaintBoundary caches the composited background so the page
        // content painting on top of it doesn't force the blur to re-raster.
        return RepaintBoundary(
          child: Stack(
            children: [
              if (d.hasSongs)
                SizedBox(
                  height: size.height,
                  child: ImageFiltered(
                    // ImageFiltered, NOT BackdropFilter. Nothing is behind this
                    // — the artwork is its own sibling inside this isolated
                    // RepaintBoundary, so "blur what is painted behind me" was
                    // always just an expensive way to say "blur this image".
                    // A backdrop filter re-reads the surface it is painted onto
                    // and cannot be raster-cached, so the blur was recomputed on
                    // every frame the app produced, on every screen. Filtering
                    // the child instead makes the whole background a static
                    // subtree: blurred once when the track changes, then reused.
                    //
                    // clamp so the blur extends the edge pixels; the default
                    // samples transparent black and fades the screen borders.
                    imageFilter: ImageFilter.blur(
                      sigmaX: backgroundBlurSigma(d.blur, washed: washed),
                      sigmaY: backgroundBlurSigma(d.blur, washed: washed),
                      tileMode: TileMode.clamp,
                    ),
                    child: ArtworkWidget(
                      useSaved: true,
                      path: d.path,
                      size: d.bgQuality,
                      quality: 1,
                      width: size.width,
                      height: size.height,
                      songId: d.songDbId,
                      type: ArtworkType.AUDIO,
                    ),
                  ),
                ),
              // The two darkening gradients that used to ride on the two
              // backdrop filters, composited into one. Blurring a smooth
              // vertical ramp returns the same ramp, so folding them loses
              // nothing: alpha = 1 - (1-a1)(1-a2) at each stop.
              Container(
                height: size.height,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: washed
                        ? const [
                            Color.fromARGB(92, 0, 0, 0), // 0.360
                            Color.fromARGB(100, 0, 0, 0), // 0.392
                            Color.fromARGB(130, 0, 0, 0), // 0.510
                            Color.fromARGB(179, 0, 0, 0), // 0.700
                          ]
                        : const [
                            Color.fromARGB(51, 0, 0, 0), // 0.20
                            Color.fromARGB(61, 0, 0, 0), // 0.24
                            Color.fromARGB(77, 0, 0, 0), // 0.30
                            Color.fromARGB(128, 0, 0, 0), // 0.50
                          ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.2, 0.5, 1.0],
                  ),
                ),
              ),
              if (d.visualInBackground)
                VisualizerWidget(
                  builder: (context, fft, _, rate) {
                    return CustomPaint(
                      painter: CircularBarVisualizer(
                        color: Theme.of(context).primaryColorLight
                            .withValues(alpha: 0.1),
                        waveData: fft,
                        width: size.width,
                        height: size.height,
                      ),
                      child: const Center(),
                    );
                  },
                  id: 0,
                ),
            ],
          ),
        );
      },
    );
  }
}
