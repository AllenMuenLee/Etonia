import 'dart:math' as math;

import '../handwriting/handwriting_style.dart';
import '../ink/ink_sample.dart';
import 'notation_font.dart';

/// A formula written in LaTeX, such as `\frac{-b \pm \sqrt{b^2-4ac}}{2a}`,
/// read once and laid out the way it is written by hand: fractions stacked
/// over a bar, exponents raised and smaller, roots under a radical that
/// reaches over them, brackets as tall as what they hold.
///
/// It reads the LaTeX of school and university mathematics: fractions,
/// roots, scripts, Greek, operators and relations, big operators with
/// limits, accents, `\left`…`\right`, `\text`, and the matrix, `cases`, and
/// `aligned` environments. `\\` starts a new line, and `&` lines lines up.
/// A command it does not know is written as its name. Only what the font
/// can write is read.
///
/// Everything is measured in capital heights: a formula written `size`
/// tall is [width] times `size` wide.
class NotationMath {
  NotationMath._(this.source, this._box);

  /// Reads [source], with or without `$`, `$$`, `\(`, or `\[` round it.
  /// Throws a [FormatException], without quoting it, for anything it
  /// cannot read or write.
  factory NotationMath.parse(String source) {
    if (source.length > maxLength) {
      throw const FormatException('Formula too long');
    }
    final _Node root = _Parser(_unwrap(source)).document();
    final _Box box = _Layout().top(root);
    if (box.ops.isEmpty) {
      throw const FormatException('Empty formula');
    }
    return NotationMath._(source, box);
  }

  static const int maxLength = 600;

  final String source;
  final _Box _box;

  /// How wide the formula is, in capital heights.
  double get width => _box.width;

  /// How far it reaches above its first line's baseline, in capital
  /// heights.
  double get ascent => _box.ascent;

  /// How tall it is, from its top to its bottom, in capital heights.
  double get height => _box.ascent + _box.descent;

  /// About how many marks writing it takes: a letter or symbol each, and
  /// each bar, radical, and bracket.
  int get marks {
    int count = 0;
    for (final _Op op in _box.ops) {
      count += switch (op) {
        _Run() => op.text.runes.where((int rune) => rune != 0x20).length,
        _Path() => 1,
      };
    }
    return count;
  }

  /// The formula as polylines, written [size] tall in [style] with the
  /// top-left corner of its box at [origin].
  List<List<InkVector>> write({
    required InkVector origin,
    required double size,
    HandwritingStyle style = HandwritingStyle.standard,
  }) {
    final double baseline = origin.y + _box.ascent * size;
    final List<List<InkVector>> strokes = <List<InkVector>>[];
    int marks = 0;
    for (final _Op op in _box.ops) {
      switch (op) {
        case _Run():
          final double scale = op.scale * size;
          final InkVector start = InkVector(
            origin.x + op.x * size,
            baseline + op.y * size - scale,
          );
          final List<List<InkVector>> written = NotationFont.write(
            op.text,
            origin: start,
            size: scale,
            style: style,
          );
          strokes.addAll(
            _narrowed(written, start.x, op.width * size + style.slant * scale),
          );
        case _Path():
          // Drawn in the hand's grid, a capital 10 tall on a baseline at
          // y = 10, so bars, radicals, and brackets take on the hand the
          // letters are written in.
          const double grid = NotationFont.capHeight;
          final List<List<InkVector>> drawn = style.mark(<List<InkVector>>[
            <InkVector>[
              for (final InkVector p in op.points)
                InkVector(p.x * grid, p.y * grid + grid),
            ],
          ], seed: marks++ * 1.91);
          for (final List<InkVector> line in drawn) {
            strokes.add(<InkVector>[
              for (final InkVector p in line)
                InkVector(
                  origin.x + p.x / grid * size,
                  baseline + (p.y - grid) / grid * size,
                ),
            ]);
          }
      }
    }
    return strokes;
  }

  /// [strokes], squeezed toward [left] when a wider hand has written them
  /// wider than [width], so they keep to the room laid out for them.
  static List<List<InkVector>> _narrowed(
    List<List<InkVector>> strokes,
    double left,
    double width,
  ) {
    double right = double.negativeInfinity;
    for (final List<InkVector> stroke in strokes) {
      for (final InkVector p in stroke) {
        right = math.max(right, p.x);
      }
    }
    if (right - left <= width * 1.02 || right <= left) {
      return strokes;
    }
    final double squeeze = width / (right - left);
    return <List<InkVector>>[
      for (final List<InkVector> stroke in strokes)
        <InkVector>[
          for (final InkVector p in stroke)
            InkVector(left + (p.x - left) * squeeze, p.y),
        ],
    ];
  }

  /// [source] without the math delimiters a model often leaves round it.
  static String _unwrap(String source) {
    String text = source.trim();
    for (final (String open, String close) in const <(String, String)>[
      (r'$$', r'$$'),
      (r'\[', r'\]'),
      (r'\(', r'\)'),
      (r'$', r'$'),
    ]) {
      if (text.length >= open.length + close.length &&
          text.startsWith(open) &&
          text.endsWith(close)) {
        text = text.substring(open.length, text.length - close.length).trim();
        break;
      }
    }
    return text;
  }

  /// Whether [text], a piece of plain text, holds LaTeX worth laying out:
  /// a math-delimited run with a command, a script, or a brace in it.
  static bool hasMath(String text) => _inlineMath.hasMatch(text);

  /// Whether [text] explicitly delimits any formula, including a simple one
  /// such as `$x = 2$` that needs no LaTeX command or script.
  static bool hasDelimitedMath(String text) => _anyMath.hasMatch(text);

  /// [text] with its `$…$` runs as LaTeX and the rest as `\text`, one line
  /// of it per LaTeX line, so plain text with formulas in it can be laid
  /// out as one formula.
  static String fromText(String text) {
    String plain(String words) {
      if (words.isEmpty) return '';
      final String escaped = words.replaceAllMapped(
        RegExp(r'[\\{}]'),
        (Match match) =>
            match.group(0) == r'\' ? r'\backslash ' : '\\${match.group(0)}',
      );
      return '\\text{$escaped}';
    }

    return <String>[
      for (final String line in text.split('\n'))
        () {
          final StringBuffer out = StringBuffer();
          int at = 0;
          for (final RegExpMatch match in _anyMath.allMatches(line)) {
            out
              ..write(plain(line.substring(at, match.start)))
              ..write('{${match.group(1) ?? match.group(2)}}');
            at = match.end;
          }
          out.write(plain(line.substring(at)));
          return out.toString();
        }(),
    ].join(r' \\ ');
  }

  static final RegExp _anyMath = RegExp(r'\$\$?([^$]+?)\$\$?|\\\((.+?)\\\)');
  static final RegExp _inlineMath = RegExp(
    r'\$\$?[^$]*[\\^_{][^$]*\$\$?|\\\(.+?\\\)',
  );
}

// ---------------------------------------------------------------------------
// The formula as read.

/// How an atom sits beside its neighbours, which sets the space between
/// them, as TeX does.
enum _Kind { ord, op, bin, rel, open, close, punct, inner }

sealed class _Node {
  const _Node();
}

/// Characters written as they are: a letter, a number, an operator.
class _Sym extends _Node {
  const _Sym(this.text, this.kind, {this.limits = false});

  final String text;
  final _Kind kind;

  /// Whether scripts go above and below it, as for `\lim` and `\max`.
  final bool limits;
}

class _Row extends _Node {
  const _Row(this.items);

  final List<_Node> items;
}

class _Scripts extends _Node {
  const _Scripts(this.base, {this.sup, this.sub});

  final _Node base;
  final _Node? sup;
  final _Node? sub;
}

class _Frac extends _Node {
  const _Frac(this.top, this.bottom, {this.bar = true});

  final _Node top;
  final _Node bottom;
  final bool bar;
}

class _Sqrt extends _Node {
  const _Sqrt(this.body, this.index);

  final _Node body;
  final _Node? index;
}

/// What a pair of brackets holds. [left] or [right] is empty for none.
class _Fenced extends _Node {
  const _Fenced(this.left, this.body, this.right, {required this.stretch});

  final String left;
  final _Node body;
  final String right;

  /// Whether the brackets always grow round [body], as `\left` and
  /// `\right` ask. Otherwise they grow only when it is taller than a line.
  final bool stretch;
}

enum _Accent { vec, hat, bar, dot, ddot, tilde, over, under, arrow }

class _Accented extends _Node {
  const _Accented(this.body, this.accent, {this.wide = false});

  final _Node body;
  final _Accent accent;

  /// Whether the accent spans all of [body], rather than sitting over its
  /// middle.
  final bool wide;
}

/// One of `\sum`, `\int`, and the like, drawn larger than the text.
class _BigOp extends _Node {
  const _BigOp(this.symbol, {required this.limits});

  final String symbol;

  /// Whether its limits go above and below, as for a sum, rather than
  /// beside it, as for an integral.
  final bool limits;
}

enum _Align { left, center, right }

class _Grid extends _Node {
  const _Grid(
    this.rows, {
    required this.align,
    this.columnGap = 0.9,
    this.centered = true,
  });

  final List<List<_Node>> rows;

  /// How column `i` lines up its cells.
  final _Align Function(int column) align;
  final double columnGap;

  /// Whether the grid is centred on the math axis, like a matrix, rather
  /// than hanging from its first line's baseline, like lines of working.
  final bool centered;
}

class _Space extends _Node {
  const _Space(this.width);

  final double width;
}

// ---------------------------------------------------------------------------
// Reading.

class _Parser {
  _Parser(this._source);

  final String _source;
  int _at = 0;
  int _depth = 0;

  static const int _maxDepth = 24;

  bool get _atEnd => _at >= _source.length;
  String get _char => _source[_at];

  Never _fail() => throw const FormatException('Unreadable formula');

  _Node document() {
    final _Node node = _cells(null);
    if (!_atEnd) _fail();
    return node;
  }

  /// Rows of `&`-separated cells up to `\end{[environment]}`, or to the
  /// end with none: one row of one cell is just that cell.
  _Node _cells(String? environment, {_Align Function(int)? align}) {
    final List<List<_Node>> rows = <List<_Node>>[];
    List<_Node> cells = <_Node>[];
    bool anyAmpersand = false;
    while (true) {
      final ({_Row row, String? stop}) cell = _row(
        stops: const <String>{'&', r'\\', r'\end', ''},
      );
      cells.add(cell.row);
      switch (cell.stop) {
        case '&':
          anyAmpersand = true;
        case r'\\':
          rows.add(cells);
          cells = <_Node>[];
        case r'\end':
          final String name = _braced();
          if (name != environment) _fail();
          rows.add(cells);
          return _gridOf(rows, environment, align, anyAmpersand);
        default:
          if (environment != null) _fail();
          rows.add(cells);
          return _gridOf(rows, environment, align, anyAmpersand);
      }
    }
  }

  _Node _gridOf(
    List<List<_Node>> rows,
    String? environment,
    _Align Function(int)? align,
    bool anyAmpersand,
  ) {
    // A trailing \\ leaves an empty last row.
    if (rows.length > 1 &&
        rows.last.length == 1 &&
        (rows.last.single as _Row).items.isEmpty) {
      rows.removeLast();
    }
    if (environment == null && rows.length == 1 && rows.single.length == 1) {
      return rows.single.single;
    }
    if (align != null) {
      return _Grid(rows, align: align, centered: environment != null);
    }
    // Lines of working: left aligned, or lined up on & as `aligned` does.
    return _Grid(
      rows,
      align: anyAmpersand ? _alignedColumn : (_) => _Align.left,
      columnGap: anyAmpersand ? 0 : 0.9,
      centered: false,
    );
  }

  static _Align _alignedColumn(int column) =>
      column.isEven ? _Align.right : _Align.left;

  /// Atoms up to one of [stops] (`''` for the end of the source), and the
  /// stop found, which is used up except for `}`.
  ({_Row row, String? stop}) _row({required Set<String> stops}) {
    if (++_depth > _maxDepth) _fail();
    final List<_Node> items = <_Node>[];
    String? stop;
    while (true) {
      _skipSpace();
      if (_atEnd) {
        if (!stops.contains('')) _fail();
        stop = '';
        break;
      }
      final String c = _char;
      if (c == '}') {
        if (!stops.contains('}')) _fail();
        stop = '}';
        break;
      }
      if (c == ']' && stops.contains(']')) {
        _at++;
        stop = ']';
        break;
      }
      if (c == '&' && stops.contains('&')) {
        _at++;
        stop = '&';
        break;
      }
      if (c == r'\') {
        final String name = _peekCommand();
        if (stops.contains(name)) {
          _at += name.length;
          stop = name;
          break;
        }
      }
      if (c == '^' || c == '_') {
        _at++;
        final _Node script = _argument();
        final _Node base = items.isEmpty
            ? const _Row(<_Node>[])
            : items.removeLast();
        items.add(_attach(base, script, superscript: c == '^'));
        continue;
      }
      if (c == "'") {
        _at++;
        items.add(const _Sym('′', _Kind.ord));
        continue;
      }
      final _Node? atom = _atom();
      if (atom != null) items.add(atom);
    }
    _depth--;
    return (row: _Row(_fenced(items)), stop: stop);
  }

  /// [base] with [script] added above or below it.
  _Node _attach(_Node base, _Node script, {required bool superscript}) {
    if (base is _Scripts &&
        (superscript ? base.sup == null : base.sub == null)) {
      return _Scripts(
        base.base,
        sup: superscript ? script : base.sup,
        sub: superscript ? base.sub : script,
      );
    }
    return superscript
        ? _Scripts(base, sup: script)
        : _Scripts(base, sub: script);
  }

  /// [items] with each matched pair of plain brackets made one [_Fenced],
  /// so they can grow round what they hold.
  static List<_Node> _fenced(List<_Node> items) {
    final List<_Node> out = <_Node>[];
    final List<int> opens = <int>[];
    for (final _Node item in items) {
      final _Node core = item is _Scripts ? item.base : item;
      if (core is _Sym && core.kind == _Kind.open && item is! _Scripts) {
        opens.add(out.length);
        out.add(item);
        continue;
      }
      if (core is _Sym && core.kind == _Kind.close && opens.isNotEmpty) {
        final int start = opens.removeLast();
        final _Sym open = out[start] as _Sym;
        final _Fenced fenced = _Fenced(
          open.text,
          _Row(out.sublist(start + 1)),
          core.text,
          stretch: false,
        );
        out
          ..removeRange(start, out.length)
          ..add(
            item is _Scripts
                ? _Scripts(fenced, sup: item.sup, sub: item.sub)
                : fenced,
          );
        continue;
      }
      out.add(item);
    }
    return out;
  }

  void _skipSpace() {
    while (!_atEnd && ' \t\n\r'.contains(_char)) {
      _at++;
    }
  }

  /// The command at the cursor, such as `\frac`, `\\`, or `\,`, without
  /// using it up.
  String _peekCommand() {
    int end = _at + 1;
    if (end >= _source.length) _fail();
    if (_isLetter(_source.codeUnitAt(end))) {
      while (end < _source.length && _isLetter(_source.codeUnitAt(end))) {
        end++;
      }
    } else {
      end++;
    }
    return _source.substring(_at, end);
  }

  static bool _isLetter(int unit) =>
      (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);

  /// A script or a command's argument: a braced group, a command, or one
  /// character.
  _Node _argument() {
    _skipSpace();
    if (_atEnd) _fail();
    if (_char == '{') {
      _at++;
      final ({_Row row, String? stop}) group = _row(stops: const <String>{'}'});
      _at++;
      return group.row;
    }
    if (_char == '}' || _char == '^' || _char == '_' || _char == '&') _fail();
    return _atom() ?? const _Row(<_Node>[]);
  }

  /// The letters of a braced argument, such as an environment's name.
  String _braced() {
    _skipSpace();
    if (_atEnd || _char != '{') _fail();
    final int close = _source.indexOf('}', _at);
    if (close < 0) _fail();
    final String name = _source.substring(_at + 1, close).trim();
    _at = close + 1;
    return name;
  }

  /// A bracketed optional argument, such as a root's index, or null.
  _Node? _optional() {
    _skipSpace();
    if (_atEnd || _char != '[') return null;
    _at++;
    return _row(stops: const <String>{']'}).row;
  }

  /// One atom, or null for something that only changes the style.
  _Node? _atom() {
    final String c = _char;
    if (c == '{') {
      _at++;
      final ({_Row row, String? stop}) group = _row(stops: const <String>{'}'});
      _at++;
      return group.row;
    }
    if (c == r'\') return _command();
    _at++;
    if (_isDigit(c)) {
      final StringBuffer number = StringBuffer(c);
      while (!_atEnd &&
          (_isDigit(_char) ||
              (_char == '.' &&
                  _at + 1 < _source.length &&
                  _isDigit(_source[_at + 1])))) {
        number.write(_char);
        _at++;
      }
      return _Sym(number.toString(), _Kind.ord);
    }
    return switch (c) {
      '+' || '*' => _Sym(c == '*' ? '·' : '+', _Kind.bin),
      '-' => const _Sym('−', _Kind.bin),
      '=' || '<' || '>' || ':' => _Sym(c, _Kind.rel),
      '(' || '[' => _Sym(c, _Kind.open),
      ')' || ']' => _Sym(c, _Kind.close),
      ',' || ';' => _Sym(c, _Kind.punct),
      '~' => const _Space(0.33),
      _ => _symbol(c),
    };
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  /// [c] written as itself, given as a character in the source.
  static _Node _symbol(String c) {
    if (!NotationFont.canWrite(c)) _failStatic();
    final _Kind kind =
        _symbols.values
            .where(((String, _Kind) symbol) => symbol.$1 == c)
            .firstOrNull
            ?.$2 ??
        _Kind.ord;
    return _Sym(c, kind);
  }

  static Never _failStatic() =>
      throw const FormatException('Unreadable formula');

  _Node? _command() {
    final String name = _peekCommand();
    _at += name.length;
    final String bare = name.substring(1);
    if (_symbols[bare] case final (String, _Kind) symbol?) {
      return _Sym(symbol.$1, symbol.$2);
    }
    if (_spaces[bare] case final double width?) return _Space(width);
    if (_functions.contains(bare)) return _Sym(bare, _Kind.op);
    if (_limitFunctions.contains(bare)) {
      return _Sym(bare, _Kind.op, limits: true);
    }
    if (_bigOps[bare] case final (String, bool) op?) {
      return _BigOp(op.$1, limits: op.$2);
    }
    if (_accents[bare] case final (_Accent, bool) accent?) {
      return _Accented(_argument(), accent.$1, wide: accent.$2);
    }
    switch (bare) {
      case 'frac' || 'dfrac' || 'tfrac' || 'cfrac':
        return _Frac(_argument(), _argument());
      case 'binom' || 'dbinom' || 'tbinom':
        return _Fenced(
          '(',
          _Frac(_argument(), _argument(), bar: false),
          ')',
          stretch: true,
        );
      case 'sqrt':
        final _Node? index = _optional();
        return _Sqrt(_argument(), index);
      case 'text' ||
          'textrm' ||
          'textit' ||
          'textbf' ||
          'textsf' ||
          'mbox' ||
          'textnormal':
        return _Sym(_plainText(), _Kind.ord);
      case 'mathrm' ||
          'mathit' ||
          'mathbf' ||
          'mathsf' ||
          'mathcal' ||
          'mathscr' ||
          'mathfrak' ||
          'boldsymbol' ||
          'bm' ||
          'mathnormal':
        return _argument();
      case 'operatorname':
        return _Sym(_plainText(), _Kind.op);
      case 'mathbb':
        return _blackboard(_argument());
      case 'left':
        return _leftRight();
      case 'right' || 'middle':
        // \middle| inside \left…\right writes a bar; a stray \right is
        // unreadable.
        if (bare == 'right') _fail();
        return _Sym(_delimiter(), _Kind.rel);
      case 'big' ||
          'Big' ||
          'bigg' ||
          'Bigg' ||
          'bigl' ||
          'bigr' ||
          'Bigl' ||
          'Bigr' ||
          'biggl' ||
          'biggr' ||
          'Biggl' ||
          'Biggr' ||
          'bigm' ||
          'Bigm':
        final String delimiter = _delimiter();
        if (delimiter.isEmpty) return null;
        return _Sym(delimiter, _delimiterKind(delimiter, bare));
      case 'begin':
        return _environment(_braced());
      case 'not':
        final _Node next = _argument();
        if (next case _Sym(text: '=')) return const _Sym('≠', _Kind.rel);
        if (next case _Sym(text: '∈')) return const _Sym('∉', _Kind.rel);
        return next;
      case 'displaystyle' ||
          'textstyle' ||
          'scriptstyle' ||
          'limits' ||
          'nolimits' ||
          'nonumber' ||
          'notag':
        return null;
      case r'\':
        // A line break where there are no lines, such as in a group.
        return null;
      case 'end':
        _fail();
      case 'label' || 'tag':
        _argument();
        return null;
      case 'color' || 'textcolor':
        _braced();
        return bare == 'color' ? null : _argument();
      case 'overset' || 'stackrel':
        final _Node over = _argument();
        return _Scripts(_argument(), sup: over);
      case 'underset':
        final _Node under = _argument();
        return _Scripts(_argument(), sub: under);
      case 'pmod':
        final _Node body = _argument();
        return _Row(<_Node>[
          const _Space(0.6),
          _Fenced(
            '(',
            _Row(<_Node>[const _Sym('mod', _Kind.op), body]),
            ')',
            stretch: false,
          ),
        ]);
    }
    // A command it does not know is written as its name.
    if (bare.isEmpty || !NotationFont.canWrite(bare)) _fail();
    return _Sym(bare, _Kind.ord);
  }

  /// The text of a `\text`-like argument, as it is written, spaces and all.
  String _plainText() {
    _skipSpace();
    if (_atEnd || _char != '{') _fail();
    _at++;
    final StringBuffer text = StringBuffer();
    int depth = 0;
    while (true) {
      if (_atEnd) _fail();
      final String c = _char;
      _at++;
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        if (depth == 0) break;
        depth--;
      } else if (c == r'\' && !_atEnd) {
        final String next = _char;
        _at++;
        if (_isLetter(next.codeUnitAt(0))) {
          final int start = _at - 1;
          while (!_atEnd && _isLetter(_char.codeUnitAt(0))) {
            _at++;
          }
          final String command = _source.substring(start, _at);
          text.write(
            _symbols[command]?.$1 ?? (command == 'backslash' ? r'\' : ''),
          );
          if (command == 'backslash' && !_atEnd && _char == ' ') _at++;
        } else {
          text.write(next == ' ' ? ' ' : next);
        }
      } else if (c == r'$') {
        // Inline math inside \text is rare; its symbols are kept.
        continue;
      } else {
        text.write(c == '\n' || c == '~' ? ' ' : c);
      }
    }
    final String written = text.toString();
    if (!NotationFont.canWrite(written)) _fail();
    return written;
  }

  _Node _blackboard(_Node letters) {
    if (letters is _Row && letters.items.length == 1) {
      return _blackboard(letters.items.single);
    }
    if (letters case _Sym(
      :final String text,
    ) when _blackboardLetters[text] != null) {
      return _Sym(_blackboardLetters[text]!, _Kind.ord);
    }
    return letters;
  }

  static const Map<String, String> _blackboardLetters = <String, String>{
    'R': 'ℝ',
    'N': 'ℕ',
    'Z': 'ℤ',
    'Q': 'ℚ',
    'C': 'ℂ',
  };

  /// The bracket after `\left`, `\right`, or `\big`: '' for `.`, none.
  String _delimiter() {
    _skipSpace();
    if (_atEnd) _fail();
    if (_char == r'\') {
      final String name = _peekCommand();
      _at += name.length;
      return switch (name) {
        r'\{' || r'\lbrace' => '{',
        r'\}' || r'\rbrace' => '}',
        r'\|' || r'\Vert' || r'\lVert' || r'\rVert' => '‖',
        r'\vert' || r'\lvert' || r'\rvert' || r'\mid' => '|',
        r'\langle' => '⟨',
        r'\rangle' => '⟩',
        r'\lfloor' || r'\lceil' => '[',
        r'\rfloor' || r'\rceil' => ']',
        _ => _fail(),
      };
    }
    final String c = _char;
    _at++;
    if (c == '.') return '';
    if (!'()[]|/'.contains(c)) _fail();
    return c;
  }

  static _Kind _delimiterKind(String delimiter, String command) {
    if (command.endsWith('l')) return _Kind.open;
    if (command.endsWith('r')) return _Kind.close;
    if (command.endsWith('m')) return _Kind.rel;
    return switch (delimiter) {
      '(' || '[' || '{' || '⟨' => _Kind.open,
      ')' || ']' || '}' || '⟩' => _Kind.close,
      _ => _Kind.ord,
    };
  }

  _Node _leftRight() {
    final String left = _delimiter();
    final ({_Row row, String? stop}) body = _row(
      stops: const <String>{r'\right'},
    );
    final String right = _delimiter();
    return _Fenced(left, body.row, right, stretch: true);
  }

  _Node _environment(String name) {
    final String base = name.endsWith('*')
        ? name.substring(0, name.length - 1)
        : name;
    _Align center(int _) => _Align.center;
    _Align left(int _) => _Align.left;
    switch (base) {
      case 'matrix' || 'smallmatrix':
        return _cells(name, align: center);
      case 'pmatrix' || 'bmatrix' || 'Bmatrix' || 'vmatrix' || 'Vmatrix':
        final (String open, String close) = switch (base) {
          'pmatrix' => ('(', ')'),
          'bmatrix' => ('[', ']'),
          'Bmatrix' => ('{', '}'),
          'vmatrix' => ('|', '|'),
          _ => ('‖', '‖'),
        };
        return _Fenced(open, _cells(name, align: center), close, stretch: true);
      case 'cases' || 'dcases':
        return _Fenced('{', _casesGrid(name), '', stretch: true);
      case 'array':
        final String spec = _braced().replaceAll(RegExp('[^lcr]'), '');
        return _cells(
          name,
          align: (int column) =>
              switch (column < spec.length ? spec[column] : 'c') {
                'l' => _Align.left,
                'r' => _Align.right,
                _ => _Align.center,
              },
        );
      case 'aligned' ||
          'align' ||
          'alignat' ||
          'split' ||
          'eqnarray' ||
          'flalign':
        if (base == 'alignat') _braced();
        return _uncentered(_cells(name, align: _alignedColumn), aligned: true);
      case 'gathered' || 'gather' || 'equation' || 'multline' || 'displaymath':
        return _uncentered(_cells(name, align: center), aligned: false);
    }
    // An environment it does not know is read as lines of working.
    return _uncentered(_cells(name, align: left), aligned: false);
  }

  _Node _casesGrid(String name) {
    final _Node cells = _cells(name, align: (int _) => _Align.left);
    if (cells is _Grid) {
      return _Grid(cells.rows, align: cells.align, columnGap: 1.2);
    }
    return cells;
  }

  /// [cells] as lines of working that hang from their first baseline.
  static _Node _uncentered(_Node cells, {required bool aligned}) {
    if (cells is! _Grid) return cells;
    return _Grid(
      cells.rows,
      align: cells.align,
      columnGap: aligned ? 0 : cells.columnGap,
      centered: false,
    );
  }

  /// Commands that name one character, and how it sits.
  static const Map<String, (String, _Kind)> _symbols =
      <String, (String, _Kind)>{
        // Greek.
        'alpha': ('α', _Kind.ord),
        'beta': ('β', _Kind.ord),
        'gamma': ('γ', _Kind.ord),
        'delta': ('δ', _Kind.ord),
        'epsilon': ('ϵ', _Kind.ord),
        'varepsilon': ('ε', _Kind.ord),
        'zeta': ('ζ', _Kind.ord),
        'eta': ('η', _Kind.ord),
        'theta': ('θ', _Kind.ord),
        'vartheta': ('ϑ', _Kind.ord),
        'iota': ('ι', _Kind.ord),
        'kappa': ('κ', _Kind.ord),
        'lambda': ('λ', _Kind.ord),
        'mu': ('μ', _Kind.ord),
        'nu': ('ν', _Kind.ord),
        'xi': ('ξ', _Kind.ord),
        'omicron': ('o', _Kind.ord),
        'pi': ('π', _Kind.ord),
        'varpi': ('ϖ', _Kind.ord),
        'rho': ('ρ', _Kind.ord),
        'varrho': ('ϱ', _Kind.ord),
        'sigma': ('σ', _Kind.ord),
        'varsigma': ('ς', _Kind.ord),
        'tau': ('τ', _Kind.ord),
        'upsilon': ('υ', _Kind.ord),
        'phi': ('ϕ', _Kind.ord),
        'varphi': ('φ', _Kind.ord),
        'chi': ('χ', _Kind.ord),
        'psi': ('ψ', _Kind.ord),
        'omega': ('ω', _Kind.ord),
        'Gamma': ('Γ', _Kind.ord),
        'Delta': ('Δ', _Kind.ord),
        'Theta': ('Θ', _Kind.ord),
        'Lambda': ('Λ', _Kind.ord),
        'Xi': ('Ξ', _Kind.ord),
        'Pi': ('Π', _Kind.ord),
        'Sigma': ('Σ', _Kind.ord),
        'Upsilon': ('Υ', _Kind.ord),
        'Phi': ('Φ', _Kind.ord),
        'Psi': ('Ψ', _Kind.ord),
        'Omega': ('Ω', _Kind.ord),
        // Binary operators.
        'pm': ('±', _Kind.bin),
        'mp': ('∓', _Kind.bin),
        'times': ('×', _Kind.bin),
        'cdot': ('·', _Kind.bin),
        'div': ('÷', _Kind.bin),
        'ast': ('∗', _Kind.bin),
        'star': ('*', _Kind.bin),
        'circ': ('∘', _Kind.bin),
        'cup': ('∪', _Kind.bin),
        'cap': ('∩', _Kind.bin),
        'setminus': ('∖', _Kind.bin),
        'wedge': ('∧', _Kind.bin),
        'land': ('∧', _Kind.bin),
        'vee': ('∨', _Kind.bin),
        'lor': ('∨', _Kind.bin),
        'oplus': ('⊕', _Kind.bin),
        'otimes': ('⊗', _Kind.bin),
        // Relations.
        'leq': ('≤', _Kind.rel),
        'le': ('≤', _Kind.rel),
        'leqslant': ('≤', _Kind.rel),
        'geq': ('≥', _Kind.rel),
        'ge': ('≥', _Kind.rel),
        'geqslant': ('≥', _Kind.rel),
        'neq': ('≠', _Kind.rel),
        'ne': ('≠', _Kind.rel),
        'approx': ('≈', _Kind.rel),
        'equiv': ('≡', _Kind.rel),
        'sim': ('∼', _Kind.rel),
        'simeq': ('≃', _Kind.rel),
        'cong': ('≅', _Kind.rel),
        'propto': ('∝', _Kind.rel),
        'll': ('≪', _Kind.rel),
        'gg': ('≫', _Kind.rel),
        'in': ('∈', _Kind.rel),
        'notin': ('∉', _Kind.rel),
        'ni': ('∋', _Kind.rel),
        'subset': ('⊂', _Kind.rel),
        'subseteq': ('⊆', _Kind.rel),
        'supset': ('⊃', _Kind.rel),
        'supseteq': ('⊇', _Kind.rel),
        'perp': ('⊥', _Kind.rel),
        'parallel': ('∥', _Kind.rel),
        'mid': ('|', _Kind.rel),
        'to': ('→', _Kind.rel),
        'rightarrow': ('→', _Kind.rel),
        'longrightarrow': ('→', _Kind.rel),
        'gets': ('←', _Kind.rel),
        'leftarrow': ('←', _Kind.rel),
        'longleftarrow': ('←', _Kind.rel),
        'Rightarrow': ('⇒', _Kind.rel),
        'Longrightarrow': ('⇒', _Kind.rel),
        'implies': ('⇒', _Kind.rel),
        'Leftarrow': ('⇐', _Kind.rel),
        'impliedby': ('⇐', _Kind.rel),
        'Leftrightarrow': ('⇔', _Kind.rel),
        'Longleftrightarrow': ('⇔', _Kind.rel),
        'iff': ('⇔', _Kind.rel),
        'leftrightarrow': ('↔', _Kind.rel),
        'mapsto': ('↦', _Kind.rel),
        'uparrow': ('↑', _Kind.rel),
        'downarrow': ('↓', _Kind.rel),
        'colon': (':', _Kind.punct),
        // Ordinary symbols.
        'infty': ('∞', _Kind.ord),
        'partial': ('∂', _Kind.ord),
        'nabla': ('∇', _Kind.ord),
        'forall': ('∀', _Kind.ord),
        'exists': ('∃', _Kind.ord),
        'nexists': ('∄', _Kind.ord),
        'emptyset': ('∅', _Kind.ord),
        'varnothing': ('∅', _Kind.ord),
        'angle': ('∠', _Kind.ord),
        'measuredangle': ('∠', _Kind.ord),
        'triangle': ('△', _Kind.ord),
        'hbar': ('ℏ', _Kind.ord),
        'ell': ('ℓ', _Kind.ord),
        'neg': ('¬', _Kind.ord),
        'lnot': ('¬', _Kind.ord),
        'prime': ('′', _Kind.ord),
        'degree': ('°', _Kind.ord),
        'checkmark': ('✓', _Kind.ord),
        'cdots': ('⋯', _Kind.inner),
        'ldots': ('…', _Kind.inner),
        'dots': ('…', _Kind.inner),
        'dotsc': ('…', _Kind.inner),
        'dotsb': ('⋯', _Kind.inner),
        'vdots': ('⋮', _Kind.ord),
        'ddots': ('⋱', _Kind.ord),
        'bot': ('⊥', _Kind.ord),
        'backslash': (r'\', _Kind.ord),
        'vert': ('|', _Kind.ord),
        'Vert': ('‖', _Kind.ord),
        '|': ('‖', _Kind.ord),
        'langle': ('⟨', _Kind.open),
        'rangle': ('⟩', _Kind.close),
        'lfloor': ('[', _Kind.open),
        'rfloor': (']', _Kind.close),
        'lceil': ('[', _Kind.open),
        'rceil': (']', _Kind.close),
        'lbrace': ('{', _Kind.open),
        'rbrace': ('}', _Kind.close),
        '{': ('{', _Kind.open),
        '}': ('}', _Kind.close),
        '%': ('%', _Kind.ord),
        r'$': (r'$', _Kind.ord),
        '#': ('#', _Kind.ord),
        '&': ('&', _Kind.ord),
        '_': ('_', _Kind.ord),
        // Also met as plain characters.
        '+': ('+', _Kind.bin),
        '×': ('×', _Kind.bin),
        '·': ('·', _Kind.bin),
        '÷': ('÷', _Kind.bin),
        '±': ('±', _Kind.bin),
        '≤': ('≤', _Kind.rel),
        '≥': ('≥', _Kind.rel),
        '≠': ('≠', _Kind.rel),
        '≈': ('≈', _Kind.rel),
        '→': ('→', _Kind.rel),
        '←': ('←', _Kind.rel),
        '∈': ('∈', _Kind.rel),
        '⇒': ('⇒', _Kind.rel),
        '⇔': ('⇔', _Kind.rel),
      };

  /// Spacing commands, in capital heights.
  static const Map<String, double> _spaces = <String, double>{
    ',': 0.17,
    'thinspace': 0.17,
    ':': 0.22,
    '>': 0.22,
    'medspace': 0.22,
    ';': 0.28,
    'thickspace': 0.28,
    '!': -0.17,
    'negthinspace': -0.17,
    ' ': 0.33,
    'quad': 1.0,
    'qquad': 2.0,
    'enspace': 0.5,
  };

  /// Functions written upright, with their arguments beside them.
  static const Set<String> _functions = <String>{
    'sin',
    'cos',
    'tan',
    'cot',
    'sec',
    'csc',
    'arcsin',
    'arccos',
    'arctan',
    'sinh',
    'cosh',
    'tanh',
    'coth',
    'log',
    'ln',
    'lg',
    'exp',
    'deg',
    'arg',
    'dim',
    'ker',
    'hom',
    'gcd',
    'lcm',
    'mod',
    'bmod',
    'sgn',
    'Re',
    'Im',
    'tr',
    'rank',
    'Var',
    'Cov',
    'E',
  };

  /// Functions whose scripts go above and below them.
  static const Set<String> _limitFunctions = <String>{
    'lim',
    'max',
    'min',
    'sup',
    'inf',
    'det',
    'Pr',
    'argmax',
    'argmin',
    'limsup',
    'liminf',
  };

  /// Big operators: the symbol, and whether its limits go above and below.
  static const Map<String, (String, bool)> _bigOps = <String, (String, bool)>{
    'sum': ('∑', true),
    'prod': ('∏', true),
    'bigcup': ('∪', true),
    'bigcap': ('∩', true),
    'bigoplus': ('⊕', true),
    'bigotimes': ('⊗', true),
    'bigvee': ('∨', true),
    'bigwedge': ('∧', true),
    'int': ('∫', false),
    'iint': ('∫∫', false),
    'iiint': ('∫∫∫', false),
    'oint': ('∮', false),
  };

  /// Accents, and whether each spans all of what it is over.
  static const Map<String, (_Accent, bool)> _accents =
      <String, (_Accent, bool)>{
        'vec': (_Accent.vec, false),
        'overrightarrow': (_Accent.vec, true),
        'hat': (_Accent.hat, false),
        'widehat': (_Accent.hat, true),
        'bar': (_Accent.bar, false),
        'overline': (_Accent.over, true),
        'underline': (_Accent.under, true),
        'dot': (_Accent.dot, false),
        'ddot': (_Accent.ddot, false),
        'tilde': (_Accent.tilde, false),
        'widetilde': (_Accent.tilde, true),
        'overleftrightarrow': (_Accent.arrow, true),
      };
}

// ---------------------------------------------------------------------------
// Laying out.

/// What a box draws: text in the font, or a pen line of its own.
sealed class _Op {
  const _Op();

  _Op moved(double dx, double dy);
}

/// [text] written [scale] capital heights tall, its first letter's left
/// edge at [x] and its baseline at [y], [width] wide.
class _Run extends _Op {
  const _Run(this.text, this.x, this.y, this.scale, this.width);

  final String text;
  final double x;
  final double y;
  final double scale;
  final double width;

  @override
  _Run moved(double dx, double dy) => _Run(text, x + dx, y + dy, scale, width);
}

class _Path extends _Op {
  const _Path(this.points);

  final List<InkVector> points;

  @override
  _Path moved(double dx, double dy) => _Path(<InkVector>[
    for (final InkVector p in points) InkVector(p.x + dx, p.y + dy),
  ]);
}

/// A laid-out piece: [width] wide from x = 0, reaching [ascent] above its
/// baseline at y = 0 and [descent] below it. y grows down.
class _Box {
  const _Box(this.width, this.ascent, this.descent, this.ops, {this.kind});

  final double width;
  final double ascent;
  final double descent;
  final List<_Op> ops;

  /// How it sits beside its neighbours, when it is one atom.
  final _Kind? kind;

  Iterable<_Op> at(double dx, double dy) =>
      ops.map((_Op op) => op.moved(dx, dy));
}

class _Layout {
  /// The height of the math axis, where fraction bars and the middle of
  /// a plus sign are, above the baseline.
  static const double axis = 0.505;

  /// The gap the font leaves between letters, in capital heights.
  static const double _letterGap =
      NotationFont.spacing / NotationFont.capHeight;

  /// How far the built-in hand leans, per unit of height.
  static final double _lean = HandwritingStyle.standard.slant;

  _Box top(_Node node) => _box(node, 1, display: true);

  _Box _box(_Node node, double scale, {required bool display}) {
    return switch (node) {
      _Sym() => _sym(node, scale),
      _Row() => _row(node.items, scale, display: display),
      _Scripts() => _scripts(node, scale, display: display),
      _Frac() => _frac(node, scale, display: display),
      _Sqrt() => _sqrt(node, scale, display: display),
      _Fenced() => _fenced(node, scale, display: display),
      _Accented() => _accented(node, scale, display: display),
      _BigOp() => _bigOp(node, scale),
      _Grid() => _grid(node, scale, display: display),
      _Space() => _Box(node.width * scale, 0, 0, const <_Op>[]),
    };
  }

  static _Box _text(String text, double scale, {_Kind? kind}) {
    double top = double.infinity;
    double bottom = double.negativeInfinity;
    for (final int rune in text.runes) {
      final ({double top, double bottom})? span = NotationFont.glyphSpan(
        String.fromCharCode(rune),
      );
      if (span == null) continue;
      top = math.min(top, span.top);
      bottom = math.max(bottom, span.bottom);
    }
    // A bar has no width in the font; it is given a little, so what
    // follows it stands clear.
    final double width =
        NotationFont.lineUnits(text) / NotationFont.capHeight * scale +
        0.1 * scale * '|'.allMatches(text).length;
    if (!top.isFinite) {
      return _Box(width, 0, 0, const <_Op>[], kind: kind);
    }
    return _Box(
      width,
      (1 - top) * scale,
      math.max(0, bottom - 1) * scale,
      <_Op>[_Run(text, 0, 0, scale, width)],
      kind: kind,
    );
  }

  _Box _sym(_Sym sym, double scale) => _text(sym.text, scale, kind: sym.kind);

  /// [items] side by side, with TeX's spacing between them and runs of
  /// letters and digits written as one word, so a joined hand joins them.
  _Box _row(List<_Node> items, double scale, {required bool display}) {
    // Neighbouring plain characters merge into one run.
    final List<_Node> merged = <_Node>[];
    for (final _Node item in items) {
      if (item is _Sym &&
          item.kind == _Kind.ord &&
          merged.isNotEmpty &&
          merged.last is _Sym &&
          (merged.last as _Sym).kind == _Kind.ord) {
        merged.last = _Sym((merged.last as _Sym).text + item.text, _Kind.ord);
      } else {
        merged.add(item);
      }
    }
    final List<_Box> boxes = <_Box>[
      for (final _Node item in merged) _box(item, scale, display: display),
    ];
    final List<_Kind> kinds = <_Kind>[
      for (int i = 0; i < boxes.length; i++) _kindOf(merged[i], boxes[i]),
    ];
    // A binary operator with nothing on its left is a sign: -x, (+1).
    for (int i = 0; i < kinds.length; i++) {
      if (kinds[i] != _Kind.bin) continue;
      final _Kind? before = _previous(kinds, merged, i);
      final _Kind? after = _next(kinds, merged, i);
      if (before == null ||
          before == _Kind.bin ||
          before == _Kind.rel ||
          before == _Kind.open ||
          before == _Kind.punct ||
          before == _Kind.op ||
          after == null) {
        kinds[i] = _Kind.ord;
      }
    }
    final List<_Op> ops = <_Op>[];
    double x = 0;
    double ascent = 0;
    double descent = 0;
    _Kind? last;
    for (int i = 0; i < boxes.length; i++) {
      final _Box box = boxes[i];
      if (merged[i] is _Space) {
        x += box.width;
        continue;
      }
      if (last != null) {
        x += _letterGap * scale + _spacing(last, kinds[i]) * scale;
      }
      ops.addAll(box.at(x, 0));
      x += box.width;
      ascent = math.max(ascent, box.ascent);
      descent = math.max(descent, box.descent);
      last = kinds[i];
    }
    final _Kind? kind = boxes.length == 1 ? kinds.single : null;
    return _Box(math.max(0, x), ascent, descent, ops, kind: kind ?? _Kind.ord);
  }

  static int? _previousIndex(List<_Node> items, int i) {
    for (int j = i - 1; j >= 0; j--) {
      if (items[j] is! _Space) return j;
    }
    return null;
  }

  static _Kind? _previous(List<_Kind> kinds, List<_Node> items, int i) {
    final int? j = _previousIndex(items, i);
    return j == null ? null : kinds[j];
  }

  static _Kind? _next(List<_Kind> kinds, List<_Node> items, int i) {
    for (int j = i + 1; j < items.length; j++) {
      if (items[j] is! _Space) return kinds[j];
    }
    return null;
  }

  static _Kind _kindOf(_Node node, _Box box) {
    return switch (node) {
      _Sym() => node.kind,
      _BigOp() => _Kind.op,
      _Scripts() => switch (node.base) {
        _BigOp() => _Kind.op,
        _Sym(kind: final _Kind kind) => kind == _Kind.bin ? _Kind.ord : kind,
        _ => _Kind.ord,
      },
      _Frac() || _Fenced() => _Kind.inner,
      _Row() => box.kind ?? _Kind.ord,
      _ => _Kind.ord,
    };
  }

  /// The space TeX puts between atoms of kinds [a] and [b], in capital
  /// heights, beyond the gap between letters.
  static double _spacing(_Kind a, _Kind b) {
    const double thin = 0.17;
    const double medium = 0.22;
    const double thick = 0.28;
    if (a == _Kind.bin || b == _Kind.bin) return medium;
    if (a == _Kind.rel || b == _Kind.rel) {
      return a == b ? 0 : thick;
    }
    if (a == _Kind.punct) return thin;
    if (a == _Kind.op &&
        (b == _Kind.ord || b == _Kind.op || b == _Kind.inner)) {
      return thin;
    }
    if (b == _Kind.op &&
        (a == _Kind.ord || a == _Kind.close || a == _Kind.inner)) {
      return thin;
    }
    if (a == _Kind.inner && b != _Kind.close && b != _Kind.punct) {
      return thin * 0.5;
    }
    if (b == _Kind.inner && a != _Kind.open) return thin * 0.5;
    return 0;
  }

  /// How much smaller each level of scripts is, and the smallest they get.
  static double _scriptScale(double scale) => math.max(0.42, scale * 0.68);

  _Box _scripts(_Scripts node, double scale, {required bool display}) {
    final _Box base = _box(node.base, scale, display: display);
    final double small = _scriptScale(scale);
    final _Box? sup = node.sup == null
        ? null
        : _box(node.sup!, small, display: false);
    final _Box? sub = node.sub == null
        ? null
        : _box(node.sub!, small, display: false);
    final bool limits = switch (node.base) {
      _BigOp(limits: final bool limits) => limits && display,
      _Sym(limits: final bool limits) => limits,
      _ => false,
    };
    if (limits) return _limits(base, sup, sub, scale);

    final double baseAscent = math.max(base.ascent, 0.62 * scale);
    double up = math.max(0.45 * scale, baseAscent - 0.4 * scale);
    double down = math.max(0.24 * scale, base.descent - 0.12 * scale);
    if (node.base is _BigOp) {
      // An integral's limits sit at its ends.
      up = base.ascent - (sup?.ascent ?? 0) * 0.6;
      down = base.descent - (sub?.descent ?? 0) - 0.1 * scale;
    }
    if (sup != null && sub != null) {
      final double gap = (down - sub.ascent) - (sup.descent - up);
      if (gap < 0.16 * scale) down += 0.16 * scale - gap;
    }
    final double x = base.width + (node.base is _BigOp ? 0.02 : 0.08) * scale;
    // Letters lean, so the top of the base reaches further right than its
    // foot: the exponent stands clear of it.
    final double supX =
        x + math.min(0.15 * scale, _lean * math.max(0, base.ascent));
    final double width = math.max(
      x + (sub?.width ?? 0),
      supX + (sup?.width ?? 0),
    );
    return _Box(
      width,
      math.max(base.ascent, sup == null ? 0 : up + sup.ascent),
      math.max(base.descent, sub == null ? 0 : down + sub.descent),
      <_Op>[
        ...base.ops,
        if (sup != null) ...sup.at(supX, -up),
        if (sub != null)
          ...sub.at(node.base is _BigOp ? x - 0.3 * scale : x, down),
      ],
      kind: base.kind,
    );
  }

  /// [base] with [over] centred above it and [under] below, as the limits
  /// of a sum or `\lim` are.
  _Box _limits(_Box base, _Box? over, _Box? under, double scale) {
    final double gap = 0.18 * scale;
    final double width = math.max(
      base.width,
      math.max(over?.width ?? 0, under?.width ?? 0),
    );
    double centre(_Box box) => (width - box.width) / 2;
    return _Box(
      width,
      base.ascent + (over == null ? 0 : gap + over.descent + over.ascent),
      base.descent + (under == null ? 0 : gap + under.ascent + under.descent),
      <_Op>[
        ...base.at(centre(base), 0),
        if (over != null)
          ...over.at(centre(over), -base.ascent - gap - over.descent),
        if (under != null)
          ...under.at(centre(under), base.descent + gap + under.ascent),
      ],
      kind: _Kind.op,
    );
  }

  _Box _frac(_Frac node, double scale, {required bool display}) {
    // A fraction in a fraction, or in a script, is written smaller.
    final double inner = display
        ? scale
        : math.min(scale, math.max(0.5, scale * 0.8));
    final _Box top = _box(node.top, inner, display: false);
    final _Box bottom = _box(node.bottom, inner, display: false);
    final double gap = (node.bar ? 0.2 : 0.3) * scale;
    final double pad = 0.12 * scale;
    final double width = math.max(top.width, bottom.width) + 2 * pad;
    final double bar = -axis * scale;
    final double topBaseline = bar - gap - top.descent;
    final double bottomBaseline = bar + gap + bottom.ascent;
    return _Box(
      width,
      -topBaseline + top.ascent,
      bottomBaseline + bottom.descent,
      <_Op>[
        ...top.at((width - top.width) / 2, topBaseline),
        if (node.bar)
          _Path(<InkVector>[
            InkVector(pad * 0.4, bar),
            InkVector(width - pad * 0.4, bar),
          ]),
        ...bottom.at((width - bottom.width) / 2, bottomBaseline),
      ],
      kind: _Kind.inner,
    );
  }

  _Box _sqrt(_Sqrt node, double scale, {required bool display}) {
    final _Box body = _box(node.body, scale, display: display);
    final double bodyAscent = math.max(body.ascent, 0.7 * scale);
    final double bodyDescent = math.max(body.descent, 0.05 * scale);
    final double top = -(bodyAscent + 0.2 * scale);
    final double bottom = bodyDescent + 0.08 * scale;
    final double height = bottom - top;
    final double sign = math.min(0.85 * scale, 0.45 * scale + 0.08 * height);
    final double bodyX = sign + 0.12 * scale;
    final double end = bodyX + body.width + 0.1 * scale;
    double shift = 0;
    final List<_Op> index = <_Op>[];
    if (node.index != null) {
      final _Box box = _box(
        node.index!,
        math.max(0.42, scale * 0.55),
        display: false,
      );
      // The index sits in the crook of the radical.
      final double right = sign * 0.5;
      final double baseline = bottom - height * 0.5 - 0.06 * scale;
      shift = math.max(0, box.width - right);
      index.addAll(box.at(right - box.width + shift, baseline - box.descent));
    }
    return _Box(end + shift, -top, bottom, <_Op>[
      ...index,
      _Path(<InkVector>[
        InkVector(shift, bottom - height * 0.4),
        InkVector(shift + sign * 0.22, bottom - height * 0.46),
        InkVector(shift + sign * 0.55, bottom),
        InkVector(shift + sign, top),
        InkVector(shift + end, top),
      ]),
      ...body.at(shift + bodyX, 0),
    ], kind: _Kind.ord);
  }

  _Box _fenced(_Fenced node, double scale, {required bool display}) {
    final _Box body = _box(node.body, scale, display: display);
    final bool tall = body.ascent > 1.08 * scale || body.descent > 0.4 * scale;
    if (!node.stretch && !tall) {
      // The font's own brackets, round a body already laid out.
      final _Box? left = node.left.isEmpty ? null : _text(node.left, scale);
      final _Box? right = node.right.isEmpty ? null : _text(node.right, scale);
      final double gap = _letterGap * scale;
      final double bodyX = left == null ? 0 : left.width + gap;
      final double rightX = bodyX + body.width + (right == null ? 0 : gap);
      return _Box(
        rightX + (right?.width ?? 0),
        math.max(body.ascent, math.max(left?.ascent ?? 0, right?.ascent ?? 0)),
        math.max(
          body.descent,
          math.max(left?.descent ?? 0, right?.descent ?? 0),
        ),
        <_Op>[...?left?.ops, ...body.at(bodyX, 0), ...?right?.at(rightX, 0)],
        kind: _Kind.inner,
      );
    }
    // Brackets as tall as what they hold, centred on the axis.
    final double centre = -axis * scale;
    final double half =
        math.max(body.ascent - axis * scale, body.descent + axis * scale) +
        0.12 * scale;
    final double top = centre - math.max(half, 0.65 * scale);
    final double bottom = centre + math.max(half, 0.65 * scale);
    final _Box? left = node.left.isEmpty
        ? null
        : _bracket(node.left, top, bottom, scale, right: false);
    final _Box? right = node.right.isEmpty
        ? null
        : _bracket(node.right, top, bottom, scale, right: true);
    final double gap = 0.1 * scale;
    final double bodyX = (left?.width ?? 0) + (left == null ? 0 : gap);
    final double rightX = bodyX + body.width + gap;
    return _Box(
      rightX + (right?.width ?? 0),
      math.max(body.ascent, -top),
      math.max(body.descent, bottom),
      <_Op>[...?left?.ops, ...body.at(bodyX, 0), ...?right?.at(rightX, 0)],
      kind: _Kind.inner,
    );
  }

  /// [delimiter] drawn from [top] to [bottom]: on the right of what it
  /// holds when [right], so facing left.
  static _Box _bracket(
    String delimiter,
    double top,
    double bottom,
    double scale, {
    required bool right,
  }) {
    final double height = bottom - top;
    final double middle = (top + bottom) / 2;
    final double width = switch (delimiter) {
      '(' || ')' => math.min(0.55 * scale, 0.2 * scale + 0.1 * height),
      '[' || ']' => 0.32 * scale,
      '{' || '}' => 0.42 * scale,
      '⟨' || '⟩' => math.min(0.5 * scale, 0.22 * scale + 0.08 * height),
      '‖' => 0.22 * scale,
      _ => 0.06 * scale,
    };
    // Drawn as the left one, then mirrored for the right.
    final List<List<InkVector>> lines = switch (delimiter) {
      '(' || ')' => <List<InkVector>>[
        _cubic(
          InkVector(width, top),
          InkVector(-width * 0.15, top + height * 0.22),
          InkVector(-width * 0.15, bottom - height * 0.22),
          InkVector(width, bottom),
        ),
      ],
      '[' || ']' => <List<InkVector>>[
        <InkVector>[
          InkVector(width, top),
          InkVector(0, top),
          InkVector(0, bottom),
          InkVector(width, bottom),
        ],
      ],
      '{' || '}' => <List<InkVector>>[
        <InkVector>[
          ..._cubic(
            InkVector(width, top),
            InkVector(width * 0.35, top),
            InkVector(width * 0.5, middle - height * 0.05),
            InkVector(0, middle),
          ),
          ..._cubic(
            InkVector(0, middle),
            InkVector(width * 0.5, middle + height * 0.05),
            InkVector(width * 0.35, bottom),
            InkVector(width, bottom),
          ).skip(1),
        ],
      ],
      '⟨' || '⟩' => <List<InkVector>>[
        <InkVector>[
          InkVector(width, top),
          InkVector(0, middle),
          InkVector(width, bottom),
        ],
      ],
      '‖' => <List<InkVector>>[
        <InkVector>[InkVector(0, top), InkVector(0, bottom)],
        <InkVector>[InkVector(width, top), InkVector(width, bottom)],
      ],
      '/' => <List<InkVector>>[
        <InkVector>[InkVector(width, top), InkVector(0, bottom)],
      ],
      _ => <List<InkVector>>[
        <InkVector>[InkVector(width / 2, top), InkVector(width / 2, bottom)],
      ],
    };
    final bool mirror = right && delimiter != '/';
    return _Box(width, -top, bottom, <_Op>[
      for (final List<InkVector> line in lines)
        _Path(<InkVector>[
          for (final InkVector p in line)
            mirror ? InkVector(width - p.x, p.y) : p,
        ]),
    ]);
  }

  static List<InkVector> _cubic(
    InkVector a,
    InkVector b,
    InkVector c,
    InkVector d,
  ) {
    const int steps = 12;
    return <InkVector>[
      for (int i = 0; i <= steps; i++)
        () {
          final double t = i / steps;
          final double u = 1 - t;
          return a * (u * u * u) +
              b * (3 * u * u * t) +
              c * (3 * u * t * t) +
              d * (t * t * t);
        }(),
    ];
  }

  _Box _accented(_Accented node, double scale, {required bool display}) {
    final _Box body = _box(node.body, scale, display: display);
    final double bodyTop = math.max(body.ascent, 0.62 * scale);
    if (node.accent == _Accent.under) {
      final double y = body.descent + 0.14 * scale;
      return _Box(body.width, body.ascent, y, <_Op>[
        ...body.ops,
        _Path(<InkVector>[InkVector(0, y), InkVector(body.width, y)]),
      ], kind: body.kind);
    }
    final double y = -(bodyTop + 0.2 * scale);
    final double span = node.wide || node.accent == _Accent.over
        ? body.width
        : math.min(body.width, 0.55 * scale);
    final double left = (body.width - span) / 2;
    final double right = left + span;
    final double middle = (left + right) / 2;
    final double rise = 0.22 * scale;
    final List<List<InkVector>> marks = switch (node.accent) {
      _Accent.vec || _Accent.arrow => <List<InkVector>>[
        <InkVector>[InkVector(left, y), InkVector(right, y)],
        <InkVector>[
          InkVector(right - 0.16 * scale, y - 0.12 * scale),
          InkVector(right, y),
          InkVector(right - 0.16 * scale, y + 0.12 * scale),
        ],
        if (node.accent == _Accent.arrow)
          <InkVector>[
            InkVector(left + 0.16 * scale, y - 0.12 * scale),
            InkVector(left, y),
            InkVector(left + 0.16 * scale, y + 0.12 * scale),
          ],
      ],
      _Accent.hat => <List<InkVector>>[
        <InkVector>[
          InkVector(left, y + rise * 0.4),
          InkVector(middle, y - rise * 0.6),
          InkVector(right, y + rise * 0.4),
        ],
      ],
      _Accent.bar || _Accent.over => <List<InkVector>>[
        <InkVector>[InkVector(left, y), InkVector(right, y)],
      ],
      _Accent.dot => <List<InkVector>>[
        <InkVector>[InkVector(middle, y)],
      ],
      _Accent.ddot => <List<InkVector>>[
        <InkVector>[InkVector(middle - 0.12 * scale, y)],
        <InkVector>[InkVector(middle + 0.12 * scale, y)],
      ],
      _Accent.tilde => <List<InkVector>>[
        <InkVector>[
          for (int i = 0; i <= 8; i++)
            InkVector(
              left + span * i / 8,
              y - 0.08 * scale * math.sin(i / 8 * 2 * math.pi),
            ),
        ],
      ],
      _Accent.under => const <List<InkVector>>[],
    };
    return _Box(body.width, -y + 0.14 * scale, body.descent, <_Op>[
      ...body.ops,
      for (final List<InkVector> mark in marks) _Path(mark),
    ], kind: body.kind);
  }

  _Box _bigOp(_BigOp node, double scale) {
    // Written larger than the text and centred on the axis.
    final double size = scale * (node.limits ? 1.45 : 1.7);
    final _Box glyph = _text(node.symbol, size);
    final ({double top, double bottom})? span = NotationFont.glyphSpan(
      String.fromCharCode(node.symbol.runes.first),
    );
    final double middle = span == null ? 0.5 : (span.top + span.bottom) / 2;
    // The baseline that puts the glyph's middle on the axis.
    final double baseline = -axis * scale - (middle - 1) * size;
    return _Box(
      glyph.width,
      glyph.ascent - baseline,
      glyph.descent + baseline,
      glyph.at(0, baseline).toList(),
      kind: _Kind.op,
    );
  }

  _Box _grid(_Grid grid, double scale, {required bool display}) {
    final List<List<_Box>> cells = <List<_Box>>[
      for (final List<_Node> row in grid.rows)
        <_Box>[
          for (int column = 0; column < row.length; column++)
            _cell(row[column], column, grid, scale, display: display),
        ],
    ];
    final int columns = cells.fold<int>(
      0,
      (int most, List<_Box> row) => math.max(most, row.length),
    );
    final List<double> widths = List<double>.filled(columns, 0);
    for (final List<_Box> row in cells) {
      for (int column = 0; column < row.length; column++) {
        widths[column] = math.max(widths[column], row[column].width);
      }
    }
    // Aligned columns come in pairs, the right one against the left; pairs
    // are set apart.
    double gapBefore(int column) {
      if (column == 0) return 0;
      if (grid.columnGap > 0) return grid.columnGap * scale;
      return column.isEven ? 1.2 * scale : 0;
    }

    final List<double> lefts = <double>[];
    double x = 0;
    for (int column = 0; column < columns; column++) {
      x += gapBefore(column);
      lefts.add(x);
      x += widths[column];
    }
    final double width = x;
    // Lines of working are spaced like lines of text; a matrix or cases
    // stays compact.
    final double leading = grid.centered ? 0.32 * scale : 0.7 * scale;
    final List<_Op> ops = <_Op>[];
    double y = 0;
    double firstAscent = 0;
    double lastDescent = 0;
    for (int r = 0; r < cells.length; r++) {
      final List<_Box> row = cells[r];
      final double ascent = row.fold<double>(
        0.75 * scale,
        (double most, _Box cell) => math.max(most, cell.ascent),
      );
      final double descent = row.fold<double>(
        0.25 * scale,
        (double most, _Box cell) => math.max(most, cell.descent),
      );
      if (r == 0) {
        firstAscent = ascent;
      } else {
        y += ascent;
      }
      for (int column = 0; column < row.length; column++) {
        final _Box cell = row[column];
        final double free = widths[column] - cell.width;
        final double offset = switch (grid.align(column)) {
          _Align.left => 0,
          _Align.center => free / 2,
          _Align.right => free,
        };
        ops.addAll(cell.at(lefts[column] + offset, y));
      }
      lastDescent = descent;
      y += descent + leading;
    }
    final double lastBaseline = y - leading - lastDescent;
    if (!grid.centered) {
      return _Box(width, firstAscent, lastBaseline + lastDescent, ops);
    }
    final double height = firstAscent + lastBaseline + lastDescent;
    final double shift = -axis * scale - (height / 2 - firstAscent);
    return _Box(
      width,
      firstAscent - shift,
      lastBaseline + lastDescent + shift,
      <_Op>[for (final _Op op in ops) op.moved(0, shift)],
      kind: _Kind.inner,
    );
  }

  _Box _cell(
    _Node node,
    int column,
    _Grid grid,
    double scale, {
    required bool display,
  }) {
    // In aligned working, the right half of a pair starts with its
    // relation, spaced as if what it relates were before it.
    if (grid.columnGap == 0 && column.isOdd) {
      return _row(
        <_Node>[
          const _Sym('', _Kind.ord),
          if (node is _Row) ...node.items else node,
        ],
        scale,
        display: display,
      );
    }
    return _box(node, scale, display: display);
  }
}
