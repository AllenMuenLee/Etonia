import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/ai/ai_notation.dart';
import 'package:greatnote/features/editor/document_io/document_models.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/pdf_exporter.dart';
import 'package:greatnote/features/editor/document_io/svg_document.dart';
import 'package:greatnote/features/editor/document_io/svg_exporter.dart';
import 'package:greatnote/features/editor/ink/eraser_settings.dart';
import 'package:greatnote/features/editor/ink/ink_controller.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';

import '../../../helpers/document_io_fakes.dart';

const String _response = '''
<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1"
  viewBox="0 0 800 1000" data-etonia-bounds="100 200 240 160"
  data-etonia-duration-ms="1200">
  <title>Force diagram</title>
  <desc data-etonia-role="message">Use **F = ma** &amp; resolve x/y.</desc>
  <g data-etonia-step="1"><rect x="100" y="200" width="80" height="60"/></g>
  <path data-etonia-step="2" d="M180 230 L340 230" stroke="blue"/>
</svg>
''';

void main() {
  group('EditableSvg', () {
    test('reads a model response and produces cumulative animation frames', () {
      final EditableSvg svg = EditableSvg.parse(_response, modelResponse: true);

      expect(svg.label, 'Force diagram');
      expect(svg.message, 'Use **F = ma** & resolve x/y.');
      expect(svg.viewBox, const Rect.fromLTWH(0, 0, 800, 1000));
      expect(svg.contentBounds, const Rect.fromLTWH(100, 200, 240, 160));
      expect(svg.stepCount, 2);
      expect(svg.frame(0), isNot(contains('<rect')));
      expect(svg.frame(1), contains('<rect'));
      expect(svg.frame(1), isNot(contains('<path')));
      expect(svg.frame(2), contains('<path'));
    });

    test('rejects script, event handlers, and external resources', () {
      for (final String unsafe in <String>[
        '<svg viewBox="0 0 10 10"><script>alert(1)</script></svg>',
        '<svg viewBox="0 0 10 10"><path onclick="x()" d="M0 0"/></svg>',
        '<svg viewBox="0 0 10 10"><use href="https://example.com/x.svg#x"/></svg>',
        '<svg viewBox="0 0 10 10"><style>@import "https://example.com/x.css";</style><path d="M0 0"/></svg>',
        '<svg viewBox="0 0 10 10"><style>.a{fill:url(#ok)}.b{fill:url(https://example.com/x.svg)}</style><path d="M0 0"/></svg>',
        '<!DOCTYPE svg [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><svg viewBox="0 0 10 10"><text>&xxe;</text></svg>',
      ]) {
        expect(() => EditableSvg.parse(unsafe), throwsFormatException);
      }
    });

    test('AI response is SVG-native while legacy JSON remains readable', () {
      final AiAssistantResponse response = AiAssistantResponse.parse(_response);
      expect(response.message, contains('F = ma'));
      expect(response.notation?.vector?.source, startsWith('<svg'));

      final AiAssistantResponse fenced = AiAssistantResponse.parse(
        '```SVG\n<?xml version="1.0"?>\n$_response```',
      );
      expect(fenced.notation?.vector?.label, 'Force diagram');

      final AiAssistantResponse unsafeDrawing = AiAssistantResponse.parse('''
<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 10 10">
  <title>Bad drawing</title>
  <desc data-etonia-role="message">The readable answer remains.</desc>
  <script>alert(1)</script>
</svg>
''');
      expect(unsafeDrawing.message, 'The readable answer remains.');
      expect(unsafeDrawing.notation, isNull);
      expect(unsafeDrawing.notationRejected, isTrue);

      final AiAssistantResponse legacy = AiAssistantResponse.parse(
        jsonEncode(<String, Object?>{
          'version': 2,
          'message': 'Still readable',
          'notation': null,
        }),
      );
      expect(legacy.message, 'Still readable');
    });
  });

  test('SVG survives note storage, transform, clipboard, and eraser tools', () {
    final EditableSvg svg = EditableSvg.parse(_response).croppedToContent();
    final InkController controller = InkController();
    addTearDown(controller.dispose);
    expect(
      controller.insertImage(
        NoteImageElement(
          id: 'svg-1',
          assetId: '',
          pixelSize: svg.viewBox.size,
          center: const InkVector(220, 280),
          size: const Size(240, 160),
          vector: svg,
        ),
      ),
      isTrue,
    );
    expect(controller.copySelection(), isTrue);
    expect(controller.paste(at: const InkVector(500, 500)), isTrue);
    expect(controller.images, hasLength(2));
    expect(controller.images.last.vector?.source, svg.source);

    final NoteContent stored = NoteContent(<StoredPage>[
      StoredPage(
        setup: const PageSetup(),
        images: controller.images,
        strokes: const [],
      ),
    ]);
    final NoteContent restored = NoteContent.fromJson(
      jsonDecode(jsonEncode(stored.toJson())) as Map<String, Object?>,
    );
    expect(restored.pages.single.images, hasLength(2));
    expect(restored.pages.single.images.first.vector?.source, svg.source);

    expect(
      controller.startErase(
        pointer: 7,
        position: const InkVector(220, 280),
        settings: const EraserSettings(mode: EraserMode.stroke, size: 20),
      ),
      isTrue,
    );
    controller.endErase(7);
    expect(controller.images, hasLength(1));
    expect(controller.undo(), isTrue);
    expect(controller.images, hasLength(2));
  });

  test(
    'SVG import retains vector source and inserts a selectable object',
    () async {
      final InkController controller = InkController();
      addTearDown(controller.dispose);
      final NoteImageElement inserted =
          await DocumentImporter(rasterizer: FakePdfRasterizer()).insertSvg(
            controller: controller,
            picked: PickedDocument(
              name: 'forces.svg',
              bytes: Uint8List.fromList(utf8.encode(_response)),
            ),
            visiblePage: const Rect.fromLTWH(0, 0, 800, 1000),
          );

      expect(inserted.vector?.viewBox, const Rect.fromLTWH(100, 200, 240, 160));
      expect(inserted.vector?.source, contains('data-etonia-step="2"'));
      expect(controller.selection?.images.single, inserted);
    },
  );

  test('page SVG export retains nested vectors as editable XML', () {
    final EditableSvg svg = EditableSvg.parse(_response).croppedToContent();
    final InkController controller = InkController(
      images: <NoteImageElement>[
        NoteImageElement(
          id: 'diagram',
          assetId: '',
          pixelSize: svg.viewBox.size,
          center: const InkVector(220, 280),
          size: const Size(240, 160),
          vector: svg,
        ),
      ],
    );
    addTearDown(controller.dispose);

    final String exported = const SvgExporter().build(
      title: 'Physics',
      pageSize: const Size(800, 1000),
      controller: controller,
    );
    final EditableSvg parsed = EditableSvg.parse(exported);
    expect(parsed.source, contains('data-etonia-object-id="diagram"'));
    expect(parsed.source, contains('data-etonia-step="2"'));
  });

  test('PDF export renders inline SVG without a bitmap asset', () async {
    final EditableSvg svg = EditableSvg.parse(_response).croppedToContent();
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final Uint8List pdf = await PdfExporter(rasterizer: FakePdfRasterizer())
        .buildPdf(
          noteId: note.id,
          title: 'Vector note',
          content: NoteContent(<StoredPage>[
            StoredPage(
              setup: const PageSetup(),
              images: <NoteImageElement>[
                NoteImageElement(
                  id: 'vector',
                  assetId: '',
                  pixelSize: svg.viewBox.size,
                  center: const InkVector(220, 280),
                  size: const Size(240, 160),
                  vector: svg,
                ),
              ],
              strokes: const [],
            ),
          ]),
          repository: repository,
        );
    expect(utf8.decode(pdf.sublist(0, 4)), '%PDF');
  });
}
