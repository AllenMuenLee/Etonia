import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/navigation/app_sheets.dart';
import '../../../editor/ai/ai_client.dart';
import '../../../editor/document_io/document_platform.dart';
import '../../../editor/widgets/ai_assistant_panel.dart' show AiAnswerMarkdown;
import '../../../../shared/widgets/etonia_mascot.dart';
import '../study_desk_controller.dart';
import '../study_desk_models.dart';
import '../study_material_sources.dart';
import 'import_test_paper_sheet.dart';
import 'study_practice_models.dart';
import 'test_handwriting_canvas.dart';
import 'study_completed_test_pdf_exporter.dart';
import 'test_paper_editor.dart';
import 'test_reference_panel.dart';

class StudyTestPaperPlayer extends StatefulWidget {
  const StudyTestPaperPlayer({
    super.key,
    required this.paper,
    required this.controller,
    required this.onClose,
    required this.onViewCitation,
    this.onSaveToLibrary,
    this.picker = const SystemDocumentPicker(),
    this.rasterizer = const PdfrxRasterizer(),
    this.manageBackNavigation = true,
    this.showCloseButton = true,
    this.closeTooltip = 'Back to Tests',
  });
  final StudyTestPaper paper;
  final StudyDeskController controller;
  final VoidCallback onClose;
  final ValueChanged<StudyCitation> onViewCitation;
  final Future<void> Function(Uint8List pdf, String title)? onSaveToLibrary;
  final DocumentPicker picker;
  final PdfRasterizer rasterizer;
  final bool manageBackNavigation;
  final bool showCloseButton;
  final String closeTooltip;
  @override
  State<StudyTestPaperPlayer> createState() => _StudyTestPaperPlayerState();
}

class _StudyTestPaperPlayerState extends State<StudyTestPaperPlayer> {
  late StudyTestPaper paper = widget.paper;
  bool busy = false;

  /// The AI is grading the submitted answers: Etonia hops and shakes.
  bool grading = false;
  String? error;
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  final _paperSurfaceKey = GlobalKey();
  final Map<String, GlobalKey> _choiceKeys = {};
  bool _referencesOpen = false;
  TestReferenceKind _referenceKind = TestReferenceKind.equationSheet;
  @override
  void initState() {
    super.initState();
    if (widget.manageBackNavigation) widget.controller.onPracticeBack = _back;
  }

  bool _back() {
    if (busy) return true;
    unawaited(_close());
    return true;
  }

  List<Rect> _choiceBounds() => [
    for (final key in _choiceKeys.values)
      if (key.currentContext?.findRenderObject() case final RenderBox box
          when box.attached && box.hasSize)
        MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        ),
  ];

  void _change(TestQuestion question) {
    if (busy || paper.isSubmitted) return;
    // Ink commits during pointer events; keep document edits independent of rebuilds.
    paper = paper.copyWith(
      questions: [
        for (final q in paper.questions) q.id == question.id ? question : q,
      ],
      updatedAt: widget.controller.clock(),
    );
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() {});
      _save();
    });
  }

  void _save() {
    final snapshot = paper;
    _writes = _writes
        .then((_) => widget.controller.saveTestPaper(snapshot))
        .catchError((Object _) {
          if (mounted) {
            setState(
              () => error =
                  'Could not save this paper. Try again before leaving.',
            );
          }
        });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (!paper.isSubmitted && !busy) _save();
    if (widget.controller.onPracticeBack == _back) {
      widget.controller.onPracticeBack = null;
    }
    super.dispose();
  }

  Future<void> _close() async {
    setState(() => error = null);
    _saveTimer?.cancel();
    _save();
    await _writes;
    if (mounted && error == null) widget.onClose();
  }

  Future<void> _openSourceChat(String id) async {
    setState(() => error = null);
    _saveTimer?.cancel();
    _save();
    await _writes;
    if (mounted && error == null) widget.controller.openMaterialSourceChat(id);
  }

  Future<void> _browseSources() => showAppSheet<void>(
    context: context,
    motionKey: 'test-sources',
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: StudyMaterialSources(
          controller: widget.controller,
          noteIds: paper.sourceNoteIds,
          sourceSessionId: paper.sourceSessionId,
          onOpenNote: (id) {
            Navigator.of(sheetContext).pop();
            widget.onViewCitation(
              StudyCitation(
                noteId: id,
                pageIndex: 0,
                revision: widget.controller.revisionOf(id),
              ),
            );
          },
          onOpenChat: (id) {
            Navigator.of(sheetContext).pop();
            unawaited(_openSourceChat(id));
          },
        ),
      ),
    ),
  );

  Future<void> _saveToLibrary() async {
    setState(() {
      busy = true;
      error = null;
    });
    _saveTimer?.cancel();
    _save();
    await _writes;
    try {
      if (error != null) return;
      final bytes = await const StudyCompletedTestPdfExporter().export(paper);
      if (mounted) await widget.onSaveToLibrary?.call(bytes, paper.title);
    } on Object {
      if (mounted) {
        setState(() => error = 'Could not add this test to your library.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<Uint8List> _snapshot(TestQuestion q) => renderTestAnswer(
    q.handwritingStrokes,
    backgroundPath: q is TestFreeResponseQuestion
        ? q.backgroundImagePath
        : null,
  );
  Future<void> _submit() async {
    setState(() {
      busy = true;
      grading = true;
      error = null;
    });
    _saveTimer?.cancel();
    _save();
    await _writes;
    try {
      if (error != null) return;
      final graded = await widget.controller.testGrader.grade(
        paper,
        snapshot: _snapshot,
        clock: widget.controller.clock,
        loadReferenceImage: (path) => File(path).readAsBytes(),
      );
      await widget.controller.saveTestPaper(graded);
      if (mounted) {
        setState(() => paper = graded);
        widget.controller.startTestReviewChat(graded);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => error = e is AiFailure
              ? e.message
              : 'Grading could not finish. Your answers are saved; try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          grading = false;
        });
      }
    }
  }

  Future<void> _export() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final bytes = await const StudyCompletedTestPdfExporter().export(paper);
      final file = File(
        '${(await getTemporaryDirectory()).path}/completed-${paper.id}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        final box = context.findRenderObject() as RenderBox?;
        await const SystemExportSink().share(
          file,
          sharePositionOrigin: box != null && box.hasSize
              ? box.localToGlobal(Offset.zero) & box.size
              : null,
        );
      }
    } on Object {
      if (mounted) setState(() => error = 'Could not export this paper.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _importReference(TestReferenceKind kind) async {
    if (busy) return;
    final sheet = await showAppSheet<TestReferenceSheet>(
      context: context,
      motionKey: 'study-import-reference',
      builder: (_) => ImportTestPaperSheet(
        picker: widget.picker,
        rasterizer: widget.rasterizer,
        referenceKind: kind,
      ),
    );
    if (sheet == null || !mounted) return;
    setState(() {
      paper = paper.copyWith(
        referenceSheets: [
          for (final existing in paper.referenceSheets)
            if (existing.kind != kind) existing,
          sheet,
        ],
        updatedAt: widget.controller.clock(),
      );
      _referenceKind = kind;
      _referencesOpen = true;
      error = null;
    });
    _save();
    await _writes;
  }

  Widget _referencePanel() => TestReferencePanel(
    sheets: paper.referenceSheets,
    kind: _referenceKind,
    onKindChanged: (kind) => setState(() => _referenceKind = kind),
    onImport: _importReference,
    onClose: () => setState(() => _referencesOpen = false),
    busy: busy,
  );

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.xxs,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final actions = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<TestReferenceKind>(
                    tooltip: 'Import reference sheet',
                    enabled: !busy,
                    icon: const AppIcon(AppIcons.add),
                    onSelected: _importReference,
                    itemBuilder: (_) => [
                      for (final kind in TestReferenceKind.values)
                        PopupMenuItem(
                          value: kind,
                          child: Text('Import ${kind.label.toLowerCase()}'),
                        ),
                    ],
                  ),
                  IconButton(
                    key: const ValueKey('study-save-test-to-library'),
                    onPressed: busy
                        ? null
                        : widget.onSaveToLibrary == null
                        ? null
                        : _saveToLibrary,
                    tooltip: 'Add to library or folder',
                    icon: const AppIcon(AppIcons.newFolder),
                  ),
                  IconButton(
                    onPressed: busy ? null : _export,
                    tooltip: 'Export handwritten PDF',
                    icon: const AppIcon(AppIcons.share),
                  ),
                ],
              );
              final compact =
                  constraints.maxWidth < 600 ||
                  MediaQuery.textScalerOf(context).scale(17) > 24;
              final heading = Row(
                children: [
                  if (widget.showCloseButton)
                    IconButton(
                      onPressed: busy ? null : _close,
                      tooltip: widget.closeTooltip,
                      icon: const AppIcon(AppIcons.back),
                    ),
                  const SizedBox(width: AppSpacing.xxs),
                  Expanded(
                    child: Text(
                      paper.isSubmitted ? 'Graded Paper' : 'Test Paper',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('test-browse-sources'),
                    tooltip: 'Browse sources',
                    onPressed: busy ? null : _browseSources,
                    icon: const AppIcon(AppIcons.folder),
                  ),
                  IconButton(
                    tooltip: 'Reference sheets',
                    isSelected: _referencesOpen,
                    style: IconButton.styleFrom(
                      backgroundColor: _referencesOpen ? colors.accent : null,
                      foregroundColor: _referencesOpen
                          ? colors.onAccent
                          : colors.textPrimary,
                    ),
                    onPressed: () =>
                        setState(() => _referencesOpen = !_referencesOpen),
                    icon: const AppIcon(AppIcons.library),
                  ),
                  if (!compact)
                    actions
                  else
                    PopupMenuButton<String>(
                      tooltip: 'Test actions',
                      icon: const AppIcon(AppIcons.more),
                      enabled: !busy,
                      onSelected: (action) {
                        if (action == 'export') {
                          unawaited(_export());
                        } else if (action == 'save') {
                          unawaited(_saveToLibrary());
                        } else {
                          unawaited(
                            _importReference(
                              TestReferenceKind.values.byName(action),
                            ),
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        for (final kind in TestReferenceKind.values)
                          PopupMenuItem(
                            value: kind.name,
                            child: Text('Import ${kind.label.toLowerCase()}'),
                          ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'save',
                          enabled: widget.onSaveToLibrary != null,
                          child: const Text('Add to library or folder'),
                        ),
                        const PopupMenuItem(
                          value: 'export',
                          child: Text('Export handwritten PDF'),
                        ),
                      ],
                    ),
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [heading],
              );
            },
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final test = TestPaperEditor(
                key: _paperSurfaceKey,
                paper: paper,
                readOnly: busy || paper.isSubmitted,
                inputExclusions: _choiceBounds,
                feedbackBuilder: (context, index) =>
                    _feedback(context, paper.questions[index]),
                onError: (message) {
                  if (mounted) setState(() => error = message);
                },
                onInkChanged: (id, strokes) {
                  final latest = paper.questions.firstWhere((q) => q.id == id);
                  _change(latest.copyWithStrokes(strokes));
                },
                questionBuilder: (context, index) => _question(
                  context,
                  paper.questions[index],
                  index,
                  AppColors.of(context),
                ),
              );
              if (!_referencesOpen) return test;
              if (constraints.maxWidth >= 820) {
                return Row(
                  children: [
                    Expanded(child: test),
                    const VerticalDivider(width: 1),
                    SizedBox(width: 300, child: _referencePanel()),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: test),
                  const Divider(height: 1),
                  SizedBox(
                    height: (constraints.maxHeight * 0.4).clamp(0, 260),
                    child: _referencePanel(),
                  ),
                ],
              );
            },
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(error!, style: TextStyle(color: colors.danger)),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${paper.answeredCount} of ${paper.questions.length} answered',
                ),
                if (!paper.isSubmitted)
                  FilledButton(
                    onPressed: busy || paper.questions.isEmpty ? null : _submit,
                    child: Text(busy ? 'Grading…' : 'Grade now'),
                  ),
                // Two hops and a shake, every two seconds, until it is marked.
                if (grading)
                  const EtoniaMascot(
                    key: ValueKey<String>('study-grading-etonia'),
                    clip: EtoniaClip.grade,
                    height: 88,
                    semanticsLabel: 'Grading your test',
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _question(
    BuildContext context,
    TestQuestion question,
    int i,
    AppColors colors,
  ) {
    return Column(
      key: ValueKey('test-question-${question.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IgnorePointer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (i == 0) ...[
                if (paper.courseName.isNotEmpty)
                  Text(
                    paper.courseName,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                Text(
                  paper.title,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  '${paper.totalPoints} Pts | ${paper.questions.length} questions',
                ),
                const SizedBox(height: 12),
                AiAnswerMarkdown(paper.instructions),
                if (paper.isSubmitted)
                  Text(
                    'Grading Report | ${paper.totalScore ?? 0} / ${paper.totalPoints}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                const Divider(height: 40),
              ],
              Text(
                'Question ${i + 1} [${question.points} Pts]',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              AiAnswerMarkdown(question.prompt),
              if (question is TestFreeResponseQuestion)
                for (final part in question.subParts) AiAnswerMarkdown(part),
            ],
          ),
        ),
        if (i == 0 && paper.sourceSessionId != null)
          Align(
            key: _choiceKeys.putIfAbsent('source-${paper.id}', GlobalKey.new),
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('test-source-conversation'),
              onPressed:
                  busy || !widget.controller.hasSession(paper.sourceSessionId!)
                  ? null
                  : () => unawaited(_openSourceChat(paper.sourceSessionId!)),
              icon: const AppIcon(AppIcons.studyDesk, size: 18),
              label: Text(
                widget.controller.hasSession(paper.sourceSessionId!)
                    ? 'Open source conversation'
                    : 'Source conversation unavailable',
              ),
            ),
          ),
        if (question is TestMultipleChoiceQuestion)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              key: ValueKey('test-mcq-widget-${question.id}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in question.options)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Material(
                      key: _choiceKeys.putIfAbsent(
                        '${question.id}-${option.id}',
                        GlobalKey.new,
                      ),
                      color: question.selectedOptionId == option.id
                          ? colors.selected
                          : colors.surface,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedSuperellipseBorder(
                        borderRadius: AppBorderRadius.medium,
                        side: BorderSide(
                          color: question.selectedOptionId == option.id
                              ? colors.accent
                              : colors.divider,
                          width: AppSizes.hairline,
                        ),
                      ),
                      child: InkWell(
                        key: ValueKey(
                          'test-option-${question.id}-${option.id}',
                        ),
                        onTap: busy || paper.isSubmitted
                            ? null
                            : () {
                                final latest =
                                    paper.questions.firstWhere(
                                          (q) => q.id == question.id,
                                        )
                                        as TestMultipleChoiceQuestion;
                                _change(latest.copyWithSelected(option.id));
                                setState(() {});
                              },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              AppIcon(
                                question.selectedOptionId == option.id
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded,
                              ),
                              const SizedBox(width: 12),
                              Text('${option.id}. '),
                              Expanded(child: AiAnswerMarkdown(option.text)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _feedback(BuildContext context, TestQuestion question) {
    final evaluation = question is TestFreeResponseQuestion
        ? question.aiEvaluation
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (paper.isSubmitted) ...[
          if (question is TestMultipleChoiceQuestion)
            IgnorePointer(
              child: AiAnswerMarkdown(
                '${question.isCorrect ? "Correct" : "Incorrect"} | ${question.isCorrect ? question.points : 0}/${question.points} Pts\n\n${question.explanation}',
              ),
            ),
          if (evaluation != null) ...[
            IgnorePointer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${evaluation.awardedPoints} / ${evaluation.maxPoints} Pts',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  AiAnswerMarkdown(evaluation.feedback),
                  for (final step in evaluation.breakdown)
                    AiAnswerMarkdown(step),
                ],
              ),
            ),
            if (evaluation.recognizedMathOrText.isNotEmpty)
              Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  title: const Text('Recognized response'),
                  children: [AiAnswerMarkdown(evaluation.recognizedMathOrText)],
                ),
              ),
          ],
          if (question is TestFreeResponseQuestion)
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                title: const Text('Assessment criteria'),
                children: [
                  for (final item in question.rubric) AiAnswerMarkdown(item),
                ],
              ),
            ),
          if (question.sourceCitation != null)
            TextButton(
              onPressed: () => widget.onViewCitation(question.sourceCitation!),
              child: const Text('Review concept in notes'),
            ),
        ],
      ],
    );
  }
}
