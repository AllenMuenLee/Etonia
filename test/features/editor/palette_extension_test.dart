import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/audio/note_audio.dart';
import 'package:greatnote/features/library/note_recording_track.dart';
import 'package:greatnote/features/editor/audio/stroke_replay_controller.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/pen_settings.dart';
import 'package:greatnote/features/editor/ink/ruler.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/sticky/sticky_note.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/widgets/palette_button.dart';
import 'package:greatnote/features/editor/widgets/recording_options.dart';
import 'package:greatnote/features/editor/widgets/tool_palette.dart';

class _IdleRecorder extends NoteAudioRecorder {
  @override
  NoteAudioRecorderState get state => NoteAudioRecorderState.idle;
  @override
  String? get activeRecordingId => null;
  @override
  int get currentElapsedMs => 0;
  @override
  Future<bool> start() async => true;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<RecordedNoteAudio?> stop() async => null;
}

class _Palette {
  _Palette()
    : tool = ValueNotifier<EditorTool>(EditorTool.pen),
      pen = ValueNotifier<PenSettings>(PenSettings.defaults()),
      eraser = ValueNotifier<EraserSettings>(EraserSettings.defaults()),
      aiActive = ValueNotifier<bool>(false),
      sticky = ValueNotifier<StickyNoteSettings>(const StickyNoteSettings()),
      ruler = RulerController(),
      controller = ToolPaletteController(),
      recorder = _IdleRecorder(),
      document = NoteDocument(),
      replay = StrokeReplayController();

  final ValueNotifier<EditorTool> tool;
  final ValueNotifier<PenSettings> pen;
  final ValueNotifier<EraserSettings> eraser;
  final ValueNotifier<bool> aiActive;
  final ValueNotifier<StickyNoteSettings> sticky;
  final RulerController ruler;
  final ToolPaletteController controller;
  final _IdleRecorder recorder;
  final NoteDocument document;
  final StrokeReplayController replay;
  final List<NoteRecordingTrack> opened = <NoteRecordingTrack>[];

  void dispose() {
    tool.dispose();
    pen.dispose();
    eraser.dispose();
    aiActive.dispose();
    sticky.dispose();
    ruler.dispose();
    controller.expanded.dispose();
    recorder.dispose();
    document.dispose();
    replay.dispose();
  }
}

Future<_Palette> _pump(
  WidgetTester tester, {
  PaletteEdge edge = PaletteEdge.top,
  Size screen = const Size(1000, 700),
}) async {
  final _Palette palette = _Palette();
  addTearDown(palette.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = screen;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ToolPalette(
            edge: edge,
            tool: palette.tool,
            penSettings: palette.pen,
            eraserSettings: palette.eraser,
            clipboardListenable: ValueNotifier<int>(0),
            canPaste: () => false,
            onPaste: () {},
            aiActive: palette.aiActive,
            onTurnOnAi: () {},
            controller: palette.controller,
            ruler: palette.ruler,
            recording: RecordingToolData(
              recorder: palette.recorder,
              document: palette.document,
              replay: palette.replay,
              onStart: () {},
              onPause: () {},
              onResume: () {},
              onStop: () {},
              onOpen: palette.opened.add,
            ),
            stickySettings: palette.sticky,
            onStickySettingsChanged: (StickyNoteSettings next) =>
                palette.sticky.value = next,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return palette;
}

void main() {
  group('size', () {
    test('grows by the three secondary tools when expanded', () {
      final Size row = ToolPalette.sizeFor(Axis.horizontal);
      final Size wide = ToolPalette.sizeFor(Axis.horizontal, expanded: true);
      final Size column = ToolPalette.sizeFor(Axis.vertical);
      final Size tall = ToolPalette.sizeFor(Axis.vertical, expanded: true);

      expect(wide.width - row.width, 3 * 44);
      expect(wide.height, row.height);
      expect(tall.height - column.height, 3 * 44);
      expect(tall.width, column.width);
      // Six tools and the arrow.
      expect(row.width, 6 * 44 + AppSizes.minTouchTarget + 2 * AppSpacing.xxs);
      expect(column, Size(row.height, row.width));
    });

    test('keeps an expanded palette inside the page where it docks', () {
      const Rect region = Rect.fromLTWH(0, 0, 500, 700);
      final Size size = ToolPalette.sizeFor(Axis.horizontal, expanded: true);

      for (final double along in <double>[0, 0.5, 1]) {
        final Offset origin = PalettePlacement(
          along: along,
        ).originIn(region, 8, expanded: true);
        expect(origin.dx, greaterThanOrEqualTo(region.left));
        expect(origin.dx + size.width, lessThanOrEqualTo(region.right));
      }
      final Offset atRight = const PalettePlacement(
        edge: PaletteEdge.right,
        along: 1,
      ).originIn(region, 8, expanded: true);
      final Size tall = ToolPalette.sizeFor(Axis.vertical, expanded: true);
      expect(atRight.dx + tall.width, lessThanOrEqualTo(region.right));
      expect(atRight.dy + tall.height, lessThanOrEqualTo(region.bottom));
    });

    test('is let go where it lies, as wide as it now is', () {
      const Rect region = Rect.fromLTWH(0, 0, 1000, 700);
      final PalettePlacement placement = PalettePlacement.nearest(
        region,
        const Offset(990, 300),
        8,
        expanded: true,
      );

      expect(placement.edge, PaletteEdge.right);
    });
  });

  group('the extension arrow', () {
    testWidgets('sits at the end, folded, with only the six tools beside it', (
      WidgetTester tester,
    ) async {
      await _pump(tester);

      expect(find.byType(PaletteButton), findsNWidgets(7));
      expect(find.byTooltip('Expand toolbar'), findsOneWidget);
      expect(find.byTooltip('Collapse toolbar'), findsNothing);
      expect(find.byIcon(CupertinoIcons.chevron_right), findsOneWidget);
      expect(find.byTooltip('Show ruler'), findsNothing);
      // At the trailing end of the row.
      final Rect arrow = tester.getRect(
        find.byKey(const ValueKey<String>('palette-extension-toggle')),
      );
      final Rect ai = tester.getRect(
        find.byKey(const ValueKey<String>('ai-mode-toggle')),
      );
      expect(arrow.left, greaterThan(ai.left));
      expect(arrow.top, ai.top);
      // Compact size.
      expect(
        tester.getSize(find.byType(ToolPalette)),
        ToolPalette.sizeFor(Axis.horizontal),
      );
    });

    testWidgets('unfolds recordings, text, and ruler, then folds them again', (
      WidgetTester tester,
    ) async {
      final _Palette palette = await _pump(tester);

      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();

      expect(palette.controller.expanded.value, isTrue);
      expect(find.byType(PaletteButton), findsNWidgets(10));
      expect(find.byTooltip('Recordings'), findsOneWidget);
      expect(find.byTooltip('Text'), findsOneWidget);
      expect(find.byTooltip('Show ruler'), findsOneWidget);
      expect(find.byTooltip('Collapse toolbar'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.chevron_left), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.chevron_right), findsNothing);
      expect(
        tester.getSize(find.byType(ToolPalette)),
        ToolPalette.sizeFor(Axis.horizontal, expanded: true),
      );
      // The arrow is still the last of them.
      final Rect arrow = tester.getRect(find.byTooltip('Collapse toolbar'));
      expect(
        arrow.left,
        greaterThan(tester.getRect(find.byTooltip('Show ruler')).left),
      );
      expect(
        tester.getRect(find.byTooltip('Recordings')).left,
        lessThan(tester.getRect(find.byTooltip('Text')).left),
      );
      expect(
        tester.getRect(find.byTooltip('Text')).left,
        lessThan(tester.getRect(find.byTooltip('Show ruler')).left),
      );

      await tester.tap(find.byTooltip('Collapse toolbar'));
      await tester.pumpAndSettle();

      expect(palette.controller.expanded.value, isFalse);
      expect(find.byTooltip('Recordings'), findsNothing);
      expect(find.byTooltip('Show ruler'), findsNothing);
      expect(find.byTooltip('Expand toolbar'), findsOneWidget);
      expect(
        tester.getSize(find.byType(ToolPalette)),
        ToolPalette.sizeFor(Axis.horizontal),
      );
    });

    testWidgets('eases out over the snappy duration', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      final double folded = tester.getSize(find.byType(ToolPalette)).width;

      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pump();
      await tester.pump(ToolPalette.unfoldDuration * 0.4);
      final double halfway = tester.getSize(find.byType(ToolPalette)).width;
      expect(halfway, greaterThan(folded));
      expect(
        halfway,
        lessThan(ToolPalette.sizeFor(Axis.horizontal, expanded: true).width),
      );

      await tester.pump(ToolPalette.unfoldDuration * 0.7);
      expect(
        tester.getSize(find.byType(ToolPalette)).width,
        ToolPalette.sizeFor(Axis.horizontal, expanded: true).width,
      );
    });

    testWidgets('points down and up along a column', (
      WidgetTester tester,
    ) async {
      await _pump(tester, edge: PaletteEdge.left);

      expect(find.byIcon(CupertinoIcons.chevron_down), findsOneWidget);
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();

      expect(find.byIcon(CupertinoIcons.chevron_up), findsOneWidget);
      expect(
        tester.getSize(find.byType(ToolPalette)),
        ToolPalette.sizeFor(Axis.vertical, expanded: true),
      );
      // The secondary tools lie below the primary ones.
      expect(
        tester.getRect(find.byTooltip('Recordings')).top,
        greaterThan(tester.getRect(find.byTooltip('Turn on AI')).top),
      );
    });

    testWidgets('announces to assistive technology', (
      WidgetTester tester,
    ) async {
      final List<String> announced = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            dynamic message,
          ) async {
            if (message is Map && message['type'] == 'announce') {
              announced.add((message['data'] as Map)['message'] as String);
            }
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      await _pump(tester);

      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Collapse toolbar'));
      await tester.pumpAndSettle();

      expect(announced, <String>[
        'Tools expanded, 3 additional tools available',
        'Tools collapsed',
      ]);
    });

    testWidgets('hides the secondary tools from screen readers when folded', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester);

      expect(find.bySemanticsLabel('Recordings'), findsNothing);
      expect(find.bySemanticsLabel('Ruler'), findsNothing);
      expect(find.bySemanticsLabel('Expand toolbar'), findsOneWidget);

      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Recordings'), findsOneWidget);
      expect(find.bySemanticsLabel('Ruler'), findsOneWidget);
      expect(find.bySemanticsLabel('Collapse toolbar'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('keeps the same 48 px touch target as the other tools', (
      WidgetTester tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();

      for (final String tooltip in <String>[
        'Expand toolbar',
        'Collapse toolbar',
        'Recordings',
        'Show ruler',
      ]) {
        final Finder finder = find.byTooltip(tooltip);
        if (finder.evaluate().isEmpty) continue;
        final Size size = tester.getSize(
          find.descendant(of: finder, matching: find.byType(InkWell)).first,
        );
        expect(size.shortestSide, greaterThanOrEqualTo(48), reason: tooltip);
      }
    });
  });

  group('the recordings button', () {
    testWidgets('opens a list of every recording and opens the chosen one', (
      WidgetTester tester,
    ) async {
      final _Palette palette = await _pump(tester);
      for (int i = 1; i <= 8; i++) {
        palette.document.addRecording(
          NoteRecordingTrack(
            id: 'rec-$i',
            title: 'Recording $i',
            assetPath: 'asset-$i',
            durationMs: 65000,
            createdAt: DateTime.utc(2026, 10, 23, i),
          ),
        );
      }
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Recordings'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Recording 8'), findsOneWidget);
      await tester.tap(find.text('Recording 8'));
      await tester.pumpAndSettle();
      expect(palette.opened.single.id, 'rec-8');
      expect(tester.takeException(), isNull);
    });
  });

  group('the ruler button', () {
    testWidgets('toggles the ruler and leaves the pen chosen', (
      WidgetTester tester,
    ) async {
      final _Palette palette = await _pump(tester);
      palette.pen.value = palette.pen.value.copyWith(
        style: WritingStyle.highlighter,
      );
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();
      final PenSettings before = palette.pen.value;

      await tester.tap(find.byTooltip('Show ruler'));
      await tester.pumpAndSettle();

      expect(palette.ruler.isVisible, isTrue);
      expect(palette.tool.value, EditorTool.pen);
      expect(palette.pen.value, before);
      expect(find.byTooltip('Hide ruler'), findsOneWidget);
      expect(
        tester
            .widget<PaletteButton>(
              find.byKey(const ValueKey<String>('ruler-toggle')),
            )
            .selected,
        isTrue,
      );

      await tester.tap(find.byTooltip('Hide ruler'));
      await tester.pumpAndSettle();

      expect(palette.ruler.isVisible, isFalse);
      expect(palette.tool.value, EditorTool.pen);
      expect(palette.pen.value, before);
      expect(
        tester
            .widget<PaletteButton>(
              find.byKey(const ValueKey<String>('ruler-toggle')),
            )
            .selected,
        isFalse,
      );
    });

    testWidgets('stays with the eraser when that is the tool', (
      WidgetTester tester,
    ) async {
      final _Palette palette = await _pump(tester);
      palette.tool.value = EditorTool.eraser;
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Show ruler'));
      await tester.pumpAndSettle();

      expect(palette.tool.value, EditorTool.eraser);
      expect(palette.ruler.isVisible, isTrue);
    });

    testWidgets('keeps the ruler showing when the toolbar is folded away', (
      WidgetTester tester,
    ) async {
      final _Palette palette = await _pump(tester);
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show ruler'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Collapse toolbar'));
      await tester.pumpAndSettle();

      expect(palette.ruler.isVisible, isTrue);
    });

    testWidgets('is announced and is a toggle to screen readers', (
      WidgetTester tester,
    ) async {
      final List<String> announced = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            dynamic message,
          ) async {
            if (message is Map && message['type'] == 'announce') {
              announced.add((message['data'] as Map)['message'] as String);
            }
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      final SemanticsHandle handle = tester.ensureSemantics();
      await _pump(tester);
      await tester.tap(find.byTooltip('Expand toolbar'));
      await tester.pumpAndSettle();
      announced.clear();

      await tester.tap(find.byTooltip('Show ruler'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.bySemanticsLabel('Ruler')),
        matchesSemantics(
          label: 'Ruler',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
        ),
      );
      await tester.tap(find.byTooltip('Hide ruler'));
      await tester.pumpAndSettle();

      expect(announced, <String>['Ruler shown', 'Ruler hidden']);
      handle.dispose();
    });
  });
}
