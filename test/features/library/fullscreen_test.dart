import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/widgets/editor_app_bar.dart';
import 'package:greatnote/features/editor/widgets/editor_chrome.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/open_notes.dart';

/// Counts how often its state is made, and offers the way out of
/// fullscreen as the real editor's page controls do.
class _Editor extends StatefulWidget {
  const _Editor({super.key, required this.note, required this.built});

  final NoteEntry note;
  final List<String> built;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  @override
  void initState() {
    super.initState();
    widget.built.add(widget.note.id);
  }

  @override
  Widget build(BuildContext context) {
    final VoidCallback? exit = EditorFullscreenScope.maybeOf(context)?.onExit;
    return Column(
      children: <Widget>[
        Text('Editor for ${widget.note.title}'),
        if (exit != null)
          TextButton(
            key: ValueKey<String>('exit-${widget.note.id}'),
            onPressed: exit,
            child: const Text('Exit'),
          ),
      ],
    );
  }
}

void main() {
  NoteEntry makeNote(String id, String title) {
    return NoteEntry(
      id: id,
      title: title,
      folderId: 'root',
      created: DateTime(2026, 10, 20),
      modified: DateTime(2026, 10, 20),
      pageCount: 1,
    );
  }

  final NoteEntry a = makeNote('a', 'Note A');
  final NoteEntry b = makeNote('b', 'Note B');

  late List<String> modes;

  setUp(() {
    modes = <String>[];
    final TestDefaultBinaryMessenger messenger =
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        modes.add(call.arguments as String);
      }
      // Manual mode is sent as the overlays it keeps.
      if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
        modes.add('manual: ${(call.arguments as List<Object?>).join(', ')}');
      }
      return null;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget host(OpenNotes notes, List<String> built, {bool showing = true}) {
    return GreatnoteApp(
      home: Scaffold(
        body: NoteTabsPage(
          notes: notes,
          showing: showing,
          builder: (note, tabs, onBack, onRenamed) {
            tabs(() {});
            return _Editor(
              key: ValueKey<String>('editor-${note.id}'),
              note: note,
              built: built,
            );
          },
        ),
      ),
    );
  }

  Future<OpenNotes> pumpTabs(WidgetTester tester, List<String> built) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final OpenNotes notes = OpenNotes();
    addTearDown(notes.dispose);
    <NoteEntry>[a, b].forEach(notes.open);
    await tester.pumpWidget(host(notes, built));
    await tester.pumpAndSettle();
    return notes;
  }

  final Finder enter = find.byKey(const ValueKey<String>('enter-fullscreen'));

  testWidgets('a note puts the status bar away; the library has it back', (
    tester,
  ) async {
    final List<String> built = <String>[];
    final OpenNotes notes = await pumpTabs(tester, built);
    expect(modes, <String>['manual: SystemUiOverlay.bottom']);

    await tester.pumpWidget(host(notes, built, showing: false));
    expect(modes.last, 'SystemUiMode.edgeToEdge');

    await tester.pumpWidget(host(notes, built));
    expect(modes.last, 'manual: SystemUiOverlay.bottom');
  });

  testWidgets('fullscreen puts the tabs away and brings them back', (
    tester,
  ) async {
    final List<String> built = <String>[];
    await pumpTabs(tester, built);
    final int builds = built.length;

    expect(find.byType(EditorAppBar), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('exit-b')), findsNothing);

    await tester.tap(enter);
    await tester.pumpAndSettle();

    expect(find.byType(EditorAppBar), findsNothing);
    expect(find.text('Editor for Note B'), findsOneWidget);
    expect(modes.last, 'SystemUiMode.immersiveSticky');
    // Nothing was built again for it.
    expect(built.length, builds);

    await tester.tap(find.byKey(const ValueKey<String>('exit-b')));
    await tester.pumpAndSettle();

    expect(find.byType(EditorAppBar), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('exit-b')), findsNothing);
    expect(modes.last, 'manual: SystemUiOverlay.bottom');
    expect(built.length, builds);
  });

  group('the slide', () {
    double barTop(WidgetTester tester) =>
        tester.getTopLeft(find.byType(EditorAppBar)).dy;
    Rect page(WidgetTester tester) =>
        tester.getRect(find.byKey(const ValueKey<String>('editor-b')));

    testWidgets('going fullscreen moves the bar and the page up as one', (
      tester,
    ) async {
      await pumpTabs(tester, <String>[]);
      final double barHeight = tester.getSize(find.byType(EditorAppBar)).height;
      expect(page(tester).top, barHeight);
      expect(page(tester).height, 800 - barHeight);

      await tester.tap(enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(barTop(tester), inExclusiveRange(-barHeight, 0));
      expect(page(tester).top, moreOrLessEquals(barTop(tester) + barHeight));
      // Already its final size, so it is not laid out on each frame.
      expect(page(tester).height, 800);

      await tester.pumpAndSettle();
      expect(find.byType(EditorAppBar), findsNothing);
      expect(page(tester), const Rect.fromLTWH(0, 0, 1200, 800));
    });

    testWidgets('leaving moves them back down, then fits the page', (
      tester,
    ) async {
      await pumpTabs(tester, <String>[]);
      await tester.tap(enter);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('exit-b')));
      await tester.pump();
      final double barHeight = tester.getSize(find.byType(EditorAppBar)).height;
      expect(barTop(tester), moreOrLessEquals(-barHeight, epsilon: 1));
      await tester.pump(const Duration(milliseconds: 100));

      expect(barTop(tester), inExclusiveRange(-barHeight, 0));
      expect(page(tester).top, moreOrLessEquals(barTop(tester) + barHeight));
      expect(page(tester).height, 800);

      await tester.pumpAndSettle();
      expect(barTop(tester), 0);
      expect(page(tester), Rect.fromLTWH(0, barHeight, 1200, 800 - barHeight));
    });

    testWidgets('turned back halfway, it goes back from where it is', (
      tester,
    ) async {
      await pumpTabs(tester, <String>[]);
      await tester.tap(enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final double halfway = barTop(tester);

      await tester.tap(find.byKey(const ValueKey<String>('exit-b')));
      await tester.pump();
      expect(barTop(tester), moreOrLessEquals(halfway, epsilon: 1));

      await tester.pumpAndSettle();
      expect(barTop(tester), 0);
      expect(find.byKey(const ValueKey<String>('exit-b')), findsNothing);
    });

    testWidgets('with motion reduced nothing travels', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpTabs(tester, <String>[]);

      await tester.tap(enter);
      await tester.pump();

      expect(find.byType(EditorAppBar), findsNothing);
      expect(page(tester), const Rect.fromLTWH(0, 0, 1200, 800));
    });

    testWidgets('the native pen surface hears where the page came to rest', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const MethodChannel channel = MethodChannel('com.etonia.app/native_ink');
      double? surfaceTop;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        if (call.method == 'registerSurface' ||
            call.method == 'updateSurface') {
          final Map<Object?, Object?> surface =
              call.arguments as Map<Object?, Object?>;
          surfaceTop = surface['originY'] as double?;
        }
        return call.method == 'registerSurface' ? true : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final OpenNotes notes = OpenNotes();
      addTearDown(notes.dispose);
      notes.open(a);
      final NoteDocument document = NoteDocument(
        pages: <NotePage>[NotePage(ink: InkController())],
      );
      addTearDown(document.dispose);
      await tester.pumpWidget(
        GreatnoteApp(
          home: NoteTabsPage(
            notes: notes,
            builder: (note, tabs, onBack, onRenamed) {
              tabs(() {});
              return EditorScreen(document: document);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      double canvasTop() => tester.getTopLeft(find.byType(InkCanvas).first).dy;
      expect(surfaceTop, moreOrLessEquals(canvasTop()));

      await tester.tap(enter);
      await tester.pumpAndSettle();
      expect(surfaceTop, moreOrLessEquals(canvasTop()));

      await tester.tap(find.byKey(const ValueKey<String>('exit-fullscreen')));
      await tester.pumpAndSettle();
      expect(surfaceTop, moreOrLessEquals(canvasTop()));

      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('going back to the library leaves fullscreen', (tester) async {
    final List<String> built = <String>[];
    final OpenNotes notes = await pumpTabs(tester, built);
    await tester.tap(enter);
    await tester.pumpAndSettle();
    expect(find.byType(EditorAppBar), findsNothing);

    await tester.pumpWidget(host(notes, built, showing: false));
    await tester.pumpAndSettle();

    expect(modes.last, 'SystemUiMode.edgeToEdge');
    expect(find.byType(EditorAppBar), findsOneWidget);
  });
}
