// Synthetic visual evidence only. No API calls or learner notes.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture readable synthetic visual-note fixtures', () async {
    final font = File(
      Platform.environment['STUDY_VISUAL_FONT'] ?? 'C:/Windows/Fonts/arial.ttf',
    );
    await ui.loadFontFromList(
      await font.readAsBytes(),
      fontFamily: 'VisualFixture',
    );
    final directory = Directory(
      Platform.environment['STUDY_VISUAL_CAPTURE_OUTPUT'] ??
          'build/study_desk_cost_audit/visual_fixtures',
    );
    await directory.create(recursive: true);
    final images = <ui.Image>[];
    for (final rows in [
      [
        'Electrical note',
        'V = I R',
        'V = 12 V',
        'R = 4 kOhm',
        'I = 0.003 A = 3 mA',
        'NOT 3 A',
      ],
      [
        'Logarithm equation',
        'log2(x - 1) + log2(x - 3) = 3',
        'Domain: x > 3',
        '(x - 1)(x - 3) = 8',
        '(x - 5)(x + 1) = 0',
        'x = 5 is valid; x = -1 is rejected',
        'Each logarithm argument must be positive.',
      ],
    ]) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)
        ..drawPaint(ui.Paint()..color = const ui.Color(0xffffffff));
      for (var i = 0; i < rows.length; i++) {
        final text = TextPainter(
          text: TextSpan(
            text: rows[i],
            style: const TextStyle(
              fontFamily: 'VisualFixture',
              fontSize: 32,
              color: ui.Color(0xff000000),
            ),
          ),
          textDirection: ui.TextDirection.ltr,
        )..layout(maxWidth: 1320);
        text.paint(canvas, ui.Offset(35, 35 + i * 76));
        text.dispose();
      }
      final picture = recorder.endRecording();
      images.add(await picture.toImage(1400, 640));
      picture.dispose();
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(images[0], ui.Offset.zero, ui.Paint());
    canvas.drawImage(images[1], const ui.Offset(0, 640), ui.Paint());
    final picture = recorder.endRecording();
    images.add(await picture.toImage(1400, 1280));
    picture.dispose();
    final fixtures = <Map<String, Object?>>[];
    for (var i = 0; i < images.length; i++) {
      final bytes = (await images[i].toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      final path = '${directory.path}/visual-$i.png';
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      fixtures.add({
        'id': ['units', 'domain', 'two-panels'][i],
        'imagePath': path,
        'panelCount': i == 2 ? 2 : 1,
        'systemInstruction': AiPrompts.plainStudyInstruction(
          AiPrompts.studyVisualDescriptionSystem,
          json: true,
        ),
      });
      images[i].dispose();
    }
    await File(
      '${directory.path}/requests.json',
    ).writeAsString(jsonEncode(fixtures));
  });
}
