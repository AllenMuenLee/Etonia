import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../backend/backend_service.dart';
import 'study_desk_models.dart';
import 'study_rag_index.dart';

// ---------------------------------------------------------------------------
// Meaning, as numbers: the second way a chunk can be found.
//
// A chunk's words, and a picture of it when words do not carry it, are turned
// into vectors by a provider (through our `embed` function, which keeps
// nothing). The vectors are kept here, on the device, by what the chunk holds,
// so that editing one page re-reads that page and no other.
// ---------------------------------------------------------------------------

/// How alike two vectors point, from -1 to 1.
double studyCosine(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  double dot = 0, na = 0, nb = 0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// What of a chunk's meaning there is to embed: its words, however they were
/// got (read from ink, typed, written in a drawing, or a PDF's own text).
String studyEmbeddingText(StudyChunk chunk) {
  final String lines = chunk.lines.map((line) => line.text).join(' ');
  final String text = <String>[
    chunk.handwriting,
    chunk.typed,
    lines,
    chunk.svgText,
    chunk.anchors.join(' '),
  ].where((part) => part.trim().isNotEmpty).join(' ');
  final String squashed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return squashed.length <= _maxText
      ? squashed
      : squashed.substring(0, _maxText);
}

const int _maxText = 3000;

/// Pictures a first-use search embeds when the request is about appearance.
const int visualPictureAllowance = 6;

/// Bound first-use embedding spend. Previously cached vectors remain usable for
/// the entire collection; new work covers a small lexical/fair-spread shortlist.
List<StudySearchDocument> studySemanticCandidates(
  List<StudySearchDocument> documents,
  String query, {
  int maxChunks = 16,
  int maxPictures = 2,
  int maxTextCharacters = 12000,
  bool visual = false,
}) {
  final ranked = StudyRetriever.retrieve(documents, query, limit: maxChunks);
  final spread = StudyRetriever.retrieve(
    documents,
    query,
    mode: StudyQueryMode.overview,
    limit: maxChunks,
  );
  // A request about how pages look is answered by their pictures, and a mark
  // is found only there. Those chunks are embedded first, and a few more
  // pictures than usual may be, since otherwise a first search sees at most
  // two of them and a note's marks are never reached.
  final marked = visual
      ? [
          for (final document in documents)
            if (document.chunk.hasMarks) StudyHit(document, 0),
        ]
      : const <StudyHit>[];
  if (visual) maxPictures = math.max(maxPictures, visualPictureAllowance);
  final selected = <StudySearchDocument>[];
  final seen = <StudyChunk>{};
  var pictures = 0;
  var characters = 0;
  for (final hit in [...ranked, ...marked, ...spread]) {
    final chunk = hit.chunk;
    if (!seen.add(chunk)) continue;
    final size = studyEmbeddingText(chunk).length;
    if (characters + size > maxTextCharacters ||
        (chunk.needsPicture && pictures >= maxPictures)) {
      continue;
    }
    selected.add(hit.document);
    characters += size;
    if (chunk.needsPicture) pictures++;
    if (selected.length >= maxChunks) break;
  }
  return selected;
}

/// A name for what a chunk holds, which changes when its meaning could: not
/// where it sits among the note's chunks, so that a page inserted before it
/// leaves it alone.
String studyChunkKey(StudyChunk chunk) {
  String bound(double v) => v.round().toString();
  final Object payload = <Object?>[
    studyEmbeddingText(chunk),
    chunk.kind.name,
    chunk.lowConfidence,
    chunk.strokeIndices.length,
    chunk.imageIds,
    chunk.stickyIds,
    bound(chunk.logicalBounds.left),
    bound(chunk.logicalBounds.top),
    bound(chunk.logicalBounds.width),
    bound(chunk.logicalBounds.height),
  ];
  return sha1.convert(utf8.encode(jsonEncode(payload))).toString();
}

/// What is known of one chunk's meaning.
@immutable
class StudyChunkVectors {
  const StudyChunkVectors({this.text, this.image, this.imageSkipped = false});

  final Float32List? text;
  final Float32List? image;

  /// A picture was wanted but could not be made or was too large: not asked
  /// for again.
  final bool imageSkipped;

  StudyChunkVectors copyWith({
    Float32List? text,
    Float32List? image,
    bool? imageSkipped,
  }) => StudyChunkVectors(
    text: text ?? this.text,
    image: image ?? this.image,
    imageSkipped: imageSkipped ?? this.imageSkipped,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (text != null) 't': encodeStudyVector(text!),
    if (image != null) 'i': encodeStudyVector(image!),
    if (imageSkipped) 'skip': true,
  };

  static StudyChunkVectors fromJson(
    Map<String, Object?> json,
  ) => StudyChunkVectors(
    text: json['t'] is String ? decodeStudyVector(json['t']! as String) : null,
    image: json['i'] is String ? decodeStudyVector(json['i']! as String) : null,
    imageSkipped: json['skip'] == true,
  );
}

String encodeStudyVector(Float32List vector) => base64Encode(
  vector.buffer.asUint8List(vector.offsetInBytes, vector.lengthInBytes),
);

/// The vector [encoded] (little-endian float32), or null if it is not one.
Float32List? decodeStudyVector(String encoded, {int? dimensions}) {
  try {
    final Uint8List bytes = Uint8List.fromList(base64Decode(encoded));
    if (bytes.isEmpty || bytes.length % 4 != 0) return null;
    final Float32List vector = bytes.buffer.asFloat32List();
    if (dimensions != null && vector.length != dimensions) return null;
    for (final double v in vector) {
      if (!v.isFinite) return null;
    }
    return vector;
  } on Object {
    return null;
  }
}

// ---------------------------------------------------------------------------
// The provider.
// ---------------------------------------------------------------------------

/// Turns words and pictures into vectors. Anything that goes wrong is a null
/// vector, never an error: search then goes on by words alone.
abstract interface class StudyEmbedder {
  /// Whether embedding is possible at all, for a user who can use it.
  bool get isAvailable;

  /// Vectors for [texts] as parts of notes, in order; null where one failed.
  Future<List<Float32List?>> embedTexts(List<String> texts);

  /// Vectors for [pngs], in order; null where one failed.
  Future<List<Float32List?>> embedImages(List<Uint8List> pngs);

  /// A vector for a question, or null.
  Future<Float32List?> embedQuery(String text);
}

typedef StudyEmbedInvoke =
    Future<Map<String, dynamic>> Function(String, Map<String, Object?>);

/// Our `embed` function: it takes sixteen inputs at a time and keeps nothing.
class BackendStudyEmbedder implements StudyEmbedder {
  BackendStudyEmbedder({BackendService? backend, this.invoke})
    : _backend = backend ?? BackendService.instance;

  final BackendService _backend;
  final StudyEmbedInvoke? invoke;

  static const int batchSize = 16;
  static const int dimensions = 768;

  /// After the account has no credit, no plan, or is being limited, asking
  /// again would only be refused: not before this long.
  static const Duration backOff = Duration(minutes: 10);
  DateTime? _blockedUntil;
  DateTime Function() clock = DateTime.now;

  @override
  bool get isAvailable =>
      invoke != null || (_backend.isConfigured && _backend.userId != null);

  bool get _blocked =>
      _blockedUntil != null && clock().isBefore(_blockedUntil!);

  static String _requestId() {
    final math.Random random = math.Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final String hex = bytes
        .map((int v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<List<Float32List?>> _embed(
    String kind,
    List<Map<String, String>> inputs,
  ) async {
    final List<Float32List?> out = List<Float32List?>.filled(
      inputs.length,
      null,
    );
    for (int start = 0; start < inputs.length; start += batchSize) {
      if (_blocked || !isAvailable) break;
      final int end = math.min(start + batchSize, inputs.length);
      try {
        final Map<String, dynamic> answer =
            await (invoke ?? _backend.invoke)('embed', <String, Object?>{
              'requestId': _requestId(),
              'kind': kind,
              'inputs': inputs.sublist(start, end),
            });
        final Object? list = answer['embeddings'];
        if (list is! List || list.length != end - start) continue;
        for (int i = 0; i < list.length; i++) {
          final Object? item = list[i];
          if (item is String) {
            out[start + i] = decodeStudyVector(item, dimensions: dimensions);
          }
        }
      } on BackendFailure catch (failure) {
        if (const <String>{
          'plan_required',
          'insufficient_credits',
          'rate_limited',
          'unauthorized',
          'not_configured',
        }.contains(failure.code)) {
          _blockedUntil = clock().add(backOff);
          break;
        }
      } on Object {
        // Whatever it was, these are searched by words.
      }
    }
    return out;
  }

  @override
  Future<List<Float32List?>> embedTexts(List<String> texts) =>
      _embed('document', <Map<String, String>>[
        for (final String text in texts) <String, String>{'text': text},
      ]);

  @override
  Future<List<Float32List?>> embedImages(List<Uint8List> pngs) =>
      _embed('document', <Map<String, String>>[
        for (final Uint8List png in pngs)
          <String, String>{'image': base64Encode(png)},
      ]);

  @override
  Future<Float32List?> embedQuery(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final List<Float32List?> vectors = await _embed(
      'query',
      <Map<String, String>>[
        <String, String>{
          'text': trimmed.length <= 1500 ? trimmed : trimmed.substring(0, 1500),
        },
      ],
    );
    return vectors.first;
  }
}

// ---------------------------------------------------------------------------
// Keeping them.
// ---------------------------------------------------------------------------

/// Vectors on disk between launches, by note and then by [studyChunkKey]. A
/// cache only: what is lost is asked for again.
abstract interface class StudyVectorDiskCache {
  Future<Map<String, StudyChunkVectors>> read(String noteId);
  Future<void> write(String noteId, Map<String, StudyChunkVectors> vectors);
  Future<void> retain(Set<String> noteIds);
}

class FileStudyVectorCache implements StudyVectorDiskCache {
  FileStudyVectorCache(this.directory);

  final Directory directory;

  /// Moves on when what the vectors mean changes (another model, other
  /// dimensions, another way of making the text), so that old ones go unused.
  static const int version = 1;

  File _file(String noteId) => File('${directory.path}/$noteId.json');

  @override
  Future<Map<String, StudyChunkVectors>> read(String noteId) async {
    try {
      final File file = _file(noteId);
      if (!await file.exists()) return <String, StudyChunkVectors>{};
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?> ||
          json['version'] != version ||
          json['dimensions'] != BackendStudyEmbedder.dimensions) {
        return <String, StudyChunkVectors>{};
      }
      return <String, StudyChunkVectors>{
        for (final MapEntry<String, Object?> entry
            in (json['vectors']! as Map<String, Object?>).entries)
          entry.key: StudyChunkVectors.fromJson(
            entry.value! as Map<String, Object?>,
          ),
      };
    } on Object {
      return <String, StudyChunkVectors>{};
    }
  }

  @override
  Future<void> write(
    String noteId,
    Map<String, StudyChunkVectors> vectors,
  ) async {
    try {
      await directory.create(recursive: true);
      final File file = _file(noteId);
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(<String, Object?>{
          'version': version,
          'dimensions': BackendStudyEmbedder.dimensions,
          'vectors': <String, Object?>{
            for (final MapEntry<String, StudyChunkVectors> e in vectors.entries)
              e.key: e.value.toJson(),
          },
        }),
      );
      await temporary.rename(file.path);
    } on Object {
      // Asked for again next time.
    }
  }

  @override
  Future<void> retain(Set<String> noteIds) async {
    try {
      if (!await directory.exists()) return;
      await for (final FileSystemEntity entity in directory.list()) {
        final String name = entity.uri.pathSegments.last;
        if (entity is! File || !name.endsWith('.json')) continue;
        final String id = name.substring(0, name.length - '.json'.length);
        if (!noteIds.contains(id)) await entity.delete();
      }
    } on Object {
      // Tried again on the next launch.
    }
  }
}

/// The vectors cache of the library at [libraryDirectory], if it has a disk.
StudyVectorDiskCache? studyVectorCacheIn(Directory? libraryDirectory) =>
    libraryDirectory == null
    ? null
    : FileStudyVectorCache(Directory('${libraryDirectory.path}/study_vectors'));

/// What search can use of meaning for one question: the question's vector and
/// what is known of each chunk's.
class StudyVectorSignal {
  const StudyVectorSignal({
    required this.query,
    required this.lookup,
    this.visual,
  });

  final Float32List query;

  /// The vector of a sentence saying how the sought page looks, matched only
  /// against pictures. Null when the question is not about appearance.
  final Float32List? visual;
  final StudyChunkVectors? Function(StudyChunk chunk) lookup;
}

/// Works out, keeps, and looks up chunk vectors.
class StudyVectorIndex {
  StudyVectorIndex({
    required this.embedder,
    this.renderer,
    this.diskCache,
    this.maxImagesPerRun = 60,
    this.maxImageBytes = 1000000,
    this.queryTimeout = const Duration(seconds: 4),
  });

  final StudyEmbedder embedder;

  /// Draws a chunk, for those that words do not carry.
  final StudyChunkRenderer? renderer;
  final StudyVectorDiskCache? diskCache;

  /// Pictures asked for per note in one run: the rest wait for the next. A
  /// textbook is not all embedded at once.
  final int maxImagesPerRun;
  final int maxImageBytes;
  final Duration queryTimeout;

  final Map<String, Map<String, StudyChunkVectors>> _memory = {};
  final Map<String, Future<void>> _running = {};
  final Map<String, Float32List?> _queries = <String, Float32List?>{};
  final Map<String, Future<Float32List?>> _queryRunning = {};

  /// How many notes' vectors were asked of the provider: for tests.
  @visibleForTesting
  int runs = 0;

  bool get isAvailable => embedder.isAvailable;

  /// Brings [chunks] of [noteId] up to date, once at a time for a note. The
  /// returned future ends when this run does; a caller may stop waiting sooner
  /// without stopping it.
  Future<void> ensure(
    String noteId,
    List<StudyChunk> chunks, {
    bool partial = false,
  }) {
    if (!isAvailable) return Future<void>.value();
    final Future<void>? running = _running[noteId];
    if (running != null) {
      // Chunks that came after it started are picked up by a second run.
      return running.then((_) => ensure(noteId, chunks, partial: partial));
    }
    final Future<void> run = _run(noteId, chunks, partial: partial)
        .whenComplete(() {
          _running.remove(noteId);
        });
    return _running[noteId] = run;
  }

  Future<void> _run(
    String noteId,
    List<StudyChunk> chunks, {
    bool partial = false,
  }) async {
    final Map<String, StudyChunkVectors> known = await _load(noteId);
    final Map<String, StudyChunk> wanted = <String, StudyChunk>{
      for (final StudyChunk chunk in chunks) studyChunkKey(chunk): chunk,
    };
    bool changed = false;

    final List<String> needText = <String>[
      for (final MapEntry<String, StudyChunk> e in wanted.entries)
        if (known[e.key]?.text == null &&
            studyEmbeddingText(e.value).isNotEmpty)
          e.key,
    ];
    if (needText.isNotEmpty) {
      runs++;
      final List<Float32List?> vectors = await embedder.embedTexts(<String>[
        for (final String key in needText) studyEmbeddingText(wanted[key]!),
      ]);
      for (int i = 0; i < needText.length; i++) {
        final Float32List? vector = vectors[i];
        if (vector == null) continue;
        known[needText[i]] = (known[needText[i]] ?? const StudyChunkVectors())
            .copyWith(text: vector);
        changed = true;
      }
      if (changed) {
        await _save(noteId, known, wanted.keys.toSet(), prune: !partial);
      }
    }

    final StudyChunkRenderer? draw = renderer;
    if (draw != null) {
      final List<String> needImage = <String>[
        for (final MapEntry<String, StudyChunk> e in wanted.entries)
          if (e.value.needsPicture &&
              known[e.key]?.image == null &&
              known[e.key]?.imageSkipped != true)
            e.key,
      ].take(maxImagesPerRun).toList();
      final List<String> keys = <String>[];
      final List<Uint8List> pngs = <Uint8List>[];
      for (final String key in needImage) {
        Uint8List? png;
        try {
          png = (await draw.render(wanted[key]!))?.png;
        } on Object {
          png = null;
        }
        if (png == null || png.length > maxImageBytes) {
          known[key] = (known[key] ?? const StudyChunkVectors()).copyWith(
            imageSkipped: true,
          );
          changed = true;
          continue;
        }
        keys.add(key);
        pngs.add(png);
      }
      if (pngs.isNotEmpty) {
        runs++;
        final List<Float32List?> vectors = await embedder.embedImages(pngs);
        for (int i = 0; i < keys.length; i++) {
          final Float32List? vector = vectors[i];
          if (vector == null) continue;
          known[keys[i]] = (known[keys[i]] ?? const StudyChunkVectors())
              .copyWith(image: vector);
          changed = true;
        }
      }
      if (changed) {
        await _save(noteId, known, wanted.keys.toSet(), prune: !partial);
      }
    }
  }

  Future<Map<String, StudyChunkVectors>> _load(String noteId) async =>
      _memory[noteId] ??=
          await diskCache?.read(noteId) ?? <String, StudyChunkVectors>{};

  Future<void> _save(
    String noteId,
    Map<String, StudyChunkVectors> known,
    Set<String> live, {
    bool prune = true,
  }) async {
    // Vectors of chunks that no longer exist go, so a note's file stays as big
    // as the note.
    if (prune) known.removeWhere((String key, _) => !live.contains(key));
    await diskCache?.write(noteId, Map<String, StudyChunkVectors>.of(known));
  }

  /// What is known of [chunk] now, without asking anyone.
  StudyChunkVectors? lookup(StudyChunk chunk) =>
      _memory[chunk.noteId]?[studyChunkKey(chunk)];

  /// Loads [noteIds]' vectors from disk, so that [lookup] can answer.
  Future<void> load(Iterable<String> noteIds) async {
    for (final String id in noteIds) {
      await _load(id);
    }
  }

  /// Brings the notes up to date and embeds [question], waiting no longer than
  /// [queryTimeout] for either. Null when meaning cannot be used: search then
  /// goes by words. What was not done in time carries on for the next question.
  ///
  /// [visualQuery], if given, is embedded too, to be matched against pictures.
  /// Without it, or when it is slow or fails, only the picture search by the
  /// question itself is lost, not the signal.
  Future<StudyVectorSignal?> signalFor(
    String question,
    Map<String, List<StudyChunk>> chunksByNote, {
    bool partial = false,
    String visualQuery = '',
  }) async {
    if (!isAvailable) return null;
    final Future<Float32List?> query = _queryVector(question);
    final bool wantsVisual =
        visualQuery.trim().isNotEmpty && visualQuery.trim() != question.trim();
    final Future<Float32List?> visual = wantsVisual
        ? _queryVector(visualQuery).catchError((Object _) => null)
        : Future<Float32List?>.value(null);
    final Future<void> indexing = Future.wait(<Future<void>>[
      for (final MapEntry<String, List<StudyChunk>> e in chunksByNote.entries)
        ensure(e.key, e.value, partial: partial),
    ]).then((_) {});
    // The question waits for its vector, and for the notes only as long as
    // the timeout lets it; a note already done is not waited for at all.
    final Float32List? vector = await query.timeout(
      queryTimeout,
      onTimeout: () => null,
    );
    final Float32List? visualVector = await visual.timeout(
      queryTimeout,
      onTimeout: () => null,
    );
    await indexing.timeout(queryTimeout, onTimeout: () {});
    if (vector == null) return null;
    await load(chunksByNote.keys);
    return StudyVectorSignal(
      query: vector,
      visual: visualVector,
      lookup: lookup,
    );
  }

  Future<Float32List?> _queryVector(String question) {
    final String key = question.trim();
    if (_queries.containsKey(key)) return Future.value(_queries[key]);
    final running = _queryRunning[key];
    if (running != null) return running;
    final pending = embedder
        .embedQuery(key)
        .then((vector) {
          if (vector != null) {
            if (_queries.length >= 32) _queries.remove(_queries.keys.first);
            _queries[key] = vector;
          }
          return vector;
        })
        .whenComplete(() {
          _queryRunning.remove(key);
        });
    _queryRunning[key] = pending;
    return pending;
  }

  /// Lets go of every note but [noteIds].
  Future<void> retain(Set<String> noteIds) async {
    _memory.removeWhere((String id, _) => !noteIds.contains(id));
    await diskCache?.retain(noteIds);
  }
}
