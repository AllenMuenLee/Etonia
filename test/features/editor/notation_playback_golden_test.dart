@Tags(<String>['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import '../../helpers/pump_app.dart';

Stroke _existingInk() {
  return Stroke.fromPoints(
    style: const StrokeStyle(ink: InkPalette.ink, width: 4),
    points: const <InkVector>[
      InkVector(100, 380),
      InkVector(190, 350),
      InkVector(280, 390),
      InkVector(370, 360),
    ],
  );
}

List<GeneratedInkTrace> _animatedInk(Size size) {
  final InkColor blue = InkPalette.byId('blue')!;
  final InkColor red = InkPalette.byId('red')!;
  return <GeneratedInkTrace>[
    GeneratedInkTrace(
      style: StrokeStyle(ink: blue, width: 6),
      points: <InkVector>[
        InkVector(size.width * 0.22, size.height * 0.28),
        InkVector(size.width * 0.38, size.height * 0.42),
        InkVector(size.width * 0.58, size.height * 0.22),
      ],
      timesMs: <double>[0, 600, 1000],
    ),
    GeneratedInkTrace(
      style: StrokeStyle(ink: red, width: 10),
      points: <InkVector>[InkVector(size.width * 0.68, size.height * 0.32)],
      timesMs: <double>[450],
    ),
  ];
}

void main() {
  for (final (String themeName, ThemeMode themeMode) in <(String, ThemeMode)>[
    ('light', ThemeMode.light),
    ('dark', ThemeMode.dark),
  ]) {
    for (final (String state, Duration elapsed) in <(String, Duration)>[
      ('start', Duration.zero),
      ('middle', const Duration(milliseconds: 500)),
      ('end', const Duration(milliseconds: 1000)),
    ]) {
      testWidgets('notation playback $state: $themeName', (
        WidgetTester tester,
      ) async {
        setViewportSize(tester, TestViewport.tabletLandscape.size);
        final InkController controller = InkController(
          strokes: <Stroke>[_existingInk()],
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          GreatnoteApp(
            themeMode: themeMode,
            home: TickerMode(
              enabled: false,
              child: EditorScreen(inkController: controller),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final Size surface = tester.getSize(find.byType(InkCanvas));
        expect(
          controller.addAiNotation(
            traces: _animatedInk(surface),
            expectedRevision: 0,
            surfaceSize: surface,
            playbackDuration: const Duration(milliseconds: 1200),
          ),
          AddNotationResult.addedWithPlayback,
        );
        if (elapsed > Duration.zero) {
          controller.advanceNotationPlayback(elapsed);
        }
        await tester.pump();

        expect(controller.notationPlayback, isNotNull);
        await expectLater(
          find.byType(GreatnoteApp),
          matchesGoldenFile(
            'goldens/notation_playback_${state}_$themeName.png',
          ),
        );
      });
    }
  }
}
