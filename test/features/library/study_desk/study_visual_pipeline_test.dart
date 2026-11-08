import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/backend_ai_client.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';

final _sourcePng = Uint8List.fromList([
  ...StudyContextAssembler.placeholderPng,
  1,
]);
const _description =
    '{"panels":[{"panel":"A","description":"A force arrow points right. The formula is F = m a.","uncertainties":["The handwritten mass subscript is unclear."]}]}';

class _Renderer implements StudyChunkRenderer {
  @override
  Future<StudyCrop?> render(StudyChunk chunk) async => StudyCrop(
    chunk: chunk,
    png: _sourcePng,
    logicalBounds: chunk.logicalBounds,
    svg: '<svg>ORIGINAL_PIXEL_COORDINATES</svg>',
  );
  @override
  Future<Uint8List> combine(List<StudyCrop> crops) async => _sourcePng;
}

class _Harness {
  late StudyDeskController desk;
  final calls = <Map<String, Object?>>[];
  final progress = <StudyRequestProgress>[];
  bool malformed = false;
  AiModelId previewModel = AiModelId.sol;
  Completer<AiModelId>? previewGate;
  bool disposed = false;

  void disposeDesk() {
    if (disposed) return;
    disposed = true;
    desk.dispose();
  }

  Completer<String>? descriptionGate;

  Future<void> load() async {
    final repo = InMemoryNoteRepository();
    final note = await repo.createNote(title: 'Physics diagrams');
    await repo.saveNote(
      note.id,
      NoteContent([
        StoredPage(
          setup: const PageSetup(),
          strokes: const [],
          images: [
            NoteImageElement(
              id: 'force',
              assetId: '',
              pixelSize: const Size(200, 100),
              center: const InkVector(200, 200),
              size: const Size(200, 100),
              vector: EditableSvg.parse(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100"><title>Force diagram</title><path d="M10 50 L180 50"/><text x="20" y="20">F = m a</text></svg>',
              ),
            ),
          ],
        ),
      ]),
    );
    final client = BackendAiClient(
      invoke: (_, body) async {
        calls.add(body);
        if (body['routeOnly'] == true) {
          return {
            'routePreview': true,
            'servedBy': {
              'model':
                  (previewGate == null
                          ? previewModel
                          : await previewGate!.future)
                      .name,
              'effort': 'medium',
            },
          };
        }
        final task = (body['routing'] as Map)['task'];
        final String answer;
        if (task == 'study.plan') {
          answer =
              '{"intent":"question","difficulty":2,"retrieval":{"notes":true,"mistakeIndices":[],"query":"force diagram","depth":"brief"}}';
        } else if (task == 'study.describe') {
          answer = descriptionGate == null
              ? (malformed ? '{}' : _description)
              : await descriptionGate!.future;
        } else if (task == 'study.suggestions') {
          answer = '{"questions":["Why?","An example?","What next?"]}';
        } else {
          final source = RegExp(
            r'\[Source (N\d+:P\d+:C\d+) \|',
          ).firstMatch(body['prompt']! as String)?.group(1);
          answer =
              'Force changes motion.${source == null ? '' : ' [[$source]]'}';
        }
        return {
          'answer': answer,
          'responseFormat': body['responseFormat'],
          'usage': {'inputTokens': 10, 'outputTokens': 20},
        };
      },
    );
    desk = StudyDeskController(
      repository: repo,
      client: client,
      store: InMemoryStudyDeskStore(),
      renderer: _Renderer(),
    );
    await desk.load();
    desk.semanticSearch = false;
    desk.addNotes([note.id]);
    desk.addListener(() {
      final work = desk.requestProgress;
      if (work != null) progress.add(work);
    });
    addTearDown(() {
      disposeDesk();
      client.close();
      repo.dispose();
    });
  }

  List<Map<String, Object?>> task(String name) => calls
      .where(
        (c) => c['routeOnly'] != true && (c['routing'] as Map)['task'] == name,
      )
      .toList();
  List<Map<String, Object?>> get previews =>
      calls.where((c) => c['routeOnly'] == true).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final model in [AiModelId.haiku, AiModelId.luna]) {
    test(
      'router-selected ${model.name} answers the image directly without a reader',
      () async {
        final h = _Harness()..previewModel = model;
        await h.load();
        await h.desk.send('Explain the force diagram.');
        expect(h.desk.failure, isNull);
        expect(h.previews, hasLength(1));
        final preview = h.previews.single;
        expect(preview['selectedImage'], base64Encode(_sourcePng));
        expect((preview['routing'] as Map)['needsVision'], true);
        expect(h.task('study.describe'), isEmpty);
        final answer = h.task('study.answer').single;
        expect(answer['selectedImage'], base64Encode(_sourcePng));
        expect((answer['routing'] as Map)['allowedModels'], [model.name]);
        expect((answer['routing'] as Map)['needsVision'], true);
        expect((answer['routing'] as Map)['diagrams'], true);
        expect(answer['prompt'], preview['prompt']);
        expect(answer['systemInstruction'], preview['systemInstruction']);
        expect(
          answer['systemInstruction'],
          isNot(contains('Visual transcriptions are fallible')),
        );
        expect(answer['prompt'], isNot(contains('ORIGINAL_PIXEL_COORDINATES')));
        expect(
          h.progress.any((p) => p.phase == StudyProgressPhase.describing),
          false,
        );
        expect(
          h.progress.any((p) => p.phase == StudyProgressPhase.answering),
          true,
        );
        expect(h.desk.messages.last.citationsOf(1), isNotEmpty);

        // Recheck each answer, rather than reusing the previous turn's model.
        h.previewModel = AiModelId.sol;
        await h.desk.send('Explain the arrow in the same diagram.');
        expect(h.previews, hasLength(2));
        expect(h.task('study.describe'), hasLength(1));
        expect(
          h.task('study.answer').last['selectedImage'],
          base64Encode(StudyContextAssembler.placeholderPng),
        );
      },
    );
  }
  test(
    'a chat cancelled during route selection never sends pixels or starts a reader',
    () async {
      final h = _Harness()..previewGate = Completer<AiModelId>();
      await h.load();
      final sent = h.desk.send('Explain the force diagram.');
      for (var i = 0; i < 200 && h.previews.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(h.previews, hasLength(1));
      h.disposeDesk();
      h.previewGate!.complete(AiModelId.luna);
      await sent;
      expect(h.task('study.describe'), isEmpty);
      expect(h.task('study.answer'), isEmpty);
    },
  );
  test(
    'a cached reader result is bypassed when the next answer is lightweight',
    () async {
      final h = _Harness();
      await h.load();
      await h.desk.send('Explain the force diagram.');
      expect(h.task('study.describe'), hasLength(1));
      final progressBefore = h.progress.length;
      h.previewModel = AiModelId.luna;
      await h.desk.send('Explain the arrow in the same diagram.');
      expect(h.task('study.describe'), hasLength(1));
      expect(
        h.task('study.answer').last['selectedImage'],
        base64Encode(_sourcePng),
      );
      expect(
        h.task('study.answer').last['prompt'],
        isNot(contains('Visual transcriptions')),
      );
      expect(
        h.progress
            .skip(progressBefore)
            .any((p) => p.phase == StudyProgressPhase.describing),
        false,
      );
    },
  );
  test(
    'only the lightweight stage gets pixels; the tutor gets detailed text and original citations; cache avoids repeat calls',
    () async {
      final h = _Harness();
      await h.load();
      await h.desk.send('Explain the force diagram.');
      expect(h.task('study.describe'), hasLength(1));
      final describe = h.task('study.describe').single;
      expect(describe['selectedImage'], base64Encode(_sourcePng));
      final routing = describe['routing']! as Map;
      expect(routing['effort'], 'medium');
      expect((routing['allowedModels'] as List).toSet(), {'haiku', 'luna'});
      expect(h.task('study.answer'), hasLength(1));
      final answer = h.task('study.answer').single;
      expect(
        answer['selectedImage'],
        base64Encode(StudyContextAssembler.placeholderPng),
      );
      expect(answer['prompt'], contains('F = m a'));
      expect(answer['prompt'], contains('subscript is unclear'));
      expect(answer['prompt'], isNot(contains('ORIGINAL_PIXEL_COORDINATES')));
      expect((answer['routing']! as Map)['needsVision'], false);
      expect((answer['routing']! as Map)['difficulty'], 3);
      expect(describe['turnId'], answer['turnId']);
      expect(h.desk.messages.last.citationsOf(1), isNotEmpty);
      expect(
        h.progress.any(
          (p) =>
              p.phase == StudyProgressPhase.searching &&
              p.query == 'force diagram',
        ),
        true,
      );
      expect(
        h.progress.any(
          (p) =>
              p.phase == StudyProgressPhase.describing &&
              p.sources.any(
                (s) => s.title == 'Physics diagrams' && s.page == 1,
              ),
        ),
        true,
      );
      await h.desk.send('Explain the arrow in the same diagram.');
      expect(h.task('study.describe'), hasLength(1));
      expect(h.task('study.answer'), hasLength(2));
    },
  );
  test(
    'malformed descriptions stop before the tutor and are not cached on retry',
    () async {
      final h = _Harness()..malformed = true;
      await h.load();
      await h.desk.send('Explain the force diagram.');
      expect(h.desk.failure?.kind, AiFailureKind.malformed);
      expect(h.task('study.answer'), isEmpty);
      h.malformed = false;
      await h.desk.retry();
      expect(h.task('study.describe'), hasLength(2));
      expect(h.task('study.answer'), hasLength(1));
    },
  );
  test(
    'progress stays with its chat while a description completes in the background',
    () async {
      final h = _Harness()..descriptionGate = Completer<String>();
      await h.load();
      final original = h.desk.currentSession.id;
      final sent = h.desk.send('Explain the force diagram.');
      for (var i = 0; i < 200 && h.task('study.describe').isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(h.desk.requestProgress?.phase, StudyProgressPhase.describing);
      h.desk.newChat();
      expect(h.desk.requestProgress, isNull);
      h.descriptionGate!.complete(_description);
      await sent;
      expect(h.desk.requestProgress, isNull);
      expect(h.desk.messages, isEmpty);
      expect(
        h.desk.allSessions
            .singleWhere((s) => s.id == original)
            .messages
            .last
            .text,
        contains('Force changes motion'),
      );
    },
  );
  test(
    'disabling both lightweight models prevents images being sent to the main model',
    () async {
      final h = _Harness();
      await h.load();
      h.desk.setRouting(
        const AiRoutingPreferences(
          disabledModels: {AiModelId.haiku, AiModelId.luna},
        ),
      );
      await h.desk.send('Explain the force diagram.');
      expect(h.desk.failure?.kind, AiFailureKind.noModelEnabled);
      expect(h.task('study.describe'), isEmpty);
      expect(h.task('study.answer'), isEmpty);
    },
  );
}
