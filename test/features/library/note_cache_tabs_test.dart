import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/app/theme/app_tokens.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_cache_page.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_editor_page.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_tabs_page.dart';
import 'package:greatnote/features/library/open_notes.dart';
import 'package:greatnote/shared/memory/note_cache_pool.dart';

/// Counts how often it is built from nothing, and let go of.
class _Probe extends StatefulWidget {
  const _Probe({required this.log});

  final List<String> log;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.log.add('built');
  }

  @override
  void dispose() {
    widget.log.add('disposed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Repository extends InMemoryNoteRepository {
  final Map<String, int> reads = <String, int>{};

  @override
  Future<NoteContent> readContent(String id) {
    reads[id] = (reads[id] ?? 0) + 1;
    return super.readContent(id);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(AppMotion.smooth.duration);
  await tester.pumpAndSettle();
}

/// A note with a line on its page, which takes some memory.
Future<NoteEntry> _noteWithInk(NoteRepository repository, String title) async {
  final NoteEntry note = await repository.createNote(title: title);
  await repository.saveNote(
    note.id,
    NoteContent(<StoredPage>[
      StoredPage(
        setup: const PageSetup(),
        strokes: <Stroke>[
          Stroke.fromPoints(
            style: const StrokeStyle(ink: InkPalette.ink, width: 2),
            points: const <InkVector>[InkVector(10, 10), InkVector(90, 90)],
          ),
        ],
      ),
    ]),
  );
  return note;
}

void main() {
  group('a page in a tab', () {
    Widget host(NoteCacheScope scope, List<String> log, {required bool shown}) {
      return TickerMode(
        enabled: shown,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: NoteCachePage(
            scope: scope,
            page: 'page',
            child: _Probe(log: log),
          ),
        ),
      );
    }

    testWidgets('stays while shown, and is built again after going out of '
        'view with its turn to go come', (tester) async {
      final NoteCachePool pool = NoteCachePool(maxBytes: 100);
      final NoteCacheScope scope = pool.scope();
      final List<String> log = <String>[];
      final List<String> popped = <String>[];

      await tester.pumpWidget(host(scope, log, shown: true));
      expect(log, <String>['built']);
      scope.add(page: 'page', bytes: 500, onPop: () => popped.add('page'));
      expect(popped, isEmpty, reason: 'on screen, even over the limit');

      await tester.pumpWidget(host(scope, log, shown: false));
      await tester.pump();
      expect(popped, <String>['page']);
      expect(log, <String>['built', 'disposed']);
      expect(pool.usedBytes, 0);

      await tester.pumpWidget(host(scope, log, shown: true));
      expect(log, <String>['built', 'disposed', 'built']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('out of view within the limit keeps what it was built from', (
      tester,
    ) async {
      final NoteCachePool pool = NoteCachePool(maxBytes: 100);
      final NoteCacheScope scope = pool.scope();
      final List<String> log = <String>[];

      await tester.pumpWidget(host(scope, log, shown: true));
      scope.add(page: 'page', bytes: 50, onPop: () => fail('no need'));
      await tester.pumpWidget(host(scope, log, shown: false));
      await tester.pump();
      expect(log, <String>['built']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('coming into view counts as a use of its note', (tester) async {
      final NoteCachePool pool = NoteCachePool(maxBytes: 200);
      final NoteCacheScope shownNote = pool.scope();
      final NoteCacheScope other = pool.scope();
      final List<String> popped = <String>[];

      shownNote.add(page: 'page', bytes: 100, onPop: () => popped.add('shown'));
      other.touch('page');
      other.add(page: 'page', bytes: 100, onPop: () => popped.add('other'));
      // The note was used before the other one, until it comes into view.
      await tester.pumpWidget(host(shownNote, <String>[], shown: true));
      await tester.pumpWidget(host(shownNote, <String>[], shown: false));
      await tester.pumpWidget(host(shownNote, <String>[], shown: true));

      other.add(page: 'more', bytes: 100, onPop: () => popped.add('more'));
      expect(popped, <String>['other']);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('tabs sharing the pool', () {
    Widget app(_Repository repository, OpenNotes tabs, NoteCachePool pool) {
      return GreatnoteApp(
        home: NoteTabsPage(
          notes: tabs,
          builder: (note, bar, back, rename) => NoteEditorPage(
            repository: repository,
            note: note,
            cachePool: pool,
            tabsBuilder: bar,
            onBack: back,
            onRenamed: rename,
          ),
        ),
      );
    }

    testWidgets('within the limit every tab stays warm', (tester) async {
      final _Repository repository = _Repository();
      final OpenNotes tabs = OpenNotes();
      addTearDown(repository.dispose);
      addTearDown(tabs.dispose);
      final NoteCachePool pool = NoteCachePool(maxBytes: 1 << 30);
      final NoteEntry a = await _noteWithInk(repository, 'A');
      final NoteEntry b = await _noteWithInk(repository, 'B');

      tabs.open(a);
      await tester.pumpWidget(app(repository, tabs, pool));
      await _settle(tester);
      tabs.open(b);
      await _settle(tester);

      expect(find.byType(EditorScreen, skipOffstage: false), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      expect(pool.usedBytes, 0, reason: 'closing gives everything back');
    });

    testWidgets('past the limit the tab used longest ago goes cold, and reads '
        'its note again when shown', (tester) async {
      final _Repository repository = _Repository();
      final OpenNotes tabs = OpenNotes();
      addTearDown(repository.dispose);
      addTearDown(tabs.dispose);
      // Room for about one of these notes, not two.
      final NoteCachePool pool = NoteCachePool(maxBytes: 400);
      final NoteEntry a = await _noteWithInk(repository, 'A');
      final NoteEntry b = await _noteWithInk(repository, 'B');

      tabs.open(a);
      await tester.pumpWidget(app(repository, tabs, pool));
      await _settle(tester);
      tabs.open(b);
      await _settle(tester);

      expect(find.byType(EditorScreen, skipOffstage: false), findsOneWidget);
      expect(
        tester.widget<EditorScreen>(find.byType(EditorScreen)).noteId,
        b.id,
      );
      expect(tabs.notes, hasLength(2), reason: 'the tab itself stays');
      expect(pool.usedBytes, lessThanOrEqualTo(400));

      tabs.open(a);
      await _settle(tester);
      expect(
        tester.widget<EditorScreen>(find.byType(EditorScreen)).noteId,
        a.id,
      );
      expect(repository.reads[a.id], 2);
      await tester.pumpWidget(const SizedBox());
      expect(pool.usedBytes, 0);
    });
  });
}
