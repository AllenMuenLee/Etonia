import 'dart:math' as math;

/// A formula in x, such as `x^2 - 2x + 1` or `2 sin(x) + 1`, read once and
/// then worked out for any x.
///
/// It is arithmetic only, never code: numbers, `x`, `+ - * / ^` and
/// parentheses, `pi` and `e`, and the functions in [functions]. A number,
/// `x`, a constant, a function, or a parenthesis written straight after
/// another multiplies it, so `2x`, `3(x + 1)`, and `x sin(x)` work. `^`
/// binds tighter than a leading minus, so `-x^2` is `-(x^2)`.
class NotationFormula {
  NotationFormula._(this._root, this.source);

  /// Reads [source]. Throws a [FormatException] for anything it cannot
  /// read, without quoting it.
  factory NotationFormula.parse(String source) {
    if (source.length > maxLength) {
      throw const FormatException('Formula too long');
    }
    final _Parser parser = _Parser(_tokenize(source));
    final _Node root = parser.expression(0);
    if (!parser.atEnd) {
      throw const FormatException('Unreadable formula');
    }
    return NotationFormula._(root, source);
  }

  static const int maxLength = 160;
  static const int _maxDepth = 40;

  /// The functions a formula may use, each of one argument.
  static final Map<String, double Function(double)> functions =
      <String, double Function(double)>{
        'sin': math.sin,
        'cos': math.cos,
        'tan': math.tan,
        'asin': math.asin,
        'acos': math.acos,
        'atan': math.atan,
        'sinh': (double v) => (math.exp(v) - math.exp(-v)) / 2,
        'cosh': (double v) => (math.exp(v) + math.exp(-v)) / 2,
        'tanh': (double v) {
          final double a = math.exp(v);
          final double b = math.exp(-v);
          return (a - b) / (a + b);
        },
        'sqrt': math.sqrt,
        'abs': (double v) => v.abs(),
        'ln': math.log,
        'log': (double v) => math.log(v) / math.ln10,
        'exp': math.exp,
        'floor': (double v) => v.floorToDouble(),
        'ceil': (double v) => v.ceilToDouble(),
      };

  static const Map<String, double> _constants = <String, double>{
    'pi': math.pi,
    'π': math.pi,
    'e': math.e,
  };

  final _Node _root;

  /// The formula as it was given.
  final String source;

  /// The formula's value at [x]. Not finite where it is undefined, such as
  /// `sqrt(x)` for x below 0.
  double evaluate(double x) => _root.evaluate(x);

  static List<_Token> _tokenize(String source) {
    // Names, longest first, so that `sinh` is not read as `sin` then `h`.
    final List<String> names = <String>[
      ...functions.keys,
      ..._constants.keys,
      'x',
    ]..sort((String a, String b) => b.length.compareTo(a.length));
    final List<_Token> tokens = <_Token>[];
    int i = 0;
    while (i < source.length) {
      final String char = source[i];
      if (char.trim().isEmpty) {
        i++;
        continue;
      }
      final Match? number = _number.matchAsPrefix(source, i);
      if (number != null) {
        final double? value = double.tryParse(number[0]!);
        if (value == null || !value.isFinite) {
          throw const FormatException('Unreadable number');
        }
        tokens.add(_Token.number(value));
        i = number.end;
        continue;
      }
      if (source.startsWith('**', i)) {
        tokens.add(const _Token.operator('^'));
        i += 2;
        continue;
      }
      final String? operator = switch (char) {
        '+' => '+',
        '-' || '−' => '-',
        '*' || '×' || '·' => '*',
        '/' || '÷' => '/',
        '^' => '^',
        '(' || '[' => '(',
        ')' || ']' => ')',
        _ => null,
      };
      if (operator != null) {
        tokens.add(_Token.operator(operator));
        i++;
        continue;
      }
      String? name;
      for (final String candidate in names) {
        if (source.startsWith(candidate, i) ||
            source.substring(i).toLowerCase().startsWith(candidate)) {
          name = candidate;
          break;
        }
      }
      if (name == null) {
        throw const FormatException('Unknown name in formula');
      }
      tokens.add(_Token.name(name));
      i += name.length;
    }
    if (tokens.isEmpty) {
      throw const FormatException('Empty formula');
    }
    return tokens;
  }

  static final RegExp _number = RegExp(r'(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?');
}

enum _Kind { number, name, operator }

class _Token {
  const _Token.number(this.value) : kind = _Kind.number, text = '';
  const _Token.name(this.text) : kind = _Kind.name, value = 0;
  const _Token.operator(this.text) : kind = _Kind.operator, value = 0;

  final _Kind kind;
  final String text;
  final double value;

  bool isOperator(String operator) {
    return kind == _Kind.operator && text == operator;
  }

  /// Whether this token can start a factor, and so multiplies whatever
  /// stands before it.
  bool get startsFactor {
    return kind == _Kind.number || kind == _Kind.name || isOperator('(');
  }
}

/// A recursive descent parser:
///
/// ```text
/// expression := term (('+' | '-') term)*
/// term       := unary (('*' | '/') unary | factor-start unary)*
/// unary      := ('-' | '+') unary | power
/// power      := primary ('^' unary)?
/// primary    := number | 'x' | constant | '(' expression ')'
///             | function ('(' expression ')' | power)
/// ```
class _Parser {
  _Parser(this._tokens);

  final List<_Token> _tokens;
  int _next = 0;

  bool get atEnd => _next >= _tokens.length;

  _Token? get _peek => atEnd ? null : _tokens[_next];

  bool _peekIs(String operator) => _peek?.isOperator(operator) ?? false;

  _Token _take() {
    if (atEnd) {
      throw const FormatException('Formula ends too soon');
    }
    return _tokens[_next++];
  }

  static void _guard(int depth) {
    if (depth > NotationFormula._maxDepth) {
      throw const FormatException('Formula nested too deeply');
    }
  }

  _Node expression(int depth) {
    _guard(depth);
    _Node node = _term(depth + 1);
    while (_peekIs('+') || _peekIs('-')) {
      final String operator = _take().text;
      node = _Binary(operator, node, _term(depth + 1));
    }
    return node;
  }

  _Node _term(int depth) {
    _guard(depth);
    _Node node = _unary(depth + 1);
    while (true) {
      final _Token? token = _peek;
      if (token == null) {
        return node;
      }
      if (token.isOperator('*') || token.isOperator('/')) {
        _take();
        node = _Binary(token.text, node, _unary(depth + 1));
      } else if (token.startsFactor) {
        node = _Binary('*', node, _unary(depth + 1));
      } else {
        return node;
      }
    }
  }

  _Node _unary(int depth) {
    _guard(depth);
    final _Token? token = _peek;
    if (token != null && (token.isOperator('-') || token.isOperator('+'))) {
      _take();
      final _Node operand = _unary(depth + 1);
      return token.text == '-' ? _Negate(operand) : operand;
    }
    return _power(depth + 1);
  }

  _Node _power(int depth) {
    _guard(depth);
    final _Node base = _primary(depth + 1);
    if (_peekIs('^')) {
      _take();
      return _Binary('^', base, _unary(depth + 1));
    }
    return base;
  }

  _Node _primary(int depth) {
    _guard(depth);
    final _Token token = _take();
    switch (token.kind) {
      case _Kind.number:
        return _Constant(token.value);
      case _Kind.name:
        if (token.text == 'x') {
          return const _Variable();
        }
        final double? constant = NotationFormula._constants[token.text];
        if (constant != null) {
          return _Constant(constant);
        }
        // A function. With parentheses, they hold the whole argument, so
        // `sin(x)^2` squares the sine. Without, it takes a power, so
        // `sin x^2` is the sine of x squared.
        return _Call(
          NotationFormula.functions[token.text]!,
          _peekIs('(') ? _primary(depth + 1) : _power(depth + 1),
        );
      case _Kind.operator:
        if (token.text != '(') {
          throw const FormatException('Unexpected operator in formula');
        }
        final _Node inner = expression(depth + 1);
        if (!_take().isOperator(')')) {
          throw const FormatException('Unclosed parenthesis in formula');
        }
        return inner;
    }
  }
}

sealed class _Node {
  const _Node();

  double evaluate(double x);
}

class _Constant extends _Node {
  const _Constant(this.value);

  final double value;

  @override
  double evaluate(double x) => value;
}

class _Variable extends _Node {
  const _Variable();

  @override
  double evaluate(double x) => x;
}

class _Negate extends _Node {
  const _Negate(this.operand);

  final _Node operand;

  @override
  double evaluate(double x) => -operand.evaluate(x);
}

class _Call extends _Node {
  const _Call(this.function, this.argument);

  final double Function(double) function;
  final _Node argument;

  @override
  double evaluate(double x) => function(argument.evaluate(x));
}

class _Binary extends _Node {
  const _Binary(this.operator, this.left, this.right);

  final String operator;
  final _Node left;
  final _Node right;

  @override
  double evaluate(double x) {
    final double a = left.evaluate(x);
    final double b = right.evaluate(x);
    return switch (operator) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      '/' => a / b,
      _ => math.pow(a, b).toDouble(),
    };
  }
}
