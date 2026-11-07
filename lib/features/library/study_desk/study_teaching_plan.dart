import 'dart:convert';

enum StudyTeachingStage { learning, assessment, completed }

/// A bounded lesson outline, saved separately from the visible transcript.
class StudyTeachingPlan {
  StudyTeachingPlan({
    required this.topic,
    required List<StudyTeachingStep> steps,
    this.activeStep = 0,
    this.scopePrompt = '',
    this.stage = StudyTeachingStage.learning,
  }) : steps = List.unmodifiable(steps);

  final String topic;
  final List<StudyTeachingStep> steps;
  final int activeStep;
  final String scopePrompt;
  final StudyTeachingStage stage;

  StudyTeachingStep get current => steps[activeStep];

  static StudyTeachingPlan? tryRead(Object? value) {
    if (value is! Map) return null;
    if (utf8
            .encode(
              jsonEncode({
                'topic': value['topic'],
                'steps': value['steps'],
                'activeStep': value['activeStep'],
                'stage': value['stage'],
              }),
            )
            .length >
        8000) {
      return null;
    }
    final scope = value['scopePrompt'];
    if (scope != null && (scope is! String || scope.length > 1000)) {
      return null;
    }
    final topic = value['topic'];
    final rawSteps = value['steps'];
    final index = value['activeStep'] ?? 0;
    final stage = value['stage'] == null
        ? StudyTeachingStage.learning
        : StudyTeachingStage.values
              .where((stage) => stage.name == value['stage'])
              .firstOrNull;
    if (!_text(topic, 200) ||
        rawSteps is! List ||
        rawSteps.length < 2 ||
        rawSteps.length > 12 ||
        index is! int ||
        index < 0 ||
        index >= rawSteps.length ||
        stage == null ||
        (stage != StudyTeachingStage.learning &&
            index != rawSteps.length - 1)) {
      return null;
    }
    final steps = <StudyTeachingStep>[];
    for (final raw in rawSteps) {
      if (raw is! Map ||
          !_text(raw['title'], 160) ||
          !_text(raw['goal'], 600) ||
          !_text(raw['retrievalQuery'], 300) ||
          !_text(raw['foundationExercise'], 600)) {
        return null;
      }
      steps.add(
        StudyTeachingStep(
          title: (raw['title'] as String).trim(),
          goal: (raw['goal'] as String).trim(),
          retrievalQuery: (raw['retrievalQuery'] as String).trim(),
          foundationExercise: (raw['foundationExercise'] as String).trim(),
        ),
      );
    }
    return StudyTeachingPlan(
      topic: (topic as String).trim(),
      steps: steps,
      activeStep: index,
      stage: stage,
      scopePrompt: value['scopePrompt'] is String
          ? value['scopePrompt'] as String
          : '',
    );
  }

  StudyTeachingPlan atStep(int index) => StudyTeachingPlan(
    topic: topic,
    steps: steps,
    activeStep: index,
    scopePrompt: scopePrompt,
    stage: stage,
  );

  StudyTeachingPlan atStage(StudyTeachingStage stage) => StudyTeachingPlan(
    topic: topic,
    steps: steps,
    activeStep: activeStep,
    scopePrompt: scopePrompt,
    stage: stage,
  );

  StudyTeachingPlan withScope(String prompt) => StudyTeachingPlan(
    topic: topic,
    steps: steps,
    activeStep: activeStep,
    scopePrompt: prompt.length > 1000 ? prompt.substring(0, 1000) : prompt,
    stage: stage,
  );

  Map<String, Object?> toJson() => {
    'topic': topic,
    'activeStep': activeStep,
    'stage': stage.name,
    if (scopePrompt.isNotEmpty) 'scopePrompt': scopePrompt,
    'steps': [for (final step in steps) step.toJson()],
  };

  static bool _text(Object? value, int max) =>
      value is String && value.trim().isNotEmpty && value.length <= max;
}

class StudyTeachingStep {
  const StudyTeachingStep({
    required this.title,
    required this.goal,
    required this.retrievalQuery,
    required this.foundationExercise,
  });

  final String title;
  final String goal;
  final String retrievalQuery;
  final String foundationExercise;

  Map<String, Object?> toJson() => {
    'title': title,
    'goal': goal,
    'retrievalQuery': retrievalQuery,
    'foundationExercise': foundationExercise,
  };
}

enum StudyTeachingIntent {
  question,
  topic,
  continuation,
  assessment,
  review,
  complete,
}

enum StudyRetrievalDepth { brief, full }

class StudyTeachingDecision {
  const StudyTeachingDecision(
    this.intent,
    this.plan, {
    this.difficulty = 2,
    this.retrieveNotes = false,
    this.mistakeIndices = const [],
    this.retrievalQuery = '',
    this.retrievalDepth = StudyRetrievalDepth.full,
  });

  final StudyTeachingIntent intent;
  final StudyTeachingPlan? plan;
  final int difficulty;
  final bool retrieveNotes;
  final List<int> mistakeIndices;
  final String retrievalQuery;
  final StudyRetrievalDepth retrievalDepth;

  StudyTeachingDecision withRetrieval(StudyTeachingDecision decision) =>
      StudyTeachingDecision(
        intent,
        plan,
        difficulty: difficulty,
        retrieveNotes: decision.retrieveNotes,
        mistakeIndices: decision.mistakeIndices,
        retrievalQuery: decision.retrievalQuery,
        retrievalDepth: decision.retrievalDepth,
      );

  /// Explicit navigation needs no new plan or correctness judgment.
  static StudyTeachingDecision? explicitNavigation(
    String prompt,
    StudyTeachingPlan? previous,
  ) {
    if (previous == null ||
        previous.stage != StudyTeachingStage.learning ||
        !const {
          'next',
          'next step',
          'move on',
          '下一步',
        }.contains(prompt.trim().toLowerCase())) {
      return null;
    }
    if (previous.activeStep == previous.steps.length - 1) {
      return StudyTeachingDecision(
        StudyTeachingIntent.assessment,
        previous.atStage(StudyTeachingStage.assessment),
        difficulty: 3,
      );
    }
    return StudyTeachingDecision(
      StudyTeachingIntent.continuation,
      previous.atStep(previous.activeStep + 1),
      difficulty: 3,
    );
  }

  static StudyTeachingDecision? parse(
    String text, {
    StudyTeachingPlan? previous,
  }) {
    if (text.length > 32000) return null;
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (raw is! Map) return null;
    final Object? difficultyValue = raw['difficulty'] ?? 2;
    if (difficultyValue is! int || difficultyValue < 1 || difficultyValue > 3) {
      return null;
    }
    final retrieval = raw['retrieval'];
    if (retrieval != null) {
      if (retrieval is! Map ||
          retrieval['notes'] is! bool ||
          retrieval['mistakeIndices'] is! List ||
          (retrieval['mistakeIndices'] as List).length > 3 ||
          !(retrieval['mistakeIndices'] as List).every(
            (i) => i is int && i >= 1 && i <= 8,
          ) ||
          retrieval['query'] is! String ||
          (retrieval['query'] as String).length > 300 ||
          (retrieval['depth'] != null &&
              !const ['brief', 'full'].contains(retrieval['depth']))) {
        return null;
      }
      final copy = Map<String, Object?>.from(raw)..remove('retrieval');
      final decision = parse(jsonEncode(copy), previous: previous);
      if (decision == null) return null;
      return StudyTeachingDecision(
        decision.intent,
        decision.plan,
        difficulty: decision.difficulty,
        retrieveNotes: retrieval['notes'] as bool,
        mistakeIndices: List<int>.unmodifiable(
          (retrieval['mistakeIndices'] as List).cast<int>().toSet(),
        ),
        retrievalQuery: (retrieval['query'] as String).trim(),
        retrievalDepth: retrieval['depth'] == 'brief'
            ? StudyRetrievalDepth.brief
            : StudyRetrievalDepth.full,
      );
    }
    switch (raw['intent']) {
      case 'question':
        return StudyTeachingDecision(
          StudyTeachingIntent.question,
          previous,
          difficulty: difficultyValue,
        );
      case 'topic':
        final plan = StudyTeachingPlan.tryRead(raw['plan']);
        if (plan == null ||
            plan.activeStep != 0 ||
            plan.stage != StudyTeachingStage.learning) {
          return null;
        }
        return StudyTeachingDecision(
          StudyTeachingIntent.topic,
          plan,
          difficulty: difficultyValue,
        );
      case 'continue':
        final index = raw['activeStep'];
        if (previous == null ||
            previous.stage != StudyTeachingStage.learning ||
            index is! int ||
            index < 0 ||
            index >= previous.steps.length ||
            index > previous.activeStep + 1) {
          return null;
        }
        return StudyTeachingDecision(
          StudyTeachingIntent.continuation,
          previous.atStep(index),
          difficulty: difficultyValue,
        );
      case 'assessment':
        if (previous == null ||
            previous.stage != StudyTeachingStage.learning ||
            previous.activeStep != previous.steps.length - 1) {
          return null;
        }
        return StudyTeachingDecision(
          StudyTeachingIntent.assessment,
          previous.atStage(StudyTeachingStage.assessment),
          difficulty: difficultyValue,
        );
      case 'complete':
      case 'review':
        if (previous == null ||
            previous.stage != StudyTeachingStage.assessment) {
          return null;
        }
        return StudyTeachingDecision(
          raw['intent'] == 'review'
              ? StudyTeachingIntent.review
              : StudyTeachingIntent.complete,
          raw['intent'] == 'review'
              ? previous
              : previous.atStage(StudyTeachingStage.completed),
          difficulty: difficultyValue,
        );
      default:
        return null;
    }
  }
}
