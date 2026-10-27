import 'package:eq_app/services/update/app_version_policy.dart';
import 'package:eq_app/services/update/update_service.dart';
import 'package:eq_app/widgets/update_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _navKey = GlobalKey<NavigatorState>();

Future<UpdateService> _pump(
  WidgetTester tester, {
  required AppVersionPolicy policy,
  String installed = '1.0.24',
  Future<bool> Function(Uri)? open,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(MaterialApp(
    navigatorKey: _navKey,
    home: const Scaffold(body: Text('home')),
  ));
  final svc = UpdateService(
    prefs: prefs,
    fetchPolicy: (_) async => policy,
    installedVersion: () async => installed,
    openUrl: open ?? (_) async => true,
    navigatorKey: _navKey,
    platform: 'android',
  );
  return svc;
}

Future<void> _check(WidgetTester tester, UpdateService svc) async {
  svc.markShellReady();
  await tester.pump(); // post-frame callback
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  const notes = 'Faster stems\nBug fixes';
  const dismissible = AppVersionPolicy(
      latestVersion: '1.0.25', minimumVersion: '1.0.20', releaseNotes: notes);
  const blocking = AppVersionPolicy(
      latestVersion: '1.0.25', minimumVersion: '1.0.24+1', releaseNotes: notes);

  testWidgets('dismissible: notes shown, barrier tap closes', (tester) async {
    final svc = await _pump(tester, policy: dismissible, installed: '1.0.21');
    await _check(tester, svc);
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.textContaining('Faster stems'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Skip this version'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('Later persists and is quiet on the next check', (tester) async {
    final svc = await _pump(tester, policy: dismissible, installed: '1.0.21');
    await _check(tester, svc);
    await tester.tap(find.byKey(const Key('update-later')));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    await svc.check();
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
  });

  testWidgets('blocking: only Update now; back and barrier do nothing',
      (tester) async {
    Uri? opened;
    final svc = await _pump(tester,
        policy: blocking,
        installed: '1.0.23',
        open: (u) async {
          opened = u;
          return true;
        });
    await _check(tester, svc);
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    expect(find.text('Skip this version'), findsNothing);
    expect(find.textContaining('Faster stems'), findsOneWidget);

    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-now')));
    await tester.pumpAndSettle();
    expect(opened.toString(), contains('play.google.com'));
    // Still blocking after returning without updating.
    expect(find.byType(UpdateDialog), findsOneWidget);
  });

  testWidgets('long notes scroll without overflow', (tester) async {
    final long = List.generate(80, (i) => 'Line $i').join('\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: UpdateDialog(
            latestVersion: '1.0.25', blocking: false, releaseNotes: long),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollbar), findsOneWidget);
  });

  testWidgets('no store link: hint instead of button', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: UpdateDialog(
            latestVersion: '1.0.25',
            blocking: true,
            canOpenStore: false,
            storeName: 'the App Store'),
      ),
    ));
    expect(find.byKey(const Key('update-now')), findsNothing);
    expect(find.text('Update from the App Store.'), findsOneWidget);
  });

  testWidgets('failed fetch shows nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
        navigatorKey: _navKey, home: const Scaffold(body: Text('home'))));
    final svc = UpdateService(
      prefs: await SharedPreferences.getInstance(),
      fetchPolicy: (_) async => throw Exception('offline'),
      installedVersion: () async => '1.0.0',
      navigatorKey: _navKey,
      platform: 'android',
    );
    await _check(tester, svc);
    expect(find.byType(UpdateDialog), findsNothing);
  });
}
