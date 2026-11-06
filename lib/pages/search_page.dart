/// One search box over everything the user can play.
///
/// Local files, a connected drive and YouTube, in one scrolling list. The asking
/// lives in [UnifiedSearch]; this file is the view.
///
/// # Tapping a result starts a station
///
/// A page of search results is not a running order. It is twenty answers to one
/// question, and following the song someone picked with the nineteen other
/// things they were choosing between is not listening to music. So a tapped
/// result plays alone and seeds a station — a rule YouTube search already
/// followed here, now extended to the library and the drive.
///
/// Albums, playlists, folders, artists and the discovery rows below an empty
/// query are untouched: those *are* running orders, or reports, and tapping into
/// one means "play from here".
///
/// # The Autoplay preference applies to YouTube and not to the others
///
/// That setting exists to stop the app making network requests of its own
/// accord. A local or cloud station makes none — it is a database query and some
/// arithmetic — so there is nothing for the preference to protect, and
/// [AppController.playStation] is not gated. YouTube keeps its existing gate.
library;

import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'dart:async';
import 'dart:io';

import '/exports/exports.dart';
import '/Routes/routes.dart';

import '../controllers/app_controller.dart';
import '../data/library_repository.dart';
import '../models/cloud_file.dart';
import '../services/radio/cloud_station.dart';
import '../services/radio/library_station.dart';
import '../services/ytmusic/yt_models.dart';
import '../services/ytmusic/yt_playback.dart';
import '../services/ytmusic/yt_repository.dart';
import '../widgets/artwork_widget.dart';
import '../widgets/song_tile.dart';
import 'album_songs.dart';
import 'artist_songs.dart';
import 'discover/widgets/yt_widgets.dart';
import 'discover/yt_search_page.dart';
import 'folder_songs.dart';
import 'playlist_songs.dart';
import 'search/unified_search.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  /// Nullable + guarded rather than `late final`: [didChangeDependencies] runs
  /// again on any inherited-widget change, and assigning a `late final` twice
  /// throws at runtime — which the analyzer cannot see.
  UnifiedSearch? _searchModel;
  UnifiedSearch get _search => _searchModel!;

  // Discovery (empty query) still reads the repository directly — it is not a
  // search and shares none of the supersession rules.
  List<SongModel> _mostPlayed = [];
  List<SongModel> _recentlyAdded = [];

  LibraryRepository get _repo => context.read<LibraryRepository>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_searchModel != null) return;
    _searchModel = UnifiedSearch(
      repo: _repo,
      loadCloudFiles: () async => _cachedCloudFiles(),
      searchYouTube: (query) => youTubeSongs(
        (q, filter) => YtMusicRepository.instance.search(q, filter),
        query,
      ),
      loadPlaylists: Platform.isAndroid ? OnAudioQuery().queryPlaylists : null,
    );
    _searchModel!.addListener(_onSearchChanged);
    _loadDiscovery();
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDiscovery() async {
    final most = await _repo.mostPlayed(limit: 10);
    final recent = await _repo.recentlyAdded(limit: 10);
    if (!mounted) return;
    setState(() {
      _mostPlayed = most;
      _recentlyAdded = recent;
    });
  }

  List<CloudFile> _cachedCloudFiles() {
    final controller = context.read<AppController>();
    final files = <CloudFile>[];
    for (final provider in CloudProvider.values) {
      final list = controller.cloudCache.loadFileList(provider);
      if (list != null) files.addAll(list);
    }
    return files;
  }

  @override
  void dispose() {
    _searchModel?.removeListener(_onSearchChanged);
    _searchModel?.dispose();
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Routes.pop(context),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          onChanged: _search.onQueryChanged,
          onSubmitted: _search.search,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.bodyLarge,
          decoration: InputDecoration(
            hintText: 'Songs, artists, YouTube, your drive...',
            hintStyle: theme.textTheme.bodyLarge?.copyWith(
              color: colorScheme.onSurface.withValues(alpha: 0.4),
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: 12,
            ),
          ),
        ),
        actions: [
          if (_searchController.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () {
                _searchController.clear();
                _search.onQueryChanged('');
              },
            ),
        ],
      ),
      body: Consumer<AppController>(
        builder: (context, controller, _) {
          if (_search.query.isEmpty) {
            return _buildDiscoveryView(controller, theme, colorScheme);
          }
          return _buildSearchResults(controller, theme, colorScheme);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Empty query — discovery view (Most Played + Recently Added)
  // ---------------------------------------------------------------------------

  Widget _buildDiscoveryView(
    AppController controller,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    if (_mostPlayed.isEmpty && _recentlyAdded.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_rounded,
              size: 72,
              color: colorScheme.onSurface.withValues(alpha: 0.15),
            ),
            const SizedBox(height: 16),
            Text(
              'Search everything',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Your library, your drive, and YouTube',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 100),
      children: [
        if (_mostPlayed.isNotEmpty) ...[
          _buildSectionHeader('Most Played', theme, colorScheme),
          const SizedBox(height: 8),
          _buildHorizontalSongCards(
            _mostPlayed,
            controller,
            theme,
            colorScheme,
            showPlayCount: true,
          ),
          const SizedBox(height: 24),
        ],
        if (_recentlyAdded.isNotEmpty) ...[
          _buildSectionHeader('Recently Added', theme, colorScheme),
          const SizedBox(height: 8),
          _buildHorizontalSongCards(
            _recentlyAdded,
            controller,
            theme,
            colorScheme,
          ),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(
    String title,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _buildHorizontalSongCards(
    List<SongModel> songs,
    AppController controller,
    ThemeData theme,
    ColorScheme colorScheme, {
    bool showPlayCount = false,
  }) {
    return SizedBox(
      height: 180,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          final playCount = controller.getPlayCount(song.id);
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              // A discovery row is a report, not a search result — tapping it
              // plays from there through the rest of the row, as it always has.
              onTap: () => _playFromList(controller, songs, song),
              child: SizedBox(
                width: 130,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: ArtworkWidget(
                            songId: song.id,
                            type: ArtworkType.AUDIO,
                            width: 130,
                            height: 130,
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        if (showPlayCount && playCount > 0)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.primary.withValues(
                                  alpha: 0.9,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.play_arrow_rounded,
                                    size: 12,
                                    color: colorScheme.onPrimary,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    '$playCount',
                                    style: TextStyle(
                                      color: colorScheme.onPrimary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      song.artist ?? 'Unknown',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Search results view
  // ---------------------------------------------------------------------------

  Widget _buildSearchResults(
    AppController controller,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    // Deliberately not `!hasResults`: while YouTube is still answering, "no
    // results" is a claim the page cannot yet make.
    if (_search.isEmptyAndSettled) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 64,
              color: colorScheme.onSurface.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 12),
            Text(
              'No results for "${_search.query}"',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            if (_search.ytFailed) ...[
              const SizedBox(height: 6),
              Text(
                "YouTube couldn't be reached",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurface.withValues(alpha: 0.35),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 100),
      children: [
        if (_search.songs.isNotEmpty)
          _buildSongsSection(_search.songs, controller, theme, colorScheme),
        if (_search.artists.isNotEmpty)
          _buildArtistsSection(_search.artists, theme, colorScheme),
        if (_search.albums.isNotEmpty)
          _buildAlbumsSection(_search.albums, theme, colorScheme),
        if (_search.folders.isNotEmpty)
          _buildFoldersSection(_search.folders, theme, colorScheme),
        if (_search.playlists.isNotEmpty)
          _buildPlaylistsSection(_search.playlists, theme, colorScheme),
        if (_search.cloudFiles.isNotEmpty)
          _buildCloudSection(
            _search.cloudFiles,
            controller,
            theme,
            colorScheme,
          ),
        // Last, and the only section that can be busy: everything above it is
        // already on screen while this one is still in the air.
        if (_search.ytLoading || _search.ytTracks.isNotEmpty)
          _buildYouTubeSection(theme, colorScheme),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Songs section (local library)
  // ---------------------------------------------------------------------------

  Widget _buildSongsSection(
    List<SongModel> songs,
    AppController controller,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final displaySongs = songs.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'Songs',
          Icons.music_note_rounded,
          '${songs.length}',
          theme,
          colorScheme,
        ),
        ...displaySongs.map((song) {
          final isPlaying =
              controller.songs.isNotEmpty &&
              controller.songId >= 0 &&
              controller.songId < controller.songs.length &&
              controller.songs[controller.songId].id == song.id;
          return SongTile(
            song: song,
            index: displaySongs.indexOf(song),
            isCurrentTrack: isPlaying,
            showTrackNumber: false,
            showOptionsIcon: false,
            onTap: () => _startLibraryStation(controller, song),
          );
        }),
        if (songs.length > 5)
          _buildSeeAllButton(
            'See all ${songs.length} songs',
            theme,
            colorScheme,
            onTap: () => _showAllSongs(songs, controller),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // YouTube section
  // ---------------------------------------------------------------------------

  Widget _buildYouTubeSection(ThemeData theme, ColorScheme colorScheme) {
    final tracks = _search.ytTracks.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'YouTube',
          Icons.play_circle_outline_rounded,
          _search.ytLoading ? '···' : '${_search.ytTracks.length}',
          theme,
          colorScheme,
        ),
        if (_search.ytLoading)
          // A skeleton, not a spinner: the section's shape is known before its
          // contents are, and showing that shape is the more honest wait.
          ...List.generate(3, (_) => const YtTrackSkeleton())
        else
          ...tracks.map(
            (track) => YtTrackRow(
              track: track,
              onTap: () => _startYouTubeStation(track),
            ),
          ),
        if (!_search.ytLoading && _search.ytTracks.length > tracks.length)
          _buildSeeAllButton(
            'See all on YouTube',
            theme,
            colorScheme,
            onTap: () => AppNav.openPage(
              context,
              const YtSearchPage(),
              key: const LibraryPageKey('ytSearch'),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Artists section
  // ---------------------------------------------------------------------------

  Widget _buildArtistsSection(
    List<ArtistModel> artists,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'Artists',
          Icons.person_rounded,
          '${artists.length}',
          theme,
          colorScheme,
        ),
        SizedBox(
          height: 100,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: artists.take(10).length,
            itemBuilder: (context, index) {
              final artist = artists[index];
              final name = artist.artist;
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _navigateToArtist(artist),
                  child: SizedBox(
                    width: 72,
                    child: Column(
                      children: [
                        ClipOval(
                          child: ArtworkWidget(
                            songId: artist.id,
                            type: ArtworkType.ARTIST,
                            width: 60,
                            height: 60,
                            borderRadius: BorderRadius.zero,
                            other: name,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          name,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Albums section
  // ---------------------------------------------------------------------------

  Widget _buildAlbumsSection(
    List<AlbumModel> albums,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'Albums',
          Icons.album_rounded,
          '${albums.length}',
          theme,
          colorScheme,
        ),
        SizedBox(
          height: 140,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.take(10).length,
            itemBuilder: (context, index) {
              final album = albums[index];
              final name = album.album;
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => _navigateToAlbum(album),
                  child: SizedBox(
                    width: 110,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: ArtworkWidget(
                            songId: album.id,
                            type: ArtworkType.ALBUM,
                            width: 110,
                            height: 110,
                            borderRadius: BorderRadius.circular(10),
                            other: name,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Folders section
  // ---------------------------------------------------------------------------

  Widget _buildFoldersSection(
    List<String> folders,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final display = folders.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'Folders',
          Icons.folder_rounded,
          '${folders.length}',
          theme,
          colorScheme,
        ),
        ...display.map((path) {
          final name = path.split('/').last;
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 0,
            ),
            leading: Icon(
              Icons.folder_rounded,
              color: colorScheme.primary.withValues(alpha: 0.7),
              size: 28,
            ),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
            onTap: () => _navigateToFolder(path),
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Playlists section
  // ---------------------------------------------------------------------------

  Widget _buildPlaylistsSection(
    List<PlaylistModel> playlists,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final display = playlists.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'Playlists',
          Icons.queue_music_rounded,
          '${playlists.length}',
          theme,
          colorScheme,
        ),
        ...display.map((playlist) {
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 0,
            ),
            leading: Icon(
              Icons.queue_music_rounded,
              color: colorScheme.tertiary.withValues(alpha: 0.7),
              size: 28,
            ),
            title: Text(
              playlist.playlist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '${playlist.numOfSongs} songs',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
            onTap: () => _navigateToPlaylist(playlist),
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Cloud section
  // ---------------------------------------------------------------------------

  Widget _buildCloudSection(
    List<CloudFile> cloudFiles,
    AppController controller,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final display = cloudFiles.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildResultSectionHeader(
          'Cloud',
          Icons.cloud_rounded,
          '${cloudFiles.length}',
          theme,
          colorScheme,
        ),
        ...display.map((file) {
          final icon = file.provider == CloudProvider.googleDrive
              ? Icons.drive_file_move_rounded
              : Icons.cloud_circle_rounded;
          final providerName = file.provider == CloudProvider.googleDrive
              ? 'Google Drive'
              : 'Dropbox';
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 0,
            ),
            leading: Icon(
              icon,
              color: colorScheme.secondary.withValues(alpha: 0.7),
              size: 28,
            ),
            title: Text(
              file.trackTitle ?? file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '${file.trackArtist ?? file.folderName} · $providerName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                fontSize: 11,
              ),
            ),
            // These rows used to have no onTap at all — cloud results were
            // decorative.
            onTap: () => _startCloudStation(controller, file),
          );
        }),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Shared widgets
  // ---------------------------------------------------------------------------

  Widget _buildResultSectionHeader(
    String title,
    IconData icon,
    String count,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              count,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeeAllButton(
    String label,
    ThemeData theme,
    ColorScheme colorScheme, {
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Playing
  // ---------------------------------------------------------------------------

  /// A search result: play it alone and build a station from the library.
  Future<void> _startLibraryStation(
    AppController controller,
    SongModel song,
  ) async {
    // The queue first: installing it resets the origin, which toPlayer then
    // records for this one.
    final started = controller.playStation(
      song,
      LibraryStation(repo: _repo, seed: song),
    );
    AppNav.toPlayer(context);
    await started;
  }

  /// A cloud result: mint a link, play it alone, build a station from the drive.
  Future<void> _startCloudStation(
    AppController controller,
    CloudFile file,
  ) async {
    final url = await _cloudStreamUrl(controller, file);
    if (!mounted) return;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That file couldn't be opened.")),
      );
      return;
    }
    final started = controller.playStation(
      file.toSongModel(url),
      CloudStation(
        // The whole drive, not just what matched — a station seeded from a
        // result is about the song, not about the word that found it.
        files: _search.allCloudFiles.isEmpty
            ? [file]
            : _search.allCloudFiles,
        seed: file,
        resolve: (f) => _cloudStreamUrl(controller, f),
      ),
    );
    AppNav.toPlayer(context);
    await started;
  }

  Future<String?> _cloudStreamUrl(
    AppController controller,
    CloudFile file,
  ) async {
    if (file.provider == CloudProvider.googleDrive) {
      return controller.googleDriveService.getStreamUrl(file.fileId);
    }
    return controller.dropboxService.getTemporaryLink(file.fileId);
  }

  /// A YouTube result. Routed through the existing path, which resolves the
  /// stream, caches the artwork, reports its own failures and attaches a
  /// `YouTubeStation` — and which honours the Autoplay preference, because
  /// unlike the other two this station costs requests.
  void _startYouTubeStation(YtTrack track) {
    YtPlayback.play(context, [track], 0, radio: true);
  }

  /// Plays from a surfaced list — a discovery row, or "see all". Falls back to a
  /// single-track queue so a tap always plays.
  void _playFromList(
    AppController controller,
    List<SongModel> list,
    SongModel song,
  ) {
    var index = list.indexWhere((s) => s.id == song.id);
    List<SongModel> queue = list;
    if (index == -1) {
      queue = [song];
      index = 0;
    }
    controller.playSongFromList(queue, index);
    AppNav.toPlayer(context);
  }

  void _showAllSongs(List<SongModel> songs, AppController controller) {
    AppNav.openPage(
      context,
      Builder(
        builder: (pageContext) => Scaffold(
          appBar: AppBar(
            title: Text('Songs matching "${_search.query}"'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              onPressed: () => Navigator.of(pageContext).pop(),
            ),
          ),
          body: SongListView(
            songs: songs,
            controller: controller,
            zoomKey: 'search',
            showTrackNumbers: false,
            showOptionsIcon: false,
            // A full list of matches reads as a list to play through, so this
            // one queues rather than starting a station.
            onTap: (song, index) {
              controller.playSongFromList(songs, index);
              AppNav.toPlayer(pageContext);
            },
          ),
        ),
      ),
      key: LibraryPageKey('songsAll', {'query': _search.query}),
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _navigateToArtist(ArtistModel artist) {
    AppNav.openPage(
      context,
      ArtistSongs(
        songs: artist.numberOfTracks ?? 0,
        albums: artist.numberOfAlbums ?? 0,
        artistId: artist.id,
        artist: artist.artist,
      ),
      key: LibraryPageKey('artist', {
        'artistId': artist.id,
        'artist': artist.artist,
        'songs': artist.numberOfTracks ?? 0,
        'albums': artist.numberOfAlbums ?? 0,
      }),
    );
  }

  void _navigateToAlbum(AlbumModel album) {
    AppNav.openPage(
      context,
      AlbumSongs(albumId: album.id, album: album.album, songs: album.numOfSongs),
      key: LibraryPageKey('album', {
        'albumId': album.id,
        'album': album.album,
        'songs': album.numOfSongs,
      }),
    );
  }

  void _navigateToFolder(String path) {
    AppNav.openPage(
      context,
      FolderSongs(path: path),
      key: LibraryPageKey('folder', {'path': path}),
    );
  }

  void _navigateToPlaylist(PlaylistModel playlist) {
    AppNav.openPage(
      context,
      PlaylistSongs(
        playlistId: playlist.id,
        playlist: playlist.playlist,
        songs: playlist.numOfSongs,
      ),
      key: LibraryPageKey('playlist', {
        'playlistId': playlist.id,
        'playlist': playlist.playlist,
        'songs': playlist.numOfSongs,
      }),
    );
  }
}
