import 'dart:collection';

import 'package:flutter/foundation.dart';

/// How much memory the app's caches may hold, and how it is shared out: a
/// tenth for the library's folder pages, the rest for open notes.
@immutable
class CacheBudget {
  const CacheBudget({this.totalBytes = 128 * 1024 * 1024})
    : assert(totalBytes > 0);

  final int totalBytes;

  /// For the folder pages: their listings and the notes' pictures.
  int get homeBytes => totalBytes ~/ 10;

  /// For every open note, in one [NoteCachePool].
  int get notesBytes => totalBytes - homeBytes;
}

/// What all open notes keep in memory, in one pool of [maxBytes].
///
/// Over the limit, what goes first is a page of the note used longest ago,
/// and of its pages the one used longest ago: it is the note's last use that
/// counts. After note 1's page 4, note 2's page 5 and note 1's page 5, it is
/// note 2's page that goes, and note 1's page 4 only once note 2 has nothing
/// left. A page goes with everything kept for it.
///
/// Nothing of a page on screen goes, so the pool may run over while what is
/// on screen alone is more than [maxBytes].
class NoteCachePool {
  NoteCachePool({required this.maxBytes}) : assert(maxBytes >= 0);

  final int maxBytes;

  int _usedBytes = 0;
  int get usedBytes => _usedBytes;

  /// The open notes, used longest ago first.
  final LinkedHashSet<NoteCacheScope> _scopes = LinkedHashSet<NoteCacheScope>();
  bool _trimming = false;

  /// A share of the pool for one open note, until [NoteCacheScope.close].
  NoteCacheScope scope() {
    final NoteCacheScope scope = NoteCacheScope._(this);
    _scopes.add(scope);
    return scope;
  }

  /// The system is low on memory: every page not on screen goes, and what
  /// their notes share. An open note's document stays; its tab decides.
  void releaseIdle() {
    for (final NoteCacheScope scope in _scopes.toList()) {
      while (scope._popPage()) {}
      scope._popShared();
    }
  }

  void _trim() {
    if (_trimming) return;
    _trimming = true;
    try {
      while (_usedBytes > maxBytes && _popNext()) {}
    } finally {
      _trimming = false;
    }
  }

  bool _popNext() {
    for (final NoteCacheScope scope in _scopes) {
      // The note's pages, then what they share, then its document.
      if (scope._popPage() || scope._popShared() || scope._putAway()) {
        return true;
      }
    }
    return false;
  }
}

/// One open note's share of a [NoteCachePool].
class NoteCacheScope {
  NoteCacheScope._(this.pool);

  final NoteCachePool pool;

  /// The note's pages, used longest ago first.
  final LinkedHashMap<Object, _CachedPage> _pages =
      LinkedHashMap<Object, _CachedPage>();

  /// What all the note's pages use, such as the bytes of its PDF.
  final Set<NoteCacheItem> _shared = <NoteCacheItem>{};

  int _documentBytes = 0;
  bool Function()? _canPutAway;
  VoidCallback? _putAwayDocument;
  bool _closed = false;

  int get maxBytes => pool.maxBytes;

  bool get _anyPageShown =>
      _pages.values.any((_CachedPage page) => page.isShown);

  /// The user has come to [page] of this note.
  void touch(Object page) {
    if (_closed) return;
    pool._scopes
      ..remove(this)
      ..add(this);
    touchPage(page);
  }

  /// Makes [page] the note's last used without counting as a use of the
  /// note, as for pages made ready around the one in view, or for a note
  /// working out of sight.
  void touchPage(Object page) {
    if (_closed) return;
    _pages[page] = _pages.remove(page) ?? _CachedPage();
  }

  /// Keeps [bytes] for [page], or for all of the note's pages without one.
  /// [onPop] lets go of them. [inUse] keeps them for as long as it says.
  NoteCacheItem add({
    Object? page,
    required int bytes,
    required VoidCallback onPop,
    bool Function()? inUse,
  }) {
    final NoteCacheItem item = NoteCacheItem._(this, bytes, onPop, inUse);
    if (_closed) {
      item._gone = true;
      return item;
    }
    item._attach(page);
    pool._usedBytes += bytes;
    pool._trim();
    return item;
  }

  /// A page is being shown, or at least built, for as long as this is held;
  /// [onPopped] is told when what it was built from has gone.
  NoteCachePageHold hold(Object page, VoidCallback onPopped) {
    final NoteCachePageHold hold = NoteCachePageHold._(this, page, onPopped);
    if (!_closed) {
      _pages.putIfAbsent(page, _CachedPage.new).holds.add(hold);
    }
    return hold;
  }

  /// The note's document costs [bytes], and is the last of the note to go:
  /// [putAway] once [canPutAway] says that is safe.
  void setDocument({
    required int bytes,
    required bool Function() canPutAway,
    required VoidCallback putAway,
  }) {
    if (_closed) return;
    pool._usedBytes += bytes - _documentBytes;
    _documentBytes = bytes;
    _canPutAway = canPutAway;
    _putAwayDocument = putAway;
    pool._trim();
  }

  /// Lets go of what is kept for one page, oldest first; false if there is
  /// nothing that can go.
  bool _popPage() {
    for (final MapEntry<Object, _CachedPage> entry in _pages.entries) {
      final _CachedPage page = entry.value;
      if (page.isShown) continue;
      final List<NoteCacheItem> idle = page.items
          .where((NoteCacheItem item) => !item._isInUse)
          .toList();
      if (idle.isEmpty) continue;
      for (final NoteCacheItem item in idle) {
        item._pop();
      }
      for (final NoteCachePageHold hold in page.holds.toList()) {
        hold._onPopped();
      }
      return true;
    }
    return false;
  }

  bool _popShared() {
    if (_anyPageShown) return false;
    final List<NoteCacheItem> idle = _shared
        .where((NoteCacheItem item) => !item._isInUse)
        .toList();
    for (final NoteCacheItem item in idle) {
      item._pop();
    }
    return idle.isNotEmpty;
  }

  bool _putAway() {
    if (_documentBytes == 0 || _anyPageShown) return false;
    if (!(_canPutAway?.call() ?? false)) return false;
    pool._usedBytes -= _documentBytes;
    _documentBytes = 0;
    _putAwayDocument?.call();
    return true;
  }

  /// The note has closed: nothing is kept for it any more, and whoever kept
  /// it has let go already.
  void close() {
    if (_closed) return;
    _closed = true;
    pool._scopes.remove(this);
    pool._usedBytes -= _documentBytes;
    _documentBytes = 0;
    for (final _CachedPage page in _pages.values) {
      for (final NoteCacheItem item in page.items.toList()) {
        item.remove();
      }
    }
    for (final NoteCacheItem item in _shared.toList()) {
      item.remove();
    }
    _pages.clear();
  }
}

/// Something kept in a [NoteCachePool].
class NoteCacheItem {
  NoteCacheItem._(this._scope, this._bytes, this._onPop, this._inUse);

  final NoteCacheScope _scope;
  int _bytes;
  final VoidCallback _onPop;
  final bool Function()? _inUse;
  _CachedPage? _page;
  bool _gone = false;

  bool get _isInUse => _inUse?.call() ?? false;

  void _attach(Object? page) {
    if (page == null) {
      _scope._shared.add(this);
      return;
    }
    _page = _scope._pages.putIfAbsent(page, _CachedPage.new)..items.add(this);
  }

  void _detach() {
    _page?.items.remove(this);
    _page = null;
    _scope._shared.remove(this);
  }

  /// Turned out to cost [bytes].
  void resize(int bytes) {
    if (_gone) return;
    _scope.pool._usedBytes += bytes - _bytes;
    _bytes = bytes;
    _scope.pool._trim();
  }

  /// Now kept for [page], as a picture used on one page and then another.
  void moveTo(Object page) {
    if (_gone) return;
    _detach();
    _attach(page);
  }

  /// Its owner let go of it.
  void remove() {
    if (_gone) return;
    _gone = true;
    _detach();
    _scope.pool._usedBytes -= _bytes;
  }

  void _pop() {
    remove();
    _onPop();
  }
}

/// A page's content being built, see [NoteCacheScope.hold].
class NoteCachePageHold {
  NoteCachePageHold._(this._scope, this._key, this._onPopped);

  final NoteCacheScope _scope;
  final Object _key;
  final VoidCallback _onPopped;
  bool _shown = false;

  /// Whether the page is on screen: nothing of it goes while it is. Going
  /// out of sight, it may go at once if the pool is over its limit.
  set shown(bool value) {
    if (_shown == value) return;
    _shown = value;
    if (!value) _scope.pool._trim();
  }

  void release() {
    _shown = false;
    _scope._pages[_key]?.holds.remove(this);
    _scope.pool._trim();
  }
}

class _CachedPage {
  final Set<NoteCacheItem> items = <NoteCacheItem>{};
  final Set<NoteCachePageHold> holds = <NoteCachePageHold>{};

  bool get isShown => holds.any((NoteCachePageHold hold) => hold._shown);
}
