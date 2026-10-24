import '../editor/ink/ink_selection.dart';
import 'note_repository.dart';

/// The in-app clipboard that follows the user between notes.
///
/// Image bytes are read as soon as Copy or Cut runs. This keeps a cut image
/// pasteable even after its source note closes, and lets a destination note
/// own a new copy of every referenced asset.
class SharedNoteClipboard {
  int _generation = 0;
  String? _sourceNoteId;
  InkClipboard? _clipboard;
  Future<Map<String, NoteAssetData>> _assets =
      Future<Map<String, NoteAssetData>>.value(<String, NoteAssetData>{});
  final Map<String, Future<InkClipboard?>> _destinations =
      <String, Future<InkClipboard?>>{};

  bool get hasData => _clipboard != null;

  void capture(
    NoteRepository repository,
    String noteId,
    InkClipboard clipboard,
  ) {
    _generation++;
    _sourceNoteId = noteId;
    _clipboard = clipboard;
    _destinations.clear();
    final Set<String> ids = <String>{
      for (final image in clipboard.images)
        if (!image.isVector) image.assetId,
    };
    _assets =
        Future.wait(<Future<NoteAssetData?>>[
          for (final String id in ids)
            repository
                .readAsset(noteId, id)
                .then<NoteAssetData?>((NoteAssetData value) => value)
                .catchError((Object _) => null),
        ]).then(
          (List<NoteAssetData?> values) => <String, NoteAssetData>{
            for (final NoteAssetData value in values.whereType<NoteAssetData>())
              value.asset.id: value,
          },
        );
  }

  /// Returns a clipboard whose image assets belong to [destinationNoteId].
  /// Repeated opens of the same destination reuse the same copied assets.
  Future<InkClipboard?> materialize(
    NoteRepository repository,
    String destinationNoteId,
  ) {
    final InkClipboard? clipboard = _clipboard;
    if (clipboard == null) {
      return Future<InkClipboard?>.value();
    }
    if (_sourceNoteId == destinationNoteId || clipboard.images.isEmpty) {
      return Future<InkClipboard?>.value(clipboard);
    }
    return _destinations.putIfAbsent(destinationNoteId, () async {
      final int generation = _generation;
      final Map<String, NoteAssetData> assets = await _assets;
      if (generation != _generation) {
        return null;
      }
      final Map<String, String> remapped = <String, String>{};
      for (final String sourceId in <String>{
        for (final image in clipboard.images)
          if (!image.isVector) image.assetId,
      }) {
        final NoteAssetData? source = assets[sourceId];
        if (source == null) continue;
        try {
          remapped[sourceId] = await repository.storeAsset(
            destinationNoteId,
            source.bytes,
            kind: source.asset.kind,
            extension: source.asset.extension,
            fileName: source.asset.fileName,
          );
        } on Object {
          // The remaining clipboard content can still be pasted.
        }
      }
      if (generation != _generation) {
        return null;
      }
      final InkClipboard result = clipboard.remapImageAssets(remapped);
      return result.isEmpty ? null : result;
    });
  }
}
