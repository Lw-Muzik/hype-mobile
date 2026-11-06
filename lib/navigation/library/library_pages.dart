/// The pages that can be rebuilt from a [LibraryPageKey] alone.
///
/// Keys that only hold an id (a playlist, a cloud folder) are resolved here
/// against the library and the cloud cache; when the thing is gone the builder
/// returns null and the trail stops at its parent.
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../controllers/app_controller.dart';
import '../../controllers/drawer_controller.dart';
import '../../data/library_repository.dart';
import '../../models/cloud_file.dart';
import '../../pages/album_songs.dart';
import '../../pages/artist_songs.dart';
import '../../pages/cloud/cloud_folder_songs.dart';
import '../../pages/discover/artist_page.dart';
import '../../pages/discover/category_page.dart';
import '../../pages/discover/opened_list_page.dart';
import '../../pages/discover/yt_search_page.dart';
import '../../pages/folder_songs.dart';
import '../../pages/genre_songs.dart';
import '../../pages/home/mix_playlist_page.dart';
import '../../pages/playlist_songs.dart';
import '../../pages/search_page.dart';
import '../../services/ytmusic/yt_models.dart';
import '../app_nav.dart';
import 'page_factory.dart';
import '../library_page_key.dart';
import '../places/place_scaffold.dart';
import '../places/places_page.dart';
import '../yt_page_keys.dart';

/// A place page wired to the library stack: back pops, the menu button opens
/// the drawer, search opens beside it.
Widget buildPlaceScaffold(PlaceId id) => Builder(
  builder: (context) => PlaceScaffold(
    id: id,
    fancy: context.select<AppController, bool>((c) => c.isFancy),
    onBack: () {
      final host = AppNav.host;
      if (host != null) {
        host.library.pop();
      } else {
        Navigator.of(context).maybePop();
      }
    },
    onMenu: () => context.read<DrawerProvider>().toggleDrawer(),
    onSearch: () => AppNav.openPage(
      context,
      const SearchPage(),
      key: const LibraryPageKey('search'),
      sibling: true,
    ),
  ),
);

int? _int(Object? v) => v is num ? v.toInt() : null;

Map<String, LibraryPageBuilder> defaultLibraryPages() => {
  'place': (key, _) {
    final id = PlaceId.values.asNameMap()[key.args['id']];
    return id == null ? null : buildPlaceScaffold(id);
  },
  'album': (key, _) {
    final id = _int(key.args['albumId']);
    final name = key.args['album'];
    if (id == null || name is! String) return null;
    return AlbumSongs(
      albumId: id,
      album: name,
      songs: _int(key.args['songs']) ?? 0,
      coverSongId: _int(key.args['coverSongId']),
      coverPath: (key.args['coverPath'] as String?) ?? '',
    );
  },
  'artist': (key, _) {
    final id = _int(key.args['artistId']);
    final name = key.args['artist'];
    if (id == null || name is! String) return null;
    return ArtistSongs(
      artistId: id,
      artist: name,
      songs: _int(key.args['songs']) ?? 0,
      albums: _int(key.args['albums']) ?? 0,
      coverSongId: _int(key.args['coverSongId']),
      coverPath: (key.args['coverPath'] as String?) ?? '',
    );
  },
  'genre': (key, _) {
    final id = _int(key.args['genreId']);
    final name = key.args['genre'];
    if (id == null || name is! String) return null;
    return GenreSongs(
      genreId: id,
      genre: name,
      songs: _int(key.args['songs']) ?? 0,
    );
  },
  'folder': (key, _) {
    final path = key.args['path'];
    return path is String ? FolderSongs(path: path) : null;
  },
  'playlist': (key, _) {
    final id = _int(key.args['playlistId']);
    final name = key.args['playlist'];
    if (id == null || name is! String) return null;
    return PlaylistSongs(
      playlistId: id,
      playlist: name,
      songs: _int(key.args['songs']) ?? 0,
    );
  },
  // A mix key holds only the playlist id: look the summary up again.
  'mix': (key, context) async {
    final id = _int(key.args['id']);
    if (id == null || context == null) return null;
    final repo = context.read<LibraryRepository>();
    final all = await repo.playlists();
    for (final p in all) {
      if (p.id == id) return MixPlaylistPage(playlist: p);
    }
    return null;
  },
  // A cloud folder key holds the folder's name and provider: reload its files
  // from the cache the Cloud page keeps.
  'cloudFolder': (key, context) {
    final name = key.args['folderName'];
    final providerName = key.args['provider'];
    if (name is! String || providerName is! String || context == null) {
      return null;
    }
    final provider = CloudProvider.values.asNameMap()[providerName];
    if (provider == null) return null;
    final cached = context.read<AppController>().cloudCache.loadFileList(
      provider,
    );
    final files = <CloudFile>[
      for (final f in cached ?? const <CloudFile>[])
        if (f.folderName == name) f,
    ];
    if (files.isEmpty) return null;
    return CloudFolderSongs(folderName: name, files: files, provider: provider);
  },
  'search': (key, _) => const SearchPage(),
  'ytSearch': (key, _) => const YtSearchPage(),
  'ytList': (key, _) {
    final item = exploreItemFromArgs(key.args);
    if (item == null) return null;
    return YtOpenedListPage(
      item: item,
      highlightVideoId: key.args['highlightVideoId'] as String?,
    );
  },
  'ytArtist': (key, _) {
    final item = exploreItemFromArgs(key.args);
    return item == null ? null : YtArtistPage(item: item);
  },
  'ytCategory': (key, _) {
    final title = key.args['title'];
    final params = key.args['params'];
    if (title is! String || params is! String) return null;
    return YtCategoryPage(
      category: ExploreCategory(title: title, params: params),
    );
  },
  // 'songsAll' (a search's full result list) is built inline by the search
  // page and has nothing to rebuild it from, so a trail ends before it.
};
