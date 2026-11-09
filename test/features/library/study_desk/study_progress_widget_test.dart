import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_screen.dart';
import 'package:greatnote/shared/widgets/etonia_mascot.dart';

void main() {
  testWidgets(
    'progress shows actual search terms and note/page names, and updates between stages',
    (tester) async {
      Future<void> show(StudyRequestProgress progress) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SizedBox(
                width: 280,
                child: StudyWorkingIndicator(
                  state: StudyRequestState.searching,
                  progress: progress,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show(
        const StudyRequestProgress(
          StudyProgressPhase.searching,
          query: 'D flip-flop clock edge',
        ),
      );
      expect(find.textContaining('D flip-flop clock edge'), findsOneWidget);
      await show(
        const StudyRequestProgress(
          StudyProgressPhase.reading,
          query: 'clock edge',
          sources: [StudyProgressSource('Digital Logic', page: 7)],
        ),
      );
      expect(find.textContaining('Digital Logic, page 7'), findsOneWidget);
      await show(
        const StudyRequestProgress(
          StudyProgressPhase.describing,
          query: 'clock edge',
          sources: [StudyProgressSource('Digital Logic', page: 7)],
        ),
      );
      expect(find.text('Describing the visual notes…'), findsOneWidget);
      expect(
        find.textContaining('Using: Digital Logic, page 7'),
        findsOneWidget,
      );
      await show(const StudyRequestProgress(StudyProgressPhase.answering));
      expect(find.text('Writing your answer…'), findsOneWidget);
      expect(
        tester.widget<EtoniaMascot>(find.byType(EtoniaMascot)).clip,
        EtoniaClip.write,
        reason: 'the write animation plays while the answer is written',
      );
      expect(find.textContaining('Digital Logic'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
