import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_rag_index.dart';
import 'package:greatnote/features/library/study_desk/study_teaching_plan.dart';

void main() {
  StudyChunk chunk(
    List<String> text, {
    bool uncertain = false,
    StudyChunkKind kind = StudyChunkKind.text,
  }) => StudyChunk(
    noteId: 'note',
    pageIndex: 0,
    chunkIndex: 0,
    kind: kind,
    logicalBounds: const Rect.fromLTWH(0, 0, 500, 700),
    lowConfidence: uncertain,
    lines: [for (final line in text) StudyChunkLine(0, 0, line)],
  );
  final unrelated = List.filled(
    4,
    'This paragraph concerns pottery and kiln preparation. Clay is shaped by hand, '
    'dried carefully and then heated. Different glazes change its surface finish. '
    'The craft requires practice and attention to the material.',
  ).join(' ');
  test(
    'selection retains exact relevant paragraphs, their neighbors, and original line objects',
    () {
      final source = chunk([
        'Course notes',
        unrelated,
        unrelated,
        unrelated,
        'Phototropism is growth toward light. Auxin distribution changes how the shoot bends.',
        'In this example the shaded side elongates faster, bending the shoot toward light.',
        unrelated,
        unrelated,
        unrelated,
      ]);
      final selected = StudyEvidenceSelector.select(
        source,
        'Explain auxin phototropism.',
      );
      expect(selected.length, lessThan(source.lines.length));
      expect(selected, contains(same(source.lines[4])));
      expect(selected, contains(same(source.lines[5])));
      for (final line in selected) {
        expect(source.lines, contains(same(line)));
      }
    },
  );
  test(
    'mathematics, conditions, uncertain ink and diagrams are never token-pruned',
    () {
      for (final condition in [
        'x > 3',
        'domain: positive arguments',
        r'$x^2 + 1$',
        r'\frac{x}{2}',
      ]) {
        final source = chunk([
          'Heading',
          unrelated,
          unrelated,
          condition,
          unrelated,
          unrelated,
        ]);
        expect(
          StudyEvidenceSelector.select(source, 'Explain auxin phototropism.'),
          same(source.lines),
        );
      }
      for (final source in [
        chunk(List.filled(8, unrelated), uncertain: true),
        chunk(List.filled(8, unrelated), kind: StudyChunkKind.diagram),
      ]) {
        expect(
          StudyEvidenceSelector.select(source, 'Explain pottery preparation.'),
          same(source.lines),
        );
      }
    },
  );
  test('semantic-only or ambiguous matches retain the full source', () {
    final source = chunk(List.filled(8, unrelated));
    expect(
      StudyEvidenceSelector.select(source, 'Explain phototropism.'),
      same(source.lines),
    );
    expect(StudyEvidenceSelector.select(source, 'this'), same(source.lines));
  });
  test(
    'a mathematical source block that exceeds the budget is omitted whole',
    () async {
      final source = chunk([
        r'Original equation: $x^2 - 4x - 5 = 0$.',
        'Its domain requires x > 3. ${List.filled(100, 'Keep the complete restriction.').join(' ')}',
      ]);
      final payload = await const StudyContextAssembler(maxTextTokens: 40)
          .assemble([
            StudyHit(
              StudySearchDocument(chunk: source, noteTitle: 'Domain example'),
              1,
            ),
          ], query: 'Solve the original equation.');
      expect(payload.contextText, isEmpty);
      expect(payload.map.chunks, isEmpty);
    },
  );
  final plan = StudyTeachingPlan(
    topic: 'Algebra',
    steps: const [
      StudyTeachingStep(
        title: 'Variables',
        goal: 'Understand variables',
        retrievalQuery: 'variables',
        foundationExercise: 'What is x?',
      ),
      StudyTeachingStep(
        title: 'Equations',
        goal: 'Balance equations',
        retrievalQuery: 'equations',
        foundationExercise: 'Solve x + 1 = 2.',
      ),
    ],
  );
  test(
    'only explicit lesson navigation bypasses planning and never skips a step',
    () {
      expect(
        StudyTeachingDecision.explicitNavigation(
          'next',
          plan,
        )!.plan!.activeStep,
        1,
      );
      expect(
        StudyTeachingDecision.explicitNavigation(
          'next step',
          plan.atStep(1),
        )!.intent,
        StudyTeachingIntent.assessment,
      );
      for (final prompt in [
        'continue',
        'I am confused',
        '2',
        'next chapter',
        'finish the test',
      ]) {
        expect(StudyTeachingDecision.explicitNavigation(prompt, plan), isNull);
      }
      expect(
        StudyTeachingDecision.explicitNavigation(
          'next',
          plan.atStep(1).atStage(StudyTeachingStage.assessment),
        ),
        isNull,
      );
    },
  );
  test(
    'planner difficulty is bounded, defaults conservatively, and does not alter lesson state',
    () {
      expect(
        StudyTeachingDecision.parse(
          '{"intent":"question"}',
          previous: plan,
        )!.difficulty,
        2,
      );
      final decision = StudyTeachingDecision.parse(
        '{"intent":"question","difficulty":1}',
        previous: plan,
      )!;
      expect(decision.plan, same(plan));
      expect(decision.difficulty, 1);
      for (final value in [0, 4, 'easy', 1.5]) {
        expect(
          StudyTeachingDecision.parse(
            jsonEncode({'intent': 'question', 'difficulty': value}),
          ),
          isNull,
        );
      }
    },
  );
}
