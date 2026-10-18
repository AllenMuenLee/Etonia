import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../app/theme/app_icons.dart';
import '../../../shared/widgets/app_controls.dart';
import '../ink/ink_painter.dart';
import '../ink/ink_sample.dart';
import '../ink/pen_settings.dart';
import '../ink/stroke.dart';

/// Opens the pen's advanced settings in a panel that slides in from the
/// left edge of the screen. Every change goes straight to [settings], so
/// the pen, and the preview at the top of the panel, follow each slider as
/// it moves. A tap outside, Escape, or the close button dismisses it.
Future<void> showPenAdvancedPanel(
  BuildContext context, {
  required ValueNotifier<PenSettings> settings,
  PenConfig config = const PenConfig(),
}) {
  final Duration duration = AppMotion.resolve(
    context,
    const Duration(milliseconds: 260),
  );
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close pen settings',
    barrierColor: AppColors.of(context).shadow.withValues(alpha: 0.16),
    transitionDuration: duration,
    pageBuilder: (BuildContext context, _, _) {
      return ValueListenableBuilder<PenSettings>(
        valueListenable: settings,
        builder: (BuildContext context, PenSettings current, Widget? _) {
          return PenAdvancedPanel(
            settings: current,
            config: config,
            onChanged: (PenSettings next) => settings.value = next,
          );
        },
      );
    },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> _,
          Widget child,
        ) {
          final Animation<double> curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(-0.12, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
  );
}

/// The pen's advanced settings: a live preview, the stroke's tip,
/// pressure, and stabilization, each off at 0%, and how the pen behaves.
class PenAdvancedPanel extends StatelessWidget {
  const PenAdvancedPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    this.config = const PenConfig(),
  });

  static const double width = 360;

  final PenSettings settings;
  final ValueChanged<PenSettings> onChanged;
  final PenConfig config;

  /// A setting as a percentage, or "Off" at 0.
  static String describe(double value) {
    final int percent = (value * 100).round();
    return percent == 0 ? 'Off' : '$percent%';
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final PenSettings defaults = PenSettings(
      ink: settings.ink,
      width: settings.width,
    );
    return SafeArea(
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: width),
            child: GlassSurface(
              borderRadius: BorderRadius.circular(AppRadii.xl),
              boxShadow: AppShadows.floating(colors),
              child: Material(
                key: const ValueKey<String>('pen-advanced'),
                type: MaterialType.transparency,
                child: Semantics(
                  scopesRoute: true,
                  namesRoute: true,
                  explicitChildNodes: true,
                  label: 'Pen settings',
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _Header(onClose: () => Navigator.of(context).maybePop()),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            0,
                            AppSpacing.lg,
                            AppSpacing.lg,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _Preview(settings: settings),
                              const SizedBox(height: AppSpacing.lg),
                              const SectionLabel('Stroke'),
                              _PercentSetting(
                                key: const ValueKey<String>(
                                  'pen-tip-sharpness',
                                ),
                                label: 'Tip sharpness',
                                hint: 'How finely each end tapers',
                                value: settings.tipSharpness,
                                onChanged: (double value) => onChanged(
                                  settings.copyWith(tipSharpness: value),
                                ),
                              ),
                              _PercentSetting(
                                key: const ValueKey<String>('pen-pressure'),
                                label: 'Pressure sensitivity',
                                hint: 'How much a firmer press widens the line',
                                value: settings.pressureSensitivity,
                                onChanged: (double value) => onChanged(
                                  settings.copyWith(pressureSensitivity: value),
                                ),
                              ),
                              _PercentSetting(
                                key: const ValueKey<String>(
                                  'pen-stabilization',
                                ),
                                label: 'Stroke stabilization',
                                hint: 'How much shaky lines are smoothed',
                                value: settings.stabilization,
                                onChanged: (double value) => onChanged(
                                  settings.copyWith(stabilization: value),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              const SectionLabel('Behavior'),
                              ToggleSetting(
                                key: const ValueKey<String>(
                                  'pen-hold-to-shape',
                                ),
                                label: 'Draw and hold for shapes',
                                hint: 'Hold the pen still to snap a shape',
                                value: settings.holdToShape,
                                onChanged: (bool value) => onChanged(
                                  settings.copyWith(holdToShape: value),
                                ),
                              ),
                              ToggleSetting(
                                key: const ValueKey<String>(
                                  'pen-scribble-to-erase',
                                ),
                                label: 'Scribble to erase',
                                hint: 'Scribble over ink to erase it',
                                value: settings.scribbleToErase,
                                onChanged: (bool value) => onChanged(
                                  settings.copyWith(scribbleToErase: value),
                                ),
                              ),
                              ToggleSetting(
                                key: const ValueKey<String>(
                                  'pen-follow-stroke',
                                ),
                                label: 'Follow nearby strokes',
                                hint: 'Ease onto ink you draw alongside',
                                value: settings.followStroke,
                                onChanged: (bool value) => onChanged(
                                  settings.copyWith(followStroke: value),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: TextButton(
                                  key: const ValueKey<String>('pen-reset'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.textSecondary,
                                    shape: const StadiumBorder(),
                                    textStyle: text.labelLarge,
                                  ),
                                  onPressed: settings == defaults
                                      ? null
                                      : () => onChanged(defaults),
                                  child: const Text('Reset to defaults'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text('Pen settings', style: text.titleLarge),
            ),
          ),
          CompactIconButton(
            key: const ValueKey<String>('pen-advanced-close'),
            tooltip: 'Close',
            onPressed: onClose,
            icon: AppIcons.close,
          ),
        ],
      ),
    );
  }
}

/// A wave drawn the way the pen would draw it now, pressing lighter and
/// harder along the way, so tip and pressure can be seen as they change.
class _Preview extends StatelessWidget {
  const _Preview({required this.settings});

  final PenSettings settings;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey<String>('pen-advanced-preview'),
        height: 112,
        decoration: BoxDecoration(
          color: colors.writingSurface,
          borderRadius: BorderRadius.circular(AppRadii.large),
          border: Border.all(color: colors.divider, width: AppSizes.hairline),
        ),
        child: CustomPaint(
          painter: _PreviewPainter(
            settings: settings,
            color: settings.ink.resolve(Theme.of(context).brightness),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter({required this.settings, required this.color});

  final PenSettings settings;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double inset = AppSpacing.lg + settings.width;
    final double span = size.width - 2 * inset;
    if (span <= 0) {
      return;
    }
    const int steps = 64;
    RawInkSample sample(int i) {
      final double t = i / steps;
      return RawInkSample(
        position: InkVector(
          inset + span * t,
          size.height / 2 + math.sin(t * 2 * math.pi) * size.height * 0.2,
        ),
        timestamp: Duration(milliseconds: 8 * i),
        // Light at the ends, firm in the middle.
        pressure: 0.15 + 0.85 * math.sin(t * math.pi),
      );
    }

    final ActiveStroke active = ActiveStroke(
      style: StrokeStyle(ink: settings.ink, width: settings.width),
      first: sample(0),
      dynamics: settings.dynamics,
    );
    for (int i = 1; i <= steps; i++) {
      active.add(sample(i));
    }
    final Stroke stroke = active.finish();
    paintInkStroke(
      canvas,
      color: color,
      width: settings.width,
      path: stroke.path,
      origin: stroke.points.first,
      isDot: stroke.isDot,
      outline: stroke.outline,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter oldDelegate) {
    return oldDelegate.settings != settings || oldDelegate.color != color;
  }
}

/// A labelled setting from 0% (off) to 100%, on a slim custom slider.
class _PercentSetting extends StatelessWidget {
  const _PercentSetting({
    super.key,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final bool off = (value * 100).round() == 0;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: SettingText(label: label, hint: hint),
              ),
              const SizedBox(width: AppSpacing.sm),
              ValuePill(PenAdvancedPanel.describe(value), muted: off),
            ],
          ),
          Semantics(
            label: label,
            child: AppSlider(
              value: value,
              divisions: 20,
              semanticFormatterCallback: PenAdvancedPanel.describe,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
