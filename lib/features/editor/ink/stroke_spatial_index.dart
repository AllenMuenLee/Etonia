import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui';

import 'stroke.dart';

/// One stroke of a document giving way to [pieces], possibly none: what an
/// erase does to it.
class StrokeSplice {
  const StrokeSplice(this.index, this.pieces);

  /// The stroke's position before any splice of the same batch.
  final int index;

  final List<Stroke> pieces;
}

/// A compact uniform-grid index over immutable stroke bounds.
///
/// Queries return document indices in ascending order. Very large strokes
/// are kept in a small overflow list instead of being copied into thousands
/// of cells, which bounds both build time and memory on infinite pages.
///
/// An eraser changes a few strokes of a page per move, so the index follows
/// such a change with [apply] instead of being built again.
class StrokeSpatialIndex {
  StrokeSpatialIndex(
    List<Stroke> strokes, {
    this.cellSize = 128,
    this.maxCellsPerStroke = 256,
  }) : assert(cellSize > 0),
       assert(maxCellsPerStroke > 0),
       _source = strokes,
       _length = strokes.length {
    for (int i = 0; i < strokes.length; i++) {
      _insert(i, strokes[i].bounds);
    }
  }

  final double cellSize;
  final int maxCellsPerStroke;
  List<Stroke> _source;
  int _length;
  final HashMap<int, List<int>> _cells = HashMap<int, List<int>>();
  final List<int> _overflow = <int>[];

  /// Which [query] last met each stroke, so one spanning several cells is
  /// reported once without a set being made for it.
  Int32List _seen = Int32List(0);
  int _queryId = 0;

  /// Scratch for [apply]: where each stroke has moved to.
  Int32List _moved = Int32List(0);

  /// Counts the changes made since this index was built, so a caller can ask
  /// [changedSince] without looking at any strokes.
  int get version => _version;
  int _version = 0;

  /// The [version] of the last change touching each cell that has had one.
  final HashMap<int, int> _changed = HashMap<int, int>();
  int _overflowChanged = 0;

  int _cell(double coordinate) => (coordinate / cellSize).floor();

  /// One number for a cell. It stays exact for any page a double can
  /// describe to the pixel, on the web too: 2^26 cells a side.
  static int _key(int x, int y) =>
      (x + 0x2000000) * 0x4000000 + (y + 0x2000000);

  void _insert(int index, Rect bounds) {
    final int left = _cell(bounds.left);
    final int right = _cell(bounds.right);
    final int top = _cell(bounds.top);
    final int bottom = _cell(bounds.bottom);
    final int cells = (right - left + 1) * (bottom - top + 1);
    if (cells > maxCellsPerStroke) {
      _overflow.add(index);
      return;
    }
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        (_cells[_key(x, y)] ??= <int>[]).add(index);
      }
    }
  }

  /// Whether this index still describes [strokes]: the same collection, not
  /// grown or shrunk in place since it was built. Strokes are immutable, so
  /// identity and length together are enough.
  bool indexes(List<Stroke> strokes) =>
      identical(strokes, _source) && strokes.length == _length;

  /// Takes in what has been added to the end of [strokes] since this index
  /// was last brought up to date. Returns false, and changes nothing, when
  /// [strokes] is another collection or has shrunk: then only a new index
  /// will do.
  bool catchUp(List<Stroke> strokes) {
    if (!identical(strokes, _source) || strokes.length < _length) {
      return false;
    }
    if (strokes.length > _length) {
      _version++;
      for (int i = _length; i < strokes.length; i++) {
        _insert(i, strokes[i].bounds);
        _markChanged(strokes[i].bounds);
      }
      _length = strokes.length;
    }
    return true;
  }

  /// Follows [splices], in ascending order of index, having been made to the
  /// collection this index describes, giving [strokes]: from here on this
  /// index describes [strokes]. Cost grows with the entries of the index, not
  /// with what is in the strokes.
  void apply(List<Stroke> strokes, List<StrokeSplice> splices) {
    if (splices.isEmpty) {
      _source = strokes;
      return;
    }
    _version++;
    for (final StrokeSplice splice in splices) {
      _markChanged(_source[splice.index].bounds);
      for (final Stroke piece in splice.pieces) {
        _markChanged(piece.bounds);
      }
    }
    _source = strokes;
    if (_moved.length < _length) {
      _moved = Int32List(_capacityFor(_length));
    }
    final Int32List moved = _moved;
    final int first = splices.first.index;
    int shift = 0;
    int next = 0;
    for (int old = first; old < _length; old++) {
      if (next < splices.length && splices[next].index == old) {
        moved[old] = -1;
        shift += splices[next].pieces.length - 1;
        next++;
      } else {
        moved[old] = old + shift;
      }
    }
    assert(next == splices.length);
    for (final List<int> bucket in _cells.values) {
      _renumber(bucket, moved, first);
    }
    _renumber(_overflow, moved, first);
    _length += shift;
    assert(_length == strokes.length);
    int before = 0;
    for (final StrokeSplice splice in splices) {
      final int start = splice.index + before;
      for (int i = 0; i < splice.pieces.length; i++) {
        _insert(start + i, splice.pieces[i].bounds);
      }
      before += splice.pieces.length - 1;
    }
  }

  void _markChanged(Rect bounds) {
    final int left = _cell(bounds.left);
    final int right = _cell(bounds.right);
    final int top = _cell(bounds.top);
    final int bottom = _cell(bounds.bottom);
    if ((right - left + 1) * (bottom - top + 1) > maxCellsPerStroke) {
      _overflowChanged = _version;
      return;
    }
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        _changed[_key(x, y)] = _version;
      }
    }
  }

  /// Whether any stroke touching [area] may have changed, come, or gone since
  /// this index was at [version]. Never false when one has; it may be true
  /// when none has, cells being coarse.
  bool changedSince(int version, Rect area) {
    if (version >= _version) {
      return false;
    }
    if (_overflowChanged > version || !area.isFinite) {
      return true;
    }
    final int left = _cell(area.left);
    final int right = _cell(area.right);
    final int top = _cell(area.top);
    final int bottom = _cell(area.bottom);
    if ((right - left + 1) * (bottom - top + 1) > maxCellsPerStroke) {
      return true;
    }
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        final int? changed = _changed[_key(x, y)];
        if (changed != null && changed > version) {
          return true;
        }
      }
    }
    return false;
  }

  static void _renumber(List<int> bucket, Int32List moved, int first) {
    int kept = 0;
    for (int i = 0; i < bucket.length; i++) {
      final int value = bucket[i];
      final int now = value < first ? value : moved[value];
      if (now >= 0) {
        bucket[kept++] = now;
      }
    }
    bucket.length = kept;
  }

  static int _capacityFor(int length) => length + (length >> 2) + 16;

  /// Candidate indices whose indexed cells touch [area]. Bounds should still
  /// be checked by the caller because cells are deliberately coarse.
  List<int> query(Rect area) {
    // A degenerate (zero-width or zero-height) area is still a valid query,
    // such as a lasso drawn as a straight line.
    if (area.width < 0 || area.height < 0 || !area.isFinite || _length == 0) {
      return const <int>[];
    }
    final int left = _cell(area.left);
    final int right = _cell(area.right);
    final int top = _cell(area.top);
    final int bottom = _cell(area.bottom);
    final int cells = (right - left + 1) * (bottom - top + 1);
    if (cells > maxCellsPerStroke * 4) {
      return List<int>.generate(_length, (int index) => index);
    }
    if (_seen.length < _length) {
      _seen = Int32List(_capacityFor(_length));
      _queryId = 0;
    }
    final Int32List seen = _seen;
    final int id = ++_queryId;
    final List<int> found = <int>[];
    void take(List<int> bucket) {
      for (int i = 0; i < bucket.length; i++) {
        final int index = bucket[i];
        if (seen[index] != id) {
          seen[index] = id;
          found.add(index);
        }
      }
    }

    take(_overflow);
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        final List<int>? bucket = _cells[_key(x, y)];
        if (bucket != null) take(bucket);
      }
    }
    return found..sort();
  }

  int get cellCount => _cells.length;
  int get indexedLength => _length;
}
