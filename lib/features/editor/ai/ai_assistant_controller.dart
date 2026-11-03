import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:ui' show Brightness, Color, Rect, Size;

import 'package:flutter/foundation.dart';

import '../document_io/document_models.dart';
import '../handwriting/handwriting_calibration.dart';
import '../ink/ink_sample.dart';
import '../ink/ink_selection.dart';
import '../ink/stroke.dart';
import '../sticky/sticky_note.dart';
import 'ai_citation.dart';
import 'ai_client.dart';
import 'ai_config.dart';
import 'ai_notation.dart';
import 'ai_usage_gate.dart';
import 'note_image_renderer.dart';
import 'selection_image_renderer.dart';
import 'selection_svg_renderer.dart';

typedef AiNoteCapture = Future<NoteImage> Function();
typedef AiNotationApply =
    AiNotationApplication Function(AiNotation notation, NoteImage context);

/// Shows [svg], a notation as far as it has been written for the request that
/// captured [context], on the note without adding it. Display only.
typedef AiNotationPreview = void Function(String svg, NoteImage context);

/// Takes away what [AiNotationPreview] showed for the request that captured
/// [context].
typedef AiNotationPreviewEnd = void Function(NoteImage context);

/// The finished strokes lying mostly within [area] on a page as it is now:
/// on [page] when it is known, else on the page holding any of [anchors].
typedef AiAreaInk =
    Iterable<Stroke> Function(
      Rect area,
      Object? page,
      Iterable<Stroke> anchors,
    );

/// The physical screen edge the panel sits against. Not mirrored for
/// right-to-left text.
enum AiPanelSide { left, right }

/// Whether an answer is being waited for.
enum AiRequestState { idle, sending, failed }

/// Whether the panel shows, and where. All the editor's layout needs.
@immutable
class AiPanelPlacement {
  const AiPanelPlacement({required this.isOpen, required this.side});

  final bool isOpen;
  final AiPanelSide side;

  @override
  bool operator ==(Object other) {
    return other is AiPanelPlacement &&
        other.isOpen == isOpen &&
        other.side == side;
  }

  @override
  int get hashCode => Object.hash(isOpen, side);
}

/// One thing the user chose for a conversation, as it lay on its page: what
/// the page shows a frame around.
class AiContextGroup {
  AiContextGroup({
    this.strokes = const <Stroke>[],
    this.images = const <NoteImageElement>[],
    this.stickies = const <StickyNoteElement>[],
    this.pdfBounds,
    this.page,
  });

  /// What [selection] holds, less [except]: the strokes a conversation drew
  /// itself are not what was chosen.
  factory AiContextGroup.of(
    InkSelection selection, {
    Object? page,
    Set<Stroke>? except,
  }) {
    return AiContextGroup(
      strokes: <Stroke>[
        for (final Stroke stroke in selection.strokes)
          if (except == null || !except.contains(stroke)) stroke,
      ],
      images: selection.images,
      stickies: selection.stickies,
      pdfBounds: selection.pdfBounds,
      page: page,
    );
  }

  final List<Stroke> strokes;
  final List<NoteImageElement> images;
  final List<StickyNoteElement> stickies;
  final Rect? pdfBounds;

  /// The page it lies on, as the editor named it; null when not known, as
  /// for a conversation saved with the note.
  final Object? page;

  /// Where it lies on its page, or null when it holds nothing.
  Rect? get bounds {
    Rect? bounds = pdfBounds;
    void add(Rect rect) => bounds = bounds?.expandToInclude(rect) ?? rect;
    for (final Stroke stroke in strokes) {
      add(stroke.bounds);
    }
    for (final NoteImageElement image in images) {
      add(image.bounds);
    }
    for (final StickyNoteElement sticky in stickies) {
      add(sticky.bounds);
    }
    return bounds;
  }
}

/// The ink one conversation is about: the snapshot taken when AI was
/// pressed, and the image made from it. The snapshot never changes; the
/// image arrives shortly after, and is drawn again over any ink that later
/// appears where the snapshot lies, the assistant's own notes included.
class AiSelectionContext {
  AiSelectionContext._(
    this._snapshot, {
    this._loadBitmaps,
    this._groups = const <AiContextGroup>[],
  }) : isPage = false;

  /// A conversation about nothing on the note: a question asked with
  /// nothing selected. The model is sent blank paper in place of ink, and
  /// its notes go in the blank space of whichever page is shown.
  AiSelectionContext._page(this._snapshot)
    : isPage = true,
      _groups = const <AiContextGroup>[],
      _renderStarted = true,
      _image = SelectionImage(
        png: _blankPaperPng,
        width: 16,
        height: 16,
        scale: 1,
        logicalBounds: Rect.zero,
      );

  /// A 16 x 16 white PNG: something to attach where there is no ink, since
  /// every request carries a picture.
  static final Uint8List _blankPaperPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFElEQVR42mP4TyJgGNUwqmH4'
    'agAAr639H23ooMoAAAAASUVORK5CYII=',
  );

  SelectionInkSnapshot _snapshot;

  List<AiContextGroup> _groups;

  /// Follows strokes the editor replaced: ink moved is still the ink chosen.
  /// Returns whether any of it was.
  bool _followStrokes(Map<Stroke, Stroke> replaced) {
    if (isPage || !_snapshot.sourceStrokes.any(replaced.containsKey)) {
      return false;
    }
    _snapshot = _snapshot.withSourceReplaced(replaced);
    _groups = <AiContextGroup>[
      for (final AiContextGroup group in _groups)
        AiContextGroup(
          strokes: <Stroke>[
            for (final Stroke stroke in group.strokes)
              replaced[stroke] ?? stroke,
          ],
          images: group.images,
          stickies: group.stickies,
          pdfBounds: group.pdfBounds,
          page: group.page,
        ),
    ];
    return true;
  }

  /// Whether nothing on the note was chosen for this conversation.
  final bool isPage;

  /// Each thing chosen for the conversation, as it lies on its page. One
  /// group, taken from the snapshot, for a conversation saved with the
  /// note; none for a [isPage] conversation.
  List<AiContextGroup> get groups {
    if (_groups.isNotEmpty || isPage) return _groups;
    return <AiContextGroup>[
      AiContextGroup(
        strokes: _snapshot.sourceStrokes,
        images: _snapshot.sourceImages,
        stickies: _snapshot.stickies,
        pdfBounds: _snapshot.explicitBounds,
      ),
    ];
  }

  /// The ink as it was when the conversation began. A conversation saved
  /// with the note gets its bitmaps back when its image is first drawn.
  SelectionInkSnapshot get snapshot => _snapshot;

  /// Reads a saved conversation's bitmaps again, once, before its image is
  /// drawn.
  Future<List<SnapshotBitmap>> Function()? _loadBitmaps;
  bool _renderStarted = false;
  SelectionImage? _image;
  SelectionImageException? _imageError;

  /// The page-coordinate range this conversation currently owns. This is
  /// updated synchronously when returned notation expands the range, while
  /// the cropped preview catches up asynchronously.
  Rect? _logicalBounds;

  /// The strokes lying where the snapshot does when it was taken, which
  /// were left out of it on purpose. Null until first looked for.
  Set<Stroke>? _present;

  /// The ink drawn over the snapshot in [image]: what appeared where it
  /// lies since.
  List<Stroke> _ink = const <Stroke>[];

  /// The latest redraw over new ink, which the next one waits for.
  Future<void>? _refreshing;

  /// The image shown in the panel and sent to the model. Null until it has
  /// been drawn.
  SelectionImage? get image => _image;

  /// Null for a [isPage] conversation: its notes go wherever the shown page
  /// is blank.
  Rect? get logicalBounds =>
      _logicalBounds ?? (isPage ? null : _image?.logicalBounds);

  /// Why there is no image, if drawing failed.
  SelectionImageException? get imageError => _imageError;

  bool get isRendering => _image == null && _imageError == null;
}

/// One remembered conversation and the selection it belongs to.
class _AiConversation {
  _AiConversation(this.context, this.lastUsed);

  /// Replaced when more ink is added to the conversation.
  AiSelectionContext context;
  int lastUsed;

  /// The strokes this conversation's answers drew on the note. Selecting
  /// them finds this conversation, as its own ink does.
  final Set<Stroke> notationStrokes = Set<Stroke>.identity();

  /// The pages it has been had on, as the editor named them: where its ink
  /// was chosen, and where its messages were sent from.
  final Set<Object> pages = Set<Object>.identity();
  List<AiMessage> messages = const <AiMessage>[];
  AiRequestState requestState = AiRequestState.idle;
  AiFailure? failure;
  String? partialAnswer;
  bool partialAnswerComplete = false;
  bool sendingWithNotation = false;
  int requestToken = 0;

  /// What each answer's paragraphs are tied to on the note, by message index.
  final Map<int, AiAnswerLinks> links = <int, AiAnswerLinks>{};

  /// What the line numbers of the request in flight mean.
  AiSourceMap? source;
}

/// The AI assistant for one editor session: where the panel is, what ink
/// the conversation is about, the conversation, and the request in flight.
///
/// It never touches the ink. It is handed a selection when AI is pressed,
/// copies what it needs, and from then on works from that copy. Nothing is
/// sent until [send], [sendQuickAction], or [retry] is called.
class AiAssistantController extends ChangeNotifier {
  AiAssistantController({
    required this._client,
    this.renderer = const SelectionImageRenderer(),
    this.captureNote,
    this.applyNotation,
    this.previewNotation,
    this.endNotationPreview,
    this.inkInArea,
    this.shownPage,
    AiPanelSide side = AiPanelSide.left,
    this._notationEnabled = false,
    this._animationEnabled = true,
    AiUsageGate? usageGate,
  }) : _placement = ValueNotifier<AiPanelPlacement>(
         AiPanelPlacement(isOpen: false, side: side),
       ) {
    this.usageGate = usageGate;
  }

  AiUsageGate? _usageGate;
  AiModelId? _selectedModel;

  /// Decides which models may be used and is charged for each answer.
  /// Without one, every model may be used and nothing is metered.
  AiUsageGate? get usageGate => _usageGate;

  set usageGate(AiUsageGate? gate) {
    if (identical(gate, _usageGate) || _disposed) {
      return;
    }
    _usageGate?.removeListener(_onGateChanged);
    _usageGate = gate;
    gate?.addListener(_onGateChanged);
    notifyListeners();
  }

  void _onGateChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// The models the user can pick between; empty when the client serves
  /// only one.
  List<AiModelId> get models {
    final AiClient client = _client;
    return client is AiModelRouter ? client.models : const <AiModelId>[];
  }

  /// The model the next message goes to: the one picked in this editor,
  /// else the one last picked anywhere, else the client's default. Null
  /// when the client serves only one.
  AiModelId? get selectedModel {
    final AiClient client = _client;
    if (client is! AiModelRouter) {
      return null;
    }
    return _selectedModel ?? _usageGate?.preferredModel ?? client.defaultModel;
  }

  /// Sends the next messages to [model], and remembers the choice.
  void selectModel(AiModelId model) {
    if (_disposed || !models.contains(model) || model == selectedModel) {
      return;
    }
    _selectedModel = model;
    _usageGate?.setPreferredModel(model);
    notifyListeners();
  }

  /// What the plan allows with [model]; null when nothing is metered.
  AiModelAccess? accessFor(AiModelId model) => _usageGate?.accessFor(model);

  /// Whether [model] has a key to send with.
  bool isModelConfigured(AiModelId model) {
    final AiClient client = _client;
    return client is AiModelRouter
        ? client.isModelConfigured(model)
        : client.isConfigured;
  }

  final AiClient _client;
  final SelectionImageRenderer renderer;
  final AiNoteCapture? captureNote;
  final AiNotationApply? applyNotation;

  /// Shows a notation as it is written. [endNotationPreview] follows, once
  /// the answer has been dealt with: added notes replace it within one frame.
  final AiNotationPreview? previewNotation;
  final AiNotationPreviewEnd? endNotationPreview;

  /// Finds the ink that has appeared where a conversation's ink lies, to
  /// draw over its image. Without it, the image stays as first drawn.
  final AiAreaInk? inkInArea;

  /// The page on screen now, named as the editor names pages to [open]. Without
  /// it, conversations are not told apart by page.
  final Object? Function()? shownPage;
  final ValueNotifier<AiPanelPlacement> _placement;

  final List<_AiConversation> _conversations = <_AiConversation>[];

  /// Inactive conversations may still be receiving an answer or rendering.
  bool get hasPendingWork => _conversations.any(
    (conversation) =>
        conversation.requestState == AiRequestState.sending ||
        (conversation.context._renderStarted &&
            conversation.context.isRendering),
  );
  _AiConversation? _conversation;

  /// The last conversation, put aside by [show] on a page it was not had on,
  /// for [show] to take up again back on one it was.
  _AiConversation? _setAside;
  int _conversationClock = 0;
  bool _selectionChanged = false;
  bool _selectionHasChat = false;

  /// Whether the assistant may draw on the note. Only a controller that can
  /// [captureNote] and [applyNotation] should start with it on.
  bool _notationEnabled;

  /// On at every launch, so notations are drawn over time unless turned
  /// off for this session.
  bool _animationEnabled;

  /// The notation being drawn on the note, if any.
  AiNotationPresentation? _presentation;

  /// Goes up each time Notation is turned off, so that a request sent
  /// before that can never draw, even if Notation is back on when it ends.
  int _notationRevocations = 0;
  int _animationRevocations = 0;
  bool _disposed = false;
  final _SessionNotifier _session = _SessionNotifier();

  /// The composer's unsent text. Kept here so it outlives the panel.
  String get draft => _draft;
  String _draft = '';
  set draft(String value) {
    _draft = value;
    if (!_disposed) _hasDraft.value = value.trim().isNotEmpty;
  }

  /// Whether [draft] holds anything but blanks, for those who need to know
  /// as soon as it changes, typing included.
  ValueListenable<bool> get hasDraft => _hasDraft;
  final ValueNotifier<bool> _hasDraft = ValueNotifier<bool>(false);

  /// Fires when something [toJson] saves has changed: a message was added
  /// or settled, or a conversation's ink grew. Never while an answer
  /// streams in.
  Listenable get sessionListenable => _session;

  /// Fires only when the panel opens, closes, or changes side.
  ValueListenable<AiPanelPlacement> get placement => _placement;

  bool get isOpen => _placement.value.isOpen;

  AiPanelSide get side => _placement.value.side;

  /// The ink the conversation is about, if AI has been opened.
  AiSelectionContext? get context => _conversation?.context;

  /// The paragraph last read in the panel, and what to show for it on the
  /// note, which stays until another takes its place. Changes as the chat
  /// scrolls, without rebuilding the panel.
  ValueListenable<AiParagraphFocus?> get paragraphFocus => _paragraphFocus;
  final ValueNotifier<AiParagraphFocus?> _paragraphFocus =
      ValueNotifier<AiParagraphFocus?>(null);

  /// Lets [reveal] bring what [paragraphFocus] holds into view on [page], for
  /// as long as that page is built.
  void addNoteRevealer(Object page, bool Function() reveal) {
    _noteRevealers[page] = reveal;
  }

  void removeNoteRevealer(Object page, bool Function() reveal) {
    if (_noteRevealers[page] == reveal) _noteRevealers.remove(page);
  }

  final Map<Object, bool Function()> _noteRevealers =
      Map<Object, bool Function()>.identity();

  /// What message [message]'s paragraphs are tied to. Only the notation model
  /// ties them, so an answer has none until its drawing pass has finished.
  AiAnswerLinks? answerLinks(int message) => _conversation?.links[message];

  /// Makes [ref] the paragraph being read. With no paragraph, or one tied to
  /// nothing on the note, the last one stays, unless it was another
  /// conversation's: its numbers mean nothing in this one.
  void focusParagraph(AiParagraphRef? ref) {
    if (_disposed) return;
    final AiParagraphLinks? links = ref == null
        ? null
        : answerLinks(ref.message)?.paragraphs[ref.paragraph];
    if (ref == null || links == null || links.isEmpty) {
      if (!identical(_focusConversation, _conversation)) {
        _paragraphFocus.value = null;
      }
    } else if (_paragraphFocus.value?.ref != ref ||
        !identical(_paragraphFocus.value?.links, links)) {
      _paragraphFocus.value = AiParagraphFocus(ref, links);
    }
    _focusConversation = _conversation;
  }

  /// The conversation [paragraphFocus] holds a paragraph of.
  _AiConversation? _focusConversation;

  /// Brings the focused paragraph's ink on [page] into view, moving nothing if
  /// it all is already. Returns false when that page is not built, being too
  /// far from what is on screen.
  bool revealOnNote(Object page) {
    if (_disposed) return false;
    return _noteRevealers[page]?.call() ?? false;
  }

  AiParagraphRef? _paragraphToShow;

  /// The paragraph the panel should scroll to, since the strokes drawn for it
  /// were selected on the note; null when none has been asked for since this
  /// was last called.
  AiParagraphRef? takeParagraphToShow() {
    final AiParagraphRef? ref = _paragraphToShow;
    _paragraphToShow = null;
    return ref;
  }

  /// Finds the paragraph that most of [selection]'s strokes were drawn for,
  /// and asks the panel to show it. Selecting a drawing leads to its words.
  void _showParagraphDrawing(InkSelection? selection) {
    final _AiConversation? conversation = _conversation;
    if (selection == null || conversation == null) return;
    AiParagraphRef? best;
    int most = 0;
    for (final MapEntry<int, AiAnswerLinks> answer
        in conversation.links.entries) {
      for (final MapEntry<int, AiParagraphLinks> paragraph
          in answer.value.paragraphs.entries) {
        final Set<Stroke> drawn = paragraph.value.drawn;
        if (drawn.isEmpty) continue;
        final int count = selection.strokes.where(drawn.contains).length;
        if (count > most) {
          most = count;
          best = AiParagraphRef(answer.key, paragraph.key);
        }
      }
    }
    if (best != null) {
      _paragraphToShow = best;
      focusParagraph(best);
    }
  }

  /// The conversation, oldest first. While a request is being sent, or has
  /// failed, the last message is the user's unanswered one.
  List<AiMessage> get messages =>
      _conversation?.messages ?? const <AiMessage>[];

  AiRequestState get requestState =>
      _conversation?.requestState ?? AiRequestState.idle;

  /// Why the last request failed. Null unless [requestState] is
  /// [AiRequestState.failed].
  AiFailure? get failure => _conversation?.failure;

  /// The answer's message as far as it has been written, while it streams
  /// in. Null when no request is in flight or nothing has arrived yet. It
  /// becomes a message in [messages], with any notation applied, only once
  /// the whole answer has arrived and been checked.
  String? get partialAnswer => _conversation?.partialAnswer;

  /// Whether all of [partialAnswer] has arrived, and only the rest of the
  /// answer, its notation if any, is still on its way.
  bool get partialAnswerComplete =>
      _conversation?.partialAnswerComplete ?? false;

  /// The readable answer is complete and visible, while the separately
  /// generated notation is still on its way.
  bool get isLoadingNotation =>
      requestState == AiRequestState.sending &&
      sendingWithNotation &&
      partialAnswerComplete &&
      (partialAnswer?.trim().isNotEmpty ?? false);

  /// Whether the request in flight was sent with Notation on, and so may
  /// still draw when it ends.
  bool get sendingWithNotation {
    final _AiConversation? conversation = _conversation;
    return conversation?.requestState == AiRequestState.sending &&
        conversation!.sendingWithNotation;
  }

  /// Whether the editor's selection is no longer the ink in [context].
  bool get selectionChanged => _selectionChanged;

  /// Whether the editor's changed selection belongs to another remembered
  /// conversation, which [useSelection] would resume rather than start.
  bool get selectionHasChat => _selectionHasChat;

  /// False when there is no API key to send with.
  bool get isConfigured {
    final AiModelId? model = selectedModel;
    return model == null ? _client.isConfigured : isModelConfigured(model);
  }

  String get modelLabel => selectedModel?.label ?? _client.modelLabel;

  bool get notationEnabled => _notationEnabled;

  bool get animationEnabled => _animationEnabled;

  /// Whether the assistant's notes always show on the note.
  /// When off, they only show while AI mode is active.
  bool get showNotesInChat => _showNotesInChat;
  bool _showNotesInChat = true;

  void setShowNotesInChat(bool show) {
    if (_disposed || show == _showNotesInChat) {
      return;
    }
    _showNotesInChat = show;
    notifyListeners();
  }

  void setNotationEnabled(bool enabled) {
    if (_disposed || enabled == _notationEnabled) {
      return;
    }
    _notationEnabled = enabled;
    if (!enabled) {
      _notationRevocations++;
    }
    notifyListeners();
  }

  void setAnimationEnabled(bool enabled) {
    if (_disposed || enabled == _animationEnabled) {
      return;
    }
    _animationEnabled = enabled;
    if (!enabled) {
      _animationRevocations++;
      // Existing motion stops only when its own animation setting is turned
      // off. Closing the assistant or disabling future notation does not own
      // or stop playback already living on the note. Playbacks older than
      // [_presentation] are stopped by the editor, which hears this change.
      _presentation?.finish();
    }
    notifyListeners();
  }

  /// Whether a notation is being drawn on the note now.
  bool get isDrawingNotation => _presentation != null;

  /// Shows the notation being drawn whole, at once. It is already on the
  /// note, so nothing is added.
  void finishNotationDrawing() => _presentation?.finish();

  /// Whether a message could be sent now. With no conversation open, one
  /// is started about nothing on the note, whose notes go in the shown
  /// page's blank space.
  bool get canSend {
    final AiSelectionContext? context = this.context;
    return isConfigured &&
        requestState != AiRequestState.sending &&
        (context == null || context.image != null);
  }

  /// Whether the conversation is about something chosen on the note, so a
  /// quick action has something to act on.
  bool get hasSelection {
    final AiSelectionContext? context = this.context;
    return context != null && !context.isPage;
  }

  /// Shows the panel for [selection]. A remembered conversation resumes when
  /// more than half of either its strokes or the current selection overlap;
  /// otherwise a new conversation is started. Sends nothing.
  ///
  /// With [ask], a chat already open stays as it is when [selection] is
  /// not about it, whatever it holds, and offers to add the selection to it
  /// or to start another.
  void open(
    InkSelection selection, {
    required Brightness brightness,
    required Color background,
    SelectionInkSnapshot? snapshot,
    Object? page,
    bool ask = false,
  }) {
    if (_disposed) {
      return;
    }
    final _AiConversation? current = _conversation;
    if (ask && isOpen && current != null && !_matches(current, selection)) {
      _selectionChanged = true;
      _selectionHasChat = _bestMatch(selection) != null;
      notifyListeners();
      return;
    }
    _activateOrCapture(
      selection,
      brightness: brightness,
      background: background,
      snapshot: snapshot,
      page: page,
    );
    _selectionChanged = false;
    _selectionHasChat = false;
    _showParagraphDrawing(selection);
    _placement.value = AiPanelPlacement(isOpen: true, side: side);
    notifyListeners();
  }

  /// Uses [selection], resuming its remembered conversation when it overlaps
  /// one sufficiently, or starting a new one otherwise.
  void useSelection(
    InkSelection selection, {
    required Brightness brightness,
    required Color background,
    SelectionInkSnapshot? snapshot,
    Object? page,
  }) {
    if (_disposed) {
      return;
    }
    _activateOrCapture(
      selection,
      brightness: brightness,
      background: background,
      snapshot: snapshot,
      page: page,
    );
    _selectionChanged = false;
    _selectionHasChat = false;
    _showParagraphDrawing(selection);
    notifyListeners();
  }

  /// Shows the panel without choosing new ink. Sends nothing. The last
  /// conversation resumes when it was had on the page shown; on any other page
  /// the panel shows none, ready to start one, and the last conversation can
  /// still be found through its ink.
  void show() {
    if (_disposed || isOpen) {
      return;
    }
    _resumeOnShownPage();
    _placement.value = AiPanelPlacement(isOpen: true, side: side);
  }

  void _resumeOnShownPage() {
    final Object? page = shownPage?.call();
    final _AiConversation? last = _conversation ?? _setAside;
    if (page == null || last == null) {
      return;
    }
    final _AiConversation? resumed = last.pages.contains(page) ? last : null;
    if (identical(resumed, _conversation)) {
      return;
    }
    _setAside = resumed == null ? last : null;
    _conversation = resumed;
    _selectionChanged = false;
    _selectionHasChat = false;
    focusParagraph(null);
    notifyListeners();
  }

  /// Adds [words] to the end of [draft], a single space apart from what is
  /// there, for the composer to show. Blank words change nothing.
  void appendToDraft(String words) {
    final String text = words.trim();
    if (_disposed || text.isEmpty) {
      return;
    }
    final String before = draft.trimRight();
    draft = before.isEmpty ? text : '$before $text';
    notifyListeners();
  }

  /// Hides the panel. The conversation, and a request in flight, carry on.
  void close() {
    if (_disposed) {
      return;
    }
    _composerRequested = false;
    _placement.value = AiPanelPlacement(isOpen: false, side: side);
  }

  bool _composerRequested = false;

  /// Asks the panel to put the caret in its composer, bringing up the
  /// keyboard, as soon as it shows: for typing about what was just chosen.
  void requestComposer() {
    if (_disposed) {
      return;
    }
    _composerRequested = true;
    notifyListeners();
  }

  /// Whether [requestComposer] has been asked since this was last called.
  bool takeComposerRequest() {
    final bool requested = _composerRequested;
    _composerRequested = false;
    return requested;
  }

  void setSide(AiPanelSide side) {
    if (_disposed) {
      return;
    }
    _placement.value = AiPanelPlacement(isOpen: isOpen, side: side);
  }

  /// Tells the assistant what the editor has selected now, so that it can
  /// say when that is no longer the ink under discussion. The conversation
  /// and its image are left alone.
  void updateCurrentSelection(InkSelection? selection) {
    if (_disposed) {
      return;
    }
    final _AiConversation? conversation = _conversation;
    final bool changed =
        conversation != null &&
        selection != null &&
        !_matches(conversation, selection);
    final bool hasChat = changed && _bestMatch(selection) != null;
    if (!changed) _showParagraphDrawing(selection);
    if (changed != _selectionChanged ||
        hasChat != _selectionHasChat ||
        _paragraphToShow != null) {
      _selectionChanged = changed;
      _selectionHasChat = hasChat;
      notifyListeners();
    }
  }

  /// The strokes drawn by the answers of the remembered conversation that
  /// [selection] belongs to, as [useSelection] would find it; empty when it
  /// belongs to none. They may be on any page, or have left the note.
  Iterable<Stroke> notationStrokesFor(InkSelection selection) {
    return _bestMatch(selection)?.notationStrokes ?? const <Stroke>[];
  }

  /// The AI notation that still belongs to [strokes], in the order it is in
  /// the note. Unlike [notationStrokesFor], this is independent of the
  /// current selection, so page-level controls can find every AI mark.
  Iterable<Stroke> notationStrokesIn(Iterable<Stroke> strokes) {
    final Set<Stroke> notation = Set<Stroke>.identity();
    for (final _AiConversation conversation in _conversations) {
      notation.addAll(conversation.notationStrokes);
    }
    return <Stroke>[
      for (final Stroke stroke in strokes)
        if (notation.contains(stroke)) stroke,
    ];
  }

  /// Follows strokes the editor replaced, such as ink moved with the
  /// selection: a replacement of the ink a conversation is about is still
  /// what it is about, and one drawn by its answer is still its own. A stroke
  /// its answer drew is kept when replaced, for an undo to restore.
  void followReplacedStrokes(Map<Stroke, Stroke> replaced) {
    if (_disposed) {
      return;
    }
    bool changed = false;
    bool contextChanged = false;
    for (final _AiConversation conversation in _conversations) {
      for (final MapEntry<Stroke, Stroke> entry in replaced.entries) {
        if (conversation.notationStrokes.contains(entry.key)) {
          changed = conversation.notationStrokes.add(entry.value) || changed;
        }
      }
      for (final AiAnswerLinks links in conversation.links.values) {
        changed = links.follow(replaced) || changed;
      }
      contextChanged =
          conversation.context._followStrokes(replaced) || contextChanged;
    }
    if (changed || contextChanged) {
      _session.notify();
    }
    if (contextChanged) {
      notifyListeners();
    }
  }

  /// Adds [selection]'s ink to the open conversation, so that it and the
  /// ink already there are sent together from the next message on. The
  /// messages are kept; a request in flight keeps the image it was sent
  /// with.
  void addToContext(
    InkSelection selection, {
    List<SnapshotBitmap> bitmaps = const <SnapshotBitmap>[],
    Object? page,
  }) {
    final _AiConversation? conversation = _conversation;
    if (_disposed || conversation == null) {
      return;
    }
    final AiContextGroup group = AiContextGroup.of(
      selection,
      page: page,
      // What the conversation drew is already its own.
      except: conversation.notationStrokes,
    );
    final SelectionInkSnapshot? merged = SelectionInkSnapshot.merged(
      conversation.context.snapshot,
      group.strokes,
      images: group.images,
      stickies: group.stickies,
      pdfBounds: group.pdfBounds,
      bitmaps: bitmaps,
    );
    _selectionChanged = false;
    _selectionHasChat = false;
    if (merged != null) {
      if (page != null) conversation.pages.add(page);
      final AiSelectionContext previous = conversation.context;
      final AiSelectionContext context = AiSelectionContext._(
        merged,
        groups: <AiContextGroup>[...previous.groups, group],
      );
      // Ink drawn over the old image is still new to the larger one.
      _notePresent(context, except: previous._ink);
      conversation.context = context;
      conversation.lastUsed = ++_conversationClock;
      unawaited(_render(context).then((void _) => _refresh(conversation)));
      _session.notify();
    }
    notifyListeners();
  }

  /// Removes one chosen group from the open conversation. Messages stay in
  /// their thread, while subsequent requests use only the groups left on the
  /// note. Removing the last group turns the thread into a page-level chat.
  void removeContext(AiContextGroup group) {
    final _AiConversation? conversation = _conversation;
    if (_disposed || conversation == null || conversation.context.isPage) {
      return;
    }
    final AiSelectionContext previous = conversation.context;
    final List<AiContextGroup> groups = previous.groups;
    final int removed = groups.indexWhere(
      (AiContextGroup candidate) =>
          identical(candidate, group) || _sameContextGroup(candidate, group),
    );
    if (removed < 0) return;

    final List<AiContextGroup> remaining = <AiContextGroup>[
      for (int i = 0; i < groups.length; i++)
        if (i != removed) groups[i],
    ];
    final AiSelectionContext next;
    if (remaining.isEmpty) {
      next = AiSelectionContext._page(
        _emptySnapshot(
          brightness: previous.snapshot.brightness,
          background: previous.snapshot.background,
        ),
      );
    } else {
      Rect? pdfBounds;
      for (final AiContextGroup kept in remaining) {
        if (kept.pdfBounds case final Rect bounds) {
          pdfBounds = pdfBounds?.expandToInclude(bounds) ?? bounds;
        }
      }
      next = AiSelectionContext._(
        previous.snapshot.retaining(
          sourceStrokes: <Stroke>[
            for (final AiContextGroup kept in remaining) ...kept.strokes,
          ],
          sourceImages: <NoteImageElement>[
            for (final AiContextGroup kept in remaining) ...kept.images,
          ],
          stickies: <StickyNoteElement>[
            for (final AiContextGroup kept in remaining) ...kept.stickies,
          ],
          explicitBounds: pdfBounds,
        ),
        groups: remaining,
      );
      _notePresent(next);
    }
    conversation
      ..context = next
      ..lastUsed = ++_conversationClock;
    _selectionChanged = false;
    _selectionHasChat = false;
    if (!next.isPage) {
      unawaited(_render(next).then((void _) => _refresh(conversation)));
    }
    _session.notify();
    notifyListeners();
  }

  static bool _sameContextGroup(AiContextGroup a, AiContextGroup b) {
    bool sameIdentities<T>(List<T> left, List<T> right) {
      if (left.length != right.length) return false;
      for (int i = 0; i < left.length; i++) {
        if (!identical(left[i], right[i])) return false;
      }
      return true;
    }

    return identical(a.page, b.page) &&
        a.pdfBounds == b.pdfBounds &&
        sameIdentities(a.strokes, b.strokes) &&
        sameIdentities(a.images, b.images) &&
        sameIdentities(a.stickies, b.stickies);
  }

  /// Draws the open conversation's image again over the ink that has been
  /// added, or taken away, where its ink lies since it was last drawn. Not
  /// while a message is being sent: sending drew it afresh itself.
  void refreshContextImage() {
    final _AiConversation? conversation = _conversation;
    if (_disposed ||
        inkInArea == null ||
        conversation == null ||
        conversation.requestState == AiRequestState.sending) {
      return;
    }
    unawaited(_refresh(conversation));
  }

  /// Sends [text] as the user's next message. Returns false, and changes
  /// nothing, when it is blank or nothing can be sent now.
  bool send(String text) => _submit(AiMessage.user(text.trim()));

  /// Sends [action]'s prompt, shown in the conversation under its label.
  /// Returns false without a selection: the prompts are about chosen ink.
  bool sendQuickAction(AiQuickAction action) {
    if (!hasSelection) return false;
    return _submit(AiMessage.user(action.prompt, label: action.label));
  }

  /// Sends the unanswered message again. Returns false, and changes
  /// nothing, unless the last request failed.
  bool retry() {
    if (_disposed || requestState != AiRequestState.failed || !canSend) {
      return false;
    }
    _start(_conversation!);
    return true;
  }

  bool _submit(AiMessage message) {
    if (_disposed || message.text.isEmpty || !canSend) {
      return false;
    }
    final _AiConversation conversation =
        _conversation ?? _startPageConversation();
    if (shownPage?.call() case final Object page) {
      conversation.pages.add(page);
    }
    conversation.messages = List<AiMessage>.unmodifiable(<AiMessage>[
      // A message that failed and was never answered is replaced, so that
      // turns keep alternating.
      ...conversation.messages.take(
        conversation.requestState == AiRequestState.failed
            ? conversation.messages.length - 1
            : conversation.messages.length,
      ),
      message,
    ]);
    _start(conversation);
    _session.notify();
    return true;
  }

  /// Starts, and makes current, a conversation about nothing on the note.
  _AiConversation _startPageConversation() {
    final _AiConversation conversation = _AiConversation(
      AiSelectionContext._page(_emptySnapshot()),
      ++_conversationClock,
    );
    _conversations.add(conversation);
    _conversation = conversation;
    _selectionChanged = false;
    _selectionHasChat = false;
    return conversation;
  }

  /// No ink. Its theme only colours the assistant's notes in a later image,
  /// should the conversation take ink in.
  static SelectionInkSnapshot _emptySnapshot({
    Brightness brightness = Brightness.light,
    Color background = const Color(0xFFFFFFFF),
  }) {
    return SelectionInkSnapshot.restored(
      strokes: const <SnapshotStroke>[],
      brightness: brightness,
      background: background,
    );
  }

  /// Requests an answer to [messages] as they stand.
  void _start(_AiConversation conversation) {
    final SelectionImage image = conversation.context.image!;
    final int token = ++conversation.requestToken;
    final bool notationAuthorized = _notationEnabled;
    final bool animationAuthorized = notationAuthorized && _animationEnabled;
    final int revocations = _notationRevocations;
    final int animationRevocations = _animationRevocations;
    final AiModelId? model = selectedModel;
    conversation.requestState = AiRequestState.sending;
    conversation.failure = null;
    conversation.partialAnswer = null;
    conversation.partialAnswerComplete = false;
    conversation.sendingWithNotation = notationAuthorized;
    notifyListeners();
    unawaited(
      _sendRequest(
        conversation,
        token,
        image,
        notationAuthorized,
        animationAuthorized,
        revocations,
        animationRevocations,
        model,
      ),
    );
  }

  Future<void> _sendRequest(
    _AiConversation conversation,
    int token,
    SelectionImage image,
    bool notationAuthorized,
    bool animationAuthorized,
    int revocations,
    int animationRevocations,
    AiModelId? model,
  ) async {
    void finish(AiResult result, {NoteImage? noteImage}) {
      _finish(
        conversation,
        token,
        result,
        notationAuthorized: notationAuthorized,
        animationAuthorized: animationAuthorized,
        revocations: revocations,
        animationRevocations: animationRevocations,
        noteImage: noteImage,
      );
    }

    final AiUsageGate? gate = _usageGate;
    if (gate != null && model != null) {
      final AiFailure? refused = gate.checkAccess(model);
      if (refused != null) {
        // Answered at once, so the panel's message and its choices show.
        await Future<void>.value();
        finish(AiError(refused));
        return;
      }
    }
    // The model sees the ink as it is now: its own earlier notes, and what
    // the user has written since, where the conversation's ink lies.
    if (inkInArea != null) {
      final AiSelectionContext context = conversation.context;
      await _refresh(conversation);
      if (_disposed || token != conversation.requestToken) {
        return;
      }
      image = context.image ?? image;
    }
    NoteImage? noteImage;
    if (notationAuthorized) {
      final AiNoteCapture? capture = captureNote;
      if (capture == null) {
        finish(const AiError(AiFailure(AiFailureKind.noteUnavailable)));
        return;
      }
      try {
        noteImage = await capture();
      } on Object {
        finish(const AiError(AiFailure(AiFailureKind.noteUnavailable)));
        return;
      }
      if (_disposed || token != conversation.requestToken) {
        return;
      }
    }
    // Drawing also gets the selection as page-coordinate SVG, for exact
    // positions; the clean PNG beside it is what the model reads.
    // A conversation about nothing on the note has no selection to give. With
    // Notation off no model sees it, and so nothing cites it.
    final bool isPage = conversation.context.isPage;
    String? selectionSvg;
    conversation.source = null;
    if (!isPage && noteImage != null) {
      final AiSelectionContext context = conversation.context;
      final SelectionInkSnapshot snapshot = context._snapshot.withInkOver(
        context._ink,
      );
      final List<Stroke?> origins = snapshot.strokeOrigins;
      final Set<int> byAssistant = <int>{
        for (int i = 0; i < origins.length; i++)
          if (conversation.notationStrokes.contains(origins[i])) i,
      };
      const SelectionSvgRenderer svgRenderer = SelectionSvgRenderer();
      final List<SelectionSvgLine> lines;
      try {
        final SelectionSvgDocument document = svgRenderer.document(
          snapshot: snapshot,
          preview: image,
          pageSize: noteImage.logicalSize,
          assistantStrokes: byAssistant,
        );
        selectionSvg = document.svg;
        lines = document.lines;
      } on Object {
        finish(
          const AiError(AiFailure(AiFailureKind.noteUnavailable)),
          noteImage: noteImage,
        );
        return;
      }
      if (lines.isNotEmpty || snapshot.holdsPicture) {
        conversation.source = AiSourceMap(
          lines,
          origins,
          picture: snapshot.holdsPicture ? image.logicalBounds : null,
        );
      }
    }
    if (_disposed || token != conversation.requestToken) {
      return;
    }
    final String noSelection = isPage ? AiPrompts.noSelection : '';
    final NoteImage? liveNote = previewNotation == null ? null : noteImage;
    void endPreview() {
      if (liveNote != null && !_disposed) {
        endNotationPreview?.call(liveNote);
      }
    }

    final AiRequest request;
    final AiResult result;
    try {
      result = await _client.send(
        request = AiRequest(
          systemInstruction:
              (notationAuthorized
                  ? AiPrompts.textSystem
                  : AiPrompts.systemFor(notationEnabled: false)) +
              noSelection,
          notationInstruction: notationAuthorized
              ? AiPrompts.systemFor(
                      notationEnabled: true,
                      animationEnabled: animationAuthorized,
                      textSize: HandwritingCalibration.textSize.value,
                    ) +
                    noSelection
              : null,
          imagePng: image.png,
          selectionSvg: selectionSvg,
          messages: conversation.messages,
          noteImage: noteImage,
          notationEnabled: notationAuthorized,
          animationEnabled: animationAuthorized,
          model: model,
        ),
        onPartial: (String message, bool isComplete) {
          if (_disposed ||
              token != conversation.requestToken ||
              (message == conversation.partialAnswer &&
                  isComplete == conversation.partialAnswerComplete)) {
            return;
          }
          conversation.partialAnswer = message;
          conversation.partialAnswerComplete = isComplete;
          if (identical(conversation, _conversation)) {
            notifyListeners();
          }
        },
        onNotation: liveNote == null
            ? null
            : (String svg) {
                if (_disposed) return;
                if (token == conversation.requestToken &&
                    _notationEnabled &&
                    revocations == _notationRevocations) {
                  previewNotation?.call(svg, liveNote);
                } else {
                  endPreview();
                }
              },
      );
    } on Object {
      finish(
        const AiError(AiFailure(AiFailureKind.network)),
        noteImage: noteImage,
      );
      endPreview();
      return;
    }
    // The provider charged for the answer whatever becomes of it here.
    if (result case AiSuccess(
      :final String text,
      :final AiTokenUsage? usage,
    ) when gate != null && model != null && !_disposed) {
      gate.recordUsage(model, usage ?? AiTokenUsage.estimate(request, text));
    }
    finish(result, noteImage: noteImage);
    endPreview();
  }

  void _finish(
    _AiConversation conversation,
    int token,
    AiResult result, {
    required bool notationAuthorized,
    required bool animationAuthorized,
    required int revocations,
    required int animationRevocations,
    NoteImage? noteImage,
  }) {
    if (_disposed || token != conversation.requestToken) {
      return;
    }
    final String? streamed = conversation.partialAnswerComplete
        ? conversation.partialAnswer
        : null;
    conversation.partialAnswer = null;
    conversation.partialAnswerComplete = false;
    // The links of the answer about to join the messages, where it goes.
    final AiSourceMap? source = conversation.source;
    final int answerIndex = conversation.messages.length;
    conversation.source = null;
    switch (result) {
      // The whole message had arrived before the answer broke off, while
      // only the notation, if any, was still to come: keep the words, and
      // draw nothing. Not for a blocked answer, which is withheld whole.
      case AiError(:final AiFailure failure)
          when streamed != null &&
              streamed.trim().isNotEmpty &&
              failure.kind != AiFailureKind.blocked:
        conversation.messages = List<AiMessage>.unmodifiable(<AiMessage>[
          ...conversation.messages,
          AiMessage.model(
            streamed.trim(),
            notationStatus: notationAuthorized
                ? AiNotationStatus.notAppliedIncomplete
                : AiNotationStatus.none,
          ),
        ]);
        conversation.requestState = AiRequestState.idle;
      case AiSuccess(
        :final String text,
        :final AiNotation? notation,
        :final bool notationRejected,
        :final Map<int, String> citations,
      ):
        AiNotationStatus status = AiNotationStatus.none;
        AiNotationPresentation? presentation;
        final AiAnswerLinks links =
            source?.resolve(
              citations,
              paragraphs: parseAiAnswer(text).length,
            ) ??
            AiAnswerLinks();
        if (notationRejected) {
          status = notationAuthorized
              ? AiNotationStatus.notAppliedInvalid
              : AiNotationStatus.notAppliedNotationOff;
        } else if (notation != null) {
          if (!notationAuthorized) {
            status = AiNotationStatus.notAppliedNotationOff;
          } else if (!_notationEnabled || revocations != _notationRevocations) {
            status = AiNotationStatus.notAppliedRevoked;
          } else if (noteImage == null || applyNotation == null) {
            status = AiNotationStatus.notAppliedInvalid;
          } else {
            try {
              final bool animate =
                  animationAuthorized &&
                  _animationEnabled &&
                  animationRevocations == _animationRevocations;
              final AiNotation effectiveNotation =
                  notation.timeline == null || animate
                  ? notation
                  : AiNotation(label: notation.label, items: notation.items);
              final AiNotationApplication application = applyNotation!(
                effectiveNotation,
                noteImage,
              );
              status = application.status;
              presentation = application.presentation;
              conversation.notationStrokes.addAll(application.strokes);
              _linkDrawing(links, text, application);
              // Asked about nothing, each answer finds blank space afresh,
              // on whichever page is shown then.
              if (!conversation.context.isPage) {
                _includeNotationInContext(conversation, application.strokes);
              }
            } on Object {
              // A failure here must not leave the request hanging; the ink
              // controller changes nothing unless it can add all of it.
              status = AiNotationStatus.notAppliedInvalid;
            }
          }
        }
        if (!links.isEmpty) conversation.links[answerIndex] = links;
        final AiMessage reply = AiMessage.model(
          text,
          notation: notationAuthorized ? notation : null,
          notationStatus: status,
        );
        conversation.messages = List<AiMessage>.unmodifiable(<AiMessage>[
          ...conversation.messages,
          reply,
        ]);
        if (presentation != null) {
          _watch(presentation, conversation, reply);
        }
        conversation.requestState = AiRequestState.idle;
      case AiError(:final AiFailure failure):
        conversation.requestState = AiRequestState.failed;
        conversation.failure = failure;
    }
    // Shown even with the panel closed, which would otherwise choose it.
    if (identical(conversation, _conversation)) {
      final AiAnswerLinks? arrived = conversation.links[answerIndex];
      final int? first = arrived?.paragraphs.keys.fold<int?>(
        null,
        (int? least, int key) => least == null || key < least ? key : least,
      );
      if (first != null) focusParagraph(AiParagraphRef(answerIndex, first));
    }
    _session.notify();
    if (identical(conversation, _conversation)) {
      notifyListeners();
    }
  }

  /// Ties the strokes [application] added to the paragraphs of [text] they say
  /// they were drawn for. A number past the last paragraph ties nothing.
  static void _linkDrawing(
    AiAnswerLinks links,
    String text,
    AiNotationApplication application,
  ) {
    if (application.paragraphs.isEmpty) return;
    final int paragraphs = parseAiAnswer(text).length;
    for (int i = 0; i < application.strokes.length; i++) {
      if (i >= application.paragraphs.length) break;
      final int? paragraph = application.paragraphs[i];
      if (paragraph != null && paragraph <= paragraphs) {
        links.of(paragraph).drawn.add(application.strokes[i]);
      }
    }
  }

  /// Marks [reply] in [conversation] as added to the note once
  /// [presentation] has finished drawing it, however it finished. Only that
  /// turn changes, and only its local status: what the model said, and so
  /// what is sent back to it, stays as it was. Nothing changes once this has
  /// been disposed.
  void _watch(
    AiNotationPresentation presentation,
    _AiConversation conversation,
    AiMessage reply,
  ) {
    _presentation = presentation;
    presentation.done.then((void _) {
      if (identical(_presentation, presentation)) {
        _presentation = null;
      }
      if (_disposed) {
        return;
      }
      final int index = conversation.messages.indexWhere(
        (AiMessage message) => identical(message, reply),
      );
      if (index >= 0) {
        conversation.messages = List<AiMessage>.unmodifiable(<AiMessage>[
          ...conversation.messages.take(index),
          reply.withNotationStatus(AiNotationStatus.applied),
          ...conversation.messages.skip(index + 1),
        ]);
        _session.notify();
      }
      notifyListeners();
    });
  }

  /// Activates the best remembered conversation for [selection], or creates
  /// one when neither overlap threshold is met.
  void _activateOrCapture(
    InkSelection selection, {
    required Brightness brightness,
    required Color background,
    SelectionInkSnapshot? snapshot,
    Object? page,
  }) {
    final _AiConversation? remembered = _bestMatch(selection);
    if (remembered != null) {
      _conversation = remembered;
      if (page != null) remembered.pages.add(page);
      remembered.lastUsed = ++_conversationClock;
      // A conversation saved with the note is drawn when first resumed, and
      // any is drawn again over what was written where it lies since.
      unawaited(
        _render(remembered.context).then((void _) => _refresh(remembered)),
      );
      return;
    }
    final AiSelectionContext context = AiSelectionContext._(
      snapshot ??
          SelectionInkSnapshot.of(
            selection,
            brightness: brightness,
            background: background,
          ),
      groups: <AiContextGroup>[AiContextGroup.of(selection, page: page)],
    );
    _notePresent(context);
    final _AiConversation conversation = _AiConversation(
      context,
      ++_conversationClock,
    );
    if (page != null) conversation.pages.add(page);
    _conversations.add(conversation);
    _conversation = conversation;
    unawaited(_render(context));
  }

  /// The strokes lying mostly where [context]'s ink does now, as
  /// [inkInArea] finds them, or null when they cannot be found.
  List<Stroke>? _inkIn(
    AiSelectionContext context, [
    Iterable<Stroke> notation = const <Stroke>[],
  ]) {
    final AiAreaInk? find = inkInArea;
    if (find == null) {
      return null;
    }
    final Rect area;
    try {
      area = renderer
          .layout(context._snapshot.withInkOver(context._ink))
          .logicalBounds;
    } on SelectionImageException {
      return null;
    }
    Object? page;
    for (final AiContextGroup group in context.groups) {
      if (group.page != null) {
        page = group.page;
        break;
      }
    }
    return find(area, page, <Stroke>[
      ...context._snapshot.sourceStrokes,
      ...notation,
    ]).toList(growable: false);
  }

  /// Remembers what lies where [context]'s ink does as it is made, less
  /// [except], so that only ink added there later is drawn over it.
  void _notePresent(
    AiSelectionContext context, {
    Iterable<Stroke> except = const <Stroke>[],
  }) {
    final List<Stroke>? ink = _inkIn(context);
    if (ink != null) {
      context._present = Set<Stroke>.identity()
        ..addAll(ink)
        ..removeAll(except);
    }
  }

  /// Draws [conversation]'s image again, after any redraw already under
  /// way, when the ink that has appeared where it lies has changed.
  Future<void> _refresh(_AiConversation conversation) {
    final AiSelectionContext context = conversation.context;
    final Future<void> next = (context._refreshing ?? Future<void>.value())
        .then((void _) => _redraw(conversation, context));
    context._refreshing = next;
    return next;
  }

  Future<void> _redraw(
    _AiConversation conversation,
    AiSelectionContext context,
  ) async {
    if (_disposed || context._image == null) {
      return;
    }
    final Set<Stroke> notation = conversation.notationStrokes;
    final List<Stroke>? inArea = _inkIn(context, notation);
    if (inArea == null) {
      return;
    }
    // A conversation saved with the note cannot know what was there when it
    // began: only its own notes, and what is written from now on, are new.
    final Set<Stroke> present = context._present ??= (Set<Stroke>.identity()
      ..addAll(inArea));
    final List<Stroke> ink = <Stroke>[
      for (final Stroke stroke in inArea)
        if (!context._snapshot.contains(stroke) &&
            (notation.contains(stroke) || !present.contains(stroke)))
          stroke,
    ];
    final List<Stroke> drawn = context._ink;
    if (ink.length == drawn.length &&
        Iterable<int>.generate(
          ink.length,
        ).every((int i) => identical(ink[i], drawn[i]))) {
      return;
    }
    final SelectionImage image;
    try {
      image = await renderer.render(context._snapshot.withInkOver(ink));
    } on Object {
      // The image as last drawn is still the conversation's ink.
      return;
    }
    if (_disposed) {
      return;
    }
    context._ink = ink;
    context._image = image;
    context._logicalBounds = image.logicalBounds;
    if (identical(context, _conversation?.context)) {
      notifyListeners();
    }
  }

  /// Expands the conversation's selected region to every stroke produced by
  /// the returned SVG, including marks drawn outside the original crop.
  void _includeNotationInContext(
    _AiConversation conversation,
    Iterable<Stroke> strokes,
  ) {
    final AiSelectionContext context = conversation.context;
    final Set<Stroke> included = Set<Stroke>.identity()..addAll(context._ink);
    bool changed = false;
    for (final Stroke stroke in strokes) {
      changed = included.add(stroke) || changed;
    }
    if (!changed) return;
    context._ink = List<Stroke>.unmodifiable(included);
    try {
      context._logicalBounds = renderer
          .layout(context._snapshot.withInkOver(context._ink))
          .logicalBounds;
    } on SelectionImageException {
      // The existing range remains usable while the preview redraw retries.
    }
    if (identical(context, _conversation?.context)) notifyListeners();
    final Future<void> next = (context._refreshing ?? Future<void>.value())
        .then((void _) => _renderExpandedContext(context));
    context._refreshing = next;
    unawaited(next);
  }

  Future<void> _renderExpandedContext(AiSelectionContext context) async {
    try {
      final SelectionImage image = await renderer.render(
        context._snapshot.withInkOver(context._ink),
      );
      if (_disposed) return;
      context._image = image;
      context._logicalBounds = image.logicalBounds;
      if (identical(context, _conversation?.context)) notifyListeners();
    } on Object {
      // Keep the earlier preview; the generated native ink is still on the
      // note and will be retried by the next context refresh.
    }
  }

  _AiConversation? _bestMatch(InkSelection selection) {
    _AiConversation? best;
    double bestScore = -1;
    for (final _AiConversation candidate in _conversations) {
      if (!_matches(candidate, selection)) {
        continue;
      }
      // Jaccard similarity favours the remembered conversation with the
      // least unrelated ink. Recency breaks an exact tie predictably.
      final int shared = _sharedContentCount(candidate, selection);
      final int union =
          candidate.context.snapshot.sourceContentCount +
          candidate.notationStrokes.length +
          selection.count +
          selection.imageCount +
          (selection.includesPdf ? 1 : 0) -
          shared;
      final double score = shared / union;
      if (score > bestScore ||
          (score == bestScore &&
              (best == null || candidate.lastUsed > best.lastUsed))) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  /// Either more than 50% of the ink the conversation is about, or at least
  /// 51% of the current selection, must be the same stroke objects. The
  /// strokes its answers drew count towards the selection's share, not the
  /// remembered one, so a large drawing never hides the ink it was about.
  bool _matches(_AiConversation conversation, InkSelection selection) {
    final SelectionInkSnapshot snapshot = conversation.context.snapshot;
    final int shared = _sharedContentCount(conversation, selection);
    final int selectionCount =
        selection.count +
        selection.imageCount +
        (selection.includesPdf ? 1 : 0);
    return shared > 0 &&
        ((snapshot.sharedStrokeCount(selection) +
                        snapshot.sharedImageCount(selection) +
                        snapshot.sharedPdfCount(selection)) *
                    2 >
                snapshot.sourceContentCount ||
            shared * 100 >= selectionCount * 51);
  }

  /// How many of [selection]'s strokes are [conversation]'s ink, or were
  /// drawn by it.
  static int _sharedContentCount(
    _AiConversation conversation,
    InkSelection selection,
  ) {
    final SelectionInkSnapshot snapshot = conversation.context.snapshot;
    int shared = 0;
    for (final Stroke stroke in selection.strokes) {
      if (conversation.notationStrokes.contains(stroke) ||
          snapshot.contains(stroke)) {
        shared++;
      }
    }
    return shared +
        snapshot.sharedImageCount(selection) +
        snapshot.sharedPdfCount(selection);
  }

  Future<void> _render(AiSelectionContext context) async {
    if (context._renderStarted) {
      return;
    }
    context._renderStarted = true;
    final Future<List<SnapshotBitmap>> Function()? load = context._loadBitmaps;
    if (load != null) {
      context._loadBitmaps = null;
      try {
        context._snapshot = context._snapshot.withBitmaps(await load());
      } on Object {
        // The image is still worth drawing from the ink alone.
      }
      if (_disposed) {
        return;
      }
    }
    try {
      context._image = await renderer.render(context.snapshot);
      context._logicalBounds = context._image!.logicalBounds;
    } on SelectionImageException catch (error) {
      context._imageError = error;
    } on Object {
      context._imageError = const SelectionImageException(
        SelectionImageFailure.encodingFailed,
      );
    }
    if (!_disposed && identical(context, _conversation?.context)) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _usageGate?.removeListener(_onGateChanged);
    _disposed = true;
    for (final _AiConversation conversation in _conversations) {
      conversation.requestToken++;
    }
    _placement.dispose();
    _hasDraft.dispose();
    _session.dispose();
    _paragraphFocus.dispose();
    super.dispose();
  }

  /// The remembered conversations, to be saved with the note, or null when
  /// there are none worth keeping. [ink] says where the ink each one is
  /// about, and the ink its answers drew, is in the note now; ink that has
  /// left the note is forgotten. A conversation never sent anything is not
  /// kept, and an answer still on its way is saved as interrupted.
  Map<String, Object?>? toJson(AiInkIndex ink) {
    final List<Object?> conversations = <Object?>[
      for (final _AiConversation conversation in _conversations)
        if (conversation.messages.isNotEmpty)
          _conversationJson(conversation, ink),
    ];
    if (conversations.isEmpty) {
      return null;
    }
    return <String, Object?>{
      'version': aiSessionVersion,
      'conversations': conversations,
    };
  }

  /// Remembers the conversations [json], from [toJson], holds, as if they
  /// had been had in this session: selecting their ink again resumes them.
  /// [ink] finds the note's strokes and images they refer to; one whose ink
  /// has all gone is dropped. [loadBitmap] reads a bitmap under the ink
  /// again, when a conversation's image is first drawn. Nothing is sent,
  /// and the panel stays as it is. Unreadable parts are skipped.
  void restore(
    Map<String, Object?> json,
    AiInkIndex ink, {
    Future<Uint8List?> Function(SnapshotBitmapSource source)? loadBitmap,
  }) {
    if (_disposed || json['version'] != aiSessionVersion) {
      return;
    }
    final Object? list = json['conversations'];
    if (list is! List) {
      return;
    }
    for (final Object? item in list) {
      try {
        final _AiConversation? conversation = _conversationFromJson(
          item! as Map<String, Object?>,
          ink,
          loadBitmap,
        );
        if (conversation != null) {
          _conversations.add(conversation);
          if (conversation.lastUsed > _conversationClock) {
            _conversationClock = conversation.lastUsed;
          }
        }
      } on Object {
        // A conversation that cannot be read is left out; the rest stay.
      }
    }
  }

  static Map<String, Object?> _conversationJson(
    _AiConversation conversation,
    AiInkIndex ink,
  ) {
    final SelectionInkSnapshot snapshot = conversation.context.snapshot;
    List<Object?> refs<T>(Iterable<T> items, AiInkRef? Function(T) locate) {
      return <Object?>[
        for (final T item in items)
          if (locate(item) case (final int page, final int index))
            <int>[page, index],
      ];
    }

    return <String, Object?>{
      'lastUsed': conversation.lastUsed,
      if (conversation.context.isPage) 'page': true,
      'messages': <Object?>[
        for (int i = 0; i < conversation.messages.length; i++)
          <String, Object?>{
            'role': conversation.messages[i].role.name,
            if (conversation.messages[i].role == AiRole.model)
              'wire': conversation.messages[i].wireText
            else
              'text': conversation.messages[i].text,
            'label': ?conversation.messages[i].label,
            'status': conversation.messages[i].notationStatus.name,
            if (conversation.links[i] case final AiAnswerLinks links)
              'links': _linksJson(links, ink),
          },
      ],
      if (conversation.requestState == AiRequestState.failed)
        'failure': conversation.failure?.kind.name,
      'snapshot': <String, Object?>{
        'brightness': snapshot.brightness.name,
        'background': snapshot.background.toARGB32(),
        'strokes': <Object?>[
          for (final SnapshotStroke stroke in snapshot.strokes)
            <String, Object?>{
              'points': <double>[
                for (final InkVector point in stroke.points) ...<double>[
                  point.x,
                  point.y,
                ],
              ],
              'width': stroke.width,
              'color': stroke.color.toARGB32(),
              'dot': stroke.isDot,
              if (stroke.writing != WritingStyle.pen)
                'style': stroke.writing.name,
            },
        ],
        'bitmaps': <Object?>[
          for (final SnapshotBitmap bitmap in snapshot.bitmaps)
            if (bitmap.source case final SnapshotBitmapSource source)
              <String, Object?>{
                'asset': source.assetId,
                'pdfPage': ?source.pdfPageIndex,
                if (source.pdfPageSize case final Size size)
                  'pdfSize': <double>[size.width, size.height],
                'bounds': <double>[
                  bitmap.bounds.left,
                  bitmap.bounds.top,
                  bitmap.bounds.right,
                  bitmap.bounds.bottom,
                ],
                'rotation': bitmap.rotation,
                'affectsCrop': bitmap.affectsCrop,
              },
        ],
        'sourceStrokes': refs(snapshot.sourceStrokes, ink.strokeRef),
        'sourceImages': refs(snapshot.sourceImages, ink.imageRef),
      },
      'notationStrokes': refs(conversation.notationStrokes, ink.strokeRef),
    };
  }

  /// [links] as saved with the note. Ink is found again by its place on it, as
  /// a conversation's own is; what has left the note is forgotten.
  static List<Object?> _linksJson(AiAnswerLinks links, AiInkIndex ink) {
    List<Object?> refs(Iterable<Stroke> strokes) => <Object?>[
      for (final Stroke stroke in strokes)
        if (ink.strokeRef(stroke) case (final int page, final int index))
          <int>[page, index],
    ];
    return <Object?>[
      for (final MapEntry<int, AiParagraphLinks> paragraph
          in links.paragraphs.entries)
        <String, Object?>{
          'paragraph': paragraph.key,
          'ranges': <Object?>[
            for (final AiLineRange range in paragraph.value.ranges)
              <int>[range.first, range.last],
          ],
          'circles': <Object?>[
            for (final Rect circle in paragraph.value.circles)
              <double>[circle.left, circle.top, circle.right, circle.bottom],
          ],
          'cited': refs(paragraph.value.cited),
          'drawn': refs(paragraph.value.drawn),
        },
    ];
  }

  /// Reads what [_linksJson] wrote. Whatever cannot be read is left out: the
  /// words of the answer do not depend on it.
  static AiAnswerLinks _linksFromJson(Object? json, AiInkIndex ink) {
    final AiAnswerLinks links = AiAnswerLinks();
    if (json is! List) return links;
    Iterable<Stroke> strokes(Object? refs) sync* {
      if (refs is! List) return;
      for (final Object? ref in refs) {
        if (ref case [final int page, final int index]) {
          if (ink.stroke((page, index)) case final Stroke stroke) yield stroke;
        }
      }
    }

    for (final Object? item in json) {
      if (item is! Map<String, Object?>) continue;
      final Object? paragraph = item['paragraph'];
      if (paragraph is! int) continue;
      links.paragraphs[paragraph] = AiParagraphLinks(
        ranges: <AiLineRange>[
          for (final Object? range in (item['ranges'] as List?) ?? <Object?>[])
            if (range case [final int first, final int last])
              AiLineRange(first, last),
        ],
        // Older notes stored whole-width bands of a picture as `regions`:
        // they name no detail of it, so they are left behind.
        circles: <Rect>[
          for (final Object? circle
              in (item['circles'] as List?) ?? <Object?>[])
            if (circle case [
              final num left,
              final num top,
              final num right,
              final num bottom,
            ])
              Rect.fromLTRB(
                left.toDouble(),
                top.toDouble(),
                right.toDouble(),
                bottom.toDouble(),
              ),
        ],
        cited: strokes(item['cited']),
        drawn: strokes(item['drawn']),
      );
    }
    return links;
  }

  static _AiConversation? _conversationFromJson(
    Map<String, Object?> json,
    AiInkIndex ink,
    Future<Uint8List?> Function(SnapshotBitmapSource source)? loadBitmap,
  ) {
    List<T> resolve<T>(Object? refs, T? Function(AiInkRef ref) find) {
      return <T>[
        for (final Object? ref in (refs as List?) ?? const <Object?>[])
          if (ref case [final int page, final int index]) ?find((page, index)),
      ];
    }

    double number(Object? value) => (value! as num).toDouble();

    final Map<String, Object?> stored =
        json['snapshot']! as Map<String, Object?>;
    final List<Stroke> sourceStrokes = resolve(
      stored['sourceStrokes'],
      ink.stroke,
    );
    final List<NoteImageElement> sourceImages = resolve(
      stored['sourceImages'],
      ink.image,
    );
    final List<Stroke> notationStrokes = resolve(
      json['notationStrokes'],
      ink.stroke,
    );
    if (sourceStrokes.isEmpty &&
        sourceImages.isEmpty &&
        notationStrokes.isEmpty) {
      // Nothing on the note could find it again.
      return null;
    }
    final List<SnapshotBitmapSource> bitmapSources = <SnapshotBitmapSource>[];
    final List<Map<String, Object?>> bitmapJson = <Map<String, Object?>>[];
    for (final Object? item in (stored['bitmaps'] as List?) ?? <Object?>[]) {
      final Map<String, Object?> bitmap = item! as Map<String, Object?>;
      final List<Object?>? pdfSize = bitmap['pdfSize'] as List?;
      bitmapSources.add(
        SnapshotBitmapSource(
          bitmap['asset']! as String,
          pdfPageIndex: bitmap['pdfPage'] as int?,
          pdfPageSize: pdfSize == null
              ? null
              : Size(number(pdfSize[0]), number(pdfSize[1])),
        ),
      );
      bitmapJson.add(bitmap);
    }
    final SelectionInkSnapshot snapshot = SelectionInkSnapshot.restored(
      brightness: stored['brightness'] == Brightness.dark.name
          ? Brightness.dark
          : Brightness.light,
      background: Color(stored['background']! as int),
      strokes: <SnapshotStroke>[
        for (final Object? item in (stored['strokes'] as List?) ?? <Object?>[])
          if (item case final Map<String, Object?> stroke)
            SnapshotStroke(
              points: <InkVector>[
                for (
                  int i = 0;
                  i + 1 < (stroke['points']! as List).length;
                  i += 2
                )
                  InkVector(
                    number((stroke['points']! as List)[i]),
                    number((stroke['points']! as List)[i + 1]),
                  ),
              ],
              width: number(stroke['width']),
              color: Color(stroke['color']! as int),
              isDot: stroke['dot'] == true,
              writing: WritingStyle.values.firstWhere(
                (WritingStyle style) => style.name == stroke['style'],
                orElse: () => WritingStyle.pen,
              ),
            ),
      ],
      sourceStrokes: sourceStrokes,
      sourceImages: sourceImages,
    );
    final Future<List<SnapshotBitmap>> Function()? loadBitmaps =
        loadBitmap == null || bitmapSources.isEmpty
        ? null
        : () async {
            final List<SnapshotBitmap> bitmaps = <SnapshotBitmap>[];
            for (int i = 0; i < bitmapSources.length; i++) {
              final Uint8List? bytes = await loadBitmap(bitmapSources[i]);
              if (bytes == null) {
                continue;
              }
              final List<Object?> bounds = bitmapJson[i]['bounds']! as List;
              bitmaps.add(
                SnapshotBitmap(
                  bytes: bytes,
                  bounds: Rect.fromLTRB(
                    number(bounds[0]),
                    number(bounds[1]),
                    number(bounds[2]),
                    number(bounds[3]),
                  ),
                  rotation: number(bitmapJson[i]['rotation'] ?? 0),
                  affectsCrop: bitmapJson[i]['affectsCrop'] != false,
                  source: bitmapSources[i],
                ),
              );
            }
            return bitmaps;
          };

    final _AiConversation conversation = _AiConversation(
      json['page'] == true
          ? AiSelectionContext._page(snapshot)
          : AiSelectionContext._(snapshot, loadBitmaps: loadBitmaps),
      (json['lastUsed'] as int?) ?? 0,
    )..notationStrokes.addAll(notationStrokes);
    final List<AiMessage> messages = <AiMessage>[];
    for (final Object? item in (json['messages'] as List?) ?? <Object?>[]) {
      final Map<String, Object?> message = item! as Map<String, Object?>;
      AiNotationStatus status = AiNotationStatus.values.firstWhere(
        (AiNotationStatus s) => s.name == message['status'],
        orElse: () => AiNotationStatus.none,
      );
      // Its drawing is on the note, and plays there again by itself.
      if (status == AiNotationStatus.animating) {
        status = AiNotationStatus.applied;
      }
      if (message['role'] == AiRole.model.name) {
        final AiAssistantResponse response = AiAssistantResponse.parse(
          message['wire']! as String,
        );
        messages.add(
          AiMessage.model(
            response.message,
            notation: response.notation,
            notationStatus: status,
          ),
        );
        final AiAnswerLinks links = _linksFromJson(message['links'], ink);
        if (!links.isEmpty) conversation.links[messages.length - 1] = links;
      } else {
        messages.add(
          AiMessage.user(
            message['text']! as String,
            label: message['label'] as String?,
          ),
        );
      }
    }
    if (messages.isEmpty) {
      return null;
    }
    conversation.messages = List<AiMessage>.unmodifiable(messages);
    // A question without its answer: asked again with Retry.
    if (messages.last.role == AiRole.user) {
      conversation.requestState = AiRequestState.failed;
      conversation.failure = AiFailure(
        AiFailureKind.values.firstWhere(
          (AiFailureKind kind) => kind.name == json['failure'],
          orElse: () => AiFailureKind.interrupted,
        ),
      );
    }
    return conversation;
  }

  /// The assets a saved session, [json] from [toJson], still reads, so they
  /// are kept while it does.
  static Set<String> referencedAssets(Map<String, Object?>? json) {
    final Set<String> assets = <String>{};
    final Object? conversations = json?['conversations'];
    if (conversations is! List) {
      return assets;
    }
    for (final Object? conversation in conversations) {
      if (conversation case {
        'snapshot': {'bitmaps': final List<Object?> bitmaps},
      }) {
        for (final Object? bitmap in bitmaps) {
          if (bitmap case {'asset': final String asset}) {
            assets.add(asset);
          }
        }
      }
    }
    return assets;
  }
}

/// The version of what [AiAssistantController.toJson] writes.
const int aiSessionVersion = 1;

/// Where a stroke or image is in the note: its page, and its place among
/// that page's strokes or images.
typedef AiInkRef = (int page, int index);

/// Finds the note's strokes and images by their place, and their places by
/// them, as the note stands now.
class AiInkIndex {
  AiInkIndex(List<(List<Stroke>, List<NoteImageElement>)> pages)
    : _pages = pages {
    for (int page = 0; page < pages.length; page++) {
      final (List<Stroke> strokes, List<NoteImageElement> images) = pages[page];
      for (int i = 0; i < strokes.length; i++) {
        _strokeRefs[strokes[i]] = (page, i);
      }
      for (int i = 0; i < images.length; i++) {
        _imageRefs[images[i]] = (page, i);
      }
    }
  }

  final List<(List<Stroke>, List<NoteImageElement>)> _pages;
  final Map<Stroke, AiInkRef> _strokeRefs = Map<Stroke, AiInkRef>.identity();
  final Map<NoteImageElement, AiInkRef> _imageRefs =
      Map<NoteImageElement, AiInkRef>.identity();

  AiInkRef? strokeRef(Stroke stroke) => _strokeRefs[stroke];

  AiInkRef? imageRef(NoteImageElement image) => _imageRefs[image];

  Stroke? stroke(AiInkRef ref) {
    final (int page, int index) = ref;
    if (page < 0 || page >= _pages.length) {
      return null;
    }
    final List<Stroke> strokes = _pages[page].$1;
    return index >= 0 && index < strokes.length ? strokes[index] : null;
  }

  NoteImageElement? image(AiInkRef ref) {
    final (int page, int index) = ref;
    if (page < 0 || page >= _pages.length) {
      return null;
    }
    final List<NoteImageElement> images = _pages[page].$2;
    return index >= 0 && index < images.length ? images[index] : null;
  }
}

class _SessionNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
