import 'dart:convert';

import '../study_desk_models.dart';
import '../study_rag_index.dart';
import 'study_practice_models.dart';
import 'study_completed_test_pdf_exporter.dart';

Future<StudyPayload> studyTestReviewPayload(
  StudyTestPaper paper,
  String prompt,
  List<StudyMessage> history, {
  int reservedTextBytes = 0,
}) async {
  final number = RegExp(
    r'\b(?:question|q|problem|page)\s*#?\s*(\d+)\b',
    caseSensitive: false,
  );
  int? selected(String text) {
    final match = number.firstMatch(text);
    return match == null ? null : int.tryParse(match[1]!);
  }

  int? focused = selected(prompt);
  if (focused == null) {
    for (final message in history.reversed.where((m) => m.fromUser)) {
      focused = selected(message.text);
      if (focused != null) break;
    }
  }
  final questions = paper.questions;
  if (focused == null && questions.isNotEmpty) {
    final index = questions.indexWhere(
      (q) => switch (q) {
        TestMultipleChoiceQuestion() => !q.isCorrect,
        TestFreeResponseQuestion() =>
          (q.aiEvaluation?.awardedPoints ?? 0) < q.points,
      },
    );
    focused = index < 0 ? 1 : index + 1;
  }
  final index = focused == null ? -1 : focused - 1;
  final question = index >= 0 && index < questions.length
      ? questions[index]
      : null;
  final overview = jsonEncode({
    'test': paper.title,
    'course': paper.courseName,
    'score': paper.totalScore,
    'maxPoints': paper.totalPoints,
    'questions': [
      for (var i = 0; i < questions.length; i++)
        {'number': i + 1, ..._questionContext(questions[i], brief: true)},
    ],
  });
  final detail = question == null
      ? 'The requested question is outside this test. Do not invent its content.'
      : jsonEncode({
          'attachedAnswerImageForQuestion': focused,
          'instructions': paper.instructions,
          ..._questionContext(question),
        });
  // The focused question precedes the bounded overview of the rest of the test.
  final budget = (21000 - utf8.encode(prompt).length - reservedTextBytes).clamp(
    0,
    18000,
  );
  final text = _bounded('$detail\nTest overview: $overview', budget);
  return StudyPayload(
    contextText: text,
    imagePng: question == null
        ? StudyContextAssembler.placeholderPng
        : await snapshotStudyTestQuestion(question),
    map: StudySourceMap(noteIds: const {}, chunks: const [], crops: const {}),
    estimatedTextTokens: (text.length / 4).ceil(),
  );
}

Map<String, Object?> _questionContext(
  TestQuestion question, {
  bool brief = false,
}) => {
  'prompt': question.prompt,
  'maxPoints': question.points,
  if (question is TestMultipleChoiceQuestion) ...{
    'options': [for (final option in question.options) option.toJson()],
    'selectedOption': question.selectedOptionId,
    'correctOption': question.correctOptionId,
    'awardedPoints': question.isCorrect ? question.points : 0,
    'explanation': question.explanation,
  },
  if (question is TestFreeResponseQuestion) ...{
    if (!brief) 'subParts': question.subParts,
    if (!brief) 'rubric': question.rubric,
    if (!brief) 'modelAnswer': question.modelAnswer,
    'awardedPoints': question.aiEvaluation?.awardedPoints,
    'feedback': question.aiEvaluation?.feedback,
    if (!brief) 'breakdown': question.aiEvaluation?.breakdown,
    if (!brief)
      'recognizedResponse': question.aiEvaluation?.recognizedMathOrText,
    if (!brief)
      'annotations': [
        for (final annotation
            in question.aiEvaluation?.annotations ?? <TestAiAnnotation>[])
          annotation.toJson(),
      ],
  },
};

String _bounded(String text, int bytes) {
  if (utf8.encode(text).length <= bytes) return text;
  final result = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    used += utf8.encode(character).length;
    if (used > bytes) break;
    result.write(character);
  }
  return '${result.toString()}\n[Remaining test context omitted; ask about a specific question.]';
}
