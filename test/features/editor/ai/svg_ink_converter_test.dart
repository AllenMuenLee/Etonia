import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/svg_ink_converter.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

EditableSvg _svg(String body, {String animation = ''}) => EditableSvg.parse(
  '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
  'viewBox="0 0 200 200" data-etonia-bounds="10 10 180 180" '
  '$animation><title>Native ink</title>'
  '<desc data-etonia-role="message">Drawn.</desc>$body</svg>',
  modelResponse: true,
);

void main() {
  group('SvgInkConverter', () {
    test('keeps good shapes on both sides of a malformed shape', () {
      final EditableSvg svg = _svg(
        '<path d="M10 20 L90 20" stroke="black" fill="none"/>'
        '<path d="invalid path"/>'
        '<g transform="invalid(1)"><path d="M10 30 L90 30"/></g>'
        '<path d="M10 40 L90 40" stroke="black" fill="none"/>',
      );
      expect(
        () => SvgInkConverter.convert(
          svg,
          defaultInk: InkPalette.ink,
          defaultWidth: 2,
        ),
        throwsFormatException,
      );
      final SvgInkConversion result = SvgInkConverter.convert(
        svg,
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
        skipInvalidElements: true,
      );
      expect(result.traces, hasLength(2));
      expect(result.traces.first.points.first.y, closeTo(20, 1));
      expect(result.traces.last.points.first.y, closeTo(40, 1));
    });

    test('does not apply empty notation when every shape is invalid', () {
      expect(
        () => SvgInkConverter.convert(
          _svg('<path d="invalid path"/>'),
          defaultInk: InkPalette.ink,
          defaultWidth: 2,
          skipInvalidElements: true,
        ),
        throwsFormatException,
      );
    });

    test('turns every supported SVG contour into a native trace', () {
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg('''
          <path d="M20 20 C40 10 60 30 80 20 M20 30 A10 10 0 0 1 40 30"
            fill="none" stroke="black"/>
          <line x1="20" y1="40" x2="80" y2="40" stroke="black"/>
          <polyline points="20,60 50,50 80,60" fill="none" stroke="black"/>
          <polygon points="20,80 50,70 80,80" fill="none" stroke="black"/>
          <rect x="100" y="20" width="50" height="30" rx="5"
            fill="none" stroke="black"/>
          <circle cx="125" cy="85" r="20" fill="none" stroke="black"/>
          <ellipse cx="125" cy="140" rx="30" ry="15"
            fill="none" stroke="black"/>
        '''),
        defaultInk: InkPalette.ink,
        defaultWidth: 3,
      );

      // The path's two subpaths are two independently editable strokes.
      expect(result.traces, hasLength(8));
      expect(result.playbackDuration, isNull);
      for (final GeneratedInkTrace trace in result.traces) {
        expect(trace.points, isNotEmpty);
        expect(trace.points.length, lessThanOrEqualTo(8192));
        expect(trace.style.ink, same(InkPalette.ink));
      }
      expect(result.traces[4].points.first, result.traces[4].points.last);
    });

    test('uses the user pen width through transforms and model widths', () {
      final InkColor red = InkPalette.byId('red')!;
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg('''
          <g transform="translate(10 20) scale(2)" opacity="0.5">
            <path d="M10 15 L30 15" fill="none" stroke="#c62f2f"
              stroke-width="2" data-etonia-stroke-ink="red"/>
            <path d="M10 25 L30 25" fill="none" stroke="#c62f2f"
              stroke-width="12" data-etonia-stroke-ink="red"/>
          </g>
        '''),
        defaultInk: InkPalette.ink,
        defaultWidth: 3,
      );

      final GeneratedInkTrace trace = result.traces.first;
      expect(trace.points.first.x, closeTo(30, 0.01));
      expect(trace.points.first.y, closeTo(50, 0.01));
      expect(trace.points.last.x, closeTo(70, 0.01));
      expect(trace.style.ink, same(red));
      expect(result.traces, hasLength(2));
      expect(
        result.traces.map((GeneratedInkTrace trace) => trace.style.width),
        everyElement(3),
      );
      expect(trace.style.opacity, closeTo(0.5, 0.001));
    });

    test('samples large curves at sub-pixel resolution', () {
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg('''
          <circle cx="100" cy="100" r="80" fill="none" stroke="black"/>
        '''),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );

      final List<InkVector> points = result.traces.single.points;
      expect(points.length, greaterThan(200));
      double longestSegment = 0;
      for (int i = 1; i < points.length; i++) {
        longestSegment = math.max(
          longestSegment,
          (points[i] - points[i - 1]).length,
        );
      }
      expect(longestSegment, lessThan(2.5));
    });

    test('clips provider curve overshoot instead of dropping the notation', () {
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg('''
          <path d="M-0.2 40 C40 -0.4 160 200.4 200.2 160"
            fill="none" stroke="black"/>
        '''),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );

      expect(result.traces, hasLength(1));
      for (final InkVector point in result.traces.single.points) {
        expect(point.x, inInclusiveRange(1, 199));
        expect(point.y, inInclusiveRange(1, 199));
      }
    });

    test('maps semantic SVG steps onto native playback times', () {
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg('''
            <line x1="20" y1="20" x2="80" y2="20" stroke="black"/>
            <line x1="20" y1="40" x2="80" y2="40" stroke="black"
              data-etonia-step="1"/>
            <line x1="20" y1="60" x2="80" y2="60" stroke="black"
              data-etonia-step="2"/>
          ''', animation: 'data-etonia-duration-ms="1000"'),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );

      expect(result.playbackDuration, const Duration(milliseconds: 1000));
      expect(result.traces[0].timesMs, everyElement(0));
      expect(result.traces[1].timesMs!.first, 0);
      expect(result.traces[1].timesMs!.last, 500);
      expect(result.traces[2].timesMs!.first, 500);
      expect(result.traces[2].timesMs!.last, 1000);
    });

    test('converted contours erase independently as ordinary strokes', () {
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg('''
          <line x1="20" y1="50" x2="180" y2="50" stroke="black"/>
          <line x1="20" y1="100" x2="180" y2="100" stroke="black"/>
        '''),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      expect(
        controller.addAiNotation(
          traces: result.traces,
          expectedRevision: controller.documentRevision,
          surfaceSize: const Size(200, 200),
        ),
        AddNotationResult.added,
      );
      expect(controller.images, isEmpty);
      expect(controller.strokes, hasLength(2));

      expect(
        controller.startErase(
          pointer: 1,
          position: const InkVector(50, 50),
          settings: const EraserSettings(mode: EraserMode.stroke, size: 24),
        ),
        isTrue,
      );
      controller.endErase(1);

      expect(controller.strokes, hasLength(1));
      expect(controller.strokes.single.points.first.y, closeTo(100, 0.01));
    });
  });

  group('drawn by hand', () {
    SvgInkConversion convert(String body, {bool sketch = true}) =>
        SvgInkConverter.convert(
          _svg(body),
          defaultInk: InkPalette.ink,
          defaultWidth: 2,
          sketch: sketch,
        );

    double furthestFrom(List<InkVector> points, double y) =>
        points.map((InkVector point) => (point.y - y).abs()).reduce(math.max);

    test('a straight line bows a little, keeping its ends', () {
      const String line =
          '<line x1="20" y1="100" x2="180" y2="100" stroke="black"/>';
      final List<InkVector> drawn = convert(line).traces.single.points;
      expect(drawn.first.x, closeTo(20, 0.01));
      expect(drawn.first.y, closeTo(100, 0.01));
      expect(drawn.last.x, closeTo(180, 0.01));
      expect(drawn.last.y, closeTo(100, 0.01));
      // 160 long: it bows between 2 and 4 units, at most.
      expect(furthestFrom(drawn, 100), inInclusiveRange(1.5, 5.5));

      final List<InkVector> ruled = convert(
        line,
        sketch: false,
      ).traces.single.points;
      expect(furthestFrom(ruled, 100), lessThan(0.01));
    });

    test('the same notation is drawn the same way every time', () {
      const String body =
          '<polyline points="20,20 100,60 180,20" fill="none" stroke="black"/>'
          '<circle cx="100" cy="130" r="40" fill="none" stroke="black"/>';
      final SvgInkConversion once = convert(body);
      final SvgInkConversion again = convert(body);
      for (int i = 0; i < once.traces.length; i++) {
        expect(again.traces[i].points, once.traces[i].points);
      }
    });

    test('a polyline keeps its corners where they were written', () {
      final List<InkVector> drawn = convert(
        '<polyline points="20,20 100,60 180,20" fill="none" stroke="black"/>',
      ).traces.single.points;
      expect(
        drawn.any(
          (InkVector point) => (point - const InkVector(100, 60)).length < 0.3,
        ),
        isTrue,
      );
    });

    test('a circle is one loop that runs past its start, never inside', () {
      final List<InkVector> drawn = convert(
        '<circle cx="100" cy="100" r="40" fill="none" stroke="black"/>',
      ).traces.single.points;
      for (final InkVector point in drawn) {
        final double radius = (point - const InkVector(100, 100)).length;
        expect(radius, inInclusiveRange(39.9, 47));
      }
      // The pen ends past where it began, a little further out.
      expect((drawn.last - drawn.first).length, greaterThan(2));
      double turned = 0;
      for (int i = 1; i < drawn.length; i++) {
        final InkVector a = drawn[i - 1] - const InkVector(100, 100);
        final InkVector b = drawn[i] - const InkVector(100, 100);
        turned += math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y);
      }
      expect(turned.abs(), greaterThan(2 * math.pi));
    });

    test('an arrow gets a head along its shaft, drawn by the app', () {
      final SvgInkConversion result = convert(
        '<line x1="20" y1="100" x2="180" y2="100" stroke="black" '
        'data-etonia-arrow="end"/>',
      );
      expect(result.traces, hasLength(2));
      final List<InkVector> head = result.traces[1].points;
      // One stroke: a wing, the tip at the end of the shaft, the other wing.
      final InkVector tip = head.reduce(
        (InkVector a, InkVector b) => a.x > b.x ? a : b,
      );
      expect(tip.x, closeTo(180, 0.01));
      expect(tip.y, closeTo(100, 0.01));
      expect(head.first.x, lessThan(175));
      expect(head.last.x, lessThan(175));
      // The wings sit either side of the shaft.
      expect((head.first.y - 100).sign, -(head.last.y - 100).sign);
    });

    test('a curved shaft points its head the way the curve ends', () {
      final List<InkVector> head = convert(
        '<path d="M20 20 Q180 20 180 180" fill="none" stroke="black" '
        'data-etonia-arrow="end"/>',
      ).traces[1].points;
      // The curve comes down into its end, so both wings are above it.
      expect(head.first.y, lessThan(175));
      expect(head.last.y, lessThan(175));
      expect((head.first.x - 180).sign, -(head.last.x - 180).sign);
    });

    test('both ends, or an SVG marker, take heads too', () {
      expect(
        convert(
          '<line x1="20" y1="50" x2="180" y2="50" stroke="black" '
          'data-etonia-arrow="both"/>',
        ).traces,
        hasLength(3),
      );
      expect(
        convert(
          '<line x1="20" y1="50" x2="180" y2="50" stroke="black" '
          'marker-end="url(#head)"/>',
        ).traces,
        hasLength(2),
      );
    });

    test('a head appears as its end of the shaft is drawn', () {
      final SvgInkConversion result = SvgInkConverter.convert(
        _svg(
          '<line x1="20" y1="50" x2="180" y2="50" stroke="black" '
          'data-etonia-arrow="end" data-etonia-step="1"/>',
          animation: 'data-etonia-duration-ms="1000"',
        ),
        defaultInk: InkPalette.ink,
        defaultWidth: 2,
      );
      expect(result.traces[1].timesMs, everyElement(1000));
    });

    test('handwritten text is left as written', () {
      final List<InkVector> drawn = convert(
        '<g data-etonia-handwriting="1">'
        '<path d="M20 100 L180 100" fill="none" stroke="black"/></g>',
      ).traces.single.points;
      expect(furthestFrom(drawn, 100), lessThan(0.01));
    });
  });
}
