import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../handwriting/recognized_handwriting.dart';
import '../ink/ink_controller.dart';
import '../ink/stroke.dart';
import '../sticky/sticky_note.dart';
import '../document_io/document_models.dart';
import 'page_setup.dart';

/// One page of a note: its ink and its setup.
class NotePage {
  NotePage({
    required this.ink,
    this.setup = const PageSetup(),
    this.extent,
    this.lastFitSize,
    this.pdfSource,
    this.ownsInk = true,
    Iterable<RecognizedInkWord> recognizedWords = const <RecognizedInkWord>[],
  }) : recognizedWords = List<RecognizedInkWord>.of(recognizedWords);

  final InkController ink;

  PageSetup setup;

  /// How far an infinite page has grown, in page units. Null until it first
  /// grows; until then it is the size of the writing area.
  Size? extent;

  /// Legacy Fit-page size, retained when old notes are read and rewritten.
  Size? lastFitSize;

  /// Original PDF paper under this page's images and ink.
  final PdfPageSource? pdfSource;

  /// Whether the document disposes [ink] with itself.
  final bool ownsInk;

  /// Searchable handwriting and the high-confidence vector samples learned
  /// from it. Mutated only through [NoteDocument].
  final List<RecognizedInkWord> recognizedWords;
}

/// The pages of one note, and which one is shown.
///
/// Notifies when pages are added, removed, or switched, and when a page's
/// setup or extent changes. Ink changes are heard from each page's
/// [InkController]. [structureRevision] counts the changes this object
/// makes, which together with each page's
/// [InkController.documentRevision] tells a saver that something changed.
class NoteDocument extends ChangeNotifier {
  NoteDocument({
    List<NotePage>? pages,
    int currentIndex = 0,
    InkController Function()? createInk,
  }) : _createInk = createInk ?? InkController.new,
       _pages = pages == null || pages.isEmpty
           ? <NotePage>[NotePage(ink: (createInk ?? InkController.new)())]
           : List<NotePage>.of(pages),
       _current = 0 {
    _current = currentIndex.clamp(0, _pages.length - 1);
  }

  /// A one-page document around [ink], which the caller keeps owning.
  factory NoteDocument.single(
    InkController ink, {
    InkController Function()? createInk,
  }) {
    return NoteDocument(
      pages: <NotePage>[NotePage(ink: ink, ownsInk: false)],
      createInk: createInk,
    );
  }

  final InkController Function() _createInk;
  final List<NotePage> _pages;
  int _current;
  int _structureRevision = 0;
  bool _disposed = false;

  /// The AI assistant's remembered conversations, as stored with the note.
  /// Opaque here: written and read by the editor. Null when there are none.
  Map<String, Object?>? aiSession;

  /// While an editor is open on this note, writes [aiSession] as it is now,
  /// so that stroke references are taken at the moment of saving.
  Map<String, Object?>? Function()? aiSessionWriter;

  /// [aiSession], from the open editor when there is one.
  Map<String, Object?>? get currentAiSession {
    final Map<String, Object?>? Function()? writer = aiSessionWriter;
    return writer == null ? aiSession : writer();
  }

  /// The AI session changed, so the note needs saving.
  void aiSessionChanged() => _changed();

  /// Adds one on-device handwriting reading. This is document metadata, so
  /// it is autosaved without creating an ink undo step.
  void addRecognizedWord(NotePage page, RecognizedInkWord word) {
    if (!_pages.contains(page) || word.text.isEmpty) return;
    page.recognizedWords.add(word);
    _changed();
  }

  /// Keeps recognition links aligned with transformed strokes and removes
  /// readings whose source ink was erased or moved to another page.
  void reconcileRecognizedWords(
    NotePage page, {
    Map<Stroke, Stroke> replacements = const <Stroke, Stroke>{},
  }) {
    if (!_pages.contains(page) || page.recognizedWords.isEmpty) return;
    final List<RecognizedInkWord> next = <RecognizedInkWord>[];
    for (final RecognizedInkWord word in page.recognizedWords) {
      final RecognizedInkWord followed = replacements.isEmpty
          ? word
          : word.follow(replacements);
      final StickyNoteElement? sticky = followed.stickyId == null
          ? null
          : page.ink.stickyNotes
                .where((StickyNoteElement note) => note.id == followed.stickyId)
                .firstOrNull;
      final Set<Stroke> present = Set<Stroke>.identity()
        ..addAll(
          followed.stickyId == null
              ? page.ink.strokes
              : sticky?.strokes ?? const <Stroke>[],
        );
      if (followed.sourceStrokes.every(present.contains)) next.add(followed);
    }
    if (listEquals(next, page.recognizedWords)) return;
    page.recognizedWords
      ..clear()
      ..addAll(next);
    _changed();
  }

  Iterable<RecognizedInkWord> get recognizedWords sync* {
    for (final NotePage page in _pages) {
      yield* page.recognizedWords;
    }
  }

  List<NotePage> get pages => UnmodifiableListView<NotePage>(_pages);

  int get pageCount => _pages.length;

  int get currentIndex => _current;

  NotePage get current => _pages[_current];

  int get structureRevision => _structureRevision;

  bool get canGoBack => _current > 0;

  bool get canGoForward => _current < _pages.length - 1;

  void goTo(int index) {
    if (index < 0 || index >= _pages.length || index == _current) {
      return;
    }
    _current = index;
    notifyListeners();
  }

  void previousPage() => goTo(_current - 1);

  void nextPage() => goTo(_current + 1);

  /// Inserts an empty page after the current one, with the current page's
  /// setup, and shows it.
  NotePage addPage() {
    final NotePage page = _pageLike(current);
    _pages.insert(_current + 1, page);
    _current++;
    _changed();
    return page;
  }

  /// Adds an empty page after the last one, with its setup, and stays on
  /// the page shown: the new one waits below to be scrolled to.
  NotePage appendPage() {
    final NotePage page = _pageLike(_pages.last);
    _pages.add(page);
    _changed();
    return page;
  }

  /// An empty page the size of [model]; after an imported PDF page, a
  /// blank page as big as its paper.
  NotePage _pageLike(NotePage model) {
    final PageSetup setup = model.pdfSource == null
        ? model.setup
        : PageSetup(
            size: PageSize.custom,
            customSize: model.pdfSource!.pageSize,
          );
    return NotePage(ink: _createInk(), setup: setup);
  }

  /// Inserts already validated pages after the current page as one document
  /// mutation and shows the first inserted page.
  void insertPagesAfterCurrent(List<NotePage> pages) {
    if (pages.isEmpty) {
      return;
    }
    _pages.insertAll(_current + 1, pages);
    _current++;
    _changed();
  }

  /// Removes the page at [index] and its ink. The only page cannot be
  /// removed.
  bool deletePage(int index) {
    if (_pages.length <= 1 || index < 0 || index >= _pages.length) {
      return false;
    }
    final NotePage removed = _pages.removeAt(index);
    if (index < _current || _current >= _pages.length) {
      _current--;
    }
    _changed();
    if (removed.ownsInk) {
      removed.ink.dispose();
    }
    return true;
  }

  /// Gives the current page [setup]. Its ink keeps its page coordinates.
  void setSetup(PageSetup setup) {
    final NotePage page = current;
    if (page.setup == setup) {
      return;
    }
    page.setup = setup;
    _changed();
  }

  /// Records how far [page] has grown.
  void setExtent(NotePage page, Size extent) {
    if (page.extent == extent || !_pages.contains(page)) {
      return;
    }
    page.extent = extent;
    _changed();
  }

  void _changed() {
    _structureRevision++;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final NotePage page in _pages) {
      if (page.ownsInk) {
        page.ink.dispose();
      }
    }
    super.dispose();
  }
}
