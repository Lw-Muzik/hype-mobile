import 'dart:async';
import 'dart:io';

import '/exports/exports.dart';
import '/services/artwork_service.dart';

class ArtworkWidget extends StatefulWidget {
  final String path;
  final String other;
  final int songId;
  final int quality;
  final ArtworkType type;
  final BoxFit fit;
  final BlendMode? blendMode;
  final double width;
  final double height;
  final BorderRadiusGeometry? borderRadius;
  final ColorFilter? colorFilter;
  final Widget? child;
  final bool useSaved;
  final int size;
  final EdgeInsetsGeometry? margin;
  const ArtworkWidget({
    super.key,
    this.path = "",
    required this.songId,
    this.type = ArtworkType.AUDIO,
    this.fit = BoxFit.cover,
    this.width = 100,
    this.height = 100,
    this.borderRadius,
    this.child,
    this.margin,
    this.colorFilter,
    this.other = "",
    this.quality = 70,
    this.size = 2,
    this.useSaved = true,
    this.blendMode,
  });

  @override
  State<ArtworkWidget> createState() => _ArtworkWidgetState();
}

/// One resolved cover: the provider and the decode width it was made at.
class _ArtEntry {
  final ImageProvider provider;
  final int width;
  final int songId;
  const _ArtEntry(this.provider, this.width, this.songId);
}

/// Last resolved cover per art identity, shared by every ArtworkWidget so a
/// widget built for art that was resolved a moment ago (pinch morph layer,
/// rest layout, scroll-back) paints it on its first frame.
class _ArtCache {
  static const int _max = 400;
  static final Map<String, _ArtEntry> _entries = <String, _ArtEntry>{};
  static StreamSubscription<int>? _sub;

  /// Bumped on every replacement so a resolve that started before it can't
  /// store the old picture afterwards.
  static int generation = 0;

  static String keyOf(ArtworkWidget w) =>
      '${w.songId}|${w.type}|${w.path}|${w.other}';

  static void _listen() {
    _sub ??= ArtworkService.instance.changes.listen(evict);
  }

  static _ArtEntry? get(String key) {
    _listen();
    final e = _entries.remove(key);
    if (e != null) _entries[key] = e; // most recently used goes last
    return e;
  }

  static void put(String key, _ArtEntry e) {
    _listen();
    _entries.remove(key);
    _entries[key] = e;
    while (_entries.length > _max) {
      _entries.remove(_entries.keys.first);
    }
  }

  static void evict(int songId) {
    generation++;
    _entries.removeWhere((_, e) => e.songId == songId);
  }

  @visibleForTesting
  static void clear() {
    generation++;
    _entries.clear();
  }
}

/// Test seam: forget every cached cover.
@visibleForTesting
void clearArtworkCacheForTest() => _ArtCache.clear();

class _ArtworkWidgetState extends State<ArtworkWidget> {
  /// What is painted now; null means the placeholder. Taken from the shared
  /// cache on the first frame when the art was resolved before, and kept
  /// while a larger decode is prepared so nothing blinks.
  ImageProvider? _shown;
  String? _pendingKey;
  int? _pendingWidth;

  /// Artwork the user replaces ("Find artwork") is swapped in everywhere the
  /// song shows — the player, its background, every list — without waiting
  /// for the song to scroll away and back.
  StreamSubscription<int>? _replaced;

  @override
  void initState() {
    super.initState();
    _replaced = ArtworkService.instance.changes.listen((id) {
      if (id == widget.songId && widget.type == ArtworkType.AUDIO && mounted) {
        _ArtCache.evict(id);
        setState(() {
          _shown = null;
          _pendingKey = null;
          _pendingWidth = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _replaced?.cancel();
    super.dispose();
  }

  /// Physical pixels to decode at, bucketed upward so a pinch or a resize
  /// doesn't decode per frame.
  int _computeDecodeWidth(BuildContext context, double? availableWidth) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    // Prefer the ACTUAL laid-out width so a grid cell or the full-screen player
    // decodes at its real display size, not the widget's nominal width (which
    // is often a small default). Fall back to the nominal width, then screen.
    double logical;
    if (availableWidth != null &&
        availableWidth.isFinite &&
        availableWidth > 0) {
      logical = availableWidth;
    } else if (widget.width.isFinite && widget.width > 0) {
      logical = widget.width;
    } else {
      logical = MediaQuery.of(context).size.width;
    }
    // Bounded so decoded bitmaps stay small (a full-res 3000px embedded cover
    // is ~36MB RGBA).
    final px = (logical * dpr).ceil();
    return ((px + 127) ~/ 128 * 128).clamp(64, 1600);
  }

  void _ensure(int needed) {
    final key = _ArtCache.keyOf(widget);
    final entry = _ArtCache.get(key);
    if (entry != null && entry.width >= needed && entry.width <= needed * 2) {
      _shown = entry.provider;
      _pendingKey = null;
      _pendingWidth = null;
      return;
    }
    // Keep showing whatever there is (an older, smaller or larger decode)
    // until the new one is ready.
    if (entry != null) _shown ??= entry.provider;
    if (_pendingKey == key && _pendingWidth == needed) return;
    _pendingKey = key;
    _pendingWidth = needed;
    _resolve(key, needed);
  }

  // Resolves the art path lazily via ArtworkService (in-memory LRU -> DB path
  // -> temp PNG -> capped extraction), then decodes at display size. Nothing
  // is extracted until a tile actually asks for it.
  Future<void> _resolve(String key, int decodeWidth) async {
    final generation = _ArtCache.generation;
    final path = await ArtworkService.instance.pathFor(
      id: widget.songId,
      data: widget.path,
      type: widget.type,
      other: widget.other,
    );
    final stale = !mounted || _pendingKey != key || _pendingWidth != decodeWidth;
    if (path == null) {
      if (!stale) setState(() => _shown = const AssetImage("assets/audio.jpeg"));
      return;
    }
    final provider = ResizeImage(
      FileImage(File(path)),
      width: decodeWidth,
      policy: ResizeImagePolicy.fit,
    );
    // Swapping over an existing picture: decode first so the old one stays
    // on screen until the new one can paint.
    if (!stale && mounted && _shown != null && _shown is! AssetImage) {
      try {
        await precacheImage(provider, context);
      } catch (_) {}
    }
    if (generation == _ArtCache.generation) {
      _ArtCache.put(key, _ArtEntry(provider, decodeWidth, widget.songId));
    }
    if (!mounted || _pendingKey != key || _pendingWidth != decodeWidth) return;
    setState(() => _shown = provider);
  }

  @override
  void didUpdateWidget(covariant ArtworkWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path ||
        oldWidget.songId != widget.songId ||
        oldWidget.other != widget.other ||
        oldWidget.type != widget.type) {
      _shown = null; // identity changed — take it from the cache or resolve
      _pendingKey = null;
      _pendingWidth = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensure(_computeDecodeWidth(context, constraints.maxWidth));
        return Container(
          margin: widget.margin,
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius ?? BorderRadius.circular(10),
            image: DecorationImage(
              fit: widget.fit,
              colorFilter: widget.colorFilter,
              image: _shown ?? const AssetImage("assets/audio.jpeg"),
            ),
          ),
          child: widget.child,
        );
      },
    );
    // : FutureBuilder(
    //     future: OnAudioQuery.platform.queryArtwork(
    //       songId,
    //       type,
    //       quality: quality,
    //       format: ArtworkFormat.JPEG,
    //       size: size,
    //     ),
    //     builder: (context, imageSnap) {
    //       return Container(
    //         margin: margin,
    //         width: width,
    //         height: height,
    //         decoration: BoxDecoration(
    //           borderRadius: borderRadius,
    //           image: DecorationImage(
    //             fit: fit,
    //             colorFilter: colorFilter ??
    //                 ColorFilter.mode(
    //                     imageSnap.hasData ? Colors.black26 : Colors.black,
    //                     BlendMode.darken),
    //             image: imageSnap.hasData
    //                 ? MemoryImage(imageSnap.data!)
    //                 : const AssetImage("assets/audio.jpeg")
    //                     as ImageProvider,
    //           ),
    //         ),
    //         child: child,
    //       );
    //     },
    //   );
  }
}
