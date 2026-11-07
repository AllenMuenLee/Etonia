import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shows a picture of its child in the child's place while
/// [SnapshotController.allowSnapshotting] is set, and the child itself
/// otherwise.
///
/// This is Flutter's own [SnapshotWidget] with one difference that matters
/// to a zoom: the picture is taken at [pixelRatio], which the caller picks,
/// rather than at the screen's. Taken at several times the screen's density,
/// a picture can be scaled up by that much before it is any softer than the
/// live content would be, so a pinch can run on one picture for far longer
/// before it has to be taken again.
///
/// The picture is taken synchronously, in the paint that first needs it, from
/// what the child is at that moment, and kept until the controller is
/// cleared, snapshotting is turned off, or the size changes. A new
/// [pixelRatio] applies to the next picture, not the one held.
class ZoomSnapshot extends SingleChildRenderObjectWidget {
  const ZoomSnapshot({
    super.key,
    required this.controller,
    required this.painter,
    required this.pixelRatio,
    super.child,
  });

  final SnapshotController controller;

  /// Draws the picture, wherever it has been moved to, or the child.
  final SnapshotPainter painter;

  /// Device pixels in the picture to a logical pixel of the child.
  final double pixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderZoomSnapshot(
      controller: controller,
      painter: painter,
      pixelRatio: pixelRatio,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderZoomSnapshot renderObject,
  ) {
    renderObject
      ..controller = controller
      ..painter = painter
      ..pixelRatio = pixelRatio;
  }
}

class RenderZoomSnapshot extends RenderProxyBox {
  RenderZoomSnapshot({
    required this._controller,
    required this._painter,
    required this.pixelRatio,
  });

  SnapshotController get controller => _controller;
  SnapshotController _controller;
  set controller(SnapshotController value) {
    if (identical(value, _controller)) return;
    if (attached) _controller.removeListener(_onControllerChanged);
    _controller = value;
    if (attached) _controller.addListener(_onControllerChanged);
    _dropPicture();
    markNeedsPaint();
  }

  SnapshotPainter get painter => _painter;
  SnapshotPainter _painter;
  set painter(SnapshotPainter value) {
    if (identical(value, _painter)) return;
    final SnapshotPainter old = _painter;
    if (attached) old.removeListener(markNeedsPaint);
    _painter = value;
    if (attached) _painter.addListener(markNeedsPaint);
    if (old.runtimeType != value.runtimeType || value.shouldRepaint(old)) {
      markNeedsPaint();
    }
  }

  /// What the next picture is taken at. The one held keeps its own.
  double pixelRatio;

  ui.Image? _picture;
  Size? _pictureSize;
  double _pictureRatio = 1;
  bool _cannotPicture = false;

  /// The picture held, for tests.
  @visibleForTesting
  ui.Image? get picture => _picture;

  @override
  void attach(covariant PipelineOwner owner) {
    _controller.addListener(_onControllerChanged);
    _painter.addListener(markNeedsPaint);
    super.attach(owner);
  }

  @override
  void detach() {
    _controller.removeListener(_onControllerChanged);
    _painter.removeListener(markNeedsPaint);
    _cannotPicture = false;
    _dropPicture();
    super.detach();
  }

  @override
  void dispose() {
    _dropPicture();
    super.dispose();
  }

  void _onControllerChanged() {
    _cannotPicture = false;
    _dropPicture();
    markNeedsPaint();
  }

  void _dropPicture() {
    _picture?.dispose();
    _picture = null;
    _pictureSize = null;
  }

  /// Paints the child into a layer of its own and makes a picture of that,
  /// without leaving the child's layers in the tree.
  ui.Image? _takePicture() {
    final OffsetLayer layer = OffsetLayer();
    final PaintingContext context = PaintingContext(layer, Offset.zero & size);
    super.paint(context, Offset.zero);
    // Protected so a painting context is not ended by accident; ending it is
    // what this does, to have everything painted so far in the layer.
    // ignore: invalid_use_of_protected_member
    context.stopRecordingIfNeeded();
    if (!layer.supportsRasterization()) {
      // A platform view cannot be pictured: paint as usual instead.
      layer.dispose();
      _cannotPicture = true;
      return null;
    }
    final ui.Image image = layer.toImageSync(
      Offset.zero & size,
      pixelRatio: pixelRatio,
    );
    layer.dispose();
    _pictureRatio = pixelRatio;
    return image;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) {
      _dropPicture();
      return;
    }
    if (!_controller.allowSnapshotting || _cannotPicture) {
      _dropPicture();
      _painter.paint(context, offset, size, super.paint);
      return;
    }
    // A picture is only of the size it was taken at.
    if (_picture != null && _pictureSize != size) {
      _dropPicture();
    }
    if (_picture == null) {
      _picture = _takePicture();
      _pictureSize = _picture == null ? null : size;
    }
    final ui.Image? picture = _picture;
    if (picture == null) {
      _painter.paint(context, offset, size, super.paint);
      return;
    }
    _painter.paintSnapshot(
      context,
      offset,
      size,
      picture,
      size * _pictureRatio,
      _pictureRatio,
    );
  }
}
