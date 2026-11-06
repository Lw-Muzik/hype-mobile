import 'package:eq_app/navigation/motion/motion_progress.dart';
import 'package:eq_app/navigation/motion_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MotionProgress mp;
  setUp(() => mp = MotionProgress(vsync: const TestVSync()));
  tearDown(() => mp.dispose());

  testWidgets('run follows the curve over time', (tester) async {
    mp.run(to: 1, duration: const Duration(milliseconds: 250), curve: cosEase);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    expect(mp.value, closeTo(0.5, 0.02));
    await tester.pump(const Duration(milliseconds: 200));
    expect(mp.value, 1);
    expect(mp.isAnimating, isFalse);
  });

  testWidgets('retarget continues from the current value', (tester) async {
    mp.run(to: 1, duration: const Duration(milliseconds: 250), curve: cosEase);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    var last = mp.value;
    expect(last, greaterThan(0.1));
    mp.run(to: 0, duration: const Duration(milliseconds: 250), curve: cosEase);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect((mp.value - last).abs(), lessThan(0.04));
      last = mp.value;
    }
  });

  Future<bool?> drag(WidgetTester t, double p, double v, ReleaseRules r) async {
    mp.beginDrag();
    mp.dragTo(p);
    final f = mp.release(velocityPerSecond: v, rules: r);
    return (() async {
      await t.pump();
      await t.pump(const Duration(seconds: 2));
      return f;
    })();
  }

  testWidgets('slow release past 0.3 commits, below cancels', (tester) async {
    expect(await drag(tester, 0.31, 0, ReleaseRules.artDrag), isTrue);
    expect(mp.value, 1);
    mp.jumpTo(0);
    expect(await drag(tester, 0.29, 0, ReleaseRules.artDrag), isFalse);
    expect(mp.value, 0);
  });

  testWidgets('fling decides by direction', (tester) async {
    final fling = MotionSpec.flingVelocity / MotionSpec.dragTravel;
    expect(await drag(tester, 0.1, fling + 0.1, ReleaseRules.artDrag), isTrue);
    mp.jumpTo(0);
    expect(
      await drag(tester, 0.9, -fling - 0.1, ReleaseRules.artDrag),
      isFalse,
    );
  });

  testWidgets('forExtent rescales the fling threshold', (tester) async {
    final rules = ReleaseRules.artDrag.forExtent(250);
    expect(rules.flingPerSecond, MotionSpec.flingVelocity / 250);
  });

  testWidgets('commit with forward velocity glides at the 4/s floor', (
    tester,
  ) async {
    mp.beginDrag();
    mp.dragTo(0.5);
    mp.release(velocityPerSecond: 0.5, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 62));
    expect(mp.value, closeTo(0.5 + 4 * 0.062, 0.03));
    await tester.pump(const Duration(milliseconds: 100));
    expect(mp.value, 1);
  });

  testWidgets('timed commit respects the 100 ms floor', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.7);
    mp.release(velocityPerSecond: 0, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(mp.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 60));
    expect(mp.value, 1);
  });

  testWidgets('timed cancel respects the 167 ms floor', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.25);
    mp.release(velocityPerSecond: 0, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(mp.value, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 30));
    expect(mp.value, 0);
  });

  testWidgets('back swipe cancel above 0.2 glides at constant speed', (
    tester,
  ) async {
    mp.beginDrag();
    mp.dragTo(0.228);
    // Finger still moving right: the settle sees it reversed.
    mp.release(velocityPerSecond: 0.3, rules: ReleaseRules.backSwipe);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(mp.value, closeTo(0.228 - 3.5 * 0.03, 0.02));
    await tester.pump(const Duration(milliseconds: 50));
    expect(mp.value, 0);
  });

  testWidgets('run reports reached vs pre-empted', (tester) async {
    bool? first;
    bool? second;
    mp
        .run(to: 1, duration: const Duration(milliseconds: 200), curve: cosEase)
        .then((v) => first = v);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    mp
        .run(to: 0, duration: const Duration(milliseconds: 100), curve: cosEase)
        .then((v) => second = v);
    await tester.pump();
    expect(first, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(second, isTrue);
    // beginDrag and jumpTo also pre-empt.
    bool? third;
    mp
        .run(to: 1, duration: const Duration(milliseconds: 200), curve: cosEase)
        .then((v) => third = v);
    mp.beginDrag();
    await tester.pump();
    expect(third, isFalse);
    bool? fourth;
    mp
        .run(to: 1, duration: const Duration(milliseconds: 200), curve: cosEase)
        .then((v) => fourth = v);
    mp.jumpTo(0.2);
    await tester.pump();
    expect(fourth, isFalse);
  });

  testWidgets('release is null when interrupted', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.6);
    bool? result = true;
    var done = false;
    mp.release(velocityPerSecond: 0, rules: ReleaseRules.artDrag).then((v) {
      result = v;
      done = true;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    mp.beginDrag();
    await tester.pump();
    expect(done, isTrue);
    expect(result, isNull);
  });

  testWidgets('timed commit is still running at 90 ms (100 ms floor)', (
    tester,
  ) async {
    mp.beginDrag();
    mp.dragTo(0.7);
    mp.release(velocityPerSecond: 0, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(mp.value, lessThan(1));
    expect(mp.value, greaterThan(0.7));
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('velocity is dropped past 0.8 on commit', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.85);
    // Glide at 8/s would finish in 19 ms; timed floor is 100 ms.
    mp.release(velocityPerSecond: 3, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(mp.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 80));
    expect(mp.value, 1);
  });

  testWidgets('velocity is dropped below 0.2 on cancel', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.15);
    // Glide back would take at most 43 ms; timed floor is 167 ms.
    mp.release(velocityPerSecond: -1, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(mp.value, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(mp.value, 0);
  });

  testWidgets('commit glide clamps at 8 per second', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.4);
    mp.release(velocityPerSecond: 1.3, rules: ReleaseRules.artDrag);
    await tester.pump();
    mp.value; // first frame starts the clock
    await tester.pump(const Duration(milliseconds: 40));
    expect(mp.value, closeTo(0.4 + 4 * 0.04, 0.03));
    final fast = MotionProgress(vsync: const TestVSync());
    fast.beginDrag();
    fast.dragTo(0.4);
    const rules = ReleaseRules(
      commitAt: 0.3,
      flingPerSecond: 100,
      settleCommit: Duration(milliseconds: 250),
      settleCancel: Duration(milliseconds: 500),
      minCommit: Duration(milliseconds: 100),
      minCancel: Duration(milliseconds: 167),
      glideMin: 4,
      glideMax: 8,
      cancelGlideMin: 3.5,
    );
    fast.release(velocityPerSecond: 50, rules: rules);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(fast.value, closeTo(0.4 + 8 * 0.04, 0.03));
    await tester.pump(const Duration(milliseconds: 100));
    fast.dispose();
  });

  testWidgets('art drag cancel with backward velocity glides linearly 3.5-8', (
    tester,
  ) async {
    mp.beginDrag();
    mp.dragTo(0.25);
    mp.release(velocityPerSecond: -1, rules: ReleaseRules.artDrag);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    // Slowest 3.5/s: 0.07 down; clamp at 3.5 since |v| = 1.
    expect(mp.value, closeTo(0.25 - 3.5 * 0.02, 0.02));
    await tester.pump(const Duration(milliseconds: 20));
    expect(mp.value, closeTo(0.25 - 3.5 * 0.04, 0.02));
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('back swipe slow commit is timed, not a glide', (tester) async {
    mp.beginDrag();
    mp.dragTo(0.625);
    // Finger moving right (forward): reversed for the settle, so timed.
    mp.release(velocityPerSecond: 0.4, rules: ReleaseRules.backSwipe);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // cos over 100 ms: halfway = midpoint of 0.625..1.
    expect(mp.value, closeTo(0.625 + 0.375 * 0.5, 0.03));
    await tester.pump(const Duration(milliseconds: 60));
    expect(mp.value, 1);
  });
}
