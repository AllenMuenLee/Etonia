import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'library_models.dart';
import 'note_content.dart';
import 'note_repository.dart';

Map<String, Object?> _decodeNoteJson(String encoded) {
  final Object? decoded = jsonDecode(encoded);
  if (decoded is! Map<String, Object?>) {
    throw const StorageFormatException('Not a note.');
  }
  return decoded;
}

/// Stores the library under one directory: `library.json`, the index of
/// folders and notes, and `notes/<id>.json`, one file of pages and ink per
/// note.
///
/// Every file is written to a temporary file first and then renamed over
/// the old one, so a crash leaves either the old file or the new one, never
/// half of one. A note whose file cannot be read fails to open with a
/// [StorageFormatException]; the rest of the library is unaffected.
class FileNoteRepository extends IndexedNoteRepository {
  FileNoteRepository._(
    this.directory, {
    super.clock,
    super.newId,
    super.folders,
    super.notes,
    super.trash,
  });

  /// Reads the library in [directory], creating it if needed.
  static Future<FileNoteRepository> open(
    Directory directory, {
    DateTime Function()? clock,
    String Function()? newId,
  }) async {
    await Directory('${directory.path}/notes').create(recursive: true);
    final File index = File('${directory.path}/$_indexName');
    List<Folder> folders = const <Folder>[];
    List<NoteEntry> notes = const <NoteEntry>[];
    List<NoteEntry> trash = const <NoteEntry>[];
    if (await index.exists()) {
      final Map<String, Object?> json =
          jsonDecode(await index.readAsString()) as Map<String, Object?>;
      checkSchema(json);
      folders = <Folder>[
        for (final Object? folder in (json['folders'] as List?) ?? <Object?>[])
          Folder.fromJson(folder! as Map<String, Object?>),
      ];
      notes = <NoteEntry>[
        for (final Object? note in (json['notes'] as List?) ?? <Object?>[])
          NoteEntry.fromJson(note! as Map<String, Object?>),
      ];
      trash = <NoteEntry>[
        for (final Object? note in (json['trash'] as List?) ?? <Object?>[])
          NoteEntry.fromJson(note! as Map<String, Object?>),
      ];
    }
    return FileNoteRepository._(
      directory,
      clock: clock,
      newId: newId,
      folders: folders,
      notes: notes,
      trash: trash,
    );
  }

  /// The library in the app's documents directory.
  static Future<FileNoteRepository> openDefault() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return open(Directory('${documents.path}/greatnote'));
  }

  static const String _indexName = 'library.json';

  final Directory directory;

  File _noteFile(String id) => File('${directory.path}/notes/$id.json');
  Directory _assetDirectory(String id) =>
      Directory('${directory.path}/notes/$id.assets');
  File _assetManifest(String id) =>
      File('${_assetDirectory(id).path}/manifest.json');

  @override
  Future<void> writeIndex() {
    return _writeAtomically(
      File('${directory.path}/$_indexName'),
      jsonEncode(indexToJson()),
    );
  }

  @override
  Future<NoteContent> readContent(String id) async {
    final File file = _noteFile(id);
    if (!await file.exists()) {
      return NoteContent.blank();
    }
    try {
      final String encoded = await file.readAsString();
      // Small notes avoid isolate startup cost. Large notes transfer only
      // JSON values, never ui.Path / NoteDocument / controllers.
      if (encoded.length >= 512 * 1024) {
        final task = TimelineTask()..start('note.hydrateLarge');
        try {
          final json = await compute(
            _decodeNoteJson,
            encoded,
            debugLabel: 'note.jsonDecode',
          );
          return await NoteContent.fromJsonIncrementally(json);
        } finally {
          task.finish();
        }
      }
      final json = Timeline.timeSync(
        'note.jsonDecode',
        () => _decodeNoteJson(encoded),
      );
      return Timeline.timeSync(
        'note.materialize',
        () => NoteContent.fromJson(json),
      );
    } on StorageFormatException {
      rethrow;
    } on Object catch (error) {
      throw StorageFormatException('Could not read the note: $error');
    }
  }

  @override
  Future<void> writeContent(String id, NoteContent content) {
    return _writeAtomically(_noteFile(id), jsonEncode(content.toJson()));
  }

  @override
  Future<void> deleteContent(String id) async {
    final File file = _noteFile(id);
    if (await file.exists()) {
      await file.delete();
    }
    final Directory assets = _assetDirectory(id);
    if (await assets.exists()) {
      await assets.delete(recursive: true);
    }
  }

  Future<Map<String, NoteAsset>> _readAssetManifest(String noteId) async {
    final File manifest = _assetManifest(noteId);
    if (!await manifest.exists()) {
      return <String, NoteAsset>{};
    }
    final Object? decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const StorageFormatException('Invalid asset manifest.');
    }
    final Map<String, NoteAsset> assets = <String, NoteAsset>{};
    for (final Object? raw in (decoded['assets'] as List?) ?? <Object?>[]) {
      final Map<String, Object?> json = raw! as Map<String, Object?>;
      final String id = json['id']! as String;
      assets[id] = NoteAsset(
        id: id,
        kind: NoteAssetKind.values.byName(json['kind']! as String),
        extension: json['extension']! as String,
        fileName: json['fileName'] as String?,
      );
    }
    return assets;
  }

  Future<void> _writeAssetManifest(String noteId, Iterable<NoteAsset> assets) {
    return _writeAtomically(
      _assetManifest(noteId),
      jsonEncode(<String, Object?>{
        'schema': storageSchema,
        'assets': <Object?>[
          for (final NoteAsset asset in assets)
            <String, Object?>{
              'id': asset.id,
              'kind': asset.kind.name,
              'extension': asset.extension,
              'fileName': asset.fileName,
            },
        ],
      }),
    );
  }

  File _assetFile(String noteId, NoteAsset asset) =>
      File('${_assetDirectory(noteId).path}/${asset.id}.${asset.extension}');

  @override
  Future<String> storeAsset(
    String noteId,
    Uint8List bytes, {
    required NoteAssetKind kind,
    required String extension,
    String? fileName,
  }) async {
    if (!noteIndex.any((NoteEntry note) => note.id == noteId)) {
      throw LibraryException('No note $noteId.');
    }
    final Directory assets = _assetDirectory(noteId);
    await assets.create(recursive: true);
    final Map<String, NoteAsset> manifest = await _readAssetManifest(noteId);
    final String base =
        'asset-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    String id = base;
    for (int suffix = 2; manifest.containsKey(id); suffix++) {
      id = '$base-$suffix';
    }
    final NoteAsset asset = NoteAsset(
      id: id,
      kind: kind,
      extension: extension.toLowerCase().replaceAll('.', ''),
      fileName: fileName,
    );
    final File target = _assetFile(noteId, asset);
    final File temporary = File('${target.path}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      manifest[id] = asset;
      await _writeAssetManifest(noteId, manifest.values);
      return id;
    } on Object {
      if (await temporary.exists()) {
        await temporary.delete();
      }
      if (await target.exists()) {
        await target.delete();
      }
      rethrow;
    }
  }

  @override
  Future<NoteAssetData> readAsset(String noteId, String assetId) async {
    final NoteAsset? asset = (await _readAssetManifest(noteId))[assetId];
    if (asset == null) {
      throw LibraryException('No asset $assetId.');
    }
    final File file = _assetFile(noteId, asset);
    try {
      return NoteAssetData(asset: asset, bytes: await file.readAsBytes());
    } on Object catch (error) {
      throw StorageFormatException('Could not read asset $assetId: $error');
    }
  }

  @override
  Future<List<NoteAsset>> listAssets(String noteId) async {
    return List<NoteAsset>.unmodifiable(
      (await _readAssetManifest(noteId)).values,
    );
  }

  @override
  Future<void> removeAsset(String noteId, String assetId) async {
    final Map<String, NoteAsset> manifest = await _readAssetManifest(noteId);
    final NoteAsset? asset = manifest.remove(assetId);
    if (asset == null) {
      return;
    }
    final File file = _assetFile(noteId, asset);
    if (await file.exists()) {
      await file.delete();
    }
    await _writeAssetManifest(noteId, manifest.values);
  }

  @override
  Future<void> cleanupAssets(
    String noteId,
    Set<String> referencedAssetIds,
  ) async {
    for (final NoteAsset asset in await listAssets(noteId)) {
      if (!referencedAssetIds.contains(asset.id)) {
        await removeAsset(noteId, asset.id);
      }
    }
  }

  @override
  Future<void> copyAssets(String fromNoteId, String toNoteId) async {
    final Map<String, NoteAsset> source = await _readAssetManifest(fromNoteId);
    if (source.isEmpty) {
      return;
    }
    final Directory targetDirectory = _assetDirectory(toNoteId);
    await targetDirectory.create(recursive: true);
    try {
      for (final NoteAsset asset in source.values) {
        final File target = _assetFile(toNoteId, asset);
        final File temporary = File('${target.path}.tmp');
        await _assetFile(fromNoteId, asset).copy(temporary.path);
        await temporary.rename(target.path);
      }
      await _writeAssetManifest(toNoteId, source.values);
    } on Object {
      if (await targetDirectory.exists()) {
        await targetDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  static Future<void> _writeAtomically(File file, String text) async {
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }
}
