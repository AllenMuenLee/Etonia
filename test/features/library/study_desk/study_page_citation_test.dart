import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

void main() {
  const paper = Rect.fromLTWH(0, 0, 600, 900);
  const page = StoredPage(
    setup: PageSetup(),
    strokes: [],
    pdfSource: PdfPageSource(
      assetId: 'pdf',
      pageIndex: 0,
      pageSize: Size(600, 900),
    ),
  );

  StudyCitation resolve(String tag, {Rect region = paper}) {
    final chunk = StudyChunk(
      noteId: 'book',
      pageIndex: 0,
      chunkIndex: 1,
      kind: StudyChunkKind.diagram,
      logicalBounds: region,
      otherBounds: region,
    );
    return StudyCitationResolver(
      map: StudySourceMap(
        noteIds: const {1: 'book'},
        chunks: [chunk],
        crops: {chunk: region},
      ),
      pageOf: (_, _) => page,
      revisionOf: (_) => 1,
    ).resolve('A source. $tag').single.citations.single;
  }

  test('a scanned page citation opens the page without a circle', () {
    final citation = resolve('[[N1:P1:C1]]');
    expect(citation.pageIndex, 0);
    expect(citation.bounds, paper);
    expect(citation.rings, isEmpty);
  });

  test('an explicit box covering the whole page is also suppressed', () {
    expect(resolve('[[N1:P1:C1 0 0 1000 1000]]').rings, isEmpty);
  });

  test('a slightly inset whole-page box does not circle the page', () {
    expect(resolve('[[N1:P1:C1 25 25 975 975]]').rings, isEmpty);
  });

  test('a detail of a scanned page still has a circle', () {
    expect(resolve('[[N1:P1:C1 100 200 300 400]]').rings, [
      const Rect.fromLTRB(120, 90, 240, 270),
    ]);
  });

  test('a whole small crop is a detail of the page', () {
    const figure = Rect.fromLTWH(50, 100, 200, 150);
    expect(resolve('[[N1:P1:C1]]', region: figure).rings, [figure]);
  });

  test('a wide text line remains circled', () {
    const line = Rect.fromLTWH(10, 100, 580, 25);
    expect(resolve('[[N1:P1:C1]]', region: line).rings, [line]);
  });

  test('old saved citations filter only page-sized rings in the preview', () {
    const detail = Rect.fromLTWH(100, 200, 50, 50);
    final citation = StudyCitation.fromJson(
      const StudyCitation(
        noteId: 'book',
        pageIndex: 0,
        revision: 1,
        rings: [paper, detail],
      ).toJson(),
    );
    expect(citation.ringsOn(page), [detail]);
  });
}
