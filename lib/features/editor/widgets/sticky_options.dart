import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/widgets/app_controls.dart';
import '../sticky/sticky_note.dart';
import '../sticky/sticky_note_painter.dart';
import 'color_palette_dialog.dart';

/// The Sticky note tool's options: the paper color and the paper style,
/// each marked by a check and its name, never by color or pattern alone.
/// They set the look of the next note, and of the note open for writing.
class StickyOptions extends StatelessWidget {
  const StickyOptions({
    super.key,
    required this.settings,
    required this.onChanged,
    this.targetLabel,
  });

  final StickyNoteSettings settings;
  final ValueChanged<StickyNoteSettings> onChanged;

  /// The note these options also restyle, as announced, if any.
  final String? targetLabel;

  /// "Yellow, Lined", as screen readers announce the tool.
  static String describe(StickyNoteSettings settings) {
    return '${settings.color.label}, ${settings.paper.label}';
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool hasCustomSelected = !StickyPalette.colors.any(
      (StickyPaperColor c) => c.id == settings.color.id,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionLabel('Paper color'),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          runSpacing: AppSpacing.xxs,
          children: <Widget>[
            for (final StickyPaperColor color in StickyPalette.colors)
              _PaperSwatch(
                key: ValueKey<String>('sticky-color-${color.id}'),
                color: color,
                selected: color.id == settings.color.id,
                onTap: () => onChanged(settings.copyWith(color: color)),
              ),
            if (hasCustomSelected)
              _PaperSwatch(
                key: ValueKey<String>('sticky-color-${settings.color.id}'),
                color: settings.color,
                selected: true,
                onTap: () =>
                    onChanged(settings.copyWith(color: settings.color)),
              ),
            ColorPaletteButton(
              onTap: () async {
                final Color? picked = await showColorPaletteDialog(
                  context,
                  initialColor: settings.color.paper,
                  title: 'Paper color',
                );
                if (picked != null) {
                  onChanged(
                    settings.copyWith(color: StickyPalette.custom(picked)),
                  );
                }
              },
              tooltip: 'Paper color palette',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const SectionLabel('Paper'),
        Row(
          children: <Widget>[
            for (final StickyPaperStyle paper in StickyPaperStyle.values)
              Expanded(
                child: _PaperStyleTile(
                  key: ValueKey<String>('sticky-paper-${paper.name}'),
                  paper: paper,
                  color: settings.color,
                  selected: paper == settings.paper,
                  onTap: () => onChanged(settings.copyWith(paper: paper)),
                ),
              ),
          ],
        ),
        if (targetLabel != null) ...<Widget>[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Also changes the $targetLabel being written on.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }
}

class _PaperSwatch extends StatelessWidget {
  const _PaperSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final StickyPaperColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Tooltip(
      message: color.label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: selected,
        label: color.label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox.square(
            dimension: AppSizes.minTouchTarget,
            child: Center(
              child: Container(
                width: AppSizes.colorSwatch + AppSpacing.xs + 2,
                height: AppSizes.colorSwatch + AppSpacing.xs + 2,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? colors.accent
                        : colors.accent.withValues(alpha: 0),
                    width: AppSizes.focusRingWidth,
                  ),
                ),
                child: Container(
                  width: AppSizes.colorSwatch,
                  height: AppSizes.colorSwatch,
                  decoration: BoxDecoration(
                    color: color.paper,
                    shape: BoxShape.circle,
                    border: Border.all(color: color.edge),
                  ),
                  child: selected
                      ? const ExcludeSemantics(
                          child: AppIcon(
                            AppIcons.check,
                            size: 16,
                            color: Color(0xFF1F2937),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PaperStyleTile extends StatelessWidget {
  const _PaperStyleTile({
    super.key,
    required this.paper,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final StickyPaperStyle paper;
  final StickyPaperColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: paper.label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppBorderRadius.medium,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.small),
                  border: Border.all(
                    color: selected ? colors.accent : colors.divider,
                    width: selected
                        ? AppSizes.focusRingWidth
                        : AppSizes.hairline,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.small),
                  child: CustomPaint(
                    painter: StickyPaperPreviewPainter(
                      paper: paper,
                      color: color,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxs),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (selected)
                    AppIcon(
                      AppIcons.check,
                      size: 12,
                      color: colors.textPrimary,
                    ),
                  Flexible(
                    child: Text(
                      paper.label,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(
                        color: selected
                            ? colors.textPrimary
                            : colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A swatch of paper in [color] printed with [paper], at a small spacing.
class StickyPaperPreviewPainter extends CustomPainter {
  const StickyPaperPreviewPainter({required this.paper, required this.color});

  static const StickyNoteConfig _preview = StickyNoteConfig(
    patternSpacing: 8,
    contentPadding: 4,
    dotRadius: 1,
  );

  final StickyPaperStyle paper;
  final StickyPaperColor color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color.paper);
    final StickyPattern pattern = StickyPattern.of(paper, size, _preview);
    final Paint ink = Paint()
      ..color = color.pattern
      ..strokeWidth = 1
      ..isAntiAlias = true;
    for (final (a, b) in pattern.lines) {
      canvas.drawLine(Offset(a.x, a.y), Offset(b.x, b.y), ink);
    }
    for (final dot in pattern.dots) {
      canvas.drawCircle(Offset(dot.x, dot.y), _preview.dotRadius, ink);
    }
  }

  @override
  bool shouldRepaint(StickyPaperPreviewPainter oldDelegate) {
    return oldDelegate.paper != paper || oldDelegate.color != color;
  }
}
