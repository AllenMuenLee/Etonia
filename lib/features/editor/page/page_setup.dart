import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// How big a page is.
enum PageSize {
  a4Portrait('A4 portrait', Size(794, 1123)),
  a4Landscape('A4 landscape', Size(1123, 794)),
  letterPortrait('Letter portrait', Size(816, 1056)),
  letterLandscape('Letter landscape', Size(1056, 816)),
  square('Square', Size(1000, 1000)),

  /// A fixed size captured from a PDF-backed page when a normal page is
  /// added after it. The dimensions live in [PageSetup.customSize].
  custom('Custom'),

  /// A whiteboard: an [InfiniteBoard] that reaches far past the screen in
  /// every direction, with no paper edge in view.
  infinite('Infinite');

  const PageSize(this.label, [this.fixedSize]);

  final String label;

  /// The paper size in logical page units, for a fixed size.
  final Size? fixedSize;

  bool get isFixed => fixedSize != null;
}

/// What is printed on the paper under the ink.
enum PageBackground {
  blank('Blank'),
  lined('Lined'),
  grid('Grid'),
  dotted('Dotted');

  const PageBackground(this.label);

  final String label;
}

/// A page's size and background.
@immutable
class PageSetup {
  const PageSetup({
    this.size = PageSize.a4Portrait,
    this.background = PageBackground.blank,
    Size? customSize,
  }) : customSize = size == PageSize.custom
           ? (customSize ?? const Size(1000, 1000))
           : customSize;

  final PageSize size;
  final PageBackground background;
  final Size? customSize;

  PageSetup copyWith({
    PageSize? size,
    PageBackground? background,
    Size? customSize,
  }) {
    final PageSize nextSize = size ?? this.size;
    return PageSetup(
      size: nextSize,
      background: background ?? this.background,
      customSize: nextSize == PageSize.custom
          ? (customSize ?? this.customSize)
          : null,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PageSetup &&
        other.size == size &&
        other.background == background &&
        other.customSize == customSize;
  }

  @override
  int get hashCode => Object.hash(size, background, customSize);
}

/// Background rule spacings, in logical page units.
class PageConfig {
  const PageConfig({
    this.lineSpacing = 32,
    this.gridSpacing = 24,
    this.dotSpacing = 24,
    this.marginRuleInset = 72,
    this.appendPageAt = 0.75,
    this.minRuleGap = 10,
  }) : assert(lineSpacing > 0),
       assert(appendPageAt > 0 && appendPageAt <= 1),
       assert(gridSpacing > 0),
       assert(dotSpacing > 0),
       assert(minRuleGap >= 0);

  final double lineSpacing;
  final double gridSpacing;
  final double dotSpacing;

  /// Distance of lined paper's margin rule from the left edge.
  final double marginRuleInset;

  /// Once ink on the last page of a fixed size reaches this fraction of
  /// its height, an empty page is added after it, ready to scroll onto.
  final double appendPageAt;

  /// The closest, in screen pixels, that rules are drawn to each other.
  /// Zoomed far out, as a whiteboard can be, every second rule is left out,
  /// and again, until they are at least this far apart.
  final double minRuleGap;
}

/// The writing surface of an infinite page: one fixed square of page
/// units, so large that it reads as endless. Its ink starts at [origin],
/// the middle, so there is as much room above and to the left of the first
/// stroke as below and to the right of it.
///
/// Its size is a power of two, kept small enough that page coordinates
/// stay finer than a hundredth of a unit in single precision.
abstract final class InfiniteBoard {
  static const double extent = 131072;
  static const Size size = Size(extent, extent);

  /// The middle of the board, on the rules' lattice, so ink moved here from
  /// a fixed page, or back, keeps its place on the lines.
  static const Offset origin = Offset(683 * frameSnap, 683 * frameSnap);

  /// The smallest frame [frameOf] gives, so a few lines of ink do not fill
  /// a whole thumbnail or exported page.
  static const Size minFrame = Size(640, 480);

  /// The blank border [frameOf] leaves round the ink.
  static const double frameMargin = 48;

  /// The part of a board worth showing away from the editor, in thumbnails,
  /// the page overview, and exports: [ink] with a margin, at least
  /// [minFrame], or a [minFrame] at [origin] when there is no ink.
  static Rect frameOf(Rect? ink) {
    if (ink == null || !ink.isFinite) {
      return origin & minFrame;
    }
    final Rect padded = ink.inflate(frameMargin);
    // On the rules' lattice, so lines and dots shown from the frame's
    // corner fall where they were under the ink.
    final Offset corner = Offset(
      (padded.left / frameSnap).floorToDouble() * frameSnap,
      (padded.top / frameSnap).floorToDouble() * frameSnap,
    );
    return corner &
        Size(
          math.max(padded.right - corner.dx, minFrame.width),
          math.max(padded.bottom - corner.dy, minFrame.height),
        );
  }

  /// A multiple of every default rule spacing.
  static const double frameSnap = 96;

  /// The shift that brings a board's [ink] onto a fixed page: back by
  /// [origin], and then far enough down and right that none of it is
  /// left above or to the left of the paper.
  static Offset toPage(Rect? ink) {
    double dx = -origin.dx;
    double dy = -origin.dy;
    if (ink != null && ink.isFinite) {
      if (ink.left + dx < 0) dx = frameMargin - ink.left;
      if (ink.top + dy < 0) dy = frameMargin - ink.top;
    }
    return Offset(dx, dy);
  }
}

/// Where a page sits in the writing area: its size in page units, and the
/// scale it is shown at.
@immutable
class PageGeometry {
  const PageGeometry(this.pageSize, this.scale);

  /// A fixed page is scaled to the area's width; an infinite page is the
  /// whole [InfiniteBoard], at scale 1.
  factory PageGeometry.of(
    PageSetup setup,
    Size? extent,
    Size viewport, {
    Size? pdfPageSize,
  }) {
    if (pdfPageSize != null) {
      final double scale = viewport.width > 0 && viewport.width.isFinite
          ? viewport.width / pdfPageSize.width
          : 1;
      return PageGeometry(pdfPageSize, scale);
    }
    switch (setup.size) {
      case PageSize.infinite:
        return const PageGeometry(InfiniteBoard.size, 1);
      case PageSize.a4Portrait:
      case PageSize.a4Landscape:
      case PageSize.letterPortrait:
      case PageSize.letterLandscape:
      case PageSize.square:
      case PageSize.custom:
        final Size paper = setup.size == PageSize.custom
            ? setup.customSize!
            : setup.size.fixedSize!;
        final double scale = viewport.width > 0 && viewport.width.isFinite
            ? viewport.width / paper.width
            : 1;
        return PageGeometry(paper, scale);
    }
  }

  final Size pageSize;
  final double scale;

  /// The page's size on screen.
  Size get displaySize => pageSize * scale;

  @override
  bool operator ==(Object other) {
    return other is PageGeometry &&
        other.pageSize == pageSize &&
        other.scale == scale;
  }

  @override
  int get hashCode => Object.hash(pageSize, scale);
}
