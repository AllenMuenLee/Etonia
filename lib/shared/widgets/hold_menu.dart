import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_tokens.dart';

/// One thing a [HoldMenu] offers.
class HoldMenuAction {
  const HoldMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

/// Opens a small menu of [actions] when the child is held, or right-clicked.
///
/// This listens to raw pointers, as [Pressable] does, so it never competes with
/// a gesture inside the child: text in it can still be selected and links
/// still tapped. A hold ends if the pointer moves, so scrolling is left alone.
/// With no [actions], or [enabled] false, the child is shown as it is.
class HoldMenu extends StatefulWidget {
  const HoldMenu({
    super.key,
    required this.child,
    required this.actions,
    this.enabled = true,
    this.holdDuration = const Duration(milliseconds: 450),
  });

  final Widget child;

  /// Asked when the menu is about to open, so it reflects the moment: an
  /// action that is not possible now is left out.
  final List<HoldMenuAction> Function() actions;
  final bool enabled;
  final Duration holdDuration;

  @override
  State<HoldMenu> createState() => _HoldMenuState();
}

class _HoldMenuState extends State<HoldMenu> {
  Timer? _timer;
  int? _pointer;
  Offset _origin = Offset.zero;

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
  }

  void _down(PointerDownEvent event) {
    if (!widget.enabled) return;
    if (event.kind == PointerDeviceKind.mouse) {
      // A mouse has the secondary button for this: no waiting.
      if (event.buttons == kSecondaryMouseButton) _open(event.position);
      return;
    }
    _cancel();
    _pointer = event.pointer;
    _origin = event.position;
    _timer = Timer(widget.holdDuration, () {
      final Offset at = _origin;
      _cancel();
      _open(at);
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _origin).distance > kTouchSlop) _cancel();
  }

  void _end(PointerEvent event) {
    if (event.pointer == _pointer) _cancel();
  }

  void _open(Offset position) {
    if (!mounted || !widget.enabled) return;
    final List<HoldMenuAction> actions = widget.actions();
    if (actions.isEmpty) return;
    HapticFeedback.selectionClick();
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final AppColors colors = AppColors.of(context);
    unawaited(
      showMenu<HoldMenuAction>(
        context: context,
        position: RelativeRect.fromRect(
          Rect.fromLTWH(position.dx, position.dy, 0, 0),
          Offset.zero & overlay.size,
        ),
        items: <PopupMenuEntry<HoldMenuAction>>[
          for (final HoldMenuAction action in actions)
            PopupMenuItem<HoldMenuAction>(
              value: action,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(action.icon, size: 18, color: colors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Text(action.label),
                ],
              ),
            ),
        ],
      ).then((HoldMenuAction? chosen) => chosen?.onSelected()),
    );
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _end,
      onPointerCancel: _end,
      child: widget.child,
    );
  }
}
