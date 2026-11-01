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
  testWidgets('scrolling clears the screen-space native ink preview', (
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

    expect(calls, contains('clearAllPreviews'));

    await first.up();
    await second.up();
  });
}
