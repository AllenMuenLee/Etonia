import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../app/theme/app_tokens.dart';
import '../../../editor/editor_screen.dart';
import '../../../editor/ink/ink_controller.dart';
import '../../../editor/ink/ink_painter.dart';
import '../../../editor/ink/stroke.dart';
import '../../../editor/ink/ink_sample.dart';
import '../../../editor/page/note_document.dart';
import '../../../editor/page/page_setup.dart';
import '../../../editor/widgets/toolbar_layout.dart';
import 'study_practice_models.dart';
import 'test_handwriting_canvas.dart';
import 'test_paper_surface.dart';

class TestPaperEditor extends StatefulWidget {
  const TestPaperEditor({
    super.key,
    required this.paper,
    required this.onInkChanged,
    required this.questionBuilder,
    required this.feedbackBuilder,
    required this.inputExclusions,
    required this.onError,
    this.readOnly = false,
  });

  final StudyTestPaper paper;
  final void Function(String id, Uint8List strokes) onInkChanged;
  final Widget Function(BuildContext context, int index) questionBuilder;
  final Widget Function(BuildContext context, int index) feedbackBuilder;
  final List<Rect> Function() inputExclusions;
  final ValueChanged<String> onError;
  final bool readOnly;

  @override
  State<TestPaperEditor> createState() => _TestPaperEditorState();
}

class _TestPaperEditorState extends State<TestPaperEditor> {
  static const _sheetSize = Size(760, 760 * 1123 / 794);
  final _tools = ValueNotifier<ToolbarLayout>(
    const ToolbarLayout(
      shown: [
        PaletteItem.pen,
        PaletteItem.eraser,
        PaletteItem.select,
        PaletteItem.ruler,
      ],
      folded: [],
    ),
  );
  late final NoteDocument _document;
  final Map<NotePage, VoidCallback> _listeners = {};
  final Map<String, Offset> _legacyOffsets = {};
  final Map<String, Size> _answerSizes = {};

  @override
  void initState() {
    super.initState();
    _document = NoteDocument(
      pages: [
        for (final question in widget.paper.questions) _makePage(question),
      ],
    );
    for (var i = 0; i < widget.paper.questions.length; i++) {
      final index = i;
      final page = _document.pages[index];
      void save() {
        if (widget.readOnly) return;
        widget.onInkChanged(
          widget.paper.questions[index].id,
          page.ink.strokes.isEmpty
              ? Uint8List.fromList([91, 93])
              : encodeTestPageInk(page.ink.strokes, page.setup.customSize!),
        );
      }

      _listeners[page] = save;
      page.ink.documentRevisionListenable.addListener(save);
      final question = widget.paper.questions[index];
      if (question is TestFreeResponseQuestion &&
          question.backgroundImagePath != null) {
        _sizeImportedPage(page, question.backgroundImagePath!);
      }
    }
  }

  NotePage _makePage(TestQuestion question) {
    final imported =
        question is TestFreeResponseQuestion &&
        question.backgroundImagePath != null;
    final savedSize = testInkPageSize(question.handwritingStrokes);
    _answerSizes[question.id] = savedSize ?? _sheetSize;
    final offset = !imported && savedSize == null
        ? const Offset(0, 560)
        : Offset.zero;
    _legacyOffsets[question.id] = offset;
    return NotePage(
      setup: PageSetup(
        size: PageSize.custom,
        customSize: savedSize ?? _sheetSize,
      ),
      ink: InkController(
        strokes: [
          for (final stroke in decodeTestInk(question.handwritingStrokes))
            offset == Offset.zero
                ? stroke
                : stroke.translated(InkVector(offset.dx, offset.dy)),
        ],
      ),
    );
  }

  Future<void> _sizeImportedPage(NotePage page, String path) async {
    try {
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
        targetWidth: 760,
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          if (!mounted) return;
          page.setup = page.setup.copyWith(
            customSize: Size(760, 760 * image.height / image.width),
          );
          _answerSizes[widget
                  .paper
                  .questions[_document.pages.indexOf(page)]
                  .id] =
              page.setup.customSize!;
          _document.notifyListeners();
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } on Object {
      if (mounted) {
        widget.onError('The imported test page could not be loaded.');
      }
    }
  }

  void _contentHeight(int index, double height) {
    if (!mounted) return;
    final page = _document.pages[index];
    final oldSize = page.setup.customSize!;
    final nextHeight = math.max(_sheetSize.height, height + 520);
    if (nextHeight <= oldSize.height + 1) return;
    page.setup = page.setup.copyWith(
      customSize: Size(oldSize.width, nextHeight),
    );
    if (!widget.paper.isSubmitted) {
      _answerSizes[widget.paper.questions[index].id] = page.setup.customSize!;
    }
    _document.notifyListeners();
  }

  void _feedbackHeight(int index, double height) {
    if (!mounted) return;
    final page = _document.pages[index];
    final size = _answerSizes[widget.paper.questions[index].id]!;
    final nextSize = Size(size.width, size.height + height);
    if (page.setup.customSize == nextSize) return;
    page.setup = page.setup.copyWith(customSize: nextSize);
    _document.notifyListeners();
  }

  @override
  void didUpdateWidget(TestPaperEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.readOnly && !oldWidget.readOnly) {
      for (final page in _document.pages) {
        page.ink.finalizeActiveGesture();
        page.ink.clearSelection();
      }
    }
  }

  @override
  void dispose() {
    for (final entry in _listeners.entries) {
      entry.key.ink.documentRevisionListenable.removeListener(entry.value);
    }
    _document.dispose();
    _tools.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TestPaperSurface(
    child: EditorScreen(
      key: const ValueKey('test-paper-canvas'),
      document: _document,
      title: widget.paper.title,
      toolbarLayout: _tools,
      readOnly: widget.readOnly,
      allowPageManagement: false,
      showAppBar: false,
      inputExclusions: widget.inputExclusions,
      pageUnderlayBuilder: (context, index) {
        if (index >= widget.paper.questions.length) {
          return const SizedBox.shrink();
        }
        final question = widget.paper.questions[index];
        if (question is TestFreeResponseQuestion &&
            question.backgroundImagePath != null) {
          return IgnorePointer(
            child: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: _answerSizes[question.id]!.width,
                height: _answerSizes[question.id]!.height,
                child: Image.file(
                  File(question.backgroundImagePath!),
                  fit: BoxFit.fill,
                ),
              ),
            ),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            fit: OverflowBoxFit.deferToChild,
            child: _ContentExtent(
              onHeight: (height) => _contentHeight(index, height),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(36, 160, 36, 36),
                child: widget.questionBuilder(context, index),
              ),
            ),
          ),
        );
      },
      pageOverlayBuilder: (context, index) {
        if (index >= widget.paper.questions.length) {
          return const SizedBox.shrink();
        }
        final question = widget.paper.questions[index];
        final evaluation = question is TestFreeResponseQuestion
            ? question.aiEvaluation
            : null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (widget.paper.isSubmitted)
              Positioned(
                left: 0,
                right: 0,
                top: _answerSizes[question.id]!.height,
                child: _ContentExtent(
                  onHeight: (height) => _feedbackHeight(index, height),
                  child: Padding(
                    padding: const EdgeInsets.all(36),
                    child: widget.feedbackBuilder(context, index),
                  ),
                ),
              ),
            if (evaluation != null)
              IgnorePointer(
                child: CustomPaint(
                  key: ValueKey('test-marking-${question.id}'),
                  painter: _MarkingPainter(
                    decodeTestInk(evaluation.markingStrokes),
                    evaluation.annotations,
                    testInkPageSize(question.handwritingStrokes) == null
                        ? _legacyOffsets[question.id] ?? Offset.zero
                        : Offset.zero,
                    _answerSizes[question.id]!,
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _ContentExtent extends SingleChildRenderObjectWidget {
  const _ContentExtent({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ContentExtentBox(onHeight);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ContentExtentBox renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _ContentExtentBox extends RenderProxyBox {
  _ContentExtentBox(this.onHeight);
  ValueChanged<double> onHeight;
  double? _previous;
  @override
  void performLayout() {
    super.performLayout();
    if (_previous == size.height) return;
    _previous = size.height;
    final height = size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}

class _MarkingPainter extends CustomPainter {
  const _MarkingPainter(
    this.strokes,
    this.annotations,
    this.offset,
    this.answerSize,
  );
  final List<Stroke> strokes;
  final List<TestAiAnnotation> annotations;
  final Offset offset;
  final Size answerSize;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    for (final stroke in strokes) {
      paintInkStroke(
        canvas,
        color: stroke.style.resolve(Brightness.light),
        width: stroke.style.width,
        path: stroke.path,
        origin: stroke.points.first,
        isDot: stroke.isDot,
        outline: stroke.outline,
        writing: stroke.style.writing,
      );
    }
    for (var i = 0; i < annotations.length; i++) {
      final mark = annotations[i];
      final point = Offset(
        mark.x * answerSize.width,
        mark.y * (offset == Offset.zero ? answerSize.height : 360),
      );
      canvas.drawCircle(
        point,
        12,
        Paint()
          ..color = mark.isCorrect
              ? AppColors.light.success
              : AppColors.light.danger,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, point - Offset(text.width / 2, text.height / 2));
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkingPainter oldDelegate) => true;
}
