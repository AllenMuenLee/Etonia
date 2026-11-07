import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../editor/ai/ai_client.dart';
import '../../../editor/ai/ai_config.dart';
import '../../../editor/ai/chat_math.dart';
import '../../../editor/ai/streaming_ai_client.dart' show stripJsonFence;
import '../study_rag_index.dart';
import 'study_practice_models.dart';

/// Which kinds of item a set is made of.
enum PracticeQuestionTypes {
  flashcards('Flashcards'),
  multipleChoice('Multiple Choice'),
  mixed('Mixed Test');

  const PracticeQuestionTypes(this.label);

  final String label;
}

/// How hard a set's items are.
enum PracticeDifficulty {
  fundamentals('Fundamental', 'Ask for definitions, names, and basic facts.'),
  application(
    'Medium',
    'Ask the student to apply ideas to new cases and to solve problems.',
  ),
  comprehensive(
    'Hard',
    'Write as an exam would: cover everything, from recall to hard synthesis '
        'across topics.',
  );

  const PracticeDifficulty(this.label, this.instruction);

  final String label;
  final String instruction;
}

/// All that is asked of one generation.
@immutable
class StudyPracticeRequest {
  const StudyPracticeRequest({
    required this.noteIds,
    this.types = PracticeQuestionTypes.mixed,
    this.itemCount = 10,
    this.difficulty = PracticeDifficulty.fundamentals,
    this.focus = '',
  });

  static const List<int> itemCounts = <int>[5, 10, 15, 20];

  /// The most of [focus] that is sent: the service takes 24,000 bytes of
  /// prompt, and the excerpts come with it.
  static const int maxFocusCharacters = 500;

  final List<String> noteIds;
  final PracticeQuestionTypes types;

  /// How many items in all. A mixed test is about half of each.
  final int itemCount;
  final PracticeDifficulty difficulty;

  /// What to concentrate on, in the user's words. May be empty.
  final String focus;

  int get flashcardCount => switch (types) {
    PracticeQuestionTypes.flashcards => itemCount,
    PracticeQuestionTypes.multipleChoice => 0,
    PracticeQuestionTypes.mixed => itemCount ~/ 2,
  };

  int get multipleChoiceCount => itemCount - flashcardCount;
}

/// A set as a model wrote it, before its citations are worked out. A source is
/// the tag it wrote, as `[[N1:P2:C3]]`, for each item by its id.
@immutable
class StudyPracticeDraft {
  const StudyPracticeDraft({
    required this.title,
    required this.flashcards,
    required this.multipleChoiceQuestions,
    this.sources = const <String, String>{},
  });

  final String title;
  final List<PracticeFlashcard> flashcards;
  final List<PracticeMultipleChoice> multipleChoiceQuestions;
  final Map<String, String> sources;

  int get itemCount => flashcards.length + multipleChoiceQuestions.length;
}

/// A draft, or why there is none.
@immutable
class StudyPracticeOutcome {
  const StudyPracticeOutcome.success(StudyPracticeDraft this.draft)
    : failure = null;
  const StudyPracticeOutcome.failed(AiFailure this.failure) : draft = null;

  final StudyPracticeDraft? draft;
  final AiFailure? failure;
}

/// Asks a model for a practice set, and reads what it answers.
class StudyPracticeGenerator {
  const StudyPracticeGenerator({required this.client});

  final AiClient client;

  /// Every attempt is charged for, so a set that cannot be read is asked for
  /// once more and no further.
  static const int maxAttempts = 2;

  /// The most of any one piece of text that is kept, against a runaway model.
  static const int _maxText = 2000;

  /// What is asked for, under [payload]'s excerpts. [correction] says what was
  /// wrong with the last attempt.
  static String promptFor(
    StudyPracticeRequest request,
    StudyPayload payload, {
    bool correction = false,
  }) {
    final String focus = request.focus.trim();
    final String clipped =
        focus.length <= StudyPracticeRequest.maxFocusCharacters
        ? focus
        : focus.substring(0, StudyPracticeRequest.maxFocusCharacters);
    final StringBuffer prompt = StringBuffer();
    if (payload.contextText.isNotEmpty) {
      prompt
        ..write('Excerpts from my notes:\n\n')
        ..write(payload.contextText)
        ..write('\n\n');
    }
    prompt.write('Write a practice set of ');
    final int cards = request.flashcardCount;
    final int questions = request.multipleChoiceCount;
    prompt.write(
      <String>[
        if (cards > 0) '$cards flashcards',
        if (questions > 0) '$questions multiple choice questions',
      ].join(' and '),
    );
    prompt
      ..write('. ')
      ..write(request.difficulty.instruction);
    if (clipped.isNotEmpty) {
      prompt.write(
        ' Concentrate on what the student asks for here: "$clipped"',
      );
    }
    if (correction) {
      prompt.write(
        '\n\nThe last answer could not be read. Answer again with only the '
        'JSON object in the required form, every string properly escaped, and '
        'keep each item short so that all of it fits.',
      );
    }
    return prompt.toString();
  }

  /// Asks for the set. [onAnswered] is told of each attempt the provider
  /// answered, which is charged for whatever becomes of it.
  Future<StudyPracticeOutcome> generate({
    required StudyPracticeRequest request,
    required StudyPayload payload,
    ({AiModelId? model, AiRouting? routing}) route = (
      model: null,
      routing: null,
    ),
    void Function(AiRequest request, AiSuccess answer)? onAnswered,
    bool Function()? cancelled,
  }) async {
    StudyPracticeDraft? salvaged;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final AiRequest asked = AiRequest(
        systemInstruction: AiPrompts.studyPracticeSystem,
        imagePng: payload.imagePng,
        model: route.model,
        routing: route.routing,
        messages: <AiMessage>[
          AiMessage.user(
            promptFor(request, payload, correction: attempt > 0),
            label: 'Generate a study set',
          ),
        ],
      );
      // An answer cut off by the output limit reaches here only as this: what
      // arrived of it is still good, as far as it goes.
      String partial = '';
      final AiResult result;
      try {
        result = await client.send(
          asked,
          onPartial: (String message, bool _) => partial = message,
        );
      } on Object {
        return const StudyPracticeOutcome.failed(
          AiFailure(AiFailureKind.network),
        );
      }
      if (cancelled?.call() ?? false) {
        return const StudyPracticeOutcome.failed(
          AiFailure(AiFailureKind.interrupted),
        );
      }
      final String text;
      switch (result) {
        case AiSuccess():
          onAnswered?.call(asked, result);
          text = result.text;
        case AiError(:final AiFailure failure):
          if (failure.kind != AiFailureKind.malformed) {
            return StudyPracticeOutcome.failed(failure);
          }
          text = partial;
      }
      try {
        return StudyPracticeOutcome.success(parse(text, request));
      } on FormatException {
        final StudyPracticeDraft? rescued = salvage(text, request);
        if (rescued != null && rescued.itemCount > (salvaged?.itemCount ?? 0)) {
          salvaged = rescued;
        }
        // Most of a set is worth more than paying for all of it again.
        if ((salvaged?.itemCount ?? 0) * 5 >= request.itemCount * 3) break;
      }
    }
    return salvaged != null
        ? StudyPracticeOutcome.success(salvaged)
        : const StudyPracticeOutcome.failed(AiFailure(AiFailureKind.malformed));
  }

  /// Reads [answer]. Items that break the form are left out; with none left,
  /// or none readable, this throws a [FormatException].
  static StudyPracticeDraft parse(String answer, StudyPracticeRequest request) {
    final String text = stripJsonFence(answer.trim());
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('No practice set in the answer');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(repairLatexEscapes(text.substring(start, end + 1)));
    } on FormatException {
      throw const FormatException('The practice set is not valid JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('The practice set is not an object');
    }
    final StudyPracticeDraft draft = _draftOf(
      title: _clean(decoded['title']),
      cards: decoded['flashcards'],
      questions: decoded['multipleChoiceQuestions'],
      request: request,
    );
    if (draft.itemCount == 0) {
      throw const FormatException('The practice set has no usable items');
    }
    return draft;
  }

  /// The whole items in [answer] when it cannot be read as a whole, as when it
  /// was cut off. Null when there are none.
  static StudyPracticeDraft? salvage(
    String answer,
    StudyPracticeRequest request,
  ) {
    final String source = repairLatexEscapes(answer);
    final Map<String, Object?> items = <String, Object?>{
      'flashcards': _wholeObjectsAfter(source, '"flashcards"'),
      'multipleChoiceQuestions': _wholeObjectsAfter(
        source,
        '"multipleChoiceQuestions"',
      ),
    };
    final StudyPracticeDraft draft = _draftOf(
      title:
          RegExp(r'"title"\s*:\s*"([^"\\]*)"').firstMatch(source)?.group(1) ??
          '',
      cards: items['flashcards'],
      questions: items['multipleChoiceQuestions'],
      request: request,
    );
    return draft.itemCount == 0 ? null : draft;
  }

  /// The complete objects in the JSON array that follows [key] in [source].
  static List<Object?> _wholeObjectsAfter(String source, String key) {
    final int at = source.indexOf(key);
    if (at < 0) return const <Object?>[];
    int i = source.indexOf('[', at);
    if (i < 0) return const <Object?>[];
    final List<Object?> found = <Object?>[];
    int depth = 0;
    int objectStart = -1;
    bool inString = false;
    for (i = i + 1; i < source.length; i++) {
      final String char = source[i];
      if (inString) {
        if (char == r'\') {
          i++;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '{') {
        if (depth == 0) objectStart = i;
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0 && objectStart >= 0) {
          try {
            found.add(jsonDecode(source.substring(objectStart, i + 1)));
          } on FormatException {
            // This one is left out; those after it may be whole.
          }
          objectStart = -1;
        }
      } else if (char == ']' && depth == 0) {
        break;
      }
    }
    return found;
  }

  static StudyPracticeDraft _draftOf({
    required String title,
    required Object? cards,
    required Object? questions,
    required StudyPracticeRequest request,
  }) {
    final Map<String, String> sources = <String, String>{};
    final List<PracticeFlashcard> flashcards = <PracticeFlashcard>[];
    if (cards is List && request.flashcardCount > 0) {
      for (final Object? raw in cards) {
        if (flashcards.length >= request.flashcardCount) break;
        final String id = 'c${flashcards.length}';
        final PracticeFlashcard? card = _flashcard(raw, id);
        if (card == null) continue;
        flashcards.add(card);
        _keepSource(sources, id, raw);
      }
    }
    final List<PracticeMultipleChoice> choices = <PracticeMultipleChoice>[];
    if (questions is List && request.multipleChoiceCount > 0) {
      for (final Object? raw in questions) {
        if (choices.length >= request.multipleChoiceCount) break;
        final String id = 'q${choices.length}';
        final PracticeMultipleChoice? question = _multipleChoice(raw, id);
        if (question == null) continue;
        choices.add(question);
        _keepSource(sources, id, raw);
      }
    }
    return StudyPracticeDraft(
      title: title,
      flashcards: flashcards,
      multipleChoiceQuestions: choices,
      sources: sources,
    );
  }

  static void _keepSource(Map<String, String> into, String id, Object? raw) {
    final String source = _clean((raw! as Map<String, Object?>)['source']);
    if (source.isEmpty) return;
    into[id] = source.contains('[[') ? source : '[[$source]]';
  }

  static String _clean(Object? value) {
    if (value is! String) return '';
    final String text = value.trim();
    return text.length <= _maxText ? text : text.substring(0, _maxText);
  }

  static PracticeFlashcard? _flashcard(Object? raw, String id) {
    if (raw is! Map<String, Object?>) return null;
    final String front = _clean(raw['frontPrompt']);
    final String back = _clean(raw['backAnswer']);
    if (front.isEmpty || back.isEmpty) return null;
    return PracticeFlashcard(
      id: id,
      frontPrompt: front,
      backAnswer: back,
      explanation: _clean(raw['explanation']),
      topic: _clean(raw['topic']),
    );
  }

  static const List<String> _letters = <String>['A', 'B', 'C', 'D'];

  static PracticeMultipleChoice? _multipleChoice(Object? raw, String id) {
    if (raw is! Map<String, Object?>) return null;
    final String question = _clean(raw['question']);
    final Object? rawOptions = raw['options'];
    if (question.isEmpty || rawOptions is! List || rawOptions.length != 4) {
      return null;
    }
    final String wanted = _clean(raw['correctOptionId']).toUpperCase();
    final List<PracticeChoiceOption> options = <PracticeChoiceOption>[];
    String? correct;
    for (int i = 0; i < 4; i++) {
      final Object? option = rawOptions[i];
      if (option is! Map<String, Object?>) return null;
      final String text = _clean(option['text']);
      if (text.isEmpty) return null;
      // Lettered by place, whatever was written, so that a test prints in order.
      options.add(PracticeChoiceOption(id: _letters[i], text: text));
      if (_clean(option['id']).toUpperCase() == wanted) correct = _letters[i];
    }
    final Set<String> different = <String>{
      for (final PracticeChoiceOption option in options) option.text,
    };
    if (correct == null || different.length != 4) return null;
    return PracticeMultipleChoice(
      id: id,
      question: question,
      options: options,
      correctOptionId: correct,
      explanation: _clean(raw['explanation']),
      topic: _clean(raw['topic']),
    );
  }
}
