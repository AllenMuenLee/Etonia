import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_thumbnails.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/library_models.dart';

void main() {
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
        final note = await first.createNote();
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
        cache.dispose();
        first.dispose();

        // If the cache misses, loading the note now fails. The exact disk
        // thumbnail remains keyed by the index's modified timestamp.
        await File('${directory.path}/notes/${note.id}.json').delete();
        final FileNoteRepository reopened = await FileNoteRepository.open(
          directory,
        );
        final NoteEntry indexed = (await reopened.list(null)).notes.single;
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
