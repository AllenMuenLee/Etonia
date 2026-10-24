import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Brightness, CustomPainter;
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/notation_playback.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

final StrokeStyle _blue = StrokeStyle(ink: InkPalette.byId('blue')!, width: 3);
const Size _surface = Size(400, 300);

GeneratedInkTrace _timed(List<InkVector> points, List<double> times) {
  return GeneratedInkTrace(style: _blue, points: points, timesMs: times);
}

/// A line drawn from 0 to 100 ms, and a dot at 150 ms.
List<GeneratedInkTrace> _notation() {
  return <GeneratedInkTrace>[
    _timed(
      const <InkVector>[InkVector(20, 20), InkVector(120, 20)],
      <double>[0, 100],
    ),
    _timed(const <InkVector>[InkVector(200, 50)], <double>[150]),
  ];
}

Stroke _existing() => Stroke.fromPoints(
  style: const StrokeStyle(ink: InkPalette.ink, width: 4),
  points: const <InkVector>[InkVector(10, 200), InkVector(100, 200)],
);

/// Counts every notification [controller] sends.
class _Counts {
  _Counts(InkController controller) {
    controller.completedStrokesListenable.addListener(() => completed++);
    controller.documentRevisionListenable.addListener(() => revisions++);
    controller.selectionListenable.addListener(() => selection++);
    controller.notationPlaybackListenable.addListener(() => ownership++);
    controller.notationFrameListenable.addListener(() => frames++);
  }

  int completed = 0;
  int revisions = 0;
  int selection = 0;
  int ownership = 0;
  int frames = 0;
}

InkController _animated({
  List<Stroke> existing = const <Stroke>[],
  Duration duration = const Duration(milliseconds: 250),
}) {
  final InkController controller = InkController(strokes: existing);
  addTearDown(controller.dispose);
  expect(
    controller.addAiNotation(
      traces: _notation(),
      expectedRevision: 0,
      surfaceSize: _surface,
      playbackDuration: duration,
    ),
    AddNotationResult.addedWithPlayback,
  );
  return controller;
}

Future<Uint8List> _paint(CustomPainter painter) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  painter.paint(canvas, _surface);
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    _surface.width.toInt(),
    _surface.height.toInt(),
  );
  final ByteData data = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!;
  image.dispose();
  picture.dispose();
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void main() {
  group('revealTrace', () {
    const List<InkVector> line = <InkVector>[
      InkVector(0, 0),
      InkVector(100, 0),
      InkVector(100, 50),
    ];
    const List<double> times = <double>[100, 300, 400];

    test('shows nothing before the trace starts', () {
      expect(revealTrace(line, times, 0), TraceReveal.hidden);
      expect(revealTrace(line, times, 99.999), TraceReveal.hidden);
    });

    test('interpolates each segment at its start, midpoint, and end', () {
      final TraceReveal start = revealTrace(line, times, 100);
      expect(start.state, TraceRevealState.partial);
      expect(start.reached, 0);
      expect(start.tip, const InkVector(0, 0));

      final TraceReveal middle = revealTrace(line, times, 200);
      expect(middle.reached, 0);
      expect(middle.tip, const InkVector(50, 0));

      // The end of one segment is the start of the next.
      final TraceReveal corner = revealTrace(line, times, 300);
      expect(corner.reached, 1);
      expect(corner.tip, const InkVector(100, 0));

      final TraceReveal second = revealTrace(line, times, 350);
      expect(second.reached, 1);
      expect(second.tip, const InkVector(100, 25));
    });

    test('is complete from the last time on', () {
      expect(revealTrace(line, times, 400), TraceReveal.complete);
      expect(revealTrace(line, times, 1e9), TraceReveal.complete);
    });

    test('a dot appears exactly at its time', () {
      const List<InkVector> dot = <InkVector>[InkVector(5, 5)];
      expect(revealTrace(dot, <double>[250], 249.9), TraceReveal.hidden);
      expect(revealTrace(dot, <double>[250], 250), TraceReveal.complete);
    });

    test('points reached at the same moment are passed together', () {
      final TraceReveal reveal = revealTrace(
        const <InkVector>[
          InkVector(0, 0),
          InkVector(10, 0),
          InkVector(20, 0),
          InkVector(30, 0),
        ],
        <double>[0, 100, 100, 200],
        100,
      );
      expect(reveal.reached, 2);
      expect(reveal.tip, const InkVector(20, 0));
    });
  });

  group('addAiNotation with a playback', () {
    test('commits once, with the playback in place before anyone hears', () {
      final InkController controller = InkController(
        strokes: <Stroke>[_existing()],
      );
      addTearDown(controller.dispose);
      final _Counts counts = _Counts(controller);
      NotationPlayback? playbackWhenNotified;
      controller.completedStrokesListenable.addListener(() {
        playbackWhenNotified = controller.notationPlayback;
      });

      final AddNotationResult result = controller.addAiNotation(
        traces: _notation(),
        expectedRevision: 0,
        surfaceSize: _surface,
        playbackDuration: const Duration(milliseconds: 250),
      );

      expect(result, AddNotationResult.addedWithPlayback);
      expect(controller.strokes, hasLength(3));
      expect(controller.documentRevision, 1);
      expect(counts.completed, 1);
      expect(counts.revisions, 1);
      expect(counts.ownership, 1);
      expect(counts.frames, 0);
      final NotationPlayback playback = controller.notationPlayback!;
      expect(playbackWhenNotified, same(playback));
      // It refers to the very strokes added, in order, and hides only them.
      expect(playback.strokes[0], same(controller.strokes[1]));
      expect(playback.strokes[1], same(controller.strokes[2]));
      expect(playback.owns(controller.strokes[0]), isFalse);
      expect(playback.owns(controller.strokes[1]), isTrue);
      expect(playback.owns(controller.strokes[2]), isTrue);
      expect(playback.duration, const Duration(milliseconds: 250));
      expect(playback.surfaceSize, _surface);
      expect(playback.revealAt(0).state, TraceRevealState.partial);
      expect(playback.revealAt(1), TraceReveal.hidden);
    });

    test('a stroke with the same points is not hidden: identity counts', () {
      final InkController controller = _animated();
      final Stroke twin = Stroke.fromPoints(
        style: _blue,
        points: controller.strokes[0].points,
      );
      expect(controller.notationPlayback!.owns(controller.strokes[0]), isTrue);
      expect(controller.notationPlayback!.owns(twin), isFalse);
    });

    test('frames, skipping, and finishing never touch the document', () {
      final InkController controller = _animated(
        existing: <Stroke>[_existing()],
      );
      final List<Stroke> strokes = controller.strokes.toList();
      final _Counts counts = _Counts(controller);
      final NotationPlayback playback = controller.notationPlayback!;

      controller.advanceNotationPlayback(const Duration(milliseconds: 50));
      controller.advanceNotationPlayback(const Duration(milliseconds: 120));
      expect(counts.frames, 2);
      expect(playback.revealAt(0), TraceReveal.complete);
      expect(playback.revealAt(1), TraceReveal.hidden);

      // Time never goes back.
      controller.advanceNotationPlayback(const Duration(milliseconds: 60));
      expect(playback.elapsed, const Duration(milliseconds: 120));
      expect(counts.frames, 2);

      // Reaching the duration wraps to the first frame and keeps ownership.
      controller.advanceNotationPlayback(const Duration(milliseconds: 250));
      expect(controller.notationPlayback, same(playback));
      expect(playback.elapsed, Duration.zero);
      expect(playback.isFinished, isFalse);
      expect(playback.owns(strokes[1]), isTrue);
      expect(counts.frames, 3);
      expect(counts.ownership, 0);

      controller.advanceNotationPlayback(const Duration(milliseconds: 300));
      expect(playback.elapsed, const Duration(milliseconds: 50));
      expect(playback.revealAt(0).tip, const InkVector(70, 20));
      expect(playback.revealAt(1), TraceReveal.hidden);

      // Large jumps resolve to the same phase, independent of frame count.
      controller.advanceNotationPlayback(const Duration(seconds: 5));
      expect(playback.elapsed, Duration.zero);
      expect(counts.frames, 5);
      expect(controller.finishNotationPlayback(), isTrue);
      expect(controller.finishNotationPlayback(), isFalse);
      expect(counts.ownership, 1);

      expect(controller.strokes, orderedEquals(strokes));
      expect(controller.documentRevision, 1);
      expect(counts.completed, 0);
      expect(counts.revisions, 0);
      expect(counts.selection, 0);
    });

    test('a forced finish shows everything at once, once', () async {
      final InkController controller = _animated();
      final _Counts counts = _Counts(controller);
      final NotationPlayback playback = controller.notationPlayback!;
      bool done = false;
      unawaited(playback.done.then((void _) => done = true));

      expect(controller.finishNotationPlayback(), isTrue);
      expect(controller.finishNotationPlayback(), isFalse);
      await Future<void>.delayed(Duration.zero);

      expect(done, isTrue);
      expect(counts.ownership, 1);
      expect(counts.completed, 0);
      expect(counts.revisions, 0);
      expect(controller.documentRevision, 1);
    });

    test('the final animated frame is pixel-identical to normal ink', () async {
      final InkController controller = _animated();
      // The last point has arrived, but the duration's final hold has not,
      // so the animation layer still owns and paints the complete strokes.
      controller.advanceNotationPlayback(const Duration(milliseconds: 150));
      final Uint8List animated = await _paint(
        NotationPlaybackPainter(
          controller: controller,
          brightness: Brightness.light,
        ),
      );

      expect(controller.finishNotationPlayback(), isTrue);
      final Uint8List normal = await _paint(
        CompletedStrokesPainter(
          controller: controller,
          brightness: Brightness.light,
        ),
      );

      expect(animated, orderedEquals(normal));
    });

    test('elapsed time, not frame count, decides what shows', () {
      // 60, 90, and 120 Hz, a stalled frame, and one big jump all land on
      // the same moment, and show the same thing there.
      final List<List<double>> schedules = <List<double>>[
        <double>[for (int i = 1; i <= 6; i++) i * 1000 / 60],
        <double>[for (int i = 1; i <= 9; i++) i * 1000 / 90],
        <double>[for (int i = 1; i <= 12; i++) i * 1000 / 120],
        <double>[16.7, 16.7, 16.7, 100],
        <double>[100],
      ];
      final List<TraceReveal> results = <TraceReveal>[];
      for (final List<double> schedule in schedules) {
        final InkController controller = _animated();
        for (final double ms in schedule) {
          controller.advanceNotationPlayback(
            Duration(microseconds: (ms * 1000).round()),
          );
        }
        results.add(controller.notationPlayback!.revealAt(0));
      }
      expect(results.toSet(), hasLength(1));
      expect(results.first, TraceReveal.complete);
    });

    test('without a duration, the times are ignored and nothing plays', () {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      final _Counts counts = _Counts(controller);
      expect(
        controller.addAiNotation(
          traces: _notation(),
          expectedRevision: 0,
          surfaceSize: _surface,
        ),
        AddNotationResult.added,
      );
      expect(controller.notationPlayback, isNull);
      expect(counts.ownership, 0);
    });

    test('bad timing rejects it whole, adds nothing, and plays nothing', () {
      for (final (String reason, List<GeneratedInkTrace> traces, Duration d)
          in <(String, List<GeneratedInkTrace>, Duration)>[
            (
              'missing times',
              <GeneratedInkTrace>[
                _notation().first,
                GeneratedInkTrace(
                  style: _blue,
                  points: const <InkVector>[InkVector(5, 5)],
                ),
              ],
              const Duration(milliseconds: 250),
            ),
            (
              'one time too few',
              <GeneratedInkTrace>[
                _timed(
                  const <InkVector>[InkVector(5, 5), InkVector(9, 9)],
                  <double>[0],
                ),
              ],
              const Duration(milliseconds: 250),
            ),
            (
              'going back',
              <GeneratedInkTrace>[
                _timed(
                  const <InkVector>[InkVector(5, 5), InkVector(9, 9)],
                  <double>[100, 50],
                ),
              ],
              const Duration(milliseconds: 250),
            ),
            (
              'negative',
              <GeneratedInkTrace>[
                _timed(const <InkVector>[InkVector(5, 5)], <double>[-1]),
              ],
              const Duration(milliseconds: 250),
            ),
            (
              'past the end',
              <GeneratedInkTrace>[
                _timed(const <InkVector>[InkVector(5, 5)], <double>[251]),
              ],
              const Duration(milliseconds: 250),
            ),
            (
              'not finite',
              <GeneratedInkTrace>[
                _timed(
                  const <InkVector>[InkVector(5, 5)],
                  <double>[double.nan],
                ),
              ],
              const Duration(milliseconds: 250),
            ),
            ('no duration', _notation(), Duration.zero),
            ('too long', _notation(), const Duration(milliseconds: 12001)),
          ]) {
        final InkController controller = InkController();
        addTearDown(controller.dispose);
        final _Counts counts = _Counts(controller);
        expect(
          controller.addAiNotation(
            traces: traces,
            expectedRevision: 0,
            surfaceSize: _surface,
            playbackDuration: d,
          ),
          AddNotationResult.invalid,
          reason: reason,
        );
        expect(controller.strokes, isEmpty, reason: reason);
        expect(controller.notationPlayback, isNull, reason: reason);
        expect(counts.completed + counts.revisions + counts.ownership, 0);
      }
    });

    test('stale, busy, and off-page notations start no playback', () {
      final InkController controller = _animated();
      final NotationPlayback first = controller.notationPlayback!;
      expect(
        controller.addAiNotation(
          traces: _notation(),
          expectedRevision: 0,
          surfaceSize: _surface,
          playbackDuration: const Duration(milliseconds: 250),
        ),
        AddNotationResult.stale,
      );
      expect(
        controller.addAiNotation(
          traces: <GeneratedInkTrace>[
            _timed(const <InkVector>[InkVector(399, 5)], <double>[0]),
          ],
          expectedRevision: 1,
          surfaceSize: _surface,
          playbackDuration: const Duration(milliseconds: 250),
        ),
        AddNotationResult.invalid,
      );
      // A rejected notation leaves the playing one alone.
      expect(controller.notationPlayback, same(first));

      controller.startStroke(
        pointer: 1,
        sample: const RawInkSample(
          position: InkVector(300, 250),
          timestamp: Duration.zero,
        ),
        style: _blue,
      );
      expect(
        controller.addAiNotation(
          traces: _notation(),
          expectedRevision: 1,
          surfaceSize: _surface,
          playbackDuration: const Duration(milliseconds: 250),
        ),
        AddNotationResult.busy,
      );
      expect(controller.strokes, hasLength(2));
    });

    test('a second notation plays alongside the first, from its start', () {
      final InkController controller = _animated();
      final NotationPlayback first = controller.notationPlayback!;
      controller.advanceNotationPlayback(const Duration(milliseconds: 120));
      final _Counts counts = _Counts(controller);

      expect(
        controller.addAiNotation(
          traces: _notation(),
          expectedRevision: 1,
          surfaceSize: _surface,
          playbackDuration: const Duration(milliseconds: 250),
        ),
        AddNotationResult.addedWithPlayback,
      );

      expect(first.isFinished, isFalse);
      final NotationPlayback second = controller.notationPlayback!;
      expect(second, isNot(same(first)));
      expect(controller.notationPlaybacks, <NotationPlayback>[first, second]);
      expect(first.owns(controller.strokes[0]), isTrue);
      expect(second.owns(controller.strokes[0]), isFalse);
      expect(second.owns(controller.strokes[2]), isTrue);
      expect(controller.strokes, hasLength(4));
      expect(controller.documentRevision, 2);
      expect(counts.completed, 1);
      expect(counts.revisions, 1);

      // One clock, but each is drawn from the moment it was added.
      controller.advanceNotationPlayback(const Duration(milliseconds: 170));
      expect(first.elapsed, const Duration(milliseconds: 170));
      expect(second.elapsed, const Duration(milliseconds: 50));
      controller.advanceNotationPlayback(const Duration(seconds: 10));
      expect(first.isFinished, isFalse);
      expect(second.isFinished, isFalse);
    });

    test('a still notation leaves a playing one alone', () {
      final InkController controller = _animated();
      final NotationPlayback first = controller.notationPlayback!;
      expect(
        controller.addAiNotation(
          traces: _notation(),
          expectedRevision: 1,
          surfaceSize: _surface,
        ),
        AddNotationResult.added,
      );
      expect(first.isFinished, isFalse);
      expect(controller.notationPlayback, same(first));
    });

    test(
      'done completes after the first full drawing; it keeps looping',
      () async {
        final InkController controller = _animated();
        final NotationPlayback playback = controller.notationPlayback!;
        bool done = false;
        unawaited(playback.done.then((void _) => done = true));

        controller.advanceNotationPlayback(const Duration(milliseconds: 200));
        await Future<void>.delayed(Duration.zero);
        expect(done, isFalse);

        controller.advanceNotationPlayback(const Duration(milliseconds: 260));
        await Future<void>.delayed(Duration.zero);
        expect(done, isTrue);
        expect(playback.isFinished, isFalse);
        expect(controller.notationPlayback, same(playback));
      },
    );

    test('finishing one playback leaves the others playing', () {
      final InkController controller = _animated();
      final NotationPlayback first = controller.notationPlayback!;
      controller.addAiNotation(
        traces: _notation(),
        expectedRevision: 1,
        surfaceSize: _surface,
        playbackDuration: const Duration(milliseconds: 250),
      );
      final NotationPlayback second = controller.notationPlayback!;

      expect(controller.finishNotationPlayback(first), isTrue);
      expect(controller.finishNotationPlayback(first), isFalse);
      expect(first.isFinished, isTrue);
      expect(controller.notationPlaybacks, <NotationPlayback>[second]);
    });

    group('working on the ink leaves it playing', () {
      void expectStillPlaying(void Function(InkController controller) act) {
        final InkController controller = _animated(
          existing: <Stroke>[_existing()],
        );
        final NotationPlayback playback = controller.notationPlayback!;
        act(controller);
        expect(playback.isFinished, isFalse);
        expect(controller.notationPlayback, same(playback));
      }

      test('writing, keeping the first sample', () {
        expectStillPlaying((InkController controller) {
          expect(
            controller.startStroke(
              pointer: 1,
              sample: const RawInkSample(
                position: InkVector(300, 250),
                timestamp: Duration.zero,
              ),
              style: _blue,
            ),
            isTrue,
          );
          expect(controller.activeStroke!.origin, const InkVector(300, 250));
        });
      });

      test('erasing lets go of what it erases, and nothing else', () {
        expectStillPlaying((InkController controller) {
          final Stroke line = controller.strokes[1];
          final Stroke dot = controller.strokes[2];
          controller.startErase(
            pointer: 1,
            position: const InkVector(200, 50),
            settings: const EraserSettings(mode: EraserMode.stroke, size: 20),
          );
          controller.endErase(1);
          expect(controller.strokes, hasLength(2));
          expect(controller.notationPlayback!.owns(line), isTrue);
          expect(controller.notationPlayback!.owns(dot), isFalse);
        });
      });

      test('erasing all of it finishes it', () {
        final InkController controller = _animated();
        final NotationPlayback playback = controller.notationPlayback!;
        for (final InkVector at in const <InkVector>[
          InkVector(200, 50),
          InkVector(70, 20),
        ]) {
          controller.startErase(
            pointer: 1,
            position: at,
            settings: const EraserSettings(mode: EraserMode.stroke, size: 20),
          );
          controller.endErase(1);
        }
        expect(controller.strokes, isEmpty);
        expect(playback.isFinished, isTrue);
        expect(controller.notationPlaybacks, isEmpty);
      });

      test('selecting, which can select the notation', () {
        expectStillPlaying((InkController controller) {
          controller
            ..beginSelectionGesture(pointer: 1, position: const InkVector(0, 0))
            ..endSelectionGesture(1, const InkVector(390, 100));
          expect(controller.selection!.count, 2);
        });
      });

      test('cutting and pasting other ink', () {
        expectStillPlaying((InkController controller) {
          controller
            ..beginLasso(pointer: 1, position: const InkVector(0, 180))
            ..endLasso(1, const InkVector(150, 220));
          expect(controller.cutSelection(), isTrue);
          expect(controller.strokes, hasLength(2));
          expect(controller.strokes.every(controller.isPlayingStroke), isTrue);
        });
        expectStillPlaying((InkController controller) {
          controller
            ..beginLasso(pointer: 1, position: const InkVector(0, 180))
            ..endLasso(1, const InkVector(150, 220))
            ..copySelection();
          expect(controller.paste(), isTrue);
          expect(controller.isPlayingStroke(controller.strokes.last), isFalse);
        });
      });

      test('a move carries the notation along, still playing', () {
        expectStillPlaying((InkController controller) {
          controller
            ..beginLasso(pointer: 1, position: const InkVector(0, 0))
            ..endLasso(1, const InkVector(390, 100));
          expect(controller.selection!.count, 2);
          final InkVector grab = controller.selection!.frame.center;
          controller
            ..beginTransform(
              pointer: 2,
              position: grab,
              hit: controller.selection!.frame.hitTest(
                grab,
                handleHitRadius: 1,
                rotationHandleOffset: 1,
                tolerance: 1e-6,
              )!,
            )
            ..endTransform(2, grab + const InkVector(10, 30));
          final Stroke moved = controller.strokes[1];
          expect(moved.points.first, const InkVector(30, 50));
          expect(controller.notationPlayback!.owns(moved), isTrue);
          expect(controller.notationPlayback!.strokes[0], same(moved));
        });
      });

      test('a replacement with a different point count keeps playing', () {
        final Stroke original = Stroke.fromPoints(
          style: _blue,
          points: const <InkVector>[InkVector(20, 20), InkVector(120, 20)],
        );
        final Stroke replacement = Stroke.fromPoints(
          style: _blue,
          points: const <InkVector>[
            InkVector(20, 20),
            InkVector(70, 10),
            InkVector(120, 20),
          ],
        );
        final NotationPlayback playback = NotationPlayback(
          <Stroke>[original],
          timesMs: <List<double>>[
            <double>[0, 100],
          ],
          duration: const Duration(milliseconds: 250),
          surfaceSize: _surface,
        );

        playback.replace(original, replacement);

        expect(playback.owns(replacement), isTrue);
        expect(playback.timesAt(0), <double>[0, 50, 100]);
      });
    });

    test('disposing ends the playback without notifying anyone', () async {
      final InkController controller = InkController();
      controller.addAiNotation(
        traces: _notation(),
        expectedRevision: 0,
        surfaceSize: _surface,
        playbackDuration: const Duration(milliseconds: 250),
      );
      final NotationPlayback playback = controller.notationPlayback!;
      controller.dispose();
      expect(playback.isFinished, isTrue);
      await expectLater(playback.done, completes);
      // Late frames after disposal are ignored.
      controller.advanceNotationPlayback(const Duration(milliseconds: 10));
      expect(controller.finishNotationPlayback(), isFalse);
    });
  });
}
