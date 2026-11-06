import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../../../shared/feedback/app_haptics.dart';
import '../../../shared/widgets/app_controls.dart';
import '../../editor/ink/eraser_settings.dart';
import '../../editor/ink/ink_controller.dart';
import '../../editor/ink/ink_palette.dart';
import '../../editor/ink/pen_settings.dart';
import '../../editor/ink/stroke.dart';
import 'study_in_situ_editor.dart';

/// What a pointer on the page does, as the toolbar shows it. The pen and the
/// highlighter are one tool to the canvas, and two here.
enum _StudyTool { pen, highlighter, eraser, lasso }

/// The few tools a page needs while studying, floating over it: pen,
/// highlighter, eraser, and lasso, each with what it needs one row below, and
/// the way back from a mistake.
class StudyInSituToolbar extends StatelessWidget {
  const StudyInSituToolbar({super.key, required this.session});

  final StudyInSituSession session;

  static const double _button = AppSizes.minTouchTarget;

  _StudyTool _current() {
    return switch (session.tool.value) {
      EditorTool.eraser => _StudyTool.eraser,
      EditorTool.select => _StudyTool.lasso,
      _ =>
        session.pen.value.isHighlighter
            ? _StudyTool.highlighter
            : _StudyTool.pen,
    };
  }

  void _choose(_StudyTool tool) {
    AppHaptics.toolSwitch();
    final InkController ink = session.ink;
    if (tool != _StudyTool.lasso) ink.clearSelection();
    switch (tool) {
      case _StudyTool.pen:
        session.tool.value = EditorTool.pen;
        final PenSettings pen = session.pen.value;
        if (pen.isHighlighter) {
          session.pen.value = pen.copyWith(style: WritingStyle.pen);
        }
      case _StudyTool.highlighter:
        session.tool.value = EditorTool.pen;
        session.pen.value = session.pen.value.copyWith(
          style: WritingStyle.highlighter,
        );
      case _StudyTool.eraser:
        session.tool.value = EditorTool.eraser;
      case _StudyTool.lasso:
        session.tool.value = EditorTool.select;
    }
  }

  @override
  Widget build(BuildContext context) {
    final InkController ink = session.ink;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        session.tool,
        session.pen,
        session.eraser,
        ink.documentRevisionListenable,
        ink.selectionListenable,
        ink.completedStrokesListenable,
      ]),
      builder: (BuildContext context, Widget? _) {
        final AppColors colors = AppColors.of(context);
        final _StudyTool tool = _current();
        final Widget? options = _options(context, tool);
        return GlassSurface(
          key: const ValueKey<String>('study-in-situ-toolbar'),
          quality: GlassQuality.tinted,
          borderRadius: AppBorderRadius.glass,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                if (options != null) ...<Widget>[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: options,
                  ),
                  Divider(
                    height: AppSpacing.xs,
                    thickness: AppSizes.hairline,
                    color: colors.divider,
                  ),
                ],
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _tool(
                        context,
                        _StudyTool.pen,
                        tool,
                        AppIcons.pen,
                        'Pen',
                        'study-tool-pen',
                      ),
                      _tool(
                        context,
                        _StudyTool.highlighter,
                        tool,
                        AppIcons.highlighter,
                        'Highlighter',
                        'study-tool-highlighter',
                      ),
                      _tool(
                        context,
                        _StudyTool.eraser,
                        tool,
                        session.eraser.value.mode == EraserMode.area
                            ? AppIcons.eraseArea
                            : AppIcons.eraseStroke,
                        'Eraser',
                        'study-tool-eraser',
                      ),
                      _tool(
                        context,
                        _StudyTool.lasso,
                        tool,
                        AppIcons.lasso,
                        'Lasso',
                        'study-tool-lasso',
                      ),
                      SizedBox(
                        height: AppSpacing.lg,
                        child: VerticalDivider(
                          width: AppSpacing.sm,
                          thickness: AppSizes.hairline,
                          color: colors.divider,
                        ),
                      ),
                      _action(
                        'Undo',
                        AppIcons.undo,
                        'study-tool-undo',
                        ink.canUndo ? ink.undo : null,
                      ),
                      _action(
                        'Redo',
                        AppIcons.redo,
                        'study-tool-redo',
                        ink.canRedo ? ink.redo : null,
                      ),
                      _action(
                        'Clear Annotations',
                        AppIcons.delete,
                        'study-tool-clear',
                        session.annotations.isEmpty
                            ? null
                            : session.clearAnnotations,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tool(
    BuildContext context,
    _StudyTool tool,
    _StudyTool current,
    IconData icon,
    String label,
    String key,
  ) {
    final AppColors colors = AppColors.of(context);
    final bool selected = tool == current;
    return Semantics(
      selected: selected,
      child: CompactIconButton(
        key: ValueKey<String>(key),
        tooltip: label,
        onPressed: () => _choose(tool),
        icon: icon,
        size: _button,
        background: selected ? colors.accent : null,
        foreground: selected ? colors.onAccent : colors.textPrimary,
      ),
    );
  }

  Widget _action(
    String label,
    IconData icon,
    String key,
    Object? Function()? onPressed,
  ) => CompactIconButton(
    key: ValueKey<String>(key),
    tooltip: label,
    onPressed: onPressed == null ? null : () => onPressed(),
    icon: icon,
    size: _button,
  );

  /// What the chosen tool needs at hand, or null when it needs nothing just now.
  Widget? _options(BuildContext context, _StudyTool tool) {
    final PenSettings pen = session.pen.value;
    switch (tool) {
      case _StudyTool.pen:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final InkColor ink in PenSettings.defaultSwatches)
              _Swatch(
                ink: ink,
                selected: pen.ink == ink,
                onPressed: () => session.pen.value = pen.copyWith(ink: ink),
              ),
            SizedBox(
              width: 150,
              child: AppSlider(
                key: const ValueKey<String>('study-tool-width'),
                value: pen.width.clamp(1, 20),
                min: 1,
                max: 20,
                onChanged: (double width) => session.pen.value = session
                    .pen
                    .value
                    .copyWith(width: width),
                semanticFormatterCallback: (double width) =>
                    'Stroke width ${width.round()}',
              ),
            ),
          ],
        );
      case _StudyTool.highlighter:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final InkColor ink in PenSettings.defaultHighlighterSwatches)
              _Swatch(
                ink: ink,
                selected: pen.highlighterInk == ink,
                onPressed: () =>
                    session.pen.value = pen.copyWith(highlighterInk: ink),
              ),
          ],
        );
      case _StudyTool.eraser:
        return SizedBox(
          width: 200,
          child: SegmentedChoice<EraserMode>(
            options: EraserMode.values,
            selected: session.eraser.value.mode,
            labelOf: (EraserMode mode) => mode.label,
            keyOf: (EraserMode mode) =>
                ValueKey<String>('study-eraser-${mode.name}'),
            onSelected: (EraserMode mode) => session.eraser.value = session
                .eraser
                .value
                .copyWith(mode: mode),
          ),
        );
      case _StudyTool.lasso:
        final InkController ink = session.ink;
        if (ink.selection == null) return null;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _action(
              'Duplicate',
              AppIcons.duplicate,
              'study-tool-duplicate',
              ink.duplicateSelection,
            ),
            _action(
              'Delete',
              AppIcons.delete,
              'study-tool-delete',
              ink.deleteSelection,
            ),
          ],
        );
    }
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.ink,
    required this.selected,
    required this.onPressed,
  });

  final InkColor ink;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color fill = ink.resolve(Theme.of(context).brightness);
    return Semantics(
      button: true,
      selected: selected,
      label: ink.label,
      excludeSemantics: true,
      child: InkResponse(
        key: ValueKey<String>('study-swatch-${ink.id}'),
        onTap: onPressed,
        radius: AppSizes.minTouchTarget / 2,
        child: SizedBox.square(
          dimension: AppSizes.minTouchTarget,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fill,
                border: Border.all(
                  color: selected ? colors.accent : colors.divider,
                  width: selected ? 2 : AppSizes.hairline,
                ),
              ),
              child: const SizedBox.square(dimension: 24),
            ),
          ),
        ),
      ),
    );
  }
}
