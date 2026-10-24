import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_thumbnails.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_content.dart';

void main() {
  testWidgets('prefetch draws a folder\'s pictures before any card asks', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final repository = InMemoryNoteRepository();
      final notes = <NoteEntry>[
        for (int i = 0; i < 6; i++) await repository.createNote(),
      ];
      final cache = ThumbnailCache(
        repository: repository,
        rasterizer: const PdfrxRasterizer(),
        pixelWidth: 40,
        prefetchLimit: 4,
      );
      const style = ThumbnailStyle(
        brightness: Brightness.light,
        paper: Colors.white,
        rule: Colors.grey,
        marginRule: Colors.red,
      );
      cache.prefetch(notes, style);
      // Past the limit: not drawn until a card asks.
      final late = cache.watch(notes[5], style);
      for (int i = 0; i < 200 && late.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(late.value, isNotNull);
      for (final NoteEntry note in notes.take(4)) {
        final picture = cache.watch(note, style);
        for (int i = 0; i < 200 && picture.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(picture.value, isNotNull);
      }
      cache.dispose();
      repository.dispose();
    });
  });

  testWidgets('a reopened file library serves its persistent thumbnail', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'greatnote-thumbnail-',
      );
      try {
        final FileNoteRepository first = await FileNoteRepository.open(
          directory,
        );
        final created = await first.createNote();
        // Saved, as from the editor: its time in memory is finer than the
        // index stores.
        final note = await first.saveNote(created.id, NoteContent.blank());
        const style = ThumbnailStyle(
          brightness: Brightness.light,
          paper: Colors.white,
          rule: Colors.grey,
          marginRule: Colors.red,
        );
        final ThumbnailCache cache = ThumbnailCache(
          repository: first,
          rasterizer: const PdfrxRasterizer(),
          pixelWidth: 40,
        );
        final image = cache.watch(note, style);
        for (int i = 0; i < 200 && image.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(image.value, isNotNull);
        // The picture is shown before it is saved.
        await cache.settleWrites();
        cache.dispose();
        first.dispose();

        // If the cache misses, drawing the note now fails: the picture on
        // disk must be found by the entry as the index reads it back.
        await File(
          '${directory.path}/notes/${note.id}.json',
        ).writeAsString('not a note');
        final FileNoteRepository reopened = await FileNoteRepository.open(
          directory,
        );
        final NoteEntry indexed = (await reopened.list(null)).notes.single;
        expect(indexed.revision, note.revision);
        final ThumbnailCache cold = ThumbnailCache(
          repository: reopened,
          rasterizer: const PdfrxRasterizer(),
          pixelWidth: 40,
        );
        final cached = cold.watch(indexed, style);
        for (int i = 0; i < 200 && cached.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(cached.value, isNotNull);
        cold.dispose();
        reopened.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets(
    'a note saved from the editor is pictured from memory once shown, and stored',
    (tester) async {
      await tester.runAsync(() async {
        final Directory directory = await Directory.systemTemp.createTemp(
          'greatnote-thumbnail-',
        );
        try {
          final FileNoteRepository repository = await FileNoteRepository.open(
            directory,
          );
          final note = await repository.createNote();
          const style = ThumbnailStyle(
            brightness: Brightness.light,
            paper: Colors.white,
            rule: Colors.grey,
            marginRule: Colors.red,
          );
          final ThumbnailCache cache = ThumbnailCache(
            repository: repository,
            rasterizer: const PdfrxRasterizer(),
            pixelWidth: 40,
          );
          final shown = cache.watch(note, style);
          for (int i = 0; i < 200 && shown.value == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await cache.settleWrites();

          // The note is in front: saves are only kept.
          cache.pause();
          final NoteContent content = NoteContent.blank();
          final NoteEntry saved = await repository.saveNote(note.id, content);
          cache.capture(saved, content.pages.first);
          // Reading the note back now fails: the picture must come from
          // the page handed over.
          await File(
            '${directory.path}/notes/${note.id}.json',
          ).writeAsString('not a note');
          final NoteThumbnailImage? before = shown.value;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(shown.value, same(before));

          cache.resume();
          for (int i = 0; i < 200 && identical(shown.value, before); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(shown.value, isNot(same(before)));
          await cache.settleWrites();
          expect(
            await repository.readThumbnail(note.id, 'r${saved.revision}_light'),
            isNotNull,
          );
          cache.dispose();
          repository.dispose();
        } finally {
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('a rename keeps the picture: only saved pages redraw it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final repository = InMemoryNoteRepository();
      final note = await repository.createNote();
      final cache = ThumbnailCache(
        repository: repository,
        rasterizer: const PdfrxRasterizer(),
        pixelWidth: 40,
      );
      const style = ThumbnailStyle(
        brightness: Brightness.light,
        paper: Colors.white,
        rule: Colors.grey,
        marginRule: Colors.red,
      );
      final shown = cache.watch(note, style);
      for (int i = 0; i < 200 && shown.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final NoteThumbnailImage? drawn = shown.value;
      expect(drawn, isNotNull);

      await repository.renameNote(note.id, 'Renamed');
      final NoteEntry renamed = (await repository.list(null)).notes.single;
      expect(renamed.modified, isNot(note.modified));
      expect(cache.peek(renamed, Brightness.light), same(drawn));
      cache.watch(renamed, style);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(shown.value, same(drawn));

      final NoteEntry saved = await repository.saveNote(
        note.id,
        NoteContent.blank(),
      );
      expect(saved.revision, renamed.revision + 1);
      expect(cache.peek(saved, Brightness.light), isNull);
      cache.dispose();
      repository.dispose();
    });
  });

  test('every note is listed, in any folder', () async {
    final repository = InMemoryNoteRepository();
    final folder = await repository.createFolder('Inside');
    final top = await repository.createNote();
    final inside = await repository.createNote(folderId: folder.id);
    expect(
      (await repository.allNotes()).map((NoteEntry note) => note.id),
      unorderedEquals(<String>[top.id, inside.id]),
    );
    repository.dispose();
  });

  testWidgets(
    'thumbnail byte eviction releases owners and preserves visible clones',
    (tester) async {
      await tester.runAsync(() async {
        final repository = InMemoryNoteRepository();
        final a = await repository.createNote();
        final b = await repository.createNote();
        final cache = ThumbnailCache(
          repository: repository,
          rasterizer: const PdfrxRasterizer(),
          pixelWidth: 40,
          // Room for one 40 px wide portrait page, not two.
          maxBytes: 12000,
        );
        const style = ThumbnailStyle(
          brightness: Brightness.light,
          paper: Colors.white,
          rule: Colors.grey,
          marginRule: Colors.red,
        );
        final first = cache.watch(a, style);
        for (var i = 0; i < 100 && first.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final owner = first.value!;
        final int one = owner.image.width * owner.image.height * 4;
        expect(one, lessThanOrEqualTo(12000));
        expect(2 * one, greaterThan(12000));
        final visible = owner.clone();
        final second = cache.watch(b, style);
        for (var i = 0; i < 100 && second.value == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(cache.retainedBytes, lessThanOrEqualTo(12000));
        expect(owner.image.debugDisposed, isTrue);
        expect(visible.image.debugDisposed, isFalse);
        expect(cache.peek(a, Brightness.light), isNull);
        expect(cache.peek(b, Brightness.dark), isNull);
        final last = second.value!;
        cache.dispose();
        expect(last.image.debugDisposed, isTrue);
        visible.dispose();
        repository.dispose();
      });
    },
  );
}
