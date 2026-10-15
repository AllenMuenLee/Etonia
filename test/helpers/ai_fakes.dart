import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/note_image_renderer.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/ink_selection.dart';

/// An [AiClient] that records what it is sent and answers when the test
/// says so. It never touches the network.
class FakeAiClient implements AiClient {
  FakeAiClient({this.isConfigured = true});

  @override
  final bool isConfigured;

  /// Every request, in the order it was sent.
  final List<AiRequest> requests = <AiRequest>[];
  final List<Completer<AiResult>> _pending = <Completer<AiResult>>[];
  final List<AiPartialCallback?> _partials = <AiPartialCallback?>[];
  bool closed = false;

  @override
  String get modelLabel => 'Fake model';

  @override
  Future<AiResult> send(AiRequest request, {AiPartialCallback? onPartial}) {
    requests.add(request);
    final Completer<AiResult> completer = Completer<AiResult>();
    _pending.add(completer);
    _partials.add(onPartial);
    return completer.future;
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

  /// Fails request number [index].
  void fail(AiFailureKind kind, {int? index}) {
    _pending[index ?? _pending.length - 1].complete(AiError(AiFailure(kind)));
  }

  @override
  void close() => closed = true;
}

/// A renderer that makes no native image: it returns a few bytes that say
/// which render they came from, when the test lets it.
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
      png: Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]),
      width: snapshot.logicalSize.width.ceil(),
      height: snapshot.logicalSize.height.ceil(),
      scale: 1,
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
