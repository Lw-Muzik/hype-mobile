import 'package:eq_app/navigation/motion/morph.dart';
import 'package:eq_app/navigation/motion/motion_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _opacityOf(WidgetTester t, String key) => t
    .widget<Opacity>(
      find
          .descendant(
            of: find.byKey(ValueKey('tag-$key')),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

void main() {
  _flightTests();
  _standInTests();
  testWidgets('fly lerps the rect and hides both tags until done', (
    tester,
  ) async {
    final p = ValueNotifier<double>(0);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MorphScope(
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: 100,
                height: 100,
                child: MorphTag(
                  key: const ValueKey('tag-a'),
                  tag: 'a',
                  child: Container(key: const ValueKey('a'), color: Colors.red),
                ),
              ),
              Positioned(
                left: 200,
                top: 100,
                width: 50,
                height: 50,
                child: MorphTag(
                  key: const ValueKey('tag-b'),
                  tag: 'b',
                  child: Container(
                    key: const ValueKey('b'),
                    color: Colors.blue,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    expect(scope.rectOf('a'), const Rect.fromLTWH(0, 0, 100, 100));
    expect(scope.rectOf('b'), const Rect.fromLTWH(200, 100, 50, 50));

    var done = false;
    scope.fly(from: 'a', to: 'b', progress: p).then((_) => done = true);
    p.value = 0.5;
    await tester.pump();
    await tester.pump();
    await tester.pump(); // the stand-in arms after two frames
    final flying = find
        .byType(Positioned)
        .evaluate()
        .map((e) => e.widget as Positioned);
    final fly = flying.firstWhere((w) => w.left == 100 && w.top == 50);
    expect(fly.width, 75);
    expect(fly.height, 75);
    expect(_opacityOf(tester, 'a'), 0);
    expect(_opacityOf(tester, 'b'), 0);

    p.value = 1;
    await tester.pump();
    await tester.pump();
    expect(done, isTrue);
    expect(_opacityOf(tester, 'a'), 1);
    expect(_opacityOf(tester, 'b'), 1);
  });

  testWidgets('MorphTag works without a scope', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MorphTag(tag: 1, child: SizedBox(width: 10, height: 10)),
      ),
    );
    expect(find.byType(MorphTag), findsOneWidget);
  });
}

Widget _twoTags({bool showB = true, Key? scopeKey}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MorphScope(
    key: scopeKey,
    child: Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: 100,
          height: 100,
          child: MorphTag(
            key: const ValueKey('tag-a'),
            tag: 'a',
            child: const ColoredBox(color: Colors.red),
          ),
        ),
        if (showB)
          Positioned(
            left: 200,
            top: 100,
            width: 50,
            height: 50,
            child: MorphTag(
              key: const ValueKey('tag-b'),
              tag: 'b',
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
      ],
    ),
  ),
);

class _Owner extends StatefulWidget {
  const _Owner({required this.onReady});
  final void Function(MotionProgress) onReady;
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> with SingleTickerProviderStateMixin {
  late final MotionProgress mp = MotionProgress(vsync: this);
  @override
  void initState() {
    super.initState();
    widget.onReady(mp);
  }

  @override
  void dispose() {
    mp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void _flightTests() {
  testWidgets('owner disposing its driver during unmount is safe', (
    tester,
  ) async {
    late MotionProgress mp;
    var show = true;
    late StateSetter set;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MorphScope(
          child: StatefulBuilder(
            builder: (c, s) {
              set = s;
              return Stack(
                children: [
                  const Positioned(
                    left: 0,
                    top: 0,
                    width: 50,
                    height: 50,
                    child: MorphTag(
                      key: ValueKey('tag-a'),
                      tag: 'a',
                      child: ColoredBox(color: Colors.red),
                    ),
                  ),
                  const Positioned(
                    left: 100,
                    top: 100,
                    width: 50,
                    height: 50,
                    child: MorphTag(
                      key: ValueKey('tag-b'),
                      tag: 'b',
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                  if (show) _Owner(onReady: (m) => mp = m),
                ],
              );
            },
          ),
        ),
      ),
    );
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    var done = false;
    scope.fly(from: 'a', to: 'b', progress: mp).then((_) => done = true);
    mp.dragTo(0.5);
    await tester.pump();
    await tester.pump();
    await tester.pump(); // the stand-in arms after two frames
    expect(_opacityOf(tester, 'a'), 0);
    set(() => show = false);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(done, isTrue);
    expect(_opacityOf(tester, 'a'), 1);
    expect(_opacityOf(tester, 'b'), 1);
  });

  testWidgets('progress back to 0 ends the flight and restores tags', (
    tester,
  ) async {
    final p = ValueNotifier<double>(0);
    await tester.pumpWidget(_twoTags());
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    var done = false;
    scope.fly(from: 'a', to: 'b', progress: p).then((_) => done = true);
    p.value = 0.4;
    await tester.pump();
    await tester.pump();
    await tester.pump(); // the stand-in arms after two frames
    expect(_opacityOf(tester, 'a'), 0);
    p.value = 0;
    await tester.pump();
    await tester.pump();
    expect(done, isTrue);
    expect(_opacityOf(tester, 'a'), 1);
    expect(_opacityOf(tester, 'b'), 1);
  });

  testWidgets('fromRect/toRect overrides drive the flight', (tester) async {
    final p = ValueNotifier<double>(0);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MorphScope(
          child: Stack(
            children: [
              const Positioned(
                left: 0,
                top: 0,
                width: 100,
                height: 100,
                child: MorphTag(
                  tag: 'a',
                  child: ColoredBox(color: Colors.red),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                width: 400,
                height: 400,
                child: Transform.scale(
                  scale: 0.5,
                  child: const Stack(
                    children: [
                      Positioned(
                        left: 200,
                        top: 200,
                        width: 100,
                        height: 100,
                        child: MorphTag(
                          tag: 'b',
                          child: ColoredBox(color: Colors.blue),
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
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    const end = Rect.fromLTWH(300, 400, 120, 120);
    scope.fly(from: 'a', to: 'b', progress: p, toRect: end);
    // Read the flight's rect just before it ends by sampling at 0.999.
    p.value = 0.999;
    await tester.pump();
    final fly = find
        .byType(Positioned)
        .evaluate()
        .map((e) => e.widget as Positioned)
        .firstWhere((w) => (w.left ?? 0) > 290 && (w.left ?? 0) < 301);
    expect(fly.left, closeTo(end.left, 0.5));
    expect(fly.top, closeTo(end.top, 0.5));
    expect(fly.width, closeTo(120, 0.5));
    p.value = 1;
    await tester.pump();
  });

  testWidgets('scope disposed mid-flight completes the flight', (tester) async {
    final p = ValueNotifier<double>(0);
    await tester.pumpWidget(_twoTags());
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    var done = false;
    scope.fly(from: 'a', to: 'b', progress: p).then((_) => done = true);
    p.value = 0.5;
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(done, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tag unmounted mid-flight ends the flight and restores the other',
    (tester) async {
      final p = ValueNotifier<double>(0);
      await tester.pumpWidget(_twoTags());
      final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
      var done = false;
      scope.fly(from: 'a', to: 'b', progress: p).then((_) => done = true);
      p.value = 0.5;
      await tester.pump();
      await tester.pumpWidget(_twoTags(showB: false));
      await tester.pump();
      expect(done, isTrue);
      expect(_opacityOf(tester, 'a'), 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a disposed MotionProgress ends the flight', (tester) async {
    final p = MotionProgress(vsync: const TestVSync());
    await tester.pumpWidget(_twoTags());
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    var done = false;
    scope.fly(from: 'a', to: 'b', progress: p).then((_) => done = true);
    p.dragTo(0.5);
    await tester.pump();
    p.dispose();
    await tester.pump();
    await tester.pump();
    expect(done, isTrue);
    expect(_opacityOf(tester, 'a'), 1);
  });
}

void _standInTests() {
  testWidgets(
    'stand-ins keep the tag\'s text style and ink without exceptions',
    (tester) async {
      final p = ValueNotifier<double>(0);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MorphScope(
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  width: 120,
                  height: 60,
                  child: Material(
                    child: DefaultTextStyle(
                      style: const TextStyle(
                        fontSize: 31,
                        color: Color(0xFF123456),
                      ),
                      child: MorphTag(
                        tag: 'a',
                        child: InkWell(
                          onTap: () {},
                          child: const Text('styled', key: ValueKey('txt')),
                        ),
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  left: 200,
                  top: 100,
                  width: 50,
                  height: 50,
                  child: MorphTag(tag: 'b', child: SizedBox()),
                ),
              ],
            ),
          ),
        ),
      );
      final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
      scope.fly(from: 'a', to: 'b', progress: p);
      p.value = 0.4;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      final standIn = find.descendant(
        of: find.byType(FittedBox),
        matching: find.byKey(const ValueKey('txt')),
      );
      expect(standIn, findsOneWidget);
      final style = DefaultTextStyle.of(tester.element(standIn)).style;
      expect(style.fontSize, 31);
      expect(style.color, const Color(0xFF123456));
    },
  );

  testWidgets(
    'a tag on a covered route yields to the one on the current route',
    (tester) async {
      final nav = GlobalKey<NavigatorState>();
      late MorphScopeState scope;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MorphScope(
            child: Builder(
              builder: (context) {
                scope = MorphScope.of(context);
                return Navigator(
                  key: nav,
                  onGenerateRoute: (_) => PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) => const Stack(
                      children: [
                        Positioned(
                          left: 0,
                          top: 0,
                          width: 50,
                          height: 50,
                          child: MorphTag(tag: 't', child: SizedBox()),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(scope.rectOf('t'), const Rect.fromLTWH(0, 0, 50, 50));
      nav.currentState!.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => const Stack(
            children: [
              Positioned(
                left: 200,
                top: 200,
                width: 60,
                height: 60,
                child: MorphTag(tag: 't', child: SizedBox()),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(scope.rectOf('t'), const Rect.fromLTWH(200, 200, 60, 60));
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(scope.rectOf('t'), const Rect.fromLTWH(0, 0, 50, 50));
    },
  );

  testWidgets('a row flying into a tall header keeps its text aspect', (
    tester,
  ) async {
    final p = ValueNotifier<double>(0);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MorphScope(
          child: DefaultTextStyle(
            style: const TextStyle(fontSize: 20, color: Color(0xFF000000)),
            child: Stack(
              children: [
                const Positioned(
                  left: 0,
                  top: 0,
                  width: 300,
                  height: 60,
                  child: MorphTag(
                    tag: 'a',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'A long row title',
                        key: ValueKey('row-text'),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 300,
                  width: 300,
                  height: 220,
                  child: MorphTag(
                    tag: 'b',
                    child: Container(color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final rest = tester.getSize(find.byKey(const ValueKey('row-text')));
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    scope.fly(from: 'a', to: 'b', progress: p);
    p.value = 0.5;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final standIn = find.descendant(
      of: find.byType(FittedBox),
      matching: find.byKey(const ValueKey('row-text')),
    );
    final r = tester.getRect(standIn);
    expect(r.width / r.height, closeTo(rest.width / rest.height, 0.02));
  });

  testWidgets(
    'a finger past full travel keeps the flight; the settle ends it',
    (tester) async {
      final mp = MotionProgress(vsync: const TestVSync());
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MorphScope(
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  width: 100,
                  height: 100,
                  child: MorphTag(
                    tag: 'a',
                    child: Container(color: Colors.red),
                  ),
                ),
                Positioned(
                  left: 200,
                  top: 100,
                  width: 50,
                  height: 50,
                  child: MorphTag(
                    tag: 'b',
                    child: Container(color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
      scope.fly(from: 'a', to: 'b', progress: mp);
      mp.beginDrag();
      mp.dragTo(1.12, clamp: false);
      await tester.pump();
      await tester.pump();
      expect(mp.value, closeTo(1.12, 1e-9));
      // The stand-in follows the finger past the end (linear, 1.12 of the way).
      final flight = tester.widget<Positioned>(
        find
            .ancestor(
              of: find.byType(FittedBox),
              matching: find.byType(Positioned),
            )
            .first,
      );
      expect(flight.left, closeTo(224, 0.01));
      expect(flight.top, closeTo(112, 0.01));
      expect(flight.width, closeTo(44, 0.01));
      expect(
        find.ancestor(
          of: find.byType(FittedBox),
          matching: find.byType(Positioned),
        ),
        findsWidgets,
        reason: 'still flying while the finger is past 1',
      );
      mp.release(velocityPerSecond: 0, rules: ReleaseRules.artDrag);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(mp.value, 1);
      expect(
        find.ancestor(
          of: find.byType(FittedBox),
          matching: find.byType(Positioned),
        ),
        findsNothing,
      );
      mp.dispose();
    },
  );
}
