import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_assistant_controller.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/stylus_actions.dart';
import 'package:greatnote/features/editor/widgets/editor_settings_sheet.dart';
import 'package:greatnote/features/editor/widgets/history_controls.dart';
import 'package:greatnote/features/editor/widgets/page_controls.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';
import 'package:greatnote/features/editor/widgets/writing_surface_frame.dart';

import '../../helpers/ai_fakes.dart';
import '../../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stylus action defaults match the writing shortcuts', () {
    const StylusActionBindings bindings = StylusActionBindings();

    expect(
      bindings.actionFor(StylusGesture.singlePress),
      StylusAction.toggleToolOptions,
    );
    expect(
      bindings.actionFor(StylusGesture.doubleTap),
      StylusAction.togglePenEraser,
    );
    expect(bindings.actionFor(StylusGesture.secondaryPress), StylusAction.none);
    expect(bindings.actionFor(StylusGesture.squeeze), StylusAction.none);
  });

  test('a binding can be changed without changing the others', () {
    const StylusActionBindings original = StylusActionBindings();
    final StylusActionBindings changed = original.withAction(
      StylusGesture.squeeze,
      StylusAction.undo,
    );

    expect(changed.squeeze, StylusAction.undo);
    expect(changed.singlePress, original.singlePress);
    expect(changed.doubleTap, original.doubleTap);
    expect(changed.secondaryPress, original.secondaryPress);
  });

  testWidgets('native single press hides and shows only the tool options', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, home: const EditorScreen());
    expect(find.byType(PenOptions), findsOneWidget);

    await _sendGesture(StylusGesture.singlePress);
    await tester.pump();
    expect(find.byType(PenOptions), findsNothing);
    expect(find.byType(ToolPalette), findsOneWidget);
    expect(find.byType(WritingSurfaceFrame).hitTestable(), findsOneWidget);

    await _sendGesture(StylusGesture.singlePress);
    await tester.pump();
    expect(find.byType(PenOptions), findsOneWidget);
    expect(find.byType(ToolPalette), findsOneWidget);
  });

  testWidgets('a press bound to the toolbar hides and shows it', (
    WidgetTester tester,
  ) async {
    await _pumpWithToolbarBinding(tester);
    expect(find.byType(ToolPalette), findsOneWidget);

    await _sendGesture(StylusGesture.singlePress);
    await tester.pump();
    expect(find.byType(ToolPalette), findsNothing);

    await _sendGesture(StylusGesture.singlePress);
    await tester.pump();
    expect(find.byType(ToolPalette), findsOneWidget);
  });

  testWidgets('hiding the toolbar leaves the rest of the editor on screen', (
    WidgetTester tester,
  ) async {
    await _pumpWithToolbarBinding(tester);
    expect(find.byType(WritingSurfaceFrame).hitTestable(), findsOneWidget);
    expect(find.byType(HistoryControls).hitTestable(), findsOneWidget);
    expect(find.byType(PageControls).hitTestable(), findsOneWidget);

    await _sendGesture(StylusGesture.singlePress);
    await tester.pump();

    expect(find.byType(ToolPalette), findsNothing);
    expect(find.byType(WritingSurfaceFrame).hitTestable(), findsOneWidget);
    expect(find.byType(HistoryControls).hitTestable(), findsOneWidget);
    expect(find.byType(PageControls).hitTestable(), findsOneWidget);
  });

  testWidgets('native double tap switches between pen and eraser', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, home: const EditorScreen());
    final ToolPalette palette = tester.widget<ToolPalette>(
      find.byType(ToolPalette),
    );
    expect(palette.tool.value, EditorTool.pen);

    await _sendGesture(StylusGesture.doubleTap);
    await tester.pump();
    expect(palette.tool.value, EditorTool.eraser);

    await _sendGesture(StylusGesture.doubleTap);
    await tester.pump();
    expect(palette.tool.value, EditorTool.pen);
  });

  testWidgets('settings offer the buttons an Android stylus has', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<StylusActionBindings> bindings =
        ValueNotifier<StylusActionBindings>(const StylusActionBindings());
    addTearDown(bindings.dispose);
    await pumpApp(tester, home: EditorScreen(stylusActions: bindings));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(_actionRow(StylusGesture.singlePress), findsOneWidget);
    expect(_actionRow(StylusGesture.doubleTap), findsOneWidget);
    expect(_actionRow(StylusGesture.secondaryPress), findsOneWidget);
    expect(_actionRow(StylusGesture.squeeze), findsNothing);
    expect(find.text('Only write with stylus'), findsOneWidget);

    await tester.tap(_actionRow(StylusGesture.secondaryPress));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo').last);
    await tester.pumpAndSettle();

    expect(bindings.value.secondaryPress, StylusAction.undo);
  });

  testWidgets(
    'settings offer the gestures Apple Pencil has',
    (WidgetTester tester) async {
      await _pumpSettings(tester);

      expect(find.text('Apple Pencil'), findsOneWidget);
      expect(find.text('Only write with Apple Pencil'), findsOneWidget);
      expect(_actionRow(StylusGesture.doubleTap), findsOneWidget);
      expect(_actionRow(StylusGesture.squeeze), findsOneWidget);
      expect(_actionRow(StylusGesture.singlePress), findsNothing);
      expect(_actionRow(StylusGesture.secondaryPress), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'where no stylus gestures are reported, settings offer none',
    (WidgetTester tester) async {
      await _pumpSettings(tester);

      for (final StylusGesture gesture in StylusGesture.values) {
        expect(_actionRow(gesture), findsNothing);
      }
      expect(find.text('Only write with stylus'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('settings fit a narrow phone at a large text size', (
    WidgetTester tester,
  ) async {
    await _pumpSettings(
      tester,
      size: const Size(320, 640),
      textScaler: const TextScaler.linear(1.5),
    );

    await tester.dragUntilVisible(
      find.text('Panel side'),
      find.byType(EditorSettingsSheet),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();

    expect(find.text('Panel side'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Finder _actionRow(StylusGesture gesture) =>
    find.byKey(ValueKey<String>('stylus-${gesture.name}-action'));

/// The editor, with the single press bound to hiding the whole toolbar.
Future<void> _pumpWithToolbarBinding(WidgetTester tester) async {
  final ValueNotifier<StylusActionBindings> bindings =
      ValueNotifier<StylusActionBindings>(
        const StylusActionBindings(singlePress: StylusAction.toggleToolbar),
      );
  addTearDown(bindings.dispose);
  await pumpApp(tester, home: EditorScreen(stylusActions: bindings));
}

/// The settings alone, on whichever platform the test's variant sets.
Future<void> _pumpSettings(
  WidgetTester tester, {
  Size size = const Size(1194, 834),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  final ValueNotifier<StylusActionBindings> bindings =
      ValueNotifier<StylusActionBindings>(const StylusActionBindings());
  addTearDown(bindings.dispose);
  final ValueNotifier<bool> stylusOnly = ValueNotifier<bool>(true);
  addTearDown(stylusOnly.dispose);
  final ValueNotifier<AiTextSize> textSize = ValueNotifier<AiTextSize>(
    AiTextSize.medium,
  );
  addTearDown(textSize.dispose);
  final AiAssistantController controller = AiAssistantController(
    client: FakeAiClient(),
  );
  addTearDown(controller.dispose);
  await pumpApp(
    tester,
    size: size,
    home: Builder(
      builder: (BuildContext context) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: Scaffold(
            body: EditorSettingsSheet(
              controller: controller,
              stylusOnly: stylusOnly,
              stylusActions: bindings,
              textSize: textSize,
              onTextSizeChanged: (_) {},
            ),
          ),
        );
      },
    ),
  );
}

Future<void> _sendGesture(StylusGesture gesture) async {
  final ByteData data = const StandardMethodCodec().encodeMethodCall(
    MethodCall('stylusGesture', <String, Object>{'gesture': gesture.name}),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('com.etonia.app/native_ink', data, (_) {});
}
