import 'dart:async';

import 'package:flutter/widgets.dart';

import '../editor/ink/ink_controller.dart';
import '../editor/page/note_document.dart';
import 'note_content.dart';

/// Saves a note's pages a short while after they change.
///
/// Changes are a page's ink ([InkController.documentRevisionListenable]),
/// and a page being added, removed, or set up ([NoteDocument]). Each change
/// restarts the wait. When it ends while a pointer is still writing,
/// erasing, or transforming, the save waits for the gesture to end. [flush]
/// saves at once; it is also called when the app is paused. A failed save
/// is reported to [onError] and tried again on the next change or flush;
/// the ink in memory is never touched.
class NoteAutosaver with WidgetsBindingObserver {
  NoteAutosaver({
    required this.document,
    required this.save,
    this.delay = const Duration(milliseconds: 800),
    this.onError,
  }) : _structure = document.structureRevision {
    document.addListener(_onStructureChanged);
    _listenToPages();
    WidgetsBinding.instance.addObserver(this);
  }

  final NoteDocument document;
  final Future<void> Function(NoteContent content) save;
  final Duration delay;
  final void Function(Object error)? onError;

  final Set<InkController> _listening = <InkController>{};
  int _structure;
  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  Future<void> _saving = Future<void>.value();

  /// Whether there are changes not yet handed to [save].
  bool get isDirty => _dirty;

  /// Turning pages is not a change; adding, removing, or setting one up is.
  void _onStructureChanged() {
    _listenToPages();
    if (document.structureRevision != _structure) {
      _structure = document.structureRevision;
      _changed();
    }
  }

  void _listenToPages() {
    final Set<InkController> present = <InkController>{
      for (final NotePage page in document.pages) page.ink,
    };
    for (final InkController gone in _listening.difference(present)) {
      gone.documentRevisionListenable.removeListener(_changed);
    }
    for (final InkController added in present.difference(_listening)) {
      added.documentRevisionListenable.addListener(_changed);
    }
    _listening
      ..clear()
      ..addAll(present);
  }

  void _changed() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(delay, _saveWhenIdle);
  }

  void _saveWhenIdle() {
    _timer = null;
    final bool busy = document.pages.any((NotePage page) => page.ink.isBusy);
    if (busy) {
      _timer = Timer(delay, _saveWhenIdle);
      return;
    }
    flush();
  }

  /// Saves now, if anything changed. The pages are read at once, so the
  /// document may be disposed as soon as this returns.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) {
      return _saving;
    }
    _dirty = false;
    final NoteContent content = NoteContent.fromDocument(document);
    return _saving = _saving.then((_) async {
      try {
        await save(content);
      } on Object catch (error) {
        _dirty = true;
        if (!_disposed) {
          onError?.call(error);
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      flush();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    document.removeListener(_onStructureChanged);
    for (final InkController ink in _listening) {
      ink.documentRevisionListenable.removeListener(_changed);
    }
    _listening.clear();
  }
}
