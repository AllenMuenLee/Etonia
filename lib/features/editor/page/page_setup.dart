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

  /// Starts at the size of the writing area and grows when ink reaches its
  /// right or bottom edge.
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

/// Background rule spacings and infinite-page growth, in logical page
/// units.
class PageConfig {
  const PageConfig({
    this.lineSpacing = 32,
    this.gridSpacing = 24,
    this.dotSpacing = 24,
    this.marginRuleInset = 72,
    this.edgeMargin = 96,
    this.growthFraction = 0.5,
    this.minGrowthStep = 256,
    this.maxExtent = 20000,
    this.appendPageAt = 0.75,
  }) : assert(lineSpacing > 0),
       assert(appendPageAt > 0 && appendPageAt <= 1),
       assert(gridSpacing > 0),
       assert(dotSpacing > 0),
       assert(edgeMargin >= 0),
       assert(growthFraction >= 0),
       assert(minGrowthStep > 0),
       assert(maxExtent > 0);

  final double lineSpacing;
  final double gridSpacing;
  final double dotSpacing;

  /// Distance of lined paper's margin rule from the left edge.
  final double marginRuleInset;

  /// An infinite page grows when ink comes this close to its right or
  /// bottom edge.
  final double edgeMargin;

  /// Each growth adds this fraction of the writing area's extent in that
  /// direction, and at least [minGrowthStep].
  final double growthFraction;
  final double minGrowthStep;

  /// An infinite page never grows past this in either direction.
  final double maxExtent;

  /// Once ink on the last page of a fixed size reaches this fraction of
  /// its height, an empty page is added after it, ready to scroll onto.
  final double appendPageAt;
}

/// Where a page sits in the writing area: its size in page units, and the
/// scale it is shown at.
@immutable
class PageGeometry {
  const PageGeometry(this.pageSize, this.scale);

  /// A fixed page is scaled to the area's width; an infinite page is shown at
  /// scale 1 and is never smaller than the area.
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
        return PageGeometry(
          Size(
            math.max(extent?.width ?? 0, viewport.width),
            math.max(extent?.height ?? 0, viewport.height),
          ),
          1,
        );
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

/// The extent an infinite page should grow to so that [ink] keeps at least
/// [PageConfig.edgeMargin] from its right and bottom edges, or null when
/// it need not grow. [current] is the page's present size and [viewport]
/// the writing area, which sets the step.
Size? grownPageExtent({
  required Size current,
  required Size viewport,
  required Rect ink,
  PageConfig config = const PageConfig(),
}) {
  if (!ink.isFinite) {
    return null;
  }
  double width = current.width;
  double height = current.height;
  if (ink.right > width - config.edgeMargin) {
    final double step = math.max(
      config.minGrowthStep,
      viewport.width * config.growthFraction,
    );
    width = math.max(width + step, ink.right + config.edgeMargin);
  }
  if (ink.bottom > height - config.edgeMargin) {
    final double step = math.max(
      config.minGrowthStep,
      viewport.height * config.growthFraction,
    );
    height = math.max(height + step, ink.bottom + config.edgeMargin);
  }
  width = math.min(width, math.max(current.width, config.maxExtent));
  height = math.min(height, math.max(current.height, config.maxExtent));
  if (width == current.width && height == current.height) {
    return null;
  }
  return Size(width, height);
}
