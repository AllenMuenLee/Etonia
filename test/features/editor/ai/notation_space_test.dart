import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/ai/notation_space.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/streaming_ai_client.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

SpaceStroke _line(double x0, double y0, double x1, double y1) {
  return (points: <InkVector>[InkVector(x0, y0), InkVector(x1, y1)], width: 2);
}

double _area(Rect rect) => rect.width * rect.height;

bool _overlaps(Rect a, Rect b) {
  final Rect overlap = a.intersect(b);
  return overlap.width > 0 && overlap.height > 0;
}

void main() {
  const AiSpaceConfig config = AiSpaceConfig();

  test('a blank page has room, clear of the edge margin', () {
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(480, 640),
    );

    expect(space.hasRoom, isTrue);
    final Rect bounds = space.areas.first.bounds;
    expect(bounds, const Rect.fromLTRB(16, 16, 464, 624));
  });

  test('no area reaches within the clearance of ink', () {
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(480, 640),
      strokes: <SpaceStroke>[
        _line(100, 100, 300, 100),
        _line(100, 100, 100, 300),
      ],
      focus: const Rect.fromLTRB(90, 90, 310, 310),
    );

    expect(space.areas, isNotEmpty);
    expect(space.areas.length, lessThanOrEqualTo(config.maxAreas));
    for (final FreeArea area in space.areas) {
      for (final Rect part in area.parts) {
        expect(
          _overlaps(part, const Rect.fromLTRB(99, 99, 301, 101).inflate(12)),
          isFalse,
        );
        expect(
          _overlaps(part, const Rect.fromLTRB(99, 99, 101, 301).inflate(12)),
          isFalse,
        );
        expect(part.width, greaterThanOrEqualTo(config.minHeight));
        expect(part.height, greaterThanOrEqualTo(config.minHeight));
      }
    }
    // The areas never overlap one another.
    final List<Rect> parts = <Rect>[
      for (final FreeArea area in space.areas) ...area.parts,
    ];
    for (int i = 0; i < parts.length; i++) {
      for (int j = i + 1; j < parts.length; j++) {
        expect(_overlaps(parts[i], parts[j]), isFalse);
      }
    }
  });

  test('blank paper wrapping round a corner is offered as one L', () {
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(480, 480),
      blocks: const <Rect>[Rect.fromLTRB(0, 0, 240, 240)],
    );

    final FreeArea area = space.areas.first;
    expect(area.isL, isTrue);
    expect(area.bounds, const Rect.fromLTRB(16, 16, 464, 464));
    // A 200-wide strip down the right and one across the bottom, meeting.
    expect(_area(area.parts[0]) + _area(area.parts[1]), 200 * 448 + 248 * 200);
    for (final Rect part in area.parts) {
      expect(_overlaps(part, const Rect.fromLTRB(0, 0, 252, 252)), isFalse);
    }
  });

  test('what is near the selection is boxed, nearest first; what is far, '
      'or wholly selected, is not', () {
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(800, 1000),
      strokes: <SpaceStroke>[
        // The selected word.
        _line(100, 100, 200, 100),
        // A line of writing just below it, and one a little further.
        _line(100, 160, 300, 160),
        _line(100, 260, 300, 260),
        // Far down the page.
        _line(100, 900, 300, 900),
      ],
      blocks: const <Rect>[Rect.fromLTRB(400, 80, 500, 180)],
      focus: const Rect.fromLTRB(88, 88, 212, 112),
    );

    expect(space.nearby, hasLength(3));
    // The writing 48 below, the next line 148 below, the picture 188 off.
    expect(space.nearby[0].top, closeTo(159, 8));
    expect(space.nearby[1].top, closeTo(259, 8));
    expect(space.nearby[2].left, closeTo(400, 8));
    for (final Rect box in space.nearby) {
      expect(box.top, lessThan(900));
    }
  });

  group('the assistant never writes over its own notes', () {
    /// One trace of text-like ink filling [box].
    GeneratedInkTrace ink(Rect box) => GeneratedInkTrace(
      style: const StrokeStyle(ink: InkPalette.ink, width: 2),
      points: <InkVector>[
        InkVector(box.left + 1, box.top + 1),
        InkVector(box.right - 1, box.bottom - 1),
        InkVector(box.left + 1, box.bottom - 1),
      ],
    );

    Rect boundsOf(List<GeneratedInkTrace> traces) {
      Rect? out;
      for (final GeneratedInkTrace t in traces) {
        for (final InkVector p in t.points) {
          final Rect r = Rect.fromCircle(center: Offset(p.x, p.y), radius: 1);
          out = out == null ? r : out.expandToInclude(r);
        }
      }
      return out!;
    }

    // An earlier note: a label written along y 100 to 130.
    final List<SpaceStroke> earlier = <SpaceStroke>[
      _line(200, 100, 320, 100),
      _line(200, 130, 320, 130),
      _line(200, 100, 200, 130),
    ];

    test('text clear of earlier notes stays where it is', () {
      final NotationClearance clearance = NotationClearance(
        pageSize: const Size(600, 800),
        earlierNotes: earlier,
      );
      final List<GeneratedInkTrace> text = <GeneratedInkTrace>[
        ink(const Rect.fromLTRB(200, 300, 320, 330)),
      ];
      expect(identical(clearance.place(text), text), isTrue);
    });

    test('text on an earlier note is moved the shortest way clear', () {
      final NotationClearance clearance = NotationClearance(
        pageSize: const Size(600, 800),
        earlierNotes: earlier,
      );
      final Rect moved = boundsOf(
        clearance.place(<GeneratedInkTrace>[
          ink(const Rect.fromLTRB(210, 105, 310, 125)),
        ]),
      );
      expect(moved.overlaps(const Rect.fromLTRB(199, 99, 321, 131)), isFalse);
      // Just clear, not across the page.
      expect(
        (moved.center - const Rect.fromLTRB(210, 105, 310, 125).center)
            .distance,
        lessThan(60),
      );
    });

    test('later text in one notation keeps off earlier text in it', () {
      final NotationClearance clearance = NotationClearance(
        pageSize: const Size(600, 800),
      );
      const Rect spot = Rect.fromLTRB(100, 400, 220, 430);
      final Rect first = boundsOf(
        clearance.place(<GeneratedInkTrace>[ink(spot)]),
      );
      final Rect second = boundsOf(
        clearance.place(<GeneratedInkTrace>[ink(spot)]),
      );
      expect(first, boundsOf(<GeneratedInkTrace>[ink(spot)]));
      expect(second.overlaps(first), isFalse);
    });

    test('in layout, only text is moved: lines may touch notes', () {
      final AiNotation notation = AiNotation(
        label: 'Again',
        items: <AiNotationItem>[
          const AiNotationText(
            text: 'c = 5',
            x: 210 / 600,
            y: 102 / 800,
            size: 20,
            ink: 'red',
            width: 2,
          ),
          const AiNotationLine(
            from: AiNotationPoint(210 / 600, 115 / 800),
            to: AiNotationPoint(310 / 600, 115 / 800),
            lineStyle: AiLineStyle.solid,
            arrow: AiArrow.none,
            ink: 'red',
            width: 2,
          ),
        ],
      );
      final List<GeneratedInkTrace> plain = layoutNotation(
        notation,
        const Size(600, 800),
      );
      final List<GeneratedInkTrace> kept = layoutNotation(
        notation,
        const Size(600, 800),
        clearance: NotationClearance(
          pageSize: const Size(600, 800),
          earlierNotes: earlier,
        ),
      );
      expect(kept.length, plain.length);
      // The line, last, is where it was; the text is not.
      expect(kept.last.points, plain.last.points);
      expect(
        boundsOf(
          kept.sublist(0, kept.length - 1),
        ).overlaps(const Rect.fromLTRB(199, 99, 321, 131)),
        isFalse,
      );
    });

    test('the model is told where its notes are', () {
      final NoteFreeSpace space = NoteFreeSpace.measure(
        pageSize: const Size(600, 800),
        strokes: earlier,
        aiNotes: earlier,
        focus: const Rect.fromLTRB(150, 150, 400, 300),
      );
      expect(space.yourNotes, hasLength(1));
      expect(space.yourNotes.single.top, closeTo(99, 8));
      final String text = aiNoteMetadata(
        NoteImage(logicalSize: const Size(600, 800), revision: 0, space: space),
      );
      expect(text, contains('"your_notes":[['));
      expect(text, contains('Never write or draw over'));
    });
  });

  test('the area nearest the selection comes first', () {
    // A line across the middle leaves two equal halves.
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(480, 640),
      strokes: <SpaceStroke>[_line(0, 320, 480, 320)],
      focus: const Rect.fromLTRB(200, 500, 260, 540),
    );

    expect(space.areas.length, greaterThanOrEqualTo(2));
    expect(space.areas.first.bounds.top, greaterThan(320));
  });

  test('print on a page-wide background is not blank', () {
    const int side = 400;
    final Uint8List rgba = Uint8List(side * side * 4)
      ..fillRange(0, side * side * 4, 255);
    for (int y = 100; y < 300; y++) {
      for (int x = 100; x < 300; x++) {
        final int i = (y * side + x) * 4;
        rgba[i] = 0;
        rgba[i + 1] = 0;
        rgba[i + 2] = 0;
      }
    }
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(400, 400),
      backgrounds: <SpaceBackground>[
        SpaceBackground(
          bounds: const Rect.fromLTWH(0, 0, 400, 400),
          width: side,
          height: side,
          rgba: rgba,
        ),
      ],
    );

    expect(space.hasRoom, isTrue);
    for (final FreeArea area in space.areas) {
      for (final Rect part in area.parts) {
        expect(
          _overlaps(part, const Rect.fromLTRB(100, 100, 300, 300).inflate(12)),
          isFalse,
        );
      }
    }
  });

  group('a packed page', () {
    // Hatching every 40 units leaves no box 120 by 60.
    final List<SpaceStroke> hatching = <SpaceStroke>[
      for (double y = 20; y < 600; y += 40) _line(0, y, 600, y),
    ];

    test('has no room', () {
      final NoteFreeSpace space = NoteFreeSpace.measure(
        pageSize: const Size(600, 600),
        strokes: hatching,
      );
      expect(space.hasRoom, isFalse);
      expect(space.areas, isEmpty);
    });

    test('takes a sticky note beside the selection, not on it', () {
      const Rect focus = Rect.fromLTRB(250, 250, 350, 350);
      final NoteFreeSpace space = NoteFreeSpace.measure(
        pageSize: const Size(600, 600),
        strokes: hatching,
        focus: focus,
      );

      final Rect placed = space.placeSticky(const Size(200, 150));
      expect(placed.size, const Size(200, 150));
      expect(_overlaps(placed, focus), isFalse);
      expect(placed.left, greaterThanOrEqualTo(16));
      expect(placed.top, greaterThanOrEqualTo(16));
      expect(placed.right, lessThanOrEqualTo(584));
      expect(placed.bottom, lessThanOrEqualTo(584));
      // Right beside it, not off in a corner.
      final double gap = <double>[
        focus.left - placed.right,
        placed.left - focus.right,
        focus.top - placed.bottom,
        placed.top - focus.bottom,
      ].reduce((double a, double b) => a > b ? a : b);
      expect(gap, lessThan(16));
    });
  });

  group('the model is told', () {
    NoteImage note(NoteFreeSpace space) =>
        NoteImage(logicalSize: const Size(480, 480), revision: 0, space: space);

    test('each free area and its size, and when to use a sticky note', () {
      final String text = aiNoteMetadata(
        note(
          NoteFreeSpace.measure(
            pageSize: const Size(480, 480),
            blocks: const <Rect>[Rect.fromLTRB(0, 0, 240, 240)],
          ),
        ),
      );

      expect(text, contains('Area 1 is an L: '));
      expect(text, contains('units)'));
      expect(text, contains('"free_areas":[{"shape":"L","parts":[{'));
      expect(text, contains('"width_units":'));
      expect(text, contains('sticky_normalized'));
      expect(text, isNot(contains('You may draw anywhere')));
    });

    test('to use a sticky note when there is no room', () {
      final String text = aiNoteMetadata(
        note(
          NoteFreeSpace.measure(
            pageSize: const Size(480, 480),
            blocks: const <Rect>[Rect.fromLTRB(0, 0, 480, 480)],
          ),
        ),
      );

      expect(text, contains('no blank area'));
      expect(text, contains('sticky_normalized'));
      expect(text, isNot(contains('free_areas')));
    });
  });

  test('a sticky note too big for the page shrinks, keeping its shape', () {
    final NoteFreeSpace space = NoteFreeSpace.measure(
      pageSize: const Size(300, 200),
    );

    final Rect placed = space.placeSticky(const Size(640, 480));
    expect(placed.left, greaterThanOrEqualTo(16));
    expect(placed.top, greaterThanOrEqualTo(16));
    expect(placed.right, lessThanOrEqualTo(284 + 1e-9));
    expect(placed.bottom, lessThanOrEqualTo(184 + 1e-9));
    expect(placed.width / placed.height, closeTo(640 / 480, 1e-9));
  });
}
