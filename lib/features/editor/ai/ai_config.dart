import 'ai_models.dart';

/// Sizes of the AI assistant panel.
class AiLayoutConfig {
  const AiLayoutConfig({
    this.panelWidth = 360,
    this.minPanelWidth = 280,
    this.maxPanelWidth = 720,
    this.minEditorWidth = 280,
    this.sheetMaxWidthFraction = 0.88,
    this.previewMaxHeight = 160,
    this.composerMaxLines = 4,
  });

  /// Width of the panel beside the editor until the user resizes it, and
  /// the most a compact side sheet takes.
  final double panelWidth;

  /// Narrowest the user can drag the panel beside the editor.
  final double minPanelWidth;

  /// Widest the user can drag the panel beside the editor.
  final double maxPanelWidth;

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

  /// Width of the panel beside an editor [available] pixels wide, given the
  /// width the user dragged it to, if any.
  double inlineWidth(double available, {double? preferred}) {
    final double wanted = preferred == null
        ? panelWidth
        : preferred.clamp(minPanelWidth, maxPanelWidth).toDouble();
    final double width = available - minEditorWidth;
    return width < 0 ? 0 : (width < wanted ? width : wanted);
  }

  /// Width of the side sheet on a compact screen [screenWidth] wide.
  double sheetWidth(double screenWidth) {
    final double share = screenWidth * sheetMaxWidthFraction;
    return share < panelWidth ? share : panelWidth;
  }
}

/// How selected ink is previewed and raster-backed selections are embedded in
/// the SVG sent to the model.
class AiImageConfig {
  const AiImageConfig({
    this.padding = 12,
    this.pixelRatio = 3,
    this.maxDimension = 2048,
    this.maxPngBytes = 3500000,
    this.focusInkTolerance = 0.012,
    this.focusInkMaxPoints = 240,
    this.space = const AiSpaceConfig(),
  });

  /// How the blank areas the model is told it may draw in are found.
  final AiSpaceConfig space;

  /// Logical pixels of background kept around the ink on every side.
  final double padding;

  /// Physical pixels per logical pixel. Never exceeded.
  final double pixelRatio;

  /// Neither side of the image is longer than this, in physical pixels.
  /// High enough that handwriting reaches the model at full detail; the
  /// image is a lossless PNG, never recompressed.
  final int maxDimension;

  /// The most bytes the PNG may take, within what the backend accepts
  /// (6,000,000 base64 characters). Only a selection over a detailed
  /// picture gets near it; it is then drawn smaller until it fits.
  final int maxPngBytes;

  /// Legacy simplified focus geometry retained for saved contexts. Current
  /// notation requests carry the selected native paths directly as SVG.
  final double focusInkTolerance;

  /// At most this many points of that ink are sent; the longest strokes
  /// go first.
  final int focusInkMaxPoints;
}

/// How the app finds blank paper for the model to draw in, and where it
/// puts a sticky note when there is none. In logical units.
class AiSpaceConfig {
  const AiSpaceConfig({
    this.cellSize = 8,
    this.maxCells = 160,
    this.clearance = 12,
    this.edgeMargin = 16,
    this.minWidth = 120,
    this.minHeight = 60,
    this.maxAreas = 3,
    this.nearness = 0.3,
    this.backgroundInkThreshold = 48,
    this.nearbyReach = 240,
    this.maxNearby = 16,
  });

  /// Content this close to the selection is described to the model, as a
  /// box round each group, in place of a picture of the page...
  final double nearbyReach;

  /// ...at most this many boxes, the nearest.
  final int maxNearby;

  /// The paper is looked at in square cells this wide...
  final double cellSize;

  /// ...or wider, so that neither side has more than this many.
  final int maxCells;

  /// Blank paper this close to ink, an image, or a sticky note is not
  /// offered: a drawing there would crowd it.
  final double clearance;

  /// Nor is paper this close to its edge.
  final double edgeMargin;

  /// The smallest box worth offering. An L's arm is offered when it is at
  /// least [minHeight] thick and as big as such a box.
  final double minWidth;
  final double minHeight;

  /// The most areas, each a box or an L, the model is told about.
  final int maxAreas;

  /// How much nearness to the selection counts against size: an area this
  /// fraction of the paper's diagonal away counts as a quarter its size.
  final double nearness;

  /// A pixel of a page-wide background, such as a PDF page, that differs
  /// from white by more than this in any channel is printed on.
  final int backgroundInkThreshold;
}

/// Limits for structured, model-produced notation.
class AiNotationConfig {
  const AiNotationConfig({
    this.maxLabelRunes = 80,
    this.maxItems = 48,
    this.maxPointsPerStroke = 128,
    this.maxPathPoints = 64,
    this.maxTotalPoints = 4096,
    this.maxTextRunes = 48,
    this.maxTotalTextRunes = 400,
    this.maxMathRunes = 400,
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
    // Enough for a detailed answer or drawing while preventing a runaway
    // response from spending an entire large context window.
    this.maxOutputTokens = 16384,
    this.inkSnapDistance = 16,
    this.inkClearance = 0.6,
    this.minInkClearance = 8,
    this.sketchBow = 0.03,
    this.maxSketchBow = 5,
    this.sketchOvershoot = 0.08,
    this.minStickyWidth = 120,
    this.minStickyHeight = 90,
    this.maxStickyWidth = 640,
    this.maxStickyHeight = 480,
  });

  final int maxLabelRunes;

  /// The sizes a sticky note the model asks for may be, in logical units:
  /// those a user's own sticky note may be. A size outside is brought
  /// within.
  final double minStickyWidth;
  final double minStickyHeight;
  final double maxStickyWidth;
  final double maxStickyHeight;

  /// A loose end of a line, path, or stroke the model draws that lands this
  /// close to existing ink, in logical pixels, is moved onto it, so a lead
  /// meant to touch a drawing does. Text is never moved. 0 turns it off.
  final double inkSnapDistance;

  /// The clear space kept between what the model writes and ink already on
  /// the paper, the user's or its own, in text sizes (capital heights), and
  /// never less than [minInkClearance] logical units. Writing placed closer
  /// is moved the shortest way clear; pinned labels stay where they are.
  final double inkClearance;
  final double minInkClearance;

  /// How far a straight stretch of the model's line art bows off true when
  /// drawn as ink, as a fraction of its length, and never more than
  /// [maxSketchBow] logical units, so it looks drawn by hand, not ruled.
  final double sketchBow;
  final double maxSketchBow;

  /// How far a circle or ellipse drawn as ink runs on past where it began,
  /// as a fraction of a turn, as a loop drawn by hand does.
  final double sketchOvershoot;

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

  /// Characters in one math item's LaTeX, which counts toward
  /// [maxTotalTextRunes] too.
  final int maxMathRunes;

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
    this.claudeApiKey = '',
    this.claudeApiKeyFallbacks = const <String>[],
    this.openAiApiKey = '',
    this.openAiApiKeyFallbacks = const <String>[],
    this.claudeBaseUrl = defaultClaudeBaseUrl,
    this.openAiBaseUrl = defaultOpenAiBaseUrl,
    this.modelOverrides = const <AiModelId, String>{},
  });

  /// Provider credentials are deliberately never read from build defines.
  /// Production requests use BackendAiClient. Direct provider clients remain
  /// injectable for isolated tests. Reads the model (`GEMINI_MODEL`), thinking level
  /// (`GEMINI_THINKING_LEVEL`), and thinking budget
  /// (`GEMINI_THINKING_BUDGET`). They are usually given with
  /// `--dart-define-from-file=dart_defines.json`, and are fixed when the
  /// app is built, so a change takes a full restart. A blank one is the
  /// default.
  const AiApiConfig.fromEnvironment()
    : this(
        apiKey: '',
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
        claudeApiKey: '',
        openAiApiKey: '',
        modelOverrides: const <AiModelId, String>{
          AiModelId.haiku: String.fromEnvironment('HAIKU_MODEL_ID'),
          AiModelId.luna: String.fromEnvironment('LUNA_MODEL_ID'),
          AiModelId.sonnet: String.fromEnvironment('SONNET_MODEL_ID'),
          AiModelId.sol: String.fromEnvironment('SOL_MODEL_ID'),
          AiModelId.opus: String.fromEnvironment('OPUS_MODEL_ID'),
          AiModelId.argon: String.fromEnvironment('ARGON_MODEL_ID'),
          AiModelId.astra: String.fromEnvironment('ASTRA_MODEL_ID'),
        },
      );

  /// The `dart_defines.json` keys for the Claude and OpenAI keys, spelled
  /// as existing local files spell them. `CLAUDE_API_KEY`,
  /// `ANTHROPIC_API_KEY`, and `OPENAI_API_KEY` are read when these are
  /// blank.
  static const String claudeEnvironmentKey = 'Claude_API_KEY';
  static const String openAiEnvironmentKey = 'Openai_API_KEY';

  static const String defaultClaudeBaseUrl = 'https://api.anthropic.com/v1';
  static const String defaultOpenAiBaseUrl = 'https://api.openai.com/v1';

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

  /// As given with `Claude_API_KEY`; see [claudeKey] for the one used.
  final String claudeApiKey;

  /// Read in order when [claudeApiKey] is blank.
  final List<String> claudeApiKeyFallbacks;

  /// As given with `Openai_API_KEY`; see [openAiKey] for the one used.
  final String openAiApiKey;

  /// Read in order when [openAiApiKey] is blank.
  final List<String> openAiApiKeyFallbacks;

  final String claudeBaseUrl;
  final String openAiBaseUrl;

  /// Provider model IDs given in place of each model's default; blank
  /// ones are ignored.
  final Map<AiModelId, String> modelOverrides;

  static String _firstGiven(String key, List<String> fallbacks) {
    for (final String candidate in <String>[key, ...fallbacks]) {
      if (candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return '';
  }

  /// The Claude key requests are sent with; blank when none was given.
  String get claudeKey => _firstGiven(claudeApiKey, claudeApiKeyFallbacks);

  /// The OpenAI key requests are sent with; blank when none was given.
  String get openAiKey => _firstGiven(openAiApiKey, openAiApiKeyFallbacks);

  /// Whether requests to [provider] have a key to go with them.
  bool hasKeyFor(AiProvider provider) {
    return switch (provider) {
      AiProvider.gemini => hasApiKey,
      AiProvider.claude => claudeKey.isNotEmpty,
      AiProvider.openai => openAiKey.isNotEmpty,
    };
  }

  /// The provider's ID for [model]: its override when one was given, and
  /// otherwise its default.
  String providerModelId(AiModelId model) {
    String id = (modelOverrides[model] ?? '').trim();
    if (id.startsWith('models/')) {
      id = id.substring('models/'.length);
    }
    return id.isEmpty ? model.defaultProviderModelId : id;
  }

  /// This configuration with Gemini requests going to [model] instead.
  AiApiConfig withGeminiModel(String model) {
    return AiApiConfig(
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
      timeout: timeout,
      maxDuration: maxDuration,
      thinkingLevel: thinkingLevel,
      thinkingBudget: thinkingBudget,
      serverErrorRetries: serverErrorRetries,
      retryDelay: retryDelay,
      claudeApiKey: claudeApiKey,
      claudeApiKeyFallbacks: claudeApiKeyFallbacks,
      openAiApiKey: openAiApiKey,
      openAiApiKeyFallbacks: openAiApiKeyFallbacks,
      claudeBaseUrl: claudeBaseUrl,
      openAiBaseUrl: openAiBaseUrl,
      modelOverrides: modelOverrides,
    );
  }

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
        '${hasApiKey ? '<redacted>' : '<missing>'}, claudeApiKey: '
        '${claudeKey.isNotEmpty ? '<redacted>' : '<missing>'}, openAiApiKey: '
        '${openAiKey.isNotEmpty ? '<redacted>' : '<missing>'})';
  }
}

/// The fixed instructions sent to the model.
abstract final class AiPrompts {
  static const String _tutor =
      "You are Etonia's study tutor. The selected context is an image cropped "
      'from the user\'s handwritten note (with Notation on, also the same '
      'crop as page-coordinate SVG): teach that '
      'subject, and do not describe the image, SVG, handwriting, or layout. '
      'Never ask the user to confirm or clarify: '
      'when anything is unclear, take the most likely reading, state it in '
      'one short line, and answer fully but concisely. Use the visible work and do not '
      'invent facts. Write Markdown with all LaTeX inside \$...\$ or '
      '\$\$...\$\$; never leave \\frac, \\sqrt, ^, or _ outside them. When '
      'grading, explain your reasoning; never claim an official grade '
      'without a provided rubric.';

  // ignore: unused_field, retained only to read legacy JSON conversations.
  static const String _responseContract =
      ' Return only minified JSON with exactly the keys version (2), message '
      '(the Markdown answer), and notation; nothing outside it. Escape '
      'backslashes in JSON strings: \\frac is written \\\\frac.';

  // ignore: unused_field
  static const String _notationOff =
      ' Notation is off, so notation must be null.';

  // ignore: unused_field
  static const String _textContract =
      ' Return only minified JSON with exactly the keys version (2) and '
      'message (the Markdown answer); nothing outside it. Escape '
      'backslashes in JSON strings: \\frac is written \\\\frac. Answer in '
      'words only: a separate step draws on the note afterwards, so do '
      'not draw or mention a drawing.';

  // ignore: unused_field
  static const String _notationOn =
      ' Notation is on: you can write and draw on the note. You get the '
      'selected note as page-coordinate SVG and note metadata: its region, '
      'boxes round nearby content, and the '
      'blank free areas. Every answer must come with a notation, except a '
      'simple text answer (a word, number, yes or no, or a fact of a '
      'sentence or two). Anything more is also written on the note, doing '
      'what applies: (1) write the key result near its work; (2) draw a '
      'small helping visual; (3) mark the work: circle, '
      'underline, check, mark mistakes, label with leader lines. Draw '
      'readily for functions, equations, rates, areas, data, geometry, '
      'vectors, forces, and motion: plot the function and mark its roots or '
      'extrema, show a solution as an intersection, shade an integral, '
      'label a figure\'s sides and angles, draw a free-body diagram. One '
      'clear visual beats several cramped ones. When asked to draw, mark, '
      'or write on the note, return a notation that does it. message keeps '
      'the full explanation, written first; the notation is its condensed '
      'handwritten version. The annotation must not repeat the message: '
      'make the two support each other, with each adding different value. '
      'Coordinates are note_normalized over the paper: (0,0) top-left, '
      '(1,1) bottom-right, 3 decimals, every mark a little inside 0 and 1 '
      '(a drawing that reaches an edge is rejected whole); '
      'sticky_normalized on a sticky note. Read positions directly from the '
      'selected SVG paths. '
      'To finish or add to the user\'s drawing, '
      'build on their ink: make your parts touch it where they meet. '
      'A notation is {label, coordinate_space, items}, each item with '
      'exactly its kind\'s fields; points are {"x":0.6,"y":0.45}. Example: '
      '{"label":"Answer","coordinate_space":"note_normalized","items":'
      '[{"type":"math","latex":"c = \\\\sqrt{a^2 + b^2} = 5","x":0.6,'
      '"y":0.4,"size":24,"ink":"blue","width":2},{"type":"line","from":{"x":0.6,"y":0.45},"to":'
      '{"x":0.75,"y":0.45},"line_style":"solid","arrow":"none","ink":'
      '"red","width":2}]}. Every item has ink (ink, graphite, blue, red, '
      'green, orange, purple, teal) and width (1 to 20 logical units; 2 to '
      '3 is a pen). Kinds: '
      '"text": text, x and y of its first letter\'s top-left, size (capital '
      'height in logical units, {text_size}). Use text for words and plain '
      'labels. A line of n characters is about 0.7*n*size wide and '
      '1.3*size tall; \\n breaks lines. Only these characters: letters, '
      'digits, space, . , : ; ! ? \' " ( ) [ ] { } + - × · ÷ / \\ ^ = < > '
      '≤ ≥ ≠ ≈ ± √ π θ Δ ∞ ° → ← ² ³ ✓ % # _ | ~ * & \$ @. '
      '"math": latex, x and y of its top-left, size (as text): every '
      'formula, equation, or expression, and any symbol, subscript, '
      'superscript, or accent, written in correct LaTeX notation without '
      '\$; the app lays it out and handwrites it. Use it readily: '
      '\\frac, \\sqrt[n]{}, x_i, x^2, \\hat{x}, \\bar{x}, \\vec{v}, \\dot{x}, '
      '\\ddot{x}, \\tilde{x}, \\overline{AB}, f\', Greek, \\sum/\\prod/\\int '
      'with limits, \\lim_{x \\to 0}, \\partial, \\nabla, \\infty, \\pm, '
      '\\cdot, \\times, \\leq, \\approx, \\in, \\subseteq, \\Rightarrow, '
      '\\left( \\right), \\text{}, pmatrix/bmatrix, cases, and aligned with '
      '& and \\\\ for lines of working. One line of it is about '
      '0.6*size per symbol wide and 1.3*size tall; a fraction is about '
      '2.6*size tall, a sum or integral with limits about 3*size. '
      '"plot": the way to draw any graph: box (left, top, right, bottom), '
      'x_from, x_to, y_from, y_to (both null to fit), axes, ticks (the app '
      'numbers them), children. Children use the plot\'s own x and y, '
      'never note coordinates; each has an ink: "function" (formula in x '
      'with + - * / ^ ( ) pi e sqrt abs sin cos tan asin acos atan ln log '
      'exp; optional line_style; optional marks: "roots", "extrema", '
      '"y_intercept", which the app finds and labels, so never compute '
      'them); "intersections" (of: two formulas, also drawn as functions; '
      'the app finds and labels them); "point" (x, y, optional label); '
      '"segment" (from, to, optional line_style, arrow); "label" (text '
      'above-right of x, y); "shade" (formula, optional base, default y = '
      '0, from and to in x). '
      '"graph": a lone curve: formula, x_from, x_to, y_from, y_to, box, '
      'axes; prefer plot. '
      '"line": from, to, line_style ("solid", "dashed", "dotted"), arrow '
      '("none", "end", "start", "both"); for every arrow, leader line, and '
      'underline. '
      '"shape": shape in a box (left, top, right, bottom) with line_style: '
      '"ellipse" (fills the box; to circle something use a slightly larger '
      'box), "circle", "rectangle", "triangle", "triangle_down", '
      '"triangle_left", "triangle_right" (apex at that edge), '
      '"right_triangle" (right angle bottom-left), "diamond", "pentagon", '
      '"hexagon", "star". '
      '"path": only for a freehand curve with no formula: points (ends, '
      'peaks, troughs, corners, in order), segments ("straight" or "curve" '
      'for each gap), closed (joins back to the start; arrow must then be '
      '"none"), line_style, arrow. '
      '"stroke": points of one small mark, such as a check; few points. '
      'Use very little text: short labels or key steps only, one text item '
      'per line, at most 48 characters each and 400 per notation. Lay it '
      'out so it reads at a glance and is never clustered. Put new text and '
      'visuals in the blank free areas, and plan every item\'s box first: '
      'leave a gap of at least one text height between items, stack lines '
      'of working one line apart, and put a label beside what it names, '
      'with a leader line when space is tight. You may draw on the user\'s '
      'own graph or figure when that is the point (mark a point, shade, '
      'circle, annotate a curve), keeping marks light so their work stays '
      'readable. Check that no text sits on a line, shape, curve, or other '
      'text. Draw a visual big enough for its labels to fit outside it; if '
      'it will not fit cleanly, shrink it or drop the least important item '
      'rather than crowd it. Use few colors: one for the result, one for '
      'marks. Mention the drawing in message only when notation is not '
      'null. Never ask for ink to be deleted or moved, or give UI or '
      'executable instructions. When what or where to draw is unclear, '
      'make the most reasonable choice and draw it; return null only when '
      'strokes cannot express it.';

  static const String _svgResponseContract =
      ' Return exactly one valid, self-contained SVG document and nothing '
      'else. The root is <svg xmlns="http://www.w3.org/2000/svg" '
      'data-etonia-version="1">. Put the complete Markdown chat answer as '
      'XML-escaped text in <desc data-etonia-role="message">. Put a short '
      'user-facing drawing label in <title>. Do not use JSON or Markdown '
      'fences. Never use scripts, event attributes, foreignObject, images, '
      'external URLs, fonts, stylesheets, or executable content.';

  static const String _svgNotationOff =
      ' Notation is off: return no visible SVG elements; include only title '
      'and the message desc.';

  static const String _svgNotationOn =
      ' Notation is on. The selected note comes twice: as an image, to read '
      'what is written, and as page-coordinate SVG, to take exact positions '
      'from. Interact with that SVG: annotate the note or add animation to '
      'it, in whatever way best serves the answer. You can annotate '
      'directly on the user\'s strokes: your marks may touch, cross, trace, '
      'or sit on the existing-ink paths in the selected SVG, not only beside '
      'them. Leave the note recognisably the user\'s: do not redraw the '
      'user\'s note, replace it, or cover it with a background. '
      'Tie the drawing to the words: set data-etonia-paragraph="N" on each '
      'visible element, or on a group of them, where N is the paragraph of '
      'the answer it illustrates, counting from 1 the blocks of the answer '
      'between blank lines. '
      'Say what the words are about, for the app to highlight it as they are '
      'read: for each large paragraph, and any paragraph about particular '
      'ink, add <desc data-etonia-role="citation" data-etonia-paragraph="N"> '
      'holding the selected SVG lines it refers to, as [[L12-L30]], or '
      '[[L12-L30,L44-L50]] for several places, whether or not you draw for '
      'that paragraph. Those numbers are data-etonia-line values: match what '
      'the paragraph discusses in the image to the elements at that position, '
      'and cite as narrowly as you can. You may cite both the user\'s ink and '
      'your own earlier notation (data-etonia-author="assistant"). Only cite '
      'lines you were given, and never invent a number. An <image> in the '
      'selected SVG is a picture or printed page, whose details have no '
      'lines. For a paragraph about one specific detail of it, such as a '
      'labelled part, a formula, a sentence, or a table cell, also put '
      '[[C top left bottom right]] in that desc, and the app rings that '
      'detail itself, so do not draw the ring. Those numbers are the tightest '
      'box around just that detail in the image, each from 0 to 1000 as a '
      'share of the image\'s height (top, bottom) or width (left, right), '
      'measured from its top left corner. Box only what the paragraph '
      'discusses, at most three per paragraph and never most of the picture; '
      'when no one detail is meant, or you cannot see exactly where it is, '
      'leave the box out. Write citations only in these desc elements, and '
      'never in the message or in visible text. '
      'How the app reads your SVG: the root viewBox is "0 0 W H", the exact '
      'logical paper width W and height H from the note metadata, and '
      'data-etonia-bounds="x y width height" on the root is the finite box '
      'around all visible content, left out only when you draw nothing. '
      'Paths, lines, polylines, polygons, rects, circles, and ellipses become '
      'editable ink strokes; markers, gradients, patterns, masks, clips, '
      'filters, and <use> are not drawn. Set data-etonia-arrow="end" (or '
      '"start" or "both") on a line or path for the app to draw its '
      'arrowhead. Name colors with data-etonia-stroke-ink and '
      'data-etonia-fill-ink, using ink, graphite, blue, red, green, orange, '
      'purple, or teal, with matching fallback stroke/fill colors. Words are '
      '<text> elements with numeric x, y, and font-size, holding plain ASCII '
      'and no tspan; the app replaces them with the user-configured '
      'handwriting, and may move them clear of other ink unless they carry '
      'data-etonia-fixed="1", so set it on words you place on a stroke. '
      'Write a formula as LaTeX between dollar signs '
      'inside the same kind of <text> element, such as '
      '\$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\$ (escape < and & as XML): '
      'the app lays it out and handwrites it, and y is its first baseline. '
      'Draw other symbols as paths.';

  static const String _svgAnimationOn =
      ' To animate, put data-etonia-motion="1" and data-etonia-step="1", then '
      '2, and so on (maximum 24), on each element or group that changes. A '
      'step without data-etonia-motion="1" is ignored, and <text> does not '
      'step. Put data-etonia-static="1" on fixed children inside a moving '
      'group. Set data-etonia-duration-ms on the root from 300 through 20000. '
      'The steps loop until the user stops animation. Do not use JavaScript, '
      'CSS, or SMIL animation.';

  static const String _svgAnimationOff =
      ' Animation is disabled: omit data-etonia-step and '
      'data-etonia-duration-ms.';

  /// The default/off-mode instruction retained for existing callers.
  static const String system = '$_tutor$_svgResponseContract$_svgNotationOff';

  /// The first pass writes the explanation only; the drawing pass adds the
  /// visible SVG elements without converting them to a JSON scene grammar.
  static const String textSystem =
      '$_tutor$_svgResponseContract$_svgNotationOff';

  // ignore: unused_field
  static const String _animationOn =
      ' Animation is permitted but static is the default. Use steps only '
      'when comprehension requires seeing physical movement or deformation, '
      'propagation or flow, or parts joining, separating, or transforming. '
      'Never animate a reveal, explanation sequence, emphasis, decoration, '
      'or anything whose purpose is fixed identification, measurement, '
      'orientation, reference, structure, or explanation. If uncertain, use '
      'no steps. Fixed items appear at once and are not redrawn. Animations '
      'also stay correct when their strokes are replaced or erased. The '
      'animation repeats until the user stops it. The app sets the pace, so '
      'never give times.';

  // ignore: unused_field
  static const String _animationOff =
      ' Animation is disabled for this request: omit step on every item.';

  static String systemFor({
    required bool notationEnabled,
    bool animationEnabled = false,
    AiTextSize textSize = AiTextSize.medium,
  }) {
    return '$_tutor$_svgResponseContract'
        '${notationEnabled ? _svgNotationOn : _svgNotationOff}'
        '${notationEnabled ? (animationEnabled ? _svgAnimationOn : _svgAnimationOff) : ''}'
        ' When writing SVG text, use a font-size from ${textSize.min.round()} '
        'through ${textSize.max.round()} logical units.';
  }

  /// Added to the system instruction when nothing on the note was chosen.
  static const String noSelection =
      ' Nothing on the note was selected for this conversation: the attached '
      'image is blank paper, not the user\'s work. Answer the question on '
      'its own terms, and never mention the image, a selection, or missing '
      'context. Any notation goes only in blank space on the page, never on '
      'or pointing at the user\'s ink.';

  static const String explain =
      'Teach me the subject of the selected handwritten content. Start by '
      'naming what it is, such as the circuit, equation, diagram, or '
      'concept. Then explain how it works: what each part or component is '
      'and what it does, how the parts work together, and the principles '
      'behind it. Include the key formulas, typical values, and common '
      'variations or pitfalls a student should know. Do not describe what '
      'the image looks like. If part of it is hard to read, go with the '
      'most likely reading, say in one short line what you assumed, and '
      'carry on.';

  static const String grade =
      'Review the selected handwritten work for correctness. State what is '
      'correct, identify mistakes with specific explanations, and suggest an '
      'improved answer. If no question, answer key, rubric, or point total '
      'is visible, assume the most likely task, state that in one short '
      'line, and give full formative feedback rather than inventing an '
      'authoritative score.';
}

/// How large the assistant writes text on the note, as the writer prefers:
/// the range of capital heights, in logical units, it is asked to keep to.
enum AiTextSize {
  small('Small', 10, 15),
  medium('Medium', 12, 19),
  large('Large', 16, 26);

  const AiTextSize(this.label, this.min, this.max);

  final String label;
  final double min;
  final double max;

  static AiTextSize byName(Object? name) {
    for (final AiTextSize size in values) {
      if (size.name == name) return size;
    }
    return medium;
  }
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
