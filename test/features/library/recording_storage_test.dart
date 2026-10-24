import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_recording_track.dart';
import 'package:greatnote/features/library/file_note_repository.dart';
import 'package:greatnote/features/library/note_repository.dart';

void main() {
  test('schema 5 migrates with no recordings or timing', () {
    final NoteContent migrated = NoteContent.fromJson(<String, Object?>{
      'schema': 5,
      'pages': <Object?>[
        <String, Object?>{
          'size': PageSize.a4Portrait.name,
          'background': PageBackground.blank.name,
          'strokes': <Object?>[
            <String, Object?>{
              'ink': InkPalette.ink.id,
              'width': 3,
              'points': <double>[0, 0, 10, 10],
            },
          ],
        },
      ],
    });
    expect(migrated.recordings, isEmpty);
    expect(migrated.pages.single.strokes.single.completedAtMs, isNull);
  });

  test('schema 6 round-trips tracks, stroke timing, and erase tombstones', () {
    final Stroke stroke = Stroke.fromPoints(
      style: const StrokeStyle(ink: InkPalette.ink, width: 3),
      points: const <InkVector>[InkVector(1, 2), InkVector(3, 4)],
      completedAtMs: 900,
      recordingId: 'rec-1',
      sampleDeltasMs: const <int>[0, 200],
    );
    final NoteContent content = NoteContent(
      <StoredPage>[
        StoredPage(
          setup: const PageSetup(),
          strokes: <Stroke>[stroke],
          erasedStrokeRecords: <ErasedStrokeRecord>[
            ErasedStrokeRecord(
              stroke: stroke,
              erasedAtMs: 1400,
              recordingId: 'rec-1',
            ),
          ],
        ),
      ],
      recordings: <NoteRecordingTrack>[
        NoteRecordingTrack(
          id: 'rec-1',
          title: 'Lecture Recording 1',
          assetPath: 'asset-audio',
          durationMs: 184500,
          createdAt: DateTime.utc(2026, 10, 23, 15, 30),
        ),
      ],
    );
    final NoteContent restored = NoteContent.fromJson(
      jsonDecode(jsonEncode(content.toJson())) as Map<String, Object?>,
    );
    expect(storageSchema, 6);
    expect(restored.recordings.single.assetPath, 'asset-audio');
    final Stroke restoredStroke = restored.pages.single.strokes.single;
    expect(restoredStroke.completedAtMs, 900);
    expect(restoredStroke.recordingId, 'rec-1');
    expect(restoredStroke.sampleDeltasMs, <int>[0, 200]);
    expect(restored.pages.single.erasedStrokeRecords.single.erasedAtMs, 1400);
    expect(
      restored.pages.single.erasedStrokeRecords.single.stroke.id,
      stroke.id,
    );
  });

  test('orphaned recording assets are purged from disk', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'greatnote-recording-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final FileNoteRepository repository = await FileNoteRepository.open(
      directory,
    );
    addTearDown(repository.dispose);
    final note = await repository.createNote(title: 'Lecture');
    final String assetId = await repository.storeAsset(
      note.id,
      Uint8List.fromList(<int>[1, 2, 3]),
      kind: NoteAssetKind.audio,
      extension: 'm4a',
    );
    expect(await repository.listAssets(note.id), hasLength(1));
    await repository.cleanupAssets(note.id, <String>{});
    expect(await repository.listAssets(note.id), isEmpty);
    await expectLater(
      repository.readAsset(note.id, assetId),
      throwsA(isA<LibraryException>()),
    );
  });
}
