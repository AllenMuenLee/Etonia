import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';
import 'package:greatnote/features/library/study_desk/study_teaching_plan.dart';
import 'package:greatnote/features/library/study_desk/study_vectors.dart';

const int _dims = BackendStudyEmbedder.dimensions;

Float32List _vec(int axis) => Float32List(_dims)..[axis] = 1;

/// [count] points from [a] to [b], both included.
List<Offset> _along(Offset a, Offset b, [int count = 6]) => <Offset>[
  for (int i = 0; i < count; i++) Offset.lerp(a, b, i / (count - 1))!,
];

StudyStrokeData _stroke(
  int index,
  List<Offset> points, {
  String ink = studyNeutralInk,
}) {
  final double left = points.map((p) => p.dx).reduce(math.min);
  final double right = points.map((p) => p.dx).reduce(math.max);
  final double top = points.map((p) => p.dy).reduce(math.min);
  final double bottom = points.map((p) => p.dy).reduce(math.max);
  return StudyStrokeData(
    index: index,
    bounds: Rect.fromLTRB(left - 1, top - 1, right + 1, bottom + 1),
    points: Float32List.fromList(<double>[
      for (final Offset p in points) ...<double>[p.dx, p.dy],
    ]),
    inkFamily: ink,
  );
}

/// A line, as a stroke.
StudyStrokeData _line(
  int index,
  Offset a,
  Offset b, {
  String ink = studyNeutralInk,
}) => _stroke(index, _along(a, b), ink: ink);

StudyStrokeData _tick(int index, Offset at, {String ink = studyNeutralInk}) =>
    _stroke(index, <Offset>[
      ..._along(at, at + const Offset(8, 12), 4),
      ..._along(at + const Offset(8, 12), at + const Offset(30, -20), 7).skip(1),
    ], ink: ink);

/// An X in two strokes, [size] across.
List<StudyStrokeData> _cross(
  int first,
  Offset at, {
  double size = 30,
  String ink = studyNeutralInk,
}) => <StudyStrokeData>[
  _line(first, at, at + Offset(size, size), ink: ink),
  _line(first + 1, at + Offset(size, 0), at + Offset(0, size), ink: ink),
];

StudyStrokeData _loop(int index, Rect around, {String ink = studyNeutralInk}) {
  final Offset c = around.center;
  final List<Offset> ring = <Offset>[
    for (int i = 0; i <= 24; i++)
      Offset(
        c.dx + around.width / 2 * math.cos(i / 24 * 2 * math.pi),
        c.dy + around.height / 2 * math.sin(i / 24 * 2 * math.pi),
      ),
  ];
  return _stroke(index, ring, ink: ink);
}

StudyBoxData _text(String text, Rect bounds) => StudyBoxData(
  id: 'text-${bounds.left}-${bounds.top}',
  kind: StudyBoxKind.text,
  bounds: bounds,
  text: text,
);

List<StudyChunk> _chunks(
  List<StudyStrokeData> strokes, [
  List<StudyBoxData> boxes = const <StudyBoxData>[],
]) => StudyChunker.chunkPage(
  'n',
  StudyPageData(
    pageIndex: 0,
    strokes: strokes,
    boxes: boxes,
    words: const <StudyWordData>[],
  ),
);

/// Neutral ink far from any mark, so a page has a pen of its own.
List<StudyStrokeData> _writing(int first, {int count = 8}) =>
    <StudyStrokeData>[
      for (int i = 0; i < count; i++)
        _line(first + i, Offset(0, 600.0 + 60 * i), Offset(50, 600.0 + 60 * i)),
    ];

StudyChunk _marked({String words = 'x equals four', int chunkIndex = 1}) =>
    StudyChunk(
      noteId: 'n',
      pageIndex: chunkIndex,
      chunkIndex: chunkIndex,
      kind: StudyChunkKind.text,
      logicalBounds: Rect.fromLTWH(0, chunkIndex * 100.0, 300, 90),
      handwriting: words,
      tags: const <String>[StudyChunk.markedTag],
    );

void main() {
  group('ink colour', () {
    test('names a hue, and calls black and grey neutral', () {
      expect(studyInkFamily(const Color(0xFFC62F2F)), 'red');
      expect(studyInkFamily(const Color(0xFF1F5FD1)), 'blue');
      expect(studyInkFamily(const Color(0xFF1E7B46)), 'green');
      expect(studyInkFamily(const Color(0xFFB85C00)), 'orange');
      expect(studyInkFamily(const Color(0xFF7B3FC4)), 'purple');
      expect(studyInkFamily(const Color(0xFF0F172A)), studyNeutralInk);
      expect(studyInkFamily(const Color(0xFF5F6368)), studyNeutralInk);
    });
  });

  group('marks on a page', () {
    test('a tick in the clear is a mark, and says so in plain words', () {
      final StudyChunk chunk = _chunks(<StudyStrokeData>[
        _tick(0, const Offset(100, 100)),
      ]).single;
      expect(chunk.tags, containsAll(<String>['marked', 'tick', 'correct']));
      expect(chunk.hasMarks, isTrue);
      expect(chunk.needsPicture, isTrue);
    });

    test('a cross in the clear is a mark that reads as a mistake', () {
      final StudyChunk chunk = _chunks(
        _cross(0, const Offset(100, 100)),
      ).single;
      expect(
        chunk.tags,
        containsAll(<String>['marked', 'cross', 'wrong', 'mistake']),
      );
    });

    test('a loop round a line of type is circled', () {
      final StudyChunk chunk = _chunks(
        <StudyStrokeData>[_loop(0, const Rect.fromLTWH(80, 90, 120, 50))],
        <StudyBoxData>[_text('x = 4', const Rect.fromLTWH(110, 105, 60, 20))],
      ).single;
      expect(chunk.tags, containsAll(<String>['marked', 'circled']));
    });

    test('a level line through the middle of a word strikes it out', () {
      final StudyChunk chunk = _chunks(
        <StudyStrokeData>[
          _line(0, const Offset(96, 110), const Offset(204, 110)),
        ],
        <StudyBoxData>[_text('x = 5', const Rect.fromLTWH(100, 100, 100, 20))],
      ).single;
      expect(
        chunk.tags,
        containsAll(<String>['marked', 'strikethrough', 'corrected']),
      );
    });

    test('an underline is not a strike-through', () {
      final StudyChunk chunk = _chunks(
        <StudyStrokeData>[
          _line(0, const Offset(96, 124), const Offset(204, 124)),
        ],
        <StudyBoxData>[_text('x = 5', const Rect.fromLTWH(100, 100, 100, 20))],
      ).single;
      expect(chunk.tags, isNot(contains('strikethrough')));
      expect(chunk.hasMarks, isFalse);
    });

    test('a letter v is not a tick', () {
      final StudyChunk chunk = _chunks(<StudyStrokeData>[
        _stroke(0, <Offset>[
          ..._along(const Offset(100, 100), const Offset(110, 115), 4),
          ..._along(const Offset(110, 115), const Offset(120, 100), 4).skip(1),
        ]),
      ]).single;
      expect(chunk.tags, isNot(contains('tick')));
    });

    test('an X in the page\'s own pen, among writing, is only a letter', () {
      final StudyChunk chunk = _chunks(<StudyStrokeData>[
        ..._cross(0, const Offset(100, 100)),
        // Writing right beside it, in the same pen.
        _line(2, const Offset(60, 112), const Offset(98, 112)),
        _line(3, const Offset(134, 112), const Offset(180, 112)),
      ]).first;
      expect(chunk.tags, isNot(contains('cross')));
      expect(chunk.hasMarks, isFalse);
    });

    test('the same X in another pen is a mark however close the writing', () {
      final List<StudyChunk> chunks = _chunks(<StudyStrokeData>[
        ..._cross(0, const Offset(100, 100), ink: 'red'),
        _line(2, const Offset(60, 112), const Offset(98, 112)),
        _line(3, const Offset(134, 112), const Offset(180, 112)),
        ..._writing(10),
      ]);
      final StudyChunk chunk = chunks.firstWhere((c) => c.hasMarks);
      expect(chunk.tags, containsAll(<String>['marked', 'cross']));
      // Two strokes are not enough to call a chunk annotated.
      expect(chunk.tags, isNot(contains('annotated')));
    });

    test('several strokes in another pen make a chunk annotated', () {
      final List<StudyChunk> chunks = _chunks(<StudyStrokeData>[
        _line(0, const Offset(100, 100), const Offset(180, 100), ink: 'red'),
        _line(1, const Offset(100, 120), const Offset(190, 121), ink: 'red'),
        _line(2, const Offset(100, 140), const Offset(170, 139), ink: 'red'),
        _line(3, const Offset(100, 160), const Offset(160, 160)),
        ..._writing(10),
      ]);
      final StudyChunk chunk = chunks.firstWhere((c) => c.hasMarks);
      expect(
        chunk.tags,
        containsAll(<String>['annotated', 'red-ink', 'red']),
      );
      expect(chunk.needsPicture, isTrue);
    });

    test('one pen throughout is no annotation, even if it is red', () {
      final List<StudyChunk> chunks = _chunks(<StudyStrokeData>[
        for (int i = 0; i < 10; i++)
          _line(
            i,
            Offset(0, 100.0 + 60 * i),
            Offset(50, 100.0 + 60 * i),
            ink: 'red',
          ),
      ]);
      expect(chunks.any((c) => c.hasMarks), isFalse);
    });

    test('a page with too little ink has no usual pen to differ from', () {
      final List<StudyChunk> chunks = _chunks(<StudyStrokeData>[
        _line(0, const Offset(100, 100), const Offset(180, 100), ink: 'red'),
        _line(1, const Offset(100, 120), const Offset(190, 121), ink: 'red'),
        _line(2, const Offset(100, 140), const Offset(170, 139), ink: 'red'),
        _line(3, const Offset(100, 160), const Offset(160, 160)),
      ]);
      expect(chunks.any((c) => c.hasMarks), isFalse);
    });

    test('marks survive being kept on disk', () {
      final StudyChunk chunk = _chunks(<StudyStrokeData>[
        _tick(0, const Offset(100, 100)),
      ]).single;
      final StudyChunk again = StudyChunk.fromJson(chunk.toJson());
      expect(again.hasMarks, isTrue);
      expect(again.tags, chunk.tags);
    });

    test('a mark is found by the words a student would use', () {
      final List<StudyChunk> chunks = _chunks(<StudyStrokeData>[
        ..._cross(0, const Offset(100, 100)),
      ]);
      final List<StudyHit> hits = StudyRetriever.retrieve(<StudySearchDocument>[
        for (final StudyChunk chunk in chunks)
          StudySearchDocument(chunk: chunk, noteTitle: 'Algebra'),
      ], 'wrong incorrect crossed');
      expect(hits, isNotEmpty);
    });
  });

  group('looking for how a page looks', () {
    // A page of working with a red cross on it says "x equals four" and
    // nothing of mistakes; its picture does show them.
    final StudyChunk markedPage = _marked();
    const StudyChunk plain = StudyChunk(
      noteId: 'n',
      pageIndex: 2,
      chunkIndex: 2,
      kind: StudyChunkKind.text,
      logicalBounds: Rect.fromLTWH(0, 200, 300, 90),
      handwriting: 'laplace transform of a step',
    );
    final List<StudySearchDocument> documents = <StudySearchDocument>[
      StudySearchDocument(chunk: markedPage, noteTitle: 'Algebra'),
      const StudySearchDocument(chunk: plain, noteTitle: 'Algebra'),
    ];

    StudyVectorSignal signal({Float32List? visual}) {
      final Map<String, StudyChunkVectors> known = <String, StudyChunkVectors>{
        // Its picture is unlike the bare question and like the description.
        studyChunkKey(markedPage): StudyChunkVectors(
          text: _vec(5),
          image: _vec(2),
        ),
        studyChunkKey(plain): StudyChunkVectors(text: _vec(6)),
      };
      return StudyVectorSignal(
        query: _vec(0),
        visual: visual,
        lookup: (StudyChunk c) => known[studyChunkKey(c)],
      );
    }

    test('a keyword and its vector reach neither the page nor its picture', () {
      expect(
        StudyRetriever.retrieve(documents, 'mistakes', vectors: signal()),
        isEmpty,
      );
    });

    test('a sentence about how it looks reaches the marked page', () {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        documents,
        'mistakes',
        vectors: signal(visual: _vec(2)),
      );
      expect(hits.map((h) => h.chunk), <StudyChunk>[markedPage]);
    });

    test('a look that matches nothing adds nothing', () {
      expect(
        StudyRetriever.retrieve(
          documents,
          'mistakes',
          vectors: signal(visual: _vec(9)),
        ),
        isEmpty,
      );
    });
  });

  group('the look of a question is embedded with it', () {
    test('both are asked for, and the look rides on the signal', () async {
      final _Embedder embedder = _Embedder()..queryVector = _vec(1);
      final StudyVectorIndex index = StudyVectorIndex(embedder: embedder);
      final StudyVectorSignal? signal = await index.signalFor(
        'mistakes wrong cross',
        <String, List<StudyChunk>>{'n': <StudyChunk>[_marked()]},
        visualQuery: 'handwriting with red crosses',
      );
      expect(signal?.visual, isNotNull);
      expect(embedder.queries, <String>[
        'mistakes wrong cross',
        'handwriting with red crosses',
      ]);
    });

    test('no look, or the same words twice, costs no second embedding', () async {
      final _Embedder embedder = _Embedder()..queryVector = _vec(1);
      final StudyVectorIndex index = StudyVectorIndex(embedder: embedder);
      final Map<String, List<StudyChunk>> notes = <String, List<StudyChunk>>{
        'n': <StudyChunk>[_marked()],
      };
      expect((await index.signalFor('q', notes))?.visual, isNull);
      expect((await index.signalFor('q', notes, visualQuery: ' '))?.visual, isNull);
      expect((await index.signalFor('q', notes, visualQuery: ' q '))?.visual, isNull);
      expect(embedder.queries, <String>['q']);
    });

    test('a look that cannot be embedded leaves the question\'s signal', () async {
      final _Embedder embedder = _Embedder()
        ..queryFor = (String text) => text == 'q' ? _vec(1) : null;
      final StudyVectorIndex index = StudyVectorIndex(embedder: embedder);
      final StudyVectorSignal? signal = await index.signalFor(
        'q',
        <String, List<StudyChunk>>{
          'n': <StudyChunk>[_marked()],
        },
        visualQuery: 'red crosses',
      );
      expect(signal, isNotNull);
      expect(signal!.visual, isNull);
    });

    test('a request about appearance embeds more pictures, marks first', () {
      final List<StudySearchDocument> documents = <StudySearchDocument>[
        for (int i = 1; i <= 6; i++)
          StudySearchDocument(
            chunk: _marked(words: 'x', chunkIndex: i),
            noteTitle: 'Algebra',
          ),
      ];
      int pictures(List<StudySearchDocument> chosen) =>
          chosen.where((d) => d.chunk.needsPicture).length;
      expect(pictures(studySemanticCandidates(documents, 'zzz')), 2);
      expect(
        pictures(studySemanticCandidates(documents, 'zzz', visual: true)),
        6,
      );
    });
  });

  group('the planner can say how a page looks', () {
    String reply(String retrieval) =>
        '{"intent":"question","retrieval":$retrieval}';

    test('a look is read with the rest of the retrieval', () {
      final StudyTeachingDecision? decision = StudyTeachingDecision.parse(
        reply(
          '{"notes":true,"mistakeIndices":[],"query":"wrong cross",'
          '"visualQuery":"  handwriting with red crosses  ","depth":"full"}',
        ),
      );
      expect(decision?.retrieveNotes, isTrue);
      expect(decision?.retrievalQuery, 'wrong cross');
      expect(decision?.visualQuery, 'handwriting with red crosses');
    });

    test('older planner replies, without one, still parse', () {
      final StudyTeachingDecision? decision = StudyTeachingDecision.parse(
        reply('{"notes":true,"mistakeIndices":[],"query":"flip flops"}'),
      );
      expect(decision, isNotNull);
      expect(decision!.visualQuery, isEmpty);
    });

    test('a malformed look is dropped, not the whole plan', () {
      for (final String bad in <String>[
        '5',
        'null',
        '["red crosses"]',
        '"${'a' * (StudyTeachingDecision.maxVisualQuery + 1)}"',
      ]) {
        final StudyTeachingDecision? decision = StudyTeachingDecision.parse(
          reply(
            '{"notes":true,"mistakeIndices":[],"query":"q","visualQuery":$bad}',
          ),
        );
        expect(decision, isNotNull, reason: bad);
        expect(decision!.visualQuery, isEmpty, reason: bad);
        expect(decision.retrievalQuery, 'q', reason: bad);
      }
    });

    test('with no notes asked for, a look is ignored', () {
      final StudyTeachingDecision? decision = StudyTeachingDecision.parse(
        reply(
          '{"notes":false,"mistakeIndices":[],"query":"",'
          '"visualQuery":"red crosses"}',
        ),
      );
      expect(decision!.visualQuery, isEmpty);
    });

    test('a look survives the decision being completed by a lesson plan', () {
      final StudyTeachingDecision retrieval = StudyTeachingDecision.parse(
        reply(
          '{"notes":true,"mistakeIndices":[],"query":"q","visualQuery":"v"}',
        ),
      )!;
      const StudyTeachingDecision plain = StudyTeachingDecision(
        StudyTeachingIntent.question,
        null,
      );
      expect(plain.withRetrieval(retrieval).visualQuery, 'v');
    });

    test('the prompts tell the models about marks', () {
      expect(AiPrompts.studyTeachingPlannerSystem, contains('visualQuery'));
      expect(AiPrompts.studyTeachingPlannerSystem, contains('crossed-out'));
      expect(AiPrompts.studyVisualDescriptionSystem, contains('crosses'));
    });
  });
}

class _Embedder implements StudyEmbedder {
  Float32List? queryVector;
  Float32List? Function(String text)? queryFor;
  final List<String> queries = <String>[];

  @override
  bool get isAvailable => true;

  @override
  Future<List<Float32List?>> embedTexts(List<String> texts) async =>
      <Float32List?>[for (final _ in texts) _vec(0)];

  @override
  Future<List<Float32List?>> embedImages(List<Uint8List> pngs) async =>
      <Float32List?>[for (final _ in pngs) _vec(0)];

  @override
  Future<Float32List?> embedQuery(String text) async {
    queries.add(text);
    return queryFor != null ? queryFor!(text) : queryVector;
  }
}
