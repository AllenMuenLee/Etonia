import 'dart:convert';

import 'practice/study_mistakes.dart';
import 'study_rag_index.dart' show studyTokens, StudyContextAssembler;

/// Most introductions need a small source anchor, not the full evidence budget.
StudyContextAssembler studyBriefAssembler(StudyContextAssembler normal) =>
    StudyContextAssembler(
      maxTextTokens: normal.maxTextTokens > 800 ? 800 : normal.maxTextTokens,
      maxPictures: normal.maxPictures > 1 ? 1 : normal.maxPictures,
      maxSvgCharacters: 0,
      maxTotalBytes: normal.maxTotalBytes,
    );

/// A bounded local index for the model's relevance decision, not full records.
List<StudyMistake> studyMistakeCandidates(
  List<StudyMistake> mistakes,
  String query, {
  String? courseId,
}) {
  final tokens = studyTokens(query).toSet();
  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
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
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byCourse = (b.mistake.courseId == courseId ? 1 : 0).compareTo(
          a.mistake.courseId == courseId ? 1 : 0,
        );
        return byCourse != 0
            ? byCourse
            : b.mistake.gradedAt.compareTo(a.mistake.gradedAt);
      });
  final seen = <String>{};
  return [
    for (final entry in ranked)
      if (seen.add(
        jsonEncode([entry.mistake.sourceId, entry.mistake.question.id]),
      ))
        entry.mistake,
  ].take(8).toList(growable: false);
}

String studyMistakeCatalogue(List<StudyMistake> candidates) {
  if (candidates.isEmpty) return '';
  String brief(String text, int limit) =>
      text.length > limit ? text.substring(0, limit) : text;
  final entries = [
    for (var i = 0; i < candidates.length; i++)
      {
        'index': i + 1,
        'topic': brief(candidates[i].question.topic, 80),
        'question': brief(candidates[i].question.prompt, 180),
        'errorHint': brief(
          candidates[i].context['feedback'] as String? ?? '',
          120,
        ),
        'studentAnswer': brief(
          jsonEncode(candidates[i].context['studentAnswer']),
          60,
        ),
        'unanswered': candidates[i].context['unanswered'],
      },
  ];
  return 'Mistake topic index (availability only, not confirmed relevance):\n${jsonEncode(entries)}\n\n';
}
