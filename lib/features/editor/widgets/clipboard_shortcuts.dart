import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Runs Copy, Cut, and Paste for `Ctrl` or `Meta` with C, X, and V, and
/// Undo and Redo for Z, Shift+Z, and Y, while keyboard focus is on [child]
/// or inside it.
///
/// A focused text field keeps those keys for its own text: the event is
/// left unhandled, so it carries on to the text-editing shortcuts.
class ClipboardShortcuts extends StatefulWidget {
  const ClipboardShortcuts({
    super.key,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.child,
    this.onUndo,
    this.onRedo,
    this.focusNode,
  });

  final VoidCallback onCopy;
  final VoidCallback onCut;
  final VoidCallback onPaste;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final Widget child;

  /// The editor's own focus, for a caller that needs to hand focus back to
  /// it. One is made when none is given.
  final FocusNode? focusNode;

  @override
  State<ClipboardShortcuts> createState() => _ClipboardShortcutsState();
}

class _ClipboardShortcutsState extends State<ClipboardShortcuts> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode {
    return widget.focusNode ??
        (_ownedFocusNode ??= FocusNode(debugLabel: 'Editor'));
  }

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _isEditingText()) {
      return KeyEventResult.ignored;
    }
    final VoidCallback? action = _actionFor(event);
    if (action == null) {
      return KeyEventResult.ignored;
    }
    action();
    return KeyEventResult.handled;
  }

  VoidCallback? _actionFor(KeyEvent event) {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    bool pressed(LogicalKeyboardKey key) {
      // Each accepts its one modifier and no other.
      return SingleActivator(key, control: true).accepts(event, keyboard) ||
          SingleActivator(key, meta: true).accepts(event, keyboard);
    }

    if (pressed(LogicalKeyboardKey.keyC)) {
      return widget.onCopy;
    }
    if (pressed(LogicalKeyboardKey.keyX)) {
      return widget.onCut;
    }
    if (pressed(LogicalKeyboardKey.keyV)) {
      return widget.onPaste;
    }
    if (pressed(LogicalKeyboardKey.keyZ)) {
      return widget.onUndo;
    }
    if (pressed(LogicalKeyboardKey.keyY) ||
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ).accepts(event, keyboard) ||
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          meta: true,
          shift: true,
        ).accepts(event, keyboard)) {
      return widget.onRedo;
    }
    return null;
  }

  bool _isEditingText() {
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        // Touching the editor brings the keyboard back to it.
        onPointerDown: (PointerDownEvent event) {
          if (!_focusNode.hasFocus) {
            _focusNode.requestFocus();
          }
        },
        child: widget.child,
      ),
    );
  }
}
