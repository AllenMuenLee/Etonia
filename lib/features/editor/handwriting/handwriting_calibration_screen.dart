import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ink/ink_sample.dart';
import 'handwriting_calibration.dart';

/// Shows calibration and returns the profile it learned, or null when the
/// writer skipped before learning anything.
Future<HandwritingProfile?> showHandwritingCalibration(
  BuildContext context, {
  required HandwritingProfileStore store,
}) {
  return Navigator.of(context).push<HandwritingProfile?>(
    MaterialPageRoute<HandwritingProfile?>(
      fullscreenDialog: true,
      builder: (BuildContext context) =>
          HandwritingCalibrationScreen(store: store),
    ),
  );
}

/// Walks the writer through [calibrationChunks], one phrase on one ruled
/// line at a time, and learns their letters and words from what they write.
///
/// The text is known in advance, so nothing is sent to a recognizer: ink is
/// paired with its text by position alone.
class HandwritingCalibrationScreen extends StatefulWidget {
  const HandwritingCalibrationScreen({super.key, required this.store});

  final HandwritingProfileStore store;

  @override
  State<HandwritingCalibrationScreen> createState() =>
      _HandwritingCalibrationScreenState();
}

class _HandwritingCalibrationScreenState
    extends State<HandwritingCalibrationScreen> {
  int _step = 0;
  final List<List<InkVector>> _strokes = <List<InkVector>>[];
  HandwritingProfile _learned = HandwritingProfile();
  int _lettersLearned = 0;
  String? _problem;
  bool _saving = false;

  /// The pad's ruled line, measured during layout.
  double _capTop = 0;
  double _lineHeight = 0;

  CalibrationChunk get _chunk => calibrationChunks[_step];
  bool get _lastStep => _step == calibrationChunks.length - 1;

  void _next() {
    final CalibrationReading reading = readCalibration(
      _chunk,
      _strokes,
      capTop: _capTop,
      lineHeight: _lineHeight,
    );
    if (!reading.wordsMatched) {
      setState(() {
        _problem = reading.wordsFound < reading.wordsExpected
            ? 'I counted ${reading.wordsFound} of ${reading.wordsExpected} '
                  'words. Leave a little more room between them.'
            : 'I counted ${reading.wordsFound} words but expected '
                  '${reading.wordsExpected}. Keep each word together.';
      });
      return;
    }
    _learned = _learned.mergedWith(reading.profile);
    _lettersLearned += reading.lettersLearned;
    _advance();
  }

  void _advance() {
    if (_lastStep) {
      _finish(skipped: false);
      return;
    }
    setState(() {
      _step++;
      _strokes.clear();
      _problem = null;
    });
  }

  Future<void> _finish({required bool skipped}) async {
    if (_saving) return;
    setState(() => _saving = true);
    final HandwritingProfile? profile = _learned.isEmpty ? null : _learned;
    await widget.store.write(
      HandwritingCalibrationState(profile: profile, skipped: skipped),
    );
    if (profile != null) HandwritingCalibration.current.value = profile;
    if (mounted) Navigator.of(context).pop(profile);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: const Text('Teach Etonia your handwriting'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : () => _finish(skipped: true),
            child: Text(_learned.isEmpty ? 'Skip' : 'Save & stop'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              LinearProgressIndicator(
                value: _step / calibrationChunks.length,
                color: colors.accent,
                backgroundColor: colors.surfaceMuted,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                _step == 0
                    ? 'Copy each line in your everyday handwriting. '
                          'The AI will write its notes in your hand.'
                    : 'Line ${_step + 1} of ${calibrationChunks.length} · '
                          '$_lettersLearned letters learned so far',
                style: text.bodySmall!.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                _chunk.text,
                key: const ValueKey<String>('calibration-phrase'),
                textAlign: TextAlign.center,
                style: text.headlineSmall!.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Text(
                _chunk.quip,
                textAlign: TextAlign.center,
                style: text.bodyMedium!.copyWith(
                  color: colors.textSecondary,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // Sized so the phrase fits on one line at a natural
                  // letter width, as large as the screen allows.
                  _lineHeight =
                      (constraints.maxWidth / (_chunk.text.length * 0.62 + 1))
                          .clamp(28.0, 72.0);
                  final double padHeight = _lineHeight * 2.6;
                  _capTop = _lineHeight * 0.7;
                  return _WritingPad(
                    height: padHeight,
                    capTop: _capTop,
                    lineHeight: _lineHeight,
                    strokes: _strokes,
                    onChanged: () => setState(() => _problem = null),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              SizedBox(
                height: 40,
                child: _problem == null
                    ? null
                    : Text(
                        _problem!,
                        textAlign: TextAlign.center,
                        style: text.bodyMedium!.copyWith(color: colors.danger),
                      ),
              ),
              const Spacer(),
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(() {
                            _strokes.removeLast();
                            _problem = null;
                          }),
                    child: const Text('Undo'),
                  ),
                  TextButton(
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(() {
                            _strokes.clear();
                            _problem = null;
                          }),
                    child: const Text('Clear'),
                  ),
                  const Spacer(),
                  if (_problem != null)
                    TextButton(
                      onPressed: _saving ? null : _advance,
                      child: const Text('Skip line'),
                    ),
                  const SizedBox(width: AppSpacing.xs),
                  FilledButton(
                    onPressed: _strokes.isEmpty || _saving ? null : _next,
                    child: Text(_lastStep ? 'Finish' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A ruled line to write on: a capital line, a dotted middle line, and a
/// baseline. Any pointer writes, so a finger works where there is no pen.
class _WritingPad extends StatefulWidget {
  const _WritingPad({
    required this.height,
    required this.capTop,
    required this.lineHeight,
    required this.strokes,
    required this.onChanged,
  });

  final double height;
  final double capTop;
  final double lineHeight;

  /// Finished strokes; owned by the screen and added to here.
  final List<List<InkVector>> strokes;
  final VoidCallback onChanged;

  @override
  State<_WritingPad> createState() => _WritingPadState();
}

class _WritingPadState extends State<_WritingPad> {
  List<InkVector>? _active;
  int? _pointer;

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    setState(() => _active = <InkVector>[_vector(event.localPosition)]);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final InkVector point = _vector(event.localPosition);
    final List<InkVector> active = _active!;
    if ((point - active.last).length < 0.75) return;
    setState(() => active.add(point));
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    final List<InkVector> active = _active!;
    _pointer = null;
    _active = null;
    widget.strokes.add(active);
    widget.onChanged();
  }

  static InkVector _vector(Offset offset) => InkVector(offset.dx, offset.dy);

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      label: 'Writing area',
      child: Listener(
        key: const ValueKey<String>('calibration-pad'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: colors.writingSurface,
            borderRadius: BorderRadius.circular(AppRadii.small * 3),
            border: Border.all(color: colors.divider),
          ),
          child: CustomPaint(
            painter: _PadPainter(
              capTop: widget.capTop,
              lineHeight: widget.lineHeight,
              strokes: <List<InkVector>>[...widget.strokes, ?_active],
              rule: colors.pageRule,
              ink: colors.textPrimary,
              strokeWidth: math.max(2, widget.lineHeight / 22),
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter({
    required this.capTop,
    required this.lineHeight,
    required this.strokes,
    required this.rule,
    required this.ink,
    required this.strokeWidth,
  });

  final double capTop;
  final double lineHeight;
  final List<List<InkVector>> strokes;
  final Color rule;
  final Color ink;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint guide = Paint()
      ..color = rule
      ..strokeWidth = 1;
    final double baseline = capTop + lineHeight;
    final double middle = capTop + lineHeight * 0.45;
    void dashed(double y, double dash, double gap) {
      for (double x = 0; x < size.width; x += dash + gap) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + dash, size.width), y),
          guide,
        );
      }
    }

    dashed(capTop, 6, 6);
    dashed(middle, 2, 6);
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      guide..strokeWidth = 1.5,
    );

    final Paint pen = Paint()
      ..color = ink
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final List<InkVector> stroke in strokes) {
      if (stroke.length == 1) {
        canvas.drawCircle(
          Offset(stroke.first.x, stroke.first.y),
          strokeWidth / 2,
          Paint()..color = ink,
        );
        continue;
      }
      final Path path = Path()..moveTo(stroke.first.x, stroke.first.y);
      for (final InkVector point in stroke.skip(1)) {
        path.lineTo(point.x, point.y);
      }
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}
