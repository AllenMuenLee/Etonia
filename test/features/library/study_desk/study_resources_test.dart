import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

NoteEntry _note(String id, {int revision = 1}) => NoteEntry(
  id: id,
  title: id,
  folderId: null,
  created: DateTime(2026),
  modified: DateTime(2026),
  pageCount: 1,
  revision: revision,
);

List<StudyChunk> _chunks(String id, {String text = 'words'}) => [
  StudyChunk(
    noteId: id,
    pageIndex: 0,
    chunkIndex: 1,
    kind: StudyChunkKind.text,
    logicalBounds: const Rect.fromLTWH(0, 0, 20, 20),
    typed: text,
  ),
];

class _ChunkCache implements StudyChunkDiskCache {
  final reads = <(String, int)>[];
  final gates = <(String, int), Completer<List<StudyChunk>?>>{};
  String text = 'words';

  @override
  Future<List<StudyChunk>?> read(String id, int revision) {
    reads.add((id, revision));
    return gates[(id, revision)]?.future ??
        Future.value(_chunks(id, text: text));
  }

  @override
  Future<void> write(String id, int revision, List<StudyChunk> chunks) async {}

  @override
  Future<void> retain(Set<String> ids) async {}
}

class _AnswerClient extends AiClient {
  @override
  bool get isConfigured => true;
  @override
  String get modelLabel => 'Test';
  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
  }) async => request.systemInstruction == AiPrompts.studyTeachingPlannerSystem
      ? const AiSuccess(
          '{"intent":"question","retrieval":{"notes":true,"mistakeIndices":[],"query":"mechanics"}}',
        )
      : const AiSuccess(
          'All four notes [[N1:P1:C1]] [[N2:P1:C1]] [[N3:P1:C1]] [[N4:P1:C1]]',
        );
  @override
  void close() {}
}

class _DelayedRepository extends InMemoryNoteRepository {
  Completer<NoteContent>? gate;

  @override
  Future<NoteContent> loadNote(String id) => gate?.future ?? super.loadNote(id);
}

void main() {
  group('Study resource lifetimes', () {
    late InMemoryNoteRepository repository;
    late _ChunkCache disk;

    setUp(() {
      repository = InMemoryNoteRepository();
      disk = _ChunkCache();
      addTearDown(repository.dispose);
    });

    test(
      'memory pressure prevents pending reads from repopulating caches',
      () async {
        final index = StudyRagIndex(repository: repository, diskCache: disk);
        final gate = disk.gates[('a', 1)] = Completer();
        final pending = index.chunksFor(_note('a'));
        index.releaseMemory();
        gate.complete(_chunks('a'));
        await pending;
        disk.gates.clear();
        await index.chunksFor(_note('a'));
        expect(disk.reads, [('a', 1), ('a', 1)]);
      },
    );

    test('a removed note cannot be cached by a late read', () async {
      final index = StudyRagIndex(repository: repository, diskCache: disk);
      final gate = disk.gates[('a', 1)] = Completer();
      final pending = index.chunksFor(_note('a'));
      await index.retain({});
      gate.complete(_chunks('a'));
      await pending;
      disk.gates.clear();
      await index.chunksFor(_note('a'));
      expect(disk.reads, [('a', 1), ('a', 1)]);
    });

    test(
      'an old revision finishing last cannot replace the new revision',
      () async {
        final index = StudyRagIndex(repository: repository, diskCache: disk);
        final old = disk.gates[('a', 1)] = Completer();
        final pending = index.chunksFor(_note('a'));
        final latest = await index.chunksFor(_note('a', revision: 2));
        old.complete(_chunks('a', text: 'old'));
        await pending;
        expect(await index.chunksFor(_note('a', revision: 2)), same(latest));
        expect(disk.reads, [('a', 1), ('a', 2)]);
      },
    );

    test('simultaneous requests for the same revision share a read', () async {
      final index = StudyRagIndex(repository: repository, diskCache: disk);
      final gate = disk.gates[('a', 1)] = Completer();
      final first = index.chunksFor(_note('a'));
      final second = index.chunksFor(_note('a'));
      gate.complete(_chunks('a'));
      expect(await first, same(await second));
      expect(disk.reads, [('a', 1)]);
    });

    test('LRU eviction preserves recently used chunks', () async {
      final index = StudyRagIndex(
        repository: repository,
        diskCache: disk,
        maxMemoryNotes: 2,
      );
      final a = await index.chunksFor(_note('a'));
      await index.chunksFor(_note('b'));
      expect(await index.chunksFor(_note('a')), same(a));
      await index.chunksFor(_note('c'));
      expect(await index.chunksFor(_note('a')), same(a));
      await index.chunksFor(_note('b'));
      expect(disk.reads, [('a', 1), ('b', 1), ('c', 1), ('b', 1)]);
    });

    test(
      'byte budget evicts entries even below the note count limit',
      () async {
        final oneEntry = estimatedStudyChunkBytes(_chunks('a'));
        final index = StudyRagIndex(
          repository: repository,
          diskCache: disk,
          maxMemoryNotes: 10,
          maxMemoryBytes: oneEntry,
        );
        await index.chunksFor(_note('a'));
        final b = await index.chunksFor(_note('b'));
        expect(await index.chunksFor(_note('b')), same(b));
        await index.chunksFor(_note('a'));
        expect(disk.reads, [('a', 1), ('b', 1), ('a', 1)]);
      },
    );

    test(
      'oversized notes are returned without evicting a small hot note',
      () async {
        final index = StudyRagIndex(
          repository: repository,
          diskCache: disk,
          maxMemoryBytes: 1024,
        );
        final a = await index.chunksFor(_note('a'));
        disk.text = 'large text' * 1000;
        expect((await index.chunksFor(_note('b'))).single.typed, disk.text);
        expect(await index.chunksFor(_note('a')), same(a));
        await index.chunksFor(_note('b'));
        expect(disk.reads, [('a', 1), ('b', 1), ('b', 1)]);
      },
    );

    test('a failed load can be retried', () async {
      final index = StudyRagIndex(repository: repository, diskCache: disk);
      final gate = disk.gates[('a', 1)] = Completer();
      final pending = index.chunksFor(_note('a'));
      final checked = expectLater(pending, throwsStateError);
      gate.completeError(StateError('unavailable'));
      await checked;
      disk.gates.clear();
      expect(await index.chunksFor(_note('a')), isNotEmpty);
      expect(disk.reads, [('a', 1), ('a', 1)]);
    });

    test(
      'resolving four notes keeps every citation across LRU eviction',
      () async {
        final ids = <String>[];
        for (var i = 0; i < 4; i++) {
          final note = await repository.createNote(title: 'Source $i');
          await repository.saveNote(
            note.id,
            NoteContent([
              StoredPage(
                setup: const PageSetup(),
                strokes: const [],
                textElements: [
                  NoteTextElement(
                    id: 'text',
                    position: const InkVector(10, 10),
                    text: 'Mechanics chapter $i',
                  ),
                ],
              ),
            ]),
          );
          ids.add(note.id);
        }
        final desk = StudyDeskController(
          repository: repository,
          client: _AnswerClient(),
        );
        addTearDown(desk.dispose);
        await desk.load();
        desk.addNotes(ids);
        await desk.send('Summarize mechanics', mode: StudyQueryMode.overview);
        expect(
          desk.messages.last.citationsOf(1).map((c) => c.noteId).toSet(),
          ids.toSet(),
        );
      },
    );

    test('disposing a desk invalidates a pending citation page load', () async {
      final delayed = _DelayedRepository();
      addTearDown(delayed.dispose);
      final note = await delayed.createNote(title: 'Source');
      final desk = StudyDeskController(
        repository: delayed,
        client: _AnswerClient(),
      );
      await desk.load();
      final gate = delayed.gate = Completer();
      final pending = desk.pageFor(
        StudyCitation(noteId: note.id, pageIndex: 0, revision: 0),
      );
      desk.dispose();
      gate.complete(
        const NoteContent([StoredPage(setup: PageSetup(), strokes: [])]),
      );
      expect(await pending, isNull);
    });
  });

  group('Study file persistence', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('study_resources_');
      addTearDown(() => directory.delete(recursive: true));
    });

    test(
      'a burst of desk snapshots persists the latest complete snapshot',
      () async {
        final file = File('${directory.path}/desk.json');
        final store = FileStudyDeskStore(file);
        StudyDeskState snapshot(int i) => StudyDeskState(
          sources: [StudySourceItem(noteId: '$i')],
          sessions: [
            StudySession(
              id: '$i',
              created: DateTime(2026),
              messages: [StudyMessage.user('long answer ' * 5000)],
            ),
          ],
          currentSessionId: '$i',
        );
        await Future.wait([
          for (var i = 0; i < 20; i++) store.write(snapshot(i)),
        ]);
        final restored = (await store.read())!;
        expect(restored.currentSessionId, '19');
        expect(restored.sources.single.noteId, '19');
        expect(
          restored.sessions.single.messages.single.text,
          'long answer ' * 5000,
        );
        expect(await File('${file.path}.tmp').exists(), isFalse);
      },
    );

    test(
      'large chunk files round trip with complete model conversion',
      () async {
        final cache = FileStudyChunkCache(directory);
        final chunks = _chunks('a', text: 'recognized words ' * 5000);
        await cache.write('a', 2, chunks);
        final restored = (await cache.read('a', 2))!;
        expect(restored.single.toJson(), chunks.single.toJson());
        expect(await cache.read('a', 1), isNull);
      },
    );

    test(
      'overlapping chunk writes preserve the last requested revision',
      () async {
        final cache = FileStudyChunkCache(directory);
        await Future.wait([
          for (var revision = 1; revision <= 12; revision++)
            cache.write(
              'a',
              revision,
              _chunks('a', text: 'revision $revision ' * 1000),
            ),
        ]);
        expect(
          (await cache.read('a', 12))!.single.typed,
          'revision 12 ' * 1000,
        );
        expect(await File('${directory.path}/a.json.tmp').exists(), isFalse);
      },
    );

    test(
      'pruning waits for an active cache write before deleting it',
      () async {
        final cache = FileStudyChunkCache(directory);
        final writing = cache.write('a', 1, _chunks('a', text: 'large' * 5000));
        await cache.retain({});
        await writing;
        expect(await cache.read('a', 1), isNull);
      },
    );

    test('a failed desk write does not poison later saves', () async {
      final file = File('${directory.path}/missing/desk.json');
      final store = FileStudyDeskStore(file);
      const state = StudyDeskState(
        sources: [],
        sessions: [],
        currentSessionId: 'latest',
      );
      await expectLater(
        store.write(state),
        throwsA(isA<FileSystemException>()),
      );
      await file.parent.create();
      await store.write(state);
      expect((await store.read())!.currentSessionId, 'latest');
    });
  });
}
