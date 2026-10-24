import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/navigation/app_dialogs.dart';
import 'package:greatnote/shared/navigation/app_sheets.dart';

const Key _openKey = Key('open');

/// A home page with one button that pushes a second page, themed as the app.
Widget _routes({bool reduced = false, bool fullscreenDialog = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Builder(
      builder: (BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            key: _openKey,
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                fullscreenDialog: fullscreenDialog,
                builder: (BuildContext context) =>
                    const Scaffold(body: Center(child: Text('second'))),
              ),
            ),
            child: const Text('first'),
          ),
        ),
      ),
    ),
  );
}

Offset _secondPageOffset(WidgetTester tester) {
  return tester.getTopLeft(find.text('second'));
}

void main() {
  group('page transitions', () {
    testWidgets('a push slides in from the trailing edge', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_routes());
      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(AppMotion.smooth.duration ~/ 4);
      final double earlier = _secondPageOffset(tester).dx;
      await tester.pumpAndSettle();
      final double settled = _secondPageOffset(tester).dx;
      expect(earlier, greaterThan(settled));
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('a leading-edge swipe pops interactively', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_routes());
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();

      final TestGesture gesture = await tester.startGesture(
        const Offset(4, 300),
      );
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      // Tracking the finger: the page has moved with it, and is still there.
      final double tracked = _secondPageOffset(tester).dx;
      expect(tracked, greaterThan(100));
      expect(find.text('second'), findsOneWidget);

      await gesture.moveBy(const Offset(400, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('second'), findsNothing);
      expect(find.text('first'), findsOneWidget);
    });

    testWidgets('a swipe can be released short and reversed mid-flight', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_routes());
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();

      final double rest = _secondPageOffset(tester).dx;

      // Dragged most of the way, then taken back under the finger before the
      // release: the transition reverses, and the page stays.
      final TestGesture gesture = await tester.startGesture(
        const Offset(4, 300),
      );
      await gesture.moveBy(const Offset(500, 0));
      await tester.pump();
      expect(_secondPageOffset(tester).dx, greaterThan(rest + 400));
      await gesture.moveBy(const Offset(-440, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('second'), findsOneWidget);
      expect(_secondPageOffset(tester).dx, rest);
    });

    testWidgets('reduced motion only cross-fades, with no travel', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_routes(reduced: true));
      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(AppMotion.reduced ~/ 2);
      final Finder incoming = find.ancestor(
        of: find.text('second'),
        matching: find.byType(FadeTransition),
      );
      expect(incoming, findsWidgets);
      // The page is already where it will rest.
      expect(_secondPageOffset(tester).dx, lessThan(400));
      final double mid = _secondPageOffset(tester).dx;
      await tester.pumpAndSettle();
      expect(_secondPageOffset(tester).dx, mid);
    });

    testWidgets('the page below moves back by Cupertino\'s parallax', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_routes());
      final double before = tester.getTopLeft(find.text('first')).dx;
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();
      final double after = tester
          .getTopLeft(find.text('first', skipOffstage: false))
          .dx;
      final double width = tester.getSize(find.byType(MaterialApp)).width;
      // Flutter's iOS push moves the page below a third of the width, which
      // is the "about 30%" the design asks for.
      expect(before - after, closeTo(width / 3, width * 0.02));
    });
  });

  group('dialogs and sheets', () {
    testWidgets('an alert grows from 1.08 and fades, then leaves quickly', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext context) => TextButton(
              key: _openKey,
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (BuildContext context) =>
                    const AlertDialog(content: Text('alert')),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_openKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final double early = tester
          .widget<ScaleTransition>(
            find
                .ancestor(
                  of: find.byType(AlertDialog),
                  matching: find.byType(ScaleTransition),
                )
                .first,
          )
          .scale
          .value;
      expect(early, greaterThan(1));
      expect(early, lessThanOrEqualTo(1.08));
      await tester.pumpAndSettle();
      expect(find.text('alert'), findsOneWidget);

      Navigator.of(tester.element(find.text('alert'))).pop();
      await tester.pump();
      await tester.pump(AppMotion.fadeOut);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('alert'), findsNothing);
    });

    test('the dialog route is shorter leaving than arriving', () {
      expect(AppMotion.fadeOut, lessThan(AppMotion.fadeIn));
      expect(AppMotion.snappy.duration, lessThan(AppMotion.smooth.duration));
    });

    test('a sheet snaps to the nearest detent after projecting velocity', () {
      // At rest it keeps the detent it is closest to.
      expect(projectSheetDetent(extent: 0.45, velocity: 0), 0.5);
      expect(projectSheetDetent(extent: 0.8, velocity: 0), 1);
      // A flick upward from the medium detent carries it to large.
      expect(projectSheetDetent(extent: 0.55, velocity: 2.5), 1);
      // A flick downward from near large settles at medium.
      expect(projectSheetDetent(extent: 0.9, velocity: -3), 0.5);
      // A small drag with no speed returns to where it began.
      expect(projectSheetDetent(extent: 0.56, velocity: 0.1), 0.5);
    });
  });

  group('tokens', () {
    test('springs settle by about 250 ms and never overshoot but bouncy', () {
      for (final SpringDescription spring in <SpringDescription>[
        AppMotion.snappy,
        AppMotion.smooth,
      ]) {
        final SpringSimulation simulation = SpringSimulation(spring, 0, 1, 0);
        double peak = 0;
        for (int ms = 0; ms <= 600; ms += 5) {
          peak = peak < simulation.x(ms / 1000)
              ? simulation.x(ms / 1000)
              : peak;
        }
        expect(peak, lessThanOrEqualTo(1.0005));
        expect(simulation.x(0.25), greaterThan(0.85));
      }
      final SpringSimulation bouncy = SpringSimulation(
        AppMotion.bouncy,
        0,
        1,
        0,
      );
      double top = 0;
      for (int ms = 0; ms <= 600; ms += 5) {
        top = top < bouncy.x(ms / 1000) ? bouncy.x(ms / 1000) : top;
      }
      expect(top, greaterThan(1));
    });

    testWidgets('reduced motion resolves to the short linear fade', (
      WidgetTester tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (BuildContext c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        AppMotion.resolve(context, AppMotion.smooth.duration),
        AppMotion.reduced,
      );
      expect(
        AppMotion.springDuration(context, AppMotion.sheet),
        AppMotion.reduced,
      );
      expect(AppMotion.spring(context, AppMotion.bouncy).bounce, 0);
    });
  });

  group('feature code', () {
    test('uses motion tokens, not raw curves, staggers or scene sliders', () {
      final RegExp offenders = RegExp(
        r'Curves\.|Cubic\(|StaggerScope|StaggerItem|SceneSwitcher|'
        r'(?:duration|reverseDuration)\s*:\s*(?:const\s+)?Duration\((?:milliseconds|seconds)',
      );
      final List<String> found = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        if (path.endsWith('app/theme/app_tokens.dart')) continue;
        final List<String> lines = entity.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          if (offenders.hasMatch(lines[i])) found.add('$path:${i + 1}');
        }
      }
      expect(found, isEmpty, reason: found.join('\n'));
    });
  });
}
