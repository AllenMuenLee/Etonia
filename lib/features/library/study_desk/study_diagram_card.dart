import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';
import 'study_desk_widgets.dart';
import 'study_view_cache.dart';

/// A crop of the actual note, loaded once while this lazy transcript row lives.
class StudyDiagramCard extends StatefulWidget {
  const StudyDiagramCard({
    super.key,
    required this.controller,
    required this.citation,
    required this.onPressed,
  });
  final StudyDeskController controller;
  final StudyCitation citation;
  final VoidCallback onPressed;

  @override
  State<StudyDiagramCard> createState() => _StudyDiagramCardState();
}

class _StudyDiagramCardState extends State<StudyDiagramCard> {
  late int _epoch = widget.controller.pagesEpoch;
  late Object? _key = _keyOf();
  late Future<Uint8List?> _crop = _load();

  /// What this crop is made from: the same card, shown again as the chat is
  /// scrolled or another chat is opened, is not cut out again.
  Object? _keyOf() {
    final citation = widget.citation;
    final bounds = citation.bounds;
    if (bounds == null || bounds.isEmpty) return null;
    return (
      identityHashCode(widget.controller.repository),
      citation.noteId,
      widget.controller.revisionOf(citation.noteId),
      citation.pageIndex,
      bounds.left,
      bounds.top,
      bounds.right,
      bounds.bottom,
      citation.kind,
    );
  }

  Future<Uint8List?> _load() {
    final Object? key = _key;
    if (key == null) return Future<Uint8List?>.value();
    return StudyViewCache.crops.load(key, _render);
  }

  Future<Uint8List?> _render() async {
    final citation = widget.citation;
    final controller = widget.controller;
    try {
      final view = await controller.pageFor(citation);
      if (view == null) return null;
      final bounds = citation.bounds;
      if (bounds == null || bounds.isEmpty) return null;
      final chunk = StudyChunk(
        noteId: citation.noteId,
        pageIndex: citation.pageIndex,
        chunkIndex: 0,
        kind: citation.kind ?? StudyChunkKind.diagram,
        logicalBounds: bounds,
        strokeIndices: [
          for (var i = 0; i < view.page.strokes.length; i++)
            if (bounds.overlaps(view.page.strokes[i].bounds)) i,
        ],
        imageIds: [
          for (final image in view.page.images)
            if (bounds.overlaps(image.bounds)) image.id,
        ],
        stickyIds: [
          for (final sticky in view.page.stickyNotes)
            if (bounds.overlaps(sticky.bounds)) sticky.id,
        ],
      );
      return (await controller.renderer.render(chunk))?.png;
    } on Object {
      return null;
    }
  }

  @override
  void didUpdateWidget(StudyDiagramCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.citation.noteId != widget.citation.noteId ||
        oldWidget.citation.pageIndex != widget.citation.pageIndex ||
        oldWidget.citation.bounds != widget.citation.bounds ||
        _epoch != widget.controller.pagesEpoch ||
        oldWidget.controller != widget.controller) {
      _epoch = widget.controller.pagesEpoch;
      _key = _keyOf();
      _crop = _load();
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: StudySurface(
      onTap: widget.onPressed,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 150,
            child: FutureBuilder<Uint8List?>(
              future: _crop,
              initialData: _key == null
                  ? null
                  : StudyViewCache.crops.peek(_key!),
              builder: (context, snap) => AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.fadeIn),
                switchInCurve: AppMotion.fadeInCurve,
                switchOutCurve: AppMotion.fadeOutCurve,
                child: snap.data == null
                    ? const Center(
                        key: ValueKey<String>('diagram-placeholder'),
                        child: AppIcon(Icons.schema_rounded),
                      )
                    : RepaintBoundary(
                        key: const ValueKey<String>('diagram-crop'),
                        child: Image.memory(
                          snap.data!,
                          fit: BoxFit.contain,
                          cacheWidth: 640,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              const Center(child: AppIcon(Icons.schema_rounded)),
                        ),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const AppIcon(Icons.zoom_in_rounded),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Inspect diagram · ${widget.controller.labelOf(widget.citation)}',
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
