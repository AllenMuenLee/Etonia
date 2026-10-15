import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_client.dart';
import 'package:greatnote/features/editor/ai/selection_image_renderer.dart';
import 'package:greatnote/features/editor/editor_screen.dart';
import 'package:greatnote/features/editor/ink/ink_canvas.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';

import 'pump_app.dart';

/// Pumps the editor with an [InkController] the test can inspect, holding
/// [strokes] to begin with. Without an [aiClient] the assistant has no key
/// and can send nothing.
Future<InkController> pumpEditor(
  WidgetTester tester, {
  TestViewport viewport = TestViewport.tabletLandscape,
  ThemeMode themeMode = ThemeMode.light,
  Iterable<Stroke> strokes = const <Stroke>[],
  AiClient? aiClient,
  SelectionImageRenderer selectionImageRenderer =
      const SelectionImageRenderer(),
  // Notation sends capture the whole note, which only some tests pump for.
  bool initialNotationEnabled = false,
}) async {
  final InkController controller = InkController(strokes: strokes);
  addTearDown(controller.dispose);
  await pumpApp(
    tester,
    viewport: viewport,
    themeMode: themeMode,
    home: EditorScreen(
      inkController: controller,
      aiClient: aiClient,
      selectionImageRenderer: selectionImageRenderer,
      initialNotationEnabled: initialNotationEnabled,
    ),
  );
  return controller;
}

/// The canvas bounds in global logical pixels.
Rect canvasRect(WidgetTester tester) => tester.getRect(find.byType(InkCanvas));

/// A snapshot of the whole screen. At the test pixel ratio of 1, pixel
/// coordinates equal global logical coordinates.
Future<ScreenPixels> captureScreen(WidgetTester tester) async {
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find
            .ancestor(
              of: find.byType(Scaffold),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
  final ScreenPixels? pixels = await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage();
    final ByteData? bytes = await image.toByteData();
    final int width = image.width;
    image.dispose();
    return ScreenPixels(bytes!, width);
  });
  return pixels!;
}

class ScreenPixels {
  const ScreenPixels(this._rgba, this._width);

  final ByteData _rgba;
  final int _width;

  Color at(Offset position) {
    final int offset = (position.dy.floor() * _width + position.dx.floor()) * 4;
    return Color.fromARGB(
      _rgba.getUint8(offset + 3),
      _rgba.getUint8(offset),
      _rgba.getUint8(offset + 1),
      _rgba.getUint8(offset + 2),
    );
  }
}
