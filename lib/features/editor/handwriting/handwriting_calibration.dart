import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../ai/notation_font.dart';
import '../ink/ink_sample.dart';
import 'glyph_builder.dart';
import 'hand_features.dart';
import 'hand_glyphs.dart';
import 'handwriting_fonts.dart';
import 'handwriting_style.dart';
import 'stroke_runs.dart';

/// The pages of boxes the writer fills to make a font of their own, each a
/// few rows of letters, one box for each. The [keyLetters], on the first
/// page, must be written: the rest of the alphabet is built from their
/// strokes. Any of the others may be written too, to be used as written;
/// digits left out are written in the built-in font.
const List<List<String>> customFontPages = <List<String>>[
  <String>['abefgik', 'nostw', 'AER'],
  <String>['cdhjlmp', 'qruvxyz'],
  <String>['BCDFGHIJ', 'KLMNOPQS', 'TUVWXYZ'],
  <String>['01234', '56789'],
];

/// Whether [page] of [customFontPages] may be left empty.
bool customFontPageOptional(int page) => page > 0;

/// How far the built-in hand moves towards the traits measured from the
/// writer's letters, for what they did not write out: all the way would
/// copy their slips as faithfully as their style.
const double calibrationMix = 0.8;

/// How wide a box is, in line heights.
const double calibrationCell = 1.5;

/// How far apart rows of boxes are, in line heights.
const double calibrationRowGap = 2.2;

/// Where a pad's boxes are: each row's baseline from the pad's top, how
/// tall an ascender would stand above it, where the first box starts, and
/// how wide each box is.
typedef CalibrationRuling = ({
  List<double> baselines,
  double lineHeight,
  double left,
  double cellWidth,
});

/// The ruling of a page of [rows] rows in the pad's ruled units (see
/// [CalibrationDraft]): a line height of 1, the first box's left edge at
/// x = 0 and the first baseline at y = 0.
CalibrationRuling ruledUnits(int rows) => (
  baselines: <double>[for (int i = 0; i < rows; i++) i * calibrationRowGap],
  lineHeight: 1,
  left: 0,
  cellWidth: calibrationCell,
);

/// What reading the letters found.
@immutable
class CalibrationReading {
  const CalibrationReading({this.missing = const <String>[], this.style});

  /// Letters with nothing written in their boxes.
  final List<String> missing;

  /// The writer's own font; null unless every key letter was written.
  final HandwritingStyle? style;

  bool get complete => missing.isEmpty && style != null;
}

/// The strokes in each box of a page whose rows hold [rows], ruled by
/// [ruling]: by row, then by column.
///
/// A row's ink is first split into letters, each running from its leftmost
/// end to its rightmost, where nothing overlaps it. When there are as many
/// letters as boxes, they go to the boxes in order, left to right, so a row
/// that drifts left or right of its boxes still gives each letter its own
/// strokes. Otherwise a stroke belongs to the box its middle is in, so a
/// tail or a dot that strays over an edge stays with its letter; ink
/// outside every box is left out.
List<List<List<List<InkVector>>>> calibrationCells(
  List<List<InkVector>> strokes,
  CalibrationRuling ruling,
  List<String> rows,
) {
  final List<List<List<List<InkVector>>>> cells = <List<List<List<InkVector>>>>[
    for (final String row in rows)
      <List<List<InkVector>>>[
        for (int c = 0; c < row.length; c++) <List<InkVector>>[],
      ],
  ];
  final List<List<List<InkVector>>> byRow = <List<List<InkVector>>>[
    for (int i = 0; i < rows.length; i++) <List<InkVector>>[],
  ];
  for (final List<InkVector> stroke in strokes) {
    if (stroke.isEmpty) continue;
    final _Bounds bounds = _Bounds.of(<List<InkVector>>[stroke]);
    int row = 0;
    double nearest = double.infinity;
    for (int i = 0; i < rows.length; i++) {
      // Measured from the middle of a letter on that line, so the dot of
      // an i stays in its row.
      final double away =
          (bounds.centerY - (ruling.baselines[i] - ruling.lineHeight * 0.45))
              .abs();
      if (away < nearest) {
        nearest = away;
        row = i;
      }
    }
    byRow[row].add(stroke);
  }
  for (int r = 0; r < rows.length; r++) {
    final List<List<List<InkVector>>> letters = _letters(
      byRow[r],
      ruling.lineHeight * 0.15,
    );
    if (letters.length == rows[r].length) {
      for (int c = 0; c < letters.length; c++) {
        cells[r][c].addAll(letters[c]);
      }
      continue;
    }
    for (final List<InkVector> stroke in byRow[r]) {
      final _Bounds bounds = _Bounds.of(<List<InkVector>>[stroke]);
      final int column = ((bounds.centerX - ruling.left) / ruling.cellWidth)
          .floor();
      if (column < 0 || column >= rows[r].length) continue;
      cells[r][column].add(stroke);
    }
  }
  return cells;
}

/// [strokes] gathered into letters, left to right: strokes whose spans
/// across the line overlap, or come within [gap] of each other, are one
/// letter, from its leftmost end to its rightmost. Each letter's strokes
/// stay in the order they were written.
List<List<List<InkVector>>> _letters(
  List<List<InkVector>> strokes,
  double gap,
) {
  final List<int> order = <int>[for (int i = 0; i < strokes.length; i++) i];
  final List<_Bounds> bounds = <_Bounds>[
    for (final List<InkVector> stroke in strokes)
      _Bounds.of(<List<InkVector>>[stroke]),
  ];
  order.sort((int a, int b) => bounds[a].left.compareTo(bounds[b].left));
  final List<List<int>> letters = <List<int>>[];
  double right = double.negativeInfinity;
  for (final int i in order) {
    if (letters.isEmpty || bounds[i].left > right + gap) {
      letters.add(<int>[]);
      right = bounds[i].right;
    } else {
      right = math.max(right, bounds[i].right);
    }
    letters.last.add(i);
  }
  return <List<List<InkVector>>>[
    for (final List<int> letter in letters)
      <List<InkVector>>[for (final int i in letter..sort()) strokes[i]],
  ];
}

/// The letters still to be written on [page] of [customFontPages], whose
/// ink, in ruled units, is [strokes].
List<String> missingLetters(int page, List<List<InkVector>> strokes) {
  final List<String> rows = customFontPages[page];
  final List<List<List<List<InkVector>>>> cells = calibrationCells(
    strokes,
    ruledUnits(rows.length),
    rows,
  );
  return <String>[
    for (int r = 0; r < rows.length; r++)
      for (int c = 0; c < rows[r].length; c++)
        if (cells[r][c].isEmpty) rows[r][c],
  ];
}

/// Makes the writer's own font from [pages], the ink on each page of
/// [customFontPages] in ruled units. Each box holds a known letter, so
/// nothing is sent to a recognizer. Every letter is kept as written,
/// smoothed, and scaled so that the writer's capitals are the font's; the
/// letters they left out are built from the strokes of those they wrote
/// ([buildMissingGlyphs]). What is not a letter, such as punctuation, or a
/// digit left out, is written in the built-in font shaped by the traits
/// measured from their letters.
CalibrationReading readCustomFont(List<List<List<InkVector>>> pages) {
  final List<String> missing = <String>[
    for (int p = 0; p < customFontPages.length; p++)
      if (!customFontPageOptional(p))
        ...missingLetters(
          p,
          p < pages.length ? pages[p] : const <List<InkVector>>[],
        ),
  ];
  if (missing.isNotEmpty) return CalibrationReading(missing: missing);

  final List<_Sample> samples = <_Sample>[];
  for (int p = 0; p < customFontPages.length && p < pages.length; p++) {
    final List<String> rows = customFontPages[p];
    final CalibrationRuling ruling = ruledUnits(rows.length);
    final List<List<List<List<InkVector>>>> cells = calibrationCells(
      pages[p],
      ruling,
      rows,
    );
    for (int r = 0; r < rows.length; r++) {
      final double rule = ruling.baselines[r];
      // Where this row's letters sit: the feet of those without a tail,
      // where they are near the line.
      final List<double> feet = <double>[
        for (int c = 0; c < rows[r].length; c++)
          if (!_tails.contains(rows[r][c]) && cells[r][c].isNotEmpty)
            if ((_Bounds.of(cells[r][c]).bottom - rule).abs() < 0.4)
              _Bounds.of(cells[r][c]).bottom,
      ];
      final double baseline = feet.isEmpty ? rule : _median(feet);
      for (int c = 0; c < rows[r].length; c++) {
        if (cells[r][c].isEmpty) continue;
        samples.add(_Sample(rows[r][c], cells[r][c], baseline));
      }
    }
  }

  // How tall the writer's capitals are, which the font's are made.
  List<double> heights(String letters) => <double>[
    for (final _Sample s in samples)
      if (letters.contains(s.letter))
        if (s.baseline - s.bounds.top > 0.2 && s.baseline - s.bounds.top < 2.5)
          s.baseline - s.bounds.top,
  ];
  final List<double> capitals = heights('ABCDEFGHIKLMNOPRSTUVWXYZ');
  final List<double> ascenders = heights('bdfhklt');
  final double capHeight = capitals.isNotEmpty
      ? _median(capitals)
      : ascenders.isNotEmpty
      ? _median(ascenders)
      : 1;
  final double unit = capHeight / NotationFont.capHeight;

  final Map<String, HandGlyph> glyphs = <String, HandGlyph>{};
  for (final _Sample s in samples) {
    final List<List<InkVector>> smooth = beautifyHandwriting(
      s.strokes,
      spacing: unit * 0.4,
    );
    final _Bounds bounds = _Bounds.of(smooth);
    glyphs[s.letter] = HandGlyph(bounds.width / unit, <List<InkVector>>[
      for (final List<InkVector> stroke in smooth)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(
              (p.x - bounds.left) / unit,
              NotationFont.capHeight + (p.y - s.baseline) / unit,
            ),
        ],
    ]);
  }

  // Measured at the size of a pad, as its thresholds expect.
  final HandwritingStyle measured = _measure(<_Sample>[
    for (final _Sample s in samples)
      if (handLetters.contains(s.letter)) s.scaled(_padScale),
  ], _padScale);
  glyphs.addAll(buildMissingGlyphs(glyphs, slant: measured.slant));

  return CalibrationReading(
    style: HandwritingStyle.standard
        .mix(measured, calibrationMix)
        .clamped()
        .withGlyphs(HandGlyphs.rounded(glyphs)),
  );
}

/// About how many pixels a line height is on a pad.
const double _padScale = 60;

/// Letters that hang below the line, so do not show where it is.
const String _tails = 'gjpqyQJ';

/// One letter as written in its box.
class _Sample {
  _Sample(this.letter, this.strokes, this.baseline)
    : bounds = _Bounds.of(strokes);

  final String letter;
  final List<List<InkVector>> strokes;

  /// This sample [factor] times as large.
  _Sample scaled(double factor) => _Sample(letter, <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[for (final InkVector p in stroke) p * factor],
  ], baseline * factor);

  /// Where the letter sits.
  final double baseline;
  final _Bounds bounds;
}

/// The hand that wrote [samples].
///
/// None of the letters has an ascender, so their own x-height sets the
/// scale: the writer's letters are laid in the font's grid as tall as the
/// font's, upright, and measured there against the font's.
HandwritingStyle _measure(List<_Sample> samples, double lineHeight) {
  const HandwritingStyle standard = HandwritingStyle.standard;
  final List<double> xHeights = <double>[
    for (final _Sample s in samples)
      if ('agpw'.contains(s.letter))
        if (s.baseline - s.bounds.top > lineHeight * 0.15 &&
            s.baseline - s.bounds.top < lineHeight * 2.5)
          s.baseline - s.bounds.top,
  ];
  final double xHeight = xHeights.isEmpty
      ? lineHeight * 0.55
      : _median(xHeights);
  final double unit = xHeight / (standard.xHeight * NotationFont.capHeight);

  final double slant =
      _slant(<List<InkVector>>[
        for (final _Sample s in samples)
          if ('ipag'.contains(s.letter)) ...s.strokes,
      ]) ??
      standard.slant;

  // Each letter upright, in the font's grid: its left edge at x = 0 and
  // its baseline at y = 10.
  final Map<String, List<List<List<InkVector>>>> grid =
      <String, List<List<List<InkVector>>>>{};
  for (final _Sample s in samples) {
    final List<List<InkVector>> upright = <List<InkVector>>[
      for (final List<InkVector> stroke in s.strokes)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(p.x - slant * (s.baseline - p.y), p.y),
        ],
    ];
    final double left = _Bounds.of(upright).left;
    (grid[s.letter] ??= <List<List<InkVector>>>[]).add(<List<InkVector>>[
      for (final List<InkVector> stroke in upright)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(
              (p.x - left) / unit,
              NotationFont.capHeight + (p.y - s.baseline) / unit,
            ),
        ],
    ]);
  }

  // Width against the font's, from the w alone: the other letters are
  // mostly bowl, and how round the bowls are is the bowls' to say, not
  // counted twice.
  final List<double> widths = <double>[
    for (final String letter in <String>['w'])
      for (final List<List<InkVector>> sample
          in grid[letter] ?? const <List<List<InkVector>>>[])
        _Bounds.of(sample).width / NotationFont.glyphWidth(letter)!,
  ];
  // Depth of the descenders against the font's.
  final List<double> depths = <double>[
    for (final String letter in <String>['g', 'p'])
      for (final List<List<InkVector>> sample
          in grid[letter] ?? const <List<List<InkVector>>>[])
        (_Bounds.of(sample).bottom - NotationFont.capHeight) /
            (NotationFont.glyphSpan(letter)!.bottom * NotationFont.capHeight -
                NotationFont.capHeight),
  ];

  return HandwritingStyle(
    slant: slant,
    widthScale: widths.isEmpty ? standard.widthScale : _median(widths),
    descenderScale: depths.isEmpty ? standard.descenderScale : _median(depths),
    features: HandFeatures.measure(grid),
  ).clamped();
}

/// The lean of the near-vertical strokes in [strokes], weighted by length:
/// how far right the pen moves per unit it rises. Null with too little to
/// tell.
double? _slant(List<List<InkVector>> strokes) {
  final List<(double, double)> leans = <(double, double)>[];
  double total = 0;
  for (final List<InkVector> stroke in strokes) {
    final List<InkVector> even = resampled(stroke, 3);
    for (int i = 1; i < even.length; i++) {
      final InkVector step = even[i] - even[i - 1];
      if (step.y.abs() < 1e-6 || step.x.abs() > step.y.abs() * 0.8) continue;
      // Up or down, a forward lean has x and y moving opposite ways.
      leans.add((-step.x / step.y, step.length));
      total += step.length;
    }
  }
  if (total == 0) return null;
  leans.sort(((double, double) a, (double, double) b) => a.$1.compareTo(b.$1));
  double running = 0;
  for (final (double lean, double weight) in leans) {
    running += weight;
    if (running >= total / 2) return lean;
  }
  return leans.last.$1;
}

/// [strokes] of the writer's own hand, tidied a little for writing it back:
/// each stroke is resampled evenly, [spacing] apart, and smoothed so that
/// the jitter of the pen is gone while the shape, its ends, and the
/// strokes' order stay as written. A dot stays a dot.
List<List<InkVector>> beautifyHandwriting(
  List<List<InkVector>> strokes, {
  required double spacing,
}) => <List<InkVector>>[
  for (final List<InkVector> stroke in strokes)
    smoothedPoints(resampled(stroke, spacing)),
];

@immutable
class _Bounds {
  const _Bounds(this.left, this.top, this.right, this.bottom);

  factory _Bounds.of(Iterable<List<InkVector>> strokes) {
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector point in stroke) {
        left = math.min(left, point.x);
        top = math.min(top, point.y);
        right = math.max(right, point.x);
        bottom = math.max(bottom, point.y);
      }
    }
    return _Bounds(left, top, right, bottom);
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
}

double _median(List<double> values) {
  final List<double> sorted = List<double>.of(values)..sort();
  final int middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// Where the writer's hand is kept, and whether they have been asked.
abstract class HandwritingProfileStore {
  /// The saved state, or null when calibration has never been offered.
  Future<HandwritingCalibrationState?> read();

  Future<void> write(HandwritingCalibrationState state);

  /// The letters as far as they were written before calibration was left:
  /// the ink on each page of [customFontPages], in the pad's ruled units
  /// (see [CalibrationDraft]), or empty.
  Future<List<List<List<InkVector>>>> readDraft();

  /// Keeps [pages] until calibration is finished; empty forgets them.
  Future<void> writeDraft(List<List<List<InkVector>>> pages);
}

/// Ink on the calibration pad, measured so it survives the pad changing
/// size: x in line heights from the first box's left edge, y in line
/// heights below the first baseline.
abstract final class CalibrationDraft {
  static List<List<InkVector>> encode(
    List<List<InkVector>> strokes, {
    required CalibrationRuling ruling,
  }) => <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[
        for (final InkVector p in stroke)
          InkVector(
            (p.x - ruling.left) / ruling.lineHeight,
            (p.y - ruling.baselines.first) / ruling.lineHeight,
          ),
      ],
  ];

  static List<List<InkVector>> decode(
    List<List<InkVector>> strokes, {
    required CalibrationRuling ruling,
  }) => <List<InkVector>>[
    for (final List<InkVector> stroke in strokes)
      <InkVector>[
        for (final InkVector p in stroke)
          InkVector(
            ruling.left + p.x * ruling.lineHeight,
            ruling.baselines.first + p.y * ruling.lineHeight,
          ),
      ],
  ];

  static Object toJson(List<List<InkVector>> strokes) => <List<double>>[
    for (final List<InkVector> stroke in strokes)
      <double>[
        for (final InkVector p in stroke) ...<double>[p.x, p.y],
      ],
  ];

  static Object pagesToJson(List<List<List<InkVector>>> pages) => <Object>[
    for (final List<List<InkVector>> page in pages) toJson(page),
  ];

  static List<List<List<InkVector>>> pagesFromJson(Object? json) {
    if (json is! List) return const <List<List<InkVector>>>[];
    return <List<List<InkVector>>>[
      for (final Object? page in json) fromJson(page),
    ];
  }

  static List<List<InkVector>> fromJson(Object? json) {
    if (json is! List) return const <List<InkVector>>[];
    return <List<InkVector>>[
      for (final Object? stroke in json)
        if (stroke is List && stroke.length >= 2)
          <InkVector>[
            for (int i = 0; i + 1 < stroke.length; i += 2)
              InkVector(
                (stroke[i] as num).toDouble(),
                (stroke[i + 1] as num).toDouble(),
              ),
          ],
    ];
  }
}

/// The writer's hand and their choices around calibration prompts.
@immutable
class HandwritingCalibrationState {
  const HandwritingCalibrationState({
    this.style,
    this.font,
    this.skipped = false,
    this.chatReminderDismissed = false,
  });

  final HandwritingStyle? style;

  /// Which of the fonts [style] is; null when nothing was chosen.
  final HandwritingFont? font;

  /// The writer chose not to calibrate; they are not asked again at
  /// startup.
  final bool skipped;

  /// The writer permanently dismissed the small reminder in the chat.
  final bool chatReminderDismissed;

  Map<String, Object?> toJson() => <String, Object?>{
    'skipped': skipped,
    if (font != null) 'font': font!.name,
    if (chatReminderDismissed) 'chatReminderDismissed': true,
    if (style != null) 'style': style!.toJson(),
  };

  /// A preset font is written as it is now, not as it was when chosen.
  static HandwritingCalibrationState fromJson(Map<String, Object?> json) {
    final HandwritingFont? font = HandwritingFont.byName(json['font']);
    return HandwritingCalibrationState(
      style: font?.style ?? HandwritingStyle.fromJson(json['style']),
      font: font,
      skipped: json['skipped'] == true,
      chatReminderDismissed: json['chatReminderDismissed'] == true,
    );
  }
}

/// Keeps the writer's hand in one JSON file, written atomically.
class FileHandwritingProfileStore implements HandwritingProfileStore {
  FileHandwritingProfileStore(this.file);

  final File file;

  @override
  Future<HandwritingCalibrationState?> read() async {
    try {
      if (!await file.exists()) return null;
      final Object? json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?>) {
        return const HandwritingCalibrationState();
      }
      // Calibrated glyph by glyph, as long ago: offered again, once, since
      // those glyphs are no longer used.
      if (json.containsKey('profile')) return null;
      // A hand measured from a few letters, before there were fonts to
      // choose from: offered again, once, to choose one.
      if (json['style'] != null &&
          HandwritingFont.byName(json['font']) == null) {
        return null;
      }
      // A font of the writer's own that can no longer be read.
      if (json['font'] == HandwritingFont.custom.name &&
          HandwritingStyle.fromJson(json['style'])?.glyphs == null) {
        return null;
      }
      return HandwritingCalibrationState.fromJson(json);
    } on Object {
      // A damaged file counts as asked, so startup is not interrupted again;
      // calibration stays available from the library menu.
      return const HandwritingCalibrationState();
    }
  }

  @override
  Future<void> write(HandwritingCalibrationState state) =>
      _queued(() => _writeAtomically(file, jsonEncode(state.toJson())));

  /// Beside the hand, so half-written letters outlive the app. Named for
  /// the key letters, so letters left half-written in the boxes of an
  /// older calibration are not put in its boxes.
  File get _draftFile => File('${file.path}.key.draft');

  @override
  Future<List<List<List<InkVector>>>> readDraft() async {
    try {
      if (!await _draftFile.exists()) {
        return const <List<List<InkVector>>>[];
      }
      return CalibrationDraft.pagesFromJson(
        jsonDecode(await _draftFile.readAsString()),
      );
    } on Object {
      return const <List<List<InkVector>>>[];
    }
  }

  @override
  Future<void> writeDraft(List<List<List<InkVector>>> pages) =>
      _queued(() async {
        if (pages.every((List<List<InkVector>> page) => page.isEmpty)) {
          if (await _draftFile.exists()) await _draftFile.delete();
          return;
        }
        await _writeAtomically(
          _draftFile,
          jsonEncode(CalibrationDraft.pagesToJson(pages)),
        );
      });

  /// Writes run one at a time, so two never share a temporary file.
  Future<void> _last = Future<void>.value();

  Future<void> _queued(Future<void> Function() write) {
    final Future<void> next = _last.then((void _) => write());
    _last = next.catchError((Object _) {});
    return next;
  }

  static Future<void> _writeAtomically(File target, String contents) async {
    await target.parent.create(recursive: true);
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  }
}

/// Keeps the writer's hand in memory, for tests and harnesses.
class InMemoryHandwritingProfileStore implements HandwritingProfileStore {
  InMemoryHandwritingProfileStore([this.state]);

  HandwritingCalibrationState? state;

  @override
  Future<HandwritingCalibrationState?> read() async => state;

  @override
  Future<void> write(HandwritingCalibrationState state) async {
    this.state = state;
  }

  List<List<List<InkVector>>> draft = const <List<List<InkVector>>>[];

  @override
  Future<List<List<List<InkVector>>>> readDraft() async => draft;

  @override
  Future<void> writeDraft(List<List<List<InkVector>>> pages) async {
    draft = pages.every((List<List<InkVector>> page) => page.isEmpty)
        ? const <List<List<InkVector>>>[]
        : <List<List<InkVector>>>[
            for (final List<List<InkVector>> page in pages)
              List<List<InkVector>>.of(page),
          ];
  }
}

/// The writer's hand for the running app. Every note's AI notation reads
/// it, so it lives outside any single note.
abstract final class HandwritingCalibration {
  static final ValueNotifier<HandwritingStyle?> current =
      ValueNotifier<HandwritingStyle?>(null);
}
