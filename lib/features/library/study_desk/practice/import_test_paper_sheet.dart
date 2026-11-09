import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/widgets/etonia_mark.dart';
import 'package:path_provider/path_provider.dart';

import '../../../editor/document_io/document_platform.dart';
import 'study_practice_models.dart';

class ImportTestPaperSheet extends StatefulWidget {
  const ImportTestPaperSheet({
    super.key,
    this.picker = const SystemDocumentPicker(),
    this.rasterizer = const PdfrxRasterizer(),
    this.referenceKind,
  });
  final DocumentPicker picker;
  final PdfRasterizer rasterizer;
  final TestReferenceKind? referenceKind;
  @override
  State<ImportTestPaperSheet> createState() => _ImportTestPaperSheetState();
}

class _ImportTestPaperSheetState extends State<ImportTestPaperSheet> {
  bool busy = false;
  String? error;
  Future<void> _import(bool pdf) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final picked = pdf
          ? await widget.picker.pickPdf()
          : await widget.picker.pickImage(DocumentImageSource.gallery);
      if (picked == null || !mounted) return;
      if (picked.bytes.length > 40 * 1024 * 1024) {
        throw const FormatException('Choose a document under 40 MB.');
      }
      final now = DateTime.now();
      final dir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/study_test_imports/${now.microsecondsSinceEpoch}',
      );
      await dir.create(recursive: true);
      final paths = <String>[];
      String? pdfPath;
      if (pdf) {
        final info = await widget.rasterizer.inspect(picked.bytes);
        if (info.pageSizes.isEmpty ||
            info.pageSizes.length > 30 ||
            info.isEncrypted) {
          throw const FormatException(
            'Choose an unlocked PDF with 1–30 pages.',
          );
        }
        pdfPath = '${dir.path}/original.pdf';
        await File(pdfPath).writeAsBytes(picked.bytes, flush: true);
        for (int i = 0; i < info.pageSizes.length; i++) {
          final size = info.pageSizes[i];
          final page = await widget.rasterizer.render(
            picked.bytes,
            i,
            pixelWidth: (1600 * size.aspectRatio).round(),
            pixelHeight: 1600,
          );
          final path = '${dir.path}/page-$i.png';
          await File(path).writeAsBytes(page.png, flush: true);
          paths.add(path);
        }
      } else {
        final codec = await ui.instantiateImageCodec(
          picked.bytes,
          targetWidth: 1600,
        );
        try {
          final image = (await codec.getNextFrame()).image;
          try {
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            final path = '${dir.path}/page-0.png';
            await File(path).writeAsBytes(png, flush: true);
            paths.add(path);
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
      if (widget.referenceKind case final kind?) {
        if (mounted) {
          Navigator.of(context).pop(
            TestReferenceSheet(
              kind: kind,
              name: picked.name,
              imagePaths: paths,
              pdfPath: pdfPath,
            ),
          );
        }
        return;
      }
      final paper = StudyTestPaper(
        id: 'import-${now.microsecondsSinceEpoch}',
        title: picked.name,
        courseName: 'Imported exam',
        instructions:
            'Write directly on each page. Each page is normalized to 100 points for AI grading.',
        createdAt: now,
        updatedAt: now,
        importedPdfPath: pdfPath,
        importedImagePaths: paths,
        questions: [
          for (int i = 0; i < paths.length; i++)
            TestFreeResponseQuestion(
              id: 'page-$i',
              prompt: 'Imported exam · Page ${i + 1}',
              subParts: const [],
              rubric: const [
                'Evaluate the printed questions and handwritten responses. Normalize the page score to 100 points. Award partial credit for valid working.',
              ],
              points: 100,
              backgroundImagePath: paths[i],
            ),
        ],
      );
      if (mounted) Navigator.of(context).pop(paper);
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'Could not import this paper. Try another file.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.referenceKind == null
                  ? 'Import Test Paper'
                  : 'Import ${widget.referenceKind!.label.toLowerCase()}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.referenceKind == null
                  ? 'Bring in a PDF or photo and write directly on its pages.'
                  : 'Keep a PDF or photo beside your test while you work.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.resolve(context).textSecondary,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Semantics(
                liveRegion: true,
                child: Text(
                  error!,
                  style: TextStyle(color: AppColors.resolve(context).danger),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            if (busy)
              Row(
                children: [
                  EtoniaBarsLoader(
                    size: 24,
                    color: AppColors.resolve(context).textPrimary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  const Expanded(child: Text('Preparing pages…')),
                ],
              )
            else
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  FilledButton.icon(
                    onPressed: () => _import(true),
                    icon: const AppIcon(AppIcons.pdf, size: 18),
                    label: const Text('Choose PDF'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _import(false),
                    icon: const AppIcon(AppIcons.insertImage, size: 18),
                    label: const Text('Choose Photo'),
                  ),
                ],
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    ),
  );
}
