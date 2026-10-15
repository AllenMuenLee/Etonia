import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../ink/ink_controller.dart';
import '../ink/ink_sample.dart';
import '../ink/ink_selection.dart';
import '../ink/selection_config.dart';
import '../ink/selection_transform.dart';
import '../page/page_viewport.dart';
import 'palette_button.dart';

/// Copy, Cut, and AI for the current selection, floating beside its frame.
///
/// Fills its parent, which must be the page, or the viewport showing it
/// through [transform], and places the bar above the frame when there is
/// room, below it otherwise, and always inside its parent.
/// The bar's trailing end, where AI is, lines up with the frame's trailing
/// edge: its top-right corner when text runs left to right.
/// It is hidden while a lasso is drawn or the selection is transformed, and
/// rebuilds only when that or the selection changes, never per pointer move.
///
/// It must sit above the canvas as a sibling, not inside it, so that a press
/// on the bar is not also seen by the canvas.
class SelectionActionBar extends StatefulWidget {
  const SelectionActionBar({
    super.key,
    required this.controller,
    this.onAiPressed,
    this.onCopy,
    this.onCut,
    this.transform = PageTransform.identity,
    this.obstruction,
  });

  final InkController controller;

  /// What floats over the parent that the bar must stay clear of, such as
  /// the tool palette, in the parent's coordinates.
  final Rect? obstruction;

  /// Maps the page's coordinates to the parent's. The bar itself is never
  /// scaled.
  final PageTransform transform;

  /// Called when AI is pressed. The bar knows nothing else about the
  /// assistant. With no callback there is no AI button.
  final VoidCallback? onAiPressed;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;

  static String describe(int count) {
    return count == 1 ? '1 stroke selected' : '$count strokes selected';
  }

  static String describeSelection(InkSelection selection) {
    final int itemCount =
        selection.count +
        selection.imageCount +
        (selection.includesPdf ? 1 : 0);
    if (selection.includesPdf && itemCount == 1) {
      return 'PDF excerpt selected';
    }
    if (selection.includesPdf) return '$itemCount items selected';
    if (selection.imageCount == 0) return describe(selection.count);
    if (selection.count == 0) {
      return selection.imageCount == 1
          ? '1 image selected'
          : '${selection.imageCount} images selected';
    }
    return '${selection.count + selection.imageCount} items selected';
  }

  @override
  State<SelectionActionBar> createState() => _SelectionActionBarState();
}

class _SelectionActionBarState extends State<SelectionActionBar> {
  InkSelection? _selection;

  @override
  void initState() {
    super.initState();
    widget.controller.selectionListenable.addListener(_onSelectionChanged);
    _selection = _visibleSelection();
  }

  @override
  void didUpdateWidget(SelectionActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.selectionListenable.removeListener(
        _onSelectionChanged,
      );
      widget.controller.selectionListenable.addListener(_onSelectionChanged);
      _selection = _visibleSelection();
    }
  }

  @override
  void dispose() {
    widget.controller.selectionListenable.removeListener(_onSelectionChanged);
    super.dispose();
  }

  /// The selection to show actions for: none while a gesture is reshaping
  /// it.
  InkSelection? _visibleSelection() {
    final InkController controller = widget.controller;
    final bool gesturing =
        controller.activeLasso != null || controller.activeTransform != null;
    return gesturing ? null : controller.selection;
  }

  void _onSelectionChanged() {
    final InkSelection? next = _visibleSelection();
    if (!identical(next, _selection)) {
      setState(() => _selection = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final InkSelection? selection = _selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final AppColors colors = AppColors.of(context);
    return CustomSingleChildLayout(
      delegate: _BesideFrame(
        widget.transform.applyRect(
          _anchor(selection.frame, widget.controller.selectionConfig),
        ),
        trailingIn: Directionality.of(context),
        obstruction: widget.obstruction,
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        liveRegion: true,
        label: SelectionActionBar.describeSelection(selection),
        child: _FloatingBar(
          children: <Widget>[
            PaletteButton(
              tooltip: 'Copy',
              onPressed: widget.onCopy ?? widget.controller.copySelection,
              child: const Icon(Icons.content_copy),
            ),
            PaletteButton(
              tooltip: 'Cut',
              onPressed: widget.onCut ?? widget.controller.cutSelection,
              child: const Icon(Icons.content_cut),
            ),
            if (widget.onAiPressed != null)
              PaletteButton(
                tooltip: 'AI assistant',
                onPressed: widget.onAiPressed,
                child: Text(
                  'AI',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The upright box around everything drawn for [frame]: its outline, its
  /// corner handles, and its rotation handle.
  static Rect _anchor(SelectionFrame frame, SelectionConfig config) {
    final List<InkVector> points = <InkVector>[
      ...frame.corners,
      frame.rotationHandle(config.rotationHandleOffset),
    ];
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    for (final InkVector point in points) {
      left = math.min(left, point.x);
      top = math.min(top, point.y);
      right = math.max(right, point.x);
      bottom = math.max(bottom, point.y);
    }
    return Rect.fromLTRB(
      left,
      top,
      right,
      bottom,
    ).inflate(config.handleVisualRadius);
  }
}

/// Paste, offered where a pointer was held on the page.
///
/// Fills its parent, which must be the page, and shows a one-button bar just
/// above [anchor] while it is not null. Like [SelectionActionBar] it must be
/// a sibling above the canvas.
class PastePrompt extends StatelessWidget {
  const PastePrompt({
    super.key,
    required this.anchor,
    required this.onPaste,
    this.transform = PageTransform.identity,
    this.obstruction,
  });

  /// Maps the page's coordinates to the parent's.
  final PageTransform transform;

  /// What the prompt must stay clear of, as for [SelectionActionBar].
  final Rect? obstruction;

  /// Where the pointer was held, in page coordinates, or null to hide.
  final ValueListenable<Offset?> anchor;

  /// Called with the held position when Paste is pressed.
  final ValueChanged<Offset> onPaste;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Offset?>(
      valueListenable: anchor,
      builder: (BuildContext context, Offset? position, Widget? _) {
        if (position == null) {
          return const SizedBox.shrink();
        }
        return CustomSingleChildLayout(
          delegate: _BesideFrame(
            transform.apply(position) & Size.zero,
            obstruction: obstruction,
          ),
          child: _FloatingBar(
            children: <Widget>[
              PaletteButton(
                tooltip: 'Paste',
                onPressed: () => onPaste(position),
                child: const Icon(Icons.content_paste),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A small row of buttons with the palette's look, floating on the page.
class _FloatingBar extends StatelessWidget {
  const _FloatingBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    // Opaque, so a press between the buttons stops here too.
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.large),
          border: Border.all(color: colors.divider, width: AppSizes.hairline),
          boxShadow: AppShadows.floating(colors),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            child: FocusTraversalGroup(
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      ),
    );
  }
}

/// Puts the child above [anchor], or below it when it would not fit above,
/// and keeps it inside the parent. Across, it is centered on the anchor, or
/// with [trailingIn] its trailing edge meets the anchor's. When that would
/// put it under [obstruction], such as the tool palette floating over the
/// page, it moves the shortest way clear of it that stays inside.
class _BesideFrame extends SingleChildLayoutDelegate {
  const _BesideFrame(this.anchor, {this.trailingIn, this.obstruction});

  static const double _gap = AppSpacing.xs;
  static const double _margin = AppSpacing.xs;

  final Rect anchor;

  /// The text direction whose trailing edge the child is aligned to, or
  /// null to center it.
  final TextDirection? trailingIn;

  /// What the child must not sit under, in the parent's coordinates.
  final Rect? obstruction;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return constraints.loosen();
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double maxLeft = size.width - childSize.width - _margin;
    final double maxTop = size.height - childSize.height - _margin;
    final double above = anchor.top - _gap - childSize.height;
    final double below = anchor.bottom + _gap;
    final double top = above >= _margin || below > maxTop ? above : below;
    final double left = switch (trailingIn) {
      null => anchor.center.dx - childSize.width / 2,
      TextDirection.ltr => anchor.right - childSize.width,
      TextDirection.rtl => anchor.left,
    };
    // The lower bound is applied last, so it wins on a page too small for
    // both.
    final Offset placed = Offset(
      math.max(_margin, math.min(left, maxLeft)),
      math.max(_margin, math.min(top, maxTop)),
    );
    final Rect? blocked = obstruction;
    if (blocked == null || !(placed & childSize).overlaps(blocked)) {
      return placed;
    }
    final List<Offset> clear = <Offset>[
      Offset(blocked.right + _margin, placed.dy),
      Offset(blocked.left - _margin - childSize.width, placed.dy),
      Offset(placed.dx, blocked.bottom + _margin),
      Offset(placed.dx, blocked.top - _margin - childSize.height),
    ];
    Offset? best;
    for (final Offset candidate in clear) {
      final bool inside =
          candidate.dx >= _margin &&
          candidate.dx <= maxLeft &&
          candidate.dy >= _margin &&
          candidate.dy <= maxTop;
      if (inside &&
          (best == null ||
              (candidate - placed).distance < (best - placed).distance)) {
        best = candidate;
      }
    }
    return best ?? placed;
  }

  @override
  bool shouldRelayout(_BesideFrame oldDelegate) {
    return oldDelegate.anchor != anchor ||
        oldDelegate.trailingIn != trailingIn ||
        oldDelegate.obstruction != obstruction;
  }
}
