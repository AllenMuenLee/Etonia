import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import 'study_desk_controller.dart';
import 'study_desk_models.dart';
import 'study_desk_widgets.dart';

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
  late Future<Uint8List?> _crop = _load();

  Future<Uint8List?> _load() async {
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
              builder: (context, snap) => AnimatedSwitcher(
                duration: AppMotion.resolve(context, AppMotion.fadeIn),
                switchInCurve: AppMotion.fadeInCurve,
                switchOutCurve: AppMotion.fadeOutCurve,
                child: snap.data == null
                    ? const Center(
                        key: ValueKey<String>('diagram-placeholder'),
                        child: Icon(Icons.schema_outlined),
                      )
                    : RepaintBoundary(
                        key: const ValueKey<String>('diagram-crop'),
                        child: Image.memory(
                          snap.data!,
                          fit: BoxFit.contain,
                          cacheWidth: 640,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              const Center(child: Icon(Icons.schema_outlined)),
                        ),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Icon(Icons.zoom_in, size: 18),
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
