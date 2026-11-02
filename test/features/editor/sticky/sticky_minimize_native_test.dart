import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';

import '../../../helpers/pump_app.dart';

const MethodChannel _channel = MethodChannel('com.etonia.app/native_ink');

/// The native ink bridge is one instance that remembers a missing platform,
/// so this has a file of its own: the pen reaches the page through it on a
/// real device, and every press here comes as native packets.
void main() {
  testWidgets('a pen tap through native ink works the minimize button', (
    WidgetTester tester,
  ) async {
    final List<int> surfaces = <int>[];
    final List<int> finished = <int>[];
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      final Map<Object?, Object?>? args = call.arguments is Map
          ? call.arguments as Map<Object?, Object?>
          : null;
      switch (call.method) {
        case 'registerSurface':
          surfaces.add(args!['surfaceId']! as int);
          return true;
        case 'finishPreview':
          finished.add(args!['pointer']! as int);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));

    final InkController controller = InkController(
      stickyNotes: <StickyNoteElement>[
        StickyNoteElement(
          id: 'n',
          center: const InkVector(300, 300),
          size: const Size(240, 180),
          colorId: 'yellow',
        ),
      ],
    );
    addTearDown(controller.dispose);
    await pumpApp(tester, home: EditorScreen(inkController: controller));
    await tester.pumpAndSettle();
    expect(surfaces, isNotEmpty);

    int time = 0;
    Future<void> packet(int pointer, String phase, InkVector at) async {
      time += 8000;
      await messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(
          MethodCall('inkPacket', <String, Object?>{
            'surfaceId': surfaces.first,
            'pointer': pointer,
            'phase': phase,
            'kind': 'stylus',
            'samples': <Object?>[at.x, at.y, time, 0.5],
          }),
        ),
        (_) {},
      );
      await tester.pump();
    }

    // The note's top-left corner is at (180, 210); its button's middle 22
    // in from each edge.
    const InkVector button = InkVector(202, 232);

    // Written elsewhere on it, the same packets are ink: they do arrive.
    await packet(1, 'down', const InkVector(300, 300));
    await packet(1, 'move', const InkVector(340, 300));
    await packet(1, 'up', const InkVector(380, 300));
    expect(controller.stickyNotes.single.strokes, hasLength(1));
    // Pointer-up commits the Flutter stroke, but native wet ink stays until
    // that frame is surely rasterized and shown: two more frames must begin,
    // which the engine allows only once the commit frame is drawn, and a
    // third for the display. So blank paper never appears between the two
    // renderers, however long the raster thread takes over a long stroke.
    for (int frame = 0; frame < 2; frame++) {
      expect(finished, isEmpty);
      await tester.pump();
    }
    expect(finished, isEmpty);
    await tester.pump();
    expect(finished, <int>[1]);

    finished.clear();
    await packet(2, 'down', button);
    // The preview's dot goes as soon as the press lands on the button.
    expect(finished, contains(2));
    await packet(2, 'up', button);
    expect(controller.stickyNotes.single.minimized, isTrue);
    expect(controller.stickyNotes.single.strokes, hasLength(1));
    expect(controller.strokes, isEmpty);

    await packet(3, 'down', button);
    await packet(3, 'up', button);
    expect(controller.stickyNotes.single.minimized, isFalse);
    expect(controller.stickyNotes.single.strokes, hasLength(1));

    // Moved away from the button, the press does nothing at all.
    await packet(4, 'down', button);
    await packet(4, 'move', const InkVector(300, 232));
    await packet(4, 'up', const InkVector(300, 232));
    expect(controller.stickyNotes.single.minimized, isFalse);
    expect(controller.stickyNotes.single.strokes, hasLength(1));
    expect(controller.strokes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
