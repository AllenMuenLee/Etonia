import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/navigation/app_page_route.dart';
import '../ai/notation_font.dart';
import '../ink/ink_sample.dart';
import '../widgets/eraser_options.dart';
import 'handwriting_calibration.dart';
import 'handwriting_fonts.dart';
import 'handwriting_style.dart';

/// Shows calibration and returns the hand chosen, or null when the writer
/// left without choosing one.
Future<HandwritingStyle?> showHandwritingCalibration(
  BuildContext context, {
  required HandwritingProfileStore store,
}) {
  return Navigator.of(context).push<HandwritingStyle?>(
    AppPageRoute<HandwritingStyle?>(
      fullscreenDialog: true,
      motionKey: 'handwriting-calibration',
      builder: (BuildContext context) =>
          HandwritingCalibrationScreen(store: store),
    ),
  );
}

/// Rules a pad of [size] into a box for each letter of [rows]: as large as
/// the width allows, small enough that every row fits the height, and
/// centred.
@visibleForTesting
CalibrationRuling calibrationRuling(Size size, List<String> rows) {
  const double cell = calibrationCell;
  // 1.3 above the first baseline, the gap between rows, 0.9 below the last.
  final double height = 1.3 + calibrationRowGap * (rows.length - 1) + 0.9;
  final int columns = rows.map((String row) => row.length).reduce(math.max);
  final double lineHeight = math.min(
    (size.width / (columns * cell + 0.3)).clamp(22.0, 96.0),
    size.height / height,
  );
  final double cellWidth = lineHeight * cell;
  final double top = (size.height - lineHeight * height) / 2;
  return (
    baselines: <double>[
      for (int i = 0; i < rows.length; i++)
        top + lineHeight * (1.3 + i * calibrationRowGap),
    ],
    lineHeight: lineHeight,
    left: (size.width - cellWidth * columns) / 2,
    cellWidth: cellWidth,
  );
}

/// What each font's card writes.
const String _sampleText = 'Quick notes, jumpy gigs';

/// What each page of [customFontPages] asks for.
const List<String> _pageTitles = <String>[
  'Key letters',
  'More small letters',
  'More capitals',
  'Digits',
];

/// What each page of [customFontPages] asks the writer to do.
const List<String> _pageHints = <String>[
  'Write each letter once in its box with your pen, the way you usually '
      'write it. The rest of the alphabet is built from these.',
  'Write any of these you like; the rest are built from your key letters.',
  'Write any of these you like; the rest are built from your key letters.',
  'Write any digits you like; the rest are written in Etonia\'s hand, '
      'shaped like your letters.',
];

enum _Stage { choosing, writing, finished }

/// Lets the writer choose the hand the AI writes their notes in: one of
/// five [HandwritingFont]s, or their own, made by writing the key letters
/// once, each in a box of its own, and any others they like.
///
/// Each box holds a known letter, so nothing is sent to a recognizer: ink
/// is paired with its letter by position alone.
class HandwritingCalibrationScreen extends StatefulWidget {
  const HandwritingCalibrationScreen({super.key, required this.store});

  final HandwritingProfileStore store;

  @override
  State<HandwritingCalibrationScreen> createState() =>
      _HandwritingCalibrationScreenState();
}

class _HandwritingCalibrationScreenState
    extends State<HandwritingCalibrationScreen> {
  _Stage _stage = _Stage.choosing;

  /// What was saved before, whose other choices are kept.
  HandwritingCalibrationState? _saved;

  /// The font chosen on the cards.
  HandwritingFont _font = HandwritingFont.normal;

  /// The writer's own font, as saved before or as just made.
  HandwritingStyle? _custom;

  /// Which page of [customFontPages] is on the pad.
  int _page = 0;

  /// What is written on each page, in ruled units ([CalibrationDraft]), so
  /// it stays on its lines when the pad changes size.
  final List<List<List<InkVector>>> _pages = <List<List<InkVector>>>[
    for (int i = 0; i < customFontPages.length; i++) <List<InkVector>>[],
  ];

  /// Earlier versions of each page, for undo.
  final List<List<List<List<InkVector>>>> _histories =
      <List<List<List<InkVector>>>>[
        for (int i = 0; i < customFontPages.length; i++)
          <List<List<InkVector>>>[],
      ];

  /// Whether the pen tip erases; the pen's eraser end always does.
  bool _eraserTool = false;
  bool _erasedThisGesture = false;

  /// The font just made from the pages, kept once the writer is done.
  HandwritingStyle? _made;
  String? _problem;
  bool _saving = false;

  /// The pad's boxes, measured during layout.
  CalibrationRuling _ruling = (
    baselines: const <double>[0],
    lineHeight: 1,
    left: 0,
    cellWidth: 1,
  );

  List<List<InkVector>> get _strokes => _pages[_page];
  List<List<List<InkVector>>> get _history => _histories[_page];
  List<String> get _rows => customFontPages[_page];

  @override
  void initState() {
    super.initState();
    widget.store.read().then((HandwritingCalibrationState? state) {
      if (!mounted || state == null) return;
      _saved = state;
      setState(() {
        if (state.font != null) _font = state.font!;
        if (state.font == HandwritingFont.custom) _custom = state.style;
      });
    });
    widget.store.readDraft().then((List<List<List<InkVector>>> draft) {
      if (!mounted || _pages.any((List<List<InkVector>> p) => p.isNotEmpty)) {
        return;
      }
      setState(() {
        for (int i = 0; i < draft.length && i < _pages.length; i++) {
          _pages[i].addAll(draft[i]);
        }
      });
    });
  }

  List<List<InkVector>> _onPad(List<List<InkVector>> ruled) =>
      CalibrationDraft.decode(ruled, ruling: _ruling);

  List<InkVector> _ruled(List<InkVector> stroke) => CalibrationDraft.encode(
    <List<InkVector>>[stroke],
    ruling: _ruling,
  ).single;

  /// Records the page before a change, so Undo can bring it back.
  void _remember() => _history.add(List<List<InkVector>>.of(_strokes));

  /// Keeps what is written on the device, so leaving calibration, or the
  /// app closing, does not lose it.
  void _keepDraft() => widget.store.writeDraft(_pages);

  void _changed(VoidCallback change) {
    setState(() {
      change();
      _problem = null;
    });
    _keepDraft();
  }

  void _addStroke(List<InkVector> stroke) => _changed(() {
    _remember();
    _strokes.add(_ruled(stroke));
  });

  void _eraseStart() => _erasedThisGesture = false;

  /// Removes every stroke within reach of the eraser at [point], on the
  /// pad.
  void _eraseAt(InkVector point) {
    final InkVector at = _ruled(<InkVector>[point]).single;
    const double reach = 0.3; // Line heights.
    final List<List<InkVector>> hit = <List<InkVector>>[
      for (final List<InkVector> stroke in _strokes)
        if (_distanceToStroke(at, stroke) <= reach) stroke,
    ];
    if (hit.isEmpty) return;
    setState(() {
      if (!_erasedThisGesture) _remember();
      _erasedThisGesture = true;
      _strokes.removeWhere(hit.contains);
      _problem = null;
    });
  }

  void _eraseEnd() {
    if (_erasedThisGesture) _keepDraft();
  }

  void _undo() => _changed(() {
    _strokes
      ..clear()
      ..addAll(_history.removeLast());
  });

  void _clear() => _changed(() {
    _remember();
    _strokes.clear();
  });

  void _choose(HandwritingFont font) {
    if (font == HandwritingFont.custom && _custom == null) {
      _writeOwn();
      return;
    }
    setState(() => _font = font);
  }

  /// To the pad, to write the key letters of the writer's own font.
  void _writeOwn() => setState(() {
    _stage = _Stage.writing;
    _page = 0;
    _problem = null;
  });

  /// Back a page, or from the first back to the fonts.
  void _back() => setState(() {
    _problem = null;
    if (_page == 0) {
      _stage = _Stage.choosing;
    } else {
      _page--;
    }
  });

  /// Once every key letter is written, to what the letters make; from a
  /// page of letters that may be written, on to the next, or from the
  /// last, to what they make.
  void _next() {
    final List<String> missing = missingLetters(_page, _strokes);
    if (missing.isNotEmpty && !customFontPageOptional(_page)) {
      setState(() => _problem = _askFor(missing));
      return;
    }
    if (_page > 0 && _page < customFontPages.length - 1) {
      setState(() {
        _page++;
        _problem = null;
      });
      return;
    }
    _make();
  }

  /// To what the letters written make.
  void _make() {
    final CalibrationReading reading = readCustomFont(_pages);
    if (!reading.complete) {
      // Only a page already passed can be missing letters.
      setState(() {
        _page = customFontPages.indexWhere(
          (List<String> rows) => rows.join().contains(reading.missing.first),
        );
        _problem = _askFor(reading.missing);
      });
      return;
    }
    setState(() {
      _made = reading.style;
      _stage = _Stage.finished;
    });
  }

  /// Back to the pad with the letters still on it, to fix what was off.
  void _tryAgain() => setState(() {
    _made = null;
    _stage = _Stage.writing;
  });

  Future<void> _finish(HandwritingStyle? style, HandwritingFont? font) async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.store.write(
      (_saved ?? const HandwritingCalibrationState()).withStyle(style, font),
    );
    // Letters written out are kept until they make a font, or the writer
    // chooses another.
    if (style == null || font != HandwritingFont.custom || _made != null) {
      await widget.store.writeDraft(const <List<List<InkVector>>>[]);
    }
    if (style != null) HandwritingCalibration.current.value = style;
    if (mounted) Navigator.of(context).pop(style);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        title: Text(
          _stage == _Stage.choosing
              ? 'Choose the AI\'s handwriting'
              : 'Make your own handwriting',
        ),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : () => _finish(null, null),
            child: const Text('Skip'),
          ),
        ],
      ),
      // The pad takes whatever height is left, so nothing scrolls under
      // the pen.
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: switch (_stage) {
            _Stage.choosing => _buildChoosing(context),
            _Stage.writing => _buildWriting(context),
            _Stage.finished => _buildFinished(context, _made!),
          },
        ),
      ),
    );
  }

  Widget _buildChoosing(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final HandwritingStyle? chosen = _font == HandwritingFont.custom
        ? _custom
        : _font.style;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Choose how the AI writes on your notes, or write 15 letters to '
          'make it write like you.',
          style: text.bodyMedium!.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final int columns = constraints.maxWidth >= 840
                  ? 3
                  : constraints.maxWidth >= 520
                  ? 2
                  : 1;
              return GridView.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpacing.sm,
                  crossAxisSpacing: AppSpacing.sm,
                  mainAxisExtent: 148,
                ),
                itemCount: HandwritingFont.values.length,
                itemBuilder: (BuildContext context, int index) {
                  final HandwritingFont font = HandwritingFont.values[index];
                  return _FontCard(
                    font: font,
                    style: font == HandwritingFont.custom
                        ? _custom
                        : font.style,
                    selected:
                        font == _font &&
                        (font != HandwritingFont.custom || _custom != null),
                    onTap: _saving ? null : () => _choose(font),
                    onRewrite: font == HandwritingFont.custom && _custom != null
                        ? _writeOwn
                        : null,
                  );
                },
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: <Widget>[
            const Spacer(),
            FilledButton(
              key: const ValueKey<String>('calibration-use-font'),
              onPressed: chosen == null || _saving
                  ? null
                  : () => _finish(chosen, _font),
              child: const Text('Use this handwriting'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWriting(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool last = _page == customFontPages.length - 1;
    final bool done = _page == 0 || last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${_pageTitles[_page]}${customFontPageOptional(_page) ? ' (optional)' : ''}'
                ' · ${_page + 1} of ${customFontPages.length}',
                style: text.titleSmall!.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Up here, where a phone has room for it beside the title.
            if (!done)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _saving ? null : _make,
                child: const Text('Finish'),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxs),
        Text(
          _pageHints[_page],
          style: text.bodySmall!.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              _ruling = calibrationRuling(constraints.biggest, _rows);
              return _WritingPad(
                key: ValueKey<int>(_page),
                height: constraints.maxHeight,
                ruling: _ruling,
                rows: _rows,
                strokes: _onPad(_strokes),
                eraserTool: _eraserTool,
                onStroke: _addStroke,
                onEraseStart: _eraseStart,
                onErase: _eraseAt,
                onEraseEnd: _eraseEnd,
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: <Widget>[
            IconButton(
              tooltip: _page == 0 ? 'Back to the fonts' : 'Previous page',
              onPressed: _saving ? null : _back,
              icon: const Icon(AppIcons.previous),
            ),
            IconButton(
              tooltip: 'Undo',
              onPressed: _history.isEmpty ? null : _undo,
              icon: const Icon(AppIcons.undo),
            ),
            IconButton(
              key: const ValueKey<String>('calibration-eraser'),
              tooltip: _eraserTool ? 'Write with the pen' : 'Eraser',
              isSelected: _eraserTool,
              onPressed: () => setState(() => _eraserTool = !_eraserTool),
              icon: const EraserIcon(),
              selectedIcon: const EraserIcon(),
              style: IconButton.styleFrom(
                backgroundColor: _eraserTool ? colors.surfaceMuted : null,
              ),
            ),
            TextButton(
              onPressed: _strokes.isEmpty ? null : _clear,
              child: const Text('Clear'),
            ),
            // In the button row, so a problem never changes the pad's size
            // under ink already written.
            Expanded(
              child: Text(
                _problem ?? '',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall!.copyWith(color: colors.danger),
              ),
            ),
            FilledButton(
              onPressed:
                  _saving ||
                      (_strokes.isEmpty && !customFontPageOptional(_page))
                  ? null
                  : _next,
              child: Text(done ? 'Done' : 'Next'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFinished(BuildContext context, HandwritingStyle style) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(AppIcons.check, size: 48, color: colors.accent),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Calibration finished',
                  key: const ValueKey<String>('calibration-finished'),
                  style: text.titleMedium!.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: _saving ? null : _tryAgain,
              child: const Text('Try again'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () => _finish(style, HandwritingFont.custom),
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }
}

/// [missing] letters, asked for: all of them while there are few, or how
/// many while there are many.
String _askFor(List<String> missing) => missing.length == 1
    ? 'Write a ${missing.single} in its box too.'
    : missing.length <= 6
    ? 'Write ${_listed(missing)} in their boxes too.'
    : 'Write a letter in each of the ${missing.length} empty boxes too.';

/// A font to choose: its name, what it is like, and a line written in it.
class _FontCard extends StatelessWidget {
  const _FontCard({
    required this.font,
    required this.style,
    required this.selected,
    required this.onTap,
    required this.onRewrite,
  });

  final HandwritingFont font;

  /// The hand the card writes in; null for the writer's own font before
  /// they have made it.
  final HandwritingStyle? style;
  final bool selected;
  final VoidCallback? onTap;

  /// Writes the letters of the writer's own font again.
  final VoidCallback? onRewrite;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final HandwritingStyle? style = this.style;
    final BorderRadius radius = BorderRadius.circular(AppRadii.small * 3);
    return Semantics(
      button: true,
      selected: selected,
      label: '${font.label}: ${font.description}',
      excludeSemantics: onRewrite == null,
      child: Material(
        key: ValueKey<String>('calibration-font-${font.name}'),
        color: colors.writingSurface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? colors.accent : colors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        font.label,
                        style: text.titleSmall!.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (onRewrite != null)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: onRewrite,
                        child: const Text('Write again'),
                      ),
                    if (selected)
                      Icon(AppIcons.check, size: 18, color: colors.accent),
                  ],
                ),
                Text(
                  font.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall!.copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Expanded(
                  child: style == null
                      ? Row(
                          children: <Widget>[
                            Icon(AppIcons.newNote, color: colors.textSecondary),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: Text(
                                'Write 15 letters, and the AI will write in '
                                'your handwriting.',
                                style: text.bodySmall!.copyWith(
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        )
                      : CustomPaint(
                          painter: _PreviewPainter(
                            text: _sampleText,
                            style: style,
                            ink: colors.textPrimary,
                            alignLeft: true,
                          ),
                          size: Size.infinite,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A box to write each letter of [rows] in, labelled with it, in rows:
/// each with a dotted line at the height of a small letter and a solid
/// baseline. Only a pen writes, so a resting palm or finger leaves no
/// marks; touching it with anything else says so. The pen's eraser end,
/// its side button, or the tip with [eraserTool] chosen erases whole
/// strokes instead.
class _WritingPad extends StatefulWidget {
  const _WritingPad({
    super.key,
    required this.height,
    required this.ruling,
    required this.rows,
    required this.strokes,
    required this.eraserTool,
    required this.onStroke,
    required this.onEraseStart,
    required this.onErase,
    required this.onEraseEnd,
  });

  final double height;
  final CalibrationRuling ruling;
  final List<String> rows;

  /// Finished strokes, on the pad.
  final List<List<InkVector>> strokes;
  final bool eraserTool;
  final ValueChanged<List<InkVector>> onStroke;
  final VoidCallback onEraseStart;
  final ValueChanged<InkVector> onErase;
  final VoidCallback onEraseEnd;

  @override
  State<_WritingPad> createState() => _WritingPadState();
}

class _WritingPadState extends State<_WritingPad> {
  List<InkVector>? _active;
  int? _pointer;
  bool _notPen = false;

  /// Where the eraser is while it erases, for its outline.
  InkVector? _eraser;

  bool _erases(PointerEvent event) =>
      event.kind == PointerDeviceKind.invertedStylus ||
      event.buttons & kSecondaryStylusButton != 0 ||
      widget.eraserTool;

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      if (!_notPen) setState(() => _notPen = true);
      return;
    }
    _pointer = event.pointer;
    final InkVector point = _vector(event.localPosition);
    if (_erases(event)) {
      setState(() {
        _notPen = false;
        _eraser = point;
      });
      widget.onEraseStart();
      widget.onErase(point);
      return;
    }
    setState(() {
      _notPen = false;
      _active = <InkVector>[point];
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final InkVector point = _vector(event.localPosition);
    if (_eraser != null) {
      setState(() => _eraser = point);
      widget.onErase(point);
      return;
    }
    final List<InkVector> active = _active!;
    if ((point - active.last).length < 0.75) return;
    setState(() => active.add(point));
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    if (_eraser != null) {
      setState(() => _eraser = null);
      widget.onEraseEnd();
      return;
    }
    final List<InkVector> active = _active!;
    _active = null;
    widget.onStroke(active);
  }

  static InkVector _vector(Offset offset) => InkVector(offset.dx, offset.dy);

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Semantics(
      label:
          'Writing area: a box for each of the letters '
          '${_listed(widget.rows.join().split(''))}',
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
              ruling: widget.ruling,
              rows: widget.rows,
              strokes: <List<InkVector>>[...widget.strokes, ?_active],
              rule: colors.pageRule,
              label: colors.textSecondary,
              ink: colors.textPrimary,
              strokeWidth: math.max(2, widget.ruling.lineHeight / 22),
              eraser: _eraser,
              eraserRadius: widget.ruling.lineHeight * 0.3,
            ),
            size: Size.infinite,
            child: _notPen || (widget.strokes.isEmpty && _active == null)
                ? Padding(
                    padding: const EdgeInsets.all(AppSpacing.xs),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Text(
                        _notPen
                            ? 'Use your pen to write here'
                            : 'Write each letter in its box, sitting on '
                                  'the solid line',
                        style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          color: _notPen
                              ? colors.danger
                              : colors.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// [letters] as a phrase: "g", "g and p", "g, p and w".
String _listed(List<String> letters) => letters.length == 1
    ? letters.single
    : '${letters.sublist(0, letters.length - 1).join(', ')} and '
          '${letters.last}';

/// How far [point] is from the nearest part of [stroke].
double _distanceToStroke(InkVector point, List<InkVector> stroke) {
  if (stroke.length == 1) return (point - stroke.first).length;
  double nearest = double.infinity;
  for (int i = 1; i < stroke.length; i++) {
    final InkVector a = stroke[i - 1];
    final InkVector along = stroke[i] - a;
    final double squared = along.x * along.x + along.y * along.y;
    final double t = squared == 0
        ? 0
        : (((point.x - a.x) * along.x + (point.y - a.y) * along.y) / squared)
              .clamp(0.0, 1.0);
    nearest = math.min(
      nearest,
      (point - InkVector(a.x + along.x * t, a.y + along.y * t)).length,
    );
  }
  return nearest;
}

void _paintStrokes(
  Canvas canvas,
  List<List<InkVector>> strokes,
  Color ink,
  double strokeWidth,
) {
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

class _PadPainter extends CustomPainter {
  _PadPainter({
    required this.ruling,
    required this.rows,
    required this.strokes,
    required this.rule,
    required this.label,
    required this.ink,
    required this.strokeWidth,
    required this.eraser,
    required this.eraserRadius,
  });

  final CalibrationRuling ruling;
  final List<String> rows;
  final List<List<InkVector>> strokes;
  final Color rule;
  final Color label;
  final Color ink;
  final double strokeWidth;
  final InkVector? eraser;
  final double eraserRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final double lineHeight = ruling.lineHeight;
    final Paint guide = Paint()..strokeWidth = 1;
    void dashed(double from, double to, double y, double dash, double gap) {
      for (double x = from; x < to; x += dash + gap) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, to), y), guide);
      }
    }

    for (int row = 0; row < rows.length; row++) {
      final double baseline = ruling.baselines[row];
      final List<String> letters = rows[row].split('');
      final Color lines = rule;
      for (int c = 0; c < letters.length; c++) {
        final double left = ruling.left + c * ruling.cellWidth;
        final Rect box = Rect.fromLTRB(
          left + 3,
          baseline - lineHeight * 1.15,
          left + ruling.cellWidth - 3,
          baseline + lineHeight * 0.8,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            box,
            const Radius.circular(AppRadii.small * 2),
          ),
          Paint()
            ..color = lines
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        guide
          ..color = lines
          ..strokeWidth = 1;
        dashed(box.left + 4, box.right - 4, baseline - lineHeight * 0.55, 2, 5);
        canvas.drawLine(
          Offset(box.left + 4, baseline),
          Offset(box.right - 4, baseline),
          guide..strokeWidth = 1.5,
        );
        final TextPainter name = TextPainter(
          text: TextSpan(
            text: letters[c],
            style: TextStyle(
              color: label.withValues(alpha: label.a * 0.8),
              fontSize: math.max(11, lineHeight * 0.3),
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        name.paint(canvas, box.topLeft + const Offset(6, 3));
        name.dispose();
      }
    }
    _paintStrokes(canvas, strokes, ink, strokeWidth);
    final InkVector? at = eraser;
    if (at != null) {
      canvas.drawCircle(
        Offset(at.x, at.y),
        eraserRadius,
        Paint()
          ..color = ink.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}

/// [text] written in [style], as large as fits: centred, or on the left
/// with [alignLeft].
class _PreviewPainter extends CustomPainter {
  _PreviewPainter({
    required this.text,
    required this.style,
    required this.ink,
    this.alignLeft = false,
  });

  final String text;
  final HandwritingStyle style;
  final Color ink;
  final bool alignLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final List<List<InkVector>> written = NotationFont.write(
      text,
      origin: InkVector.zero,
      size: NotationFont.capHeight,
      style: style,
    );
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in written) {
      for (final InkVector p in stroke) {
        left = math.min(left, p.x);
        top = math.min(top, p.y);
        right = math.max(right, p.x);
        bottom = math.max(bottom, p.y);
      }
    }
    if (!left.isFinite) return;
    final double scale = math.min(
      size.width / (right - left),
      size.height / (bottom - top),
    );
    final double dx = alignLeft ? 0 : (size.width - (right - left) * scale) / 2;
    final double dy = (size.height - (bottom - top) * scale) / 2;
    _paintStrokes(
      canvas,
      <List<InkVector>>[
        for (final List<InkVector> stroke in written)
          <InkVector>[
            for (final InkVector p in stroke)
              InkVector((p.x - left) * scale + dx, (p.y - top) * scale + dy),
          ],
      ],
      ink,
      math.max(1.5, scale * 0.7),
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.text != text || old.style != style || old.ink != ink;
}
