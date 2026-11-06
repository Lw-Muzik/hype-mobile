import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/Global/index.dart';
import '/exports/exports.dart';
import '../controllers/app_controller.dart';
import '../data/library_repository.dart';
import '/widgets/song_options_sheet.dart';
import '/widgets/song_tile.dart';
import 'package:eq_app/navigation/library/library_tags.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/motion/morph.dart';

class FolderSongs extends StatefulWidget {
  final String path;
  const FolderSongs({super.key, required this.path});

  @override
  State<FolderSongs> createState() => _FolderSongsState();
}

class _FolderSongsState extends State<FolderSongs> {
  // Single reactive query feeding both the header and the list — the page used
  // to run the folder query three separate times (init + two FutureBuilders in
  // build()).
  late final Stream<List<SongModel>> _songsStream = context
      .read<LibraryRepository>()
      .watchFolderSongs(widget.path);

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) => StreamBuilder<List<SongModel>>(
        stream: _songsStream,
        builder: (context, snapshot) {
          final songs = snapshot.data ?? const <SongModel>[];
          return NestedScrollView(
            headerSliverBuilder: (context, _) => [
              _buildSliverAppBar(context, appController, songs),
            ],
            body: _buildBody(appController, songs, snapshot.hasData),
          );
        },
      ),
    );
  }

  SliverAppBar _buildSliverAppBar(
    BuildContext context,
    AppController appController,
    List<SongModel> songs,
  ) {
    return SliverAppBar(
      forceMaterialTransparency: appController.isFancy,
      expandedHeight: 400,
      shadowColor: Colors.transparent,
      elevation: 0,
      flexibleSpace: FlexibleSpaceBar(
        centerTitle: true,
        background: MorphTag(
          tag: headerTag(LibraryPageKey('folder', {'path': widget.path})),
          child: _buildFlexibleSpaceBackground(
            context,
            appController,
            songs,
          ),
        ),
      ),
    );
  }

  Widget _buildFlexibleSpaceBackground(
    BuildContext context,
    AppController controller,
    List<SongModel> songs,
  ) {
    return Hero(
      tag: 'folder_${widget.path}',
      child: Stack(
        children: [
          if (songs.isNotEmpty) headerWidget(controller, context, data: songs),
          Positioned(
            bottom: 45,
            left: 10,
            child: _buildFolderInfo(context, songs.length),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderInfo(BuildContext context, int songCount) {
    final textTheme = Theme.of(context).textTheme;
    final folderName = widget.path.split("/").last;

    return RichText(
      text: TextSpan(
        children: [
          TextSpan(text: "$folderName\n", style: textTheme.displayMedium),
          TextSpan(
            text: "$songCount",
            style: textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w300,
            ),
          ),
          TextSpan(
            text: songCount == 1 ? " Available Track\n" : " Available Tracks\n",
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w300,
            ),
          ),
          TextSpan(
            text: widget.path,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    AppController controller,
    List<SongModel> songs,
    bool hasData,
  ) {
    return StreamBuilder<bool>(
      stream: controller.handler.player.playingStream,
      builder: (context, snapshot) {
        // The stream is kept as a rebuild trigger — the bar's *contents* still
        // track play/pause — but its value no longer decides whether the bar
        // exists. That is `hasNowPlaying`'s job now.
        return Scaffold(
          backgroundColor: controller.isFancy
              ? Colors.transparent
              : Theme.of(context).scaffoldBackgroundColor,
          body: _buildSongList(controller, songs, hasData),
        );
      },
    );
  }

  Widget _buildSongList(
    AppController controller,
    List<SongModel> songs,
    bool hasData,
  ) {
    if (!hasData) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    return SongListView(
      songs: songs,
      controller: controller,
      zoomKey: 'folder_songs',
      onTap: (song, index) {
        controller.playSongFromList(songs, index);
        AppNav.toPlayer(context);
      },
      onLongPress: (song, index) {
        showModalBottomSheet(
          useRootNavigator: true,
          context: context,
          builder: (_) => SongOptionsSheet(song: song),
        );
      },
      onOptions: (song, index) {
        showModalBottomSheet(
          useRootNavigator: true,
          context: context,
          builder: (_) => SongOptionsSheet(song: song),
        );
      },
    );
  }
}
