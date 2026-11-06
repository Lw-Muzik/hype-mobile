import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';

import 'dart:ui';

import '/exports/exports.dart';
import '../../controllers/app_controller.dart';
import '../../models/cloud_file.dart';
import 'cloud_folder_songs.dart';

import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/motion/morph.dart';

class CloudView extends StatefulWidget {
  const CloudView({super.key});

  @override
  State<CloudView> createState() => _CloudViewState();
}

class _CloudViewState extends State<CloudView>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  bool _loading = false;
  bool _refreshing = false;
  String? _error;
  Map<String, List<CloudFile>> _gdriveFolders = {};
  Map<String, List<CloudFile>> _dropboxFolders = {};
  late AnimationController _shimmerController;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Not started here: _loading starts false and this State is kept alive
    // for the whole session (AutomaticKeepAliveClientMixin). The controller
    // is started at the sites that set _loading = true and stopped when the
    // load completes, so it never ticks while no skeleton is on screen.
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _loadIfConnected();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  void _loadIfConnected() {
    final controller = Provider.of<AppController>(context, listen: false);
    if (controller.isGoogleConnected || controller.isDropboxConnected) {
      _loadFromCacheThenRefresh();
    }
  }

  Future<void> _loadFromCacheThenRefresh() async {
    final controller = Provider.of<AppController>(context, listen: false);
    final cache = controller.cloudCache;

    bool hasCached = false;
    if (controller.isGoogleConnected) {
      final cached = cache.loadFileList(CloudProvider.googleDrive);
      if (cached != null && cached.isNotEmpty) {
        _gdriveFolders = _groupByFolder(cached);
        hasCached = true;
      }
    }
    if (controller.isDropboxConnected) {
      final cached = cache.loadFileList(CloudProvider.dropbox);
      if (cached != null && cached.isNotEmpty) {
        _dropboxFolders = _groupByFolder(cached);
        hasCached = true;
      }
    }

    if (hasCached && mounted) {
      setState(() => _refreshing = true);
    }
    if (!hasCached) {
      _shimmerController.repeat();
      setState(() => _loading = true);
    }
    await _refreshFromApi();
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loading = _gdriveFolders.isEmpty && _dropboxFolders.isEmpty;
      _refreshing = !_loading;
      _error = null;
    });
    if (_loading) _shimmerController.repeat();
    await _refreshFromApi();
  }

  Future<void> _refreshFromApi() async {
    final controller = Provider.of<AppController>(context, listen: false);
    final cache = controller.cloudCache;

    try {
      if (controller.isGoogleConnected) {
        final files = await controller.googleDriveService.listAudioFiles();
        final cached = cache.loadFileList(CloudProvider.googleDrive);
        final merged = _mergeWithCachedMetadata(files, cached);
        cache.saveFileList(CloudProvider.googleDrive, merged);
        _gdriveFolders = _groupByFolder(merged);
        controller.preloadCloudMetadata(CloudProvider.googleDrive, merged);
      } else {
        _gdriveFolders = {};
      }

      if (controller.isDropboxConnected) {
        final files = await controller.dropboxService.listAudioFiles();
        final cached = cache.loadFileList(CloudProvider.dropbox);
        final merged = _mergeWithCachedMetadata(files, cached);
        cache.saveFileList(CloudProvider.dropbox, merged);
        _dropboxFolders = _groupByFolder(merged);
        controller.preloadCloudMetadata(CloudProvider.dropbox, merged);
      } else {
        _dropboxFolders = {};
      }

      _error = null;
    } catch (e) {
      if (_gdriveFolders.isEmpty && _dropboxFolders.isEmpty) {
        _error = e.toString();
      }
    }

    if (mounted) {
      _shimmerController.stop();
      setState(() {
        _loading = false;
        _refreshing = false;
      });
    }
  }

  List<CloudFile> _mergeWithCachedMetadata(
    List<CloudFile> fresh,
    List<CloudFile>? cached,
  ) {
    if (cached == null || cached.isEmpty) return fresh;
    final cachedMap = {for (final f in cached) f.fileId: f};
    return fresh.map((f) {
      final c = cachedMap[f.fileId];
      if (c == null) return f;
      if (f.trackTitle == null && c.trackTitle != null ||
          f.trackArtist == null && c.trackArtist != null ||
          f.albumName == null && c.albumName != null) {
        return CloudFile(
          provider: f.provider,
          fileId: f.fileId,
          name: f.name,
          folderPath: f.folderPath,
          size: f.size,
          mimeType: f.mimeType,
          thumbnailUrl: f.thumbnailUrl,
          modifiedDate: f.modifiedDate,
          trackTitle: f.trackTitle ?? c.trackTitle,
          trackArtist: f.trackArtist ?? c.trackArtist,
          albumName: f.albumName ?? c.albumName,
          durationMs: f.durationMs ?? c.durationMs,
        );
      }
      return f;
    }).toList();
  }

  Map<String, List<CloudFile>> _groupByFolder(List<CloudFile> files) {
    final map = <String, List<CloudFile>>{};
    for (final f in files) {
      (map[f.folderPath] ??= []).add(f);
    }
    return map;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Consumer<AppController>(
      builder: (context, controller, _) {
        final hasConnection =
            controller.isGoogleConnected || controller.isDropboxConnected;
        final hasFolders =
            _gdriveFolders.isNotEmpty || _dropboxFolders.isNotEmpty;

        return RefreshIndicator(
          onRefresh: _loadFiles,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            children: [
              _buildProviderRow(controller),
              const SizedBox(height: 20),
              if (_refreshing && hasFolders) _buildRefreshingIndicator(),
              if (_loading && !hasFolders)
                _FolderGridSkeleton(controller: _shimmerController),
              if (_error != null) _buildErrorWidget(),
              if (hasConnection && _gdriveFolders.isNotEmpty)
                _buildProviderSection(
                  'Google Drive',
                  Icons.cloud_rounded,
                  _gdriveFolders,
                  CloudProvider.googleDrive,
                  controller,
                ),
              if (hasConnection && _dropboxFolders.isNotEmpty)
                _buildProviderSection(
                  'Dropbox',
                  Icons.cloud_circle_rounded,
                  _dropboxFolders,
                  CloudProvider.dropbox,
                  controller,
                ),
              if (!_loading && !_refreshing && !hasConnection)
                _buildEmptyState(),
              if (!_loading &&
                  !_refreshing &&
                  hasConnection &&
                  !hasFolders &&
                  _error == null)
                _buildNoFilesState(),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Provider connection row
  // ---------------------------------------------------------------------------

  Widget _buildProviderRow(AppController controller) {
    return Row(
      children: [
        Expanded(
          child: _ProviderChip(
            icon: Icons.cloud_rounded,
            name: 'Google Drive',
            connected: controller.isGoogleConnected,
            isFancy: controller.isFancy,
            onConnect: () async {
              final ok = await controller.connectGoogle();
              if (ok && mounted) {
                _loadFromCacheThenRefresh();
              } else if (!ok && mounted) {
                _showError(
                  controller.cloudAuth.lastError ?? 'Connection failed',
                );
              }
            },
            onDisconnect: () async {
              await controller.disconnectGoogle();
              controller.cloudCache.clearFileList(CloudProvider.googleDrive);
              setState(() => _gdriveFolders = {});
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ProviderChip(
            icon: Icons.cloud_circle_rounded,
            name: 'Dropbox',
            connected: controller.isDropboxConnected,
            isFancy: controller.isFancy,
            onConnect: () async {
              final ok = await controller.connectDropbox();
              if (ok && mounted) {
                _loadFromCacheThenRefresh();
              } else if (!ok && mounted) {
                _showError(
                  controller.cloudAuth.lastError ?? 'Connection failed',
                );
              }
            },
            onDisconnect: () async {
              await controller.disconnectDropbox();
              controller.cloudCache.clearFileList(CloudProvider.dropbox);
              setState(() => _dropboxFolders = {});
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Refreshing badge
  // ---------------------------------------------------------------------------

  Widget _buildRefreshingIndicator() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Syncing',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Provider section (header + folder grid)
  // ---------------------------------------------------------------------------

  Widget _buildProviderSection(
    String title,
    IconData icon,
    Map<String, List<CloudFile>> folders,
    CloudProvider provider,
    AppController controller,
  ) {
    final sortedKeys = folders.keys.toList()..sort();
    final totalSongs = folders.values.fold<int>(
      0,
      (sum, list) => sum + list.length,
    );
    final totalSize = folders.values.fold<int>(
      0,
      (sum, list) => sum + list.fold<int>(0, (s, f) => s + f.size),
    );
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '$totalSongs songs \u00B7 ${_formatBytes(totalSize)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
          ),
          // Folder grid (2 columns, matching local Folders.dart)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.0,
            ),
            itemCount: sortedKeys.length,
            itemBuilder: (context, index) {
              final files = folders[sortedKeys[index]]!;
              return _CloudFolderCard(
                files: files,
                provider: provider,
                isFancy: controller.isFancy,
                colorIndex: index,
              );
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // States
  // ---------------------------------------------------------------------------

  Widget _buildErrorWidget() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.cloud_off_rounded,
              size: 36,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 16),
          Text('Failed to load files', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Check your connection and try again',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: _loadFiles, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 56,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text('Connect a cloud provider', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Stream music from Google Drive or Dropbox',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoFilesState() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.music_off_rounded,
            size: 56,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text('No audio files found', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Upload music files to your cloud storage',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Cloud folder card — gradient art card matching local folder grid style
// =============================================================================

// Gradient pairs for folder cards (warm tones that complement crimson seed)
const _folderGradients = [
  [Color(0xFF2C1810), Color(0xFF4A2520)], // dark ember
  [Color(0xFF1A1A2E), Color(0xFF302B63)], // midnight
  [Color(0xFF1B2838), Color(0xFF2D4059)], // deep ocean
  [Color(0xFF2D1B33), Color(0xFF4A2545)], // plum
  [Color(0xFF1C2A1C), Color(0xFF2D4A2D)], // forest
  [Color(0xFF2E1F0F), Color(0xFF4A3520)], // bronze
];

class _CloudFolderCard extends StatelessWidget {
  final List<CloudFile> files;
  final CloudProvider provider;
  final bool isFancy;
  final int colorIndex;

  const _CloudFolderCard({
    required this.files,
    required this.provider,
    required this.isFancy,
    required this.colorIndex,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folderName = files.first.folderName;
    final songCount = files.length;
    final gradientPair = _folderGradients[colorIndex % _folderGradients.length];

    return Card(
      elevation: isFancy ? 0 : 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      color: Colors.transparent,
      child: MorphTag(
        tag: itemTag(
          LibraryPageKey('cloudFolder', {
            'folderName': folderName,
            'provider': provider.name,
          }),
        ),
        child: InkWell(
          onTap: () => AppNav.openPage(
            context,
            CloudFolderSongs(
              folderName: folderName,
              files: files,
              provider: provider,
            ),
            key: LibraryPageKey('cloudFolder', {
              'folderName': folderName,
              'provider': provider.name,
            }),
            morphFrom: itemTag(
              LibraryPageKey('cloudFolder', {
                'folderName': folderName,
                'provider': provider.name,
              }),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background gradient
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradientPair,
                  ),
                ),
              ),
              // Frosted glass overlay in fancy mode
              if (isFancy)
                BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(color: Colors.transparent),
                ),
              // Large folder icon (watermark)
              Positioned(
                top: -8,
                right: -12,
                child: Icon(
                  Icons.folder_rounded,
                  size: 80,
                  color: Colors.white.withValues(alpha: 0.04),
                ),
              ),
              // Cloud provider badge
              Positioned(
                top: 12,
                right: 12,
                child: Icon(
                  provider == CloudProvider.googleDrive
                      ? Icons.cloud_rounded
                      : Icons.cloud_circle_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.3),
                ),
              ),
              // Bottom label overlay (matching local folderArtwork pattern)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.6),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        folderName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$songCount ${songCount == 1 ? 'Song' : 'Songs'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Provider connection chip
// =============================================================================

class _ProviderChip extends StatelessWidget {
  final IconData icon;
  final String name;
  final bool connected;
  final bool isFancy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  const _ProviderChip({
    required this.icon,
    required this.name,
    required this.connected,
    required this.isFancy,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: isFancy ? 20 : 0,
          sigmaY: isFancy ? 20 : 0,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: isFancy
                ? Colors.white.withValues(alpha: 0.06)
                : theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: connected
                ? Border.all(color: accent.withValues(alpha: 0.25), width: 1)
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: connected ? onDisconnect : onConnect,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 22,
                      color: connected
                          ? accent
                          : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: connected
                                      ? const Color(0xFF4CAF50)
                                      : theme.colorScheme.onSurface.withValues(
                                          alpha: 0.2,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                connected ? 'Connected' : 'Tap to connect',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: connected
                                      ? const Color(0xFF4CAF50)
                                            .withValues(alpha: 0.8)
                                      : theme.colorScheme.onSurface.withValues(
                                          alpha: 0.35,
                                        ),
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Skeleton shimmer loader — grid layout
// =============================================================================

class _FolderGridSkeleton extends StatelessWidget {
  final AnimationController controller;

  const _FolderGridSkeleton({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final baseColor = theme.colorScheme.surfaceContainerHighest;
        final highlightColor = theme.colorScheme.surfaceContainerLow;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header skeleton
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Row(
                children: [
                  _ShimmerBox(
                    width: 20,
                    height: 20,
                    borderRadius: 4,
                    offset: controller.value,
                    baseColor: baseColor,
                    highlightColor: highlightColor,
                  ),
                  const SizedBox(width: 8),
                  _ShimmerBox(
                    width: 90,
                    height: 14,
                    borderRadius: 4,
                    offset: controller.value,
                    baseColor: baseColor,
                    highlightColor: highlightColor,
                  ),
                ],
              ),
            ),
            // Grid skeleton (2x3 = 6 cards)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.0,
              ),
              itemCount: 6,
              itemBuilder: (context, index) {
                final offset = (controller.value + index * 0.08) % 1.0;
                return _SkeletonCard(
                  offset: offset,
                  baseColor: baseColor,
                  highlightColor: highlightColor,
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  final double offset;
  final Color baseColor;
  final Color highlightColor;

  const _SkeletonCard({
    required this.offset,
    required this.baseColor,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          colors: [baseColor, highlightColor, baseColor],
          stops: const [0.0, 0.5, 1.0],
          begin: Alignment(-1.0 + 2.0 * offset, -0.5),
          end: Alignment(1.0 + 2.0 * offset, 0.5),
        ),
      ),
      child: Stack(
        children: [
          // Bottom label area
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShimmerBox(
                  width: 80,
                  height: 12,
                  borderRadius: 3,
                  offset: offset,
                  baseColor: highlightColor,
                  highlightColor: baseColor,
                ),
                const SizedBox(height: 4),
                _ShimmerBox(
                  width: 50,
                  height: 10,
                  borderRadius: 3,
                  offset: offset,
                  baseColor: highlightColor,
                  highlightColor: baseColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShimmerBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;
  final double offset;
  final Color baseColor;
  final Color highlightColor;

  const _ShimmerBox({
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.offset,
    required this.baseColor,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          colors: [baseColor, highlightColor, baseColor],
          stops: const [0.0, 0.5, 1.0],
          begin: Alignment(-1.0 + 2.0 * offset, 0),
          end: Alignment(1.0 + 2.0 * offset, 0),
        ),
      ),
    );
  }
}
