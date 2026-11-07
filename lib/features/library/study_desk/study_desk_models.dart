import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';

import '../../editor/ai/ai_citation.dart';
import '../../editor/ink/stroke.dart';
import '../note_content.dart';
import 'study_teaching_plan.dart';

/// The workspace's user-facing name, in this one place.
abstract final class StudyDesk {
  static const String title = 'Study Desk';
}

/// What a chunk of a page is mostly made of, and so how it is sent to a model.
enum StudyChunkKind {
  /// Typed text, or ink most of which reads as words: sent as words alone.
  text,

  /// A drawing or picture with no words of its own.
  diagram,

  /// A drawing or picture with recognized words in it.
  mixed;

  static StudyChunkKind byName(Object? name) => values.firstWhere(
    (StudyChunkKind kind) => kind.name == name,
    orElse: () => text,
  );
}

/// One row of words in a chunk. [first] and [last] are the page's strokes
/// behind it, from one, as a citation names them; both are 0 for typed text,
/// which no line number can name.
@immutable
class StudyChunkLine {
  const StudyChunkLine(this.first, this.last, this.text);

  factory StudyChunkLine.fromJson(Map<String, Object?> json) => StudyChunkLine(
    json['f']! as int,
    json['l']! as int,
    json['t']! as String,
  );

  final int first;
  final int last;
  final String text;

  bool get hasStrokes => first > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'f': first,
    'l': last,
    't': text,
  };
}

/// A PDF bookmark mapped to the note's pages, stored on its first chunk.
@immutable
class StudySourceSection {
  const StudySourceSection(this.title, this.endPageIndex);

  final String title;
  final int endPageIndex;

  factory StudySourceSection.fromJson(Map<String, Object?> json) =>
      StudySourceSection(json['title']! as String, json['end']! as int);

  Map<String, Object?> toJson() => {'title': title, 'end': endPageIndex};
}

/// A paragraph-sized patch of one page, and all that makes it findable. Holds
/// plain data only, so it can cross isolates and be kept on disk.
@immutable
class StudyChunk {
  const StudyChunk({
    required this.noteId,
    required this.pageIndex,
    required this.chunkIndex,
    required this.kind,
    required this.logicalBounds,
    this.strokeIndices = const <int>[],
    this.stickyIds = const <String>[],
    this.imageIds = const <String>[],
    this.otherBounds,
    this.lines = const <StudyChunkLine>[],
    this.handwriting = '',
    this.alternatives = '',
    this.typed = '',
    this.anchors = const <String>[],
    this.svgText = '',
    this.tags = const <String>[],
    this.lowConfidence = false,
    this.sourceSection,
  });

  factory StudyChunk.fromJson(Map<String, Object?> json) {
    List<String> strings(String key) => <String>[
      for (final Object? value in (json[key] as List?) ?? const <Object?>[])
        value! as String,
    ];
    Rect? rect(Object? raw) {
      if (raw is! List || raw.length != 4) return null;
      return Rect.fromLTRB(
        (raw[0]! as num).toDouble(),
        (raw[1]! as num).toDouble(),
        (raw[2]! as num).toDouble(),
        (raw[3]! as num).toDouble(),
      );
    }

    return StudyChunk(
      noteId: json['noteId']! as String,
      pageIndex: json['page']! as int,
      chunkIndex: json['chunk']! as int,
      kind: StudyChunkKind.byName(json['kind']),
      logicalBounds: rect(json['bounds'])!,
      strokeIndices: <int>[
        for (final Object? value
            in (json['strokes'] as List?) ?? const <Object?>[])
          value! as int,
      ],
      stickyIds: strings('stickies'),
      imageIds: strings('images'),
      otherBounds: rect(json['other']),
      lines: <StudyChunkLine>[
        for (final Object? line
            in (json['lines'] as List?) ?? const <Object?>[])
          StudyChunkLine.fromJson(line! as Map<String, Object?>),
      ],
      handwriting: json['handwriting'] as String? ?? '',
      alternatives: json['alternatives'] as String? ?? '',
      typed: json['typed'] as String? ?? '',
      anchors: strings('anchors'),
      svgText: json['svg'] as String? ?? '',
      tags: strings('tags'),
      lowConfidence: json['low'] == true,
      sourceSection: switch (json['section']) {
        final Map<String, Object?> section => StudySourceSection.fromJson(
          section,
        ),
        _ => null,
      },
    );
  }

  final String noteId;

  /// From zero, as the note's pages are held.
  final int pageIndex;

  /// From one, down the page, as a citation names it.
  final int chunkIndex;
  final StudyChunkKind kind;

  /// Round everything in the chunk, in page coordinates.
  final Rect logicalBounds;

  /// The page's strokes in it, by their place on the page, from zero.
  final List<int> strokeIndices;
  final List<String> stickyIds;
  final List<String> imageIds;

  /// Round what in it is not page ink: pictures, sticky notes, typed text.
  final Rect? otherBounds;

  final List<StudyChunkLine> lines;

  /// The recognized words, as read.
  final String handwriting;

  /// The recognizer's other readings, so messy writing still matches.
  final String alternatives;
  final String typed;

  /// Words written in or near a drawing: its labels and caption.
  final List<String> anchors;

  /// The title, description, and text inside an inline SVG.
  final String svgText;

  /// What a drawing's strokes look like: box, axes, arrow, curve.
  final List<String> tags;

  /// Ink that reads poorly, or not at all, even though it is no drawing.
  final bool lowConfidence;

  final StudySourceSection? sourceSection;

  /// Whether a model has to see this to use it: its words do not carry it.
  bool get needsPicture => kind != StudyChunkKind.text || lowConfidence;

  Map<String, Object?> toJson() => <String, Object?>{
    'noteId': noteId,
    'page': pageIndex,
    'chunk': chunkIndex,
    'kind': kind.name,
    'bounds': _rectJson(logicalBounds),
    if (strokeIndices.isNotEmpty) 'strokes': strokeIndices,
    if (stickyIds.isNotEmpty) 'stickies': stickyIds,
    if (imageIds.isNotEmpty) 'images': imageIds,
    if (otherBounds != null) 'other': _rectJson(otherBounds!),
    if (lines.isNotEmpty)
      'lines': <Object?>[
        for (final StudyChunkLine line in lines) line.toJson(),
      ],
    if (handwriting.isNotEmpty) 'handwriting': handwriting,
    if (alternatives.isNotEmpty) 'alternatives': alternatives,
    if (typed.isNotEmpty) 'typed': typed,
    if (anchors.isNotEmpty) 'anchors': anchors,
    if (svgText.isNotEmpty) 'svg': svgText,
    if (tags.isNotEmpty) 'tags': tags,
    if (lowConfidence) 'low': true,
    if (sourceSection != null) 'section': sourceSection!.toJson(),
  };
}

List<double> _rectJson(Rect rect) => <double>[
  rect.left,
  rect.top,
  rect.right,
  rect.bottom,
];

/// A note on the desk, in the context of questions while [enabled].
@immutable
class StudySourceItem {
  const StudySourceItem({required this.noteId, this.enabled = true});

  factory StudySourceItem.fromJson(Map<String, Object?> json) =>
      StudySourceItem(
        noteId: json['noteId']! as String,
        enabled: json['enabled'] != false,
      );

  final String noteId;
  final bool enabled;

  StudySourceItem copyWith({bool? enabled}) =>
      StudySourceItem(noteId: noteId, enabled: enabled ?? this.enabled);

  Map<String, Object?> toJson() => <String, Object?>{
    'noteId': noteId,
    'enabled': enabled,
  };
}

/// What an answer cites on one page of one note. Holds each stroke's
/// `aiStrokeKey`, so it stays right as the note is edited and reloaded, and needs
/// no number from its request.
@immutable
class StudyCitation {
  const StudyCitation({
    required this.noteId,
    required this.pageIndex,
    required this.revision,
    this.strokeKeys = const <String>[],
    this.strokeIndices = const <int>[],
    this.rings = const <Rect>[],
    this.kind,
    this.bounds,
    this.diagramBounds = const <Rect>[],
  });

  factory StudyCitation.fromJson(Map<String, Object?> json) => StudyCitation(
    noteId: json['noteId']! as String,
    pageIndex: json['page']! as int,
    revision: json['revision'] as int? ?? 0,
    kind: StudyChunkKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull,
    diagramBounds: <Rect>[
      for (final region in json['diagramBounds'] as List? ?? const [])
        if (region case [final num l, final num t, final num r, final num b])
          Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()),
    ],
    bounds: switch (json['bounds']) {
      [final num l, final num t, final num r, final num b] => Rect.fromLTRB(
        l.toDouble(),
        t.toDouble(),
        r.toDouble(),
        b.toDouble(),
      ),
      _ => null,
    },
    strokeKeys: <String>[
      for (final Object? id in (json['keys'] as List?) ?? const <Object?>[])
        id! as String,
    ],
    strokeIndices: <int>[
      for (final Object? index
          in (json['indices'] as List?) ?? const <Object?>[])
        index! as int,
    ],
    rings: <Rect>[
      for (final Object? ring in (json['rings'] as List?) ?? const <Object?>[])
        if (ring case [
          final num left,
          final num top,
          final num right,
          final num bottom,
        ])
          Rect.fromLTRB(
            left.toDouble(),
            top.toDouble(),
            right.toDouble(),
            bottom.toDouble(),
          ),
    ],
  );

  final String noteId;

  /// From zero.
  final int pageIndex;

  /// The note's revision when cited: [strokeIndices] hold only for that one.
  final int revision;
  final List<String> strokeKeys;
  final List<int> strokeIndices;

  /// Details to ring, in page coordinates.
  final List<Rect> rings;
  final StudyChunkKind? kind;
  final Rect? bounds;

  /// Kept separately when one paragraph cites words and several diagrams on
  /// the same page, so each crop still opens at its own original location.
  final List<Rect> diagramBounds;

  static Rect pageBounds(StoredPage page) {
    if (page.pdfSource case final source?) {
      return Offset.zero & source.pageSize;
    }
    if (page.isBoard) {
      return page.contentBounds ?? (Offset.zero & const Size(640, 480));
    }
    return Offset.zero &
        (page.setup.customSize ??
            page.setup.size.fixedSize ??
            page.extent ??
            const Size(640, 480));
  }

  /// Page-sized regions are navigation targets, rather than details to ring.
  static bool coversPage(Rect region, StoredPage page) {
    final Rect paper = pageBounds(page);
    if (paper.isEmpty || !region.overlaps(paper)) return false;
    final Rect covered = region.intersect(paper);
    return covered.width >= paper.width * 0.9 &&
        covered.height >= paper.height * 0.9;
  }

  List<Rect> ringsOn(StoredPage page) => [
    for (final ring in rings)
      if (!coversPage(ring, page)) ring,
  ];

  List<StudyCitation> get diagramCitations => [
    for (final region in <Rect>{
      ...diagramBounds,
      if (diagramBounds.isEmpty &&
          kind != null &&
          kind != StudyChunkKind.text &&
          bounds != null)
        bounds!,
    })
      StudyCitation(
        noteId: noteId,
        pageIndex: pageIndex,
        revision: revision,
        kind: StudyChunkKind.diagram,
        bounds: region,
        rings: [region],
      ),
  ];

  /// This, as marks for the note at [currentRevision].
  AiNoteMarks marks(int currentRevision) => AiNoteMarks(
    noteId: noteId,
    pageIndex: pageIndex,
    strokeKeys: strokeKeys.toSet(),
    strokeIndices: currentRevision == revision ? strokeIndices : const <int>[],
    rings: rings,
  );

  /// The cited strokes on [page] as it now stands in the note at
  /// [currentRevision]. Those since erased are gone from here.
  List<Stroke> strokesOn(StoredPage page, int currentRevision) =>
      marks(currentRevision).strokesIn(page.strokes);

  /// This together with [other], cited on the same page by the same paragraph.
  StudyCitation merged(StudyCitation other) => StudyCitation(
    noteId: noteId,
    pageIndex: pageIndex,
    revision: revision,
    kind: kind ?? other.kind,
    diagramBounds: <Rect>{
      ...diagramCitations.map((c) => c.bounds!),
      ...other.diagramCitations.map((c) => c.bounds!),
    }.toList(),
    bounds: bounds == null
        ? other.bounds
        : other.bounds == null
        ? bounds
        : bounds!.expandToInclude(other.bounds!),
    strokeKeys: <String>{...strokeKeys, ...other.strokeKeys}.toList(),
    strokeIndices: <int>{...strokeIndices, ...other.strokeIndices}.toList(),
    rings: <Rect>[...rings, ...other.rings],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'noteId': noteId,
    'page': pageIndex,
    'revision': revision,
    if (kind != null) 'kind': kind!.name,
    if (bounds != null) 'bounds': _rectJson(bounds!),
    if (diagramBounds.isNotEmpty)
      'diagramBounds': [for (final region in diagramBounds) _rectJson(region)],
    if (strokeKeys.isNotEmpty) 'keys': strokeKeys,
    if (strokeIndices.isNotEmpty) 'indices': strokeIndices,
    if (rings.isNotEmpty)
      'rings': <Object?>[for (final Rect ring in rings) _rectJson(ring)],
  };
}

/// What one paragraph of an answer cites. [paragraph] is its number from one,
/// by the numbering of `parseAiAnswer`.
@immutable
class StudyParagraphLinks {
  const StudyParagraphLinks({required this.paragraph, required this.citations});

  factory StudyParagraphLinks.fromJson(Map<String, Object?> json) =>
      StudyParagraphLinks(
        paragraph: json['paragraph']! as int,
        citations: <StudyCitation>[
          for (final Object? citation
              in (json['citations'] as List?) ?? const <Object?>[])
            StudyCitation.fromJson(citation! as Map<String, Object?>),
        ],
      );

  final int paragraph;
  final List<StudyCitation> citations;

  Map<String, Object?> toJson() => <String, Object?>{
    'paragraph': paragraph,
    'citations': <Object?>[
      for (final StudyCitation citation in citations) citation.toJson(),
    ],
  };
}

/// One message of a study chat. An answer's [text] holds no citation: what they
/// said is in [links].
@immutable
class StudyMessage {
  const StudyMessage.user(this.text)
    : fromUser = true,
      links = const <StudyParagraphLinks>[];

  const StudyMessage.answer(
    this.text, {
    this.links = const <StudyParagraphLinks>[],
  }) : fromUser = false;

  factory StudyMessage.fromJson(Map<String, Object?> json) =>
      json['user'] == true
      ? StudyMessage.user(json['text']! as String)
      : StudyMessage.answer(
          json['text']! as String,
          links: <StudyParagraphLinks>[
            for (final Object? link
                in (json['links'] as List?) ?? const <Object?>[])
              StudyParagraphLinks.fromJson(link! as Map<String, Object?>),
          ],
        );

  final bool fromUser;
  final String text;
  final List<StudyParagraphLinks> links;

  /// What paragraph [number] of this answer cites.
  List<StudyCitation> citationsOf(int number) {
    for (final StudyParagraphLinks link in links) {
      if (link.paragraph == number) return link.citations;
    }
    return const <StudyCitation>[];
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (fromUser) 'user': true,
    'text': text,
    if (links.isNotEmpty)
      'links': <Object?>[
        for (final StudyParagraphLinks link in links) link.toJson(),
      ],
  };
}

/// A class and the library material normally studied in it.
@immutable
class StudyCourse {
  const StudyCourse({
    required this.id,
    required this.name,
    required this.colorHex,
    required this.createdAt,
    this.associatedFolderIds = const <String>[],
    this.associatedNoteIds = const <String>[],
  });

  final String id;
  final String name;
  final String colorHex;
  final DateTime createdAt;
  final List<String> associatedFolderIds;
  final List<String> associatedNoteIds;

  factory StudyCourse.fromJson(Map<String, Object?> json) => StudyCourse(
    id: json['id']! as String,
    name: json['name']! as String,
    colorHex: json['colorHex'] as String? ?? '#6750A4',
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
    associatedFolderIds: List<String>.from(
      json['folderIds'] as List? ?? const [],
    ),
    associatedNoteIds: List<String>.from(json['noteIds'] as List? ?? const []),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'colorHex': colorHex,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'folderIds': associatedFolderIds,
    'noteIds': associatedNoteIds,
  };
}

const Object _unchangedCourse = Object();

/// One conversation on the desk.
@immutable
class StudySession {
  const StudySession({
    required this.id,
    required this.created,
    this.messages = const <StudyMessage>[],
    String? title,
    DateTime? updatedAt,
    this.courseId,
    this.isPinned = false,
    this.sources,
    this.teachingPlan,
    this.testPaperId,
    // The public argument is `title`; the nullable override stays private.
    // ignore: prefer_initializing_formals
  }) : _title = title,
       updatedAt = updatedAt ?? created;

  factory StudySession.fromJson(Map<String, Object?> json) => StudySession(
    id: json['id']! as String,
    created: DateTime.fromMillisecondsSinceEpoch(json['created']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] ?? json['created'])! as int,
    ),
    title: json['title'] as String?,
    courseId: json['courseId'] as String?,
    isPinned: json['isPinned'] == true,
    teachingPlan: StudyTeachingPlan.tryRead(json['teachingPlan']),
    testPaperId: json['testPaperId'] as String?,
    sources: json['sources'] is List
        ? <StudySourceItem>[
            for (final source in json['sources']! as List)
              StudySourceItem.fromJson(
                Map<String, Object?>.from(source as Map),
              ),
          ]
        : null,
    messages: <StudyMessage>[
      for (final Object? message
          in (json['messages'] as List?) ?? const <Object?>[])
        StudyMessage.fromJson(message! as Map<String, Object?>),
    ],
  );

  final String id;
  final DateTime created;
  DateTime get createdAt => created;
  final DateTime updatedAt;
  final String? _title;
  final String? courseId;
  final bool isPinned;

  /// Null only for legacy conversations, which used the desk's shared sources.
  final List<StudySourceItem>? sources;
  final List<StudyMessage> messages;
  final StudyTeachingPlan? teachingPlan;
  final String? testPaperId;

  /// Its first question, in a few words.
  String get title {
    if (_title != null && _title.trim().isNotEmpty) return _title;
    for (final StudyMessage message in messages) {
      if (!message.fromUser) continue;
      final String text = message.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return text.length <= 48 ? text : '${text.substring(0, 48).trimRight()}…';
    }
    return 'New chat';
  }

  StudySession copyWith({
    List<StudyMessage>? messages,
    String? title,
    DateTime? updatedAt,
    Object? courseId = _unchangedCourse,
    bool? isPinned,
    List<StudySourceItem>? sources,
    StudyTeachingPlan? teachingPlan,
    String? testPaperId,
  }) => StudySession(
    id: id,
    created: created,
    title: title ?? _title,
    updatedAt: updatedAt ?? this.updatedAt,
    courseId: identical(courseId, _unchangedCourse)
        ? this.courseId
        : courseId as String?,
    isPinned: isPinned ?? this.isPinned,
    sources: sources ?? this.sources,
    messages: messages ?? this.messages,
    teachingPlan: teachingPlan ?? this.teachingPlan,
    testPaperId: testPaperId ?? this.testPaperId,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'created': created.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (_title != null) 'title': _title,
    if (courseId != null) 'courseId': courseId,
    'isPinned': isPinned,
    if (teachingPlan != null) 'teachingPlan': teachingPlan!.toJson(),
    if (testPaperId != null) 'testPaperId': testPaperId,
    if (sources != null)
      'sources': [for (final source in sources!) source.toJson()],
    'messages': <Object?>[
      for (final StudyMessage message in messages) message.toJson(),
    ],
  };
}

/// All that is kept of the desk between launches.
@immutable
class StudyDeskState {
  const StudyDeskState({
    this.sources = const <StudySourceItem>[],
    this.sessions = const <StudySession>[],
    this.currentSessionId,
    this.courses = const <StudyCourse>[],
    this.semanticSearch = true,
  });

  factory StudyDeskState.fromJson(Map<String, Object?> json) => StudyDeskState(
    courses: <StudyCourse>[
      for (final course in json['courses'] as List? ?? const [])
        StudyCourse.fromJson(Map<String, Object?>.from(course as Map)),
    ],
    sources: <StudySourceItem>[
      for (final Object? source
          in (json['sources'] as List?) ?? const <Object?>[])
        StudySourceItem.fromJson(source! as Map<String, Object?>),
    ],
    sessions: <StudySession>[
      for (final Object? session
          in (json['sessions'] as List?) ?? const <Object?>[])
        StudySession.fromJson(session! as Map<String, Object?>),
    ],
    currentSessionId: json['current'] as String?,
    semanticSearch: json['semantic'] != false,
  );

  final List<StudySourceItem> sources;
  final List<StudySession> sessions;
  final String? currentSessionId;
  final List<StudyCourse> courses;

  /// Whether notes on the desk are found by meaning too, which sends them to
  /// the embedding service. On unless the user turned it off.
  final bool semanticSearch;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 2,
    if (!semanticSearch) 'semantic': false,
    'courses': [for (final course in courses) course.toJson()],
    'sources': <Object?>[
      for (final StudySourceItem source in sources) source.toJson(),
    ],
    'sessions': <Object?>[
      for (final StudySession session in sessions) session.toJson(),
    ],
    if (currentSessionId != null) 'current': currentSessionId,
  };
}
