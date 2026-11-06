import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../file_note_repository.dart';
import '../../note_repository.dart';
import 'study_practice_models.dart';
import 'study_mistakes.dart';

/// Where practice sets are kept between launches. Each change runs after the
/// last has finished, so two made at once cannot lose one another.
abstract class StudyPracticeStore {
  Future<void> _queue = Future<void>.value();
  List<StudyTestPaper>? _papers;
  List<StudyMistake> _mistakes = const [];

  Future<List<StudyMistake>> loadMistakes() => _enqueue(_readMistakes);

  Future<List<StudyMistake>> _readMistakes() async {
    final kept = await readMistakes();
    final found = [
      for (final paper in await readPapers() ?? <StudyTestPaper>[])
        ...StudyMistake.fromPaper(paper),
      for (final set in await read()) ...StudyMistake.fromSet(set),
    ];
    return _keepMistakes(kept, found);
  }

  Future<List<StudyMistake>> _keepMistakes(
    List<StudyMistake> kept,
    Iterable<StudyMistake> found,
  ) async {
    String fingerprint(StudyMistake m) =>
        jsonEncode([m.sourceId, m.question.id, m.question.toJson()]);
    final fingerprints = kept.map(fingerprint).toSet();
    final merged = [...kept];
    for (final mistake in found) {
      if (fingerprints.add(fingerprint(mistake))) merged.add(mistake);
    }
    if (merged.length != kept.length) await writeMistakes(merged);
    return List<StudyMistake>.unmodifiable(merged);
  }

  Future<List<StudyMistake>> readMistakes() async => _mistakes;
  Future<void> writeMistakes(List<StudyMistake> mistakes) async =>
      _mistakes = List<StudyMistake>.unmodifiable(mistakes);

  Future<List<StudyFlashcardDeck>> loadDecks() async => [
    for (final set in await loadSets())
      if (set.flashcards.isNotEmpty) StudyFlashcardDeck.fromSet(set),
  ];

  Future<void> saveDeck(StudyFlashcardDeck deck) => _change((sets) {
    final at = sets.indexWhere((s) => s.id == deck.id);
    if (at < 0) {
      sets.add(deck.toSet());
    } else {
      sets[at] = sets[at].copyWith(
        title: deck.title,
        updatedAt: deck.updatedAt,
        flashcards: deck.flashcards,
      );
    }
  });

  Future<List<StudyTestPaper>> loadPapers() => _enqueue(_readPapers);

  Future<List<StudyTestPaper>> _readPapers() async {
    final stored = await readPapers();
    if (stored != null) return stored;
    final migrated = [
      for (final set in await read())
        if (set.multipleChoiceQuestions.isNotEmpty)
          StudyTestPaper.fromLegacy(set),
    ];
    await writePapers(migrated);
    return migrated;
  }

  Future<void> savePaper(StudyTestPaper paper) => _enqueue(() async {
    await _keepMistakes(await _readMistakes(), StudyMistake.fromPaper(paper));
    final papers = [...await _readPapers()];
    final at = papers.indexWhere((p) => p.id == paper.id);
    if (at < 0) {
      papers.add(paper);
    } else {
      papers[at] = paper;
    }
    await writePapers(papers);
  });

  Future<void> deletePaper(String id) => _enqueue(() async {
    await _readMistakes();
    final papers = [...await _readPapers()]..removeWhere((p) => p.id == id);
    await writePapers(papers);
  });

  Future<List<StudyTestPaper>?> readPapers() async => _papers;
  Future<void> writePapers(List<StudyTestPaper> papers) async =>
      _papers = papers;

  /// Every set, as last written; none when nothing was.
  Future<List<StudyPracticeSet>> loadSets() => _enqueue(read);

  /// Adds [set], or replaces the set with its id.
  Future<void> saveSet(StudyPracticeSet set) =>
      _change((List<StudyPracticeSet> sets) {
        final int at = sets.indexWhere(
          (StudyPracticeSet kept) => kept.id == set.id,
        );
        if (at < 0) {
          sets.add(set);
        } else {
          sets[at] = set;
        }
      });

  /// Replaces the set with [set]'s id. A set since deleted stays deleted.
  Future<void> updateSet(StudyPracticeSet set) =>
      _change((List<StudyPracticeSet> sets) {
        final int at = sets.indexWhere(
          (StudyPracticeSet kept) => kept.id == set.id,
        );
        if (at >= 0) sets[at] = set;
      });

  Future<void> deleteSet(String id) => _change(
    (List<StudyPracticeSet> sets) =>
        sets.removeWhere((StudyPracticeSet set) => set.id == id),
  );

  Future<void> _change(void Function(List<StudyPracticeSet> sets) change) =>
      _enqueue(() async {
        final mistakes = await _readMistakes();
        final List<StudyPracticeSet> sets = List<StudyPracticeSet>.of(
          await read(),
        );
        change(sets);
        await _keepMistakes(mistakes, [
          for (final set in sets) ...StudyMistake.fromSet(set),
        ]);
        await write(sets);
      });

  Future<T> _enqueue<T>(Future<T> Function() work) {
    final Future<T> done = _queue.then((void _) => work());
    _queue = done.then((T _) {}, onError: (Object _) {});
    return done;
  }

  Future<List<StudyPracticeSet>> read();
  Future<void> write(List<StudyPracticeSet> sets);
}

/// Keeps practice sets for as long as the app runs, for a library in memory.
class InMemoryStudyPracticeStore extends StudyPracticeStore {
  List<StudyPracticeSet> _sets = const <StudyPracticeSet>[];

  @override
  Future<List<StudyPracticeSet>> read() async => _sets;

  @override
  Future<void> write(List<StudyPracticeSet> sets) async => _sets = sets;
}

/// Keeps practice sets in `<libraryDir>/study_practice_sets.json`. Written to a
/// temporary file and renamed over the old one, so a crash leaves one or the
/// other whole.
class FileStudyPracticeStore extends StudyPracticeStore {
  FileStudyPracticeStore(this.file);

  final File file;

  File get paperFile => File('${file.path}.papers.json');
  File get mistakeFile => File('${file.path}.mistakes.json');

  @override
  Future<List<StudyMistake>> readMistakes() async {
    if (!await mistakeFile.exists()) return const [];
    final json = jsonDecode(await mistakeFile.readAsString()) as Map;
    return [
      for (final raw in json['mistakes']! as List)
        StudyMistake.fromJson(Map<String, Object?>.from(raw as Map)),
    ];
  }

  @override
  Future<void> writeMistakes(List<StudyMistake> mistakes) async {
    await file.parent.create(recursive: true);
    final temporary = File('${mistakeFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 1,
        'mistakes': [for (final mistake in mistakes) mistake.toJson()],
      }),
      flush: true,
    );
    await temporary.rename(mistakeFile.path);
  }

  @override
  Future<List<StudyTestPaper>?> readPapers() async {
    if (!await paperFile.exists()) return null;
    // A failed read propagates; never overwrite an unreadable exam or its ink.
    final json =
        jsonDecode(await paperFile.readAsString()) as Map<String, Object?>;
    return [
      for (final raw in json['papers']! as List)
        StudyTestPaper.fromJson(Map<String, Object?>.from(raw as Map)),
    ];
  }

  @override
  Future<void> writePapers(List<StudyTestPaper> papers) async {
    await file.parent.create(recursive: true);
    final temporary = File('${paperFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema': 2,
        'papers': papers.map((p) => p.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(paperFile.path);
  }

  @override
  Future<List<StudyPracticeSet>> read() async {
    if (!await file.exists()) return const <StudyPracticeSet>[];
    try {
      final Object? json = jsonDecode(await file.readAsString());
      return <StudyPracticeSet>[
        for (final Object? set
            in (json! as Map<String, Object?>)['sets']! as List)
          StudyPracticeSet.fromJson(set! as Map<String, Object?>),
      ];
    } on Object {
      // Sets cannot be made again for free, so a file that cannot be read is
      // moved aside rather than overwritten by the next change.
      try {
        await file.rename('${file.path}.damaged');
      } on Object {
        // It stays where it is, and is read as nothing.
      }
      return const <StudyPracticeSet>[];
    }
  }

  @override
  Future<void> write(List<StudyPracticeSet> sets) async {
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'sets': <Object?>[
          for (final StudyPracticeSet set in sets) set.toJson(),
        ],
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

/// Where the practice sets of [repository] are kept: beside the device's
/// library, or in memory for any other.
StudyPracticeStore studyPracticeStoreFor(NoteRepository repository) =>
    switch (repository) {
      final FileNoteRepository files => FileStudyPracticeStore(
        File('${files.directory.path}/study_practice_sets.json'),
      ),
      _ => InMemoryStudyPracticeStore(),
    };
