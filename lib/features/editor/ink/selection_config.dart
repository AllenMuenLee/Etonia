// Pure Dart: no Flutter imports, so selection math can run anywhere.
import 'ink_sample.dart';

/// Tolerances, sizes, and limits for selecting and transforming ink. All
/// lengths are page-local logical pixels, so selection behaves the same at
/// any device pixel ratio.
class SelectionConfig {
  const SelectionConfig({
    this.minLassoPointSpacing = 2,
    this.geometryTolerance = 0.001,
    this.handleVisualRadius = 6,
    this.handleHitRadius = 24,
    this.rotationHandleOffset = 32,
    this.minScale = 0.1,
    this.maxScale = 10,
    this.pasteOffset = const InkVector(24, 24),
    this.minStrokeWidth = 0.01,
    this.maxCoordinate = 1e6,
    this.rectangleMaxDetour = 1.25,
    this.lassoClosingFraction = 0.2,
    this.lassoDashLength = 6,
    this.lassoDashGap = 4,
    this.pasteHoldDuration = const Duration(milliseconds: 500),
    this.pasteHoldSlop = 10,
    this.pdfSelectionMargin = 32,
  }) : assert(minLassoPointSpacing >= 0),
       assert(minLassoPointSpacing < double.infinity),
       assert(geometryTolerance >= 0),
       assert(geometryTolerance < double.infinity),
       assert(handleVisualRadius > 0),
       assert(handleHitRadius >= handleVisualRadius),
       assert(handleHitRadius < double.infinity),
       assert(rotationHandleOffset > 0),
       assert(rotationHandleOffset < double.infinity),
       assert(minScale > 0),
       assert(minScale <= 1),
       assert(maxScale >= 1),
       assert(maxScale < double.infinity),
       assert(minStrokeWidth > 0),
       assert(minStrokeWidth < double.infinity),
       assert(maxCoordinate > 0),
       assert(maxCoordinate < double.infinity),
       assert(rectangleMaxDetour >= 1),
       assert(rectangleMaxDetour < double.infinity),
       assert(lassoClosingFraction >= 0),
       assert(lassoClosingFraction <= 1),
       assert(lassoDashLength > 0),
       assert(lassoDashLength < double.infinity),
       assert(lassoDashGap > 0),
       assert(lassoDashGap < double.infinity),
       assert(pasteHoldSlop >= 0),
       assert(pasteHoldSlop < double.infinity),
       assert(pdfSelectionMargin >= 0),
       assert(pdfSelectionMargin < double.infinity);

  /// A lasso point is stored only once the pointer is this far from the
  /// previous stored point. The first and the final point are always kept.
  final double minLassoPointSpacing;

  /// Inclusive slack for geometry: ink this close to the lasso touches it, a
  /// lasso this thin has no area, and a transform that moves nothing further
  /// than this is the identity.
  final double geometryTolerance;

  /// Painted radius of the scale and rotation handles.
  final double handleVisualRadius;

  /// How far from a handle's center a pointer still grabs it. The default
  /// gives each handle a 48 px target.
  final double handleHitRadius;

  /// Distance from the frame's top edge to the rotation handle.
  final double rotationHandleOffset;

  /// Smallest and largest uniform scale one gesture can apply.
  final double minScale;
  final double maxScale;

  /// How far each paste lands from the one before it, starting from the
  /// copied ink. Must be finite; a paste that cannot be placed is refused.
  final InkVector pasteOffset;

  /// Scaling down stops where the thinnest selected stroke would get thinner
  /// than this, so repeated gestures cannot shrink ink to nothing.
  final double minStrokeWidth;

  /// A move, scale, rotation, or paste that would put the selection frame
  /// further than this from the page origin, on either axis, is refused.
  /// It keeps repeated gestures from running coordinates off to infinity.
  final double maxCoordinate;

  /// A drag is a rectangle selection, with its start and end as opposite
  /// corners, while the path drawn is no longer than this many times the
  /// straight distance between them. A path that wanders more is a freeform
  /// lasso.
  final double rectangleMaxDetour;

  /// A freeform lasso selects only when it ends nearly where it began: the
  /// gap between its two ends must be no more than this share of the length
  /// drawn. An open one selects nothing.
  final double lassoClosingFraction;

  /// Length of the dashes, and of the gaps between them, in the selection
  /// outline while it is drawn.
  final double lassoDashLength;
  final double lassoDashGap;

  /// Holding a pointer still on the page for this long, with something on
  /// the clipboard, offers Paste there.
  final Duration pasteHoldDuration;

  /// How far a held pointer may drift and still count as still.
  final double pasteHoldSlop;

  /// A selection on a PDF page takes the paper along with the ink inside
  /// it only when its outline keeps at least this far from all of that ink;
  /// drawn closer, it picks the ink alone.
  final double pdfSelectionMargin;
}
