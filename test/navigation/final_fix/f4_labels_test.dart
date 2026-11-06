import 'package:eq_app/navigation/places/places_page.dart';
import 'package:eq_app/onboarding/home_guide.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the YouTube place is Discover in store builds', () {
    expect(youtubePlaceLabel(directBuild: false), 'Discover');
    expect(youtubePlaceLabel(directBuild: true), 'YouTube Music');
  });

  test('guide copy names YouTube Music only in direct builds', () {
    expect(guideDiscoverMessage(directBuild: true), contains('YouTube Music'));
    expect(
      guideDiscoverMessage(directBuild: false),
      allOf(contains('Discover'), isNot(contains('YouTube'))),
    );
    expect(
      guidePlacesMessage(directBuild: false, isAndroid: true),
      isNot(contains('YouTube')),
    );
    expect(
      guidePlacesMessage(directBuild: true, isAndroid: true),
      contains('YouTube Music'),
    );
  });

  test('guide lists Folders only on Android', () {
    expect(
      guidePlacesMessage(directBuild: false, isAndroid: true),
      contains('Genres, Folders, Playlists, Discover, and Cloud'),
    );
    expect(
      guidePlacesMessage(directBuild: false, isAndroid: false),
      allOf(
        isNot(contains('Folders')),
        contains('Genres, Playlists, Discover, and Cloud'),
      ),
    );
  });
}
