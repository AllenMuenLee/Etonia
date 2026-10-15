import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ink/ink_controller.dart';
import '../ink/ink_selection.dart';
import 'document_models.dart';

typedef NoteAssetReader = Future<Uint8List?> Function(String assetId);

/// Paints page images in insertion order below every ink layer.
class PageImageLayer extends StatefulWidget {
  const PageImageLayer({
    super.key,
    required this.controller,
    required this.readAsset,
    this.maxDecodeDimension = 4096,
  });

  final InkController controller;
  final NoteAssetReader readAsset;
  final int maxDecodeDimension;

  @override
  State<PageImageLayer> createState() => _PageImageLayerState();
}

class _PageImageLayerState extends State<PageImageLayer> {
  final Map<String, Future<Uint8List?>> _assets =
      <String, Future<Uint8List?>>{};

  @override
  void didUpdateWidget(PageImageLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readAsset != widget.readAsset) {
      _assets.clear();
    }
  }

  Future<Uint8List?> _read(String assetId) {
    return _assets.putIfAbsent(assetId, () => widget.readAsset(assetId));
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
                element:
                    selected.contains(i) &&
                        widget.controller.activeTransform != null
                    ? widget.controller.images[i].transformed(
                        widget.controller.activeTransform!.transform,
                      )
                    : widget.controller.images[i],
                selected: selected.contains(i),
                asset: _read(widget.controller.images[i].assetId),
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
    required this.element,
    required this.selected,
    required this.asset,
    required this.maxDecodeDimension,
  });

  final NoteImageElement element;
  final bool selected;
  final Future<Uint8List?> asset;
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
          child: FutureBuilder<Uint8List?>(
            future: asset,
            builder: (BuildContext context, AsyncSnapshot<Uint8List?> data) {
              final Uint8List? bytes = data.data;
              if (bytes == null) {
                if (data.connectionState != ConnectionState.done) {
                  return const ColoredBox(color: Color(0x08000000));
                }
                return const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0x0F000000)),
                  child: Center(child: Text('Image unavailable')),
                );
              }
              final double pixelRatio = MediaQuery.devicePixelRatioOf(context);
              final double requestedWidth = element.size.width * pixelRatio;
              final double requestedHeight = element.size.height * pixelRatio;
              final double reduction = math.min(
                1,
                maxDecodeDimension / math.max(requestedWidth, requestedHeight),
              );
              return Image.memory(
                bytes,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
                cacheWidth: math.max(1, (requestedWidth * reduction).round()),
                cacheHeight: math.max(1, (requestedHeight * reduction).round()),
                errorBuilder: (_, _, _) =>
                    const Center(child: Text('Image unavailable')),
              );
            },
          ),
        ),
      ),
    );
  }
}
