import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/shared/widgets/etonia_mascot.dart';

Widget _app() => const MaterialApp(
  home: Scaffold(
    body: EtoniaMascot(clip: EtoniaClip.hop, rest: Duration(seconds: 5)),
  ),
);

void main() {
  tearDown(() => EtoniaMascot.idles = false);

  testWidgets('breathes while she stands still between clips', (
    WidgetTester tester,
  ) async {
    EtoniaMascot.idles = true;
    await tester.pumpWidget(_app());
    // One round of the clip, then she stands still.
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final Finder breathing = find.descendant(
      of: find.byType(EtoniaMascot),
      matching: find.byType(AnimatedBuilder),
    );
    expect(breathing, findsWidgets);
    Matrix4 scale() => tester
        .widget<Transform>(
          // The breath is the outermost turn; the one inside it mirrors her.
          find
              .descendant(of: breathing.first, matching: find.byType(Transform))
              .first,
        )
        .transform;
    final double before = scale().storage[5];
    await tester.pump(const Duration(milliseconds: 600));
    expect(scale().storage[5], isNot(closeTo(before, 0.0001)));
  });

  testWidgets('holds still when idling is off', (WidgetTester tester) async {
    EtoniaMascot.idles = false;
    await tester.pumpWidget(_app());
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Resting: nothing is scheduled until the next clip starts.
    expect(tester.hasRunningAnimations, isFalse);
  });
}
