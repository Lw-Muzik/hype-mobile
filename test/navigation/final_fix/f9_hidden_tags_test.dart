import 'package:eq_app/navigation/motion/morph.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Found on a tablet: while the cover flew from a row into the player, the
// player's card deck showed the next track's card where the cover was (the
// tagged card was hidden, the cards stacked behind it were not). The scope
// says which tags are behind a flying stand-in so such a widget can hide too.

Widget _tags() => Directionality(
  textDirection: TextDirection.ltr,
  child: MorphScope(
    child: Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: 100,
          height: 100,
          child: MorphTag(tag: 'row', child: Container(color: Colors.red)),
        ),
        Positioned(
          left: 200,
          top: 100,
          width: 50,
          height: 50,
          child: MorphTag(tag: 'cover', child: Container(color: Colors.blue)),
        ),
      ],
    ),
  ),
);

void main() {
  testWidgets('hiddenTags names both ends while a flight is armed', (
    tester,
  ) async {
    await tester.pumpWidget(_tags());
    final scope = MorphScope.of(tester.element(find.byType(MorphTag).first));
    expect(scope.hiddenTags.value, isEmpty);

    final p = ValueNotifier<double>(0);
    scope.fly(from: 'row', to: 'cover', progress: p);
    p.value = 0.3;
    await tester.pump();
    await tester.pump();
    await tester.pump(); // armed after two frames
    expect(scope.hiddenTags.value, {'row', 'cover'});

    p.value = 1;
    await tester.pump();
    await tester.pump();
    expect(scope.hiddenTags.value, isEmpty);
  });
}
