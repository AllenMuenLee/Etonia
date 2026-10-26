import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/text/note_text.dart';
import 'package:greatnote/features/library/note_content.dart';

import '../../helpers/editor_harness.dart';

void main() {
  testWidgets('Text tool places and formats persistent text', (
    WidgetTester tester,
  ) async {
    final InkController controller = await pumpEditor(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('palette-extension-toggle')),
    );
    await tester.pumpAndSettle();

    final Rect recording = tester.getRect(
      find.byKey(const ValueKey<String>('recording-tool')),
    );
    final Rect text = tester.getRect(
      find.byKey(const ValueKey<String>('text-tool')),
    );
    final Rect ruler = tester.getRect(
      find.byKey(const ValueKey<String>('ruler-toggle')),
    );
    expect(recording.left, lessThan(text.left));
    expect(text.left, lessThan(ruler.left));

    await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('text-options-bar')),
      findsOneWidget,
    );

    final RenderBox canvas = tester.renderObject<RenderBox>(
      find.byType(InkCanvas).first,
    );
    await tester.tapAt(canvas.localToGlobal(const Offset(180, 220)));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('canvas-text-editor')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('canvas-text-editor')),
      'A typed note',
    );
    await tester.tap(find.byKey(const ValueKey<String>('text-bold')));
    await tester.pump();

    expect(controller.textElements.single.text, 'A typed note');
    expect(controller.textElements.single.settings.bold, isTrue);

    // The open box takes taps itself: nothing painted above it swallows
    // them, so the caret can be placed in the words.
    final HitTestResult hit = tester.hitTestOnBinding(
      tester.getCenter(
        find.byKey(const ValueKey<String>('canvas-text-editor')),
      ),
    );
    expect(
      hit.path.any((HitTestEntry entry) => entry.target is RenderEditable),
      isTrue,
    );

    // A tap beside the box, on its handles, starts no second box.
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey<String>('text-move-handle'))),
    );
    await tester.pump();
    expect(controller.textElements, hasLength(1));

    await tester.tap(find.byKey(const ValueKey<String>('text-delete')));
    await tester.pump();
    expect(controller.textElements, isEmpty);
  });

  testWidgets('typed text keeps its measured size under system text scaling', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final InkController controller = await pumpEditor(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('palette-extension-toggle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('text-tool')));
    await tester.pumpAndSettle();
    final RenderBox canvas = tester.renderObject<RenderBox>(
      find.byType(InkCanvas).first,
    );
    await tester.tapAt(canvas.localToGlobal(const Offset(180, 220)));
    await tester.pump();
    final Finder editor = find.byKey(
      const ValueKey<String>('canvas-text-editor'),
    );
    await tester.enterText(editor, 'A typed note');
    await tester.pump();

    // The box, its handles, thumbnails and exports all use the unscaled
    // measurement, so the live words must too.
    final Rect bounds = controller.textElements.single.bounds;
    expect(tester.getSize(editor).height, moreOrLessEquals(bounds.height));
  });

  test('typed text survives document storage and participates in undo', () {
    final InkController controller = InkController();
    final NoteDocument document = NoteDocument.single(controller);
    addTearDown(document.dispose);

    expect(
      controller.insertText(
        const InkVector(40, 60),
        const TextSettings(fontSize: 24, bold: true),
        pageBounds: const Rect.fromLTWH(0, 0, 800, 1000),
      ),
      isTrue,
    );
    controller.updateEditingText(text: 'Saved words');
    controller.finishTextEditing();

    final Map<String, Object?> json = NoteContent.fromDocument(
      document,
    ).toJson();
    final NoteDocument restored = NoteContent.fromJson(json).toDocument();
    addTearDown(restored.dispose);
    final NoteTextElement text = restored.current.ink.textElements.single;
    expect(text.text, 'Saved words');
    expect(text.position, const InkVector(40, 60));
    expect(text.settings.fontSize, 24);
    expect(text.settings.bold, isTrue);

    expect(controller.undo(), isTrue);
    expect(controller.textElements, isEmpty);
  });

  test('an abandoned empty text box leaves no step in the history', () {
    final InkController controller = InkController();
    final NoteDocument document = NoteDocument.single(controller);
    addTearDown(document.dispose);
    const Rect page = Rect.fromLTWH(0, 0, 800, 1000);

    controller.insertText(
      const InkVector(40, 60),
      const TextSettings(),
      pageBounds: page,
    );
    controller.finishTextEditing();
    expect(controller.textElements, isEmpty);
    expect(document.history.canUndo, isFalse);

    // Typed into, then emptied again: still nothing to undo.
    controller.insertText(
      const InkVector(40, 60),
      const TextSettings(),
      pageBounds: page,
    );
    controller.updateEditingText(text: 'x');
    controller.updateEditingText(text: '');
    controller.finishTextEditing();
    expect(controller.textElements, isEmpty);
    expect(document.history.canUndo, isFalse);
  });

  test('the open text box moves, resizes and deletes as single changes', () {
    final InkController controller = InkController();
    final NoteDocument document = NoteDocument.single(controller);
    addTearDown(document.dispose);
    const Rect page = Rect.fromLTWH(0, 0, 800, 1000);

    controller.insertText(
      const InkVector(40, 60),
      const TextSettings(),
      pageBounds: page,
    );
    controller.updateEditingText(text: 'Moving words');
    controller.finishTextEditing();
    final String id = controller.textElements.single.id;

    controller.editText(id);
    for (final double x in <double>[60, 90, 120]) {
      controller.setEditingTextFrame(
        position: InkVector(x, 100),
        pageBounds: page,
        commit: false,
      );
    }
    controller.setEditingTextFrame(
      position: const InkVector(120, 100),
      width: 400,
      pageBounds: page,
    );
    expect(controller.textElements.single.position, const InkVector(120, 100));
    expect(controller.textElements.single.width, 400);

    // Clamped into the page.
    controller.setEditingTextFrame(
      position: const InkVector(790, -50),
      pageBounds: page,
    );
    expect(controller.textElements.single.position, const InkVector(400, 0));

    expect(controller.deleteEditingText(), isTrue);
    expect(controller.textElements, isEmpty);
    // The delete and each drag come back one undo at a time.
    expect(controller.undo(), isTrue);
    expect(controller.textElements.single.position, const InkVector(400, 0));
    expect(controller.undo(), isTrue);
    expect(controller.textElements.single.position, const InkVector(120, 100));
    expect(controller.textElements.single.width, 400);
    expect(controller.undo(), isTrue);
    expect(controller.textElements.single.position, const InkVector(40, 60));
    expect(controller.textElements.single.width, 280);
  });

  test('wrapped text is hit across its full measured height', () {
    final NoteTextElement element = NoteTextElement(
      id: 't',
      position: const InkVector(0, 0),
      text: List<String>.filled(40, 'word').join(' '),
      width: 120,
    );
    // One line of 20px text at height 1.3 is 26 tall; this wraps to many.
    expect(element.bounds.height, greaterThan(26 * 4));
  });

  group('list formatting', () {
    TextEditingValue at(String text, int caret) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );

    test('plain text keeps a line that starts like a list', () {
      final TextEditingValue value = at('1. first', 8);
      expect(
        formatListValue(
          value,
          from: TextListStyle.none,
          to: TextListStyle.none,
        ),
        value,
      );
    });

    test('a new line is marked and the caret stays in the words', () {
      final TextEditingValue next = formatListValue(
        at('• one\n', 6),
        from: TextListStyle.bullets,
        to: TextListStyle.bullets,
      );
      expect(next.text, '• one\n• ');
      expect(next.selection.extentOffset, next.text.length);

      // Typing in the middle of the first line keeps the caret there.
      final TextEditingValue middle = formatListValue(
        at('• oXne\n• two', 4),
        from: TextListStyle.bullets,
        to: TextListStyle.bullets,
      );
      expect(middle.text, '• oXne\n• two');
      expect(middle.selection.extentOffset, 4);
    });

    test('numbers follow the lines and bullets keep content numbers', () {
      expect(
        formattedText(
          '1. a\n2. b\n3. c',
          from: TextListStyle.numbers,
          to: TextListStyle.bullets,
        ),
        '• a\n• b\n• c',
      );
      expect(
        formattedText(
          '• 3. apples',
          from: TextListStyle.bullets,
          to: TextListStyle.bullets,
        ),
        '• 3. apples',
      );
      expect(
        formattedText(
          '1. a\n3. c',
          from: TextListStyle.numbers,
          to: TextListStyle.numbers,
        ),
        '1. a\n2. c',
      );
    });

    test('backspace into a marker joins the line onto the one above', () {
      // "• one\n• two" with the space after the second bullet deleted.
      final TextEditingValue next = formatListValue(
        at('• one\n•two', 7),
        from: TextListStyle.bullets,
        to: TextListStyle.bullets,
        deleted: true,
      );
      expect(next.text, '• onetwo');
      expect(next.selection.extentOffset, 5);
    });
  });
}
