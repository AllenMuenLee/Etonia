/// Sizes of the AI assistant panel.
class AiLayoutConfig {
  const AiLayoutConfig({
    this.panelWidth = 360,
    this.minEditorWidth = 280,
    this.sheetMaxWidthFraction = 0.88,
    this.previewMaxHeight = 160,
    this.composerMaxLines = 4,
  });

  /// Width of the panel beside the editor, and the most a compact side
  /// sheet takes.
  final double panelWidth;

  /// What a panel beside the editor always leaves for the page and palette:
  /// enough for the palette's gutter and a page as wide as the selection's
  /// action bar.
  final double minEditorWidth;

  /// The most of the screen's width a compact side sheet takes.
  final double sheetMaxWidthFraction;

  /// Tallest the selection preview gets.
  final double previewMaxHeight;

  /// Lines the composer grows to before it scrolls.
  final int composerMaxLines;

  /// Width of the panel beside an editor [available] pixels wide.
  double inlineWidth(double available) {
    final double width = available - minEditorWidth;
    return width < 0 ? 0 : (width < panelWidth ? width : panelWidth);
  }

  /// Width of the side sheet on a compact screen [screenWidth] wide.
  double sheetWidth(double screenWidth) {
    final double share = screenWidth * sheetMaxWidthFraction;
    return share < panelWidth ? share : panelWidth;
  }
}

/// How selected ink is turned into the image sent to the model.
class AiImageConfig {
  const AiImageConfig({
    this.padding = 12,
    this.pixelRatio = 2,
    this.maxDimension = 2048,
    this.minPixelRatio = 0.05,
    this.noteGridDivisions = 10,
    this.noteGridLabelSize = 14,
    this.focusInkTolerance = 0.012,
    this.focusInkMaxPoints = 240,
  });

  /// Logical pixels of background kept around the ink on every side.
  final double padding;

  /// Physical pixels per logical pixel. Never exceeded.
  final double pixelRatio;

  /// Neither side of the image is longer than this, in physical pixels.
  final int maxDimension;

  /// A selection that would have to be shrunk below this ratio to fit is
  /// refused: its ink would no longer be visible.
  final double minPixelRatio;

  /// The whole-note image is overlaid with a faint coordinate grid: a
  /// labelled line every 1/[noteGridDivisions] of the paper, and an
  /// unlabelled one halfway between, so the model can read positions off
  /// it. Below 2, no grid is drawn.
  final int noteGridDivisions;

  /// The grid labels' font size, in image pixels, so they stay legible
  /// however far the note is scaled.
  final double noteGridLabelSize;

  /// The ink in the selected region is also sent as coordinates, so the
  /// model can attach to it exactly: each stroke cut down to its ends and
  /// corners, keeping it within this fraction of the region's longer side.
  final double focusInkTolerance;

  /// At most this many points of that ink are sent; the longest strokes
  /// go first.
  final int focusInkMaxPoints;
}

/// Limits for structured, model-produced notation.
class AiNotationConfig {
  const AiNotationConfig({
    this.maxLabelRunes = 80,
    this.maxItems = 48,
    this.maxPointsPerStroke = 128,
    this.maxPathPoints = 64,
    this.maxTotalPoints = 4096,
    this.maxTextRunes = 120,
    this.maxTotalTextRunes = 600,
    this.minTextSize = 8,
    this.maxTextSize = 120,
    this.maxFormulaLength = 160,
    this.maxGraphCoordinate = 1e6,
    this.graphSamples = 240,
    this.minWidth = 1,
    this.maxWidth = 20,
    this.minDurationMs = 250,
    this.maxDurationMs = 12000,
    this.maxSteps = 24,
    this.stepPauseMs = 250,
    this.stepFinalHoldMs = 600,
    this.maxPlotChildren = 16,
    this.plotTextSize = 12,
    this.maxPlotMarks = 8,
    this.maxResponseBytes = 256 * 1024,
    // Gemini 2.5 counts its thinking, often 1500 tokens or more, against
    // this too.
    this.maxOutputTokens = 32768,
    this.inkSnapDistance = 16,
  });

  final int maxLabelRunes;

  /// A loose end of a line, path, or stroke the model draws that lands this
  /// close to existing ink, in logical pixels, is moved onto it, so a lead
  /// meant to touch a drawing does. Text is never moved. 0 turns it off.
  final double inkSnapDistance;

  /// Texts, graphs, paths, and strokes in one notation.
  final int maxItems;

  /// Points the model may give one stroke.
  final int maxPointsPerStroke;

  /// Key points the model may give one path.
  final int maxPathPoints;

  /// Points the model may give, over every stroke and path of a notation.
  /// Text and graphs are drawn by the app and do not count.
  final int maxTotalPoints;

  /// Characters in one text, and in every text of a notation.
  final int maxTextRunes;
  final int maxTotalTextRunes;

  /// The height of a capital letter, in logical pixels.
  final double minTextSize;
  final double maxTextSize;

  final int maxFormulaLength;

  /// The furthest from 0 a graph's own x or y range may reach.
  final double maxGraphCoordinate;

  /// Points a graph's curve is worked out at, from its start to its end.
  final int graphSamples;

  final double minWidth;
  final double maxWidth;

  /// The shortest and longest an animated notation may take, once timed
  /// from its steps.
  final int minDurationMs;
  final int maxDurationMs;

  /// The highest `step` an animated item may give.
  final int maxSteps;

  /// The pause between one step of an animation and the next, and the
  /// hold after the last, before it starts again.
  final int stepPauseMs;
  final int stepFinalHoldMs;

  /// Functions, points, segments, labels, shadings, and intersections in
  /// one plot.
  final int maxPlotChildren;

  /// The height of a capital in a plot's tick numbers and the coordinates
  /// it writes by marked points, in logical pixels.
  final double plotTextSize;

  /// The most points one mark or intersection labels: a curve with more
  /// roots, say, has only the first of them marked.
  final int maxPlotMarks;

  final int maxResponseBytes;
  final int maxOutputTokens;

  static const List<String> defaultInkIds = <String>[
    'ink',
    'graphite',
    'blue',
    'red',
    'green',
    'orange',
    'purple',
    'teal',
  ];

  List<String> get inkIds => defaultInkIds;
}

/// Where and how the Gemini API is called.
///
/// The key comes from outside the source tree. A key compiled into a mobile
/// binary can be extracted from it, so this is for prototypes only; see the
/// README.
class AiApiConfig {
  const AiApiConfig({
    required this.apiKey,
    this.model = defaultModel,
    this.baseUrl = defaultBaseUrl,
    this.timeout = defaultTimeout,
    this.maxDuration = defaultMaxDuration,
    this.thinkingLevel = defaultThinkingLevel,
    this.thinkingBudget = defaultThinkingBudget,
    this.serverErrorRetries = 1,
    this.retryDelay = const Duration(seconds: 1),
  });

  /// Reads the key given with `--dart-define=GEMINI_API_KEY=...`, and,
  /// when given, the model (`GEMINI_MODEL`), thinking level
  /// (`GEMINI_THINKING_LEVEL`), and thinking budget
  /// (`GEMINI_THINKING_BUDGET`). They are usually given with
  /// `--dart-define-from-file=dart_defines.json`, and are fixed when the
  /// app is built, so a change takes a full restart. A blank one is the
  /// default.
  const AiApiConfig.fromEnvironment()
    : this(
        apiKey: const String.fromEnvironment(environmentKey),
        model: const String.fromEnvironment(
          modelEnvironmentKey,
          defaultValue: defaultModel,
        ),
        thinkingLevel: const String.fromEnvironment(
          thinkingLevelEnvironmentKey,
        ),
        thinkingBudget:
            const String.fromEnvironment(thinkingBudgetEnvironmentKey) == ''
            ? null
            : const int.fromEnvironment(
                thinkingBudgetEnvironmentKey,
                // Not a whole number: treated as not given.
                defaultValue: _notABudget,
              ),
      );

  static const String environmentKey = 'GEMINI_API_KEY';
  static const String modelEnvironmentKey = 'GEMINI_MODEL';
  static const String thinkingLevelEnvironmentKey = 'GEMINI_THINKING_LEVEL';
  static const String thinkingBudgetEnvironmentKey = 'GEMINI_THINKING_BUDGET';

  /// Below every budget the API accepts; -1 asks for dynamic thinking.
  static const int _notABudget = -2;

  /// What each thinking level is on a model that takes a budget instead,
  /// in tokens. `high` leaves room for a long drawing within
  /// [AiNotationConfig.maxOutputTokens], which thinking counts against.
  static const Map<String, int> thinkingLevelBudgets = <String, int>{
    'MINIMAL': 0,
    'LOW': 1024,
    'MEDIUM': 4096,
    'HIGH': 16384,
  };

  /// Gemini 2.5 Pro cannot turn its thinking off; this is its least.
  static const int minimalProBudget = 128;

  /// Of the models tried, the only one that drew Notation where it was
  /// asked to, in legible strokes.
  static const String defaultModel = 'gemini-2.5-flash';

  /// Names shown in the panel for models it knows; any other model is
  /// shown by its ID.
  static const Map<String, String> modelLabels = <String, String>{
    'gemini-2.5-flash': 'Gemini 2.5 Flash',
    'gemini-2.5-flash-lite': 'Gemini 2.5 Flash-Lite',
    'gemini-2.5-pro': 'Gemini 2.5 Pro',
    'gemma-4-31b-it': 'Gemma 4 31B',
    'gemma-4-26b-a4b-it': 'Gemma 4 26B',
  };
  static const String defaultBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  /// The model can think for over 30 seconds before its first word, so
  /// this is generous; once it writes, pieces come every second or so.
  static const Duration defaultTimeout = Duration(seconds: 90);

  /// A long drawing streams for a minute or more after the words.
  static const Duration defaultMaxDuration = Duration(minutes: 4);

  /// None: the model decides how long to think, which every model accepts.
  static const String? defaultThinkingLevel = null;

  /// None. With thinking turned off (`0`), Gemini 2.5 Flash's handwritten
  /// notation comes out scrambled.
  static const int? defaultThinkingBudget = null;

  final String apiKey;

  /// As given; see [modelId] for the one used.
  final String model;
  final String baseUrl;

  /// The longest an attempt may go without hearing anything: before the
  /// service answers, and between the pieces of a streamed answer. An
  /// answer still arriving is not cut off for being long.
  final Duration timeout;

  /// The longest one attempt may take in all, however steadily it streams.
  final Duration maxDuration;

  /// How long the model thinks: `MINIMAL`, `LOW`, `MEDIUM`, or `HIGH`, as
  /// given, in any case and with or without a `ThinkingLevel.` prefix;
  /// blank is the model's default. See [requestThinking] for what is sent.
  final String? thinkingLevel;

  /// The most tokens the model may think for, as given: `0` turns thinking
  /// off where a model allows it, `-1` lets the model decide. It takes
  /// precedence over [thinkingLevel]. See [requestThinking].
  final int? thinkingBudget;

  /// How many times a 500 or 503 is sent again before it is reported. The
  /// service returns these intermittently, at once, without generating.
  final int serverErrorRetries;

  /// The wait before each of those retries.
  final Duration retryDelay;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  /// The model requests go to: [model] trimmed, without a `models/` prefix
  /// copied from the API's model list, or [defaultModel] when that leaves
  /// nothing.
  String get modelId {
    String id = model.trim();
    if (id.startsWith('models/')) {
      id = id.substring('models/'.length);
    }
    return id.isEmpty ? defaultModel : id;
  }

  /// Shown in the panel header.
  String get modelLabel => modelLabels[modelId] ?? modelId;

  /// Whether the model thinks to a token budget and refuses a thinking
  /// level with a 400, as Gemini 2.5 does.
  bool get thinksToBudget => modelId.startsWith('gemini-2.5');

  /// What is sent as `thinkingConfig`; neither, when both are null.
  ///
  /// A [thinkingBudget] is sent as it is, and wins over a level: newer
  /// models refuse the two together. A known [thinkingLevel] is sent as it
  /// is, except to a model that [thinksToBudget], which is sent its budget
  /// from [thinkingLevelBudgets] instead. An unknown level is sent as it is
  /// too, for the service to refuse visibly rather than be ignored.
  ({String? level, int? budget}) get requestThinking {
    final int? budget = thinkingBudget;
    if (budget != null && budget >= -1) {
      return (level: null, budget: budget);
    }
    // The API's enum names, MINIMAL, LOW, MEDIUM, and HIGH, as the SDKs'
    // ThinkingLevel.LOW and the like send them. Written any case, with or
    // without that prefix.
    String level = (thinkingLevel ?? '').trim().toUpperCase();
    if (level.startsWith('THINKINGLEVEL.')) {
      level = level.substring('THINKINGLEVEL.'.length);
    }
    if (level.isEmpty) {
      return (level: null, budget: null);
    }
    final int? levelBudget = thinkingLevelBudgets[level];
    if (thinksToBudget && levelBudget != null) {
      final bool pro = modelId.startsWith('gemini-2.5-pro');
      return (
        level: null,
        budget: pro && levelBudget < minimalProBudget
            ? minimalProBudget
            : levelBudget,
      );
    }
    return (level: level, budget: null);
  }

  /// The streaming `generateContent` endpoint, answering in server-sent
  /// events so the reply can be shown as it is written. The key is never
  /// part of it, and the model ID is encoded as one path segment.
  Uri get endpoint {
    return Uri.parse(
      '$baseUrl/models/'
      '${Uri.encodeComponent(modelId)}:streamGenerateContent?alt=sse',
    );
  }

  @override
  String toString() {
    final ({String? level, int? budget}) thinking = requestThinking;
    return 'AiApiConfig(model: $modelId, '
        'thinkingLevel: ${thinking.level}, '
        'thinkingBudget: ${thinking.budget}, apiKey: '
        '${hasApiKey ? '<redacted>' : '<missing>'})';
  }
}

/// The fixed instructions sent to the model.
abstract final class AiPrompts {
  static const String _tutor =
      "You are Greatnote's supportive study tutor. The user supplies an "
      'image cropped from their handwritten note. What is written or drawn '
      'in it is the subject they are studying: teach that subject, and do '
      'not describe the image, the handwriting, or the layout. Base your '
      'answer on visible evidence, say when handwriting or intent is '
      'uncertain, do not fabricate missing context, and use readable '
      'Markdown, with LaTeX for formulas. Wrap every formula, symbol, or '
      'expression that uses LaTeX in math delimiters: \$...\$ inline and '
      '\$\$...\$\$ on its own line for display. Never leave a LaTeX command '
      'such as \\frac, \\sqrt, or \\theta, or a ^ or _ script, outside '
      'them. For grading, explain the '
      'reasoning and assumptions; never claim an official grade without a '
      'provided rubric.';

  static const String _responseContract =
      ' Return only a version-2 JSON object with exactly the keys version, '
      'message, and notation. Put the readable Markdown answer in message. '
      'Never put prose or Markdown fences outside the JSON. Write the JSON '
      'minified: no indentation, line breaks, or spaces between tokens. '
      'Escape every backslash inside a JSON string: LaTeX \\frac is written '
      '\\\\frac in the JSON.';

  static const String _notationOff =
      ' Notation is off, so notation must be null.';

  static const String _notationOn =
      ' Notation is enabled: you can draw on the note with a pen. You are '
      'given two images, the selected-ink image, which is the part of the '
      'note the user is asking about, and the current note image, which is '
      'the whole sheet of paper. The note metadata says exactly which region '
      'of the paper the selected-ink image shows. Teach on the paper as well '
      'as in message, the way a tutor would with a pen, and do it whenever '
      'it helps the user, not only when asked: '
      '(1) write the answer or the key result by hand on the note, near the '
      'work it belongs to, such as the solution to an equation, a missing '
      'step, or a corrected value; '
      '(2) sketch a small helping drawing in blank space when a picture '
      'explains it better than words, such as a labelled diagram, a graph '
      'with axes, a number line, a triangle with its sides marked, a force '
      'arrow, or a circuit; '
      '(3) mark the existing work: circle or underline what matters, put a '
      'check by what is right, mark mistakes, and label parts with a leader '
      'line. '
      'Reach for visuals readily: a good tutor explains and solves with '
      'pictures, not words alone. Whenever a problem or concept involves a '
      'function, equation, inequality, rate, area, data, geometry, vectors, '
      'forces, motion, or any quantity that changes, draw it, even if the '
      'user did not ask. Plot the function behind an equation and mark its '
      'roots, extrema, or intercepts; show a solution as where two curves '
      'intersect; shade the area an integral or inequality describes; draw '
      'a tangent or secant line for a derivative or slope; put values on a '
      'number line; sketch the figure of a geometry problem with its known '
      'sides and angles labelled; draw a free-body or vector diagram for '
      'physics. Prefer a plot for anything with a graph, and let the app '
      'find and label its features. When solving, let the visual carry the '
      'key step, such as the intersection that is the answer, and refer to '
      'it in message. One clear, well-placed visual beats several cramped '
      'ones. '
      'When the user asks you to draw, mark, circle, underline, label, '
      'annotate, correct, or write on the note, you must return a notation '
      'that does it; never only describe the drawing in message. Return '
      'null only when nothing on the paper would help, or there is no room. '
      'message still carries the full explanation; the notation is the '
      'short handwritten version of it. Write message first and notation '
      'after it. A valid notation is drawn on the note at once. '
      'Coordinates are note_normalized over the whole paper: (0,0) is the '
      'top-left corner and (1,1) the bottom-right, x grows right and y grows '
      'down. Work out positions from the selected region given in the '
      'metadata: to mark selected ink, map its place in the selected-ink '
      'image onto the note. You may draw anywhere on the paper, inside or '
      'outside the selected region, but never off the paper: keep every '
      'mark a little inside 0 and 1, because a drawing that reaches an edge '
      'is rejected whole. Give coordinates to 3 decimals. '
      'When the user asks you to finish or add to something they drew, '
      'build on their ink instead of drawing the part again: work out from '
      'selected_ink in the metadata where the parts you add meet theirs, '
      'and make them touch their ink exactly there. '
      'A notation is a list of items. You say what to draw and where; the '
      'app draws it. Every item has an ink (ink, graphite, blue, red, '
      'green, orange, purple, teal) and a pen width in logical units from 1 '
      'through 20 (2 to 3 is a normal pen). There are seven kinds: '
      '"text": words, which the app writes in its own handwriting. Give the '
      'text, x and y for the top-left corner of its first letter, and size, '
      'the height of a capital letter in logical units (18 to 30 suits most '
      'notes). Never draw letters or digits yourself; always use text. A '
      'text item is placed in note coordinates; inside a plot, use its '
      'point labels and label children instead. A '
      'line of n characters is about 0.7 * n * size logical units wide and '
      '1.3 * size tall, and \\n starts a new line; convert with the note '
      'size in the metadata and leave the whole text inside the paper. It '
      'can write letters, digits, spaces, and . , : ; ! ? \' " ( ) [ ] { } + '
      '- × · ÷ / \\ ^ = < > ≤ ≥ ≠ ≈ ± √ π θ Δ ∞ ° → ← ² ³ ✓ % # _ | ~ *; use '
      'only those. '
      '"plot": a coordinate plane, the way to draw any graph, chart, or '
      'number plane. Give its box on the paper (left, top, right, bottom, '
      'note_normalized), the x range it shows (x_from, x_to), the y range '
      '(y_from, y_to, or both null to fit its contents), axes to draw the '
      'x and y axes, ticks to have the app number them at round values, '
      'and children. Everything in children is placed in the plot\'s own '
      'x and y, not note coordinates: the point (2, 4) is x 2, y 4 of the '
      'graph, and the app maps it into the box, so never convert graph '
      'values to note coordinates yourself. The plot\'s ink is its axes\' '
      'and its width every child\'s. Children, each with an ink: '
      '"function" draws a formula in x across the plot, such as '
      'x^2 - 2*x + 1 or 2*sin(x) (+ - * / ^, parentheses, pi, e, sqrt, abs, '
      'sin, cos, tan, asin, acos, atan, ln, log, exp), with an optional '
      'line_style and optional marks, a list of "roots", "extrema", and '
      '"y_intercept": the app finds those points exactly and draws and '
      'labels each with its coordinates, so never work them out and place '
      'them yourself; '
      '"intersections" with of, two formulas: the app finds, dots, and '
      'labels where their curves meet (draw each curve with a function as '
      'well); '
      '"point" puts a dot at x, y, with an optional label written beside '
      'it; '
      '"segment" is a straight line from one point to another, with an '
      'optional line_style and arrow, for asymptotes, tangent lines, '
      'vectors, and dashed guides to an axis; '
      '"label" writes text just above and right of x, y, to name a curve '
      'or region; '
      '"shade" hatches the area between formula and base (y = 0 unless '
      'given) from x from to x to, for an integral or a region between '
      'two curves. Anything outside the plot\'s ranges is cut off at the '
      'box. '
      '"graph": a lone curve in a box, with no marks or labels; prefer '
      'plot. Give its formula, x_from, x_to, y_from, y_to, the box (left, '
      'top, right, bottom), and axes. '
      '"line": a straight line from one point to another. Its line_style '
      'is "solid", "dashed", or "dotted" (for guides, projections, and '
      'construction lines), and its arrow is "none", "end" (an arrowhead '
      'at to), "start" (at from), or "both". Use it for every arrow, leader '
      'line, underline, and dotted guide; the app draws the arrowheads. '
      '"shape": a simple shape the app draws to fill a box (left, top, '
      'right, bottom, note_normalized), with a line_style: "ellipse" fills '
      'the box, so to circle something give a box a little larger than it; '
      '"circle" is the largest circle in the box; "rectangle" (to box an '
      'answer); "triangle" (apex at the top middle); "triangle_down", '
      '"triangle_left", and "triangle_right" (apex at the named edge); '
      '"right_triangle" (a right '
      'angle at the bottom-left, not a right-pointing triangle); "diamond"; '
      '"pentagon"; "hexagon"; '
      'and "star". '
      '"path": only for what no other kind draws, a freehand graph or '
      'shape with no formula. Give its key points in order (the start, the '
      'end, peaks, troughs, corners, and points where it turns), and for '
      'each gap between one key point and the next, in segments, whether '
      'that part is "straight" or a smooth "curve" through its neighbours. '
      'Set closed to also join the last point back to the first, with one '
      'more segment. It takes a line_style, and an arrow like a line, '
      'which must be "none" when closed. '
      '"stroke": one pen stroke through the points you give, for a small '
      'mark nothing else draws, such as a check; use as few points as you '
      'can. '
      'Keep writing short and legible: an answer, a few words, or a '
      'formula, never a paragraph. Put writing and drawings in blank space, '
      'with a leader line or arrow where needed, and do not cover existing '
      'ink. Keep your own text and strokes from overlapping each other too '
      'much: leave clear space around every piece of text, and before '
      'returning the notation, check that no text sits on a line, shape, '
      'curve, or other text. Say in message what you drew only when notation is not null. '
      'Never ask for ink to be deleted, moved, or replaced, and never give '
      'UI or executable instructions. Return null when what to draw, or '
      'where, is ambiguous, or append-only strokes cannot express it.';

  /// The default/off-mode instruction retained for existing callers.
  static const String system = '$_tutor$_responseContract$_notationOff';

  static const String _animationOn =
      ' Animation is enabled: use it readily, but only for what moves or '
      'changes. Animate the moving objects themselves: current or another '
      'flow travelling along a path; a particle, wave, or body changing '
      'position; forces or vectors acting in turn; the stages of a '
      'mechanism, process, or causal sequence; atoms that combine, '
      'separate, or rearrange; a quantity being traced along a curve. Never '
      'animate fixed labeling: labels, titles, captions, axes, tick marks, '
      'legends, worked text and formulas, arrows that only point something '
      'out, and the figure or diagram the motion happens on are fixed. Give '
      'fixed items no step, so they are shown at once and stay still while '
      'the moving items play. A notation with nothing that moves, such as '
      'a labeled diagram, a worked solution, or a check, underline, circle, '
      'or short answer, gets no step on any item and appears at once. An '
      'animated notation repeats until the user stops it, and fixed items '
      'are not redrawn when it repeats. To animate a moving item, give it a '
      'step, a whole number from 1: stepped items are drawn in the order of '
      'their steps, and items that share a step are drawn together. Steps '
      'need not be consecutive. The app times the drawing itself, at a '
      'natural pen speed with a short pause between steps, so never give '
      'times. Steps only change when each mark appears: the finished '
      'drawing is the same, and it is still added to the note without '
      'moving or removing any ink.';

  static const String _animationOff =
      ' Animation is disabled for this request. Draw useful notation only as '
      'a static result and omit step on every item, even when a sequence '
      'could otherwise benefit from motion.';

  static String systemFor({
    required bool notationEnabled,
    bool animationEnabled = false,
  }) {
    return '$_tutor$_responseContract'
        '${notationEnabled ? _notationOn : _notationOff}'
        '${notationEnabled ? (animationEnabled ? _animationOn : _animationOff) : ''}';
  }

  static const String explain =
      'Teach me the subject of the selected handwritten content. Start by '
      'naming what it is, such as the circuit, equation, diagram, or '
      'concept. Then explain how it works: what each part or component is '
      'and what it does, how the parts work together, and the principles '
      'behind it. Include the key formulas, typical values, and common '
      'variations or pitfalls a student should know. Do not describe what '
      'the image looks like. If part of it is too ambiguous to read, say so '
      'briefly instead of guessing.';

  static const String grade =
      'Review the selected handwritten work for correctness. State what is '
      'correct, identify mistakes with specific explanations, and suggest an '
      'improved answer. If no question, answer key, rubric, or point total '
      'is visible, say what assumptions you are making and give formative '
      'feedback rather than inventing an authoritative score.';
}

/// A one-press prompt offered in the panel.
enum AiQuickAction {
  explain('Explain this', AiPrompts.explain),
  grade('Grade this', AiPrompts.grade);

  const AiQuickAction(this.label, this.prompt);

  /// Shown on the button and in the transcript.
  final String label;

  /// What the model is sent.
  final String prompt;
}
