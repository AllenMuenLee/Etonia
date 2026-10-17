import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:greatnote/features/editor/document_io/document_io_config.dart';
import 'package:greatnote/features/editor/document_io/document_importer.dart';
import 'package:greatnote/features/editor/document_io/document_platform.dart';
import 'package:greatnote/features/editor/document_io/goodnotes_pdf_recovery.dart';
import 'package:greatnote/features/editor/ink/ink_palette.dart';
import 'package:greatnote/features/editor/ink/ink_sample.dart';
import 'package:greatnote/features/editor/ink/stroke.dart';
import 'package:greatnote/features/editor/page/note_document.dart';
import 'package:greatnote/features/editor/page/page_setup.dart';
import 'package:greatnote/features/library/note_content.dart';
import 'package:greatnote/features/library/note_repository.dart';
import 'package:image/image.dart' as image;

import '../../helpers/document_io_fakes.dart';

void main() {
  test(
    'width control removes isolated spikes and dips without flattening pressure',
    () {
      final List<InkVector> points = <InkVector>[
        for (int i = 0; i <= 100; i++) InkVector(i.toDouble(), 0),
      ];
      final List<double> measured = <double>[
        for (int i = 0; i <= 100; i++) 2 + math.min(i, 100 - i) * 0.2,
      ]..[25] = 40;
      measured[70] = 1;
      final List<double> widths = smoothRecoveredWidthsForTest(
        points: points,
        diameters: measured,
      );
      expect(widths[25], closeTo(7, 0.3));
      expect(widths[70], closeTo(8, 0.3));
      expect(widths[50], greaterThan(11));
      expect(widths.first, lessThan(2.2));
      expect(widths.last, lessThan(2.2));
      _expectSmoothWidths(points, widths);
    },
  );

  test('width control bounds abrupt transitions with uneven point spacing', () {
    final List<InkVector> points = <InkVector>[
      for (int i = 0; i < 40; i++)
        InkVector(i < 20 ? i * 1.5 : 28.5 + (i - 19) * 0.05, 0),
    ];
    final List<double> widths = smoothRecoveredWidthsForTest(
      points: points,
      diameters: <double>[for (int i = 0; i < 40; i++) i < 20 ? 12 : 2],
    );
    _expectSmoothWidths(points, widths);
    expect(widths.first, greaterThan(10));
    expect(widths.last, closeTo(2, 0.01));
    final List<double> reversed = smoothRecoveredWidthsForTest(
      points: points.reversed.toList(),
      diameters: <double>[
        for (int i = 0; i < 40; i++) i < 20 ? 12 : 2,
      ].reversed.toList(),
    );
    for (int i = 0; i < widths.length; i++) {
      expect(reversed[widths.length - 1 - i], closeTo(widths[i], 1e-9));
    }
  });

  test('width control keeps a closed loop smooth across its seam', () {
    final List<InkVector> points = <InkVector>[
      for (int i = 0; i < 80; i++)
        InkVector(
          20 * math.cos(i * math.pi / 40),
          20 * math.sin(i * math.pi / 40),
        ),
    ];
    points.add(points.first);
    final List<double> widths = smoothRecoveredWidthsForTest(
      points: points,
      diameters: <double>[for (int i = 0; i < 80; i++) i < 40 ? 12 : 2],
      closed: true,
    );
    expect(widths, hasLength(points.length));
    expect(widths.first, widths.last);
    _expectSmoothWidths(points, widths);
    expect(widths[20], greaterThan(10));
  });

  for (final bool curved in <bool>[false, true]) {
    for (final bool textured in <bool>[false, true]) {
      test('recovers pressure profile: curved=$curved, pencil=$textured', () {
        final _Overlay overlay = _pressureOverlay(
          curved: curved,
          textured: textured,
        );
        final List<Stroke> strokes = traceGoodnotesOverlayForTest(
          rgb: overlay.rgb,
          alpha: overlay.alpha,
          width: overlay.width,
          height: overlay.height,
          pageSize: const Size(200, 200),
        );
        expect(
          strokes,
          hasLength(1),
          reason: strokes
              .map((s) => '${s.points.length}: ${s.bounds}')
              .join('\n'),
        );
        final Stroke stroke = strokes.single;
        expect(
          (stroke.style.ink.resolve(Brightness.light).a * 255).round(),
          textured ? inInclusiveRange(100, 150) : 255,
        );
        expect(stroke.widths, hasLength(stroke.points.length));
        expect(stroke.points.length, greaterThan(50));
        _expectSmoothWidths(stroke.points, <double>[
          for (final double factor in stroke.widths!)
            factor * stroke.style.width,
        ]);
        double diameterAt(double x) {
          int closest = 0;
          for (int i = 1; i < stroke.points.length; i++) {
            if ((stroke.points[i].x - x).abs() <
                (stroke.points[closest].x - x).abs()) {
              closest = i;
            }
          }
          return stroke.widths![closest] * stroke.style.width;
        }

        expect(diameterAt(100), closeTo(14, 2));
        expect(diameterAt(40), closeTo(5, 2));
        expect(diameterAt(160), closeTo(5, 2));
        expect(diameterAt(100), greaterThan(diameterAt(40) * 2));
        for (int i = 0; i < stroke.points.length; i++) {
          final InkVector point = stroke.points[i];
          final double center =
              100.5 +
              (curved
                  ? 12 * math.sin((point.x - 25.5) / 150 * math.pi * 2)
                  : 0);
          expect(point.y, closeTo(center, 1.8));
          expect(stroke.widths![i], isPositive);
          if (i > 0) {
            expect(
              (stroke.widths![i] - stroke.widths![i - 1]).abs() *
                  stroke.style.width,
              lessThan(1.6),
            );
          }
        }
        final NoteContent stored = NoteContent.fromJson(
          jsonDecode(
                jsonEncode(
                  NoteContent(<StoredPage>[
                    StoredPage(setup: const PageSetup(), strokes: strokes),
                  ]).toJson(),
                ),
              )
              as Map<String, Object?>,
        );
        final Stroke copy = stored.pages.single.strokes.single;
        expect(copy.points.length, stroke.points.length);
        for (int i = 0; i < stroke.points.length; i++) {
          expect(copy.widths![i], closeTo(stroke.widths![i], 0.00051));
        }
      });
    }
  }

  test(
    'texture cleanup preserves real crossings and separate nearby strokes',
    () {
      final _Overlay overlay = _rasterOverlay(
        (int x, int y) =>
            (x >= 30 && x <= 100 && (y - 70).abs() <= 2) ||
            (y >= 35 && y <= 110 && (x - 65).abs() <= 2) ||
            (x >= 125 &&
                x <= 175 &&
                ((y - 60).abs() <= 2 || (y - 68).abs() <= 2)),
      );
      for (int i = 0; i < overlay.alpha.length; i++) {
        if (overlay.alpha[i] != 0) overlay.alpha[i] = 60 + (i * 17) % 150;
      }
      final List<Stroke> strokes = traceGoodnotesOverlayForTest(
        rgb: overlay.rgb,
        alpha: overlay.alpha,
        width: overlay.width,
        height: overlay.height,
        pageSize: const Size(200, 200),
      );
      expect(strokes, hasLength(6));
      final List<Stroke> nearby = strokes
          .where((s) => s.points.first.x > 120)
          .toList();
      expect(nearby, hasLength(2));
      expect(nearby.map((s) => s.points.first.y).toList()..sort(), <double>[
        60.5,
        68.5,
      ]);
      for (final Stroke stroke in strokes) {
        expect(
          stroke.widths!.map((w) => w * stroke.style.width).reduce(math.max),
          lessThan(10),
        );
      }
    },
  );

  test('dense fixed regions stay fixed while colored ink is traced', () {
    final _Overlay overlay = _testOverlay();
    final List<Stroke> strokes = traceGoodnotesOverlayForTest(
      rgb: overlay.rgb,
      alpha: overlay.alpha,
      width: overlay.width,
      height: overlay.height,
      pageSize: const Size(200, 200),
    );

    expect(strokes, isNotEmpty);
    expect(
      strokes.expand((Stroke stroke) => stroke.points),
      everyElement(
        isA<InkVector>().having(
          (InkVector point) => point.x,
          'x',
          greaterThan(95),
        ),
      ),
    );
    expect(strokes.first.style.ink.id, 'imported-ffff0000');
    expect(strokes.first.style.width, inInclusiveRange(1, 20));
    expect(
      strokes.expand((Stroke stroke) => stroke.points),
      everyElement(
        isA<InkVector>().having(
          (InkVector point) => point.y,
          'top-to-bottom raster y',
          greaterThan(100),
        ),
      ),
    );
    expect(
      strokes.expand((Stroke stroke) => stroke.points),
      everyElement(
        isA<InkVector>().having(
          (InkVector point) => point.isFinite,
          'finite',
          isTrue,
        ),
      ),
    );
  });

  test('asymmetric ink keeps its position and slope on a scaled page', () {
    final _Overlay overlay = _rasterOverlay(
      (int x, int y) =>
          x >= 20 && x <= 80 && (y - 15 - (x - 20) / 2).abs() <= 2,
    );
    final List<Stroke> strokes = traceGoodnotesOverlayForTest(
      rgb: overlay.rgb,
      alpha: overlay.alpha,
      width: overlay.width,
      height: overlay.height,
      pageSize: const Size(400, 600),
    );
    expect(strokes, hasLength(1));
    final List<InkVector> points = strokes.single.points;
    final InkVector left = points.reduce((a, b) => a.x < b.x ? a : b);
    final InkVector right = points.reduce((a, b) => a.x > b.x ? a : b);
    expect(left.x, closeTo(41, 5));
    expect(left.y, closeTo(46.5, 7));
    expect(right.x, closeTo(161, 5));
    expect(right.y, closeTo(136.5, 7));
    expect(right.y, greaterThan(left.y));
  });

  test('round handwriting stays closed, smooth, and close to the source', () {
    final _Overlay overlay = _rasterOverlay((int x, int y) {
      final double radius = math.sqrt(
        math.pow(x - 100, 2) + math.pow(y - 85, 2),
      );
      return (radius - 45).abs() <= 2.5;
    });
    final List<Stroke> strokes = traceGoodnotesOverlayForTest(
      rgb: overlay.rgb,
      alpha: overlay.alpha,
      width: overlay.width,
      height: overlay.height,
      pageSize: const Size(200, 200),
    );
    expect(strokes, hasLength(1));
    final List<InkVector> points = strokes.single.points;
    expect((points.first - points.last).length, lessThan(0.001));
    double greatestTurn = 0;
    String worstCorner = '';
    for (int i = 0; i < points.length - 1; i++) {
      final InkVector at = points[i];
      expect((at - const InkVector(100.5, 85.5)).length, closeTo(45, 1.5));
      final InkVector before =
          points[(i - 1 + points.length - 1) % (points.length - 1)];
      final InkVector after = points[i + 1];
      final InkVector incoming = at - before;
      final InkVector outgoing = after - at;
      final double cosine =
          incoming.dot(outgoing) / (incoming.length * outgoing.length);
      final double turn = math.acos(cosine.clamp(-1.0, 1.0));
      if (turn > greatestTurn) {
        greatestTurn = turn;
        worstCorner =
            '(${before.x}, ${before.y}) -> (${at.x}, ${at.y}) -> (${after.x}, ${after.y})';
      }
    }
    expect(greatestTurn, lessThan(0.3), reason: worstCorner);
    expect(strokes.single.style.width, closeTo(5, 1));
  });

  test('smoothing retains short dots and deliberate right-angle corners', () {
    final _Overlay overlay = _rasterOverlay((int x, int y) {
      final bool dot = x >= 20 && x <= 22 && y >= 20 && y <= 22;
      final bool horizontal = x >= 50 && x <= 120 && y >= 58 && y <= 62;
      final bool vertical = x >= 118 && x <= 122 && y >= 60 && y <= 130;
      return dot || horizontal || vertical;
    });
    final List<Stroke> strokes = traceGoodnotesOverlayForTest(
      rgb: overlay.rgb,
      alpha: overlay.alpha,
      width: overlay.width,
      height: overlay.height,
      pageSize: const Size(200, 200),
    );
    expect(strokes, hasLength(2));
    final Stroke dot = strokes.singleWhere((Stroke stroke) => stroke.isDot);
    expect(dot.points.single.x, closeTo(21.5, 0.5));
    expect(dot.points.single.y, closeTo(21.5, 0.5));
    final Stroke corner = strokes.singleWhere((Stroke stroke) => !stroke.isDot);
    expect(
      corner.points
          .map((InkVector p) => (p - const InkVector(120.5, 60.5)).length)
          .reduce(math.min),
      lessThan(2),
    );
    expect(corner.bounds.left, lessThan(52));
    expect(corner.bounds.bottom, greaterThan(128));
  });

  test(
    'small multicolored artwork is kept fixed instead of averaged into ink',
    () {
      final _Overlay overlay = _rasterOverlay(
        (int x, int y) => x >= 20 && x <= 80 && y >= 20 && y <= 25,
      );
      for (int y = 20; y <= 25; y++) {
        for (int x = 50; x <= 80; x++) {
          final int at = (y * overlay.width + x) * 3;
          overlay.rgb[at] = 0;
          overlay.rgb[at + 2] = 255;
        }
      }
      expect(
        traceGoodnotesOverlayForTest(
          rgb: overlay.rgb,
          alpha: overlay.alpha,
          width: overlay.width,
          height: overlay.height,
          pageSize: const Size(200, 200),
        ),
        isEmpty,
      );
    },
  );

  test('imported RGB ink survives note JSON round trips', () {
    final Stroke stroke = Stroke.fromPoints(
      style: StrokeStyle(
        ink: InkPalette.imported(const Color(0x8012a4ef)),
        width: 2.5,
      ),
      points: const <InkVector>[InkVector(1, 2), InkVector(3, 4)],
    );
    final NoteContent copy = NoteContent.fromJson(
      jsonDecode(
            jsonEncode(
              NoteContent(<StoredPage>[
                StoredPage(setup: const PageSetup(), strokes: <Stroke>[stroke]),
              ]).toJson(),
            ),
          )
          as Map<String, Object?>,
    );

    final Stroke stored = copy.pages.single.strokes.single;
    expect(stored.style.ink.id, 'imported-8012a4ef');
    expect(stored.style.ink.resolve(Brightness.light), const Color(0x8012a4ef));
  });

  test(
    'Goodnotes PDF recovery produces editable ink and cleaned paper',
    () async {
      final _GoodnotesFixture fixture = _goodnotesFixture();
      expect(
        probeGoodnotesPdfForTest(
          bytes: fixture.pdf,
          pageSizes: const <Size>[
            Size(100 * 4 / 3, 100 * 4 / 3),
            Size(100 * 4 / 3, 100 * 4 / 3),
          ],
        ),
        2,
      );
      final GoodnotesPdfRecovery? recovery = await const GoodnotesPdfRecoverer()
          .recover(
            bytes: fixture.pdf,
            pageSizes: const <Size>[
              Size(100 * 4 / 3, 100 * 4 / 3),
              Size(100 * 4 / 3, 100 * 4 / 3),
            ],
            config: const DocumentIoConfig(),
          );

      expect(recovery, isNotNull);
      expect(recovery!.backgroundPdf.sublist(0, 4), utf8.encode('%PDF'));
      expect(recovery.pageStrokes, hasLength(2));
      expect(recovery.pageStrokes, everyElement(isNotEmpty));
      // Both pages share one badge. Its soft mask is cleared, while the
      // screenshot's alpha and the badge RGB stream are preserved.
      expect(_decodedStream(recovery.backgroundPdf, 9), everyElement(0));
      expect(
        _decodedStream(recovery.backgroundPdf, 10),
        _decodedStream(fixture.pdf, 10),
      );
      for (final int mask in <int>[7, 13]) {
        final Uint8List cleaned = _decodedStream(recovery.backgroundPdf, mask);
        expect(cleaned[20 * 200 + 20], 255);
        expect(cleaned[120 * 200 + 140], 0);
      }
      expect(
        await const GoodnotesPdfRecoverer().recover(
          bytes: recovery.backgroundPdf,
          pageSizes: const <Size>[
            Size(100 * 4 / 3, 100 * 4 / 3),
            Size(100 * 4 / 3, 100 * 4 / 3),
          ],
          config: const DocumentIoConfig(),
        ),
        isNull,
      );
    },
  );

  test(
    'watermark is removed even when a page has no recoverable ink',
    () async {
      final _GoodnotesFixture fixture = _goodnotesFixture(withInk: false);
      final GoodnotesPdfRecovery? recovery = await const GoodnotesPdfRecoverer()
          .recover(
            bytes: fixture.pdf,
            pageSizes: const <Size>[
              Size(100 * 4 / 3, 100 * 4 / 3),
              Size(100 * 4 / 3, 100 * 4 / 3),
            ],
            config: const DocumentIoConfig(),
          );
      expect(recovery, isNotNull);
      expect(recovery!.pageStrokes, everyElement(isEmpty));
      expect(_decodedStream(recovery.backgroundPdf, 9), everyElement(0));
      expect(
        _decodedStream(recovery.backgroundPdf, 7),
        _decodedStream(fixture.pdf, 7),
      );
    },
  );

  test(
    'new-note import stores recovered strokes and one replacement PDF',
    () async {
      final _GoodnotesFixture fixture = _goodnotesFixture();
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      final FakePdfRasterizer rasterizer = FakePdfRasterizer(
        inspection: const PdfInspection(
          pageSizes: <Size>[Size(100, 100), Size(100, 100)],
        ),
        renderedPng: fixture.renderedPng,
      );

      final note = await DocumentImporter(rasterizer: rasterizer)
          .importPdfAsNote(
            repository: repository,
            picked: PickedDocument(name: 'Goodnotes.pdf', bytes: fixture.pdf),
            recoverGoodnotesInk: true,
            onNoInkRecovered: () => fail('ink should have been recovered'),
          );
      final NoteContent content = await repository.loadNote(note.id);

      expect(content.pages, hasLength(2));
      expect(
        content.pages,
        everyElement(predicate<StoredPage>((p) => p.strokes.isNotEmpty)),
      );
      expect(await repository.listAssets(note.id), hasLength(1));
      final NoteAsset asset = (await repository.listAssets(note.id)).single;
      final Uint8List stored = (await repository.readAsset(
        note.id,
        asset.id,
      )).bytes;
      expect(stored.sublist(0, 4), utf8.encode('%PDF'));
      expect(stored.length, isNot(fixture.pdf.length));
    },
  );

  test('a plain PDF import leaves a Goodnotes export as it is', () async {
    final _GoodnotesFixture fixture = _goodnotesFixture();
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final FakePdfRasterizer rasterizer = FakePdfRasterizer(
      inspection: const PdfInspection(
        pageSizes: <Size>[Size(100, 100), Size(100, 100)],
      ),
      renderedPng: fixture.renderedPng,
    );

    final note = await DocumentImporter(rasterizer: rasterizer).importPdfAsNote(
      repository: repository,
      picked: PickedDocument(name: 'Goodnotes.pdf', bytes: fixture.pdf),
    );
    final NoteContent content = await repository.loadNote(note.id);

    expect(
      content.pages,
      everyElement(predicate<StoredPage>((p) => p.strokes.isEmpty)),
    );
    final NoteAsset asset = (await repository.listAssets(note.id)).single;
    expect((await repository.readAsset(note.id, asset.id)).bytes, fixture.pdf);
  });

  test(
    'badge-only recovery still reports that no handwriting was found',
    () async {
      final _GoodnotesFixture fixture = _goodnotesFixture(withInk: false);
      final InMemoryNoteRepository repository = InMemoryNoteRepository();
      addTearDown(repository.dispose);
      bool noInk = false;
      final note =
          await DocumentImporter(
            rasterizer: FakePdfRasterizer(
              inspection: const PdfInspection(
                pageSizes: <Size>[Size(100, 100), Size(100, 100)],
              ),
            ),
          ).importPdfAsNote(
            repository: repository,
            picked: PickedDocument(name: 'Goodnotes.pdf', bytes: fixture.pdf),
            recoverGoodnotesInk: true,
            onNoInkRecovered: () => noInk = true,
          );
      expect(noInk, isTrue);
      final NoteContent content = await repository.loadNote(note.id);
      expect(
        content.pages,
        everyElement(predicate<StoredPage>((p) => p.strokes.isEmpty)),
      );
      final NoteAsset asset = (await repository.listAssets(note.id)).single;
      expect(
        _decodedStream(
          (await repository.readAsset(note.id, asset.id)).bytes,
          9,
        ),
        everyElement(0),
      );
    },
  );

  test('a Goodnotes import with no ink found falls back to plain', () async {
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    bool noInk = false;
    final note =
        await DocumentImporter(
          rasterizer: FakePdfRasterizer(
            inspection: const PdfInspection(pageSizes: <Size>[Size(100, 100)]),
          ),
        ).importPdfAsNote(
          repository: repository,
          picked: PickedDocument(
            name: 'Plain.pdf',
            bytes: Uint8List.fromList(utf8.encode('%PDF-1.7 not goodnotes')),
          ),
          recoverGoodnotesInk: true,
          onNoInkRecovered: () => noInk = true,
        );

    expect(noInk, isTrue);
    final NoteContent content = await repository.loadNote(note.id);
    expect(content.pages.single.strokes, isEmpty);
    expect(content.pages.single.pdfSource, isNotNull);
  });

  test('inserting pages leaves a Goodnotes export as it is', () async {
    final _GoodnotesFixture fixture = _goodnotesFixture();
    final InMemoryNoteRepository repository = InMemoryNoteRepository();
    addTearDown(repository.dispose);
    final note = await repository.createNote();
    final NoteDocument document = NoteDocument();
    addTearDown(document.dispose);
    final FakePdfRasterizer rasterizer = FakePdfRasterizer(
      inspection: const PdfInspection(
        pageSizes: <Size>[Size(100, 100), Size(100, 100)],
      ),
    );

    await DocumentImporter(rasterizer: rasterizer).insertPdfPages(
      repository: repository,
      noteId: note.id,
      document: document,
      picked: PickedDocument(name: 'Goodnotes.pdf', bytes: fixture.pdf),
    );

    expect(document.pageCount, 3);
    expect(document.currentIndex, 1);
    expect(document.pages[1].ink.strokes, isEmpty);
    expect(document.pages[2].ink.strokes, isEmpty);
    final NoteAsset asset = (await repository.listAssets(note.id)).single;
    expect((await repository.readAsset(note.id, asset.id)).bytes, fixture.pdf);
  });

  test('ordinary PDFs bypass recovery', () async {
    final GoodnotesPdfRecovery? recovery = await const GoodnotesPdfRecoverer()
        .recover(
          bytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nnot-goodnotes')),
          pageSizes: const <Size>[Size(816, 1056)],
          config: const DocumentIoConfig(),
        );

    expect(recovery, isNull);
  });

  test(
    'PDF recovery carries pressure widths and removes only recovered texture',
    () async {
      final _GoodnotesFixture fixture = _goodnotesFixture(
        content: _pressureOverlay(curved: true, textured: true),
      );
      final GoodnotesPdfRecovery? recovery = await const GoodnotesPdfRecoverer()
          .recover(
            bytes: fixture.pdf,
            pageSizes: const <Size>[
              Size(100 * 4 / 3, 100 * 4 / 3),
              Size(100 * 4 / 3, 100 * 4 / 3),
            ],
            config: const DocumentIoConfig(),
          );
      expect(recovery, isNotNull);
      for (final List<Stroke> page in recovery!.pageStrokes) {
        expect(page, hasLength(1));
        expect(page.single.widths, hasLength(page.single.points.length));
        expect(
          page.single.widths!.reduce(math.max),
          greaterThan(page.single.widths!.reduce(math.min) * 2),
        );
      }
      expect(_decodedStream(recovery.backgroundPdf, 7), everyElement(0));
      expect(_decodedStream(recovery.backgroundPdf, 13), everyElement(0));
      expect(
        _decodedStream(recovery.backgroundPdf, 8),
        _decodedStream(fixture.pdf, 8),
      );
    },
  );

  test(
    'ambiguous dense branch networks retain their original pixels',
    () async {
      final _Overlay overlay = _rasterOverlay(
        (int x, int y) =>
            x >= 40 &&
            x <= 100 &&
            y >= 40 &&
            y <= 100 &&
            (x % 5 == 0 || y % 5 == 0),
      );
      final _GoodnotesFixture fixture = _goodnotesFixture(content: overlay);
      final GoodnotesPdfRecovery? recovery = await const GoodnotesPdfRecoverer()
          .recover(
            bytes: fixture.pdf,
            pageSizes: const <Size>[
              Size(100 * 4 / 3, 100 * 4 / 3),
              Size(100 * 4 / 3, 100 * 4 / 3),
            ],
            config: const DocumentIoConfig(),
          );
      expect(recovery, isNotNull);
      expect(recovery!.pageStrokes, everyElement(isEmpty));
      expect(_decodedStream(recovery.backgroundPdf, 7), overlay.alpha);
    },
  );
}

void _expectSmoothWidths(List<InkVector> points, List<double> widths) {
  for (int i = 1; i < widths.length; i++) {
    expect(
      (widths[i] - widths[i - 1]).abs(),
      lessThanOrEqualTo(0.35 * (points[i] - points[i - 1]).length + 1e-8),
    );
  }
}

class _Overlay {
  const _Overlay(this.width, this.height, this.rgb, this.alpha);
  final int width;
  final int height;
  final Uint8List rgb;
  final Uint8List alpha;
}

_Overlay _rasterOverlay(bool Function(int x, int y) contains) {
  const int size = 200;
  final Uint8List rgb = Uint8List(size * size * 3);
  final Uint8List alpha = Uint8List(size * size);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      if (!contains(x, y)) continue;
      final int at = y * size + x;
      rgb[at * 3] = 255;
      alpha[at] = 255;
    }
  }
  return _Overlay(size, size, rgb, alpha);
}

_Overlay _pressureOverlay({required bool curved, required bool textured}) {
  final _Overlay overlay = _rasterOverlay((int x, int y) {
    if (x < 25 || x > 175) return false;
    final double t = (x - 25) / 150;
    final double center = 100 + (curved ? 12 * math.sin(t * math.pi * 2) : 0);
    final double radius = 2 + 5 * math.pow(math.sin(t * math.pi), 2).toDouble();
    return (y - center).abs() <= radius;
  });
  if (textured) {
    for (int y = 0; y < overlay.height; y++) {
      for (int x = 0; x < overlay.width; x++) {
        final int at = y * overlay.width + x;
        if (overlay.alpha[at] == 0) continue;
        overlay.alpha[at] = (x % 4 == 0 && y % 4 == 0)
            ? 0
            : 50 + (x * 31 + y * 17) % 170;
      }
    }
  }
  return overlay;
}

_Overlay _testOverlay({bool withInk = true}) {
  const int width = 200;
  const int height = 200;
  final Uint8List rgb = Uint8List(width * height * 3);
  final Uint8List alpha = Uint8List(width * height);

  void pixel(int x, int y, int red, int green, int blue) {
    final int at = y * width + x;
    rgb
      ..[at * 3] = red
      ..[at * 3 + 1] = green
      ..[at * 3 + 2] = blue;
    alpha[at] = 255;
  }

  // A dense rectangular screenshot. Its white field connects everything in
  // the rectangle, so it must remain one fixed component.
  for (int y = 5; y <= 50; y++) {
    for (int x = 5; x <= 75; x++) {
      pixel(x, y, 255, 255, 255);
    }
  }
  // A separate, thick red pen line.
  for (int x = 110; withInk && x <= 175; x++) {
    final int y = 105 + (x - 110) ~/ 2;
    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        pixel(x + dx, y + dy, 255, 0, 0);
      }
    }
  }
  return _Overlay(width, height, rgb, alpha);
}

class _GoodnotesFixture {
  const _GoodnotesFixture(this.pdf, this.renderedPng);
  final Uint8List pdf;
  final Uint8List renderedPng;
}

_GoodnotesFixture _goodnotesFixture({bool withInk = true, _Overlay? content}) {
  final _Overlay overlay = content ?? _testOverlay(withInk: withInk);
  final Uint8List badgeRgb = Uint8List(36 * 6 * 3)
    ..fillRange(0, 36 * 6 * 3, 80);
  final Uint8List badgeAlpha = Uint8List(36 * 6)..fillRange(0, 36 * 6, 220);
  final List<Uint8List> objects = <Uint8List>[
    _plain('<</Pages 2 0 R/Type/Catalog>>'),
    _plain('<</Count 2/Kids[4 0 R 11 0 R]/Type/Pages>>'),
    _plain(
      '<</CreationDate(D:20261015155806)/Creator(PDFium)/Producer(PDFium)>>',
    ),
    _plain('<</MediaBox[0 0 100 100]/Parent 2 0 R/Resources 5 0 R/Type/Page>>'),
    _plain('<</XObject<</FXX2 8 0 R/FXX3 10 0 R>>>>'),
    _plain('<</Length 0>>stream\r\n\r\nendstream'),
    _imageObject(overlay.alpha, 200, 200, gray: true),
    _imageObject(overlay.rgb, 200, 200, mask: 7),
    _imageObject(badgeAlpha, 36, 6, gray: true),
    _imageObject(badgeRgb, 36, 6, mask: 9),
    _plain(
      '<</MediaBox[0 0 100 100]/Parent 2 0 R/Resources 12 0 R/Type/Page>>',
    ),
    _plain('<</XObject<</FXX2 14 0 R/FXX3 10 0 R>>>>'),
    _imageObject(overlay.alpha, 200, 200, gray: true),
    _imageObject(overlay.rgb, 200, 200, mask: 13),
  ];
  final BytesBuilder pdf = BytesBuilder();
  pdf.add(latin1.encode('%PDF-1.7\r\n%\u00a1\u00b3\u00c5\u00d7\r\n'));
  final List<int> offsets = <int>[0];
  for (int i = 0; i < objects.length; i++) {
    offsets.add(pdf.length);
    pdf
      ..add(latin1.encode('${i + 1} 0 obj\r\n'))
      ..add(objects[i])
      ..add(latin1.encode('\r\nendobj\r\n'));
  }
  final int xref = pdf.length;
  pdf.add(latin1.encode('xref\r\n0 ${objects.length + 1}\r\n'));
  pdf.add(latin1.encode('0000000000 65535 f\r\n'));
  for (final int offset in offsets.skip(1)) {
    pdf.add(latin1.encode('${offset.toString().padLeft(10, '0')} 00000 n\r\n'));
  }
  pdf.add(
    latin1.encode(
      'trailer\r\n<</Root 1 0 R/Info 3 0 R/Size ${objects.length + 1}>>\r\n'
      'startxref\r\n$xref\r\n%%EOF\r\n',
    ),
  );

  final image.Image rendered = image.Image(width: 200, height: 200);
  image.fill(rendered, color: image.ColorRgb8(255, 255, 255));
  for (int i = 0; i < overlay.alpha.length; i++) {
    if (overlay.alpha[i] == 0) continue;
    final int x = i % 200;
    final int y = i ~/ 200;
    rendered.setPixelRgba(
      x,
      y,
      overlay.rgb[i * 3],
      overlay.rgb[i * 3 + 1],
      overlay.rgb[i * 3 + 2],
      255,
    );
  }
  return _GoodnotesFixture(
    pdf.toBytes(),
    Uint8List.fromList(image.encodePng(rendered)),
  );
}

Uint8List _plain(String value) => Uint8List.fromList(latin1.encode(value));

Uint8List _decodedStream(Uint8List pdf, int object) {
  final String text = latin1.decode(pdf);
  final RegExpMatch match = RegExp(
    '(?:^|[\\r\\n])$object 0 obj\\s*',
  ).firstMatch(text)!;
  final int stream = text.indexOf('stream', match.end);
  final String dictionary = text.substring(match.end, stream);
  final int length = int.parse(
    RegExp(r'/Length\s+(\d+)').firstMatch(dictionary)!.group(1)!,
  );
  int start = stream + 6;
  if (pdf[start] == 13) start++;
  if (pdf[start] == 10) start++;
  return Uint8List.fromList(
    ZLibDecoder().convert(pdf.sublist(start, start + length)),
  );
}

Uint8List _imageObject(
  Uint8List pixels,
  int width,
  int height, {
  bool gray = false,
  int? mask,
}) {
  final Uint8List compressed = Uint8List.fromList(
    ZLibEncoder().convert(pixels),
  );
  final BytesBuilder object = BytesBuilder();
  object
    ..add(
      latin1.encode(
        '<</BitsPerComponent 8/ColorSpace/${gray ? 'DeviceGray' : 'DeviceRGB'}'
        '/Filter/FlateDecode/Height $height/Length ${compressed.length}'
        '${mask == null ? '' : '/SMask $mask 0 R'}'
        '/Subtype/Image/Type/XObject/Width $width>>stream\r\n',
      ),
    )
    ..add(compressed)
    ..add(latin1.encode('\r\nendstream'));
  return object.toBytes();
}
