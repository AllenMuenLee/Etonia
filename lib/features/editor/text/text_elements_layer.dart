import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/app_tokens.dart';
import '../ink/eraser_settings.dart';
import '../ink/ink_controller.dart';
import 'note_text.dart';

/// Paints saved typed text and turns the active element into a multiline
/// editor without repainting the ink layers beneath it.
///
/// The open box's move grip and width tab are drawn here but dragged by
/// the canvas, which owns the page's pointers; see [TextFrame].
class TextElementsLayer extends StatelessWidget {
  const TextElementsLayer({
    super.key,
    required this.controller,
    required this.tool,
  });

  final InkController controller;
  final ValueListenable<EditorTool> tool;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[
      controller.textEditingListenable,
      tool,
    ]),
    builder: (BuildContext context, Widget? _) {
      final Brightness brightness = Theme.of(context).brightness;
      final NoteTextElement? editing = tool.value == EditorTool.text
          ? controller.editingText
          : null;
      // Typed text is page content, measured (NoteTextElement.bounds),
      // thumbnailed and exported at its own size: the system text scale
      // would draw it past its box and its handles, and differently on
      // every device.
      return MediaQuery.withNoTextScaling(
        child: Stack(
          key: const ValueKey<String>('typed-text-layer'),
          fit: StackFit.expand,
          children: <Widget>[
            if (editing != null) ..._frame(context, editing),
            for (final NoteTextElement element in controller.textElements)
              Positioned(
                key: ValueKey<String>('text-element-${element.id}'),
                left: element.position.x,
                top: element.position.y,
                width: element.width,
                child: editing?.id == element.id
                    ? _TextEditor(
                        element: element,
                        brightness: brightness,
                        onChanged: (String value) =>
                            controller.updateEditingText(text: value),
                        onDone: controller.finishTextEditing,
                      )
                    : IgnorePointer(
                        child: Text(
                          element.text,
                          textAlign: element.settings.alignment,
                          style: element.settings.resolve(brightness),
                        ),
                      ),
              ),
          ],
        ),
      );
    },
  );

  List<Widget> _frame(BuildContext context, NoteTextElement element) {
    final AppColors colors = AppColors.of(context);
    final Rect bounds = element.bounds;
    final Rect toolbar = TextFrame.toolbar(bounds);
    final Rect move = TextFrame.moveHandle(bounds);
    final Rect delete = TextFrame.deleteHandle(bounds);
    return <Widget>[
      // A quiet sheet with a hairline edge: enough to show where the words
      // go, without boxing them in.
      Positioned.fromRect(
        rect: TextFrame.frame(bounds),
        child: IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey<String>('text-frame'),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.035),
              borderRadius: BorderRadius.circular(AppRadii.small),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.4),
                width: AppSizes.hairline,
              ),
            ),
          ),
        ),
      ),
      // One small capsule above the corner: the grip, a rule, delete.
      Positioned.fromRect(
        rect: toolbar,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(toolbar.height / 2),
              border: Border.all(
                color: colors.divider,
                width: AppSizes.hairline,
              ),
              boxShadow: AppShadows.raised(colors),
            ),
            child: Center(
              child: Container(
                width: AppSizes.hairline,
                height: toolbar.height / 2,
                color: colors.divider,
              ),
            ),
          ),
        ),
      ),
      Positioned.fromRect(
        rect: move,
        child: IgnorePointer(
          child: Center(
            child: CustomPaint(
              key: const ValueKey<String>('text-move-handle'),
              size: const Size(10, 14),
              painter: _GripPainter(colors.textSecondary),
            ),
          ),
        ),
      ),
      Positioned.fromRect(
        rect: delete,
        child: Semantics(
          button: true,
          label: 'Delete text box',
          child: GestureDetector(
            key: const ValueKey<String>('text-delete'),
            behavior: HitTestBehavior.opaque,
            onTap: controller.deleteEditingText,
            child: Center(
              child: Icon(AppIcons.delete, size: 16, color: colors.danger),
            ),
          ),
        ),
      ),
      Positioned.fromRect(
        rect: TextFrame.resizeHandle(bounds),
        child: IgnorePointer(
          child: Center(
            child: Container(
              key: const ValueKey<String>('text-resize-handle'),
              width: 6,
              height: 22,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                  color: colors.accent.withValues(alpha: 0.7),
                  width: 1.5,
                ),
                boxShadow: AppShadows.raised(colors),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

/// Two columns of three dots: the grip a box is dragged by.
class _GripPainter extends CustomPainter {
  const _GripPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    const double radius = 1.4;
    for (int column = 0; column < 2; column++) {
      for (int row = 0; row < 3; row++) {
        canvas.drawCircle(
          Offset(
            radius + column * (size.width - 2 * radius),
            radius + row * (size.height - 2 * radius) / 2,
          ),
          radius,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GripPainter oldDelegate) => oldDelegate.color != color;
}

class _TextEditor extends StatefulWidget {
  const _TextEditor({
    required this.element,
    required this.brightness,
    required this.onChanged,
    required this.onDone,
  });

  final NoteTextElement element;
  final Brightness brightness;
  final ValueChanged<String> onChanged;
  final VoidCallback onDone;

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final TextEditingController _text = TextEditingController(
    text: widget.element.text,
  );
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    });
  }

  @override
  void didUpdateWidget(_TextEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String text = widget.element.text;
    if (text == _text.text) return;
    // Restyled from the toolbar, a list keeps the caret in its words;
    // anything else (an undo, say) puts it at the end.
    final TextEditingValue relisted = formatListValue(
      _text.value,
      from: oldWidget.element.settings.listStyle,
      to: widget.element.settings.listStyle,
    );
    _text.value = relisted.text == text
        ? relisted.copyWith(composing: TextRange.empty)
        : TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onDone,
      },
      child: TextField(
        key: const ValueKey<String>('canvas-text-editor'),
        controller: _text,
        focusNode: _focus,
        autofocus: true,
        keyboardType: TextInputType.multiline,
        maxLines: null,
        minLines: 1,
        textAlign: widget.element.settings.alignment,
        style: widget.element.settings.resolve(widget.brightness),
        // A slim accent caret, rounded at its ends, is the only prompt an
        // empty box needs.
        cursorWidth: 2,
        cursorRadius: const Radius.circular(1),
        cursorColor: colors.accent,
        inputFormatters: <TextInputFormatter>[
          _ListFormatter(widget.element.settings.listStyle),
        ],
        // No padding, no placeholder, and none of the theme's field
        // outlines: the words stay exactly where the saved text draws them,
        // and the frame around them is the only edge.
        decoration: const InputDecoration.collapsed(hintText: null).copyWith(
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// Keeps every line of a list box marked as it is typed.
class _ListFormatter extends TextInputFormatter {
  const _ListFormatter(this.style);

  final TextListStyle style;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => formatListValue(
    newValue,
    from: style,
    to: style,
    deleted: newValue.text.length < oldValue.text.length,
  );
}
