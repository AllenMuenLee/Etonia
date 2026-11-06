import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../ink/ink_sample.dart';
import '../ink/selection_transform.dart';
import 'svg_document.dart';

@immutable
class PdfPageSource {
  const PdfPageSource({
    required this.assetId,
    required this.pageIndex,
    required this.pageSize,
  });

  final String assetId;
  final int pageIndex;
  final Size pageSize;

  bool get isValid =>
      assetId.isNotEmpty &&
      pageIndex >= 0 &&
      pageSize.isFinite &&
      pageSize.width > 0 &&
      pageSize.height > 0;

  @override
  bool operator ==(Object other) =>
      other is PdfPageSource &&
      other.assetId == assetId &&
      other.pageIndex == pageIndex &&
      other.pageSize == pageSize;

  @override
  int get hashCode => Object.hash(assetId, pageIndex, pageSize);
}

/// A bitmap or editable SVG placed below ink. List order is paint order.
@immutable
class NoteImageElement {
  const NoteImageElement({
    required this.id,
    required this.assetId,
    required this.pixelSize,
    required this.center,
    required this.size,
    this.rotation = 0,
    this.fileName,
    this.vector,
    this.aiGenerated = false,
  });

  /// A unique id for a new image element.
  static String newId([String prefix = 'image']) {
    _idCount++;
    final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final String random = _random.nextInt(1 << 32).toRadixString(36);
    return '$prefix-$time-$_idCount-$random';
  }

  static int _idCount = 0;
  static final math.Random _random = math.Random();

  final String id;
  final String assetId;
  final Size pixelSize;
  final InkVector center;
  final Size size;
  final double rotation;
  final String? fileName;

  /// Inline editable SVG source. Bitmap elements leave this null and use
  /// [assetId]. Keeping it inline makes copy, save, import, and export lossless.
  final EditableSvg? vector;
  final bool aiGenerated;

  bool get isVector => vector != null;

  bool get isValid =>
      id.isNotEmpty &&
      (assetId.isNotEmpty || vector != null) &&
      pixelSize.isFinite &&
      pixelSize.width > 0 &&
      pixelSize.height > 0 &&
      center.isFinite &&
      size.isFinite &&
      size.width > 0 &&
      size.height > 0 &&
      rotation.isFinite;

  List<InkVector> get corners {
    final double c = math.cos(rotation);
    final double s = math.sin(rotation);
    final double hw = size.width / 2;
    final double hh = size.height / 2;
    return <InkVector>[
      for (final InkVector local in <InkVector>[
        InkVector(-hw, -hh),
        InkVector(hw, -hh),
        InkVector(hw, hh),
        InkVector(-hw, hh),
      ])
        InkVector(
          center.x + c * local.x - s * local.y,
          center.y + s * local.x + c * local.y,
        ),
    ];
  }

  Rect get bounds {
    final List<InkVector> points = corners;
    return Rect.fromLTRB(
      points.map((InkVector p) => p.x).reduce(math.min),
      points.map((InkVector p) => p.y).reduce(math.min),
      points.map((InkVector p) => p.x).reduce(math.max),
      points.map((InkVector p) => p.y).reduce(math.max),
    );
  }

  bool contains(InkVector point, {double tolerance = 0}) {
    final double c = math.cos(-rotation);
    final double s = math.sin(-rotation);
    final InkVector delta = point - center;
    final double x = c * delta.x - s * delta.y;
    final double y = s * delta.x + c * delta.y;
    return x.abs() <= size.width / 2 + tolerance &&
        y.abs() <= size.height / 2 + tolerance;
  }

  NoteImageElement transformed(InkTransform transform) {
    final double scale = transform.scale;
    return NoteImageElement(
      id: id,
      assetId: assetId,
      pixelSize: pixelSize,
      center: transform.apply(center),
      size: Size(size.width * scale, size.height * scale),
      rotation: rotation + transform.angle,
      fileName: fileName,
      vector: vector,
      aiGenerated: aiGenerated,
    );
  }

  NoteImageElement copyWith({String? id, String? assetId}) {
    return NoteImageElement(
      id: id ?? this.id,
      assetId: assetId ?? this.assetId,
      pixelSize: pixelSize,
      center: center,
      size: size,
      rotation: rotation,
      fileName: fileName,
      vector: vector,
      aiGenerated: aiGenerated,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NoteImageElement &&
      other.id == id &&
      other.assetId == assetId &&
      other.pixelSize == pixelSize &&
      other.center == center &&
      other.size == size &&
      other.rotation == rotation &&
      other.fileName == fileName &&
      other.vector?.source == vector?.source &&
      other.aiGenerated == aiGenerated;

  @override
  int get hashCode => Object.hash(
    id,
    assetId,
    pixelSize,
    center,
    size,
    rotation,
    fileName,
    vector?.source,
    aiGenerated,
  );
}
