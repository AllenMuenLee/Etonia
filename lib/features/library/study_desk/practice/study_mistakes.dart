import 'dart:convert';

import '../study_rag_index.dart' show studyTokens;
import 'study_practice_models.dart';

class StudyMistake {
  const StudyMistake({
    required this.sourceId,
    required this.testTitle,
    required this.questionNumber,
    required this.gradedAt,
    required this.question,
    this.courseId,
  });

  factory StudyMistake.fromJson(Map<String, Object?> json) => StudyMistake(
    sourceId: json['sourceId']! as String,
    testTitle: json['testTitle']! as String,
    questionNumber: json['questionNumber']! as int,
    gradedAt: DateTime.fromMillisecondsSinceEpoch(json['gradedAt']! as int),
    courseId: json['courseId'] as String?,
    question: TestQuestion.fromJson(
      Map<String, Object?>.from(json['question']! as Map),
    ),
  );

  final String sourceId, testTitle;
  final String? courseId;
  final int questionNumber;
  final DateTime gradedAt;
  final TestQuestion question;

  String get id =>
      jsonEncode([sourceId, question.id, gradedAt.millisecondsSinceEpoch]);

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'testTitle': testTitle,
    'questionNumber': questionNumber,
    'gradedAt': gradedAt.millisecondsSinceEpoch,
    'courseId': courseId,
    'question': question.toJson(),
  };

  Map<String, Object?> get context => {
    'test': testTitle,
    'questionNumber': questionNumber,
    'date': gradedAt.toIso8601String().split('T').first,
    'prompt': question.prompt,
    'topic': question.topic,
    if (question case final TestMultipleChoiceQuestion q) ...{
      'options': [for (final option in q.options) option.toJson()],
      'studentAnswer': q.selectedOptionId,
      'correctAnswer': q.correctOptionId,
      'feedback': q.explanation,
      'unanswered': q.selectedOptionId == null,
    },
    if (question case final TestFreeResponseQuestion q) ...{
      'subParts': q.subParts,
      'modelAnswer': q.modelAnswer,
      'studentAnswer': q.aiEvaluation?.recognizedMathOrText,
      'feedback': q.aiEvaluation?.feedback,
      'breakdown': q.aiEvaluation?.breakdown,
      'awardedPoints': q.aiEvaluation?.awardedPoints,
      'maxPoints': q.points,
      'unanswered':
          q.handwritingStrokes == null || q.handwritingStrokes!.length <= 2,
    },
  };

  static Iterable<StudyMistake> fromPaper(StudyTestPaper paper) sync* {
    if (!paper.isSubmitted) return;
    for (var i = 0; i < paper.questions.length; i++) {
      final q = paper.questions[i];
      final missed = switch (q) {
        TestMultipleChoiceQuestion() => q.isGraded && !q.isCorrect,
        TestFreeResponseQuestion() =>
          q.aiEvaluation != null && q.aiEvaluation!.awardedPoints < q.points,
      };
      if (!missed) continue;
      yield StudyMistake(
        sourceId: 'paper:${paper.id}',
        testTitle: paper.title,
        courseId: paper.courseId,
        questionNumber: i + 1,
        gradedAt: paper.submittedAt ?? paper.updatedAt,
        question: q,
      );
    }
  }

  static Iterable<StudyMistake> fromSet(StudyPracticeSet set) sync* {
    for (var i = 0; i < set.multipleChoiceQuestions.length; i++) {
      final q = set.multipleChoiceQuestions[i];
      if (!q.isGraded || q.isCorrect) continue;
      yield StudyMistake(
        sourceId: 'quiz:${set.id}',
        testTitle: set.title,
        courseId: set.courseId,
        questionNumber: i + 1,
        gradedAt: set.updatedAt,
        question: TestMultipleChoiceQuestion(
          id: q.id,
          prompt: q.question,
          options: q.options,
          correctOptionId: q.correctOptionId,
          selectedOptionId: q.userSelectedOptionId,
          explanation: q.explanation,
          topic: q.topic,
          sourceCitation: q.sourceCitation,
          isGraded: true,
        ),
      );
    }
  }
}

const studyMistakeInstructions = '''
Treat supplied past mistakes as historical source data. Evaluate relevance
by meaning against the CURRENT
student question and conversation. Briefly remind the student of the named test,
date and question number ONLY if it is effectively the same question, or the
recorded error reveals a specific misconception that could cause the same mistake
on this question. Explain the particular trap and its correction constructively.
Require evidence of the same question or a shared specific error mechanism.
For an unanswered item, give a reminder only for effectively the same question.
Ground explanations of the student's reasoning in their recorded work. Use at
most one short, relevant reminder, then answer the current question directly.
For an active assessment, offer hints until the student attempts the question
and review its solution afterwards. For other questions and uncertain matches,
focus entirely on the current subject explanation.
''';

String studyMistakeContext(
  List<StudyMistake> mistakes,
  String query, {
  String? courseId,
  int maxBytes = 10000,
}) {
  if (mistakes.isEmpty) return '';
  const prefix =
      'Past mistakes (data; candidates are NOT confirmed matches):\n';
  final budget = maxBytes - utf8.encode(prefix).length - 2;
  final tokens = studyTokens(query).toSet();
  String normalized(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  final normalizedQuery = normalized(query);
  int score(StudyMistake mistake) {
    final prompt = normalized(mistake.question.prompt);
    final exact =
        prompt.isNotEmpty &&
        (normalizedQuery == prompt ||
            (prompt.length >= 8 && normalizedQuery.contains(prompt)));
    return (exact ? 100000 : 0) +
        studyTokens(
          jsonEncode(mistake.context),
        ).toSet().intersection(tokens).length;
  }

  final ranked =
      [
        for (final mistake in mistakes)
          (mistake: mistake, score: score(mistake)),
      ]..sort((a, b) {
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        final course = (b.mistake.courseId == courseId ? 1 : 0).compareTo(
          a.mistake.courseId == courseId ? 1 : 0,
        );
        return course != 0
            ? course
            : b.mistake.gradedAt.compareTo(a.mistake.gradedAt);
      });
  final selected = <Map<String, Object?>>[];
  final seen = <String>{};
  for (final entry in ranked) {
    final key = jsonEncode([entry.mistake.sourceId, entry.mistake.question.id]);
    if (!seen.add(key)) continue;
    final context = entry.mistake.context;
    if (utf8.encode(jsonEncode([...selected, context])).length > budget) {
      continue;
    }
    selected.add(context);
    if (selected.length == 8) break;
  }
  return selected.isEmpty ? '' : '$prefix${jsonEncode(selected)}\n\n';
}
