import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';

import '../../helpers/pump_app.dart';

void main() {
  testWidgets('scrolling drops only the native stroke being drawn', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const MethodChannel channel = MethodChannel('com.etonia.app/native_ink');
    final List<String> calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      return call.method == 'registerSurface' ? true : null;
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    const PageSetup shortPage = PageSetup(
      size: PageSize.custom,
      customSize: Size(1000, 500),
    );
    final NoteDocument document = NoteDocument(
      pages: <NotePage>[
        for (int i = 0; i < 3; i++)
          NotePage(ink: InkController(), setup: shortPage),
      ],
    );
    addTearDown(document.dispose);
    await pumpApp(
      tester,
      viewport: TestViewport.tabletLandscape,
      home: EditorScreen(document: document),
    );
    calls.clear();

    final Offset center = tester.getCenter(find.byType(EditorScreen));
    final TestGesture first = await tester.startGesture(
      center - const Offset(40, 0),
      kind: PointerDeviceKind.touch,
    );
    final TestGesture second = await tester.startGesture(
      center + const Offset(40, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    expect(calls, contains('clearLivePreview'));
    expect(calls, isNot(contains('finishPreview')));

    await first.up();
    await second.up();
  });

  testWidgets('closing the page mid-handoff still removes the wet ink', (
    WidgetTester tester,
  ) async {
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const MethodChannel channel = MethodChannel('com.etonia.app/native_ink');
    final List<int> surfaces = <int>[];
    final List<int> finished = <int>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
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
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final InkController controller = InkController();
    addTearDown(controller.dispose);
    await pumpApp(tester, home: EditorScreen(inkController: controller));
    await tester.pumpAndSettle();
    expect(surfaces, isNotEmpty);

    int time = 0;
    Future<void> packet(String phase, double x) async {
      time += 8000;
      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('inkPacket', <String, Object?>{
            'surfaceId': surfaces.first,
            'pointer': 1,
            'phase': phase,
            'kind': 'stylus',
            'samples': <Object?>[x, 300.0, time, 0.5],
          }),
        ),
        (_) {},
      );
    }

    await packet('down', 300);
    await packet('move', 340);
    await packet('up', 380);
    expect(controller.strokes, hasLength(1));
    expect(finished, isEmpty);

    // The overlay lives in the root view and outlasts the page, so nothing
    // would ever take the stroke off the screen after this.
    await tester.pumpWidget(const SizedBox.shrink());

    expect(finished, <int>[1]);
  });
}
