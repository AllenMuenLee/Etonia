import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import '../../../../app/theme/app_tokens.dart';

import '../../../editor/ink/ink_controller.dart';
import '../../../editor/ink/ink_painter.dart';
import '../../../editor/ink/stroke.dart';
import '../../../editor/page/note_document.dart';
import '../../../editor/page/page_background.dart';
import '../../../editor/page/page_setup.dart';
import '../../../editor/page/page_viewport.dart';
import '../../../editor/widgets/writing_surface_frame.dart';
import '../../note_content.dart';
import '../study_in_situ_editor.dart';
import '../study_in_situ_toolbar.dart';
import 'study_practice_models.dart';

Object? _testInkJson(Uint8List? bytes) =>
    bytes == null ? null : jsonDecode(utf8.decode(bytes));

List<Stroke> decodeTestInk(Uint8List? bytes) {
  final value = _testInkJson(bytes);
  final strokes = value is Map ? value['strokes'] : value;
  return [
    if (strokes is List)
      for (final raw in strokes) ?StoredPage.strokeFromJson(raw),
  ];
}

Size? testInkPageSize(Uint8List? bytes) {
  final value = _testInkJson(bytes);
  if (value is! Map) return null;
  final width = value['width'];
  final height = value['height'];
  if (width is! num ||
      height is! num ||
      !width.isFinite ||
      !height.isFinite ||
      width <= 0 ||
      height <= 0) {
    return null;
  }
  return Size(width.toDouble(), height.toDouble());
}

Uint8List encodeTestPageInk(Iterable<Stroke> strokes, Size size) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'width': size.width,
          'height': size.height,
          'strokes': strokes.map(StoredPage.strokeToJson).toList(),
        }),
      ),
    );

Future<Uint8List> renderTestAnswer(
  Uint8List? ink, {
  String? backgroundPath,
  Uint8List? markingStrokes,
  List<TestAiAnnotation> annotations = const [],
}) async {
  final pageSize = testInkPageSize(ink);
  final width = pageSize?.width.ceil() ?? 760;
  double height = pageSize?.height ?? 360;
  ui.Image? background;
  if (backgroundPath != null) {
    final codec = await ui.instantiateImageCodec(
      await File(backgroundPath).readAsBytes(),
      targetWidth: width,
    );
    try {
      background = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    height = pageSize?.height ?? width * background.height / background.width;
  }
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height),
      ui.Paint()..color = Colors.white,
    );
  if (background != null) {
    canvas.drawImageRect(
      background,
      ui.Rect.fromLTWH(
        0,
        0,
        background.width.toDouble(),
        background.height.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height),
      ui.Paint(),
    );
  }
  for (final stroke in [
    ...decodeTestInk(ink),
    ...decodeTestInk(markingStrokes),
  ]) {
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
    final annotation = annotations[i];
    final position = Offset(
      (annotation.x * width).clamp(14, width - 14).toDouble(),
      (annotation.y * height).clamp(14, height - 14).toDouble(),
    );
    canvas.drawCircle(
      position,
      12,
      Paint()
        ..color = (annotation.isCorrect
            ? AppColors.light.success
            : AppColors.light.danger),
    );
    final label = TextPainter(
      text: TextSpan(
        text: '${i + 1}',
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, position - Offset(label.width / 2, label.height / 2));
    label.dispose();
  }
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height.ceil());
    try {
      return (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
    background?.dispose();
  }
}

class TestHandwritingCanvas extends StatefulWidget {
  const TestHandwritingCanvas({
    super.key,
    this.strokes,
    required this.onChanged,
    this.readOnly = false,
    this.backgroundPath,
    this.aspectRatio = 760 / 360,
    this.annotations = const [],
    this.markingStrokes,
    this.showTools = true,
    this.autofocus = false,
    this.onActivate,
    this.toolSettings,
  });
  final Uint8List? strokes;
  final ValueChanged<Uint8List> onChanged;
  final bool readOnly;
  final String? backgroundPath;
  final double aspectRatio;
  final List<TestAiAnnotation> annotations;
  final Uint8List? markingStrokes;
  final bool showTools;
  final bool autofocus;
  final ValueChanged<TestCanvasEditingSession>? onActivate;
  final TestCanvasEditingSession? toolSettings;
  @override
  State<TestHandwritingCanvas> createState() => _TestHandwritingCanvasState();
}

class TestCanvasEditingSession {
  const TestCanvasEditingSession({
    required this.session,
    required this.stylusOnly,
    required this.background,
  });
  final StudyInSituSession session;
  final ValueNotifier<bool> stylusOnly;
  final ValueNotifier<PageBackground> background;
}

class _TestHandwritingCanvasState extends State<TestHandwritingCanvas>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => !widget.showTools;
  late final document = NoteDocument(
    pages: [
      NotePage(ink: InkController(strokes: decodeTestInk(widget.strokes))),
    ],
  );
  late final session = StudyInSituSession(document: document);
  final stylusOnly = ValueNotifier<bool>(true);
  final background = ValueNotifier<PageBackground>(PageBackground.lined);
  late final editingSession = TestCanvasEditingSession(
    session: session,
    stylusOnly: stylusOnly,
    background: background,
  );
  bool _navigating = false;
  @override
  void initState() {
    super.initState();
    session.ink.documentRevisionListenable.addListener(_save);
    background.addListener(_backgroundChanged);
    _listenToTools(widget.toolSettings, add: true);
    _copyTools();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onActivate?.call(editingSession);
      });
    }
  }

  void _listenToTools(TestCanvasEditingSession? source, {required bool add}) {
    if (source == null || identical(source.session, session)) return;
    for (final notifier in <Listenable>[
      source.session.tool,
      source.session.pen,
      source.session.eraser,
      source.stylusOnly,
      source.background,
    ]) {
      if (add) {
        notifier.addListener(_copyTools);
      } else {
        notifier.removeListener(_copyTools);
      }
    }
  }

  void _copyTools() {
    final source = widget.toolSettings;
    if (source == null || identical(source.session, session)) return;
    session.tool.value = source.session.tool.value;
    session.pen.value = source.session.pen.value;
    session.eraser.value = source.session.eraser.value;
    stylusOnly.value = source.stylusOnly.value;
    background.value = source.background.value;
  }

  void _backgroundChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(TestHandwritingCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.toolSettings != widget.toolSettings) {
      _listenToTools(oldWidget.toolSettings, add: false);
      _listenToTools(widget.toolSettings, add: true);
      _copyTools();
    }
  }

  void _save() {
    widget.onChanged(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(session.ink.strokes.map(StoredPage.strokeToJson).toList()),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _listenToTools(widget.toolSettings, add: false);
    session.ink.documentRevisionListenable.removeListener(_save);
    session.dispose();
    document.dispose();
    stylusOnly.dispose();
    background.removeListener(_backgroundChanged);
    background.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        if (!widget.readOnly && widget.showTools) ...[
          StudyInSituToolbar(session: session),
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: stylusOnly,
                builder: (context, value, _) => FilterChip(
                  label: const Text('Stylus only'),
                  selected: value,
                  onSelected: (v) => stylusOnly.value = v,
                ),
              ),
              if (widget.backgroundPath == null)
                DropdownButton<PageBackground>(
                  value: background.value,
                  items: [
                    for (final r in PageBackground.values)
                      DropdownMenuItem(value: r, child: Text(r.label)),
                  ],
                  onChanged: (v) => background.value = v!,
                ),
            ],
          ),
        ],
        Listener(
          onPointerDown: widget.readOnly
              ? null
              : (_) => widget.onActivate?.call(editingSession),
          child: AspectRatio(
            aspectRatio: widget.aspectRatio,
            child: LayoutBuilder(
              builder: (context, constraints) => PageViewport(
                pages: [
                  PageGeometry(
                    Size(760, 760 / widget.aspectRatio),
                    constraints.maxWidth / 760,
                  ),
                ],
                pageKeys: const [ValueKey('test-answer-page')],
                currentPage: 0,
                pageGap: 0,
                fingersNavigate: stylusOnly,
                onScrollStart: (_) => _navigating = true,
                onScrollEnd: () => _navigating = false,
                pageBuilder: (context, _, visible) => Theme(
                  data: Theme.of(context).copyWith(
                    brightness: Brightness.light,
                    extensions: const [AppColors.light],
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      WritingSurfaceFrame(
                        child: widget.backgroundPath != null
                            ? Image.file(
                                File(widget.backgroundPath!),
                                fit: BoxFit.fill,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Text('Page could not be loaded.'),
                                ),
                              )
                            : PageBackgroundLayer(background: background.value),
                      ),
                      IgnorePointer(
                        ignoring: widget.readOnly,
                        // Exam paper stays white in either app theme. Resolve ink
                        // with the same brightness used by grading and export.
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            brightness: Brightness.light,
                            extensions: const [AppColors.light],
                          ),
                          child: StudyInSituCanvas(
                            session: session,
                            isNavigating: () => widget.readOnly || _navigating,
                            stylusOnly: stylusOnly,
                            visible: visible,
                          ),
                        ),
                      ),
                      if (widget.markingStrokes != null)
                        IgnorePointer(
                          child: CustomPaint(
                            painter: _TestMarkingPainter(
                              decodeTestInk(widget.markingStrokes),
                            ),
                          ),
                        ),
                      for (final annotation in widget.annotations)
                        Positioned(
                          left: (annotation.x * 760 - 14)
                              .clamp(0, 732)
                              .toDouble(),
                          top: (annotation.y * (760 / widget.aspectRatio) - 14)
                              .clamp(0, 760 / widget.aspectRatio - 28)
                              .toDouble(),
                          child: Tooltip(
                            message: annotation.label,
                            triggerMode: TooltipTriggerMode.tap,
                            child: Semantics(
                              label: annotation.label,
                              child: Icon(
                                annotation.isCorrect
                                    ? Icons.check_circle
                                    : Icons.error,
                                color: annotation.isCorrect
                                    ? AppColors.light.success
                                    : AppColors.light.danger,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TestMarkingPainter extends CustomPainter {
  const _TestMarkingPainter(this.strokes);
  final List<Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
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
  }

  @override
  bool shouldRepaint(_TestMarkingPainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}

@Preview(name: 'Test response canvas', size: Size(700, 520))
Widget testCanvasPreview() => MaterialApp(
  theme: ThemeData.light().copyWith(extensions: const [AppColors.light]),
  home: const Scaffold(body: TestHandwritingCanvas(onChanged: _previewInk)),
);
void _previewInk(Uint8List _) {}
