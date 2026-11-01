import 'package:flutter/material.dart';

import '../../app/theme/app_tokens.dart';
import '../motion/motion_memory.dart';
import 'app_dialogs.dart';

/// Selects the closest sheet detent after projecting signed release velocity.
/// Positive velocity moves toward the larger detent.
double projectSheetDetent({
  required double extent,
  required double velocity,
  List<double> detents = const <double>[0.5, 1],
}) {
  assert(detents.isNotEmpty);
  final double projected = extent + velocity * 0.18;
  return detents.reduce(
    (double a, double b) =>
        (a - projected).abs() <= (b - projected).abs() ? a : b,
  );
}

/// Adaptive Etonia sheet: two draggable phone detents and a centered iPad
/// form sheet. Flutter owns drag/scroll gesture hand-off and interruption.
///
/// [motionKey] names the sheet for [MotionMemory]: shown for the first time
/// it rises slowly and smoothly, shown again quickly.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Object? motionKey,
}) {
  final Size size = MediaQuery.sizeOf(context);
  final AppColors colors = AppColors.of(context);
  if (size.width >= 600) {
    return showAppDialog<T>(
      context: context,
      motionKey: motionKey == null ? null : ('sheet', motionKey),
      barrierColor: colors.shadow.withValues(alpha: 0.35),
      builder: (BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 540,
            maxHeight: size.height * 0.82,
          ),
          child: GlassSurface(
            quality: GlassQuality.full,
            borderRadius: AppBorderRadius.xl,
            child: builder(context),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    barrierColor: colors.shadow.withValues(alpha: 0.35),
    sheetAnimationStyle: AppMotion.pacedSheetStyle(
      motionKey == null
          ? MotionPace.standard
          : MotionMemory.instance.recall(('sheet', motionKey)),
    ),
    builder: (BuildContext context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.5,
      maxChildSize: 1,
      snap: true,
      snapSizes: const <double>[0.5, 1],
      builder: (BuildContext context, ScrollController controller) =>
          PrimaryScrollController(
            controller: controller,
            child: builder(context),
          ),
    ),
  );
}
