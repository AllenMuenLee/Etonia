import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';

/// The image tool's options: choose from gallery or take a photo.
class ImageOptions extends StatelessWidget {
  const ImageOptions({super.key, this.onChooseFromGallery, this.onTakePhoto});

  final VoidCallback? onChooseFromGallery;
  final VoidCallback? onTakePhoto;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ImageOptionRow(
          icon: AppIcons.insertImage,
          label: 'Choose from gallery',
          onPressed: onChooseFromGallery,
        ),
        const SizedBox(height: AppSpacing.xxs),
        _ImageOptionRow(
          icon: AppIcons.camera,
          label: 'Take photo',
          onPressed: onTakePhoto,
        ),
      ],
    );
  }
}

class _ImageOptionRow extends StatelessWidget {
  const _ImageOptionRow({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final bool enabled = onPressed != null;
    const BorderRadius radius = AppBorderRadius.medium;

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: radius,
        hoverColor: colors.textPrimary.withValues(alpha: 0.06),
        focusColor: colors.textPrimary.withValues(alpha: 0.10),
        highlightColor: colors.textPrimary.withValues(alpha: 0.12),
        child: SizedBox(
          height: AppSizes.minTouchTarget,
          child: Opacity(
            opacity: enabled ? 1 : 0.38,
            child: ExcludeSemantics(
              child: Row(
                children: <Widget>[
                  const SizedBox(width: AppSpacing.xs),
                  Icon(icon, size: 20, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
