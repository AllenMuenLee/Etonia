import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/shared/layout/breakpoints.dart';

void main() {
  group('WindowSizeClass.fromWidth', () {
    test('is compact below 600', () {
      expect(WindowSizeClass.fromWidth(0), WindowSizeClass.compact);
      expect(WindowSizeClass.fromWidth(390), WindowSizeClass.compact);
      expect(WindowSizeClass.fromWidth(599.9), WindowSizeClass.compact);
    });

    test('is medium from 600 up to 840', () {
      expect(WindowSizeClass.fromWidth(600), WindowSizeClass.medium);
      expect(WindowSizeClass.fromWidth(800), WindowSizeClass.medium);
      expect(WindowSizeClass.fromWidth(839.9), WindowSizeClass.medium);
    });

    test('is expanded from 840', () {
      expect(WindowSizeClass.fromWidth(840), WindowSizeClass.expanded);
      expect(WindowSizeClass.fromWidth(1194), WindowSizeClass.expanded);
    });
  });
}
