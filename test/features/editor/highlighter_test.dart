import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/shape_recognizer.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/library/note_content.dart';

RawInkSample _sample(double x, double y, int ms, {double? pressure}) {
  return RawInkSample(
    position: InkVector(x, y),
    timestamp: Duration(milliseconds: ms),
    pressure: pressure,
  );
}

void main() {
  group('defaults', () {
    test('highlighter: translucent yellow, 12 px, 4-40 px, 0.35', () {
      const PenConfig config = PenConfig();
      final PenSettings settings = PenSettings.defaults();
      final PenSettings highlighter = settings.copyWith(
        style: WritingStyle.highlighter,
      );

      expect(settings.style, WritingStyle.pen);
      expect(config.highlighterMinWidth, 4);
      expect(config.highlighterMaxWidth, 40);
      expect(config.highlighterOpacity, 0.35);
      expect(highlighter.activeInk, InkPalette.highlighterYellow);
      expect(highlighter.activeWidth, 12);
      final StrokeStyle style = highlighter.strokeStyle(config);
      expect(style.writing, WritingStyle.highlighter);
      expect(style.opacity, 0.35);
      expect(style.width, 12);
    });

    test('the pen keeps its own defaults', () {
      final StrokeStyle style = PenSettings.defaults().strokeStyle();
      expect(style.writing, WritingStyle.pen);
      expect(style.opacity, 1);
      expect(style.ink, InkPalette.ink);
      expect(style.width, 3);
    });
  });

  test('pen and highlighter remember their own ink and width', () {
    PenSettings settings = PenSettings.defaults();
    final InkColor blue = InkPalette.colors.firstWhere((c) => c.id == 'blue');
    settings = settings.withActiveInk(blue).withActiveWidth(7);
    settings = settings.copyWith(style: WritingStyle.highlighter);
    final InkColor pink = InkPalette.highlighterColors.firstWhere(
      (c) => c.id == 'hl-pink',
    );
    settings = settings.withActiveInk(pink).withActiveWidth(30);

    expect(settings.activeInk, pink);
    expect(settings.activeWidth, 30);
    settings = settings.copyWith(style: WritingStyle.pen);
    expect(settings.activeInk, blue);
    expect(settings.activeWidth, 7);
    expect(settings.highlighterInk, pink);
    expect(settings.highlighterWidth, 30);
  });

  test('a highlighter has no taper, pressure, following, or shapes', () {
    final PenSettings highlighter = PenSettings.defaults().copyWith(
      style: WritingStyle.highlighter,
      tipSharpness: 1,
      pressureSensitivity: 1,
      holdToShape: true,
      followStroke: true,
    );
    expect(highlighter.dynamics.isNone, isTrue);
    expect(highlighter.armsHoldToShape, isFalse);
    expect(highlighter.followsStrokes, isFalse);

    final PenSettings pen = highlighter.copyWith(style: WritingStyle.pen);
    expect(pen.dynamics.isNone, isFalse);
    expect(pen.armsHoldToShape, isTrue);
  });

  test('opacity is applied once, by resolve, over any paper', () {
    final StrokeStyle style = PenSettings.defaults()
        .copyWith(style: WritingStyle.highlighter)
        .strokeStyle();
    final Color light = style.resolve(Brightness.light);
    final Color dark = style.resolve(Brightness.dark);
    expect(light.a, closeTo(0.35, 1e-3));
    expect(dark.a, closeTo(0.35, 1e-3));
    // The base is not pre-blended with any paper.
    expect(
      light.withValues(alpha: 1),
      InkPalette.highlighterYellow.onLightPaper,
    );
    // A pen is opaque.
    expect(PenSettings.defaults().strokeStyle().resolve(Brightness.light).a, 1);
  });

  test('a highlighter stroke is even even with pressure', () {
    final StrokeStyle style = PenSettings.defaults()
        .copyWith(style: WritingStyle.highlighter)
        .strokeStyle();
    final ActiveStroke active = ActiveStroke(
      style: style,
      first: _sample(0, 0, 0, pressure: 0.1),
      dynamics: PenSettings.defaults()
          .copyWith(style: WritingStyle.highlighter, pressureSensitivity: 1)
          .dynamics,
    );
    for (int i = 1; i <= 20; i++) {
      active.add(_sample(i * 10.0, 0, i * 8, pressure: i.isOdd ? 1 : 0));
    }
    final Stroke stroke = active.finish();
    expect(stroke.widths, isNull);
    expect(stroke.style.opacity, 0.35);
  });

  test('a highlighter tap is a translucent round dot', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    final StrokeStyle style = PenSettings.defaults()
        .copyWith(style: WritingStyle.highlighter)
        .strokeStyle();
    controller.startStroke(
      pointer: 1,
      sample: _sample(50, 50, 0),
      style: style,
    );
    controller.endStroke(1);
    expect(controller.strokes.single.isDot, isTrue);
    expect(controller.strokes.single.style.isHighlighter, isTrue);
  });

  test('holding a highlighter stroke never makes it a shape', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    final StrokeStyle style = PenSettings.defaults()
        .copyWith(style: WritingStyle.highlighter)
        .strokeStyle();
    controller.startStroke(
      pointer: 1,
      sample: _sample(0, 100, 0),
      style: style,
    );
    for (int i = 1; i <= 30; i++) {
      controller.addSamples(1, <RawInkSample>[_sample(i * 10.0, 100, i * 8)]);
    }
    expect(
      controller.convertActiveStrokeToShape(
        1,
        recognizer: const ShapeRecognizer(),
      ),
      isNull,
    );
    controller.endStroke(1);
    expect(controller.strokes.single.style.isHighlighter, isTrue);
  });

  test('highlighters darken in document order and keep their place', () {
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    final StrokeStyle pen = PenSettings.defaults().strokeStyle();
    final StrokeStyle marker = PenSettings.defaults()
        .copyWith(style: WritingStyle.highlighter)
        .strokeStyle();
    for (final StrokeStyle style in <StrokeStyle>[pen, marker, pen]) {
      controller.startStroke(
        pointer: 1,
        sample: _sample(0, 0, 0),
        style: style,
      );
      controller.addSamples(1, <RawInkSample>[_sample(100, 0, 8)]);
      controller.endStroke(1);
    }
    expect(
      controller.strokes.map((Stroke s) => s.style.writing).toList(),
      <WritingStyle>[
        WritingStyle.pen,
        WritingStyle.highlighter,
        WritingStyle.pen,
      ],
    );
  });

  test('saved highlighters come back with their style and opacity; old '
      'strokes are pens', () {
    final Stroke marker = Stroke.fromPoints(
      style: const StrokeStyle(
        ink: InkPalette.highlighterYellow,
        width: 12,
        writing: WritingStyle.highlighter,
        opacity: 0.35,
      ),
      points: const <InkVector>[InkVector(0, 0), InkVector(50, 0)],
    );
    final Map<String, Object?> json = StoredPage.strokeToJson(marker);
    expect(json['style'], 'highlighter');
    final Stroke back = StoredPage.strokeFromJson(json)!;
    expect(back.style, marker.style);

    final Stroke legacy = StoredPage.strokeFromJson(<String, Object?>{
      'ink': 'ink',
      'width': 3,
      'points': <double>[0, 0, 10, 10],
    })!;
    expect(legacy.style.writing, WritingStyle.pen);
    expect(legacy.style.opacity, 1);

    final Stroke unknown = StoredPage.strokeFromJson(<String, Object?>{
      'ink': 'hl-yellow',
      'width': 12,
      'style': 'marker-from-the-future',
      'points': <double>[0, 0, 10, 10],
    })!;
    expect(unknown.style.writing, WritingStyle.pen);

    final Stroke badOpacity = StoredPage.strokeFromJson(<String, Object?>{
      'ink': 'hl-yellow',
      'width': 12,
      'style': 'highlighter',
      'opacity': 7,
      'points': <double>[0, 0, 10, 10],
    })!;
    expect(badOpacity.style.opacity, StrokeStyle.defaultHighlighterOpacity);
  });

  test('a transform keeps a highlighter a highlighter', () {
    final Stroke marker = Stroke.fromPoints(
      style: const StrokeStyle(
        ink: InkPalette.highlighterYellow,
        width: 12,
        writing: WritingStyle.highlighter,
        opacity: 0.35,
      ),
      points: const <InkVector>[InkVector(100, 100), InkVector(200, 100)],
    );
    expect(marker.style.withWidth(24).isHighlighter, isTrue);
    expect(marker.style.withWidth(24).opacity, 0.35);
  });
}
