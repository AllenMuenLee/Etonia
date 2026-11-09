import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../study_desk_models.dart';

/// What one item of a practice set is.
enum PracticeItemType { flashcard, multipleChoice }

enum PracticeStudioSection { flashcards, tests }

enum TestQuestionKind { multipleChoice, freeResponse }

String _string(Object? value) => value is String ? value : '';

int _testInteger(Object? value) {
  if (value is! num || !value.isFinite || value != value.toInt()) {
    throw const FormatException('Expected an integer point value');
  }
  return value.toInt();
}

StudyCitation? _citation(Object? raw) =>
    raw is Map<String, Object?> ? StudyCitation.fromJson(raw) : null;

/// A question on one side and its answer on the other.
@immutable
class PracticeFlashcard {
  const PracticeFlashcard({
    required this.id,
    required this.frontPrompt,
    required this.backAnswer,
    this.explanation = '',
    this.topic = '',
    this.sourceCitation,
    this.diagramCrop,
    this.isMastered = false,
    this.reviewCount = 0,
  });

  factory PracticeFlashcard.fromJson(Map<String, Object?> json) {
    final Object? crop = json['diagramCrop'];
    return PracticeFlashcard(
      id: json['id']! as String,
      frontPrompt: _string(json['frontPrompt']),
      backAnswer: _string(json['backAnswer']),
      explanation: _string(json['explanation']),
      topic: _string(json['topic']),
      sourceCitation: _citation(json['sourceCitation']),
      diagramCrop: crop is String ? base64Decode(crop) : null,
      isMastered: json['isMastered'] == true,
      reviewCount: (json['reviewCount'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String frontPrompt;
  final String backAnswer;
  final String explanation;

  /// A word or two for the card's badge. May be empty.
  final String topic;
  final StudyCitation? sourceCitation;

  /// A picture of the drawing the card is about, from the note.
  final Uint8List? diagramCrop;
  final bool isMastered;
  final int reviewCount;

  /// Whether answering means drawing: a printed test leaves a box for it.
  bool get isDiagram => diagramCrop != null;

  PracticeFlashcard copyWith({
    String? frontPrompt,
    String? backAnswer,
    String? explanation,
    bool? isMastered,
    int? reviewCount,
  }) => PracticeFlashcard(
    id: id,
    frontPrompt: frontPrompt ?? this.frontPrompt,
    backAnswer: backAnswer ?? this.backAnswer,
    explanation: explanation ?? this.explanation,
    topic: topic,
    sourceCitation: sourceCitation,
    diagramCrop: diagramCrop,
    isMastered: isMastered ?? this.isMastered,
    reviewCount: reviewCount ?? this.reviewCount,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'frontPrompt': frontPrompt,
    'backAnswer': backAnswer,
    if (explanation.isNotEmpty) 'explanation': explanation,
    if (topic.isNotEmpty) 'topic': topic,
    if (sourceCitation != null) 'sourceCitation': sourceCitation!.toJson(),
    if (diagramCrop != null) 'diagramCrop': base64Encode(diagramCrop!),
    if (isMastered) 'isMastered': true,
    if (reviewCount != 0) 'reviewCount': reviewCount,
  };
}

/// One of a question's answers to choose from.
@immutable
class PracticeChoiceOption {
  const PracticeChoiceOption({required this.id, required this.text});

  factory PracticeChoiceOption.fromJson(Map<String, Object?> json) =>
      PracticeChoiceOption(
        id: json['id']! as String,
        text: _string(json['text']),
      );

  /// 'A', 'B', 'C', or 'D'.
  final String id;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'text': text};
}

/// A question with four answers, one of them right.
@immutable
class PracticeMultipleChoice {
  const PracticeMultipleChoice({
    required this.id,
    required this.question,
    required this.options,
    required this.correctOptionId,
    this.explanation = '',
    this.topic = '',
    this.sourceCitation,
    this.userSelectedOptionId,
    this.isAnswered = false,
    this.isGraded = false,
  });

  factory PracticeMultipleChoice.fromJson(Map<String, Object?> json) =>
      PracticeMultipleChoice(
        id: json['id']! as String,
        question: _string(json['question']),
        options: <PracticeChoiceOption>[
          for (final Object? option
              in (json['options'] as List?) ?? const <Object?>[])
            PracticeChoiceOption.fromJson(option! as Map<String, Object?>),
        ],
        correctOptionId: _string(json['correctOptionId']),
        explanation: _string(json['explanation']),
        topic: _string(json['topic']),
        sourceCitation: _citation(json['sourceCitation']),
        userSelectedOptionId: json['userSelectedOptionId'] as String?,
        isAnswered: json['isAnswered'] == true,
        isGraded: json['isGraded'] == true,
      );

  final String id;
  final String question;
  final List<PracticeChoiceOption> options;
  final String correctOptionId;
  final String explanation;
  final String topic;
  final StudyCitation? sourceCitation;
  final String? userSelectedOptionId;
  final bool isAnswered;
  final bool isGraded;

  bool get isCorrect => isAnswered && userSelectedOptionId == correctOptionId;

  /// This question answered with [optionId].
  PracticeMultipleChoice answered(String optionId, {bool graded = true}) =>
      _with(selected: optionId, answered: true, graded: graded);

  PracticeMultipleChoice graded() =>
      _with(selected: userSelectedOptionId, answered: isAnswered, graded: true);

  /// This question as yet unanswered.
  PracticeMultipleChoice cleared() =>
      _with(selected: null, answered: false, graded: false);

  PracticeMultipleChoice _with({
    required String? selected,
    required bool answered,
    required bool graded,
  }) => PracticeMultipleChoice(
    id: id,
    question: question,
    options: options,
    correctOptionId: correctOptionId,
    explanation: explanation,
    topic: topic,
    sourceCitation: sourceCitation,
    userSelectedOptionId: selected,
    isAnswered: answered,
    isGraded: graded,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'question': question,
    'options': <Object?>[
      for (final PracticeChoiceOption option in options) option.toJson(),
    ],
    'correctOptionId': correctOptionId,
    if (explanation.isNotEmpty) 'explanation': explanation,
    if (topic.isNotEmpty) 'topic': topic,
    if (sourceCitation != null) 'sourceCitation': sourceCitation!.toJson(),
    if (userSelectedOptionId != null)
      'userSelectedOptionId': userSelectedOptionId,
    if (isAnswered) 'isAnswered': true,
    'isGraded': isGraded,
  };
}

/// A deck: the cards and questions made together from some notes.
@immutable
class StudyPracticeSet {
  const StudyPracticeSet({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.sourceNoteIds = const <String>[],
    this.courseId,
    this.sourceSessionId,
    this.flashcards = const <PracticeFlashcard>[],
    this.multipleChoiceQuestions = const <PracticeMultipleChoice>[],
    this.bestQuizScore,
  });

  factory StudyPracticeSet.fromJson(
    Map<String, Object?> json,
  ) => StudyPracticeSet(
    id: json['id']! as String,
    courseId: json['courseId'] as String?,
    sourceSessionId: json['sourceSessionId'] as String?,
    title: _string(json['title']),
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt']! as int),
    sourceNoteIds: <String>[
      for (final Object? id
          in (json['sourceNoteIds'] as List?) ?? const <Object?>[])
        id! as String,
    ],
    flashcards: <PracticeFlashcard>[
      for (final Object? card
          in (json['flashcards'] as List?) ?? const <Object?>[])
        PracticeFlashcard.fromJson(card! as Map<String, Object?>),
    ],
    multipleChoiceQuestions: <PracticeMultipleChoice>[
      for (final Object? question
          in (json['multipleChoiceQuestions'] as List?) ?? const <Object?>[])
        PracticeMultipleChoice.fromJson(question! as Map<String, Object?>),
    ],
    bestQuizScore: (json['bestQuizScore'] as num?)?.toDouble(),
  );

  final String id;
  final String? courseId;
  final String? sourceSessionId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> sourceNoteIds;
  final List<PracticeFlashcard> flashcards;
  final List<PracticeMultipleChoice> multipleChoiceQuestions;

  /// The best share of questions right in a finished quiz, from 0 to 1.
  final double? bestQuizScore;

  /// Worked out, so that it cannot disagree with the items once some are
  /// removed.
  int get totalQuestions => flashcards.length + multipleChoiceQuestions.length;

  int get masteredCount =>
      flashcards.where((PracticeFlashcard card) => card.isMastered).length;

  /// How much of the set is known, from 0 to 1: its cards marked mastered, and
  /// its questions at the share of the best quiz.
  double get mastery {
    if (totalQuestions == 0) return 0;
    final double known =
        masteredCount + (bestQuizScore ?? 0) * multipleChoiceQuestions.length;
    return (known / totalQuestions).clamp(0, 1);
  }

  /// This set with [score] recorded, if it beats the best so far.
  StudyPracticeSet withQuizScore(double score, DateTime at) => copyWith(
    bestQuizScore: bestQuizScore == null || score > bestQuizScore!
        ? score
        : bestQuizScore,
    updatedAt: at,
  );

  /// This set as if never practised.
  StudyPracticeSet reset(DateTime at) => StudyPracticeSet(
    id: id,
    courseId: courseId,
    sourceSessionId: sourceSessionId,
    title: title,
    createdAt: createdAt,
    updatedAt: at,
    sourceNoteIds: sourceNoteIds,
    flashcards: <PracticeFlashcard>[
      for (final PracticeFlashcard card in flashcards)
        card.copyWith(isMastered: false, reviewCount: 0),
    ],
    multipleChoiceQuestions: <PracticeMultipleChoice>[
      for (final PracticeMultipleChoice question in multipleChoiceQuestions)
        question.cleared(),
    ],
  );

  /// [clearCourse] takes the set out of its class, which [courseId] cannot say.
  StudyPracticeSet copyWith({
    String? courseId,
    bool clearCourse = false,
    String? sourceSessionId,
    String? title,
    DateTime? updatedAt,
    List<PracticeFlashcard>? flashcards,
    List<PracticeMultipleChoice>? multipleChoiceQuestions,
    double? bestQuizScore,
  }) => StudyPracticeSet(
    id: id,
    courseId: clearCourse ? null : courseId ?? this.courseId,
    sourceSessionId: sourceSessionId ?? this.sourceSessionId,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sourceNoteIds: sourceNoteIds,
    flashcards: flashcards ?? this.flashcards,
    multipleChoiceQuestions:
        multipleChoiceQuestions ?? this.multipleChoiceQuestions,
    bestQuizScore: bestQuizScore ?? this.bestQuizScore,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'sourceNoteIds': sourceNoteIds,
    'courseId': courseId,
    'sourceSessionId': sourceSessionId,
    'flashcards': <Object?>[
      for (final PracticeFlashcard card in flashcards) card.toJson(),
    ],
    'multipleChoiceQuestions': <Object?>[
      for (final PracticeMultipleChoice question in multipleChoiceQuestions)
        question.toJson(),
    ],
    if (bestQuizScore != null) 'bestQuizScore': bestQuizScore,
  };
}

@immutable
class StudyFlashcardDeck {
  const StudyFlashcardDeck({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.sourceNoteIds = const [],
    this.courseId,
    this.flashcards = const [],
  });
  factory StudyFlashcardDeck.fromJson(Map<String, Object?> json) =>
      StudyFlashcardDeck.fromSet(StudyPracticeSet.fromJson(json));
  factory StudyFlashcardDeck.fromSet(StudyPracticeSet set) =>
      StudyFlashcardDeck(
        id: set.id,
        courseId: set.courseId,
        title: set.title,
        createdAt: set.createdAt,
        updatedAt: set.updatedAt,
        sourceNoteIds: set.sourceNoteIds,
        flashcards: set.flashcards,
      );
  final String id, title;
  final String? courseId;
  final DateTime createdAt, updatedAt;
  final List<String> sourceNoteIds;
  final List<PracticeFlashcard> flashcards;
  int get totalCards => flashcards.length;
  int get masteredCount => flashcards.where((f) => f.isMastered).length;
  double get masteryRate => totalCards == 0 ? 0 : masteredCount / totalCards;
  StudyPracticeSet toSet() => StudyPracticeSet(
    id: id,
    courseId: courseId,
    title: title,
    createdAt: createdAt,
    updatedAt: updatedAt,
    sourceNoteIds: sourceNoteIds,
    flashcards: flashcards,
  );
  Map<String, Object?> toJson() => toSet().toJson();
}

sealed class TestQuestion {
  const TestQuestion({
    required this.id,
    required this.prompt,
    required this.points,
    this.topic = '',
    this.sourceCitation,
    this.handwritingStrokes,
  });
  final String id, prompt, topic;
  final int points;
  final StudyCitation? sourceCitation;
  final Uint8List? handwritingStrokes;
  TestQuestionKind get kind;
  TestQuestion copyWithStrokes(Uint8List strokes);
  Map<String, Object?> toJson();
  Map<String, Object?> get commonJson => {
    'id': id,
    'prompt': prompt,
    'points': points,
    'topic': topic,
    'kind': kind.name,
    if (sourceCitation != null) 'sourceCitation': sourceCitation!.toJson(),
    if (handwritingStrokes != null)
      'handwritingStrokes': base64Encode(handwritingStrokes!),
  };
  static TestQuestion fromJson(Map<String, Object?> json) {
    final String id = json['id']! as String;
    final String prompt = _string(json['prompt']);
    final int points = _testInteger(json['points']);
    if (points <= 0) throw const FormatException('Invalid points');
    final String topic = _string(json['topic']);
    final StudyCitation? citation = _citation(json['sourceCitation']);
    final Uint8List? strokes = json['handwritingStrokes'] is String
        ? base64Decode(json['handwritingStrokes']! as String)
        : null;
    return switch (json['kind']) {
      'multipleChoice' => TestMultipleChoiceQuestion(
        id: id,
        prompt: prompt,
        points: points,
        topic: topic,
        sourceCitation: citation,
        handwritingStrokes: strokes,
        options: [
          for (final raw in json['options']! as List)
            PracticeChoiceOption.fromJson(
              Map<String, Object?>.from(raw as Map),
            ),
        ],
        correctOptionId: json['correctOptionId']! as String,
        explanation: _string(json['explanation']),
        selectedOptionId: json['selectedOptionId'] as String?,
        isGraded: json['isGraded'] == true,
      ),
      'freeResponse' => TestFreeResponseQuestion(
        id: id,
        prompt: prompt,
        points: points,
        topic: topic,
        sourceCitation: citation,
        handwritingStrokes: strokes,
        subParts: List<String>.from(json['subParts'] as List? ?? []),
        rubric: List<String>.from(json['rubric'] as List? ?? []),
        modelAnswer: _string(json['modelAnswer']),
        backgroundImagePath: json['backgroundImagePath'] as String?,
        aiEvaluation: json['aiEvaluation'] is Map
            ? TestAiEvaluation.fromJson(
                Map<String, Object?>.from(json['aiEvaluation']! as Map),
              )
            : null,
      ),
      _ => throw const FormatException('Unknown question kind'),
    };
  }
}

@immutable
class TestMultipleChoiceQuestion extends TestQuestion {
  const TestMultipleChoiceQuestion({
    required super.id,
    required super.prompt,
    required this.options,
    required this.correctOptionId,
    super.points = 2,
    this.explanation = '',
    super.topic,
    super.sourceCitation,
    this.selectedOptionId,
    super.handwritingStrokes,
    this.isGraded = false,
  });
  final List<PracticeChoiceOption> options;
  final String correctOptionId, explanation;
  final String? selectedOptionId;
  final bool isGraded;
  @override
  TestQuestionKind get kind => TestQuestionKind.multipleChoice;
  bool get isCorrect =>
      selectedOptionId != null && selectedOptionId == correctOptionId;
  TestMultipleChoiceQuestion copyWith({
    String? selectedOptionId,
    Uint8List? handwritingStrokes,
    bool? isGraded,
  }) => TestMultipleChoiceQuestion(
    id: id,
    prompt: prompt,
    options: options,
    correctOptionId: correctOptionId,
    points: points,
    explanation: explanation,
    topic: topic,
    sourceCitation: sourceCitation,
    selectedOptionId: selectedOptionId ?? this.selectedOptionId,
    handwritingStrokes: handwritingStrokes ?? this.handwritingStrokes,
    isGraded: isGraded ?? this.isGraded,
  );
  TestMultipleChoiceQuestion copyWithSelected(String optionId) {
    if (!options.any((o) => o.id == optionId)) {
      throw ArgumentError.value(optionId);
    }
    return copyWith(selectedOptionId: optionId);
  }

  @override
  TestMultipleChoiceQuestion copyWithStrokes(Uint8List strokes) =>
      copyWith(handwritingStrokes: strokes);
  @override
  Map<String, Object?> toJson() => {
    ...commonJson,
    'options': options.map((o) => o.toJson()).toList(),
    'correctOptionId': correctOptionId,
    'explanation': explanation,
    'selectedOptionId': selectedOptionId,
    'isGraded': isGraded,
  };
}

@immutable
class TestFreeResponseQuestion extends TestQuestion {
  const TestFreeResponseQuestion({
    required super.id,
    required super.prompt,
    required this.subParts,
    required this.rubric,
    super.points = 10,
    super.topic,
    super.sourceCitation,
    this.modelAnswer = '',
    super.handwritingStrokes,
    this.aiEvaluation,
    this.backgroundImagePath,
  });
  final List<String> subParts, rubric;
  final String modelAnswer;
  final TestAiEvaluation? aiEvaluation;
  final String? backgroundImagePath;
  @override
  TestQuestionKind get kind => TestQuestionKind.freeResponse;
  TestFreeResponseQuestion copyWith({
    Uint8List? handwritingStrokes,
    TestAiEvaluation? aiEvaluation,
  }) => TestFreeResponseQuestion(
    id: id,
    prompt: prompt,
    subParts: subParts,
    rubric: rubric,
    points: points,
    topic: topic,
    sourceCitation: sourceCitation,
    modelAnswer: modelAnswer,
    handwritingStrokes: handwritingStrokes ?? this.handwritingStrokes,
    aiEvaluation: aiEvaluation ?? this.aiEvaluation,
    backgroundImagePath: backgroundImagePath,
  );
  @override
  TestFreeResponseQuestion copyWithStrokes(Uint8List strokes) =>
      copyWith(handwritingStrokes: strokes);
  TestFreeResponseQuestion copyWithEvaluation(TestAiEvaluation evaluation) =>
      copyWith(aiEvaluation: evaluation);
  @override
  Map<String, Object?> toJson() => {
    ...commonJson,
    'subParts': subParts,
    'rubric': rubric,
    'modelAnswer': modelAnswer,
    'aiEvaluation': aiEvaluation?.toJson(),
    'backgroundImagePath': backgroundImagePath,
  };
}

@immutable
class TestAiAnnotation {
  const TestAiAnnotation({
    required this.x,
    required this.y,
    required this.label,
    required this.isCorrect,
  });
  factory TestAiAnnotation.fromJson(Map<String, Object?> json) {
    final x = (json['x']! as num).toDouble();
    final y = (json['y']! as num).toDouble();
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw const FormatException('Annotation outside answer area');
    }
    return TestAiAnnotation(
      x: x,
      y: y,
      label: json['label']! as String,
      isCorrect: json['isCorrect'] == true,
    );
  }
  final double x, y;
  final String label;
  final bool isCorrect;
  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'label': label,
    'isCorrect': isCorrect,
  };
}

@immutable
class TestAiEvaluation {
  const TestAiEvaluation({
    required this.awardedPoints,
    required this.maxPoints,
    required this.feedback,
    required this.breakdown,
    this.recognizedMathOrText = '',
    this.annotations = const [],
    this.markingStrokes,
  });
  factory TestAiEvaluation.fromJson(Map<String, Object?> json) {
    final int max = _testInteger(json['maxPoints']);
    final int awarded = _testInteger(json['awardedPoints']);
    if (max <= 0 || awarded < 0 || awarded > max) {
      throw const FormatException('Invalid grade');
    }
    return TestAiEvaluation(
      awardedPoints: awarded,
      maxPoints: max,
      feedback: json['feedback']! as String,
      breakdown: List<String>.from(json['breakdown']! as List),
      recognizedMathOrText: _string(json['recognizedMathOrText']),
      markingStrokes: json['markingStrokes'] is String
          ? base64Decode(json['markingStrokes']! as String)
          : null,
      annotations: [
        for (final raw in json['annotations'] as List? ?? [])
          TestAiAnnotation.fromJson(Map<String, Object?>.from(raw as Map)),
      ],
    );
  }
  final int awardedPoints, maxPoints;
  final String feedback, recognizedMathOrText;
  final List<String> breakdown;
  final List<TestAiAnnotation> annotations;
  final Uint8List? markingStrokes;
  Map<String, Object?> toJson() => {
    'awardedPoints': awardedPoints,
    'maxPoints': maxPoints,
    'feedback': feedback,
    'breakdown': breakdown,
    'recognizedMathOrText': recognizedMathOrText,
    'annotations': annotations.map((a) => a.toJson()).toList(),
    if (markingStrokes != null) 'markingStrokes': base64Encode(markingStrokes!),
  };
}

enum TestReferenceKind { answerSheet, equationSheet }

extension TestReferenceKindLabel on TestReferenceKind {
  String get label => switch (this) {
    TestReferenceKind.answerSheet => 'Answer sheet',
    TestReferenceKind.equationSheet => 'Equation sheet',
  };
}

@immutable
class TestReferenceSheet {
  const TestReferenceSheet({
    required this.kind,
    required this.name,
    required this.imagePaths,
    this.pdfPath,
  });

  factory TestReferenceSheet.fromJson(Map<String, Object?> json) =>
      TestReferenceSheet(
        kind: TestReferenceKind.values.byName(json['kind']! as String),
        name: json['name']! as String,
        imagePaths: List<String>.from(json['imagePaths']! as List),
        pdfPath: json['pdfPath'] as String?,
      );

  final TestReferenceKind kind;
  final String name;
  final List<String> imagePaths;
  final String? pdfPath;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'name': name,
    'imagePaths': imagePaths,
    'pdfPath': pdfPath,
  };
}

@immutable
class StudyTestPaper {
  const StudyTestPaper({
    required this.id,
    required this.title,
    required this.courseName,
    required this.instructions,
    required this.createdAt,
    required this.updatedAt,
    this.sourceNoteIds = const [],
    this.courseId,
    this.sourceSessionId,
    this.questions = const [],
    this.importedPdfPath,
    this.importedImagePaths = const [],
    this.referenceSheets = const [],
    this.isSubmitted = false,
    this.submittedAt,
    this.totalScore,
  });
  factory StudyTestPaper.fromJson(Map<String, Object?> json) => StudyTestPaper(
    id: json['id']! as String,
    courseId: json['courseId'] as String?,
    sourceSessionId: json['sourceSessionId'] as String?,
    title: json['title']! as String,
    courseName: _string(json['courseName']),
    instructions: _string(json['instructions']),
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt']! as int),
    sourceNoteIds: List<String>.from(json['sourceNoteIds'] as List? ?? []),
    questions: [
      for (final raw in json['questions']! as List)
        TestQuestion.fromJson(Map<String, Object?>.from(raw as Map)),
    ],
    importedPdfPath: json['importedPdfPath'] as String?,
    importedImagePaths: List<String>.from(
      json['importedImagePaths'] as List? ?? [],
    ),
    referenceSheets: [
      for (final raw in json['referenceSheets'] as List? ?? [])
        TestReferenceSheet.fromJson(Map<String, Object?>.from(raw as Map)),
    ],
    isSubmitted: json['isSubmitted'] == true,
    submittedAt: json['submittedAt'] is int
        ? DateTime.fromMillisecondsSinceEpoch(json['submittedAt']! as int)
        : null,
    totalScore: (json['totalScore'] as num?)?.toDouble(),
  );
  factory StudyTestPaper.fromLegacy(StudyPracticeSet set) => StudyTestPaper(
    id: 'test-${set.id}',
    courseId: set.courseId,
    sourceSessionId: set.sourceSessionId,
    title: set.title,
    courseName: '',
    instructions:
        'Read all questions carefully. Show all working steps in the canvas provided for full credit.',
    createdAt: set.createdAt,
    updatedAt: set.updatedAt,
    sourceNoteIds: set.sourceNoteIds,
    questions: [
      for (final q in set.multipleChoiceQuestions)
        TestMultipleChoiceQuestion(
          id: q.id,
          prompt: q.question,
          options: q.options,
          correctOptionId: q.correctOptionId,
          explanation: q.explanation,
          topic: q.topic,
          sourceCitation: q.sourceCitation,
          selectedOptionId: q.userSelectedOptionId,
        ),
    ],
  );
  final String id, title, courseName, instructions;
  final String? courseId;
  final String? sourceSessionId;
  final DateTime createdAt, updatedAt;
  final List<String> sourceNoteIds, importedImagePaths;
  final List<TestReferenceSheet> referenceSheets;
  final List<TestQuestion> questions;
  final String? importedPdfPath;
  final bool isSubmitted;
  final DateTime? submittedAt;
  final double? totalScore;
  int get totalPoints => questions.fold(0, (sum, q) => sum + q.points);
  int get answeredCount => questions
      .where(
        (q) => switch (q) {
          TestMultipleChoiceQuestion() => q.selectedOptionId != null,
          TestFreeResponseQuestion() =>
            q.handwritingStrokes != null && q.handwritingStrokes!.length > 2,
        },
      )
      .length;
  /// [clearCourse] takes the paper out of its class, which [courseId] cannot say.
  StudyTestPaper copyWith({
    String? courseId,
    bool clearCourse = false,
    List<TestQuestion>? questions,
    DateTime? updatedAt,
    bool? isSubmitted,
    DateTime? submittedAt,
    double? totalScore,
    List<TestReferenceSheet>? referenceSheets,
  }) => StudyTestPaper(
    id: id,
    courseId: clearCourse ? null : courseId ?? this.courseId,
    title: title,
    sourceSessionId: sourceSessionId,
    courseName: courseName,
    instructions: instructions,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sourceNoteIds: sourceNoteIds,
    questions: questions ?? this.questions,
    importedPdfPath: importedPdfPath,
    importedImagePaths: importedImagePaths,
    referenceSheets: referenceSheets ?? this.referenceSheets,
    isSubmitted: isSubmitted ?? this.isSubmitted,
    submittedAt: submittedAt ?? this.submittedAt,
    totalScore: totalScore ?? this.totalScore,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'courseId': courseId,
    'sourceSessionId': sourceSessionId,
    'title': title,
    'courseName': courseName,
    'instructions': instructions,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'sourceNoteIds': sourceNoteIds,
    'questions': questions.map((q) => q.toJson()).toList(),
    'importedPdfPath': importedPdfPath,
    'importedImagePaths': importedImagePaths,
    'referenceSheets': referenceSheets.map((sheet) => sheet.toJson()).toList(),
    'isSubmitted': isSubmitted,
    'submittedAt': submittedAt?.millisecondsSinceEpoch,
    'totalScore': totalScore,
  };
}
