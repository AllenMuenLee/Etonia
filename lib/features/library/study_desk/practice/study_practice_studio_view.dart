import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../app/theme/app_icons.dart';
import '../../../../app/theme/app_tokens.dart';
import '../../../../shared/navigation/app_sheets.dart';
import '../../../../shared/widgets/app_controls.dart';
import '../../../../shared/widgets/etonia_mark.dart';
import '../../../editor/ai/ai_client.dart';
import '../../../editor/document_io/document_platform.dart';
import '../../../editor/widgets/document_io_progress_dialog.dart';
import '../study_desk_controller.dart';
import '../study_desk_models.dart';
import '../study_motion.dart';
import '../study_source_tree.dart';
import '../study_material_sources.dart';
import 'study_material_library.dart';
import 'study_flashcard_player.dart';
import 'study_practice_generator.dart';
import 'study_practice_models.dart';
import 'study_test_pdf_exporter.dart';
import 'study_test_paper_player.dart';
import 'import_test_paper_sheet.dart';
import 'study_generate_test_sheet.dart';
import 'study_completed_test_pdf_exporter.dart';

/// What a player in the studio is doing with which set.

/// The Study Desk's other half: the decks made from the notes, and the way to
/// make, practise, print, and look after them.
class StudyPracticeStudioView extends StatefulWidget {
  const StudyPracticeStudioView({
    super.key,
    required this.controller,
    required this.onViewCitation,
    required this.onAddSources,
    this.showPlayerBackButton = true,
    this.onOpenPlans,
    this.exportSink = const SystemExportSink(),
    this.onOpenTestAsNote,
    this.onSaveTestToLibrary,
    this.exporter = const StudyTestPdfExporter(),
    this.temporaryDirectory = getTemporaryDirectory,
  });

  final StudyDeskController controller;

  /// Shows a citation on its note, in the desk's inspection pane.
  final ValueChanged<StudyCitation> onViewCitation;
  final VoidCallback onAddSources;
  final bool showPlayerBackButton;
  final VoidCallback? onOpenPlans;
  final ExportSink exportSink;

  /// Makes a note of a test's PDF, to write the answers on, and opens it.
  final Future<void> Function(Uint8List pdf, String title)? onOpenTestAsNote;
  final Future<void> Function(Uint8List pdf, String title)? onSaveTestToLibrary;
  final StudyTestPdfExporter exporter;
  final Future<Directory> Function() temporaryDirectory;

  @override
  State<StudyPracticeStudioView> createState() =>
      _StudyPracticeStudioViewState();
}

class _StudyPracticeStudioViewState extends State<StudyPracticeStudioView> {
  StudyDeskController get _controller => widget.controller;
  String? _savingPaperId;

  Future<void> _showSources(List<String> noteIds, String? sessionId) =>
      showAppSheet<void>(
        context: context,
        motionKey: 'study-material-sources',
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sources', style: Theme.of(context).textTheme.titleLarge),
                StudyMaterialSources(
                  controller: _controller,
                  noteIds: noteIds,
                  sourceSessionId: sessionId,
                  onOpenNote: (id) {
                    Navigator.of(sheetContext).pop();
                    widget.onViewCitation(
                      StudyCitation(
                        noteId: id,
                        pageIndex: 0,
                        revision: _controller.revisionOf(id),
                      ),
                    );
                  },
                  onOpenChat: (id) {
                    Navigator.of(sheetContext).pop();
                    _controller.openMaterialSourceChat(id);
                  },
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _savePaperToLibrary(StudyTestPaper paper) async {
    setState(() => _savingPaperId = paper.id);
    try {
      final bytes = await const StudyCompletedTestPdfExporter().export(paper);
      if (mounted) await widget.onSaveTestToLibrary?.call(bytes, paper.title);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not add this test to your library.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingPaperId = null);
    }
  }

  void _play(StudyPracticeSet set) {
    _controller.onPracticeBack = _onBack;
    _controller.openFlashcardSet(set);
  }

  void _stopPlaying() {
    _controller.onPracticeBack = null;
    _controller.closeFlashcardSet();
  }

  bool _onBack() {
    if (_controller.activeTestPaperId != null) {
      _controller.closeTestPaper();
      return true;
    }
    if (_controller.activeFlashcardSetId == null ||
        _controller.mode != StudyDeskMode.practice) {
      return false;
    }
    _stopPlaying();
    return true;
  }

  @override
  void dispose() {
    _controller.onPracticeBack = null;
    super.dispose();
  }

  Future<void> _generate() async {
    final StudyPracticeRequest? request =
        await showAppSheet<StudyPracticeRequest>(
          context: context,
          motionKey: 'study-generate',
          builder: (BuildContext context) =>
              StudyGenerateSheet(controller: _controller),
        );
    if (request == null || !mounted) return;
    unawaited(_controller.generatePracticeSet(request));
  }

  Future<void> _export(StudyPracticeSet set) async {
    final _TestExport? choice = await showAppSheet<_TestExport>(
      context: context,
      motionKey: 'study-export-test',
      builder: (BuildContext context) =>
          _ExportTestSheet(canOpenAsNote: widget.onOpenTestAsNote != null),
    );
    if (choice == null || !mounted) return;
    final Rect? origin = _shareOrigin();
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    Uint8List? bytes;
    File? file;
    bool cancelled = false;
    final DocumentIoProgressResult progress = await showDocumentIoProgress(
      context,
      title: 'Exporting test',
      onCancel: () => cancelled = true,
      operation: (_) async {
        bytes = await widget.exporter.export(
          set,
          options: choice.options,
          subject: _subjectOf(set),
          referenceOf: (StudyCitation citation) =>
              _controller.noteOf(citation.noteId)?.title,
        );
        if (choice.asNote) return;
        final Directory directory = await widget.temporaryDirectory();
        file = File('${directory.path}/${_fileNameOf(set.title)}.pdf');
        await file!.writeAsBytes(bytes!, flush: true);
      },
    );
    if (cancelled || progress.cancelled) return;
    try {
      if (progress.error != null) throw progress.error!;
      if (choice.asNote) {
        await widget.onOpenTestAsNote?.call(bytes!, set.title);
      } else {
        await widget.exportSink.share(file!, sharePositionOrigin: origin);
      }
    } on Object {
      messenger?.showSnackBar(
        const SnackBar(content: Text('This test could not be exported.')),
      );
    }
  }

  Rect? _shareOrigin() {
    final RenderObject? box = context.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
  }

  String _subjectOf(StudyPracticeSet set) => <String>[
    for (final String id in set.sourceNoteIds) ?_controller.noteOf(id)?.title,
  ].join(', ');

  static String _fileNameOf(String title) {
    final String clean = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return clean.isEmpty ? 'Test' : clean;
  }

  Future<void> _manage(StudyPracticeSet set) => showAppSheet<void>(
    context: context,
    motionKey: 'study-manage-set',
    builder: (BuildContext context) =>
        _ManageSetSheet(controller: _controller, setId: set.id),
  );

  void _onChanged(StudyPracticeSet set) =>
      unawaited(_controller.updatePracticeSet(set));

  @override
  Widget build(BuildContext context) {
    // Kept built behind the chat, it follows the controller only while it is
    // the one in view.
    return StudyScenedBuilder(
      listenable: _controller,
      builder: (BuildContext context) {
        final paper = _controller.testPapers
            .where((p) => p.id == _controller.activeTestPaperId)
            .firstOrNull;
        if (paper != null) {
          return _arrive(
            ('paper', paper.id),
            StudyTestPaperPlayer(
              key: ValueKey(paper.id),
              paper: paper,
              controller: _controller,
              onClose: _controller.closeTestPaper,
              showCloseButton: widget.showPlayerBackButton,
              onViewCitation: widget.onViewCitation,
              onSaveToLibrary: widget.onSaveTestToLibrary,
            ),
          );
        }
        _controller.onPracticeBack = _onBack;
        final String? id = _controller.activeFlashcardSetId;
        final StudyPracticeSet? set = id == null
            ? null
            : _controller.practiceSet(id);
        if (set != null) {
          return _arrive(
            ('deck', set.id),
            StudyFlashcardPlayer(
              key: ValueKey<String>('flashcards-$id'),
              set: set,
              labelOf: _controller.labelOf,
              onChanged: _onChanged,
              onViewCitation: widget.onViewCitation,
              onClose: _stopPlaying,
              showCloseButton: widget.showPlayerBackButton,
              clock: _controller.clock,
              onBrowseSources: () => unawaited(
                _showSources(set.sourceNoteIds, set.sourceSessionId),
              ),
            ),
          );
        }
        final failure = _controller.practiceFailure;
        return _arrive(
          (
            'library',
            _controller.practiceSection,
            _controller.selectedCourseId,
          ),
          StudyMaterialLibrary(
            decks:
                (_controller.browsingAllMaterials
                        ? _controller.practiceSets
                        : _controller.visiblePracticeSets)
                    .where((set) => set.flashcards.isNotEmpty)
                    .toList(),
            papers: _controller.browsingAllMaterials
                ? _controller.testPapers
                : _controller.visibleTestPapers,
            courseNames: {
              for (final course in _controller.courses) course.id: course.name,
            },
            groupByCourse: _controller.browsingAllMaterials,
            courseId: _controller.selectedCourseId,
            courseName: _controller.selectedCourse?.name,
            section: _controller.practiceSection,
            onSection: _controller.setPracticeSection,
            onGenerateFlashcards:
                _controller.isGeneratingPractice || _controller.allNotes.isEmpty
                ? null
                : () => unawaited(_generate()),
            onGenerateTest:
                _controller.isGeneratingTest || _controller.allNotes.isEmpty
                ? null
                : () => unawaited(_generateTest()),
            onImport: () => unawaited(_importPaper()),
            onOpenDeck: _play,
            onOpenPaper: (paper) => paper.isSubmitted
                ? _controller.openTestReview(paper)
                : _controller.openTestPaper(paper),
            onExportDeck: (set) => unawaited(_export(set)),
            onManageDeck: (set) => unawaited(_manage(set)),
            onSavePaper: widget.onSaveTestToLibrary == null
                ? null
                : (paper) => unawaited(_savePaperToLibrary(paper)),
            savingPaperId: _savingPaperId,
            sourceLabel: (ids) {
              final names = ids
                  .map((id) => _controller.noteOf(id)?.title)
                  .whereType<String>();
              return names.isEmpty
                  ? (_controller.browsingAllMaterials
                        ? 'Your library'
                        : _controller.selectedCourse?.name ?? 'Your library')
                  : names.join(', ');
            },
            onBrowseSources: (ids, sessionId) =>
                unawaited(_showSources(ids, sessionId)),
            status:
                failure == null &&
                    !_controller.isGeneratingPractice &&
                    !_controller.isGeneratingTest
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_controller.isGeneratingPractice ||
                          _controller.isGeneratingTest)
                        const _Generating(),
                      if (failure != null)
                        _GenerationFailure(
                          failure: failure,
                          onRetry: () => unawaited(
                            _controller.practiceSection ==
                                    PracticeStudioSection.tests
                                ? _generateTest()
                                : _controller.retryPracticeGeneration(),
                          ),
                          onDismiss: _controller.dismissPracticeFailure,
                          onOpenPlans:
                              failure.kind == AiFailureKind.planRequired ||
                                  failure.kind ==
                                      AiFailureKind.insufficientCredits
                              ? widget.onOpenPlans
                              : null,
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  /// What is opened plays in where it is, as the library does when it comes
  /// back: slowly the first time, as a glance after. Opening it is the only
  /// time anything is built for it, and closing it lets all of it go.
  Widget _arrive(Object scope, Widget child) => StudyAppear(
    playOnMount: false,
    replayKey: scope,
    memoryKey: ('study-practice', scope),
    child: child,
  );

  Future<void> _generateTest() => showAppSheet<void>(
    context: context,
    motionKey: 'study-generate-test',
    builder: (_) => StudyGenerateTestSheet(controller: _controller),
  );

  Future<void> _importPaper() async {
    final paper = await showAppSheet<StudyTestPaper>(
      context: context,
      motionKey: 'study-import-test',
      builder: (_) => const ImportTestPaperSheet(),
    );
    if (paper == null || !mounted) return;
    try {
      final assigned = paper.copyWith(
        courseId: _controller.browsingAllMaterials
            ? null
            : _controller.selectedCourseId,
      );
      await _controller.saveTestPaper(assigned);
      if (mounted) _controller.openTestPaper(assigned);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save the imported paper.')),
        );
      }
    }
  }
}

class _Generating extends StatelessWidget {
  const _Generating();

  @override
  Widget build(BuildContext context) {
    const String label = 'Writing your study set…';
    return Padding(
      key: const ValueKey<String>('practice-generating'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: <Widget>[
          const EtoniaBarsLoader(size: 24, semanticsLabel: label),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.of(context).textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GenerationFailure extends StatelessWidget {
  const _GenerationFailure({
    required this.failure,
    required this.onRetry,
    required this.onDismiss,
    this.onOpenPlans,
  });

  final AiFailure failure;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;
  final VoidCallback? onOpenPlans;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Padding(
      key: const ValueKey<String>('practice-failure'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Semantics(
        liveRegion: true,
        container: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: AppBorderRadius.medium,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  failure.message,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textPrimary),
                ),
                Wrap(
                  spacing: AppSpacing.xs,
                  children: <Widget>[
                    if (onOpenPlans != null)
                      TextButton(
                        onPressed: onOpenPlans,
                        child: const Text('Plans & Credits'),
                      )
                    else
                      TextButton(
                        onPressed: onRetry,
                        child: const Text('Try again'),
                      ),
                    TextButton(
                      onPressed: onDismiss,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Says what to generate: from which notes, of which kinds, how many, and how
/// hard. Pops with the [StudyPracticeRequest].
class StudyGenerateSheet extends StatefulWidget {
  const StudyGenerateSheet({super.key, required this.controller});

  final StudyDeskController controller;

  @override
  State<StudyGenerateSheet> createState() => _StudyGenerateSheetState();
}

class _StudyGenerateSheetState extends State<StudyGenerateSheet> {
  final TextEditingController _focus = TextEditingController();
  late final Set<String> _notes = <String>{
    ...widget.controller.initialPracticeNoteIds,
  };
  int _count = 10;
  PracticeDifficulty _difficulty = PracticeDifficulty.fundamentals;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Widget _chips<T>({
    required String keyPrefix,
    required List<T> options,
    required T selected,
    required String Function(T option) labelOf,
    required String Function(T option) keyOf,
    required ValueChanged<T> onSelected,
  }) {
    final AppColors colors = AppColors.of(context);
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xxs,
      children: <Widget>[
        for (final T option in options)
          ChoiceChip(
            key: ValueKey<String>('$keyPrefix-${keyOf(option)}'),
            label: Text(
              labelOf(option),
              style: TextStyle(
                color: option == selected
                    ? colors.onAccent
                    : colors.textPrimary,
              ),
            ),
            selected: option == selected,
            selectedColor: colors.accent,
            backgroundColor: colors.surfaceMuted,
            showCheckmark: false,
            onSelected: (bool _) => onSelected(option),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<StudySourceItem> sources = [
      for (final note in widget.controller.allNotes)
        StudySourceItem(noteId: note.id),
    ];
    return _SheetBody(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const ValueKey<String>('study-generate-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Semantics(
                header: true,
                child: Text(
                  'Generate Study Set',
                  style: text.titleLarge?.copyWith(color: colors.textPrimary),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const SectionLabel('Sources'),
                    StudySourceTree(
                      notes: widget.controller.allNotes.toList(),
                      folders: widget.controller.allFolders.toList(),
                      selected: _notes,
                      noteKeyPrefix: 'generate-source',
                      onSelectionChanged: (next) => setState(() {
                        _notes
                          ..clear()
                          ..addAll(next);
                      }),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const SectionLabel('Item Count'),
                    _chips<int>(
                      keyPrefix: 'generate-count',
                      options: StudyPracticeRequest.itemCounts,
                      selected: _count,
                      labelOf: (int n) => '$n',
                      keyOf: (int n) => '$n',
                      onSelected: (int n) => setState(() => _count = n),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const SectionLabel('Difficulty'),
                    _chips<PracticeDifficulty>(
                      keyPrefix: 'generate-difficulty',
                      options: PracticeDifficulty.values,
                      selected: _difficulty,
                      labelOf: (PracticeDifficulty d) => d.label,
                      keyOf: (PracticeDifficulty d) => d.name,
                      onSelected: (PracticeDifficulty d) =>
                          setState(() => _difficulty = d),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    const SectionLabel('Custom Focus'),
                    const SizedBox(height: AppSpacing.xxs),
                    TextField(
                      key: const ValueKey<String>('generate-focus'),
                      controller: _focus,
                      minLines: 1,
                      maxLines: 3,
                      maxLength: StudyPracticeRequest.maxFocusCharacters,
                      style: TextStyle(color: colors.textPrimary),
                      decoration: const InputDecoration(
                        hintText:
                            'Focus on diagram labels and formulas in Chapter 3',
                        hintMaxLines: 2,
                        counterText: '',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  FilledButton(
                    key: const ValueKey<String>('generate-submit'),
                    onPressed: _notes.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(
                            StudyPracticeRequest(
                              noteIds: <String>[
                                for (final StudySourceItem source in sources)
                                  if (_notes.contains(source.noteId))
                                    source.noteId,
                              ],
                              types: PracticeQuestionTypes.flashcards,
                              itemCount: _count,
                              difficulty: _difficulty,
                              focus: _focus.text,
                            ),
                          ),
                    child: const Text('Generate'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the export sheet was asked for.
class _TestExport {
  const _TestExport(this.options, {required this.asNote});

  final StudyTestOptions options;
  final bool asNote;
}

class _ExportTestSheet extends StatefulWidget {
  const _ExportTestSheet({required this.canOpenAsNote});

  final bool canOpenAsNote;

  @override
  State<_ExportTestSheet> createState() => _ExportTestSheetState();
}

class _ExportTestSheetState extends State<_ExportTestSheet> {
  StudyTestPaperSize _paper = StudyTestPaperSize.a4;
  StudyTestRuling _ruling = StudyTestRuling.ruled;
  StudyTestAnswerHeight _height = StudyTestAnswerHeight.medium;
  bool _key = true;
  bool _scratch = false;

  StudyTestOptions get _options => StudyTestOptions(
    paper: _paper,
    ruling: _ruling,
    answerHeight: _height,
    includeAnswerKey: _key,
    scratchMargin: _scratch,
  );

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    Widget menu<T>(
      String label,
      String keyName,
      List<T> options,
      T value,
      String Function(T) labelOf,
      ValueChanged<T> onChanged,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: DropdownButtonFormField<T>(
        key: ValueKey<String>(keyName),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        dropdownColor: colors.surface,
        items: <DropdownMenuItem<T>>[
          for (final T option in options)
            DropdownMenuItem<T>(
              value: option,
              child: Text(
                labelOf(option),
                style: TextStyle(color: colors.textPrimary),
              ),
            ),
        ],
        onChanged: (T? next) {
          if (next != null) onChanged(next);
        },
      ),
    );
    return _SheetBody(
      child: Column(
        key: const ValueKey<String>('study-export-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Semantics(
              header: true,
              child: Text(
                'Export Test PDF',
                style: text.titleLarge?.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  menu<StudyTestPaperSize>(
                    'Paper Size',
                    'export-paper',
                    StudyTestPaperSize.values,
                    _paper,
                    (StudyTestPaperSize p) => p.label,
                    (StudyTestPaperSize p) => setState(() => _paper = p),
                  ),
                  menu<StudyTestRuling>(
                    'Ruling Style',
                    'export-ruling',
                    StudyTestRuling.values,
                    _ruling,
                    (StudyTestRuling r) => r.label,
                    (StudyTestRuling r) => setState(() => _ruling = r),
                  ),
                  menu<StudyTestAnswerHeight>(
                    'Answer Space',
                    'export-height',
                    StudyTestAnswerHeight.values,
                    _height,
                    (StudyTestAnswerHeight h) => h.label,
                    (StudyTestAnswerHeight h) => setState(() => _height = h),
                  ),
                  ToggleSetting(
                    key: const ValueKey<String>('export-key'),
                    label: 'Include Answer Key on separate final page',
                    value: _key,
                    onChanged: (bool on) => setState(() => _key = on),
                  ),
                  ToggleSetting(
                    key: const ValueKey<String>('export-scratch'),
                    label: 'Scratch work margin beside questions',
                    value: _scratch,
                    onChanged: (bool on) => setState(() => _scratch = on),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const ValueKey<String>('export-share'),
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(_TestExport(_options, asNote: false)),
                  icon: const AppIcon(AppIcons.share, size: 18),
                  label: const Text('Share / Save PDF'),
                ),
                if (widget.canOpenAsNote)
                  FilledButton.icon(
                    key: const ValueKey<String>('export-as-note'),
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(_TestExport(_options, asNote: true)),
                    icon: const AppIcon(AppIcons.pen, size: 18),
                    label: const Text('Open as Handwritten Test Note'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Renames a set, takes items out of it, starts its progress over, or deletes
/// it.
class _ManageSetSheet extends StatefulWidget {
  const _ManageSetSheet({required this.controller, required this.setId});

  final StudyDeskController controller;
  final String setId;

  @override
  State<_ManageSetSheet> createState() => _ManageSetSheetState();
}

class _ManageSetSheetState extends State<_ManageSetSheet> {
  late final TextEditingController _title = TextEditingController(
    text: widget.controller.practiceSet(widget.setId)?.title ?? '',
  );

  StudyDeskController get _controller => widget.controller;

  @override
  void dispose() {
    final StudyPracticeSet? set = _controller.practiceSet(widget.setId);
    final String title = _title.text.trim();
    if (set != null && title.isNotEmpty && title != set.title) {
      // After this frame: the tree cannot be told of it while it is being
      // taken down.
      final StudyDeskController controller = _controller;
      final String id = widget.setId;
      scheduleMicrotask(() {
        final StudyPracticeSet? latest = controller.practiceSet(id);
        if (latest == null) return;
        unawaited(
          controller.updatePracticeSet(
            latest.copyWith(title: title, updatedAt: controller.clock()),
          ),
        );
      });
    }
    _title.dispose();
    super.dispose();
  }

  void _remove({
    required StudyPracticeSet set,
    PracticeFlashcard? card,
    PracticeMultipleChoice? question,
  }) {
    final StudyPracticeSet next = set.copyWith(
      updatedAt: _controller.clock(),
      flashcards: set.flashcards.where((c) => c.id != card?.id).toList(),
      multipleChoiceQuestions: set.multipleChoiceQuestions
          .where((q) => q.id != question?.id)
          .toList(),
    );
    unawaited(_controller.updatePracticeSet(next));
  }

  Future<void> _delete() async {
    final NavigatorState navigator = Navigator.of(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete this deck?'),
        content: const Text('Its cards, questions, and scores go with it.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('manage-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    unawaited(_controller.deletePracticeSet(widget.setId));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? _) {
        final StudyPracticeSet? set = _controller.practiceSet(widget.setId);
        if (set == null) return const SizedBox.shrink();
        return _SheetBody(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              key: const ValueKey<String>('study-manage-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.xs,
                  ),
                  child: TextField(
                    key: const ValueKey<String>('manage-title'),
                    controller: _title,
                    style: text.titleMedium?.copyWith(
                      color: colors.textPrimary,
                    ),
                    decoration: const InputDecoration(labelText: 'Deck Title'),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    children: <Widget>[
                      for (final PracticeFlashcard card in set.flashcards)
                        _ItemRow(
                          key: ValueKey<String>('manage-item-${card.id}'),
                          kind: 'Flashcard',
                          text: card.frontPrompt,
                          onRemove: () => _remove(set: set, card: card),
                        ),
                      for (final PracticeMultipleChoice question
                          in set.multipleChoiceQuestions)
                        _ItemRow(
                          key: ValueKey<String>('manage-item-${question.id}'),
                          kind: 'Question',
                          text: question.question,
                          onRemove: () => _remove(set: set, question: question),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: AppSpacing.xs,
                    children: <Widget>[
                      TextButton(
                        key: const ValueKey<String>('manage-delete'),
                        onPressed: () => unawaited(_delete()),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.danger,
                        ),
                        child: const Text('Delete Deck'),
                      ),
                      TextButton(
                        key: const ValueKey<String>('manage-reset'),
                        onPressed: () => unawaited(
                          _controller.updatePracticeSet(
                            set.reset(_controller.clock()),
                          ),
                        ),
                        child: const Text('Reset Progress'),
                      ),
                      FilledButton(
                        key: const ValueKey<String>('manage-done'),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What a sheet's content sits in. A sheet may be on glass, which rows and
/// chips cannot paint their ink on without a [Material] between.
class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: SafeArea(child: child),
  );
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.kind,
    required this.text,
    required this.onRemove,
  });

  final String kind;
  final String text;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.textPrimary),
      ),
      subtitle: Text(kind, style: TextStyle(color: colors.textSecondary)),
      trailing: IconButton(
        tooltip: 'Remove $kind',
        onPressed: onRemove,
        icon: AppIcon(AppIcons.delete, color: colors.textSecondary),
      ),
    );
  }
}
