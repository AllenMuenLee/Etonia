import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ink/ink_controller.dart';
import '../ink/ink_selection.dart';
import 'document_models.dart';
import 'page_image_cache.dart';

typedef NoteAssetReader = Future<Uint8List?> Function(String assetId);

/// Paints page images in insertion order below every ink layer.
class PageImageLayer extends StatefulWidget {
  const PageImageLayer({
    super.key,
    required this.controller,
    required this.readAsset,
    this.maxDecodeDimension = 4096,
    this.cache,
  });

  final InkController controller;
  final NoteAssetReader readAsset;
  final int maxDecodeDimension;
  final PageImageCache? cache;

  @override
  State<PageImageLayer> createState() => _PageImageLayerState();
}

class _PageImageLayerState extends State<PageImageLayer> {
  PageImageCache? _ownedCache;
  PageImageCache get _cache =>
      widget.cache ??
      (_ownedCache ??= PageImageCache(readAsset: widget.readAsset));

  @override
  void didUpdateWidget(PageImageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readAsset != widget.readAsset ||
        oldWidget.cache != widget.cache) {
      _ownedCache?.clear();
      _ownedCache = null;
    }
  }

  @override
  void dispose() {
    _ownedCache?.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.controller.completedStrokesListenable,
        widget.controller.selectionListenable,
      ]),
      builder: (BuildContext context, Widget? child) {
        final InkSelection? selection = widget.controller.selection;
        final Set<int> selected = selection?.imageIndices.toSet() ?? <int>{};
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            for (int i = 0; i < widget.controller.images.length; i++)
              _PlacedImage(
                key: ValueKey(widget.controller.images[i].id),
                element:
                    selected.contains(i) &&
                        widget.controller.activeTransform != null
                    ? widget.controller.images[i].transformed(
                        widget.controller.activeTransform!.transform,
                      )
                    : widget.controller.images[i],
                selected: selected.contains(i),
                cache: _cache,
                maxDecodeDimension: widget.maxDecodeDimension,
              ),
          ],
        );
      },
    );
  }
}

class _PlacedImage extends StatelessWidget {
  const _PlacedImage({
    super.key,
    required this.element,
    required this.selected,
    required this.cache,
    required this.maxDecodeDimension,
  });

  final NoteImageElement element;
  final bool selected;
  final PageImageCache cache;
  final int maxDecodeDimension;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: element.center.x - element.size.width / 2,
      top: element.center.y - element.size.height / 2,
      width: element.size.width,
      height: element.size.height,
      child: Semantics(
        image: true,
        label: element.fileName == null
            ? 'Image'
            : 'Image, ${element.fileName}',
        selected: selected,
        child: Transform.rotate(
          angle: element.rotation,
          child: _ImageContents(
            assetId: element.assetId,
            size: element.size,
            cache: cache,
            maxDimension: maxDecodeDimension,
          ),
        ),
      ),
    );
  }
}

class _ImageContents extends StatefulWidget {
  const _ImageContents({
    required this.assetId,
    required this.size,
    required this.cache,
    required this.maxDimension,
  });
  final String assetId;
  final Size size;
  final PageImageCache cache;
  final int maxDimension;
  @override
  State<_ImageContents> createState() => _ImageContentsState();
}

class _ImageContentsState extends State<_ImageContents> {
  ui.Image? _image;
  Object? _request;
  Object? _key;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(_ImageContents oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetId != widget.assetId ||
        oldWidget.cache != widget.cache) {
      _image?.dispose();
      _image = null;
    }
    _load();
  }

  void _load() {
    final requested = widget.size * MediaQuery.devicePixelRatioOf(context);
    final reduction = math.min(
      1.0,
      widget.maxDimension / math.max(requested.width, requested.height),
    );
    final width = math.max(1, (requested.width * reduction).round());
    final height = math.max(1, (requested.height * reduction).round());
    final key = (widget.cache, widget.assetId, width, height);
    if (key == _key) return;
    _key = key;
    _failed = false;
    final request = _request = Object();
    widget.cache
        .image(widget.assetId, width, height)
        .then(
          (image) {
            if (!mounted || request != _request) {
              image.dispose();
              return;
            }
            _image?.dispose();
            setState(() => _image = image);
          },
          onError: (Object _) {
            if (mounted && request == _request) setState(() => _failed = true);
          },
        );
  }

  @override
  void dispose() {
    _request = null;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _image != null
      ? RawImage(
          image: _image,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.medium,
        )
      : _failed
      ? const Center(child: Text('Image unavailable'))
      : const ColoredBox(color: Color(0x08000000));
}
