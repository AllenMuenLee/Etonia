import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/live_notation.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

const String _root =
    '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" '
    'viewBox="0 0 800 1000" data-etonia-bounds="10 10 100 100">';
const String _desc = '<desc data-etonia-role="message">Answer</desc>';
const String _line = '<line x1="10" y1="10" x2="50" y2="50"/>';
const String _text = '<text x="10" y="40"><tspan>a &gt; b</tspan></text>';

void main() {
  group('completedSvgDocument', () {
    test('has nothing until an element has finished', () {
      expect(completedSvgDocument(''), isNull);
      expect(completedSvgDocument('<sv'), isNull);
      expect(completedSvgDocument(_root), isNull);
      expect(completedSvgDocument('$_root<desc data-etonia'), isNull);
      expect(completedSvgDocument('$_root<desc>Ans'), isNull);
    });

    test('is not fooled by something other than an SVG', () {
      expect(completedSvgDocument('{"version":2,"message":"<g/>"}'), isNull);
      expect(completedSvgDocument('$_root<g></line></svg>'), isNull);
      expect(completedSvgDocument('<!DOCTYPE svg>$_root$_desc'), isNull);
      expect(completedSvgDocument('$_root<!DOCTYPE x>$_desc'), isNull);
    });

    test('drops a part-written element and closes what is open', () {
      expect(
        completedSvgDocument('$_root$_desc<g>$_line<path d="M1 1'),
        '$_root$_desc<g>$_line</g></svg>',
      );
      expect(
        completedSvgDocument('$_root$_desc$_line<line x1="1" y1="2'),
        '$_root$_desc$_line</svg>',
      );
    });

    test('never cuts inside text or defs', () {
      const String defs = '<defs><marker id="a"><path d="M0 0"/></marker>';
      expect(completedSvgDocument('$_root$_desc$defs'), '$_root$_desc</svg>');
      expect(
        completedSvgDocument('$_root$_desc<text x="1"><tspan>a</tspan>'),
        '$_root$_desc</svg>',
      );
      expect(completedSvgDocument('$_root$_text'), '$_root$_text</svg>');
    });

    test('reads a > inside a quoted attribute as part of the tag', () {
      expect(
        completedSvgDocument(
          '$_root$_desc<path data-note="a > b" d="M1 1 L2 2"',
        ),
        '$_root$_desc</svg>',
      );
    });

    test('skips comments and takes off a fence', () {
      expect(
        completedSvgDocument('$_root<!-- <g> -->$_line<!-- unfinished'),
        '$_root<!-- <g> -->$_line</svg>',
      );
      expect(
        completedSvgDocument('```svg\n$_root$_line'),
        '$_root$_line</svg>',
      );
    });

    test('returns a finished document whole, without its closing fence', () {
      expect(
        completedSvgDocument('$_root$_line</svg>\n```'),
        '$_root$_line</svg>',
      );
    });

    test('every cut of a real answer parses, or has nothing yet', () {
      const String answer = '$_root$_desc<g>$_line$_text</g>$_line</svg>';
      for (int cut = 0; cut <= answer.length; cut++) {
        final String? document = completedSvgDocument(answer.substring(0, cut));
        if (document == null || !document.contains('<line')) continue;
        expect(
          () => EditableSvg.parse(document, modelResponse: true),
          returnsNormally,
          reason: answer.substring(0, cut),
        );
      }
    });
  });

  group('InkController.notationPreview', () {
    GeneratedInkTrace trace(double x) => GeneratedInkTrace(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: <InkVector>[InkVector(x, 10), InkVector(x + 5, 20)],
    );

    test('is shown over the ink and is no part of the document', () {
      final InkController ink = InkController();
      addTearDown(ink.dispose);
      int notified = 0;
      ink.notationPlaybackListenable.addListener(() => notified++);
      final int revision = ink.documentRevision;

      expect(
        ink.showNotationPreview(
          traces: <GeneratedInkTrace>[trace(10), trace(20)],
          surfaceSize: const Size(100, 100),
        ),
        isTrue,
      );
      expect(ink.notationPreview, hasLength(2));
      expect(notified, 1);
      expect(ink.strokes, isEmpty);
      expect(ink.documentRevision, revision);

      ink.clearNotationPreview();
      expect(ink.notationPreview, isEmpty);
      expect(notified, 2);
      // Nothing to clear, nothing to repaint.
      ink.clearNotationPreview();
      expect(notified, 2);
    });

    test('keeps the last good one when traces leave the page', () {
      final InkController ink = InkController();
      addTearDown(ink.dispose);
      ink.showNotationPreview(
        traces: <GeneratedInkTrace>[trace(10)],
        surfaceSize: const Size(100, 100),
      );
      expect(
        ink.showNotationPreview(
          traces: <GeneratedInkTrace>[trace(10), trace(500)],
          surfaceSize: const Size(100, 100),
        ),
        isFalse,
      );
      expect(ink.notationPreview, hasLength(1));
    });
  });

  group('LiveNotationPainter', () {
    test('draws at once, then keeps only the newest while it waits', () {
      fakeAsync((FakeAsync async) {
        final List<String> drawn = <String>[];
        final LiveNotationPainter painter = LiveNotationPainter(drawn.add);
        painter.add('$_root$_desc');
        expect(drawn, <String>['$_root$_desc</svg>']);
        painter.add('$_root$_desc$_line');
        painter.add('$_root$_desc$_line$_line');
        expect(drawn, hasLength(1));
        async.elapse(const Duration(milliseconds: 120));
        expect(drawn, <String>[
          '$_root$_desc</svg>',
          '$_root$_desc$_line$_line</svg>',
        ]);
      });
    });

    test('does not draw the same elements again', () {
      fakeAsync((FakeAsync async) {
        final List<String> drawn = <String>[];
        final LiveNotationPainter painter = LiveNotationPainter(drawn.add);
        painter.add('$_root$_line');
        async.elapse(const Duration(seconds: 1));
        painter.add('$_root$_line<path d="M1');
        async.elapse(const Duration(seconds: 1));
        expect(drawn, hasLength(1));
      });
    });

    test('a failed draw is not fatal, and the next one goes ahead', () {
      fakeAsync((FakeAsync async) {
        final List<String> drawn = <String>[];
        bool fail = true;
        final LiveNotationPainter painter = LiveNotationPainter((String svg) {
          if (fail) throw StateError('no');
          drawn.add(svg);
        });
        painter.add('$_root$_line');
        fail = false;
        painter.add('$_root$_line$_line');
        async.elapse(const Duration(milliseconds: 120));
        expect(drawn, <String>['$_root$_line$_line</svg>']);
      });
    });

    test('draws nothing once closed', () {
      fakeAsync((FakeAsync async) {
        final List<String> drawn = <String>[];
        final LiveNotationPainter painter = LiveNotationPainter(drawn.add);
        painter.add('$_root$_line');
        painter.add('$_root$_line$_line');
        painter.close();
        painter.add('$_root$_line$_line$_line');
        async.elapse(const Duration(seconds: 1));
        expect(drawn, hasLength(1));
      });
    });
  });
}
