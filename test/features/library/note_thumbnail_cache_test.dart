import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/note_thumbnails.dart';

void main() {
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
