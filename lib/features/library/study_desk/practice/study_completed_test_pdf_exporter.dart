import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'study_practice_models.dart';
import 'study_test_pdf_exporter.dart';
import 'test_handwriting_canvas.dart';

class StudyCompletedTestPdfExporter {
  const StudyCompletedTestPdfExporter();

  Future<Uint8List> export(
    StudyTestPaper paper, {
    Future<Uint8List> Function(TestQuestion question)? snapshot,
    StudyTestTextRasterizer rasterizeText = rasterizeStudyTestText,
  }) async {
    final document = pw.Document();
    for (final question in paper.questions) {
      final lines = <String>[
        paper.title,
        paper.courseName,
        paper.instructions,
        if (paper.isSubmitted)
          'Final score: ${paper.totalScore ?? 0}/${paper.totalPoints}',
        '${question.points} Pts · ${question.prompt}',
        if (question is TestMultipleChoiceQuestion) ...[
          for (final option in question.options)
            '${option.id == question.selectedOptionId ? "[x]" : "[ ]"} ${option.id}. ${option.text}',
          if (paper.isSubmitted)
            '${question.isCorrect ? question.points : 0}/${question.points}: ${question.explanation}',
        ],
        if (question is TestFreeResponseQuestion) ...question.subParts,
      ];
      final content = <pw.Widget>[];
      Future<void> text(String value) async {
        final plain = studyTestPlainText(value);
        // Bounded paragraphs remain splittable across PDF pages.
        for (int start = 0; start < plain.length; start += 450) {
          final end = (start + 450).clamp(0, plain.length);
          final rendered = await rasterizeText(
            plain.substring(start, end),
            widthPt: 480,
            fontSize: 11,
            bold: false,
          );
          content.add(
            pw.Image(
              pw.MemoryImage(rendered.png),
              width: 480,
              height: rendered.heightPt,
            ),
          );
        }
      }

      for (final line in lines) {
        await text(line);
      }
      content.add(
        pw.Image(
          pw.MemoryImage(
            await (snapshot ?? snapshotStudyTestQuestion)(question),
          ),
          width: 480,
          height: 500,
          fit: pw.BoxFit.contain,
        ),
      );
      if (question is TestFreeResponseQuestion &&
          question.aiEvaluation != null) {
        final evaluation = question.aiEvaluation!;
        await text(
          '${evaluation.awardedPoints}/${evaluation.maxPoints}: ${evaluation.feedback}',
        );
        for (final step in evaluation.breakdown) {
          await text(step);
        }
        for (var i = 0; i < evaluation.annotations.length; i++) {
          await text('${i + 1}. ${evaluation.annotations[i].label}');
        }
      }
      document.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          maxPages: 100,
          build: (_) => content,
        ),
      );
    }
    return document.save();
  }
}

Future<Uint8List> snapshotStudyTestQuestion(TestQuestion question) =>
    renderTestAnswer(
      question.handwritingStrokes,
      backgroundPath: question is TestFreeResponseQuestion
          ? question.backgroundImagePath
          : null,
      markingStrokes: question is TestFreeResponseQuestion
          ? question.aiEvaluation?.markingStrokes
          : null,
      annotations: question is TestFreeResponseQuestion
          ? question.aiEvaluation?.annotations ?? const []
          : const [],
    );
