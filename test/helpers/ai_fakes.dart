import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_canvas_input.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/canvas_text_recognizer.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';

/// An [AiClient] that records what it is sent and answers when the test
/// says so. It never touches the network.
class FakeAiClient implements AiClient, AiVisualDescriptionClient {
  FakeAiClient({this.isConfigured = true});

  @override
  final bool isConfigured;

  /// Every request, in the order it was sent.
  final List<AiRequest> requests = <AiRequest>[];

  /// Retrieval planning is independent of the manually completed answer queue.
  /// Tests of the gate itself supply explicit decisions through BackendAiClient.
  final List<AiRequest> studyPlanningRequests = <AiRequest>[];
  final List<AiRequest> visualDescriptionRequests = <AiRequest>[];
  AiResult studyPlanningResult = const AiSuccess(
    '{"intent":"question","retrieval":{"notes":true,"mistakeIndices":[1,2,3],"query":""}}',
  );
  @override
  Future<AiResult> describeVisual(AiRequest request) async {
    visualDescriptionRequests.add(request);
    return fakeStudyVisualDescription(request);
  }

  final List<Completer<AiResult>> _pending = <Completer<AiResult>>[];
  final List<AiPartialCallback?> _partials = <AiPartialCallback?>[];
  final List<AiNotationPartialCallback?> _notations =
      <AiNotationPartialCallback?>[];
  bool closed = false;

  @override
  String get modelLabel => 'Fake model';

  @override
  Future<AiResult> send(
    AiRequest request, {
    AiPartialCallback? onPartial,
    AiNotationPartialCallback? onNotation,
  }) {
    if (request.systemInstruction == AiPrompts.studyVisualDescriptionSystem) {
      visualDescriptionRequests.add(request);
      return Future.value(fakeStudyVisualDescription(request));
    }
    if (request.systemInstruction == AiPrompts.studyTeachingPlannerSystem) {
      studyPlanningRequests.add(request);
      return Future.value(studyPlanningResult);
    }
    requests.add(request);
    final Completer<AiResult> completer = Completer<AiResult>();
    _pending.add(completer);
    _partials.add(onPartial);
    _notations.add(onNotation);
    return completer.future;
  }

  /// Streams [svg] as the part of request number [index]'s notation written
  /// so far.
  void streamNotation(String svg, {int? index}) {
    _notations[index ?? _notations.length - 1]?.call(svg);
  }

  /// Streams [message] as the part of request number [index]'s answer
  /// written so far.
  void stream(String message, {bool isComplete = false, int? index}) {
    _partials[index ?? _partials.length - 1]?.call(message, isComplete);
  }

  /// Answers request number [index] with [text].
  void answer(String text, {int? index}) {
    _pending[index ?? _pending.length - 1].complete(AiSuccess(text));
  }

  void answerResponse(AiAssistantResponse response, {int? index}) {
    _pending[index ?? _pending.length - 1].complete(
      AiSuccess.response(response),
    );
  }

  /// Ends request number [index] with [result].
  void complete(AiResult result, {int? index}) {
    _pending[index ?? _pending.length - 1].complete(result);
  }

  /// Fails request number [index].
  void fail(AiFailureKind kind, {int? index}) {
    _pending[index ?? _pending.length - 1].complete(AiError(AiFailure(kind)));
  }

  @override
  void close() => closed = true;
}

/// A renderer that makes no native image: it returns a few bytes that say
/// which render they came from, when the test lets it.
AiSuccess fakeStudyVisualDescription(AiRequest request) {
  final count =
      (jsonDecode(request.messages.last.text) as Map)['panelCount'] as int;
  return AiSuccess(
    jsonEncode({
      'panels': [
        for (var i = 0; i < count; i++)
          {
            'panel': String.fromCharCode(65 + i),
            'description':
                'A labelled source diagram with its visible note content.',
            'uncertainties': <String>[],
          },
      ],
    }),
  );
}

class FakeSelectionImageRenderer extends SelectionImageRenderer {
  FakeSelectionImageRenderer();

  /// Every snapshot it was asked to draw.
  final List<SelectionInkSnapshot> snapshots = <SelectionInkSnapshot>[];

  /// While set, renders wait for it.
  Completer<void>? gate;

  /// Thrown by the next renders, when set.
  SelectionImageException? error;

  @override
  Future<SelectionImage> render(SelectionInkSnapshot snapshot) async {
    snapshots.add(snapshot);
    final int number = snapshots.length;
    await gate?.future;
    final SelectionImageException? error = this.error;
    if (error != null) {
      throw error;
    }
    return SelectionImage(
      png: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, number]),
      width: 200,
      height: 100,
      scale: 2,
      logicalBounds: const Rect.fromLTWH(0, 0, 100, 50),
    );
  }
}

class FakeNoteImageRenderer extends NoteImageRenderer {
  final List<NoteInkSnapshot> snapshots = <NoteInkSnapshot>[];

  @override
  Future<NoteImage> render(NoteInkSnapshot snapshot) async {
    snapshots.add(snapshot);
    return NoteImage(
      logicalSize: snapshot.logicalSize,
      revision: snapshot.revision,
      normalizedFocusBounds: snapshot.focusBounds == null
          ? null
          : Rect.fromLTRB(
              snapshot.focusBounds!.left / snapshot.logicalSize.width,
              snapshot.focusBounds!.top / snapshot.logicalSize.height,
              snapshot.focusBounds!.right / snapshot.logicalSize.width,
              snapshot.focusBounds!.bottom / snapshot.logicalSize.height,
            ),
    );
  }
}

/// Selects every stroke of [controller] overlapping [box], as a rectangle
/// drag would, and returns the selection.
InkSelection selectInk(InkController controller, Rect box) {
  controller
    ..beginLasso(pointer: 77, position: InkVector(box.left, box.top))
    ..endLasso(77, InkVector(box.right, box.bottom));
  return controller.selection!;
}

/// Lets work that needs real time, such as encoding the selection image
/// and decoding its preview, finish inside a widget test.
Future<void> settleAi(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// Draws no native image: a handwriting batch with a few marker bytes, so
/// widget tests need no real time to render it.
class FakeHandwritingImageRenderer extends HandwritingImageRenderer {
  FakeHandwritingImageRenderer();

  /// Every batch of strokes it was asked to draw.
  final List<List<AiCanvasStroke>> batches = <List<AiCanvasStroke>>[];

  @override
  Future<HandwritingBatch> render(List<AiCanvasStroke> strokes) async {
    batches.add(strokes);
    Rect bounds = strokes.first.bounds;
    for (final AiCanvasStroke stroke in strokes.skip(1)) {
      bounds = bounds.expandToInclude(stroke.bounds);
    }
    return HandwritingBatch(
      strokes: strokes,
      png: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, batches.length]),
      pixelSize: bounds.size,
      logicalBounds: bounds,
    );
  }
}

/// Reads every batch as [text], with no platform channel, and records what
/// it was shown.
class FakeCanvasTextRecognizer implements CanvasTextRecognizer {
  FakeCanvasTextRecognizer({this.text = 'recognized words'});

  /// What the next batches are read as.
  String text;

  Future<String> Function(HandwritingBatch batch)? onRecognize;

  /// Every batch it was asked to read, in order.
  final List<HandwritingBatch> batches = <HandwritingBatch>[];

  @override
  Future<String> recognize(HandwritingBatch batch) async {
    batches.add(batch);
    return onRecognize == null ? text : await onRecognize!(batch);
  }
}

/// A [FakeAiClient] that serves every model, as the editor's own client
/// does, so the model picker shows. [unconfigured] models have no key.
class FakeAiModelRouter extends FakeAiClient implements AiModelRouter {
  FakeAiModelRouter({
    this.defaultModel = AiModelId.sol,
    this.unconfigured = const <AiModelId>{},
  });

  @override
  final AiModelId defaultModel;

  final Set<AiModelId> unconfigured;

  @override
  List<AiModelId> get models => AiModelId.values;

  /// Whether the fake chooses the model itself, as the backend does.
  @override
  bool routes = false;

  @override
  bool isModelConfigured(AiModelId model) => !unconfigured.contains(model);
}
