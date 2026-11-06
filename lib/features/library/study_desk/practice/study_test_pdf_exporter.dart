import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../study_desk_models.dart';
import 'study_practice_models.dart';

/// The paper a test is laid out for, in the sizes the note exporter uses.
enum StudyTestPaperSize {
  a4('A4'),
  letter('US Letter');

  const StudyTestPaperSize(this.label);

  final String label;

  PdfPageFormat get format => switch (this) {
    StudyTestPaperSize.a4 => PdfPageFormat.a4,
    StudyTestPaperSize.letter => const PdfPageFormat(612, 792),
  };
}

/// What fills the space left for a written answer.
enum StudyTestRuling {
  ruled('Ruled Lined'),
  grid('Grid / Graph'),
  dotGrid('Dot Grid'),
  blankBox('Blank Box');

  const StudyTestRuling(this.label);

  final String label;
}

/// How much room a written answer gets.
enum StudyTestAnswerHeight {
  small('Small'),
  medium('Medium'),
  large('Large'),
  fullPage('Full Page');

  const StudyTestAnswerHeight(this.label);

  final String label;
}

/// How a test is printed.
@immutable
class StudyTestOptions {
  const StudyTestOptions({
    this.paper = StudyTestPaperSize.a4,
    this.ruling = StudyTestRuling.ruled,
    this.answerHeight = StudyTestAnswerHeight.medium,
    this.includeAnswerKey = true,
    this.scratchMargin = false,
  });

  final StudyTestPaperSize paper;
  final StudyTestRuling ruling;
  final StudyTestAnswerHeight answerHeight;
  final bool includeAnswerKey;

  /// Whether a ruled-off column for scratch work runs beside each question of
  /// Part I.
  final bool scratchMargin;
}

/// Draws [text] as a PNG [widthPt] wide, for what the PDF's built-in fonts have
/// no glyphs for. Returns the picture and its height in points.
typedef StudyTestTextRasterizer =
    Future<({Uint8List png, double heightPt})> Function(
      String text, {
      required double widthPt,
      required double fontSize,
      required bool bold,
    });

/// A note's title, for naming where an answer comes from.
typedef StudyTestReference = String? Function(StudyCitation citation);

/// [source], Markdown with LaTeX, as text for a printed page. The Greek letters,
/// operators, and scripts of ordinary maths come out as their characters;
/// anything further is written out in line.
String studyTestPlainText(String source) {
  String text = source;
  // Fractions first, from the innermost, while their braces are still there.
  final RegExp fraction = RegExp(r'\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}');
  for (int i = 0; i < 8 && fraction.hasMatch(text); i++) {
    text = text.replaceAllMapped(fraction, (Match m) {
      String part(String value) => RegExp(r'^[\w.]+$').hasMatch(value.trim())
          ? value.trim()
          : '(${value.trim()})';
      return '${part(m[1]!)}/${part(m[2]!)}';
    });
  }
  text = text.replaceAllMapped(
    RegExp(r'\\sqrt\s*\{([^{}]*)\}'),
    (Match m) => '√(${m[1]})',
  );
  text = text.replaceAllMapped(
    RegExp(r'\\(?:text|mathrm|mathbf|mathit|operatorname)\s*\{([^{}]*)\}'),
    (Match m) => m[1]!,
  );
  // A command says it is maths wherever it is: models leave off the dollars.
  _latexSymbols.forEach((String command, String symbol) {
    text = text.replaceAll(RegExp('\\\\$command(?![A-Za-z])'), symbol);
  });
  text = text
      .replaceAll(RegExp(r'\\[,;:!]| ?\\quad ?| ?\\qquad ?'), ' ')
      .replaceAll(RegExp(r'\\(?:left|right)'), '');
  // Scripts and bare braces mean something only between dollars: outside them
  // are snake_case, a blank to fill in, and a set written {a, b}. A dollar with
  // no partner is money.
  text = text.replaceAllMapped(
    RegExp(r'\$\$([^$]+)\$\$|\$([^$\n]+)\$'),
    (Match m) => _mathToText(m[1] ?? m[2]!),
  );
  text = text
      .replaceAll(r'\{', '{')
      .replaceAll(r'\}', '}')
      .replaceAll(r'\%', '%')
      .replaceAll(r'\_', '_')
      .replaceAll(r'\&', '&')
      .replaceAll(r'\#', '#')
      .replaceAll(r'\$', r'$')
      .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (Match m) => m[1]!)
      .replaceAllMapped(RegExp(r'__([^_\s][^_]*)__'), (Match m) => m[1]!)
      .replaceAll('`', '')
      .replaceAllMapped(
        RegExp(r'(^|[\s(])\*([^*\s][^*]*)\*'),
        (Match m) => '${m[1]}${m[2]}',
      )
      .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"')
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '-')
      .replaceAll('\u2026', '...');
  return text.trim();
}

/// What is left of LaTeX between dollars, its commands already written out.
String _mathToText(String math) {
  const String open = '\u0001';
  const String close = '\u0002';
  return math
      .replaceAll(r'\{', open)
      .replaceAll(r'\}', close)
      .replaceAllMapped(
        RegExp(r'([\^_])\{([^{}]*)\}|([\^_])([A-Za-z0-9+\-])'),
        (Match m) => _script(m[2] ?? m[4]!, (m[1] ?? m[3]) == '^'),
      )
      .replaceAll(RegExp(r'[{}]'), '')
      .replaceAll(open, '{')
      .replaceAll(close, '}');
}

const Map<String, String> _latexSymbols = <String, String>{
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'epsilon': 'ε',
  'varepsilon': 'ε',
  'zeta': 'ζ',
  'eta': 'η',
  'theta': 'θ',
  'iota': 'ι',
  'kappa': 'κ',
  'lambda': 'λ',
  'mu': 'μ',
  'nu': 'ν',
  'xi': 'ξ',
  'pi': 'π',
  'rho': 'ρ',
  'sigma': 'σ',
  'tau': 'τ',
  'upsilon': 'υ',
  'phi': 'φ',
  'varphi': 'φ',
  'chi': 'χ',
  'psi': 'ψ',
  'omega': 'ω',
  'Gamma': 'Γ',
  'Delta': 'Δ',
  'Theta': 'Θ',
  'Lambda': 'Λ',
  'Pi': 'Π',
  'Sigma': 'Σ',
  'Phi': 'Φ',
  'Psi': 'Ψ',
  'Omega': 'Ω',
  'times': '×',
  'cdot': '·',
  'div': '÷',
  'pm': '±',
  'mp': '∓',
  'leq': '≤',
  'le': '≤',
  'geq': '≥',
  'ge': '≥',
  'neq': '≠',
  'ne': '≠',
  'approx': '≈',
  'equiv': '≡',
  'sim': '~',
  'to': '→',
  'rightarrow': '→',
  'leftarrow': '←',
  'Rightarrow': '⇒',
  'Leftarrow': '⇐',
  'leftrightarrow': '↔',
  'infty': '∞',
  'partial': '∂',
  'nabla': '∇',
  'int': '∫',
  'sum': 'Σ',
  'prod': 'Π',
  'in': '∈',
  'notin': '∉',
  'subset': '⊂',
  'subseteq': '⊆',
  'cup': '∪',
  'cap': '∩',
  'forall': '∀',
  'exists': '∃',
  'degree': '°',
  'circ': '°',
  'ldots': '...',
  'dots': '...',
  'cdots': '...',
  'sin': 'sin',
  'cos': 'cos',
  'tan': 'tan',
  'log': 'log',
  'ln': 'ln',
  'lim': 'lim',
  'exp': 'exp',
};

const Map<String, String> _superscripts = <String, String>{
  '0': '⁰',
  '1': '¹',
  '2': '²',
  '3': '³',
  '4': '⁴',
  '5': '⁵',
  '6': '⁶',
  '7': '⁷',
  '8': '⁸',
  '9': '⁹',
  '+': '⁺',
  '-': '⁻',
  'n': 'ⁿ',
};

const Map<String, String> _subscripts = <String, String>{
  '0': '₀',
  '1': '₁',
  '2': '₂',
  '3': '₃',
  '4': '₄',
  '5': '₅',
  '6': '₆',
  '7': '₇',
  '8': '₈',
  '9': '₉',
  '+': '₊',
  '-': '₋',
};

String _script(String body, bool up) {
  final Map<String, String> table = up ? _superscripts : _subscripts;
  final StringBuffer out = StringBuffer();
  for (final int rune in body.runes) {
    final String? mapped = table[String.fromCharCode(rune)];
    if (mapped == null) return up ? '^($body)' : '_($body)';
    out.write(mapped);
  }
  return out.toString();
}

/// Lays a practice set out as a printable test.
class StudyTestPdfExporter {
  const StudyTestPdfExporter({
    this.rasterizeText = rasterizeStudyTestText,
    this.compress = true,
    this.clock = DateTime.now,
  });

  final StudyTestTextRasterizer rasterizeText;

  /// Off only so that a test can read what the document says.
  final bool compress;
  final DateTime Function() clock;

  /// Room left around the page, and for the page number.
  static const double margin = 54;
  static const double footerHeight = 24;

  /// The distance between lines, as on a ruled page of a note.
  static const double ruleSpacing = 24;
  static const double gridSpacing = 18;
  static const PdfColor ruleColor = PdfColor.fromInt(0xFFD0D0D0);

  static const double _bodySize = 11;
  static const double _bubble = 12;
  static const double _scratchWidth = 110;

  /// The height of an answer space, within a page [usable] points tall. A
  /// question that takes a drawing is given room to draw in.
  static double answerHeightOf(
    StudyTestAnswerHeight height, {
    required double usable,
    bool diagram = false,
  }) {
    final double room = switch (height) {
      StudyTestAnswerHeight.small => 3 * ruleSpacing,
      StudyTestAnswerHeight.medium => 6 * ruleSpacing,
      StudyTestAnswerHeight.large => usable / 2,
      // What a short question leaves of a page of its own.
      StudyTestAnswerHeight.fullPage => usable - 96,
    };
    return diagram ? math.max(room, 9 * ruleSpacing) : room;
  }

  /// The page height a page's content has.
  static double usableHeight(PdfPageFormat format) =>
      format.height - margin * 2 - footerHeight;

  /// [set] as a printed test. [subject] names the course; [referenceOf] gives a
  /// citation's note title for the answer key.
  Future<Uint8List> export(
    StudyPracticeSet set, {
    StudyTestOptions options = const StudyTestOptions(),
    String subject = '',
    StudyTestReference? referenceOf,
  }) async {
    final PdfPageFormat format = options.paper.format;
    final double width = format.width - margin * 2;
    final List<pw.Widget> body = <pw.Widget>[
      ...await _header(set, subject, width),
      ...await _partOne(set, options, width),
      ...await _partTwo(set, options, format, width),
      if (options.includeAnswerKey)
        ...await _answerKey(set, referenceOf, width),
    ];
    final pw.Document document = pw.Document(
      compress: compress,
      title: set.title,
      creator: 'Etonia',
    );
    document.addPage(
      pw.MultiPage(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(margin),
        maxPages: 200,
        footer: (pw.Context context) => pw.SizedBox(
          height: footerHeight,
          child: pw.Align(
            alignment: pw.Alignment.bottomRight,
            child: pw.Text(
              'Page ${context.pageNumber} of ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ),
        ),
        build: (pw.Context _) => body,
      ),
    );
    return document.save();
  }

  /// Whether the PDF's built-in font can write [text].
  static bool _writable(String text) =>
      text.runes.every((int rune) => rune < 0x100);

  /// [source] as words on the page: real text where the built-in fonts have the
  /// glyphs, and otherwise a picture of it, set by the platform's own fonts.
  Future<pw.Widget> _text(
    String source, {
    required double width,
    double size = _bodySize,
    bool bold = false,
    bool italic = false,
    PdfColor color = PdfColors.black,
  }) async {
    final String text = studyTestPlainText(source);
    if (_writable(text)) {
      return pw.SizedBox(
        width: width,
        child: pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: size,
            color: color,
            lineSpacing: 2,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
          ),
        ),
      );
    }
    final ({Uint8List png, double heightPt}) picture = await rasterizeText(
      text,
      widthPt: width,
      fontSize: size,
      bold: bold,
    );
    return pw.Image(
      pw.MemoryImage(picture.png),
      width: width,
      height: picture.heightPt,
      fit: pw.BoxFit.fill,
    );
  }

  Future<List<pw.Widget>> _header(
    StudyPracticeSet set,
    String subject,
    double width,
  ) async {
    const double scoreWidth = 150;
    final DateTime now = clock();
    final String date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return <pw.Widget>[
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          await _text(
            set.title,
            width: width - scoreWidth - 12,
            size: 20,
            bold: true,
          ),
          pw.SizedBox(width: 12),
          pw.Container(
            width: scoreWidth,
            padding: const pw.EdgeInsets.all(6),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey800, width: 0.8),
            ),
            child: pw.Text(
              'Score: [ _____ / ${set.totalQuestions} pts ]',
              style: const pw.TextStyle(fontSize: 10),
            ),
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Text('Date: $date', style: const pw.TextStyle(fontSize: 10)),
      if (subject.trim().isNotEmpty) ...<pw.Widget>[
        pw.SizedBox(height: 4),
        await _text('Course / Subject: $subject', width: width, size: 10),
      ],
      pw.SizedBox(height: 10),
      pw.Text(
        'Name: __________________________',
        style: const pw.TextStyle(fontSize: 11),
      ),
      pw.SizedBox(height: 10),
      pw.Text(
        'Read each question carefully. For written responses, show all work '
        'in the designated lined area.',
        style: const pw.TextStyle(
          fontSize: 10,
          fontStyle: pw.FontStyle.italic,
          color: PdfColors.grey800,
        ),
      ),
      pw.SizedBox(height: 6),
      pw.Divider(thickness: 0.8, color: PdfColors.grey800),
    ];
  }

  pw.Widget _partHeading(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 12, bottom: 8),
    child: pw.Text(
      text,
      style: const pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
    ),
  );

  Future<List<pw.Widget>> _partOne(
    StudyPracticeSet set,
    StudyTestOptions options,
    double width,
  ) async {
    if (set.multipleChoiceQuestions.isEmpty) return const <pw.Widget>[];
    final double column = options.scratchMargin
        ? width - _scratchWidth - 10
        : width;
    const double numberWidth = 22;
    const double optionIndent = numberWidth + _bubble + 8;
    final List<pw.Widget> out = <pw.Widget>[
      _partHeading('Part I: Multiple Choice Questions'),
    ];
    for (int i = 0; i < set.multipleChoiceQuestions.length; i++) {
      final PracticeMultipleChoice question = set.multipleChoiceQuestions[i];
      final pw.Widget block = pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              pw.SizedBox(
                width: numberWidth,
                child: pw.Text(
                  '${i + 1}.',
                  style: const pw.TextStyle(
                    fontSize: _bodySize,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              await _text(question.question, width: column - numberWidth),
            ],
          ),
          pw.SizedBox(height: 6),
          for (final PracticeChoiceOption option in question.options)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: numberWidth, bottom: 5),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: <pw.Widget>[
                  pw.Container(
                    width: _bubble,
                    height: _bubble,
                    margin: const pw.EdgeInsets.only(right: 8),
                    decoration: pw.BoxDecoration(
                      shape: pw.BoxShape.circle,
                      border: pw.Border.all(
                        color: PdfColors.grey800,
                        width: 0.8,
                      ),
                    ),
                  ),
                  await _text(
                    '${option.id}. ${option.text}',
                    width: column - optionIndent,
                  ),
                ],
              ),
            ),
        ],
      );
      final int characters =
          question.question.length +
          question.options.fold<int>(
            0,
            (int sum, PracticeChoiceOption option) => sum + option.text.length,
          );
      // Kept together, unless it is so long it might not fit on a page. A column
      // beside it would not let it run on to the next.
      final bool fits = characters < 1800;
      final pw.Widget row = options.scratchMargin && fits
          ? pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: <pw.Widget>[
                pw.SizedBox(width: column, child: block),
                pw.SizedBox(width: 10),
                pw.Container(
                  width: _scratchWidth,
                  height: 88,
                  decoration: const pw.BoxDecoration(
                    border: pw.Border(
                      left: pw.BorderSide(color: ruleColor, width: 0.6),
                    ),
                  ),
                ),
              ],
            )
          : block;
      out.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: fits ? pw.Inseparable(child: row) : row,
        ),
      );
    }
    return out;
  }

  Future<List<pw.Widget>> _partTwo(
    StudyPracticeSet set,
    StudyTestOptions options,
    PdfPageFormat format,
    double width,
  ) async {
    if (set.flashcards.isEmpty) return const <pw.Widget>[];
    const double numberWidth = 22;
    final double usable = usableHeight(format);
    final List<pw.Widget> out = <pw.Widget>[
      // A page each: the part's heading goes with the first of them.
      if (options.answerHeight == StudyTestAnswerHeight.fullPage) pw.NewPage(),
      _partHeading('Part II: Free Response, Problem Solving & Diagrams'),
    ];
    final int first = set.multipleChoiceQuestions.length;
    for (int i = 0; i < set.flashcards.length; i++) {
      final PracticeFlashcard card = set.flashcards[i];
      final double height = answerHeightOf(
        options.answerHeight,
        usable: usable,
        diagram: card.isDiagram,
      );
      final pw.Widget prompt = pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.SizedBox(
            width: numberWidth,
            child: pw.Text(
              '${first + i + 1}.',
              style: const pw.TextStyle(
                fontSize: _bodySize,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          await _text(card.frontPrompt, width: width - numberWidth),
        ],
      );
      final pw.Widget space = _answerSpace(
        width: width,
        height: height,
        ruling: options.ruling,
        diagram: card.isDiagram,
      );
      final bool ownPage =
          options.answerHeight == StudyTestAnswerHeight.fullPage;
      // Generous for type this size, so what is kept together surely fits.
      final double promptEstimate =
          (card.frontPrompt.length / (width / (_bodySize * 0.45))).ceil() *
          _bodySize *
          1.6;
      final pw.Widget column = pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[prompt, pw.SizedBox(height: 8), space],
      );
      out
        ..add(ownPage && i > 0 ? pw.NewPage() : pw.SizedBox(height: 0))
        ..add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 14),
            child: promptEstimate + height + 30 < usable
                ? pw.Inseparable(child: column)
                : column,
          ),
        );
    }
    return out;
  }

  /// The room left for a written answer.
  static pw.Widget _answerSpace({
    required double width,
    required double height,
    required StudyTestRuling ruling,
    required bool diagram,
  }) {
    // A drawing wants no lines to write along: dots, unless it was asked to
    // have a grid.
    final StudyTestRuling drawn = diagram && ruling != StudyTestRuling.grid
        ? StudyTestRuling.dotGrid
        : ruling;
    return pw.CustomPaint(
      size: PdfPoint(width, height),
      painter: (PdfGraphics canvas, PdfPoint size) {
        canvas
          ..setStrokeColor(ruleColor)
          ..setLineWidth(0.5);
        switch (drawn) {
          case StudyTestRuling.ruled:
            _paintRules(canvas, size);
          case StudyTestRuling.grid:
            _paintGrid(canvas, size);
            _paintBox(canvas, size);
          case StudyTestRuling.dotGrid:
            _paintDots(canvas, size);
            _paintBox(canvas, size);
          case StudyTestRuling.blankBox:
            _paintBox(canvas, size);
        }
      },
    );
  }

  static void _paintRules(PdfGraphics canvas, PdfPoint size) {
    // PDF measures up from the bottom: the first line is one rule from the top.
    const double guide = 28;
    for (double y = size.y - ruleSpacing; y >= 0; y -= ruleSpacing) {
      canvas
        ..drawLine(0, y, size.x, y)
        ..strokePath();
    }
    canvas
      ..drawLine(guide, 0, guide, size.y)
      ..strokePath();
  }

  static void _paintGrid(PdfGraphics canvas, PdfPoint size) {
    for (double x = gridSpacing; x < size.x; x += gridSpacing) {
      canvas
        ..drawLine(x, 0, x, size.y)
        ..strokePath();
    }
    for (double y = gridSpacing; y < size.y; y += gridSpacing) {
      canvas
        ..drawLine(0, y, size.x, y)
        ..strokePath();
    }
  }

  static void _paintDots(PdfGraphics canvas, PdfPoint size) {
    canvas.setFillColor(ruleColor);
    for (double x = gridSpacing; x < size.x; x += gridSpacing) {
      for (double y = gridSpacing; y < size.y; y += gridSpacing) {
        canvas
          ..drawEllipse(x, y, 0.7, 0.7)
          ..fillPath();
      }
    }
  }

  static void _paintBox(PdfGraphics canvas, PdfPoint size) {
    canvas
      ..drawRect(0, 0, size.x, size.y)
      ..strokePath();
  }

  Future<List<pw.Widget>> _answerKey(
    StudyPracticeSet set,
    StudyTestReference? referenceOf,
    double width,
  ) async {
    Future<pw.Widget?> reference(StudyCitation? citation) async {
      final String? title = citation == null
          ? null
          : referenceOf?.call(citation);
      if (citation == null || title == null) return null;
      return _text(
        'Ref: Note "$title", Page ${citation.pageIndex + 1}',
        width: width,
        size: 9,
        italic: true,
        color: PdfColors.grey700,
      );
    }

    const double gap = 8;
    final List<pw.Widget> out = <pw.Widget>[
      pw.NewPage(),
      pw.Text(
        'Part III: Answer Key',
        style: const pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
      ),
      pw.SizedBox(height: 10),
    ];
    for (int i = 0; i < set.multipleChoiceQuestions.length; i++) {
      final PracticeMultipleChoice question = set.multipleChoiceQuestions[i];
      out
        ..add(
          pw.Text(
            '${i + 1}. ${question.correctOptionId}',
            style: const pw.TextStyle(
              fontSize: _bodySize,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        )
        ..add(
          question.explanation.isEmpty
              ? pw.SizedBox(height: 0)
              : await _text(question.explanation, width: width, size: 10),
        );
      final pw.Widget? cited = await reference(question.sourceCitation);
      if (cited != null) out.add(cited);
      out.add(pw.SizedBox(height: gap));
    }
    final int first = set.multipleChoiceQuestions.length;
    for (int i = 0; i < set.flashcards.length; i++) {
      final PracticeFlashcard card = set.flashcards[i];
      out
        ..add(
          pw.Text(
            '${first + i + 1}.',
            style: const pw.TextStyle(
              fontSize: _bodySize,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        )
        ..add(await _text(card.backAnswer, width: width));
      if (card.explanation.isNotEmpty) {
        out.add(
          await _text(
            card.explanation,
            width: width,
            size: 10,
            color: PdfColors.grey800,
          ),
        );
      }
      if (card.diagramCrop case final Uint8List crop) {
        out.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 4),
            child: pw.Image(
              pw.MemoryImage(crop),
              width: width / 2,
              height: 150,
              fit: pw.BoxFit.contain,
              alignment: pw.Alignment.centerLeft,
            ),
          ),
        );
      }
      final pw.Widget? cited = await reference(card.sourceCitation);
      if (cited != null) out.add(cited);
      out.add(pw.SizedBox(height: gap));
    }
    return out;
  }
}

/// Sets [text] with the platform's fonts, which reach scripts the PDF's built-in
/// fonts do not, as a PNG three times the size it prints at.
Future<({Uint8List png, double heightPt})> rasterizeStudyTestText(
  String text, {
  required double widthPt,
  required double fontSize,
  required bool bold,
}) async {
  const double scale = 3;
  final ui.ParagraphBuilder builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: fontSize,
            height: 1.35,
            fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
          ),
        )
        ..pushStyle(ui.TextStyle(color: const ui.Color(0xFF000000)))
        ..addText(text);
  final ui.Paragraph paragraph = builder.build()
    ..layout(ui.ParagraphConstraints(width: widthPt));
  final double height = math.max(paragraph.height, 1);
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..scale(scale)
    ..drawParagraph(paragraph, ui.Offset.zero);
  final ui.Picture picture = recorder.endRecording();
  paragraph.dispose();
  final ui.Image image = await picture.toImage(
    (widthPt * scale).ceil(),
    (height * scale).ceil(),
  );
  picture.dispose();
  final ByteData? bytes = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return (png: bytes!.buffer.asUint8List(), heightPt: height);
}
