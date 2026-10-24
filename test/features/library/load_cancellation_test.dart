import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_thumbnails.dart';

/// A note well past the size read off the UI isolate: [pages] pages of
/// long strokes.
NoteContent _largeNote({int pages = 3}) {
  final Map<String, Object?> page = <String, Object?>{
    'size': 'a4Portrait',
    'background': 'blank',
    'strokes': <Object?>[
      for (int s = 0; s < 120; s++)
        <String, Object?>{
          'ink': 'ink',
          'width': 3,
          'points': <double>[
            for (int p = 0; p < 60; p++) ...<double>[p * 3.25, s * 4.5],
          ],
        },
    ],
  };
  return NoteContent.fromJson(<String, Object?>{
    'schema': storageSchema,
    'pages': <Object?>[for (int i = 0; i < pages; i++) page],
  });
}

class _CountingRepository extends InMemoryNoteRepository {
  int firstPageReads = 0;

  @override
  Future<StoredPage?> readFirstPage(String id) {
    firstPageReads++;
    return super.readFirstPage(id);
  }
}

const ThumbnailStyle _style = ThumbnailStyle(
  brightness: Brightness.light,
  paper: Colors.white,
  rule: Colors.grey,
  marginRule: Colors.red,
);

Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('a large note', () {
    late Directory directory;
    late FileNoteRepository repository;
    late NoteEntry note;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('greatnote-load-');
      repository = await FileNoteRepository.open(directory);
      note = await repository.createNote(title: 'Large');
      await repository.saveNote(note.id, _largeNote());
      final File file = File('${directory.path}/notes/${note.id}.json');
      expect(await file.length(), greaterThan(64 * 1024));
    });

    tearDown(() async {
      repository.dispose();
      await directory.delete(recursive: true);
    });

    test('stops being read once no one waits for it', () async {
      final Future<NoteContent> loading = repository.loadNote(note.id);
      repository.abandonLoad(note.id);
      await expectLater(loading, throwsA(isA<LoadAbandoned>()));

      // Asked for again, it is read afresh, whole.
      final NoteContent again = await repository.loadNote(note.id);
      expect(again.pages, hasLength(3));
      expect(again.pages.first.strokes, hasLength(120));
    });

    test('is still read for whoever else waits on it', () async {
      final Future<NoteContent> first = repository.loadNote(note.id);
      final Future<NoteContent> second = repository.loadNote(note.id);
      repository.abandonLoad(note.id);
      expect((await second).pages, hasLength(3));
      expect((await first).pages, hasLength(3));
    });

    test('gives its first page alone, as the whole note has it', () async {
      final StoredPage? page = await repository.loadFirstPage(note.id);
      final NoteContent whole = await repository.loadNote(note.id);
      expect(page, isNotNull);
      expect(page!.strokes, hasLength(whole.pages.first.strokes.length));
      expect(page.strokes.last.points, whole.pages.first.strokes.last.points);
    });
  });

  testWidgets('thumbnails wait while the user is elsewhere, then draw', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final _CountingRepository repository = _CountingRepository();
      final NoteEntry note = await repository.createNote();
      final ThumbnailCache cache = ThumbnailCache(
        repository: repository,
        rasterizer: const PdfrxRasterizer(),
        pixelWidth: 40,
      );
      cache.pause();
      final image = cache.watch(note, _style);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repository.firstPageReads, 0);
      expect(image.value, isNull);

      cache.resume();
      await _until(() => image.value != null);
      expect(image.value, isNotNull);
      expect(repository.firstPageReads, 1);
      cache.dispose();
      repository.dispose();
    });
  });

  testWidgets('a picture let go mid-draw is drawn when next asked for', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final _CountingRepository repository = _CountingRepository();
      final NoteEntry note = await repository.createNote();
      final ThumbnailCache cache = ThumbnailCache(
        repository: repository,
        rasterizer: const PdfrxRasterizer(),
        pixelWidth: 40,
      );
      final image = cache.watch(note, _style);
      // As when another folder is opened before it is drawn.
      cache.cancelPending();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final again = cache.watch(note, _style);
      await _until(() => again.value != null);
      expect(identical(image, again), isTrue);
      final ui.Image? drawn = again.value?.image;
      expect(drawn, isNotNull);
      cache.dispose();
      repository.dispose();
    });
  });
}
