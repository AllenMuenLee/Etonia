import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/ai/notation_font.dart';
import 'package:greatnote/features/editor/ai/notation_layout.dart';
import 'package:greatnote/features/editor/ai/notation_math.dart';
import 'package:greatnote/features/editor/handwriting/handwriting_style.dart';
import 'package:greatnote/features/editor/ink/ink_notation.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';

const double _size = 20;

/// [latex] written with its first baseline at y = 0, so that what lies
/// above and below it can be compared.
List<List<InkVector>> _write(
  String latex, {
  HandwritingStyle style = HandwritingStyle.standard,
}) {
  final NotationMath math = NotationMath.parse(latex);
  return math.write(
    origin: InkVector(0, -math.ascent * _size),
    size: _size,
    style: style,
  );
}

Rect _bounds(Iterable<List<InkVector>> strokes) {
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final List<InkVector> stroke in strokes) {
    for (final InkVector p in stroke) {
      left = math.min(left, p.x);
      top = math.min(top, p.y);
      right = math.max(right, p.x);
      bottom = math.max(bottom, p.y);
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

Rect _of(String latex) => _bounds(_write(latex));

void main() {
  group('reads', () {
    // The notation of school and university mathematics and science.
    const List<String> notation = <String>[
      r'x_i',
      r'x_{n+1}',
      r'a_{ij}^2',
      r'\hat{x}',
      r'\hat{\beta}_1',
      r'\bar{x}',
      r'\bar{x}^2',
      r'\sigma_{\bar{x}}',
      r'\vec{F} = m\vec{a}',
      r'\dot{x}',
      r'\ddot{\theta}',
      r'\tilde{y}',
      r'\overline{AB}',
      r'\underline{x}',
      r'\widehat{ABC}',
      r'\overrightarrow{AB}',
      "f'(x)",
      "f''(x)",
      r'\frac{a}{b}',
      r'\dfrac{1}{2}',
      r'\sqrt{x}',
      r'\sqrt[3]{x}',
      r'\binom{n}{k}',
      r'\sum_{i=1}^{n} i',
      r'\prod_{k=1}^{n} k',
      r'\int_0^1 x\,dx',
      r'\iint_D f\,dA',
      r'\oint_C \vec{F} \cdot d\vec{r}',
      r'\lim_{x \to \infty} \frac{1}{x} = 0',
      r'\max_{x} f(x)',
      r'\left( \frac{a}{b} \right)',
      r'\left[ x \right]',
      r'\left\{ x \right\}',
      r'\left| x \right|',
      r'\left\langle u, v \right\rangle',
      r'\left. \frac{dy}{dx} \right|_{x=0}',
      r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
      r'\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}',
      r'\begin{vmatrix} a & b \\ c & d \end{vmatrix}',
      r'\begin{cases} 1 & x > 0 \\ 0 & \text{otherwise} \end{cases}',
      r'\begin{aligned} x &= 1 \\ y &= 2 \end{aligned}',
      r'\begin{array}{cc} 1 & 2 \end{array}',
      r'a \\ b',
      r'\alpha \beta \gamma \delta \epsilon \varepsilon \zeta \eta \theta '
          r'\vartheta \iota \kappa \lambda \mu \nu \xi \pi \rho \sigma \tau '
          r'\upsilon \phi \varphi \chi \psi \omega',
      r'\Gamma \Delta \Theta \Lambda \Xi \Pi \Sigma \Upsilon \Phi \Psi \Omega',
      r'\pm \mp \times \cdot \div \circ \cup \cap \setminus \wedge \vee '
          r'\oplus \otimes',
      r'\leq \geq \neq \approx \equiv \sim \simeq \cong \propto \ll \gg',
      r'\in \notin \ni \subset \subseteq \supset \supseteq \perp \parallel',
      r'\to \rightarrow \leftarrow \Rightarrow \Leftarrow \Leftrightarrow '
          r'\leftrightarrow \mapsto \implies \iff \uparrow \downarrow',
      r'\infty \partial \nabla \forall \exists \nexists \emptyset \angle '
          r'\hbar \ell \neg \prime \degree',
      r'\cdots \ldots \vdots \ddots',
      r'\mathbb{R} \mathbb{N} \mathbb{Z} \mathbb{Q} \mathbb{C}',
      r'\mathrm{d}x \mathbf{v} \operatorname{sgn}(x)',
      r'\text{speed } = \frac{d}{t}',
      r'\sin^2 \theta + \cos^2 \theta = 1',
      r'\log_2 8 = 3',
      r'90^\circ',
      r'\Delta G^\circ = -RT \ln K',
      r'\frac{\partial^2 u}{\partial t^2} = c^2 \nabla^2 u',
      r'x \not= y',
      r'a \equiv b \pmod{n}',
      r'E = mc^2 \quad F = ma \qquad p = mv',
      r'\displaystyle \sum_{n=0}^\infty \frac{x^n}{n!}',
      r'$x^2$',
      r'$$x^2$$',
      r'\(x^2\)',
      r'\[x^2\]',
    ];
    for (final String latex in notation) {
      test(latex, () {
        final NotationMath math = NotationMath.parse(latex);
        expect(math.width, greaterThan(0));
        expect(math.height, greaterThan(0));
        expect(_write(latex), isNotEmpty);
      });
    }

    test('throws for what it cannot read', () {
      for (final String latex in <String>[
        r'\frac{a}{b',
        r'x^',
        r'{x',
        r'x}',
        r'\left( x',
        r'\begin{pmatrix} a \end{bmatrix}',
        r'\sqrt[3{x}',
        '',
        '  ',
        'x ☃',
      ]) {
        expect(
          () => NotationMath.parse(latex),
          throwsFormatException,
          reason: latex,
        );
      }
      expect(
        () => NotationMath.parse('x' * (NotationMath.maxLength + 1)),
        throwsFormatException,
      );
    });

    test('nests deeply without failing, but not without end', () {
      expect(
        NotationMath.parse(r'\frac{1}{1+\frac{1}{1+\frac{1}{1+x}}}').height,
        greaterThan(3),
      );
      expect(
        () => NotationMath.parse('${'{' * 40}x${'}' * 40}'),
        throwsFormatException,
      );
    });

    test('writes a command it does not know as its name', () {
      expect(
        NotationMath.parse(r'\foo').width,
        NotationMath.parse('foo').width,
      );
    });
  });

  group('lays out', () {
    test('raises and shrinks a superscript', () {
      final Rect base = _of('x');
      final Rect raised = _of('x^2');
      expect(raised.top, lessThan(base.top - _size * 0.2));
      expect(raised.bottom, closeTo(base.bottom, 1));
      expect(raised.width, lessThan(base.width * 2.2));
    });

    test('lowers a subscript', () {
      final Rect base = _of('x');
      final Rect lowered = _of('x_i');
      expect(lowered.bottom, greaterThan(base.bottom + _size * 0.15));
      expect(lowered.top, closeTo(base.top, 1));
    });

    test('stacks a superscript over a subscript', () {
      final Rect both = _of('x_i^2');
      expect(both.width, lessThan(_of('x_i2').width));
      expect(both.top, lessThan(_of('x').top));
      expect(both.bottom, greaterThan(_of('x').bottom));
    });

    test('puts accents over what they mark', () {
      final Rect base = _of('x');
      for (final String accent in <String>[
        'hat',
        'bar',
        'vec',
        'dot',
        'ddot',
        'tilde',
        'widehat',
        'overline',
      ]) {
        final Rect marked = _of('\\$accent{x}');
        expect(marked.top, lessThan(base.top - 2), reason: accent);
        expect(marked.bottom, closeTo(base.bottom, 1), reason: accent);
        expect(marked.left, greaterThan(base.left - 3), reason: accent);
        expect(marked.right, lessThan(base.right + 3), reason: accent);
      }
      expect(_of(r'\underline{x}').bottom, greaterThan(base.bottom + 1));
    });

    test('keeps a subscript beside an accent', () {
      final Rect hat = _of(r'\hat{x}');
      final Rect both = _of(r'\hat{x}_i');
      expect(both.top, closeTo(hat.top, 0.5));
      expect(both.bottom, greaterThan(hat.bottom + _size * 0.15));
    });

    test('a bar over many letters spans them', () {
      final List<List<InkVector>> strokes = _write(r'\overline{ABC}');
      final Rect letters = _of('ABC');
      final List<InkVector> bar = strokes.last;
      expect(bar.first.y, lessThan(letters.top));
      expect(bar.last.x - bar.first.x, greaterThan(letters.width * 0.8));
    });

    test('stacks a fraction over a bar on the math axis', () {
      final NotationMath fraction = NotationMath.parse(r'\frac{a}{b}');
      final Rect a = _of('a');
      final Rect stacked = _of(r'\frac{a}{b}');
      expect(stacked.height, greaterThan(a.height * 2));
      expect(fraction.width, lessThan(NotationMath.parse('a/b').width));
      // The bar lies flat, between the two.
      final List<InkVector> bar = _write(
        r'\frac{a}{b}',
      ).firstWhere((List<InkVector> s) => s.length >= 2 && _isFlat(s));
      final double y = bar.first.y;
      expect(y, greaterThan(stacked.top + 2));
      expect(y, lessThan(stacked.bottom - 2));
    });

    test('centres the shorter half of a fraction', () {
      final List<List<InkVector>> strokes = _write(r'\frac{1}{abcdef}');
      final Rect all = _bounds(strokes);
      final Rect one = _bounds(<List<InkVector>>[
        for (final List<InkVector> s in strokes)
          if (s.every((InkVector p) => p.y < all.center.dy - 3)) s,
      ]);
      expect(one.center.dx, closeTo(all.center.dx, _size * 0.3));
    });

    test('a nested fraction is smaller', () {
      final double outer = NotationMath.parse(r'\frac{a}{b}').height;
      final double inner = NotationMath.parse(r'\frac{\frac{a}{b}}{c}').height;
      expect(inner, lessThan(outer * 2));
    });

    test('a radical reaches over what it holds', () {
      final Rect body = _of('x+1');
      final Rect root = _of(r'\sqrt{x+1}');
      expect(root.top, lessThan(body.top - 2));
      expect(root.width, greaterThan(body.width + _size * 0.4));
      expect(_of(r'\sqrt[3]{x+1}').width, greaterThanOrEqualTo(root.width));
    });

    test('brackets grow round a tall body', () {
      final Rect plain = _of('(x)');
      final Rect tall = _of(r'\left( \frac{a}{b} \right)');
      final Rect fraction = _of(r'\frac{a}{b}');
      expect(tall.top, lessThanOrEqualTo(fraction.top));
      expect(tall.bottom, greaterThanOrEqualTo(fraction.bottom));
      expect(tall.height, greaterThan(plain.height));
      // Plain brackets grow too, once what they hold is taller than a line.
      expect(_of(r'(\frac{a}{b})').height, closeTo(tall.height, 2));
    });

    test('puts the limits of a sum above and below it', () {
      final Rect sum = _of(r'\sum');
      final Rect limited = _of(r'\sum_{i=1}^{n}');
      expect(limited.top, lessThan(sum.top - 4));
      expect(limited.bottom, greaterThan(sum.bottom + 4));
      expect(limited.width, lessThan(sum.width * 2.5));
      expect(_of(r'\lim_{x \to 0}').bottom, greaterThan(_of('lim').bottom + 4));
    });

    test('puts the limits of an integral beside it', () {
      final Rect integral = _of(r'\int');
      final Rect limited = _of(r'\int_0^1');
      expect(limited.width, greaterThan(integral.width + 3));
    });

    test('lays a matrix out in rows and columns', () {
      final NotationMath one = NotationMath.parse(
        r'\begin{pmatrix} a \end{pmatrix}',
      );
      final NotationMath four = NotationMath.parse(
        r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
      );
      expect(four.height, greaterThan(one.height * 1.4));
      expect(four.width, greaterThan(one.width * 1.4));
    });

    test('lines up working on its relations', () {
      final List<List<InkVector>> strokes = _write(
        r'\begin{aligned} 2x + 3 &= 7 \\ x &= 2 \end{aligned}',
      );
      // Each line's equals sign: the last short flat strokes in each half,
      // after the plus sign.
      final Rect all = _bounds(strokes);
      double equalsLeft(bool upper) {
        double left = double.negativeInfinity;
        for (final List<InkVector> s in strokes) {
          if (!_isFlat(s) || _bounds(<List<InkVector>>[s]).width > _size) {
            continue;
          }
          if ((s.first.y < all.center.dy) != upper) continue;
          left = math.max(left, math.min(s.first.x, s.last.x));
        }
        return left;
      }

      expect(equalsLeft(true), closeTo(equalsLeft(false), 1.5));
    });

    test('spaces relations and operators', () {
      expect(
        NotationMath.parse('a=b').width,
        greaterThan(NotationMath.parse('ab').width + 0.5),
      );
      // A sign is not spaced as an operator is.
      expect(
        NotationMath.parse('-x').width,
        lessThan(NotationMath.parse('y-x').width - 0.4),
      );
    });

    test('measures what it writes', () {
      for (final String latex in <String>[
        r'x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}',
        r'\sum_{i=1}^{n} i^2',
        r'\begin{pmatrix} a & b \\ c & d \end{pmatrix}',
      ]) {
        final NotationMath math = NotationMath.parse(latex);
        final Rect drawn = _bounds(_write(latex));
        final double top = -math.ascent * _size;
        expect(drawn.left, greaterThan(-1), reason: latex);
        expect(drawn.top, greaterThan(top - _size * 0.1), reason: latex);
        expect(drawn.right, lessThan(math.width * _size + 4), reason: latex);
        expect(
          drawn.bottom,
          lessThan(top + math.height * _size + 2),
          reason: latex,
        );
      }
    });

    test('lays out the same every time', () {
      const String latex = r'\hat{\beta}_1 = \frac{\sum x_i y_i}{\sum x_i^2}';
      expect(_write(latex), _write(latex));
    });

    test('draws its bars and radicals in the calibrated hand', () {
      const HandwritingStyle leaning = HandwritingStyle(slant: 0.3);
      final List<List<InkVector>> standard = _write(r'\sqrt{x}');
      final List<List<InkVector>> calibrated = _write(
        r'\sqrt{x}',
        style: leaning,
      );
      expect(calibrated, isNot(standard));
      // The radical's rising stroke leans further with the hand.
      expect(_bounds(calibrated).right, greaterThan(_bounds(standard).right));
    });

    test('writes every symbol it names in the font', () {
      for (final String char in <String>[
        'α',
        'β',
        'γ',
        'δ',
        'ε',
        'ϵ',
        'ζ',
        'η',
        'ι',
        'κ',
        'λ',
        'μ',
        'ν',
        'ξ',
        'ρ',
        'σ',
        'ς',
        'τ',
        'υ',
        'φ',
        'ϕ',
        'χ',
        'ψ',
        'ω',
        'Γ',
        'Θ',
        'Λ',
        'Ξ',
        'Π',
        'Σ',
        'Υ',
        'Φ',
        'Ψ',
        'Ω',
        '∂',
        '∇',
        '∀',
        '∃',
        '∅',
        '∈',
        '∉',
        '⊂',
        '⊆',
        '∪',
        '∩',
        '≡',
        '∼',
        '∝',
        '⇒',
        '⇔',
        '↦',
        '⋯',
        '…',
        '∫',
        '∑',
        '∏',
        'ℝ',
        'ℕ',
        'ℤ',
        'ℚ',
        'ℂ',
        'ℏ',
        'ℓ',
        '′',
        '−',
      ]) {
        expect(NotationFont.canWrite(char), isTrue, reason: char);
        expect(NotationFont.glyphSpan(char), isNotNull, reason: char);
      }
    });
  });

  group('text', () {
    test('finds LaTeX in plain text', () {
      expect(NotationMath.hasMath(r'Area = $\pi r^2$'), isTrue);
      expect(NotationMath.hasMath(r'costs $5 or $6'), isFalse);
      expect(NotationMath.hasMath('plain words'), isFalse);
    });

    test('keeps the words round it', () {
      final String latex = NotationMath.fromText(r'Area = $\pi r^2$ cm');
      expect(latex, r'\text{Area = }{\pi r^2}\text{ cm}');
      expect(NotationMath.parse(latex).width, greaterThan(5));
      expect(NotationMath.fromText('a {b}\nc'), r'\text{a \{b\}} \\ \text{c}');
    });
  });

  group('notation', () {
    String response(Map<String, Object?> item) => jsonEncode(<String, Object?>{
      'version': 2,
      'message': 'm',
      'notation': <String, Object?>{
        'label': 'L',
        'coordinate_space': 'note_normalized',
        'items': <Object?>[item],
      },
    });

    test('reads a math item', () {
      final AiAssistantResponse parsed = AiAssistantResponse.parse(
        response(<String, Object?>{
          'type': 'math',
          'latex': r'\bar{x} = \frac{1}{n}\sum_{i=1}^{n} x_i',
          'x': 0.1,
          'y': 0.2,
          'size': 20,
          'ink': 'blue',
          'width': 2,
        }),
      );
      final AiNotationMath item =
          parsed.notation!.items.single as AiNotationMath;
      expect(item.math.source, r'\bar{x} = \frac{1}{n}\sum_{i=1}^{n} x_i');
      expect(item.toJson()['latex'], item.math.source);
    });

    test('reads LaTeX left unescaped in the JSON', () {
      // \f and \b are JSON escapes a model writes when it means \frac and
      // \bar.
      final AiAssistantResponse parsed = AiAssistantResponse.parse(
        '{"version":2,"message":"m","notation":{"label":"L",'
        '"coordinate_space":"note_normalized","items":[{"type":"math",'
        r'"latex":"\frac{1}{2} \bar{x} \theta","x":0.1,"y":0.1,"size":20,'
        '"ink":"blue","width":2}]}}',
      );
      final AiNotationMath item =
          parsed.notation!.items.single as AiNotationMath;
      expect(item.math.source, r'\frac{1}{2} \bar{x} \theta');
    });

    test('drops a notation whose math cannot be read', () {
      final AiAssistantResponse parsed = AiAssistantResponse.parse(
        response(<String, Object?>{
          'type': 'math',
          'latex': r'\frac{1}{',
          'x': 0.1,
          'y': 0.2,
          'size': 20,
          'ink': 'blue',
          'width': 2,
        }),
      );
      expect(parsed.notation, isNull);
      expect(parsed.notationRejected, isTrue);
    });

    test('lays out LaTeX a model put in a text item', () {
      for (final String text in <String>[
        r'Mean: $\bar{x} = 4$',
        r'x = \frac{1}{2}',
      ]) {
        final AiAssistantResponse parsed = AiAssistantResponse.parse(
          response(<String, Object?>{
            'type': 'text',
            'text': text,
            'x': 0.1,
            'y': 0.2,
            'size': 20,
            'ink': 'blue',
            'width': 2,
          }),
        );
        expect(
          parsed.notation!.items.single,
          isA<AiNotationMath>(),
          reason: text,
        );
      }
    });

    test('keeps plain text as text', () {
      final AiAssistantResponse parsed = AiAssistantResponse.parse(
        response(<String, Object?>{
          'type': 'text',
          'text': r'c = 5, costs $5',
          'x': 0.1,
          'y': 0.2,
          'size': 20,
          'ink': 'blue',
          'width': 2,
        }),
      );
      expect(parsed.notation!.items.single, isA<AiNotationText>());
    });

    test('draws a math item where it was put, kept on the paper', () {
      const Size note = Size(800, 600);
      AiNotationMath at(double x, double y) => AiNotationMath(
        math: NotationMath.parse(r'\frac{a+b}{c} = \sqrt{x^2+y^2}'),
        x: x,
        y: y,
        size: 24,
        ink: 'blue',
        width: 2,
      );
      Rect drawn(AiNotationMath item) {
        final List<GeneratedInkTrace> traces = layoutNotation(
          AiNotation(label: 'L', items: <AiNotationItem>[item]),
          note,
        );
        return _bounds(traces.map((GeneratedInkTrace t) => t.points));
      }

      final Rect placed = drawn(at(0.2, 0.3));
      expect(placed.left, closeTo(160, 3));
      expect(placed.top, closeTo(180, 6));
      final Rect kept = drawn(at(0.97, 0.98));
      expect(kept.right, lessThan(note.width));
      expect(kept.bottom, lessThan(note.height));
    });

    test('is timed by how much it writes', () {
      final AiNotationMath short = AiNotationMath(
        math: NotationMath.parse('x'),
        x: 0.1,
        y: 0.1,
        size: 20,
        ink: 'blue',
        width: 2,
      );
      final AiNotationMath long = AiNotationMath(
        math: NotationMath.parse(r'\sum_{i=1}^{n} \frac{x_i - \bar{x}}{n}'),
        x: 0.1,
        y: 0.5,
        size: 20,
        ink: 'blue',
        width: 2,
      );
      final AiNotationTimeline timeline = AiNotationTimeline.fromSteps(
        <AiNotationItem>[short, long],
        <int>[1, 2],
      );
      final AiItemTiming a = timeline.items[0];
      final AiItemTiming b = timeline.items[1];
      expect(b.endMs - b.startMs, greaterThan(a.endMs - a.startMs));
    });

    test('is in the response schema, which stays within the server limit', () {
      final String schema = jsonEncode(aiResponseJsonSchema());
      expect(schema, contains('"math"'));
      expect(utf8.encode(schema).length, lessThan(64000));
    });
  });
}

bool _isFlat(List<InkVector> stroke) {
  final Rect box = _bounds(<List<InkVector>>[stroke]);
  return box.width > 3 && box.height < box.width * 0.2;
}
