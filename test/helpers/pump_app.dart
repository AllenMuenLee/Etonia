import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/greatnote_app.dart';
import 'package:greatnote/features/editor/editor_screen.dart';

/// Logical viewport sizes every layout is tested at.
enum TestViewport {
  compact(Size(390, 844)),
  tabletPortrait(Size(800, 1280)),
  tabletLandscape(Size(1194, 834));

  const TestViewport(this.size);

  final Size size;
}

/// Resizes the test view to [size] logical pixels at a pixel ratio of 1 and
/// restores it when the test ends.
void setViewportSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

/// Pumps the app at [viewport], or at [size] when given, and lets animations
/// settle. Without a [home] it shows the editor on its own, as most tests
/// want; the library has its own tests.
Future<void> pumpApp(
  WidgetTester tester, {
  TestViewport viewport = TestViewport.tabletLandscape,
  Size? size,
  ThemeMode themeMode = ThemeMode.light,
  Widget? home,
}) async {
  setViewportSize(tester, size ?? viewport.size);
  await tester.pumpWidget(
    GreatnoteApp(themeMode: themeMode, home: home ?? const EditorScreen()),
  );
  await tester.pumpAndSettle();
}

/// WCAG 2.x contrast ratio between two opaque colors.
double contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double lighter = la > lb ? la : lb;
  final double darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}
