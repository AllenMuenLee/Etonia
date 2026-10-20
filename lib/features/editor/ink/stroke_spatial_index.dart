import 'dart:collection';
import 'dart:ui';

import 'stroke.dart';

/// A compact uniform-grid index over immutable stroke bounds.
///
/// Queries return document indices in ascending order. Very large strokes
/// are kept in a small overflow list instead of being copied into thousands
/// of cells, which bounds both build time and memory on infinite pages.
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
      final Rect bounds = strokes[i].bounds;
      final int left = _cell(bounds.left);
      final int right = _cell(bounds.right);
      final int top = _cell(bounds.top);
      final int bottom = _cell(bounds.bottom);
      final int cells = (right - left + 1) * (bottom - top + 1);
      if (cells > maxCellsPerStroke) {
        _overflow.add(i);
        continue;
      }
      for (int y = top; y <= bottom; y++) {
        for (int x = left; x <= right; x++) {
          (_cells[_Cell(x, y)] ??= <int>[]).add(i);
        }
      }
    }
  }

  final double cellSize;
  final int maxCellsPerStroke;
  final List<Stroke> _source;
  final int _length;
  final Map<_Cell, List<int>> _cells = <_Cell, List<int>>{};
  final List<int> _overflow = <int>[];

  int _cell(double coordinate) => (coordinate / cellSize).floor();

  /// Whether this index still describes [strokes]: the same collection, not
  /// grown or shrunk in place since it was built. Strokes are immutable, so
  /// identity and length together are enough.
  bool indexes(List<Stroke> strokes) =>
      identical(strokes, _source) && strokes.length == _length;

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
    final Set<int> found = HashSet<int>()..addAll(_overflow);
    for (int y = top; y <= bottom; y++) {
      for (int x = left; x <= right; x++) {
        final List<int>? bucket = _cells[_Cell(x, y)];
        if (bucket != null) found.addAll(bucket);
      }
    }
    return found.toList()..sort();
  }

  int get cellCount => _cells.length;
  int get indexedLength => _length;
}

class _Cell {
  const _Cell(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _Cell && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}
