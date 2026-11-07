import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/backend/backend_service.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';
import 'package:greatnote/features/library/study_desk/study_vectors.dart';

const int _dims = BackendStudyEmbedder.dimensions;

/// A unit vector that points along axis [axis], a little towards [other].
Float32List _vec(int axis, {int? other, double mix = 0}) {
  final Float32List v = Float32List(_dims);
  v[axis] = 1;
  if (other != null) v[other] = mix;
  return v;
}

StudyChunk _chunk(
  String note,
  int index, {
  String words = '',
  StudyChunkKind kind = StudyChunkKind.text,
  int page = 0,
}) => StudyChunk(
  noteId: note,
  pageIndex: page,
  chunkIndex: index,
  kind: kind,
  logicalBounds: Rect.fromLTWH(0, index * 100.0, 300, 90),
  handwriting: words,
);

StudySearchDocument _doc(StudyChunk chunk, String title) =>
    StudySearchDocument(chunk: chunk, noteTitle: title);

class _Embedder implements StudyEmbedder {
  _Embedder({this.available = true});

  bool available;
  final List<List<String>> textCalls = <List<String>>[];
  final List<int> imageCalls = <int>[];
  final List<String> queries = <String>[];
  Float32List? queryVector;
  Completer<void>? gate;
  int _next = 0;

  @override
  bool get isAvailable => available;

  @override
  Future<List<Float32List?>> embedTexts(List<String> texts) async {
    textCalls.add(texts);
    await gate?.future;
    return <Float32List?>[for (final _ in texts) _vec(_next++ % _dims)];
  }

  @override
  Future<List<Float32List?>> embedImages(List<Uint8List> pngs) async {
    imageCalls.add(pngs.length);
    return <Float32List?>[for (final _ in pngs) _vec(_next++ % _dims)];
  }

  @override
  Future<Float32List?> embedQuery(String text) async {
    queries.add(text);
    await gate?.future;
    return queryVector;
  }
}

class _Cache implements StudyVectorDiskCache {
  final Map<String, Map<String, StudyChunkVectors>> files = {};
  Set<String>? kept;

  @override
  Future<Map<String, StudyChunkVectors>> read(String noteId) async =>
      Map<String, StudyChunkVectors>.of(files[noteId] ?? const {});

  @override
  Future<void> write(
    String noteId,
    Map<String, StudyChunkVectors> vectors,
  ) async => files[noteId] = vectors;

  @override
  Future<void> retain(Set<String> noteIds) async => kept = noteIds;
}

class _Renderer implements StudyChunkRenderer {
  int drawn = 0;
  bool fail = false;

  @override
  Future<StudyCrop?> render(StudyChunk chunk) async {
    drawn++;
    if (fail) return null;
    return StudyCrop(
      chunk: chunk,
      png: Uint8List.fromList(<int>[1, 2, 3]),
      logicalBounds: chunk.logicalBounds,
    );
  }

  @override
  Future<Uint8List> combine(List<StudyCrop> crops) async => Uint8List(0);
}

void main() {
  test('a chunk is named by what it holds, not by where it sits', () {
    final StudyChunk a = _chunk('n', 1, words: 'flip flop');
    final StudyChunk moved = StudyChunk(
      noteId: 'n',
      pageIndex: 7,
      chunkIndex: 9,
      kind: StudyChunkKind.text,
      logicalBounds: a.logicalBounds,
      handwriting: 'flip flop',
    );
    expect(studyChunkKey(moved), studyChunkKey(a));
    expect(
      studyChunkKey(_chunk('n', 1, words: 'flip flap')),
      isNot(studyChunkKey(a)),
    );
  });

  test('vectors survive being kept, and bad ones are refused', () {
    final Float32List v = _vec(3, other: 5, mix: .25);
    final Float32List? back = decodeStudyVector(
      encodeStudyVector(v),
      dimensions: _dims,
    );
    expect(back, v);
    expect(decodeStudyVector(encodeStudyVector(v), dimensions: 10), isNull);
    expect(decodeStudyVector('not base64!', dimensions: _dims), isNull);
    expect(decodeStudyVector(base64Encode([1, 2, 3])), isNull);
    expect(studyCosine(_vec(0), _vec(0)), closeTo(1, 1e-9));
    expect(studyCosine(_vec(0), _vec(1)), 0);
    expect(studyCosine(_vec(0), Float32List(_dims)), 0);
  });

  group('BackendStudyEmbedder', () {
    String vectorJson(int axis) => encodeStudyVector(_vec(axis));

    test('sends sixteen at a time and reads each vector back', () async {
      final List<Map<String, Object?>> bodies = [];
      final BackendStudyEmbedder embedder = BackendStudyEmbedder(
        invoke: (String name, Map<String, Object?> body) async {
          expect(name, 'embed');
          bodies.add(body);
          final int count = (body['inputs']! as List).length;
          return <String, dynamic>{
            'embeddings': [for (int i = 0; i < count; i++) vectorJson(i)],
          };
        },
      );
      final List<Float32List?> out = await embedder.embedTexts(<String>[
        for (int i = 0; i < 20; i++) 'text $i',
      ]);
      expect(bodies.length, 2);
      expect((bodies.first['inputs']! as List).length, 16);
      expect(bodies.first['kind'], 'document');
      expect(bodies.first['requestId'], isNot(bodies.last['requestId']));
      expect(out.length, 20);
      expect(out[3], _vec(3));
      expect(out[16], _vec(0));
    });

    test('a failure is a missing vector, never an error', () async {
      final BackendStudyEmbedder embedder = BackendStudyEmbedder(
        invoke: (_, _) async => throw StateError('network'),
      );
      expect(await embedder.embedTexts(<String>['a', 'b']), [null, null]);
      expect(await embedder.embedQuery('q'), isNull);
      // A wrong count, or a wrong size, is not trusted either.
      final BackendStudyEmbedder odd = BackendStudyEmbedder(
        invoke: (_, _) async => <String, dynamic>{
          'embeddings': [encodeStudyVector(Float32List(3))],
        },
      );
      expect(await odd.embedTexts(<String>['a']), [null]);
    });

    test('with no credit it stops asking, for a while', () async {
      int calls = 0;
      DateTime now = DateTime(2026, 11, 7);
      final BackendStudyEmbedder embedder = BackendStudyEmbedder(
        invoke: (_, _) async {
          calls++;
          throw const BackendFailure('insufficient_credits');
        },
      )..clock = (() => now);
      await embedder.embedTexts(<String>[for (int i = 0; i < 40; i++) 'x$i']);
      expect(calls, 1);
      await embedder.embedQuery('again');
      expect(calls, 1);
      now = now.add(const Duration(minutes: 11));
      await embedder.embedQuery('later');
      expect(calls, 2);
    });
  });

  group('StudyVectorIndex', () {
    test(
      'concurrent searches share provider work and partial indexing preserves the cache',
      () async {
        final embedder = _Embedder()..queryVector = _vec(0);
        final cache = _Cache();
        final index = StudyVectorIndex(embedder: embedder, diskCache: cache);
        final old = _chunk('n', 0, words: 'existing cached subject');
        await index.ensure('n', [old]);
        embedder.textCalls.clear();
        final gate = embedder.gate = Completer<void>();
        final fresh = _chunk('n', 1, words: 'new requested subject');
        final input = {
          'n': [fresh],
        };
        final first = index.signalFor('same query', input, partial: true);
        final second = index.signalFor('same query', input, partial: true);
        await Future<void>.delayed(Duration.zero);
        expect(embedder.queries, ['same query']);
        expect(embedder.textCalls, hasLength(1));
        gate.complete();
        await Future.wait([first, second]);
        expect(embedder.textCalls, hasLength(1));
        expect(index.lookup(old)?.text, isNotNull);
        expect(cache.files['n'], hasLength(2));
      },
    );

    test(
      'cold searches bound text and image embedding work on a large collection',
      () {
        final docs = [
          for (var i = 0; i < 200; i++)
            _doc(
              _chunk(
                'n',
                i,
                words: i.isEven ? 'force ${'material ' * 300}' : '',
                kind: i.isEven ? StudyChunkKind.text : StudyChunkKind.diagram,
              ),
              'Physics',
            ),
        ];
        final selected = studySemanticCandidates(
          docs,
          'Explain force and diagrams',
        );
        expect(selected, isNotEmpty);
        expect(selected.length, lessThanOrEqualTo(16));
        expect(
          selected.where((d) => d.chunk.needsPicture).length,
          lessThanOrEqualTo(2),
        );
        expect(
          selected.fold<int>(
            0,
            (n, d) => n + studyEmbeddingText(d.chunk).length,
          ),
          lessThanOrEqualTo(12000),
        );
      },
    );

    test('embeds each chunk once and only what changed', () async {
      final _Embedder embedder = _Embedder();
      final _Cache cache = _Cache();
      final StudyVectorIndex index = StudyVectorIndex(
        embedder: embedder,
        diskCache: cache,
      );
      final List<StudyChunk> chunks = [
        _chunk('n', 1, words: 'binary counter'),
        _chunk('n', 2, words: 'shift register'),
        _chunk('n', 3), // nothing to say
      ];
      await index.ensure('n', chunks);
      expect(embedder.textCalls.single.length, 2);
      expect(index.lookup(chunks[0])?.text, isNotNull);
      expect(index.lookup(chunks[2]), isNull);

      await index.ensure('n', chunks);
      expect(embedder.textCalls.length, 1);

      await index.ensure('n', [
        chunks[0],
        _chunk('n', 2, words: 'shift register with enable'),
      ]);
      expect(embedder.textCalls.last, ['shift register with enable']);
      // What no longer exists is let go from the file.
      expect(cache.files['n']!.length, 2);

      // A new session reads them from disk and asks for nothing.
      final StudyVectorIndex fresh = StudyVectorIndex(
        embedder: embedder,
        diskCache: cache,
      );
      await fresh.ensure('n', [chunks[0]]);
      expect(embedder.textCalls.length, 2);
      expect(fresh.lookup(chunks[0])?.text, isNotNull);
    });

    test('draws only what words do not carry, and not twice', () async {
      final _Embedder embedder = _Embedder();
      final _Renderer renderer = _Renderer();
      final StudyVectorIndex index = StudyVectorIndex(
        embedder: embedder,
        renderer: renderer,
        diskCache: _Cache(),
      );
      final StudyChunk words = _chunk('n', 1, words: 'plain words');
      final StudyChunk drawing = _chunk('n', 2, kind: StudyChunkKind.diagram);
      await index.ensure('n', [words, drawing]);
      expect(renderer.drawn, 1);
      expect(embedder.imageCalls, [1]);
      expect(index.lookup(drawing)?.image, isNotNull);
      expect(index.lookup(words)?.image, isNull);
      await index.ensure('n', [words, drawing]);
      expect(renderer.drawn, 1);

      // One that cannot be drawn is not tried again.
      renderer.fail = true;
      final StudyChunk blank = _chunk('n', 3, kind: StudyChunkKind.diagram);
      await index.ensure('n', [words, drawing, blank]);
      await index.ensure('n', [words, drawing, blank]);
      expect(renderer.drawn, 2);
      expect(index.lookup(blank)?.imageSkipped, isTrue);
    });

    test('does nothing when embedding is not available', () async {
      final _Embedder embedder = _Embedder(available: false);
      final StudyVectorIndex index = StudyVectorIndex(embedder: embedder);
      await index.ensure('n', [_chunk('n', 1, words: 'x')]);
      expect(embedder.textCalls, isEmpty);
      expect(await index.signalFor('q', {'n': []}), isNull);
    });

    test('a question with no vector goes by words', () async {
      final _Embedder embedder = _Embedder()..queryVector = null;
      final StudyVectorIndex index = StudyVectorIndex(
        embedder: embedder,
        diskCache: _Cache(),
      );
      expect(
        await index.signalFor('q', {
          'n': [_chunk('n', 1, words: 'x')],
        }),
        isNull,
      );
    });

    test('the same question is embedded once', () async {
      final _Embedder embedder = _Embedder()..queryVector = _vec(0);
      final StudyVectorIndex index = StudyVectorIndex(
        embedder: embedder,
        diskCache: _Cache(),
      );
      final Map<String, List<StudyChunk>> notes = {
        'n': [_chunk('n', 1, words: 'x')],
      };
      expect(await index.signalFor(' q ', notes), isNotNull);
      expect(await index.signalFor('q', notes), isNotNull);
      expect(embedder.queries, ['q']);
    });
  });

  group('retrieval by words and meaning', () {
    // Digital systems notes are drawings with little text a recognizer can
    // read. A Laplace note says "systems" all the time.
    final StudyChunk circuit = _chunk(
      'digital',
      1,
      kind: StudyChunkKind.diagram,
    );
    final StudyChunk caption = _chunk('digital', 2, words: 'counter clock');
    final StudyChunk laplace = _chunk(
      'laplace',
      1,
      words: 'linear systems transfer function of systems',
    );
    final List<StudySearchDocument> documents = [
      _doc(circuit, 'Digital design'),
      _doc(caption, 'Digital design'),
      _doc(laplace, 'Laplace'),
    ];

    StudyVectorSignal signal({
      Float32List? circuitImage,
      Float32List? captionText,
      Float32List? laplaceText,
    }) {
      final Map<String, StudyChunkVectors> known = {
        studyChunkKey(circuit): StudyChunkVectors(image: circuitImage),
        studyChunkKey(caption): StudyChunkVectors(text: captionText),
        studyChunkKey(laplace): StudyChunkVectors(text: laplaceText),
      };
      return StudyVectorSignal(
        query: _vec(0),
        lookup: (StudyChunk c) => known[studyChunkKey(c)],
      );
    }

    test('words alone lead "digital systems" to the Laplace page', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'explain digital systems',
      );
      // Documented behaviour before meaning: the page that says "systems".
      expect(hits.map((StudyHit h) => h.chunk.noteId), contains('laplace'));
    });

    test('meaning finds the drawing and keeps the unrelated page out', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'explain digital systems',
        vectors: signal(
          circuitImage: _vec(0, other: 1, mix: .2), // near the question
          captionText: _vec(0, other: 1, mix: .3),
          laplaceText: _vec(1), // far from it
        ),
      );
      final Set<StudyChunk> found = {for (final StudyHit h in hits) h.chunk};
      expect(found, contains(circuit));
      expect(found, contains(caption));
      expect(found, isNot(contains(laplace)));
    });

    test('words that match, with a meaning not far off, still count', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'transfer function',
        vectors: signal(
          circuitImage: _vec(1),
          captionText: _vec(1),
          // Words match and the meaning is in between: kept.
          laplaceText: _vec(0, other: 1, mix: 2.2),
        ),
      );
      expect(hits.map((StudyHit h) => h.chunk), [laplace]);
    });

    test('a chunk with no vector yet is judged by its words', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'transfer function',
        vectors: StudyVectorSignal(query: _vec(0), lookup: (_) => null),
      );
      expect(hits.map((StudyHit h) => h.chunk), [laplace]);
    });

    test('nothing near, nothing matching: pages with words are not sent', () {
      final List<StudySearchDocument> withWords = [
        _doc(caption, 'Digital design'),
        _doc(laplace, 'Laplace'),
      ];
      expect(
        StudyRetriever.retrieve(withWords, 'quantum chromodynamics'),
        isEmpty,
      );
      expect(
        StudyRetriever.retrieve(
          withWords,
          'quantum chromodynamics',
          vectors: StudyVectorSignal(
            query: _vec(0),
            lookup: (StudyChunk c) => StudyChunkVectors(text: _vec(1)),
          ),
        ),
        isEmpty,
      );
    });

    test('a scan has no words to rule it out, so it goes along', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'quantum chromodynamics',
      );
      expect(hits.map((StudyHit h) => h.chunk), [circuit]);
    });

    test('a question with no subject still gets a fair sample', () {
      expect(
        StudyRetriever.retrieve(documents, 'what is this').isNotEmpty,
        isTrue,
      );
    });
  });
}
