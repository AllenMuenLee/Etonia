import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/editor/document_io/document_io_config.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/goodnotes_archive_extractor.dart';
import 'package:greatnote/features/editor/document_io/pdf_exporter.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:image/image.dart' as image;

import '../../helpers/document_io_fakes.dart';

const String _lectureFile = '2026+MGY377+Lecture+15.goodnotes';

void main() {
  group('real notebook ($_lectureFile)', () {
    final File file = File(_lectureFile);
    final String? skip = file.existsSync()
        ? null
        : '$_lectureFile is not in the project root';
    late Uint8List bytes;
    late GoodnotesArchiveExtraction extraction;

    setUpAll(() async {
      if (skip != null) return;
      bytes = file.readAsBytesSync();
      extraction = await const GoodnotesArchiveExtractor().extract(
        bytes,
        fileName: _lectureFile,
      );
    });

    test('is recognized as a notebook, not a PDF', () {
      expect(GoodnotesArchiveExtractor.isGoodnotesArchive(bytes), isTrue);
    }, skip: skip);

    test('has its title and its 38 slide pages, in order', () {
      expect(extraction.title, '2026+MGY377+Lecture+15');
      expect(extraction.pageCount, 38);
      expect(extraction.pdfAttachments, hasLength(1));
      final Uint8List pdf = extraction.pdfBytes!;
      expect(pdf.length, 2905600);
      expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
      for (int i = 0; i < 38; i++) {
        expect(extraction.pageSizes[i], const Size(1280, 720));
        expect(extraction.pdfAttachmentIndices[i], 0);
        expect(extraction.pdfPageIndices[i], i, reason: 'page ${i + 1}');
      }
    }, skip: skip);

    test('decodes every live stroke onto the 13 annotated pages', () {
      final List<int> annotated = <int>[
        for (int i = 0; i < 38; i++)
          if (extraction.pageStrokes[i].isNotEmpty) i + 1,
      ];
      expect(annotated, <int>[4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]);
      final List<Stroke> all = <Stroke>[
        for (final List<Stroke> page in extraction.pageStrokes) ...page,
      ];
      // 832 stroke records, of which 41 are erased strokes' tombstones.
      expect(all, hasLength(791));
      expect(all.where((Stroke s) => s.style.isHighlighter), hasLength(12));
      // Ink may run a few units past the edge, as it does in Goodnotes.
      final Rect page = const Rect.fromLTWH(0, 0, 1280, 720).inflate(8);
      for (final Stroke stroke in all) {
        for (final InkVector p in stroke.points) {
          expect(p.x.isFinite && p.y.isFinite, isTrue);
          expect(page.contains(Offset(p.x, p.y)), isTrue, reason: '$p');
        }
      }
    }, skip: skip);

    test('pens keep their width profile and color', () {
      final List<Stroke> pens = <Stroke>[
        for (final List<Stroke> page in extraction.pageStrokes)
          ...page.where((Stroke s) => !s.style.isHighlighter),
      ];
      expect(pens, hasLength(779));
      for (final Stroke pen in pens) {
        expect(pen.widths, isNotNull);
        expect(pen.widths, hasLength(pen.points.length));
        expect(pen.style.opacity, 1);
        // Goodnotes' near-black: (0.118, 0.106, 0.106).
        expect(pen.style.ink.id, 'imported-ff1e1b1b');
        expect(pen.style.width, inInclusiveRange(0.3, 6));
      }
      // Pressure shows: widths along a stroke are not all the same.
      expect(
        pens.where((Stroke s) => s.widths!.toSet().length > 1).length,
        greaterThan(pens.length * 0.9),
      );
    }, skip: skip);

    test('highlighters, the shape-snapped line included, are translucent', () {
      final List<Stroke> slide12 = extraction.pageStrokes[11];
      expect(slide12, hasLength(3));
      for (final Stroke stroke in slide12) {
        expect(stroke.style.writing, WritingStyle.highlighter);
        expect(stroke.style.opacity, closeTo(0.5, 0.01));
        expect(stroke.style.ink.id, 'imported-fffc8cc7');
        expect(stroke.style.width, closeTo(12.992 * 8 / 11, 0.01));
        expect(stroke.widths, isNull);
      }
      // The straight line Goodnotes snapped from a scribble, kept in
      // its own field because its curve data is empty.
      final Stroke line = slide12.singleWhere(
        (Stroke s) => s.points.length == 2,
      );
      expect(line.points.first.x, closeTo(186.077 * 8 / 11, 0.01));
      expect(line.points.first.y, closeTo(296.722 * 8 / 11, 0.01));
      expect(line.points.last.x, closeTo(1561.37 * 8 / 11, 0.01));
      expect(line.points.last.y, closeTo(296.722 * 8 / 11, 0.01));
    }, skip: skip);

    test('imports as a note that exports to a 38-page PDF', () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final FakePdfRasterizer rasterizer = FakePdfRasterizer(
        inspection: PdfInspection(
          pageSizes: List<Size>.filled(38, const Size(960, 540)),
        ),
        renderedPng: Uint8List.fromList(
          image.encodePng(image.Image(width: 4, height: 4)),
        ),
      );
      final DocumentImporter importer = DocumentImporter(
        rasterizer: rasterizer,
      );
      // The PDF import path recognizes the notebook by its contents.
      final note = await importer.importPdfAsNote(
        repository: repository,
        picked: PickedDocument(name: _lectureFile, bytes: bytes),
      );
      expect(note.title, '2026+MGY377+Lecture+15');
      final NoteContent content = await repository.loadNote(note.id);
      expect(content.pages, hasLength(38));
      final assets = await repository.listAssets(note.id);
      expect(assets, hasLength(1));
      expect(
        (await repository.readAsset(note.id, assets.single.id)).bytes.length,
        2905600,
      );
      for (int i = 0; i < 38; i++) {
        final StoredPage page = content.pages[i];
        expect(page.setup.size, PageSize.custom);
        expect(page.setup.customSize, const Size(1280, 720));
        expect(page.pdfSource!.pageIndex, i);
        expect(page.pdfSource!.pageSize, const Size(1280, 720));
        expect(page.strokes, hasLength(extraction.pageStrokes[i].length));
      }
      // Saved and loaded strokes keep their geometry and look.
      final Stroke before = extraction.pageStrokes[3].first;
      final Stroke after = content.pages[3].strokes.first;
      expect(after.style.ink.id, before.style.ink.id);
      expect(after.style.width, before.style.width);
      expect(after.style.writing, before.style.writing);
      expect(after.style.opacity, before.style.opacity);
      expect(after.points.length, before.points.length);
      expect(after.points.last.x, closeTo(before.points.last.x, 1e-3));
      expect(after.widths!.last, closeTo(before.widths!.last, 1e-3));

      final Uint8List pdf = await PdfExporter(rasterizer: rasterizer).buildPdf(
        noteId: note.id,
        title: note.title,
        content: content,
        repository: repository,
      );
      expect(ascii.decode(pdf.sublist(0, 4)), '%PDF');
      final String text = latin1.decode(pdf);
      expect(RegExp(r'/Type\s*/Page[^s]').allMatches(text), hasLength(38));
      final Iterable<RegExpMatch> boxes = RegExp(
        r'/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]',
      ).allMatches(text);
      expect(boxes, hasLength(38));
      for (final RegExpMatch box in boxes) {
        expect(double.parse(box[3]!), closeTo(960, 0.01));
        expect(double.parse(box[4]!), closeTo(540, 0.01));
      }
      // Ink is drawn in PDF points: the snapped highlighter on slide 12
      // starts at (186.077, 296.722) Goodnotes units × 8/11 × 3/4, with y
      // measured from the top or, flipped, from the bottom.
      final String drawn = _pageContents(pdf).join('\n');
      const double x = 186.077 * 8 / 11 * 0.75;
      const double y = 296.722 * 8 / 11 * 0.75;
      final bool found = RegExp(r'(-?[\d.]+) (-?[\d.]+) m\b')
          .allMatches(drawn)
          .any((RegExpMatch m) {
            final double mx = double.parse(m[1]!);
            final double my = double.parse(m[2]!);
            return (mx - x).abs() < 0.05 &&
                ((my - y).abs() < 0.05 || (my - (540 - y)).abs() < 0.05);
          });
      expect(found, isTrue);
    }, skip: skip);

    test('a cancelled import leaves nothing behind', () async {
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final ImportCancellationToken cancellation = ImportCancellationToken();
      final DocumentImporter importer = DocumentImporter(
        rasterizer: FakePdfRasterizer(
          inspection: PdfInspection(
            pageSizes: List<Size>.filled(38, const Size(960, 540)),
          ),
        ),
      );
      final Future<void> import = importer.importGoodnotesAsNote(
        repository: repository,
        picked: PickedDocument(name: _lectureFile, bytes: bytes),
        cancellation: cancellation,
      );
      cancellation.cancel();
      await expectLater(import, throwsA(isA<DocumentImportException>()));
      expect((await repository.list(null)).notes, isEmpty);
    }, skip: skip);
  });

  group('bv4 (LZ4)', () {
    test('decodes literals and overlapping matches', () {
      // "abc" then a match 3 back, 9 long: "abcabcabcabc".
      final Uint8List lz4 = Uint8List.fromList(<int>[
        0x35, 0x61, 0x62, 0x63, 0x03, 0x00, //
        0x10, 0x21, // A final literal "!".
      ]);
      final Uint8List out = decompressGoodnotesBv4(
        _bv4(<List<int>>[_bv41(lz4, 13)]),
      );
      expect(ascii.decode(out), 'abcabcabcabc!');
    });

    test('decodes long lengths', () {
      // 20 literals ("x" × 20), then a 1-back match 300 long.
      final List<int> lz4 = <int>[
        0xFF, 20 - 15, ...List<int>.filled(20, 0x78), 0x01, 0x00,
        255, 300 - 4 - 15 - 255, //
        0x10, 0x79,
      ];
      final Uint8List out = decompressGoodnotesBv4(
        _bv4(<List<int>>[_bv41(lz4, 321)]),
      );
      expect(out.length, 321);
      expect(out.sublist(0, 320).every((int b) => b == 0x78), isTrue);
      expect(out.last, 0x79);
    });

    test('joins LZ4 and stored blocks, matching across blocks', () {
      final Uint8List out = decompressGoodnotesBv4(
        _bv4(<List<int>>[
          _bv4Stored(ascii.encode('hello ')),
          // A match reaching back 6 bytes, into the stored block.
          _bv41(<int>[0x02, 0x06, 0x00, 0x10, 0x21], 7),
        ]),
      );
      expect(ascii.decode(out), 'hello hello !');
    });

    test('rejects broken streams', () {
      for (final Uint8List broken in <Uint8List>[
        Uint8List.fromList(ascii.encode('bv41')), // Truncated header.
        _bv4(<List<int>>[
          _bv41(<int>[0x00, 0x05, 0x00], 4),
        ]), // Bad offset.
        _bv4(<List<int>>[
          _bv41(<int>[0x50, 0x61], 5),
        ]), // Short literals.
        _bv4(<List<int>>[
          _bv41(<int>[0x10, 0x61], 9),
        ]), // Wrong size.
        Uint8List.fromList(ascii.encode('bv4Xjunk')),
        Uint8List.fromList(_bv41(<int>[0x10, 0x61], 1)), // No end marker.
      ]) {
        expect(
          () => decompressGoodnotesBv4(broken),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('refuses to expand past its budget', () {
      expect(
        () => decompressGoodnotesBv4(
          _bv4(<List<int>>[_bv4Stored(List<int>.filled(64, 1))]),
          maxBytes: 63,
        ),
        throwsA(isA<DocumentImportException>()),
      );
    });
  });

  group('tpl', () {
    test('parses the pen schema', () {
      final GoodnotesTpl tpl = parseGoodnotesTpl(
        _tpl('vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)', (_TplWriter w) {
          w
            ..v(2)
            ..vs(<int>[4, 5])
            ..fs(<double>[10, 20, 0.5, 1])
            ..fs(<double>[15, 20, 0.6, 20, 20, 0.7, 1, 1, 0.6])
            ..vs(<int>[])
            ..vs(<int>[])
            ..fs(<double>[])
            ..fs(<double>[])
            ..fs(<double>[])
            ..fs(<double>[])
            ..vs(<int>[]);
        }),
      );
      expect(tpl.ints(1), <int>[4, 5]);
      expect(tpl.doubles(2), <double>[10, 20, 0.5, 1]);
      expect(tpl.doubles(3)[3], 20);
      expect(tpl.doubles(3)[5], closeTo(0.7, 1e-6));
    });

    test('parses the highlighter schema', () {
      final GoodnotesTpl tpl = parseGoodnotesTpl(
        _tpl('vuA(v)A(S(uu))A(S(uuuu))vA(f)', (_TplWriter w) {
          w
            ..v(2)
            ..f(12.5)
            ..vs(<int>[0, 1])
            ..u32(1)
            ..f(1)
            ..f(2)
            ..u32(1)
            ..f(3)
            ..f(4)
            ..f(5)
            ..f(6)
            ..v(1)
            ..fs(<double>[]);
        }),
      );
      expect(tpl.number(1), 12.5);
      expect(tpl.structs(3), <List<double>>[
        <double>[1, 2],
      ]);
      expect(tpl.structs(4), <List<double>>[
        <double>[3, 4, 5, 6],
      ]);
    });

    test('rejects truncated data and arrays longer than their data', () {
      expect(
        () => parseGoodnotesTpl(
          _tpl(
            'A(u)',
            (_TplWriter w) => w
              ..u32(1000)
              ..f(1),
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseGoodnotesTpl(_tpl('vv', (_TplWriter w) => w.v(1))),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => parseGoodnotesTpl(_tpl('A(u', (_TplWriter w) => w.u32(0))),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('stroke streams', () {
    test('rebuild pens from quadratic curves with their radii', () {
      final List<GoodnotesRawStroke> strokes = decodeGoodnotesStrokeStream(
        _stream(<List<int>>[
          _penPayload(
            'A',
            start: <double>[0, 0, 1, 2],
            segments: <double>[50, 0, 2, 100, 0, 3, 2, 2, 0.6],
          ),
        ]),
      );
      final GoodnotesRawStroke pen = strokes.single;
      expect(pen.highlighter, isFalse);
      expect(pen.xy.first, 0);
      expect(pen.xy[pen.xy.length - 2], 100);
      expect(pen.radii!.first, 1);
      expect(pen.radii!.last, 3);
      // Sampled along the curve, not just at its ends.
      expect(pen.xy.length, greaterThan(4));

      final List<Stroke> built = buildGoodnotesStrokes(
        strokes,
        scaleX: 0.5,
        scaleY: 0.5,
      );
      expect(built.single.points.last.x, closeTo(50, 1e-9));
      expect(built.single.points.last.y, closeTo(0, 1e-9));
      final double end = built.single.style.width * built.single.widths!.last;
      expect(end, closeTo(3, 1e-9)); // 2 × radius 3 × scale 0.5.
    });

    test('keep only the last record of each stroke, minus erased ones', () {
      final List<GoodnotesRawStroke> strokes = decodeGoodnotesStrokeStream(
        _stream(<List<int>>[
          _penPayload(
            'A',
            start: <double>[0, 0, 1, 1],
            segments: <double>[5, 0, 1, 10, 0, 1, 1, 1, 0.6],
          ),
          _penPayload(
            'B',
            start: <double>[0, 0, 1, 1],
            segments: <double>[5, 0, 1, 10, 0, 1, 1, 1, 0.6],
          ),
          // A moved, then B erased.
          _penPayload(
            'A',
            start: <double>[0, 50, 1, 1],
            segments: <double>[5, 50, 1, 10, 50, 1, 1, 1, 0.6],
          ),
          _penPayload(
            'B',
            start: <double>[],
            segments: <double>[],
            erased: true,
          ),
        ]),
      );
      expect(strokes, hasLength(1));
      expect(strokes.single.xy[1], 50);
    });

    test('rejects truncated records', () {
      final Uint8List stream = _stream(<List<int>>[
        _penPayload(
          'A',
          start: <double>[0, 0, 1, 1],
          segments: <double>[5, 0, 1, 10, 0, 1, 1, 1, 0.6],
        ),
      ]);
      expect(
        () => decodeGoodnotesStrokeStream(
          Uint8List.sublistView(stream, 0, stream.length - 5),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('archives', () {
    test('a synthetic notebook of plain paper imports', () async {
      final Uint8List notebook = _zip(<String, List<int>>{
        'schema.pb': <int>[0x08, 26],
        'index.notes.pb': _delimitedMessages(<List<int>>[
          _fields(<int, Object>{1: 'P1-STREAM', 2: 'notes/P1-STREAM'}),
        ]),
        'notes/P1-STREAM': _stream(<List<int>>[
          _penPayload(
            'A',
            start: <double>[110, 110, 1, 1],
            segments: <double>[165, 110, 1, 220, 110, 1, 1, 1, 0.6],
          ),
        ]),
      }, deflate: true);
      expect(GoodnotesArchiveExtractor.isGoodnotesArchive(notebook), isTrue);
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final note = await DocumentImporter(rasterizer: FakePdfRasterizer())
          .importGoodnotesAsNote(
            repository: repository,
            picked: PickedDocument(name: 'Plain.goodnotes', bytes: notebook),
          );
      expect(note.title, 'Plain');
      final NoteContent content = await repository.loadNote(note.id);
      final StoredPage page = content.pages.single;
      expect(page.pdfSource, isNull);
      expect(page.setup.size, PageSize.custom);
      final List<InkVector> points = page.strokes.single.points;
      expect(points.first.x, closeTo(80, 1e-6));
      expect(points.first.y, closeTo(80, 1e-6));
      expect(points.last.x, closeTo(160, 1e-6));
      expect(points.last.y, closeTo(80, 1e-6));
      expect(await repository.listAssets(note.id), isEmpty);
    });

    test('a PDF is not taken for a notebook', () {
      expect(
        GoodnotesArchiveExtractor.isGoodnotesArchive(
          Uint8List.fromList(ascii.encode('%PDF-1.7')),
        ),
        isFalse,
      );
      expect(
        GoodnotesArchiveExtractor.isGoodnotesArchive(
          _zip(<String, List<int>>{'other.txt': ascii.encode('hi')}),
        ),
        isFalse,
      );
    });

    test('corrupt archives fail cleanly', () async {
      final Uint8List good = _zip(<String, List<int>>{
        'index.notes.pb': _delimitedMessages(<List<int>>[
          _fields(<int, Object>{1: 'S', 2: 'notes/S'}),
        ]),
        'notes/S': <int>[0x0A, 0x7F, 0x01], // A truncated record.
      });
      final List<Uint8List> broken = <Uint8List>[
        good,
        Uint8List.fromList(<int>[0x50, 0x4B, 0x03, 0x04, 1, 2, 3]),
        Uint8List.sublistView(good, 0, good.length - 30),
        _zip(<String, List<int>>{
          'index.notes.pb': <int>[0x10, 0x0A, 0x03], // Truncated.
        }),
        _zip(<String, List<int>>{
          'schema.pb': <int>[0x08, 26],
        }),
      ];
      for (final Uint8List bytes in broken) {
        await expectLater(
          const GoodnotesArchiveExtractor().extract(bytes),
          throwsA(isA<DocumentImportException>()),
        );
      }
    });

    test('a decompression bomb is refused', () async {
      // A megabyte of zeros deflates to about a kilobyte.
      final Uint8List bomb = _zip(<String, List<int>>{
        'index.notes.pb': _delimitedMessages(<List<int>>[
          _fields(<int, Object>{1: 'S', 2: 'notes/S'}),
        ]),
        'notes/S': Uint8List(1 << 20),
      }, deflate: true);
      expect(bomb.length, lessThan(16 * 1024));
      await expectLater(
        const GoodnotesArchiveExtractor().extract(
          bomb,
          config: const DocumentIoConfig(maxGoodnotesExpandedBytes: 64 * 1024),
        ),
        throwsA(
          isA<DocumentImportException>().having(
            (DocumentImportException e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
      // A forged size in the directory does not get past it either.
      final Uint8List forged = Uint8List.fromList(bomb);
      _forgeUncompressedSize(forged, 'notes/S', 1024);
      await expectLater(
        const GoodnotesArchiveExtractor().extract(forged),
        throwsA(isA<DocumentImportException>()),
      );
    });

    test('a file over the size limit is refused before reading', () async {
      await expectLater(
        const GoodnotesArchiveExtractor().extract(
          Uint8List(2048),
          config: const DocumentIoConfig(maxImportGoodnotesBytes: 1024),
        ),
        throwsA(isA<DocumentImportException>()),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

/// The decompressed content streams of [pdf].
List<String> _pageContents(Uint8List pdf) {
  final List<String> streams = <String>[];
  final String text = latin1.decode(pdf);
  for (final RegExpMatch match in RegExp(r'stream\r?\n').allMatches(text)) {
    final int start = match.end;
    final int end = text.indexOf('endstream', start);
    if (end < 0) continue;
    final Uint8List data = Uint8List.sublistView(pdf, start, end);
    try {
      streams.add(latin1.decode(ZLibCodec().decode(data)));
    } on Object {
      streams.add(latin1.decode(data));
    }
  }
  return streams;
}

Uint8List _bv4(List<List<int>> blocks) => Uint8List.fromList(<int>[
  for (final List<int> block in blocks) ...block,
  ...ascii.encode(r'bv4$'),
]);

List<int> _bv41(List<int> lz4, int size) => <int>[
  ...ascii.encode('bv41'),
  ..._u32(size),
  ..._u32(lz4.length),
  ...lz4,
];

List<int> _bv4Stored(List<int> data) => <int>[
  ...ascii.encode('bv4-'),
  ..._u32(data.length),
  ...data,
];

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

class _TplWriter {
  final BytesBuilder _out = BytesBuilder();

  void v(int value) => _out.add(
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u32(int value) => _out.add(_u32(value));
  void f(double value) => _out.add(
    (ByteData(4)..setFloat32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void vs(List<int> values) {
    u32(values.length);
    values.forEach(v);
  }

  void fs(List<double> values) {
    u32(values.length);
    values.forEach(f);
  }
}

Uint8List _tpl(String format, void Function(_TplWriter) write) {
  final _TplWriter writer = _TplWriter();
  write(writer);
  final List<int> body = <int>[
    ...ascii.encode(format),
    0,
    ...writer._out.takeBytes(),
  ];
  return Uint8List.fromList(<int>[
    ...ascii.encode('tpl'),
    0,
    ..._u32(body.length + 8),
    ...body,
  ]);
}

List<int> _varint(int value) {
  final List<int> out = <int>[];
  do {
    int byte = value & 0x7F;
    value >>= 7;
    if (value != 0) byte |= 0x80;
    out.add(byte);
  } while (value != 0);
  return out;
}

/// A protobuf message: [int] values are varints, [double]s fixed32
/// floats, [String]s and byte lists length-delimited.
List<int> _fields(Map<int, Object> fields) => <int>[
  for (final MapEntry<int, Object> field in fields.entries)
    ...switch (field.value) {
      final int v => <int>[..._varint(field.key << 3), ..._varint(v)],
      final double v => <int>[
        ..._varint(field.key << 3 | 5),
        ...(ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List(),
      ],
      final String v => <int>[
        ..._varint(field.key << 3 | 2),
        ..._varint(utf8.encode(v).length),
        ...utf8.encode(v),
      ],
      final List<int> v => <int>[
        ..._varint(field.key << 3 | 2),
        ..._varint(v.length),
        ...v,
      ],
      _ => throw ArgumentError(field.value),
    },
];

Uint8List _delimitedMessages(List<List<int>> messages) =>
    Uint8List.fromList(<int>[
      for (final List<int> m in messages) ...<int>[..._varint(m.length), ...m],
    ]);

Uint8List _stream(List<List<int>> payloads) => _delimitedMessages(payloads);

/// A stroke record: `{7: StrokePayload}` with the pen `tpl` schema,
/// stored in a `bv4-` block.
List<int> _penPayload(
  String id, {
  required List<double> start,
  required List<double> segments,
  bool erased = false,
}) {
  final Uint8List tpl = _tpl('vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)', (
    _TplWriter w,
  ) {
    w
      ..v(2)
      ..vs(<int>[
        if (start.isNotEmpty) 4,
        for (int i = 0; i < segments.length ~/ 9; i++) 5,
      ])
      ..fs(start)
      ..fs(segments)
      ..vs(<int>[])
      ..vs(<int>[])
      ..fs(<double>[])
      ..fs(<double>[])
      ..fs(<double>[])
      ..fs(<double>[])
      ..vs(<int>[]);
  });
  return _fields(<int, Object>{
    7: _fields(<int, Object>{
      1: id,
      2: _bv4(<List<int>>[_bv4Stored(tpl)]),
      3: 1,
      4: _fields(<int, Object>{1: 0.0, 2: 0.0, 3: 0.0, 4: 1.0}),
      if (erased) 14: 1,
    }),
  });
}

/// A ZIP archive of [entries], stored or deflated.
Uint8List _zip(Map<String, List<int>> entries, {bool deflate = false}) {
  final BytesBuilder out = BytesBuilder();
  final BytesBuilder directory = BytesBuilder();
  List<int> u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  for (final MapEntry<String, List<int>> entry in entries.entries) {
    final List<int> name = utf8.encode(entry.key);
    final List<int> data = deflate
        ? ZLibCodec(raw: true).encode(entry.value)
        : entry.value;
    final int offset = out.length;
    final List<int> common = <int>[
      ...u16(20), ...u16(0), ...u16(deflate ? 8 : 0), ...u16(0), ...u16(0),
      ..._u32(0), // CRC, which this reader does not check.
      ..._u32(data.length), ..._u32(entry.value.length),
      ...u16(name.length), ...u16(0),
    ];
    out
      ..add(_u32(0x04034B50))
      ..add(common)
      ..add(name)
      ..add(data);
    directory
      ..add(_u32(0x02014B50))
      ..add(u16(20))
      ..add(common)
      ..add(<int>[...u16(0), ...u16(0), ...u16(0), ..._u32(0)])
      ..add(_u32(offset))
      ..add(name);
  }
  final int directoryOffset = out.length;
  final Uint8List dir = directory.takeBytes();
  out
    ..add(dir)
    ..add(_u32(0x06054B50))
    ..add(<int>[...u16(0), ...u16(0)])
    ..add(u16(entries.length))
    ..add(u16(entries.length))
    ..add(_u32(dir.length))
    ..add(_u32(directoryOffset))
    ..add(u16(0));
  return out.takeBytes();
}

/// Rewrites [name]'s uncompressed size in both its headers.
void _forgeUncompressedSize(Uint8List zip, String name, int size) {
  final ByteData view = ByteData.sublistView(zip);
  final List<int> encoded = utf8.encode(name);
  for (int i = 0; i + 4 <= zip.length; i++) {
    final int signature = view.getUint32(i, Endian.little);
    final int? nameAt = signature == 0x04034B50
        ? i + 30
        : signature == 0x02014B50
        ? i + 46
        : null;
    if (nameAt == null || nameAt + encoded.length > zip.length) continue;
    bool matches = true;
    for (int k = 0; k < encoded.length; k++) {
      if (zip[nameAt + k] != encoded[k]) matches = false;
    }
    if (!matches) continue;
    view.setUint32(
      signature == 0x04034B50 ? i + 22 : i + 24,
      size,
      Endian.little,
    );
  }
}
