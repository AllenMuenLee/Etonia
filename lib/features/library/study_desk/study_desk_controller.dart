import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../editor/ai/ai_citation.dart';
import '../../editor/ai/ai_client.dart';
import '../../editor/ai/ai_config.dart';
import '../../editor/ai/ai_usage_gate.dart';
import '../../editor/document_io/document_platform.dart';
import '../library_models.dart';
import '../note_content.dart';
import '../note_repository.dart';
import 'study_desk_models.dart';
import 'study_desk_store.dart';
import 'study_rag_index.dart';

/// How far a question has come.
enum StudyRequestState {
  idle,

  /// Looking through the notes: nothing has been sent yet.
  searching,

  /// Sent, and waiting for the answer.
  answering,
}

/// One of the questions offered as a conversation starts.
@immutable
class StudyStarter {
  const StudyStarter(this.label, this.prompt, this.mode);

  final String label;
  final String prompt;
  final StudyQueryMode mode;

  static const List<StudyStarter> all = <StudyStarter>[
    StudyStarter(
      'Summarize key concepts',
      'Summarize the key concepts in these notes, grouped by topic.',
      StudyQueryMode.overview,
    ),
    StudyStarter(
      'Quiz me on these notes',
      'Quiz me on these notes: ask five questions of rising difficulty, then '
          'give the answers at the end.',
      StudyQueryMode.overview,
    ),
    StudyStarter(
      'Explain the diagrams',
      'Explain the diagrams and drawings in these notes: what each one shows, '
          'and how its parts relate.',
      StudyQueryMode.diagrams,
    ),
    StudyStarter(
      'Find connections & gaps',
      'Find connections between these notes, and gaps in what they cover.',
      StudyQueryMode.overview,
    ),
  ];
}

/// Which citation is shown, and the paragraph it came from.
@immutable
class StudyCitationFocus {
  const StudyCitationFocus({
    required this.citation,
    required this.message,
    required this.paragraph,
  });

  final StudyCitation citation;

  /// The answer's index among the conversation's messages.
  final int message;

  /// From one.
  final int paragraph;

  bool isOf(int message, int paragraph) =>
      this.message == message && this.paragraph == paragraph;
}

/// A cited page, as it stands now.
@immutable
class StudyPageView {
  const StudyPageView({
    required this.note,
    required this.pageIndex,
    required this.pageCount,
    required this.page,
  });

  final NoteEntry note;
  final int pageIndex;
  final int pageCount;
  final StoredPage page;
}

/// The Study Desk: the notes on it, its chats, and what each question sends.
///
/// Lives as long as the library, so a chat outlives the screen showing it, and
/// nothing about it depends on a note being open.
class StudyDeskController extends ChangeNotifier implements AiModelChooser {
  StudyDeskController({
    required this.repository,
    required this.client,
    this._usageGate,
    StudyDeskStore? store,
    StudyChunkDiskCache? diskCache,
    StudyChunkRenderer? renderer,
    PdfRasterizer? pdfRasterizer,
    this.assembler = const StudyContextAssembler(),
    this.clock = DateTime.now,
  }) : store = store ?? studyDeskStoreFor(repository) {
    index = StudyRagIndex(
      repository: repository,
      diskCache: diskCache ?? studyChunkCacheFor(repository),
      pdfText: pdfRasterizer is PdfTextExtractor
          ? pdfRasterizer as PdfTextExtractor
          : null,
    );
    this.renderer =
        renderer ??
        PageStudyChunkRenderer(
          repository: repository,
          pdfRasterizer: pdfRasterizer,
          loadPage: _loadPageOf,
        );
    repository.addListener(_onLibraryChanged);
    _usageGate?.addListener(_notify);
  }

  final NoteRepository repository;
  final AiClient client;
  final StudyDeskStore store;
  final StudyContextAssembler assembler;
  final DateTime Function() clock;
  late final StudyRagIndex index;
  late final StudyChunkRenderer renderer;

  AiUsageGate? _usageGate;
  bool _disposed = false;

  /// The most chats kept, the oldest going first.
  static const int maxSessions = 20;

  /// Whole notes kept in memory, for the pages being read and cited.
  static const int _maxLoadedNotes = 3;

  Map<String, NoteEntry> _notes = const <String, NoteEntry>{};
  Map<String, Folder> _folders = const <String, Folder>{};
  List<StudySourceItem> _sources = const <StudySourceItem>[];
  List<StudySession> _sessions = const <StudySession>[];
  late StudySession _session = _newSession();
  bool _loaded = false;
  Future<void>? _loading;

  StudyRequestState _requestState = StudyRequestState.idle;
  String? _partial;
  AiFailure? _failure;
  ({String prompt, String? label, StudyQueryMode mode})? _lastQuestion;
  int _token = 0;
  int _sessionCounter = 0;

  StudyCitationFocus? _focus;
  bool _paneOpen = false;
  int _pagesEpoch = 0;
  bool _sourcesChanged = true;

  /// What the composer holds, which outlives the screen.
  String draft = '';

  /// Each loaded note, the most recently used last.
  final Map<String, (int, Future<NoteContent>)> _content =
      <String, (int, Future<NoteContent>)>{};

  /// The notes loaded and read so far, for reading citations at once.
  final Map<String, NoteContent> _readContent = <String, NoteContent>{};

  /// Notes saved from their editors, not yet read again.
  final Set<String> _savedNotes = <String>{};

  // --- What the screen shows -------------------------------------------------

  /// The notes on the desk that are in the library now.
  List<StudySourceItem> get sources => List<StudySourceItem>.unmodifiable(
    _sources.where((StudySourceItem item) => _notes.containsKey(item.noteId)),
  );

  /// How many notes questions are about now.
  int get activeCount => sources.where((StudySourceItem s) => s.enabled).length;

  NoteEntry? noteOf(String id) => _notes[id];
  Folder? folderOf(String? id) => id == null ? null : _folders[id];
  List<NoteEntry> get allNotes => _notes.values.toList(growable: false);
  List<Folder> get allFolders => _folders.values.toList(growable: false);

  /// How far the conversation goes, oldest first.
  List<StudyMessage> get messages => _session.messages;
  String get sessionId => _session.id;

  /// Earlier chats with anything in them, most recent first.
  List<StudySession> get history => <StudySession>[
    for (final StudySession session in _sessions.reversed)
      if (session.messages.isNotEmpty && session.id != _session.id) session,
  ];

  StudyRequestState get requestState => _requestState;
  bool get isBusy => _requestState != StudyRequestState.idle;

  /// The answer as far as it has been written, no citation showing.
  String? get partialAnswer => _partial;
  AiFailure? get failure => _failure;
  bool get canSend => !isBusy && activeCount > 0;

  /// Whether to offer the starter questions: at the start of a chat, and after
  /// the notes it is about have changed.
  bool get showStarters =>
      !isBusy && activeCount > 0 && (messages.isEmpty || _sourcesChanged);

  StudyCitationFocus? get focus => _focus;

  /// Whether the citation in [focus] is being looked at.
  bool get paneOpen => _paneOpen && _focus != null;

  /// Moves on when a page may read differently now.
  int get pagesEpoch => _pagesEpoch;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // --- Models ----------------------------------------------------------------

  AiModelId? _selectedModel;

  AiModelRouter? get _router {
    final AiClient client = this.client;
    return client is AiModelRouter ? client : null;
  }

  @override
  List<AiModelId> get models => _router?.models ?? const <AiModelId>[];

  @override
  AiModelId? get selectedModel {
    final AiModelRouter? router = _router;
    if (router == null) return null;
    return _selectedModel ?? _usageGate?.preferredModel ?? router.defaultModel;
  }

  @override
  void selectModel(AiModelId model) {
    if (_disposed || !models.contains(model) || model == selectedModel) return;
    _selectedModel = model;
    _usageGate?.setPreferredModel(model);
    _notify();
  }

  @override
  AiModelAccess? accessFor(AiModelId model) => _usageGate?.accessFor(model);

  @override
  bool isModelConfigured(AiModelId model) =>
      _router?.isModelConfigured(model) ?? client.isConfigured;

  @override
  String get modelLabel => selectedModel?.label ?? client.modelLabel;

  // --- Loading and keeping ---------------------------------------------------

  /// Reads what was kept. Safe to call more than once.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final StudyDeskState? kept = await store.read();
    if (_disposed) return;
    if (kept != null) {
      _sources = kept.sources;
      _sessions = kept.sessions;
      _session =
          _sessions
              .where((StudySession s) => s.id == kept.currentSessionId)
              .firstOrNull ??
          _session;
    }
    _sourcesChanged = _session.messages.isEmpty;
    await _readLibrary();
    if (_disposed) return;
    final List<NoteEntry> trash = await repository.trash();
    if (_disposed) return;
    // Notes gone for good leave the desk; those in Recently Deleted may be back.
    final Set<String> known = <String>{
      ..._notes.keys,
      for (final NoteEntry note in trash) note.id,
    };
    _sources = _sources
        .where((StudySourceItem item) => known.contains(item.noteId))
        .toList();
    unawaited(index.retain(known));
    _loaded = true;
    _notify();
    unawaited(_prepareIndex());
  }

  void _save() {
    unawaited(
      store.write(
        StudyDeskState(
          sources: _sources,
          sessions: <StudySession>[
            ..._sessions.where((StudySession s) => s.id != _session.id),
            if (_session.messages.isNotEmpty) _session,
          ],
          currentSessionId: _session.id,
        ),
      ),
    );
  }

  StudySession _newSession() => StudySession(
    id: '${clock().microsecondsSinceEpoch}-${_sessionCounter++}',
    created: clock(),
  );

  Future<void> _readLibrary() async {
    final List<NoteEntry> notes = await repository.allNotes();
    final List<Folder> folders = await repository.allFolders();
    if (_disposed) return;
    _notes = <String, NoteEntry>{for (final NoteEntry n in notes) n.id: n};
    _folders = <String, Folder>{for (final Folder f in folders) f.id: f};
  }

  void _onLibraryChanged() {
    unawaited(
      _readLibrary().then((void _) {
        if (_loaded) _notify();
      }),
    );
  }

  /// Works out the chunks of what is on the desk ahead of the first question.
  Future<void> _prepareIndex() async {
    for (final StudySourceItem source in sources) {
      final NoteEntry? note = _notes[source.noteId];
      if (_disposed || note == null) return;
      try {
        await index.chunksFor(note);
      } on Object {
        // Tried again when a question needs it.
      }
    }
  }

  // --- Sources ---------------------------------------------------------------

  /// Adds [noteIds], those in the library and not already here. How many were
  /// added.
  int addNotes(Iterable<String> noteIds) {
    final Set<String> have = <String>{
      for (final StudySourceItem item in _sources) item.noteId,
    };
    final List<StudySourceItem> added = <StudySourceItem>[
      for (final String id in noteIds.toSet())
        if (_notes.containsKey(id) && !have.contains(id))
          StudySourceItem(noteId: id),
    ];
    // Already here, a note asked for again is put back in context.
    final Set<String> asked = noteIds.toSet();
    bool enabled = false;
    _sources = <StudySourceItem>[
      for (final StudySourceItem item in _sources)
        if (asked.contains(item.noteId) && !item.enabled)
          () {
            enabled = true;
            return item.copyWith(enabled: true);
          }()
        else
          item,
      ...added,
    ];
    if (added.isEmpty && !enabled) return 0;
    _sourcesChanged = true;
    _save();
    _notify();
    unawaited(_prepareIndex());
    return added.length;
  }

  /// The notes in [folderId] and every folder below it.
  List<String> notesInSubtree(String folderId) {
    final Set<String> below = <String>{folderId};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final Folder folder in _folders.values) {
        if (below.contains(folder.parentId) && below.add(folder.id)) {
          grew = true;
        }
      }
    }
    return <String>[
      for (final NoteEntry note in _notes.values)
        if (below.contains(note.folderId)) note.id,
    ];
  }

  /// Adds every note below [folderId]; how many were new.
  int addFolder(String folderId) => addNotes(notesInSubtree(folderId));

  void setSourceEnabled(String noteId, bool enabled) {
    _sources = <StudySourceItem>[
      for (final StudySourceItem item in _sources)
        item.noteId == noteId ? item.copyWith(enabled: enabled) : item,
    ];
    _sourcesChanged = true;
    _save();
    _notify();
  }

  void removeSource(String noteId) {
    _sources = _sources
        .where((StudySourceItem s) => s.noteId != noteId)
        .toList();
    _sourcesChanged = true;
    _save();
    _notify();
  }

  // --- Chats -----------------------------------------------------------------

  /// Keeps this chat in the history and starts another.
  void newChat() {
    if (_session.messages.isEmpty && !isBusy) return;
    _cancelRequest();
    _keepSession();
    _session = _newSession();
    _focus = null;
    _paneOpen = false;
    _sourcesChanged = true;
    _save();
    _notify();
  }

  void openSession(String id) {
    final StudySession? found = _sessions
        .where((StudySession s) => s.id == id)
        .firstOrNull;
    if (found == null) return;
    _cancelRequest();
    _keepSession();
    _session = found;
    _focus = null;
    _paneOpen = false;
    _sourcesChanged = false;
    _save();
    _notify();
  }

  void _keepSession() {
    final List<StudySession> others = _sessions
        .where((StudySession s) => s.id != _session.id)
        .toList();
    _sessions = <StudySession>[
      ...others,
      if (_session.messages.isNotEmpty) _session,
    ];
    if (_sessions.length > maxSessions) {
      _sessions = _sessions.sublist(_sessions.length - maxSessions);
    }
  }

  void _cancelRequest() {
    _token++;
    _requestState = StudyRequestState.idle;
    _partial = null;
    _failure = null;
  }

  // --- Asking ----------------------------------------------------------------

  /// Asks [prompt] about the enabled notes. [label] is what the chat shows in
  /// its place, for a starter question.
  Future<void> send(
    String prompt, {
    String? label,
    StudyQueryMode mode = StudyQueryMode.search,
  }) async {
    final String text = prompt.trim();
    if (text.isEmpty || !canSend) return;
    _lastQuestion = (prompt: text, label: label, mode: mode);
    await _ask(text, label, mode, addQuestion: true);
  }

  /// Asks the last question again, after it failed.
  Future<void> retry() async {
    final question = _lastQuestion;
    if (question == null || isBusy) return;
    await _ask(
      question.prompt,
      question.label,
      question.mode,
      addQuestion: false,
    );
  }

  void dismissFailure() {
    if (_failure == null) return;
    _failure = null;
    _notify();
  }

  Future<void> _ask(
    String prompt,
    String? label,
    StudyQueryMode mode, {
    required bool addQuestion,
  }) async {
    final int token = ++_token;
    final String sessionId = _session.id;
    final String shown = label ?? prompt;
    final List<StudyMessage> before = _session.messages;
    if (addQuestion) {
      _session = _session.copyWith(
        messages: <StudyMessage>[...before, StudyMessage.user(shown)],
      );
      _save();
    }
    _requestState = StudyRequestState.searching;
    _partial = null;
    _failure = null;
    _sourcesChanged = false;
    _notify();

    bool current() => !_disposed && token == _token;
    void fail(AiFailure failure) {
      _requestState = StudyRequestState.idle;
      _partial = null;
      _failure = failure;
      _notify();
    }

    final AiModelId? model = selectedModel;
    if (model != null) {
      final AiFailure? refused = _usageGate?.checkAccess(model);
      if (refused != null) {
        await Future<void>.value();
        if (current()) fail(refused);
        return;
      }
    }
    if (!(model == null ? client.isConfigured : isModelConfigured(model))) {
      await Future<void>.value();
      if (current()) fail(const AiFailure(AiFailureKind.notConfigured));
      return;
    }

    final StudyPayload payload;
    try {
      final List<StudyHit> hits = StudyRetriever.retrieve(
        await _documents(),
        _queryFor(prompt, before),
        mode: mode,
      );
      payload = await assembler.assemble(hits, renderer: renderer);
    } on Object {
      if (current()) fail(const AiFailure(AiFailureKind.noteUnavailable));
      return;
    }
    if (!current()) return;
    _requestState = StudyRequestState.answering;
    _notify();

    final AiRequest request = AiRequest(
      systemInstruction: AiPrompts.studySystem,
      imagePng: payload.imagePng,
      model: model,
      messages: <AiMessage>[
        ..._historyOf(before),
        AiMessage.user(_withContext(payload, prompt), label: shown),
      ],
    );
    final AiResult result;
    try {
      result = await client.send(
        request,
        onPartial: (String message, bool isComplete) {
          if (!current()) return;
          _partial = stripPartialAiCitations(message);
          _notify();
        },
      );
    } on Object {
      if (current()) fail(const AiFailure(AiFailureKind.network));
      return;
    }
    // The provider charged for the answer whatever becomes of it here.
    if (result case AiSuccess(
      :final String text,
      :final AiTokenUsage? usage,
    ) when model != null && !_disposed) {
      _usageGate?.recordUsage(
        model,
        usage ?? AiTokenUsage.estimate(request, text),
      );
    }
    if (!current() || _session.id != sessionId) return;
    switch (result) {
      case AiError(:final AiFailure failure):
        fail(failure);
      case AiSuccess(:final String text):
        final List<StudyParagraphLinks> links = await _readCitations(
          text,
          payload.map,
        );
        if (!current()) return;
        _session = _session.copyWith(
          messages: <StudyMessage>[
            ..._session.messages,
            StudyMessage.answer(stripAiCitations(text).trim(), links: links),
          ],
        );
        _requestState = StudyRequestState.idle;
        _partial = null;
        _keepSession();
        _save();
        _notify();
    }
  }

  /// A short follow-up is about what was just asked: its words are looked for
  /// together with those of the question before it.
  String _queryFor(String prompt, List<StudyMessage> before) {
    if (studyTokens(prompt).length >= 4) return prompt;
    final StudyMessage? last = before
        .where((StudyMessage message) => message.fromUser)
        .lastOrNull;
    return last == null ? prompt : '$prompt ${last.text}';
  }

  /// The turns a provider is sent. Only whole turns, as a failed question has
  /// no answer, and only their words: what was retrieved for them is not sent
  /// again, nor is anything they cited.
  List<AiMessage> _historyOf(List<StudyMessage> before) {
    final List<AiMessage> history = <AiMessage>[];
    for (int i = 0; i + 1 < before.length; i++) {
      if (before[i].fromUser && !before[i + 1].fromUser) {
        history
          ..add(AiMessage.user(before[i].text))
          ..add(AiMessage.model(before[i + 1].text));
      }
    }
    return history;
  }

  static String _withContext(StudyPayload payload, String prompt) {
    // With nothing found, nothing is said of the notes: a model told they hold
    // nothing tends to tell the user so, in place of answering.
    if (payload.contextText.isEmpty) return prompt;
    return 'Excerpts from my notes that a search found, which may or may not '
        'help:\n\n${payload.contextText}\n\nQuestion: $prompt';
  }

  Future<List<StudySearchDocument>> _documents() async {
    final List<StudySearchDocument> documents = <StudySearchDocument>[];
    Object? failed;
    bool any = false;
    for (final StudySourceItem source in sources) {
      if (!source.enabled) continue;
      final NoteEntry? note = _notes[source.noteId];
      if (note == null) continue;
      try {
        final List<StudyChunk> chunks = await index.chunksFor(note);
        any = true;
        final String folder = folderOf(note.folderId)?.name ?? '';
        for (final StudyChunk chunk in chunks) {
          documents.add(
            StudySearchDocument(
              chunk: chunk,
              noteTitle: note.title,
              folderName: folder,
            ),
          );
        }
      } on Object catch (error) {
        // One unreadable note does not stop the others being asked about.
        failed = error;
      }
    }
    if (!any && failed != null) throw failed;
    return documents;
  }

  Future<List<StudyParagraphLinks>> _readCitations(
    String answer,
    StudySourceMap map,
  ) async {
    final Set<String> cited = <String>{
      for (final AiNoteCitation citation in parseAiNoteCitations(answer))
        ?map.noteIds[citation.note],
    };
    for (final String id in cited) {
      await _contentOf(id);
    }
    return StudyCitationResolver(
      map: map,
      pageOf: (String noteId, int pageIndex) {
        final List<StoredPage>? pages = _readContent[noteId]?.pages;
        return pages == null || pageIndex >= pages.length
            ? null
            : pages[pageIndex];
      },
      revisionOf: (String noteId) => _notes[noteId]?.revision ?? 0,
    ).resolve(answer);
  }

  // --- Pages -----------------------------------------------------------------

  /// [noteId]'s content; null when it cannot be read.
  Future<NoteContent?> _contentOf(String noteId) async {
    final NoteEntry? note = _notes[noteId];
    if (note == null) return null;
    (int, Future<NoteContent>)? kept = _content.remove(noteId);
    if (kept == null || kept.$1 != note.revision) {
      kept = (note.revision, repository.loadNote(noteId));
      _readContent.remove(noteId);
    }
    _content[noteId] = kept;
    while (_content.length > _maxLoadedNotes) {
      final String oldest = _content.keys.first;
      _content.remove(oldest);
      _readContent.remove(oldest);
    }
    try {
      final NoteContent content = await kept.$2;
      if (_content[noteId]?.$2 == kept.$2) _readContent[noteId] = content;
      return content;
    } on Object {
      if (_content[noteId]?.$2 == kept.$2) _content.remove(noteId);
      return null;
    }
  }

  Future<StoredPage?> _loadPageOf(String noteId, int pageIndex) async {
    final NoteContent? content = await _contentOf(noteId);
    if (content == null || pageIndex >= content.pages.length) return null;
    return content.pages[pageIndex];
  }

  /// The page [citation] is on as it stands now, or null when the note or the
  /// page is gone.
  Future<StudyPageView?> pageFor(StudyCitation citation) async {
    final NoteEntry? note = _notes[citation.noteId];
    if (note == null) return null;
    final NoteContent? content = await _contentOf(citation.noteId);
    if (content == null || citation.pageIndex >= content.pages.length) {
      return null;
    }
    return StudyPageView(
      note: note,
      pageIndex: citation.pageIndex,
      pageCount: content.pages.length,
      page: content.pages[citation.pageIndex],
    );
  }

  /// [noteId]'s revision now, which says whether a citation's stroke numbers
  /// still hold.
  int revisionOf(String noteId) => _notes[noteId]?.revision ?? 0;

  /// What a citation's chip says.
  String labelOf(StudyCitation citation) {
    final String title = _notes[citation.noteId]?.title ?? 'Deleted note';
    return '$title · p.${citation.pageIndex + 1}';
  }

  /// Shows [citation]. With [open], the page opens if it was closed, as when a
  /// chip is pressed. Otherwise it only follows what is being read.
  void focusCitation(
    StudyCitation citation, {
    required int message,
    required int paragraph,
    bool open = true,
  }) {
    final StudyCitationFocus? current = _focus;
    if (identical(current?.citation, citation) && (_paneOpen || !open)) return;
    _focus = StudyCitationFocus(
      citation: citation,
      message: message,
      paragraph: paragraph,
    );
    if (open) _paneOpen = true;
    _notify();
  }

  void closePane() {
    if (!_paneOpen) return;
    _paneOpen = false;
    _notify();
  }

  // --- Coming back from the editor -------------------------------------------

  /// [noteId] was saved from its editor. Read again when asked to be.
  void noteSaved(String noteId) => _savedNotes.add(noteId);

  /// Reads the notes saved since this was last asked, and only those, in the
  /// background, and has what cites them read them again as they now are.
  Future<void> refreshSavedNotes() async {
    if (_savedNotes.isEmpty) return;
    final List<String> saved = _savedNotes.toList();
    _savedNotes.clear();
    await _readLibrary();
    if (_disposed) return;
    for (final String id in saved) {
      _content.remove(id);
      _readContent.remove(id);
    }
    _pagesEpoch++;
    _notify();
    for (final String id in saved) {
      final NoteEntry? note = _notes[id];
      if (note == null || !_isSource(id)) continue;
      try {
        await index.chunksFor(note);
      } on Object {
        // Tried again when a question needs it.
      }
      if (_disposed) return;
    }
  }

  bool _isSource(String noteId) =>
      _sources.any((StudySourceItem item) => item.noteId == noteId);

  /// The system is low on memory: what can be read again goes.
  void releaseMemory() {
    index.releaseMemory();
    _content.clear();
    _readContent.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _token++;
    repository.removeListener(_onLibraryChanged);
    _usageGate?.removeListener(_notify);
    _usageGate = null;
    super.dispose();
  }
}
