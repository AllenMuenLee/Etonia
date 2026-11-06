import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import '../../../editor/ai/ai_notation.dart';
import '../../../editor/ai/notation_layout.dart';
import '../../../editor/ai/svg_ink_converter.dart';
import '../../../editor/ai/svg_notation_styler.dart';
import '../../../editor/handwriting/handwriting_style.dart';
import '../../../editor/ink/ink_controller.dart';
import '../../../editor/ink/ink_notation.dart';
import '../../../editor/ink/ink_palette.dart';
import '../../note_content.dart';

Size testAnswerSize(Uint8List png) {
  if (png.length >= 24 && png[0] == 137 && png[1] == 80) {
    final data = ByteData.sublistView(png);
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    if (width > 0 && height > 0 && width <= 10000 && height <= 10000) {
      return Size(width.toDouble(), height.toDouble());
    }
  }
  return const Size(760, 360);
}

Uint8List? testMarkingInk(AiNotation? notation, Size size) {
  if (notation == null) return null;
  final vector = notation.vector;
  if (vector != null &&
      (vector.viewBox.topLeft != Offset.zero || vector.viewBox.size != size)) {
    throw const FormatException(
      'Test markings use the wrong page coordinates.',
    );
  }
  final traces = vector != null
      ? SvgInkConverter.convert(
          SvgNotationStyler.apply(
            vector,
            handwriting: HandwritingStyle.standard,
            defaultInk: InkPalette.red,
            penWidth: 2,
          ),
          defaultInk: InkPalette.red,
          defaultWidth: 2,
          animate: false,
          sketch: false,
        ).traces
      : layoutNotation(notation, size);
  final ink = InkController();
  try {
    if (ink.addAiNotation(
          traces: traces,
          expectedRevision: 0,
          surfaceSize: size,
        ) !=
        AddNotationResult.added) {
      throw const FormatException('Test markings could not be placed.');
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(ink.strokes.map(StoredPage.strokeToJson).toList()),
      ),
    );
  } finally {
    ink.dispose();
  }
}
