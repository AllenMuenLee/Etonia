import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/shared/widgets/processing.dart';

const Key _loaded = ValueKey<String>('loaded-content');
const Key _standIn = ValueKey<String>('stand-in');

/// One theme for every pump, so the app never animates between two.
final ThemeData _theme = AppTheme.light();

Widget _reveal(
  bool ready, {
  bool placeholder = false,
  bool reduceMotion = false,
  String? timing = 'test.load',
  Widget? child,
}) {
  return MaterialApp(
    theme: _theme,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Center(
        child: SizedBox.square(
          dimension: 100,
          child: LoadingReveal(
            timing: timing,
            effect: RevealEffect.zoom,
            semanticsLabel: 'Loading',
            placeholder: placeholder
                ? const ColoredBox(key: _standIn, color: Color(0xFF888888))
                : null,
            child: ready
                ? child ??
                      const ColoredBox(key: _loaded, color: Color(0xFF000000))
                : null,
          ),
        ),
      ),
    ),
  );
}

/// How far into view what [key] marks has faded: [depth] counts the fades
/// around it, nearest first.
double _opacityOf(WidgetTester tester, Key key, {int depth = 0}) => tester
    .widget<FadeTransition>(
      find
          .ancestor(of: find.byKey(key), matching: find.byType(FadeTransition))
          .at(depth),
    )
    .opacity
    .value;

void main() {
  group('LoadTimings', () {
    test('learns from each load without one swinging it', () {
      final LoadTimings timings = LoadTimings.instance;
      expect(timings.expected('new'), LoadTimings.unknown);
      timings.record('new', const Duration(milliseconds: 100));
      expect(timings.expected('new'), const Duration(milliseconds: 100));
      timings.record('new', const Duration(milliseconds: 1100));
      // 100 + (1100 - 100) * 0.3
      expect(timings.expected('new'), const Duration(milliseconds: 400));
    });
  });

  group('LoadingReveal', () {
    testWidgets('what is already there shows at once', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_reveal(true));
      expect(tester.hasRunningAnimations, isFalse);
      expect(_opacityOf(tester, _loaded), 1);
    });

    testWidgets('arrives with the fixed content fade', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_reveal(false));
      expect(find.byKey(_loaded), findsNothing);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);

      const Duration wait = Duration(milliseconds: 500);
      await tester.pump(wait);
      await tester.pumpWidget(_reveal(true));
      // The transition's first frame.
      await tester.pump();
      await tester.pump(AppMotion.fadeIn - const Duration(milliseconds: 40));
      expect(_opacityOf(tester, _loaded), lessThan(1));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 40));
      expect(_opacityOf(tester, _loaded), 1);
      // Over once a frame lands past its end.
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.bySemanticsLabel('Loading'), findsNothing);
      // Learned for the next time.
      expect(LoadTimings.instance.expected('test.load'), wait);
    });

    testWidgets('a placeholder shimmers in on the shared loading cadence', (
      WidgetTester tester,
    ) async {
      LoadTimings.instance.record(
        'test.load',
        const Duration(milliseconds: 900),
      );
      await tester.pumpWidget(_reveal(false, placeholder: true));
      await tester.pump();
      // Its own arrival, past the fade that later hands it over.
      await tester.pump(AppMotion.fadeIn ~/ 2);
      expect(
        _opacityOf(tester, _standIn, depth: 1),
        allOf(greaterThan(0), lessThan(1)),
      );
      await tester.pump(
        AppMotion.fadeIn ~/ 2 + const Duration(milliseconds: 20),
      );
      expect(_opacityOf(tester, _standIn, depth: 1), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('the placeholder gives way without disturbing what loaded', (
      WidgetTester tester,
    ) async {
      final GlobalKey key = GlobalKey();
      final Widget child = SizedBox.expand(key: key);
      await tester.pumpWidget(_reveal(false, placeholder: true, child: child));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(_reveal(true, placeholder: true, child: child));
      final Element arriving = key.currentContext! as Element;
      expect(find.byKey(_standIn), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byKey(_standIn), findsNothing);
      expect(key.currentContext, same(arriving));
    });

    testWidgets('reduced motion uses only the short fade', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _reveal(false, placeholder: true, reduceMotion: true),
      );
      await tester.pump(AppMotion.reduced);
      expect(_opacityOf(tester, _standIn, depth: 1), 1);
      await tester.pumpWidget(
        _reveal(true, placeholder: true, reduceMotion: true),
      );
      // The first frame starts the ticker; the next runs it out.
      await tester.pump();
      await tester.pump(AppMotion.reduced);
      await tester.pump(AppMotion.reduced);
      expect(tester.hasRunningAnimations, isFalse);
      expect(_opacityOf(tester, _loaded), 1);
      expect(find.byKey(_standIn), findsNothing);
    });

    testWidgets('loading again waits again', (WidgetTester tester) async {
      await tester.pumpWidget(_reveal(true));
      await tester.pumpWidget(_reveal(false));
      expect(find.byKey(_loaded), findsNothing);
      await tester.pumpWidget(_reveal(true));
      expect(_opacityOf(tester, _loaded), 0);
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, _loaded), 1);
    });
  });

  group('PendingLines', () {
    testWidgets('learns how long it stood', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: PendingLines(timing: 'test.reply', semanticsLabel: 'Waiting'),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Waiting'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        LoadTimings.instance.expected('test.reply'),
        const Duration(seconds: 2),
      );
    });
  });
}
