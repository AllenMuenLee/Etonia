import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/app/theme/app_icons.dart';
import 'package:greatnote/app/theme/app_theme.dart';
import 'package:greatnote/features/library/library_models.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:greatnote/features/library/study_desk/study_desk_controller.dart';
import 'package:greatnote/features/library/study_desk/study_desk_models.dart';
import 'package:greatnote/features/library/study_desk/study_desk_store.dart';
import 'package:greatnote/features/library/study_desk/study_desk_widgets.dart';
import 'package:greatnote/features/library/study_desk/study_history_sidebar.dart';
import 'package:greatnote/shared/widgets/etonia_icon.dart';

import '../../../helpers/ai_fakes.dart';
import '../../../helpers/document_io_fakes.dart';

void main() {
  group('FolderColor.colorHex and contrast', () {
    test('every folder color defines a valid 6-digit hex string', () {
      final hexRegex = RegExp(r'^#[0-9A-Fa-f]{6}$');
      for (final FolderColor color in FolderColor.values) {
        expect(
          hexRegex.hasMatch(color.colorHex),
          isTrue,
          reason: '${color.name} has invalid hex: ${color.colorHex}',
        );
      }
    });

    test('folder colors maintain high contrast against light surfaces', () {
      double luminance(Color c) => c.computeLuminance();
      const Color lightBackground = Color(0xFFFAF9F7);
      final double bgLum = luminance(lightBackground);

      for (final FolderColor color in FolderColor.values) {
        final Color c = studyCourseColor(color.colorHex);
        final double lum = luminance(c);
        final double contrast = (bgLum + 0.05) / (lum + 0.05);
        // Minimum contrast ratio >= 3.0:1 for graphical objects / icons
        expect(
          contrast,
          greaterThanOrEqualTo(2.8),
          reason: '${color.name} (${color.colorHex}) has low contrast: $contrast',
        );
      }
    });
  });

  group('Suggested classes and class recoloring', () {
    late InMemoryNoteRepository repository;
    late FakeAiClient client;
    late InMemoryStudyDeskStore store;
    late StudyDeskController controller;

    setUp(() async {
      repository = InMemoryNoteRepository();
      client = FakeAiClient();
      store = InMemoryStudyDeskStore();
      controller = StudyDeskController(
        repository: repository,
        client: client,
        store: store,
      );
      await controller.load();
    });

    tearDown(() {
      controller.dispose();
      client.close();
      repository.dispose();
    });

    test('initializeSuggestedClass defaults colorHex to folder.color.colorHex', () async {
      final Folder folder = await repository.createFolder(
        'Organic Chemistry',
        color: FolderColor.green,
      );
      await repository.createNote(
        title: 'Reactions',
        folderId: folder.id,
      );

      controller.initializeSuggestedClass(folder);

      expect(controller.courses.length, 1);
      final StudyCourse course = controller.courses.single;
      expect(course.name, 'Organic Chemistry');
      expect(course.colorHex, FolderColor.green.colorHex);
    });

    test('recolorCourse updates class color and persists', () async {
      final StudyCourse course = controller.addCourse(
        'Mathematics',
        colorHex: '#6750A4',
      );
      expect(controller.courses.first.colorHex, '#6750A4');

      controller.recolorCourse(course.id, '#E8590C');
      expect(controller.courses.first.colorHex, '#E8590C');

      // Whitespace or blank does not change color
      controller.recolorCourse(course.id, '  ');
      expect(controller.courses.first.colorHex, '#E8590C');
    });

    testWidgets('StudySuggestedClasses displays blackboard icon and folder color', (
      WidgetTester tester,
    ) async {
      final repo = InMemoryNoteRepository();
      final folder = await repo.createFolder(
        'History',
        color: FolderColor.orange,
      );
      await repo.createNote(
        title: 'Chapter 1',
        folderId: folder.id,
      );
      final ctrl = StudyDeskController(
        repository: repo,
        client: FakeAiClient(),
        store: InMemoryStudyDeskStore(),
      );
      addTearDown(() {
        ctrl.dispose();
        repo.dispose();
      });
      await ctrl.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: StudySuggestedClasses(controller: ctrl),
            ),
          ),
        ),
      );
      await tester.pump();

      final listTile = find.byKey(ValueKey('study-suggest-class-${folder.id}'));
      expect(listTile, findsOneWidget);

      final iconFinder = find.descendant(
        of: listTile,
        matching: find.byType(AppIcon),
      );
      final AppIcon leadingIcon = tester.widget<AppIcon>(iconFinder.first);
      expect(leadingIcon.icon, AppIcons.blackboard);
      expect(leadingIcon.color, studyCourseColor(FolderColor.orange.colorHex));
    });

    testWidgets('StudyHistorySidebar displays blackboard icon and allows changing color', (
      WidgetTester tester,
    ) async {
      final course = controller.addCourse(
        'Physics 101',
        colorHex: FolderColor.purple.colorHex,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 340,
              child: StudyHistorySidebar(
                controller: controller,
                onClose: () {},
                onAddSources: () {},
                exportSink: FakeExportSink(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify class row uses blackboard icon
      final classRowFinder = find.byKey(ValueKey('study-class-${course.id}'));
      expect(classRowFinder, findsOneWidget);

      final AppIcon blackboardIcon = tester.widget<AppIcon>(
        find.descendant(
          of: classRowFinder,
          matching: find.byIcon(AppIcons.blackboard),
        ),
      );
      expect(blackboardIcon.icon, AppIcons.blackboard);
      expect(blackboardIcon.color, studyCourseColor(FolderColor.purple.colorHex));

      // Open class actions menu
      final menuButton = find.byKey(ValueKey('study-class-menu-${course.id}'));
      expect(menuButton, findsOneWidget);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();

      // Check 'Color…' option exists
      final colorMenuItem = find.text('Color…');
      expect(colorMenuItem, findsOneWidget);

      // Tap 'Color…' to open dialog
      await tester.tap(colorMenuItem);
      await tester.pumpAndSettle();

      // Dialog should be displayed with title 'Class color'
      expect(find.text('Class color'), findsOneWidget);

      // Tap a new color swatch: Teal (#0C8599)
      final tealSwatch = find.byKey(
        ValueKey<String>('class-color-${FolderColor.teal.colorHex}'),
      );
      expect(tealSwatch, findsOneWidget);
      await tester.tap(tealSwatch);
      await tester.pumpAndSettle();

      // Class color should now be updated to teal
      expect(controller.courses.first.colorHex, FolderColor.teal.colorHex);
    });
  });
}
