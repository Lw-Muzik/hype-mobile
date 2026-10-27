import 'package:eq_app/services/news/news_push.dart';
import 'package:eq_app/widgets/news_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('payload parsing', () {
    test('parses a NEWS message', () {
      final n = NewsPayload.tryParse(
        {'type': 'NEWS', 'id': 'abc', 'link': 'https://hypemuzik.com/x'},
        title: 'Hello',
        body: 'World',
      )!;
      expect(n.id, 'abc');
      expect(n.title, 'Hello');
      expect(n.body, 'World');
      expect(n.link.toString(), 'https://hypemuzik.com/x');
    });

    test('ignores other types and messages without an id', () {
      expect(NewsPayload.tryParse({'type': 'APP_UPDATE', 'id': '1'}, title: 't'),
          isNull);
      expect(NewsPayload.tryParse({'type': 'NEWS'}, title: 't'), isNull);
      expect(NewsPayload.tryParse({'type': 'NEWS', 'id': '1'}), isNull);
    });

    test('falls back to data title/body; empty link means none', () {
      final n = NewsPayload.tryParse(
          {'type': 'NEWS', 'id': '1', 'title': 'T', 'body': 'B', 'link': ''})!;
      expect(n.title, 'T');
      expect(n.link, isNull);
    });
  });

  group('link handling', () {
    test('https only', () {
      expect(safeNewsLink('https://hypemuzik.com/a')?.host, 'hypemuzik.com');
      expect(safeNewsLink('http://hypemuzik.com'), isNull);
      expect(safeNewsLink('javascript:alert(1)'), isNull);
      expect(safeNewsLink('intent://x#Intent;end'), isNull);
      expect(safeNewsLink('https://'), isNull);
      expect(safeNewsLink('  '), isNull);
      expect(safeNewsLink(null), isNull);
    });
  });

  group('tap + events', () {
    late List<Uri> opened;
    late List<(Uri, Map<String, dynamic>)> posts;
    NewsPush make({int status = 204, bool failPost = false}) => NewsPush(
          openUrl: (u) async {
            opened.add(u);
            return true;
          },
          post: (u, b) async {
            if (failPost) throw Exception('offline');
            posts.add((u, b));
            return status;
          },
          installId: () async => 'inst-1',
          platform: 'android',
          apiBase: 'https://api.test/api',
        );
    setUp(() {
      opened = [];
      posts = [];
    });

    test('opens the https link and reports opened', () async {
      await make().handleTap(NewsPayload(
          id: 'n1', title: 't', body: 'b', link: Uri.parse('https://a.com/x')));
      expect(opened.single.toString(), 'https://a.com/x');
      expect(posts.single.$1.toString(),
          'https://api.test/api/notifications/n1/events');
      expect(posts.single.$2,
          {'installId': 'inst-1', 'platform': 'android', 'kind': 'opened'});
    });

    test('no link: nothing opened, still reports', () async {
      await make().handleTap(const NewsPayload(id: 'n2', title: 't', body: 'b'));
      expect(opened, isEmpty);
      expect(posts, hasLength(1));
    });

    test('event failures are silent', () async {
      await make(failPost: true).handleTap(
          const NewsPayload(id: 'n3', title: 't', body: 'b'));
    });

    test('subscribes to the platform topic', () {
      expect(make().topic, 'hype-news-android');
    });
  });

  group('banner', () {
    final navKey = GlobalKey<NavigatorState>();
    Future<void> pump(WidgetTester t) => t.pumpWidget(MaterialApp(
        navigatorKey: navKey, home: const Scaffold(body: Text('home'))));

    testWidgets('shows, then auto-hides after 6 s', (t) async {
      await pump(t);
      final push = NewsPush(
          navigatorKey: navKey,
          openUrl: (_) async => true,
          post: (_, _) async => 204,
          installId: () async => 'i',
          platform: 'android');
      push.showBanner(const NewsPayload(id: '1', title: 'Big news', body: 'Read it'));
      await t.pump();
      expect(find.text('Big news'), findsOneWidget);
      expect(find.text('Read it'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(find.text('Big news'), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
      expect(find.text('Big news'), findsNothing);
    });

    testWidgets('tap opens link, reports opened and hides', (t) async {
      await pump(t);
      final opened = <Uri>[];
      final posts = <Map<String, dynamic>>[];
      final push = NewsPush(
          navigatorKey: navKey,
          openUrl: (u) async {
            opened.add(u);
            return true;
          },
          post: (_, b) async {
            posts.add(b);
            return 204;
          },
          installId: () async => 'i',
          platform: 'ios');
      push.showBanner(NewsPayload(
          id: '9', title: 'Tap me', body: 'b', link: Uri.parse('https://a.com')));
      await t.pump();
      await t.tap(find.text('Tap me'));
      await t.pump();
      expect(find.text('Tap me'), findsNothing);
      expect(opened.single.host, 'a.com');
      expect(posts.single['kind'], 'opened');
      expect(posts.single['platform'], 'ios');
      await t.pump(const Duration(seconds: 7)); // timer already cancelled
    });

    testWidgets('banner widget renders on its own', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: NewsBanner(title: 'A', body: 'B', onTap: () {}))));
      expect(find.text('A'), findsOneWidget);
    });
  });
}
