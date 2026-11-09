import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_source_picker.dart';
import 'package:greatnote/features/library/study_desk/study_vectors.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/pump_app.dart';

const int _dims = BackendStudyEmbedder.dimensions;

Float32List _axis(int axis) => Float32List(_dims)..[axis] = 1;

/// Puts anything about circuits on one axis, anything about transforms on
/// another, and the question about "digital" next to the circuits.
class _Embedder implements StudyEmbedder {
  bool available = true;
  final List<String> queries = <String>[];

  /// Every chunk text ever sent to be embedded.
  final List<String> embedded = <String>[];

  Float32List _of(String text) {
    final String t = text.toLowerCase();
    if (t.contains('flip') || t.contains('digital')) return _axis(0);
    return _axis(1);
  }

  @override
  bool get isAvailable => available;

  @override
  Future<List<Float32List?>> embedTexts(List<String> texts) async {
    embedded.addAll(texts);
    return [for (final String t in texts) _of(t)];
  }

  @override
  Future<List<Float32List?>> embedImages(List<Uint8List> pngs) async => [
    for (final _ in pngs) null,
  ];

  @override
  Future<Float32List?> embedQuery(String text) async {
    queries.add(text);
    return _of(text);
  }
}

class _MemoryVectors implements StudyVectorDiskCache {
  @override
  Future<Map<String, StudyChunkVectors>> read(String noteId) async => {};
  @override
  Future<void> write(String noteId, Map<String, StudyChunkVectors> v) async {}
  @override
  Future<void> retain(Set<String> noteIds) async {}
}

Future<NoteEntry> _noteWith(
  InMemoryNoteRepository repository,
  String title,
  String text,
) async {
  final NoteEntry note = await repository.createNote(title: title);
  return repository.saveNote(
    note.id,
    NoteContent([
      StoredPage(
        setup: const PageSetup(),
        strokes: const [],
        textElements: [
          NoteTextElement(
            id: 'text',
            position: const InkVector(30, 40),
            text: text,
          ),
        ],
      ),
    ]),
  );
}

Future<String> _asked(StudyEmbedder? embedder, String question) async {
  final InMemoryNoteRepository repository = InMemoryNoteRepository();
  final FakeAiClient client = FakeAiClient();
  final NoteEntry circuits = await _noteWith(
    repository,
    'Lecture 3',
    'A JK flip flop toggles on the clock edge. A counter chains flip flops.',
  );
  final NoteEntry laplace = await _noteWith(
    repository,
    'Lecture 9',
    'The Laplace transform turns linear systems into algebra. A transfer '
        'function describes how systems respond.',
  );
  final StudyDeskController desk = StudyDeskController(
    repository: repository,
    client: client,
    embedder: embedder,
    vectorCache: _MemoryVectors(),
  );
  addTearDown(() {
    desk.dispose();
    repository.dispose();
    client.close();
  });
  await desk.load();
  desk.addNotes([circuits.id, laplace.id]);
  final Future<void> sent = desk.send(question);
  for (int i = 0; i < 50 && client.requests.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final String text = client.requests.last.messages.last.text;
  client.answer('ok');
  await sent;
  return text;
}

void main() {
  test(
    'by words alone, "digital systems" is answered from Laplace notes',
    () async {
      final String text = await _asked(null, 'explain digital systems');
      expect(text, contains('Laplace'));
      expect(text, isNot(contains('flip flop')));
    },
  );

  test('with meaning, it is answered from the notes it is about', () async {
    final _Embedder embedder = _Embedder();
    final String text = await _asked(embedder, 'explain digital systems');
    expect(text, contains('flip flop'));
    expect(text, isNot(contains('Laplace')));
    expect(embedder.queries, isNotEmpty);
  });

  test('an unavailable embedder leaves search as it was', () async {
    final _Embedder embedder = _Embedder()..available = false;
    final String text = await _asked(embedder, 'explain digital systems');
    expect(text, contains('Laplace'));
    expect(embedder.queries, isEmpty);
  });

  test('turned off, nothing is embedded and nothing is sent', () async {
    final _Embedder embedder = _Embedder();
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    final FakeAiClient client = FakeAiClient();
    final NoteEntry note = await _noteWith(
      repository,
      'Lecture 3',
      'flip flop',
    );
    final StudyDeskController desk = StudyDeskController(
      repository: repository,
      client: client,
      embedder: embedder,
      vectorCache: _MemoryVectors(),
    );
    addTearDown(() {
      desk.dispose();
      repository.dispose();
    });
    await desk.load();
    desk.semanticSearch = false;
    desk.addNotes([note.id]);
    final Future<void> sent = desk.send('flip flop');
    for (int i = 0; i < 50 && client.requests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    client.answer('ok');
    await sent;
    expect(embedder.queries, isEmpty);
  });

  test('with no notes on the desk, nothing is embedded', () async {
    final _Embedder embedder = _Embedder();
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    final FakeAiClient client = FakeAiClient();
    await _noteWith(repository, 'Lecture 3', 'flip flop');
    final StudyDeskController desk = StudyDeskController(
      repository: repository,
      client: client,
      embedder: embedder,
      vectorCache: _MemoryVectors(),
    );
    addTearDown(() {
      desk.dispose();
      repository.dispose();
    });
    await desk.load();
    final Future<void> sent = desk.send('flip flop');
    for (int i = 0; i < 50 && client.requests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    client.answer('ok');
    await sent;
    expect(embedder.queries, isEmpty);
  });

  group('the open note, asked about by the editor', () {
    Future<
      ({
        StudyDeskController desk,
        InMemoryNoteRepository repository,
        FakeAiClient client,
        NoteEntry circuits,
        NoteEntry laplace,
      })
    >
    open(StudyEmbedder? embedder) async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      final FakeAiClient client = FakeAiClient();
      final NoteEntry circuits = await _noteWith(
        repository,
        'Lecture 3',
        'A JK flip flop toggles on the clock edge. A counter chains flip '
            'flops.',
      );
      final NoteEntry laplace = await _noteWith(
        repository,
        'Lecture 9',
        'The Laplace transform turns linear systems into algebra.',
      );
      final StudyDeskController desk = StudyDeskController(
        repository: repository,
        client: client,
        embedder: embedder,
        vectorCache: _MemoryVectors(),
      );
      addTearDown(() {
        desk.dispose();
        repository.dispose();
        client.close();
      });
      await desk.load();
      return (
        desk: desk,
        repository: repository,
        client: client,
        circuits: circuits,
        laplace: laplace,
      );
    }

    test('are found by meaning, with nothing on the desk, in that note '
        'alone', () async {
      final _Embedder embedder = _Embedder();
      final rig = await open(embedder);

      final String? found = await rig.desk.excerptsOfNote(
        rig.circuits.id,
        'explain digital systems',
      );

      expect(found, contains('flip flop'));
      expect(found, isNot(contains('Laplace')));
      expect(embedder.queries, isNotEmpty);
      // Only the open note was sent to be embedded.
      expect(embedder.embedded, hasLength(1));
      expect(embedder.embedded.single, contains('flip flop'));
    });

    test('share the desk\'s vectors: nothing is embedded twice', () async {
      final _Embedder embedder = _Embedder();
      final rig = await open(embedder);

      await rig.desk.excerptsOfNote(rig.circuits.id, 'explain digital systems');
      final int afterEditor = embedder.embedded.length;
      expect(afterEditor, 1);

      // The desk asks about the same note: its chunk is already known.
      rig.desk.addNotes(<String>[rig.circuits.id]);
      final Future<void> sent = rig.desk.send('explain digital systems');
      for (int i = 0; i < 50 && rig.client.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      rig.client.answer('ok');
      await sent;
      expect(embedder.embedded, hasLength(afterEditor));

      // And the editor again, after the desk: still nothing new.
      await rig.desk.excerptsOfNote(rig.circuits.id, 'what toggles?');
      expect(embedder.embedded, hasLength(afterEditor));
    });

    test('turned off, are found by words and nothing is sent', () async {
      final _Embedder embedder = _Embedder();
      final rig = await open(embedder);
      rig.desk.semanticSearch = false;

      final String? found = await rig.desk.excerptsOfNote(
        rig.circuits.id,
        'flip flop',
      );

      expect(found, contains('flip flop'));
      expect(embedder.queries, isEmpty);
      expect(embedder.embedded, isEmpty);
    });

    test('are found by words when meaning is unavailable', () async {
      final _Embedder embedder = _Embedder()..available = false;
      final rig = await open(embedder);

      final String? found = await rig.desk.excerptsOfNote(
        rig.circuits.id,
        'flip flop',
      );

      expect(found, contains('flip flop'));
      expect(embedder.embedded, isEmpty);
    });
  });

  testWidgets(
    'the picker offers the switch only where it can work, and it sticks',
    (tester) async {
      setViewportSize(tester, const Size(800, 1000));
      final InMemoryStudyDeskStore store = InMemoryStudyDeskStore();
      Future<StudyDeskController> desk(StudyEmbedder? embedder) async {
        final InMemoryNoteRepository repository = InMemoryNoteRepository();
        await _noteWith(repository, 'Lecture 3', 'flip flop');
        final StudyDeskController controller = StudyDeskController(
          repository: repository,
          client: FakeAiClient(),
          store: store,
          embedder: embedder,
          vectorCache: _MemoryVectors(),
        );
        addTearDown(() {
          controller.dispose();
          repository.dispose();
        });
        await controller.load();
        return controller;
      }

      Future<void> open(StudyDeskController controller) async {
        await tester.pumpWidget(
          GreatnoteApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showStudySourcePicker(context, controller: controller),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      final StudyDeskController without = await desk(null);
      await open(without);
      expect(find.byKey(const ValueKey('study-semantic-search')), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      final StudyDeskController with_ = await desk(_Embedder());
      await open(with_);
      final Finder switchTile = find.byKey(
        const ValueKey('study-semantic-search'),
      );
      expect(switchTile, findsOneWidget);
      expect(with_.semanticSearch, isTrue);
      await tester.tap(switchTile);
      await tester.pumpAndSettle();
      expect(with_.semanticSearch, isFalse);
      await tester.pump(const Duration(milliseconds: 10));
      expect((await store.read())!.semanticSearch, isFalse);

      // It is remembered by the next desk.
      final StudyDeskController again = await desk(_Embedder());
      expect(again.semanticSearch, isFalse);
    },
  );
}
