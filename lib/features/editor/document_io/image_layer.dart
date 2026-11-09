import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../shared/widgets/processing.dart';
import '../ink/ink_canvas.dart';
import '../ink/ink_controller.dart';
import '../ink/ink_selection.dart';
import 'document_models.dart';
import 'page_image_cache.dart';
import 'svg_document.dart';

typedef NoteAssetReader = Future<Uint8List?> Function(String assetId);

/// Paints page images in insertion order below every ink layer.
class PageImageLayer extends StatefulWidget {
  const PageImageLayer({
    super.key,
    required this.controller,
    this.readAsset,
    this.maxDecodeDimension = 4096,
    this.cache,
    this.cachePage,
    this.carry,
  });

  /// The page the pictures are kept for, in [cache].
  final Object? cachePage;

  final InkController controller;
  final NoteAssetReader? readAsset;
  final int maxDecodeDimension;
  final PageImageCache? cache;
  final SelectionCarry? carry;

  @override
  State<PageImageLayer> createState() => _PageImageLayerState();
}

class _PageImageLayerState extends State<PageImageLayer> {
  PageImageCache? _ownedCache;
  PageImageCache? get _cache {
    if (widget.cache != null) return widget.cache;
    final NoteAssetReader? reader = widget.readAsset;
    return reader == null
        ? null
        : (_ownedCache ??= PageImageCache(readAsset: reader));
  }

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
        widget.controller.completedPaintListenable,
        widget.controller.selectionListenable,
        widget.controller.svgAnimationListenable,
        if (widget.carry != null) widget.carry!,
      ]),
      builder: (BuildContext context, Widget? child) {
        final InkSelection? selection = widget.controller.selection;
        final Set<int> selected = selection?.imageIndices.toSet() ?? <int>{};
        final List<NoteImageElement> foreignImages =
            widget.carry?.foreignImagesFor(widget.controller) ??
            const <NoteImageElement>[];
        final Set<Key> seenKeys = <Key>{};
        Key keyFor(String id, [int? index]) {
          final Key primary = ValueKey<String>(id);
          if (seenKeys.add(primary)) {
            return primary;
          }
          int disambiguator = index ?? 0;
          while (true) {
            final Key fallback = ValueKey<String>('$id-dup-$disambiguator');
            if (seenKeys.add(fallback)) {
              return fallback;
            }
            disambiguator++;
          }
        }

        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            for (int i = 0; i < widget.controller.images.length; i++)
              _PlacedImage(
                key: keyFor(widget.controller.images[i].id, i),
                element:
                    selected.contains(i) &&
                        widget.controller.activeTransform != null
                    ? widget.controller.images[i].transformed(
                        widget.controller.activeTransform!.transform,
                      )
                    : widget.controller.images[i],
                selected: selected.contains(i),
                cache: _cache,
                cachePage: widget.cachePage,
                maxDecodeDimension: widget.maxDecodeDimension,
                animateSvg: widget.controller.svgAnimationsEnabled,
              ),
            for (int i = 0; i < foreignImages.length; i++)
              _PlacedImage(
                key: keyFor('foreign-${foreignImages[i].id}', i),
                element: foreignImages[i],
                selected: true,
                cache: _cache,
                cachePage: widget.cachePage,
                maxDecodeDimension: widget.maxDecodeDimension,
                animateSvg: widget.controller.svgAnimationsEnabled,
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
    required this.cachePage,
    required this.maxDecodeDimension,
    required this.animateSvg,
  });

  final NoteImageElement element;
  final bool selected;
  final PageImageCache? cache;
  final Object? cachePage;
  final int maxDecodeDimension;
  final bool animateSvg;

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
          child: element.vector != null
              ? _SvgContents(
                  vector: element.vector!,
                  animate: animateSvg,
                  brightness: Theme.of(context).brightness,
                )
              : cache == null
              ? const Center(child: Text('Image unavailable'))
              : _ImageContents(
                  assetId: element.assetId,
                  size: element.size,
                  cache: cache!,
                  cachePage: cachePage,
                  maxDimension: maxDecodeDimension,
                ),
        ),
      ),
    );
  }
}

/// Renders the retained SVG source. Animation changes only at semantic SVG
/// steps, keeping parsing and widget work off per-frame paths.
class _SvgContents extends StatefulWidget {
  const _SvgContents({
    required this.vector,
    required this.animate,
    required this.brightness,
  });

  final EditableSvg vector;
  final bool animate;
  final Brightness brightness;

  @override
  State<_SvgContents> createState() => _SvgContentsState();
}

class _SvgContentsState extends State<_SvgContents>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late List<String> _frames;
  int _step = -1;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(_SvgContents oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vector.source != widget.vector.source ||
        oldWidget.brightness != widget.brightness) {
      _controller?.dispose();
      _controller = null;
      _prepare();
      _syncMotion();
    } else if (oldWidget.animate != widget.animate) {
      _syncMotion();
    }
  }

  void _prepare() {
    _frames = <String>[
      for (int step = 0; step <= widget.vector.stepCount; step++)
        widget.vector.frame(step, brightness: widget.brightness),
    ];
    _step = widget.vector.isAnimated ? 0 : widget.vector.stepCount;
  }

  void _syncMotion() {
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    if (!widget.vector.isAnimated || reduce || !widget.animate) {
      _controller?.stop();
      final int last = widget.vector.stepCount;
      if (_step != last) setState(() => _step = last);
      return;
    }
    final AnimationController controller = _controller ??= AnimationController(
      vsync: this,
      duration: widget.vector.duration,
    )..addListener(_tick);
    if (!controller.isAnimating) controller.repeat();
  }

  void _tick() {
    final AnimationController? controller = _controller;
    if (controller == null || !mounted) return;
    final int next = (controller.value * (widget.vector.stepCount + 1))
        .floor()
        .clamp(0, widget.vector.stepCount);
    if (next != _step) setState(() => _step = next);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    _frames[_step.clamp(0, _frames.length - 1)],
    key: ValueKey<int>(_step),
    fit: BoxFit.fill,
    clipBehavior: Clip.hardEdge,
  );
}

class _ImageContents extends StatefulWidget {
  const _ImageContents({
    required this.assetId,
    required this.size,
    required this.cache,
    required this.cachePage,
    required this.maxDimension,
  });
  final String assetId;
  final Size size;
  final PageImageCache cache;
  final Object? cachePage;
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
        .image(widget.assetId, width, height, page: widget.cachePage)
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

  // The picture fades in over its faint frame once decoded; a resize keeps
  // showing the old one until the new size is ready.
  @override
  Widget build(BuildContext context) => LoadingReveal(
    timing: LoadTimings.image,
    placeholder: const ColoredBox(color: Color(0x08000000)),
    child: _image != null
        ? SizedBox.expand(
            child: RawImage(
              image: _image,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            ),
          )
        : _failed
        ? const Center(child: Text('Image unavailable'))
        : null,
  );
}
