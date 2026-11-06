import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_painter.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';

import '../../helpers/pump_app.dart';

const MethodChannel _channel = MethodChannel('com.etonia.app/native_ink');

/// Frames after the release before the overlay may let go: the frame that
/// paints the strokes, and the three that see it to the display.
const int _handoffFrames = 4;

/// The editor, with its pen arriving as native packets, as on a device.
class _Rig {
  _Rig(this.tester, this.controller, this.messenger);

  final WidgetTester tester;
  final InkController controller;
  final TestDefaultBinaryMessenger messenger;
  final List<int> surfaces = <int>[];

  /// Each overlay call, in order, as `finish:<pointer>` or the method name.
  final List<String> overlay = <String>[];
  int _time = 0;

  List<String> get finished => overlay
      .where((String call) => call.startsWith('finish:'))
      .toList(growable: false);

  static Future<_Rig> pump(
    WidgetTester tester, {
    InkController? controller,
  }) async {
    final InkController ink = controller ?? InkController();
    addTearDown(ink.dispose);
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final _Rig rig = _Rig(tester, ink, messenger);
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      final Map<Object?, Object?>? args = call.arguments is Map
          ? call.arguments as Map<Object?, Object?>
          : null;
      switch (call.method) {
        case 'registerSurface':
          rig.surfaces.add(args!['surfaceId']! as int);
          return true;
        case 'finishPreview':
          rig.overlay.add('finish:${args!['pointer']}');
        case 'clearLivePreview':
          rig.overlay.add(call.method);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    await pumpApp(tester, home: EditorScreen(inkController: ink));
    await tester.pumpAndSettle();
    expect(rig.surfaces, isNotEmpty);
    return rig;
  }

  Future<void> packet(
    int pointer,
    String phase,
    double x,
    double y, {
    String kind = 'stylus',
  }) async {
    _time += 8000;
    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
        MethodCall('inkPacket', <String, Object?>{
          'surfaceId': surfaces.first,
          'pointer': pointer,
          'phase': phase,
          'kind': kind,
          'samples': <Object?>[x, y, _time, 0.5],
        }),
      ),
      (_) {},
    );
  }

  /// A line along [y], which native numbers [pointer].
  Future<void> write(
    int pointer, {
    double y = 300,
    double from = 300,
    double to = 380,
  }) async {
    await packet(pointer, 'down', from, y);
    await packet(pointer, 'move', (from + to) / 2, y);
    await packet(pointer, 'up', to, y);
  }

  Stroke get last => controller.strokes.last;

  /// Runs the frames of a handoff, checking that the overlay holds on until
  /// the very last and then lets go of exactly [pointers].
  Future<void> expectHandoff(List<int> pointers) async {
    final int before = finished.length;
    for (int frame = 1; frame < _handoffFrames; frame++) {
      await tester.pump();
      expect(
        finished.length,
        before,
        reason: 'the overlay let go on frame $frame of $_handoffFrames',
      );
    }
    await tester.pump();
    expect(finished.skip(before), <String>[
      for (final int pointer in pointers) 'finish:$pointer',
    ]);
  }
}

void main() {
  testWidgets('a finished stroke stays native until the pen rests', (
    WidgetTester tester,
  ) async {
    final _Rig rig = await _Rig.pump(tester);
    int inkChanges = 0;
    int repaints = 0;
    rig.controller.completedStrokesListenable.addListener(() => inkChanges++);
    rig.controller.completedPaintListenable.addListener(() => repaints++);

    await rig.write(1);

    // In the document at once, with nothing for Flutter to repaint.
    expect(rig.controller.strokes, hasLength(1));
    expect(rig.controller.canUndo, isTrue);
    expect(inkChanges, 1);
    expect(repaints, 0);
    expect(rig.controller.isStrokeNativeHeld(rig.last), isTrue);

    await tester.pump(const Duration(milliseconds: 399));
    expect(rig.controller.isStrokeNativeHeld(rig.last), isTrue);
    expect(rig.finished, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    // Timer and first frame both fell in that pump.
    expect(rig.controller.isStrokeNativeHeld(rig.last), isFalse);
    expect(repaints, 1);
    expect(rig.finished, isEmpty);
    for (int frame = 2; frame < _handoffFrames; frame++) {
      await tester.pump();
      expect(rig.finished, isEmpty);
    }
    await tester.pump();
    expect(rig.finished, <String>['finish:1']);
  });

  testWidgets('writing on keeps every earlier stroke on the overlay', (
    WidgetTester tester,
  ) async {
    final _Rig rig = await _Rig.pump(tester);
    int repaints = 0;
    rig.controller.completedPaintListenable.addListener(() => repaints++);

    await rig.write(1, y: 300);
    await tester.pump(const Duration(milliseconds: 200));
    await rig.write(2, y: 320);
    await tester.pump(const Duration(milliseconds: 200));
    await rig.write(3, y: 340);

    // The pen down of a new stroke used to wipe the one before.
    expect(rig.overlay, isEmpty);
    expect(repaints, 0);
    expect(rig.controller.strokes, hasLength(3));
    expect(
      rig.controller.strokes.every(rig.controller.isStrokeNativeHeld),
      isTrue,
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(
      rig.controller.strokes.any(rig.controller.isStrokeNativeHeld),
      isFalse,
    );
    for (int frame = 2; frame <= _handoffFrames; frame++) {
      await tester.pump();
    }
    expect(rig.finished, <String>['finish:1', 'finish:2', 'finish:3']);
  });

  testWidgets('Flutter paints a held stroke only once it is released', (
    WidgetTester tester,
  ) async {
    final _Rig rig = await _Rig.pump(tester);
    final CompletedStrokesPainter painter = CompletedStrokesPainter(
      controller: rig.controller,
      brightness: Brightness.light,
    );
    void paint(Canvas canvas) => painter.paint(canvas, const Size(1000, 1000));

    await rig.write(1);
    expect(paint, paintsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    expect(paint, isNot(paintsNothing));
    for (int frame = 2; frame <= _handoffFrames; frame++) {
      await tester.pump();
    }
    expect(rig.finished, <String>['finish:1']);
  });

  testWidgets('a stroke in progress holds off the rest', (
    WidgetTester tester,
  ) async {
    final _Rig rig = await _Rig.pump(tester);
    await rig.write(1);
    final Stroke first = rig.last;

    await tester.pump(const Duration(milliseconds: 300));
    await rig.packet(2, 'down', 300, 320);
    await tester.pump(const Duration(milliseconds: 500));

    expect(rig.controller.isStrokeNativeHeld(first), isTrue);
    expect(rig.finished, isEmpty);

    await rig.packet(2, 'up', 380, 320);
    await tester.pump(const Duration(milliseconds: 400));
    expect(rig.controller.isStrokeNativeHeld(first), isFalse);
    for (int frame = 2; frame <= _handoffFrames; frame++) {
      await tester.pump();
    }
    expect(rig.finished, <String>['finish:1', 'finish:2']);
  });

  testWidgets('a long run of strokes is handed over without waiting', (
    WidgetTester tester,
  ) async {
    final _Rig rig = await _Rig.pump(tester);
    for (int i = 1; i <= 64; i++) {
      await rig.write(i, y: 200 + i * 3.0);
    }
    expect(
      rig.controller.strokes.any(rig.controller.isStrokeNativeHeld),
      isFalse,
    );
    await rig.expectHandoff(<int>[for (int i = 1; i <= 64; i++) i]);
  });

  group('undo and redo', () {
    testWidgets('undo takes back a held stroke, and redo restores it', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1, y: 300);
      await rig.write(2, y: 320);
      final Stroke first = rig.controller.strokes[0];
      final Stroke second = rig.controller.strokes[1];

      expect(rig.controller.undo(), isTrue);

      expect(rig.controller.strokes, <Stroke>[first]);
      expect(rig.controller.isStrokeNativeHeld(first), isFalse);
      // The stroke kept is painted before the overlay lets go of it.
      expect(rig.finished, isEmpty);
      await rig.expectHandoff(<int>[1, 2]);

      expect(rig.controller.redo(), isTrue);
      expect(rig.controller.strokes, <Stroke>[first, second]);
      expect(rig.controller.isStrokeNativeHeld(second), isFalse);

      expect(rig.controller.undo(), isTrue);
      expect(rig.controller.undo(), isTrue);
      expect(rig.controller.strokes, isEmpty);
      expect(rig.controller.undo(), isFalse);
      expect(rig.controller.redo(), isTrue);
      expect(rig.controller.redo(), isTrue);
      expect(rig.controller.strokes, <Stroke>[first, second]);
      expect(rig.controller.redo(), isFalse);

      await tester.pump(const Duration(seconds: 1));
      expect(rig.finished, hasLength(2));
    });

    testWidgets('each stroke of a held run is one step of history', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      for (int i = 1; i <= 3; i++) {
        await rig.write(i, y: 280 + i * 20.0);
      }
      for (int left = 2; left >= 0; left--) {
        expect(rig.controller.undo(), isTrue);
        expect(rig.controller.strokes, hasLength(left));
      }
    });

    testWidgets('writing right after undo holds only the new stroke', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1);
      expect(rig.controller.undo(), isTrue);
      await rig.write(2, y: 320);
      expect(rig.controller.strokes, hasLength(1));
      expect(rig.controller.isStrokeNativeHeld(rig.last), isTrue);

      // The undone stroke's handoff lets go of that stroke alone.
      await rig.expectHandoff(<int>[1]);
      expect(rig.controller.isStrokeNativeHeld(rig.last), isTrue);
    });
  });

  group('other tools', () {
    testWidgets('choosing another tool hands the strokes over in order', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1);
      final Stroke stroke = rig.last;
      final ValueNotifier<EditorTool> tool =
          tester.widget<InkCanvas>(find.byType(InkCanvas).first).tool
              as ValueNotifier<EditorTool>;

      tool.value = EditorTool.select;

      expect(rig.controller.isStrokeNativeHeld(stroke), isFalse);
      // Never taken off the overlay before Flutter has drawn it.
      expect(rig.overlay, isEmpty);
      await rig.expectHandoff(<int>[1]);
      expect(rig.controller.strokes, <Stroke>[stroke]);
    });

    testWidgets('the eraser end of the pen hands the strokes over in order', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1, y: 300);
      await rig.write(2, y: 360);

      await rig.packet(9, 'down', 340, 300, kind: 'invertedStylus');
      await rig.packet(9, 'move', 340, 300, kind: 'invertedStylus');
      await rig.packet(9, 'up', 340, 300, kind: 'invertedStylus');

      // The erased stroke changed in the document, so Flutter has them all.
      expect(
        rig.controller.strokes.any(rig.controller.isStrokeNativeHeld),
        isFalse,
      );
      expect(rig.finished, isNot(contains('finish:1')));
      for (int frame = 1; frame <= _handoffFrames; frame++) {
        await tester.pump();
      }
      expect(rig.finished, containsAll(<String>['finish:1', 'finish:2']));
      expect(rig.controller.undo(), isTrue);
      expect(rig.controller.strokes, hasLength(2));
    });

    testWidgets('a finger anywhere hands the strokes over before it moves', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1);
      final Stroke stroke = rig.last;

      final TestGesture finger = await tester.startGesture(
        const Offset(20, 20),
        kind: PointerDeviceKind.touch,
      );

      expect(rig.controller.isStrokeNativeHeld(stroke), isFalse);
      expect(rig.overlay, isEmpty);
      await rig.expectHandoff(<int>[1]);
      await finger.up();
    });

    testWidgets('the pen on anything but the page hands the strokes over', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1);
      final Stroke stroke = rig.last;
      final Rect page = tester.getRect(find.byType(InkCanvas).first);

      final TestGesture pen = await tester.startGesture(
        page.bottomRight + const Offset(40, 40),
        kind: PointerDeviceKind.stylus,
      );
      await tester.pump();
      await pen.up();

      expect(rig.controller.isStrokeNativeHeld(stroke), isFalse);
    });

    testWidgets('the pen on the page keeps writing natively', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1);
      final Stroke stroke = rig.last;
      final Rect page = tester.getRect(find.byType(InkCanvas).first);

      final TestGesture pen = await tester.startGesture(
        page.center,
        kind: PointerDeviceKind.stylus,
      );
      await pen.up();

      expect(rig.controller.isStrokeNativeHeld(stroke), isTrue);
    });
  });

  group('strokes Flutter must draw at once', () {
    testWidgets('a stroke touching a sticky note, which lies above ink', (
      WidgetTester tester,
    ) async {
      final InkController controller = InkController(
        stickyNotes: <StickyNoteElement>[
          StickyNoteElement(
            id: 'n',
            center: const InkVector(500, 500),
            size: const Size(120, 120),
            colorId: 'yellow',
          ),
        ],
      );
      final _Rig rig = await _Rig.pump(tester, controller: controller);

      await rig.write(1, y: 500, from: 380, to: 450);

      expect(rig.controller.strokes, hasLength(1));
      expect(rig.controller.isStrokeNativeHeld(rig.last), isFalse);
      await rig.expectHandoff(<int>[1]);
    });

    testWidgets('a stroke off the edge of the page, which Flutter clips', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);

      await rig.write(1, y: 300, from: 40, to: -30);

      expect(rig.controller.isStrokeNativeHeld(rig.last), isFalse);
      await rig.expectHandoff(<int>[1]);
    });

    testWidgets('such a stroke takes the held ones along', (
      WidgetTester tester,
    ) async {
      final _Rig rig = await _Rig.pump(tester);
      await rig.write(1, y: 300);
      await rig.write(2, y: 340, from: 40, to: -30);

      expect(
        rig.controller.strokes.any(rig.controller.isStrokeNativeHeld),
        isFalse,
      );
      await rig.expectHandoff(<int>[1, 2]);
    });
  });

  testWidgets('a stroke cancelled before it commits is simply dropped', (
    WidgetTester tester,
  ) async {
    final _Rig rig = await _Rig.pump(tester);
    await rig.packet(1, 'down', 300, 300);
    await rig.packet(1, 'cancel', 300, 300);
    await tester.pump(const Duration(seconds: 1));
    expect(rig.finished, contains('finish:1'));
    expect(
      rig.controller.strokes.any(rig.controller.isStrokeNativeHeld),
      isFalse,
    );
  });

  testWidgets('closing the page lets go, and a later canvas draws the ink', (
    WidgetTester tester,
  ) async {
    final InkController controller = InkController();
    final _Rig rig = await _Rig.pump(tester, controller: controller);
    await rig.write(1);
    final Stroke stroke = rig.last;
    expect(controller.isStrokeNativeHeld(stroke), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(rig.finished, <String>['finish:1']);
    expect(controller.isStrokeNativeHeld(stroke), isFalse);
    expect(controller.strokes, <Stroke>[stroke]);
  });
}
