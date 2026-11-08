import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_visual_context.dart';

String described({
  String panel = 'A',
  String description =
      r'V = I R. A right-pointing arrow links the source to a resistor.',
}) => jsonEncode({
  'panels': [
    {
      'panel': panel,
      'description': description,
      'uncertainties': ['The resistor subscript is unreadable.'],
    },
  ],
});

void main() {
  test(
    'the parser preserves exact expressions and uncertainty and rejects wrong panels',
    () {
      final value = StudyVisualDescription.parse(
        '```json\n${described()}\n```',
        1,
      )!;
      expect(value.panels.single.description, contains('V = I R'));
      expect(value.panels.single.uncertainties.single, contains('unreadable'));
      expect(StudyVisualDescription.parse(described(panel: 'B'), 1), isNull);
      expect(
        StudyVisualDescription.parse(described(description: 'x' * 6001), 1),
        isNull,
      );
      expect(StudyVisualDescription.parse('{"panels":[]}', 1), isNull);
    },
  );
  test(
    'concurrent reads share one call, edited pixels and model scopes invalidate, and cache expires',
    () async {
      var now = DateTime(2026, 11, 7);
      final reader = StudyVisualContextReader(clock: () => now, maxEntries: 2);
      var calls = 0;
      final gate = Completer<AiResult>();
      Future<AiResult> send() {
        calls++;
        return gate.future;
      }

      final image = Uint8List.fromList([1, 2, 3]);
      final first = reader.read(
        image: image,
        panelCount: 1,
        modelScope: 'haiku',
        send: send,
      );
      final second = reader.read(
        image: Uint8List.fromList([1, 2, 3]),
        panelCount: 1,
        modelScope: 'haiku',
        send: send,
      );
      expect(calls, 1);
      gate.complete(AiSuccess(described()));
      await Future.wait([first, second]);
      await reader.read(
        image: image,
        panelCount: 1,
        modelScope: 'haiku',
        send: send,
      );
      expect(calls, 1);
      await reader.read(
        image: image,
        panelCount: 1,
        modelScope: 'luna',
        send: send,
      );
      expect(calls, 2);
      await reader.read(
        image: Uint8List.fromList([1, 2, 4]),
        panelCount: 1,
        modelScope: 'luna',
        send: send,
      );
      expect(calls, 3);
      now = now.add(const Duration(minutes: 11));
      await reader.read(
        image: image,
        panelCount: 1,
        modelScope: 'luna',
        send: send,
      );
      expect(calls, 4);
    },
  );
  test(
    'memory release prevents a pending old read from repopulating the cache',
    () async {
      final reader = StudyVisualContextReader();
      final gate = Completer<AiResult>();
      final image = Uint8List.fromList([1]);
      final old = reader.read(
        image: image,
        panelCount: 1,
        modelScope: 'haiku',
        send: () => gate.future,
      );
      reader.clear();
      gate.complete(AiSuccess(described()));
      await old;
      var calls = 0;
      await reader.read(
        image: image,
        panelCount: 1,
        modelScope: 'haiku',
        send: () async {
          calls++;
          return AiSuccess(described());
        },
      );
      expect(calls, 1);
    },
  );
  test(
    'malformed descriptions and provider failures are never cached',
    () async {
      final reader = StudyVisualContextReader();
      final image = Uint8List.fromList([7]);
      await expectLater(
        reader.read(
          image: image,
          panelCount: 1,
          modelScope: 'haiku',
          send: () async => const AiSuccess('not JSON'),
        ),
        throwsA(isA<AiFailure>()),
      );
      await expectLater(
        reader.read(
          image: image,
          panelCount: 1,
          modelScope: 'haiku',
          send: () async => const AiError(AiFailure(AiFailureKind.network)),
        ),
        throwsA(isA<AiFailure>()),
      );
      expect(
        await reader.read(
          image: image,
          panelCount: 1,
          modelScope: 'haiku',
          send: () async => AiSuccess(described()),
        ),
        isA<StudyVisualDescription>(),
      );
    },
  );
  test(
    'transcriptions use current source IDs and original bounds while all image/SVG payload is removed',
    () {
      const chunk = StudyChunk(
        noteId: 'note',
        pageIndex: 1,
        chunkIndex: 4,
        kind: StudyChunkKind.diagram,
        logicalBounds: Rect.fromLTWH(20, 30, 200, 100),
      );
      StudyPayload source(int note) => StudyPayload(
        contextText:
            '[Source N$note:P2:C4 | Note: "Circuits", Page 2]\nPicture panel A of the attached image.\n\nCitable lines of panel A\n<svg>OLD_COORDINATES</svg>',
        imagePng: Uint8List.fromList([1, 2, 3]),
        map: StudySourceMap(
          noteIds: {note: 'note'},
          chunks: [],
          crops: {chunk: chunk.logicalBounds},
        ),
        panelCount: 1,
        estimatedTextTokens: 30,
      );
      final description = StudyVisualDescription.parse(described(), 1)!;
      final converted = description.apply(source(3));
      expect(converted.imagePng, StudyContextAssembler.placeholderPng);
      expect(converted.panelCount, 0);
      expect(converted.contextText, contains('[Source N3:P2:C4 |'));
      expect(converted.contextText, contains('V = I R'));
      expect(converted.contextText, isNot(contains('OLD_COORDINATES')));
      expect(converted.map.chunkOn('note', 1, 4), same(chunk));
      expect(converted.map.crops[chunk], chunk.logicalBounds);
      final rebound = description.apply(source(9));
      expect(rebound.contextText, contains('N9:P2:C4'));
      expect(rebound.contextText, isNot(contains('N3:P2:C4')));
    },
  );
}
