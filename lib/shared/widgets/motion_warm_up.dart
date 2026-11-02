import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import 'scene_transitions.dart';

/// Draws one frame of the app's scene transition out of sight as the app
/// starts, so the first real one does not stutter.
///
/// With the Skia renderer (Impeller is off on Android, see the manifest),
/// the GPU programs for a kind of drawing are compiled the first time that
/// drawing happens, which costs a frame or more. Every move between scenes,
/// a folder's and a note's alike, is the same few operations: a scene drawn
/// into a picture, then that picture faded and scaled ([SceneCrossfade]).
/// Here exactly those, at mid-move, are drawn once into a single pixel in
/// the corner for two frames, then taken away: nothing is seen, and what
/// the transitions need is ready before the first tap.
class MotionWarmUp extends StatefulWidget {
  const MotionWarmUp({super.key, required this.child});

  final Widget child;

  @override
  State<MotionWarmUp> createState() => _MotionWarmUpState();
}

class _MotionWarmUpState extends State<MotionWarmUp> {
  bool _warming = true;
  final SnapshotController _snapshots = SnapshotController(
    allowSnapshotting: true,
  );

  @override
  void initState() {
    super.initState();
    // One frame to draw it, one more for the pictures drawn from it; then
    // it goes. Both run in the frame update.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _warming = false);
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  @override
  void dispose() {
    _snapshots.dispose();
    super.dispose();
  }

  /// A scene's usual ingredients: a card on paper with its shadow, a
  /// clipped rounded picture, and text.
  Widget _sample(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ColoredBox(
      color: colors.background,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.writingSurface,
            borderRadius: BorderRadius.circular(AppRadii.small + 2),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: colors.shadow.withValues(alpha: 0.08),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.small + 2),
            child: const SizedBox(
              width: 96,
              height: 72,
              child: Center(child: Text('Aa')),
            ),
          ),
        ),
      ),
    );
  }

  /// The two forms a moving scene takes: zooming (a first visit) and only
  /// fading (a revisit), each over its picture.
  Widget _frames(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Opacity(
        opacity: 0.5,
        child: Transform.scale(
          scale: AppMotion.zoomFar,
          child: scenePicture(_snapshots, _sample(context)),
        ),
      ),
      Opacity(
        opacity: 0.5,
        child: Transform.scale(
          scale: AppMotion.zoomNear,
          child: scenePicture(_snapshots, _sample(context)),
        ),
      ),
      Opacity(opacity: 0.5, child: scenePicture(_snapshots, _sample(context))),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final bool warm = _warming && !MediaQuery.disableAnimationsOf(context);
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.passthrough,
      children: <Widget>[
        widget.child,
        if (warm)
          Positioned(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: _frames(context),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
