import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';

Map<String, Object?> _line({Object? step = 1, double toX = 0.4}) {
  return <String, Object?>{
    'type': 'line',
    'from': <String, Object?>{'x': 0.2, 'y': 0.2},
    'to': <String, Object?>{'x': toX, 'y': 0.2},
    'line_style': 'solid',
    'arrow': 'end',
    'ink': 'blue',
    'width': 3,
    'step': ?step,
  };
}

Map<String, Object?> _text({Object? step = 2, String text = 'x = 3'}) {
  return <String, Object?>{
    'type': 'text',
    'text': text,
    'x': 0.5,
    'y': 0.2,
    'size': 24,
    'ink': 'blue',
    'width': 2.5,
    'step': ?step,
  };
}

Map<String, Object?> _envelope(List<Map<String, Object?>> items) {
  return <String, Object?>{
    'version': 2,
    'message': 'Circled, then answered.',
    'notation': <String, Object?>{
      'label': 'Leader and answer',
      'coordinate_space': 'note_normalized',
      'items': items,
    },
  };
}

AiAssistantResponse _parse(Map<String, Object?> envelope) {
  return AiAssistantResponse.parse(jsonEncode(envelope));
}

/// Parses [envelope], whose steps alone are wrong, and checks the drawing
/// survives with no animation.
void _expectStatic(Map<String, Object?> envelope, {String? reason}) {
  final AiAssistantResponse response = _parse(envelope);
  expect(response.notationRejected, isFalse, reason: reason);
  expect(response.notation, isNotNull, reason: reason);
  expect(response.notation!.timeline, isNull, reason: reason);
  final Map<String, Object?> notation =
      envelope['notation']! as Map<String, Object?>;
  expect(
    response.notation!.items,
    hasLength((notation['items']! as List<Object?>).length),
    reason: reason,
  );
}

void main() {
  const AiNotationConfig config = AiNotationConfig();

  test('the timing limits live in the notation config', () {
    expect(config.minDurationMs, 250);
    expect(config.maxDurationMs, 12000);
    expect(config.maxSteps, 24);
    expect(config.stepPauseMs, 250);
    expect(config.stepFinalHoldMs, 600);
  });

  test('parses steps into a timeline and serializes them back exactly', () {
    final Map<String, Object?> envelope = _envelope(<Map<String, Object?>>[
      _line(),
      _text(),
    ]);
    final AiAssistantResponse response = _parse(envelope);

    final AiNotationTimeline timeline = response.notation!.timeline!;
    expect(timeline.steps, <int>[1, 2]);
    final AiItemTiming line = timeline.items[0];
    final AiItemTiming text = timeline.items[1];
    expect(line.startMs, 0);
    expect(line.endMs, greaterThan(0));
    // The text waits for the line, and a pause, then writes 3 characters.
    expect(text.startMs, line.endMs + config.stepPauseMs);
    expect(text.endMs - text.startMs, 420);
    expect(timeline.durationMs, text.endMs + config.stepFinalHoldMs);
    expect(jsonDecode(response.toJsonString()), envelope);
  });

  test('items that share a step are drawn together', () {
    final AiNotationTimeline timeline = _parse(
      _envelope(<Map<String, Object?>>[_line(step: 3), _text(step: 3)]),
    ).notation!.timeline!;
    expect(timeline.items[0].startMs, 0);
    expect(timeline.items[1].startMs, 0);
    // The longer of the two sets when the notation ends.
    final int longest = <int>[
      timeline.items[0].endMs,
      timeline.items[1].endMs,
    ].reduce((int a, int b) => a > b ? a : b);
    expect(timeline.durationMs, longest + config.stepFinalHoldMs);
  });

  test('steps need not be consecutive, or in item order', () {
    final AiNotationTimeline timeline = _parse(
      _envelope(<Map<String, Object?>>[_text(step: 10), _line(step: 4)]),
    ).notation!.timeline!;
    expect(timeline.items[1].startMs, 0);
    expect(
      timeline.items[0].startMs,
      timeline.items[1].endMs + config.stepPauseMs,
    );
    expect(timeline.steps, <int>[10, 4]);
  });

  test('a longer item takes longer to draw', () {
    final AiNotationTimeline short = _parse(
      _envelope(<Map<String, Object?>>[_line(toX: 0.3)]),
    ).notation!.timeline!;
    final AiNotationTimeline long = _parse(
      _envelope(<Map<String, Object?>>[_line(toX: 0.9)]),
    ).notation!.timeline!;
    expect(long.items.single.endMs, greaterThan(short.items.single.endMs));
  });

  test('an animation too long to fit is sped up to the longest', () {
    final AiNotationTimeline timeline = _parse(
      _envelope(<Map<String, Object?>>[
        for (int step = 1; step <= 12; step++)
          _text(step: step, text: 'a long line of text'),
      ]),
    ).notation!.timeline!;
    expect(timeline.durationMs, config.maxDurationMs);
    expect(timeline.items.first.startMs, 0);
    for (final AiItemTiming item in timeline.items) {
      expect(item.endMs, lessThanOrEqualTo(timeline.durationMs));
    }
  });

  test('a notation without steps is drawn at once', () {
    final AiAssistantResponse response = _parse(
      _envelope(<Map<String, Object?>>[_line(step: null)]),
    );
    expect(response.notationRejected, isFalse);
    expect(response.notation!.timeline, isNull);
    expect(response.toJsonString(), isNot(contains('step')));
  });

  group('steps that break a rule are dropped, and the drawing kept', () {
    test('a step out of range, or not a JSON integer', () {
      for (final Object? step in <Object?>[0, -1, 25, 1.0, 1.5, '1', true]) {
        _expectStatic(
          _envelope(<Map<String, Object?>>[_line(step: step), _text()]),
          reason: '$step',
        );
      }
    });
  });

  test('items without a step are fixed while the stepped ones move', () {
    final Map<String, Object?> envelope = _envelope(<Map<String, Object?>>[
      _text(step: null, text: 'I'),
      _line(step: 1),
      _line(step: 2, toX: 0.6),
    ]);
    final AiAssistantResponse response = _parse(envelope);
    final AiNotationTimeline timeline = response.notation!.timeline!;

    // The label is whole from the start of every repeat.
    expect(timeline.items[0], const AiItemTiming(0, 0));
    expect(timeline.steps[0], AiNotationTimeline.fixedStep);
    // The moving items are drawn in their order, as if the label were not
    // there.
    expect(timeline.items[1].startMs, 0);
    expect(
      timeline.items[2].startMs,
      timeline.items[1].endMs + config.stepPauseMs,
    );
    expect(
      timeline.durationMs,
      timeline.items[2].endMs + config.stepFinalHoldMs,
    );
    // The fixed item goes back on the wire without a step.
    expect(jsonDecode(response.toJsonString()), envelope);
  });

  test('the old millisecond timing is no longer part of the contract', () {
    final Map<String, Object?> timed = _line(step: null)
      ..['start_ms'] = 0
      ..['end_ms'] = 400;
    expect(
      _parse(_envelope(<Map<String, Object?>>[timed])).notationRejected,
      isTrue,
    );
    final Map<String, Object?> envelope = _envelope(<Map<String, Object?>>[
      _line(),
    ]);
    (envelope['notation']! as Map<String, Object?>)['duration_ms'] = 1000;
    expect(_parse(envelope).notationRejected, isTrue);
  });

  test('a timeline built from times reports its items ranked as steps', () {
    final AiNotationTimeline timeline = AiNotationTimeline(
      durationMs: 1500,
      items: const <AiItemTiming>[
        AiItemTiming(600, 900),
        AiItemTiming(0, 400),
        AiItemTiming(600, 1000),
      ],
    );
    expect(timeline.steps, <int>[2, 1, 2]);
  });

  test('the drawing itself is still checked as strictly as ever', () {
    // An unknown key beside the step still rejects the notation whole.
    final Map<String, Object?> extra = _line()..['speed'] = 2;
    final AiAssistantResponse withExtra = _parse(
      _envelope(<Map<String, Object?>>[extra, _text()]),
    );
    expect(withExtra.notationRejected, isTrue);
    expect(withExtra.message, 'Circled, then answered.');

    // So does an unknown key on the notation.
    final Map<String, Object?> envelope = _envelope(<Map<String, Object?>>[
      _line(),
    ]);
    (envelope['notation']! as Map<String, Object?>)['fps'] = 60;
    expect(_parse(envelope).notationRejected, isTrue);

    // And one bad item rejects every item, stepped or not.
    final AiAssistantResponse badItem = _parse(
      _envelope(<Map<String, Object?>>[_line(), _text()..['ink'] = 'gold']),
    );
    expect(badItem.notationRejected, isTrue);
    expect(badItem.notation, isNull);
  });

  test('history replays the steps the model gave, never the app status', () {
    final AiAssistantResponse response = _parse(
      _envelope(<Map<String, Object?>>[_line(), _text()]),
    );
    for (final AiNotationStatus status in <AiNotationStatus>[
      AiNotationStatus.animating,
      AiNotationStatus.applied,
    ]) {
      final AiMessage message = AiMessage.model(
        response.message,
        notation: response.notation,
        notationStatus: status,
      );
      final String wire = message.wireText;
      expect(jsonDecode(wire), jsonDecode(response.toJsonString()));
      expect(wire, isNot(contains('animating')));
      expect(wire, isNot(contains('applied')));
      expect(wire, isNot(contains('Drawing')));
      expect(wire, isNot(contains('_ms')));
    }
  });

  test('a status change keeps the turn as the model gave it', () {
    final AiAssistantResponse response = _parse(
      _envelope(<Map<String, Object?>>[_line(), _text()]),
    );
    final AiMessage drawing = AiMessage.model(
      response.message,
      notation: response.notation,
      notationStatus: AiNotationStatus.animating,
    );
    final AiMessage applied = drawing.withNotationStatus(
      AiNotationStatus.applied,
    );
    expect(applied.notationStatus, AiNotationStatus.applied);
    expect(applied.text, drawing.text);
    expect(identical(applied.notation, drawing.notation), isTrue);
    expect(applied.wireText, drawing.wireText);
  });

  test('internal drawing and finished statuses remain available', () {
    expect(AiNotationStatus.animating.message, 'Drawing…');
    expect(AiNotationStatus.applied.message, 'Added to note');
  });

  test('the instruction explains steps, and never asks for times', () {
    final String on = AiPrompts.systemFor(
      notationEnabled: true,
      animationEnabled: true,
    );
    expect(on, contains('annotate the note or add animation'));
    // How to annotate or animate is the model's choice.
    expect(on, isNot(contains('default is a completely static')));
    expect(on, isNot(contains('If uncertain')));
    expect(on, contains('data-etonia-step="1"'));
    expect(on, contains('data-etonia-motion="1"'));
    expect(on, contains('data-etonia-static="1"'));
    expect(on, contains('(maximum 24)'));
    expect(on, contains('The steps loop until the user stops animation'));
    expect(on, contains('data-etonia-duration-ms on the root from 300'));
    expect(
      on,
      contains('Express the complete animation through these step attributes'),
    );
    for (final String gone in <String>['duration_ms', 'start_ms', 'end_ms']) {
      expect(on, isNot(contains(gone)));
    }
    final String staticOnly = AiPrompts.systemFor(notationEnabled: true);
    expect(
      staticOnly,
      contains('Use static SVG geometry and text for every element'),
    );
    expect(staticOnly, isNot(contains('data-etonia-step')));
    expect(staticOnly, isNot(contains('Animation is enabled')));
    final String off = AiPrompts.systemFor(notationEnabled: false);
    expect(off, isNot(contains('data-etonia-step')));
    expect(off, contains('The root contains only title and the message desc'));
  });
}
