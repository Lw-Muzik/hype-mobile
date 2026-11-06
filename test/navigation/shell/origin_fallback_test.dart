import 'package:eq_app/navigation/app_nav.dart';
import 'package:eq_app/navigation/library_page_key.dart';
import 'package:eq_app/navigation/playback_origin.dart';
import 'package:eq_app/navigation/shell/scene_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

const _album = LibraryPageKey('album', {'id': 5});
final _places = LibraryPageKey.place('albums');

void main() {
  testWidgets('pulling the player away asks for the saved origin path', (
    tester,
  ) async {
    final app = FakeApp()..playbackOrigin = PlaybackOrigin([_places, _album]);
    final lib = FakeLibrary();
    await pumpShell(tester, app: app, library: lib);
    AppNav.host!.toLibrary();
    await advance(tester, 300);
    expect(lib.shown.single, [_places, _album]);
  });

  testWidgets('no origin lands on Places (empty path)', (tester) async {
    final lib = FakeLibrary();
    await pumpShell(tester, app: FakeApp(), library: lib);
    AppNav.host!.toLibrary();
    await advance(tester, 300);
    expect(lib.shown.single, isEmpty);
  });

  testWidgets('an empty origin overrides the saved one (empty queue)', (
    tester,
  ) async {
    final app = FakeApp()..playbackOrigin = PlaybackOrigin([_places, _album]);
    final lib = FakeLibrary();
    await pumpShell(tester, app: app, library: lib);
    AppNav.host!.toLibrary(landOn: const PlaybackOrigin([]));
    await advance(tester, 300);
    expect(lib.shown.single, isEmpty);
  });

  testWidgets('a path the library cannot fully rebuild lands on what it can', (
    tester,
  ) async {
    // The library truncates at the first page it cannot build; the shell must
    // go on with whatever is left rather than fail.
    final lib = _TruncatingLibrary();
    final app = FakeApp()..playbackOrigin = PlaybackOrigin([_places, _album]);
    await pumpShell(tester, app: app, library: lib);
    final scenes = AppNav.host! as SceneController;
    scenes.toLibrary();
    await advance(tester, 300);
    expect(lib.stack, [_places]);
    expect(scenes.scene.value, Scene.library);
    expect(scenes.list.value, 1);
  });
}

class _TruncatingLibrary extends FakeLibrary {
  @override
  Future<void> showPath(List<LibraryPageKey> path) async {
    stack
      ..clear()
      ..addAll(path.takeWhile((k) => k.kind != 'album'));
  }
}
