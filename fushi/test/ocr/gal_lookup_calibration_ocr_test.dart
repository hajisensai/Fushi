import 'dart:typed_data';
import 'dart:ui';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

void main() {
  test(
    'one-cell row indent keeps opening quote and ordinary cells equal',
    () async {
      const List<String> rows = ['「あいうえおかきく', 'けこさしすせそ」'];
      final GalCalibrationOcrAlignment measured = alignGalCalibrationOcrLines(
        sourceText: rows.join(),
        lines: [
          _line(rows.first, top: 300),
          _line(rows.last, top: 348, indent: 1),
        ],
      );
      final GalCalibrationImageFit fit = await _fit(
        [_sample(rows.join())],
        [measured],
      );
      expect(fit.draft, isNotNull, reason: '${fit.reason}: ${fit.detail}');
      expect(
        fit.draft!.layout.cellGrid!.quotedContinuationIndent,
        closeTo(1, .001),
      );
      expect(fit.draft!.layout.characterAdvances, isEmpty);
      final GalCalibrationPreview boxes = await _preview(
        text: rows.join(),
        client: _sample(rows.join()).capture.referenceClient,
        rect: fit.draft!.rect,
        layout: fit.draft!.layout,
      );
      final Rect first = boxes.boxForIndex(0)!.rect;
      final Rect second = boxes.boxForIndex(rows.first.length)!.rect;
      expect(first.width, closeTo(second.width, 1e-9));
      expect(first.height, closeTo(second.height, 1e-9));
      expect(second.left - first.left, closeTo(40, .001));
    },
  );

  test(
    'negative continuation uses the same saved grid as its preview',
    () async {
      const List<String> rows = ['「あいうえお', 'かきくけこ」'];
      final GalCalibrationOcrAlignment aligned = alignGalCalibrationOcrLines(
        sourceText: rows.join(),
        lines: [
          _line(rows.first, top: 300, indent: 1),
          _line(rows.last, top: 348),
        ],
      );
      final GalCalibrationImageFit fit = await _fit(
        [_sample(rows.join())],
        [aligned],
      );
      expect(fit.reason, isNull, reason: '${fit.reason}: ${fit.detail}');
      expect(fit.draft!.layout.cellGrid!.continuationIndent, -1);
      expect(fit.draft!.rect.left, closeTo(.1, 1e-9));
    },
  );

  test(
    'unobserved ordinary prefix cannot publish a shifted runtime grid',
    () async {
      const List<String> rows = ['あいうえお', 'かきくけ'];
      final String text = '山川海空森${rows.join()}';
      final GalCalibrationImageFit fit = await _fit(
        [_sample(text)],
        [_alignment(rows, source: text)],
      );
      expect(fit.draft, isNull);
      expect(fit.detail, 'runtime_source_not_fully_observed');
    },
  );

  test(
    'single-token tail reports insufficient frozen-v24 correspondence',
    () async {
      const String first = '「あいうえおかきく―';
      const String text = '$first―」';
      final GalCalibrationOcrAlignment aligned = alignGalCalibrationOcrLines(
        sourceText: text,
        lines: [
          _line(first, top: 300),
          const GalCalibrationOcrLine(
            text: '-',
            score: .91,
            rect: OcrRect(left: 140, top: 348, right: 220, bottom: 384),
            tokens: [
              GalCalibrationOcrToken(
                '-',
                OcrRect(left: 156, top: 348, right: 164, bottom: 384),
                .23,
              ),
            ],
          ),
        ],
      );
      expect(aligned.accepted, isFalse);
      expect(aligned.reason, 'text_correspondence_insufficient');
    },
  );

  test('leading ASCII space keeps the common uniform cell grid', () async {
    const List<String> rows = ['（ あいうえおかきく', 'けこさしすせそ ）'];
    final GalCalibrationImageFit fit = await _fit(
      [_sample(rows.join())],
      [_spaceGeometry(rows, 1)],
    );
    expect(fit.draft, isNotNull, reason: '${fit.reason}: ${fit.detail}');
    expect(fit.draft!.rect.left, closeTo(.1, .001));
    expect(fit.draft!.layout.cellGrid!.continuationIndent, 0);
    expect(fit.draft!.layout.characterAdvances, isEmpty);
    final GalCalibrationPreview preview = await _preview(
      text: rows.join(),
      client: _sample(rows.join()).capture.referenceClient,
      rect: fit.draft!.rect,
      layout: fit.draft!.layout,
    );
    expect(preview.boxForIndex(0)!.rect.left, closeTo(100, .1));
    expect(preview.boxForIndex(1), isNull);
    expect(preview.boxForIndex(2)!.rect.left, closeTo(180, .1));
    expect(preview.boxForIndex(rows.first.length)!.rect.left, closeTo(100, .1));
    final int lastIndex = rows.join().length - 1;
    expect(preview.boxForIndex(lastIndex - 1), isNull);
    expect(
      preview.boxForIndex(0)!.rect.width,
      closeTo(preview.boxForIndex(2)!.rect.width, 1e-9),
    );
    expect(
      preview.boxForIndex(lastIndex)!.rect.width,
      closeTo(preview.boxForIndex(2)!.rect.width, 1e-9),
    );
  });
  for (final bool missingOpening in [true, false]) {
    test(
      missingOpening
          ? 'aligned body cannot hide a missing opening bracket'
          : 'aligned body cannot hide an end bracket on the wrong row',
      () async {
        const List<String> rows = ['（ あいうえおかきく', 'けこさしすせそ ）'];
        final GalCalibrationImageFit fit = await _fit(
          [_sample(rows.join())],
          [_spaceGeometry(rows, 1)],
          build:
              ({
                required String text,
                required GalLookupReferenceClientV1 client,
                required GalLookupNormalizedRectV1 rect,
                required GalLookupTextLayoutV1 layout,
              }) async {
                final GalCalibrationPreview valid = await _preview(
                  text: text,
                  client: client,
                  rect: rect,
                  layout: layout,
                );
                return GalCalibrationPreview(
                  boxes: [
                    for (final GalCalibrationBox box in valid.boxes)
                      if (!(missingOpening && box.charIndex == 0))
                        GalCalibrationBox(
                          box.charIndex,
                          box.charLength,
                          !missingOpening && box.charIndex == text.length - 1
                              ? box.rect.shift(
                                  Offset(
                                    0,
                                    layout
                                            .cellGrid!
                                            .lineAdvancePerClientHeight *
                                        client.heightPx,
                                  ),
                                )
                              : box.rect,
                        ),
                  ],
                );
              },
        );
        expect(fit.draft, isNull);
        expect(
          fit.reason,
          missingOpening ? 'ocr_geometry_conflict' : 'ocr_geometry_conflict',
        );
      },
    );
  }
  for (final double ratio in [1.0]) {
    test(
      'ASCII space measured between ordinary glyphs has advance $ratio',
      () async {
        const List<String> rows = ['あいうえ おかきく', 'けこさしすせそ'];
        final GalCalibrationImageFit fit = await _fit(
          [_sample(rows.join())],
          [_spaceGeometry(rows, ratio)],
        );
        expect(fit.draft, isNotNull, reason: fit.reason);
        expect(fit.draft!.rect.left, closeTo(.1, .001));
        expect(fit.draft!.layout.characterAdvances, isEmpty);
      },
    );
  }
  test(
    'compressed OCR whitespace cannot introduce custom character advances',
    () async {
      const List<String> rows = ['（  あいうえおかきく', 'けこさしすせそ）'];
      final GalCalibrationImageFit fit = await _fit(
        [_sample(rows.join())],
        [_spaceGeometry(rows, .25)],
      );
      expect(fit.draft, isNotNull, reason: fit.reason);
      expect(fit.draft!.layout.characterAdvances, isEmpty);
      final preview = await _preview(
        text: rows.join(),
        client: _sample(rows.join()).capture.referenceClient,
        rect: fit.draft!.rect,
        layout: fit.draft!.layout,
      );
      final pitch = fit.draft!.layout.cellGrid!.advancePerClientHeight * 500;
      expect(preview.accepted, isTrue);
      for (final box in preview.boxes) {
        expect(box.rect.width, closeTo(pitch, 1e-9));
      }
    },
  );
  test(
    'fitting retains its calibration slot and measured coordinate source',
    () async {
      final List<String> rows = ['あいうえおかきく', 'けこさしすせそ'];
      final GalCalibrationSample sample = _sample(rows.join());
      final GalCalibrationImageFit result = await fitGalCalibrationOcrGrid(
        GalLookupCalibrationDraft(
          rect: const GalLookupNormalizedRectV1(
            left: 0,
            top: 0,
            width: 1,
            height: 1,
          ),
          layout: const GalLookupTextLayoutV1(),
          slot: GalLookupCalibrationSlotV1.narration,
          samples: [sample],
          layoutReferenceClient: const GalLookupReferenceClientV1(
            widthPx: 800,
            heightPx: 600,
            dpi: 96,
          ),
        ),
        [_alignment(rows)],
        build: _preview,
      );
      expect(result.draft, isNotNull, reason: result.reason);
      expect(result.draft!.slot, GalLookupCalibrationSlotV1.narration);
      expect(
        result.draft!.layoutReferenceClient,
        sample.capture.referenceClient,
      );
    },
  );

  test('a button between detected rows cannot swallow a punctuation tail', () {
    const String first = '「あいうえおかきくけこさしすせそたちつてと！！';
    final GalCalibrationOcrAlignment result = alignGalCalibrationOcrLines(
      sourceText: '$first！』',
      lines: [
        _line(first, top: 300),
        _line('X', top: 307, shiftX: 1100),
        _line('！」', top: 350, indent: 1),
        _line('G', top: 362, shiftX: 800),
      ],
    );
    expect(result.accepted, isTrue);
    expect(result.lines, hasLength(2));
    final clean = alignGalCalibrationOcrLines(
      sourceText: '$first！』',
      lines: [_line(first, top: 300), _line('！」', top: 350, indent: 1)],
    );
    expect(
      result.lines.map((line) => (line.sourceStart, line.sourceEnd)),
      clean.lines.map((line) => (line.sourceStart, line.sourceEnd)),
    );
    expect(result.lines.last.rect.top, 350);
  });

  test(
    'one closing character alone cannot establish frozen-v24 correspondence',
    () {
      final GalCalibrationOcrAlignment result = alignGalCalibrationOcrLines(
        sourceText: '「あいうえおかきくけこ」',
        lines: [_line('「あいうえおかきくけこ', top: 300), _line('」', top: 350)],
      );
      expect(result.accepted, isFalse);
      expect(result.reason, 'text_correspondence_insufficient');
    },
  );

  test('a trailing advance icon never becomes a Hook character', () {
    final GalCalibrationOcrAlignment result = alignGalCalibrationOcrLines(
      sourceText: 'あいうえおかきくけこ。',
      lines: [_line('あいうえお', top: 300), _line('かきくけこ。▼', top: 348)],
    );
    expect(result.accepted, isTrue);
    expect(
      result.lines
          .expand((GalCalibrationOcrMatchedLine l) => l.glyphs)
          .map((GalCalibrationOcrGlyph g) => g.sourceIndex),
      everyElement(lessThan(11)),
    );
    expect(result.lines.last.cellCount, 6);
  });
  test(
    'short punctuation tail cannot bias ink-measured long-line pitch',
    () async {
      const String source = 'あいうえおかきくえた。';
      final GalCalibrationOcrAlignment raw = alignGalCalibrationOcrLines(
        sourceText: source,
        lines: [_line('あいうえおかきく', top: 300), _line('えた。', top: 348)],
      );
      final GalCalibrationOcrAlignment measured = GalCalibrationOcrAlignment(
        confidence: raw.confidence,
        lines: [
          for (final GalCalibrationOcrMatchedLine line in raw.lines)
            GalCalibrationOcrMatchedLine(
              sourceStart: line.sourceStart,
              sourceEnd: line.sourceEnd,
              cellCount: line.cellCount,
              lineIndex: line.lineIndex,
              ocrScore: line.ocrScore,
              rect: line.rect,
              glyphs: [
                for (final GalCalibrationOcrGlyph g in line.glyphs)
                  GalCalibrationOcrGlyph(
                    sourceIndex: g.sourceIndex,
                    charLength: g.charLength,
                    cellOffset: g.cellOffset,
                    lineIndex: g.lineIndex,
                    confidence: g.confidence,
                    matchKind: g.matchKind,
                    ocrTokenIndex: g.ocrTokenIndex,
                    syntheticOcrPosition: g.syntheticOcrPosition,
                    ocrConfidence: g.ocrConfidence,
                    ocrText: g.ocrText,
                    inkMeasured: line.lineIndex == 0,
                    rect: g.sourceIndex == source.length - 1
                        ? OcrRect(
                            left: g.rect.left - 12,
                            right: g.rect.right - 12,
                            top: g.rect.top,
                            bottom: g.rect.bottom,
                          )
                        : g.rect,
                  ),
              ],
            ),
        ],
      );
      final GalCalibrationImageFit fit = await _fit(
        [_sample(source)],
        [measured],
      );
      expect(fit.draft, isNotNull);
      expect(
        fit.draft!.layout.cellGrid!.advancePerClientHeight * 500,
        closeTo(40, .1),
      );
    },
  );
  for (final double tailShift in <double>[16, 40]) {
    test(
      'measured rows own geometry over short CTC tails ($tailShift)',
      () async {
        final List<String> rows = <String>['あいうえおかきく', 'けこさしすせそ', 'たち。'];
        final GalCalibrationOcrAlignment raw = _alignment(rows);
        final GalCalibrationOcrAlignment measured = GalCalibrationOcrAlignment(
          confidence: raw.confidence,
          lines: <GalCalibrationOcrMatchedLine>[
            for (final GalCalibrationOcrMatchedLine line in raw.lines)
              GalCalibrationOcrMatchedLine(
                sourceStart: line.sourceStart,
                sourceEnd: line.sourceEnd,
                cellCount: line.cellCount,
                lineIndex: line.lineIndex,
                ocrScore: line.ocrScore,
                rect: OcrRect(
                  left: line.rect.left,
                  right: line.rect.right,
                  top: line.rect.top + (line.lineIndex == 2 ? 10 : 0),
                  bottom: line.rect.bottom + (line.lineIndex == 2 ? 10 : 0),
                ),
                glyphs: <GalCalibrationOcrGlyph>[
                  for (final GalCalibrationOcrGlyph g in line.glyphs)
                    GalCalibrationOcrGlyph(
                      sourceIndex: g.sourceIndex,
                      charLength: g.charLength,
                      cellOffset: g.cellOffset,
                      lineIndex: g.lineIndex,
                      confidence: g.confidence,
                      matchKind: g.matchKind,
                      ocrTokenIndex: g.ocrTokenIndex,
                      syntheticOcrPosition: g.syntheticOcrPosition,
                      ocrConfidence: g.ocrConfidence,
                      ocrText: g.ocrText,
                      inkMeasured: line.lineIndex < 2,
                      rect: OcrRect(
                        left:
                            g.rect.left + (line.lineIndex == 2 ? tailShift : 0),
                        right:
                            g.rect.right +
                            (line.lineIndex == 2 ? tailShift : 0),
                        top: g.rect.top + (line.lineIndex == 2 ? 10 : 0),
                        bottom: g.rect.bottom + (line.lineIndex == 2 ? 10 : 0),
                      ),
                    ),
                ],
              ),
          ],
        );
        final GalCalibrationImageFit fit = await _fit(
          <GalCalibrationSample>[_sample(rows.join()), _sample('あい')],
          <GalCalibrationOcrAlignment>[
            measured,
            _alignment(['あい'], shiftX: 12),
          ],
        );
        // v24 keeps each observed row's Y geometry. This deliberately noisy
        // tail cannot be represented by one regular native grid.
        expect(fit.draft, isNull);
        expect(fit.reason, 'ocr_geometry_conflict');
      },
    );
  }
  test('aligns Hook text to OCR lines and keeps UTF-16 glyph offsets', () {
    final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
      sourceText: '「あいうえお」\nかきくけこ',
      lines: <GalCalibrationOcrLine>[
        const GalCalibrationOcrLine(
          text: '「あいうえお」',
          rect: OcrRect(left: 100, top: 200, right: 340, bottom: 240),
          score: 0.98,
        ),
        const GalCalibrationOcrLine(
          text: 'かきくけこ',
          rect: OcrRect(left: 120, top: 250, right: 320, bottom: 290),
          score: 0.96,
        ),
      ],
    );

    expect(alignment.accepted, isTrue);
    expect(alignment.lines, hasLength(2));
    expect(alignment.lines[0].glyphs, hasLength(7));
    expect(alignment.lines[1].glyphs, hasLength(5));
    expect(alignment.lines[0].glyphs.first.sourceIndex, 0);
    expect(alignment.lines[1].glyphs.first.sourceIndex, 8);
    expect(alignment.lines[0].glyphs.first.cellOffset, 0);
    expect(alignment.lines[1].glyphs.first.cellOffset, 0);
  });

  test('keeps geometry when OCR substitutes one character', () {
    final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
      sourceText: 'これはテストです',
      lines: <GalCalibrationOcrLine>[
        const GalCalibrationOcrLine(
          text: 'これはテス卜です',
          rect: OcrRect(left: 20, top: 30, right: 380, bottom: 70),
          score: 0.9,
        ),
      ],
    );

    expect(alignment.accepted, isTrue);
    expect(alignment.lines.single.glyphs, hasLength(8));
    expect(
      alignment.lines.single.glyphs,
      everyElement(
        isA<GalCalibrationOcrGlyph>().having(
          (g) => g.syntheticOcrPosition,
          'synthetic position',
          isTrue,
        ),
      ),
    );
  });

  test('ignores an unrelated name or button inside a rough crop', () {
    final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
      sourceText: 'これはテストです',
      lines: <GalCalibrationOcrLine>[
        const GalCalibrationOcrLine(
          text: '白崎',
          rect: OcrRect(left: 10, top: 10, right: 90, bottom: 40),
          score: 0.99,
        ),
        const GalCalibrationOcrLine(
          text: 'これはテストです',
          rect: OcrRect(left: 20, top: 100, right: 380, bottom: 140),
          score: 0.99,
        ),
        const GalCalibrationOcrLine(
          text: 'AUTO SKIP',
          rect: OcrRect(left: 400, top: 200, right: 580, bottom: 230),
          score: 0.99,
        ),
      ],
    );

    expect(alignment.accepted, isTrue);
    expect(alignment.lines, hasLength(1));
    expect(alignment.lines.single.rect.top, 100);
  });

  test('does not treat the full manga OCR pack as calibration dependency', () {
    expect(kGalCalibrationOcrModelManifest, hasLength(3));
    expect(
      kGalCalibrationOcrModelManifest
          .map((MangaOcrModelFile file) => file.expectedBytes)
          .reduce((int a, int b) => a + b),
      lessThan(32 * 1000 * 1000),
    );
  });

  test('model status counts ready files and resumable parts', () async {
    final Directory temp = await Directory.systemTemp.createTemp(
      'gal-calibration-ocr-test-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final List<MangaOcrModelFile> manifest = <MangaOcrModelFile>[
      const MangaOcrModelFile(
        fileName: 'det.onnx',
        url: 'http://127.0.0.1/det.onnx',
        expectedBytes: 10,
        role: MangaOcrModelRole.recognizer,
      ),
      const MangaOcrModelFile(
        fileName: 'rec.onnx',
        url: 'http://127.0.0.1/rec.onnx',
        expectedBytes: 20,
        role: MangaOcrModelRole.recognizer,
      ),
    ];
    await File('${temp.path}/det.onnx').writeAsBytes(List<int>.filled(10, 1));
    await File(
      '${temp.path}/rec.onnx.part',
    ).writeAsBytes(List<int>.filled(7, 1));
    final GalCalibrationOcrModelStore store = GalCalibrationOcrModelStore(
      directoryProvider: () async => temp,
      manifest: manifest,
    );

    final GalCalibrationOcrModelStatus status = await store.status();
    expect(status.ready, isFalse);
    expect(status.obtainedBytes, 17);
    expect(status.diskBytes, 17);
    expect(status.totalBytes, 30);
  });

  test(
    'normalizes OCR geometry and validates real preview coordinates',
    () async {
      final GalCalibrationImageFit fit = await _fit(
        [_sample('あいうえおかきくけ', scale: 1), _sample('あいうえおかきくけ', scale: 2)],
        [
          _alignment(['あいうえお', 'かきくけ']),
          _alignment(['あいうえお', 'かきくけ'], scale: 2),
        ],
      );
      expect(fit.reason, isNull);
      expect(fit.draft!.layout.cellGrid!.columns, 5);
      expect(fit.draft!.layout.cellGrid!.continuationIndent, 1);
      expect(
        fit.draft!.layout.cellGrid!.advancePerClientHeight,
        closeTo(.08, 1e-9),
      );
      expect(fit.draft!.rect.left, closeTo(.1, 1e-9));
      expect(fit.draft!.rect.top, closeTo(.6, 1e-9));
    },
  );

  for (final double ratio in <double>[.5, 1]) {
    test(
      'punctuation ink width $ratio cannot change uniform advance',
      () async {
        const String first = 'あいうえお、かきくけこ';
        const String second = 'さしすせそ';
        final GalCalibrationOcrAlignment raw = _alignment([first, second]);
        final GalCalibrationOcrAlignment measured = _withGeometry(
          raw,
          (GalCalibrationOcrGlyph g) => 0,
          punctuationIndex: 5,
          punctuationWidthRatio: ratio,
        );
        final GalCalibrationImageFit fit = await _fit(
          [_sample(first + second)],
          [measured],
        );
        expect(fit.reason, isNull);
        final GalLookupTextLayoutV1 layout = fit.draft!.layout;
        expect(layout.punctuationVisualBounds, isEmpty);
        expect(layout.characterAdvances, isEmpty);
        final GalCalibrationPreview result = await _preview(
          text: first + second,
          client: _sample(first + second).capture.referenceClient,
          rect: fit.draft!.rect,
          layout: layout,
        );
        final GalCalibrationBox comma = result.boxForIndex(5)!;
        expect(comma.rect.width, closeTo(40, .01));
        expect(comma.rect.height, result.boxForIndex(4)!.rect.height);
        expect(result.boxForIndex(6)!.rect.left, comma.rect.right);
      },
    );
  }

  test(
    'OCR may omit internal characters while Hook fills their grid cells',
    () async {
      const String first = 'あいうえおかきくけこ';
      const String second = 'さしすせそ';
      final GalCalibrationOcrLine full = _line(first, top: 300);
      final List<GalCalibrationOcrToken> kept = [
        for (int i = 0; i < full.tokens.length; i++)
          if (i != 2 && i != 4 && i != 7 && i != 8) full.tokens[i],
      ];
      final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
        sourceText: first + second,
        lines: [
          GalCalibrationOcrLine(
            text: kept.map((t) => t.text).join(),
            rect: full.rect,
            score: .98,
            tokens: kept,
          ),
          _line(second, top: 348, indent: 1),
        ],
      );
      expect(alignment.accepted, isTrue, reason: alignment.reason);
      final GalCalibrationImageFit fit = await _fit(
        [_sample(first + second)],
        [alignment],
      );
      expect(fit.reason, isNull);
      expect(fit.draft!.layout.cellGrid!.columns, first.length);
    },
  );

  test(
    'one displaced OCR anchor does not veto an otherwise aligned row',
    () async {
      const String first = 'あいうえおかきくけこ';
      const String second = 'さしすせそ';
      final GalCalibrationOcrAlignment raw = _alignment([first, second]);
      final GalCalibrationImageFit fit = await _fit(
        [_sample(first + second)],
        [_withGeometry(raw, (g) => g.sourceIndex == 4 ? 16 : 0)],
      );
      expect(fit.reason, isNull);
      expect(
        fit.draft!.layout.cellGrid!.advancePerClientHeight,
        closeTo(.08, .001),
      );
    },
  );

  test(
    'short samples do not shrink the body width or its vertical capacity',
    () async {
      final GalCalibrationImageFit fit = await _fit(
        [
          _sample('あいうえおかきくけ'),
          _sample('あいう'),
          _sample('あい'),
          _sample('あいうえおかきくけさしす', validation: true),
        ],
        [
          _alignment(['あいうえお', 'かきくけ']),
          _alignment(['あいう']),
          _alignment(['あい']),
          _alignment(['あいうえお', 'かきくけ', 'さしす']),
        ],
      );
      expect(fit.reason, isNull);
      expect(fit.draft!.layout.cellGrid!.columns, 5);
      expect(fit.draft!.rect.width, greaterThanOrEqualTo(.2));
      expect(fit.draft!.rect.bottom, closeTo(1, 1e-9));
    },
  );

  test(
    'rough bottom edge expands to a full row without fitting holdout geometry',
    () async {
      final draft = GalLookupCalibrationDraft(
        rect: const GalLookupNormalizedRectV1(
          left: 0,
          top: .6,
          width: 1,
          height: .26,
        ),
        layout: const GalLookupTextLayoutV1(),
        samples: [
          _sample('あいうえおかきくけ'),
          _sample('あいうえおかきくけさしす', validation: true),
        ],
      );
      final fit = await fitGalCalibrationOcrGrid(draft, [
        _alignment(['あいうえお', 'かきくけ']),
        _alignment(['あいうえお', 'かきくけ', 'さしす']),
      ], build: _preview);
      expect(fit.reason, isNull);
      expect(fit.draft!.rect.bottom, greaterThanOrEqualTo(.864));
    },
  );

  test(
    'learns one hanging closing punctuation cell from measured rows',
    () async {
      final fit = await _fit(
        [_sample('「あいうえおかきく」')],
        [
          _alignment(['「あいうえ', 'おかきく」']),
        ],
      );
      expect(fit.reason, isNull);
      expect(fit.draft!.layout.cellGrid!.columns, 5);
      expect(fit.draft!.layout.cellGrid!.hangingPunctuation, isTrue);
      expect(fit.draft!.rect.width, greaterThanOrEqualTo(.24));
    },
  );

  test('does not accept arbitrary extra text as hanging punctuation', () async {
    final fit = await _fit(
      [_sample('あいうえおかきくけこ')],
      [
        _alignment(['あいうえお', 'かきくけこ']),
      ],
    );
    expect(fit.reason, 'ocr_geometry_conflict');
  });

  test(
    'small kana may hang at a proven line end under Japanese kinsoku',
    () async {
      final fit = await _fit(
        [_sample('あいうえおかきくけ'), _sample('あいうえおょかきく')],
        [
          _alignment(['あいうえお', 'かきくけ']),
          _alignment(['あいうえおょ', 'かきく']),
        ],
      );
      expect(fit.draft, isNotNull);
      expect(fit.draft!.layout.cellGrid!.columns, 5);
      expect(fit.draft!.layout.cellGrid!.hangingPunctuation, isTrue);
    },
  );

  test('held-out geometry rejects a shifted row even when text fits', () async {
    final GalCalibrationImageFit fit = await _fit(
      [_sample('あいうえおかきくけ'), _sample('あいうえおかきくけ', validation: true)],
      [
        _alignment(['あいうえお', 'かきくけ']),
        _alignment(['あいうえお', 'かきくけ'], shiftX: 40),
      ],
    );
    expect(fit.draft, isNull);
    expect(fit.reason, 'ocr_geometry_conflict');
    expect(fit.sampleIndex, 1);
  });

  test('held-out line wrapping is checked against native preview', () async {
    final GalCalibrationImageFit fit = await _fit(
      [_sample('あいうえおかきくけ'), _sample('あいうえおかきくけ', validation: true)],
      [
        _alignment(['あいうえお', 'かきくけ']),
        _alignment(['あいうえ', 'おかきくけ']),
      ],
    );
    expect(fit.reason, 'ocr_geometry_conflict');
    expect(fit.sampleIndex, 1);
  });

  test(
    'Hook newlines use the selected region without being called a short sentence',
    () async {
      final GalCalibrationImageFit fit = await _fit(
        [_sample('あいうえお\nかきくけ')],
        [
          _alignment(['あいうえお', 'かきくけ'], source: 'あいうえお\nかきくけ'),
        ],
      );
      expect(fit.reason, isNull);
      expect(fit.draft!.layout.cellGrid!.columns, greaterThanOrEqualTo(5));
    },
  );
  test('Hook rows permit a shifted but index-correct editable grid', () async {
    const String hard = 'あいうえお\nかきくけ';
    const String soft = 'あいうえおかきくけ';
    Future<GalCalibrationPreview> shifted({
      required String text,
      required GalLookupReferenceClientV1 client,
      required GalLookupNormalizedRectV1 rect,
      required GalLookupTextLayoutV1 layout,
    }) async {
      final GalCalibrationPreview base = await _preview(
        text: text,
        client: client,
        rect: rect,
        layout: layout,
      );
      return GalCalibrationPreview(
        boxes: [
          for (final GalCalibrationBox box in base.boxes)
            GalCalibrationBox(
              box.charIndex,
              box.charLength,
              box.rect.translate(box.charIndex >= 6 ? 8 : 0, 0),
            ),
        ],
      );
    }

    final GalCalibrationImageFit hardFit = await _fit(
      [_sample(hard)],
      [
        _alignment(['あいうえお', 'かきくけ'], source: hard),
      ],
      build: shifted,
    );
    expect(
      hardFit.draft,
      isNotNull,
      reason: '${hardFit.reason}: ${hardFit.detail}',
    );
    final GalCalibrationImageFit softFit = await _fit(
      [_sample(soft)],
      [
        _alignment(['あいうえお', 'かきくけ'], source: soft),
      ],
      build: shifted,
    );
    expect(softFit.detail, 'runtime_grid_differs_from_fitted_cells');
  });

  test('Hook rows still reject a native break inside one source row', () async {
    const String hard = 'あいうえお\nかきくけ';
    final GalCalibrationImageFit fit = await _fit(
      [_sample(hard)],
      [
        _alignment(['あいうえお', 'かきくけ'], source: hard),
      ],
      build:
          ({
            required String text,
            required GalLookupReferenceClientV1 client,
            required GalLookupNormalizedRectV1 rect,
            required GalLookupTextLayoutV1 layout,
          }) async {
            final GalCalibrationPreview base = await _preview(
              text: text,
              client: client,
              rect: rect,
              layout: layout,
            );
            return GalCalibrationPreview(
              boxes: [
                for (final GalCalibrationBox box in base.boxes)
                  GalCalibrationBox(
                    box.charIndex,
                    box.charLength,
                    box.rect.translate(0, box.charIndex == 2 ? 48 : 0),
                  ),
              ],
            );
          },
    );
    expect(fit.detail, 'runtime_row_breaks_differ_from_hook');
  });

  test(
    'a longer second Hook row has one editable cell per character',
    () async {
      const String first = 'あいうえおかきくけこ';
      const String second = 'さしすせそたちつてとなにぬねのはひ';
      const String text = '$first\n$second';
      final GalCalibrationImageFit fit = await _fit(
        [_sample(text)],
        [
          _alignment([first, second], source: text),
        ],
      );
      expect(fit.draft, isNotNull, reason: '${fit.reason}: ${fit.detail}');
      final GalCalibrationPreview preview = await _preview(
        text: text,
        client: _sample(text).capture.referenceClient,
        rect: fit.draft!.rect,
        layout: fit.draft!.layout,
      );
      expect(preview.boxes.length, first.length + second.length);
      expect(preview.boxForIndex(first.length), isNull);
      expect(
        preview.boxForIndex(first.length + 1)!.rect.top,
        greaterThan(preview.boxForIndex(0)!.rect.top),
      );
    },
  );

  test(
    'unobserved wrap spaces keep the next row at its fitted origin',
    () async {
      const List<String> rows = ['あいうえお', 'かきくけ'];
      for (final String gap in [' ', '  ', '\u3000']) {
        final String text = rows.join(gap);
        final GalCalibrationImageFit fit = await _fit(
          [_sample(text)],
          [_alignment(rows, source: text)],
        );
        expect(fit.reason, isNull, reason: '${fit.reason}: ${fit.detail}');
        expect(fit.draft!.layout.cellGrid!.trimWrapWhitespace, isTrue);
        final GalCalibrationPreview preview = await _preview(
          text: text,
          client: _sample(text).capture.referenceClient,
          rect: fit.draft!.rect,
          layout: fit.draft!.layout,
        );
        expect(
          preview.boxForIndex(5 + gap.length)!.rect.left,
          closeTo(140, .1),
        );
      }
    },
  );

  test('unequal hard-break rows do not impose a soft-wrap capacity', () async {
    const List<String> rows = ['あいうえお', 'かきくけこさしすせそ', 'たちつてと'];
    for (final String separator in ['\n', '\r\n']) {
      final String text = rows.join(separator);
      final GalCalibrationImageFit fit = await _fit(
        [_sample(text)],
        [_alignment(rows, source: text)],
      );
      expect(fit.reason, isNull, reason: '${fit.reason}: ${fit.detail}');
      expect(fit.draft!.layout.cellGrid!.columns, greaterThanOrEqualTo(11));
    }
  });

  // Runtime wrapping and row limits for this mode are native behavior and are
  // covered by attached_text_layout_test.cpp; here the fitter must only prove
  // the mode from Hook-only rows and never infer it without row evidence.
  test('Hook-only rows mark the profile as following Hook breaks', () async {
    const List<String> rows = ['あいうえお', 'かきくけ'];
    for (final String separator in ['\n', '\r\n']) {
      final String text = rows.join(separator);
      final GalCalibrationImageFit fit = await _fit(
        [_sample(text)],
        [_alignment(rows, source: text)],
      );
      expect(fit.draft, isNotNull, reason: '${fit.reason}: ${fit.detail}');
      expect(fit.draft!.layout.cellGrid!.explicitLineBreaks, isTrue);
    }
  });

  test('any soft-wrapped training row rules out Hook-only breaks', () async {
    const List<String> softRows = ['あいうえおかきく', 'けこさしす'];
    const List<String> hardRows = ['たちつてと', 'なにぬね'];
    final String hard = hardRows.join('\n');
    final GalCalibrationImageFit fit = await _fit(
      [_sample(softRows.join()), _sample(hard)],
      [_alignment(softRows), _alignment(hardRows, source: hard)],
    );
    expect(fit.draft, isNotNull, reason: '${fit.reason}: ${fit.detail}');
    expect(fit.draft!.layout.cellGrid!.explicitLineBreaks, isFalse);
  });

  test('soft-wrapped rows keep wrapping at the calibrated width', () async {
    const List<String> rows = ['あいうえおかきく', 'けこさしす'];
    final GalCalibrationImageFit fit = await _fit(
      [_sample(rows.join())],
      [_alignment(rows)],
    );
    expect(fit.draft, isNotNull, reason: '${fit.reason}: ${fit.detail}');
    expect(fit.draft!.layout.cellGrid!.explicitLineBreaks, isFalse);
  });

  test(
    'explicit newlines and surrogate offsets survive native validation',
    () async {
      final GalCalibrationImageFit fit = await _fit(
        [_sample('あいうえおかきくけ'), _sample('😀いう\r\nかきく', validation: true)],
        [
          _alignment(['あいうえお', 'かきくけ']),
          _alignment(['😀いう', 'かきく'], source: '😀いう\r\nかきく'),
        ],
      );
      expect(fit.reason, isNull);
    },
  );

  test('Hook tabs advance one cell just like the native renderer', () async {
    const String source = 'あいうえお\tかきくけこ\nさしすせそたちつ';
    final GalCalibrationImageFit fit = await _fit(
      [_sample(source)],
      [_alignment(source.split('\n'), source: source)],
    );
    expect(fit.draft, isNotNull, reason: fit.reason);
    expect(
      fit.draft!.layout.cellGrid!.advancePerClientHeight,
      closeTo(.08, 1e-9),
    );
    expect(fit.draft!.layout.characterAdvances, isEmpty);
  });

  test(
    'recognition positions prevent a missing OCR character shifting the row',
    () async {
      final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
        sourceText: 'あいうえおかきくけ',
        lines: [
          _line('あいえお', top: 300, offsets: [0, 1, 3, 4]),
          _line('かきくけ', top: 348, indent: 1),
        ],
      );
      expect(alignment.accepted, isTrue);
      final GalCalibrationImageFit fit = await _fit(
        [_sample('あいうえおかきくけ')],
        [alignment],
      );
      expect(fit.reason, isNull);
      expect(
        fit.draft!.layout.cellGrid!.advancePerClientHeight,
        closeTo(.08, 1e-9),
      );
    },
  );

  test('combining marks stay in one UTF-16 glyph cluster', () {
    final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
      sourceText: 'か\u3099e\u0301😀あ',
      lines: [_line('か\u3099e\u0301😀あ', top: 300)],
    );
    // Kana U+3099 is not currently a supported native combining mark; the
    // Latin combining mark is, and must include both UTF-16 units.
    expect(alignment.accepted, isTrue);
    expect(
      alignment.lines.single.glyphs
          .firstWhere((g) => g.sourceIndex == 2)
          .charLength,
      2,
    );
    expect(
      alignment.lines.single.glyphs
          .firstWhere((g) => g.sourceIndex == 4)
          .charLength,
      2,
    );
  });

  test(
    'joins separated detections on the same row without losing x positions',
    () async {
      final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
        sourceText: 'あいうえおかきくけ',
        lines: [
          _line('あいう', top: 300),
          _line('えお', top: 302, indent: 3),
          _line('かきくけ', top: 348, indent: 1),
        ],
      );
      expect(alignment.accepted, isTrue);
      expect(alignment.lines, hasLength(2));
      expect(alignment.lines.first.glyphs[3].rect.centerX, 240);
      final GalCalibrationImageFit fit = await _fit(
        [_sample('あいうえおかきくけ')],
        [alignment],
      );
      expect(fit.reason, isNull);
    },
  );

  test('overlapping detector margins still form a single row', () {
    final alignment = alignGalCalibrationOcrLines(
      sourceText: 'あいうえお',
      lines: [
        _line('あいう', top: 300),
        _line('えお', top: 301, indent: 3, shiftX: -3),
      ],
    );
    expect(alignment.accepted, isTrue);
    expect(alignment.lines, hasLength(1));
  });

  test(
    'detector confidence and recognition confidence have separate roles',
    () {
      final row = _line('あいうえお', top: 300);
      final alignment = alignGalCalibrationOcrLines(
        sourceText: row.text,
        lines: [
          GalCalibrationOcrLine(
            text: row.text,
            rect: row.rect,
            score: .47,
            tokens: row.tokens,
          ),
        ],
      );
      expect(alignment.accepted, isTrue);
    },
  );

  test('text matching does not discard low-confidence position evidence', () {
    final row = _line('あいうえお', top: 300);
    final alignment = alignGalCalibrationOcrLines(
      sourceText: row.text,
      lines: [
        GalCalibrationOcrLine(
          text: row.text,
          rect: row.rect,
          score: .99,
          tokens: [
            row.tokens.first,
            for (final token in row.tokens.skip(1))
              GalCalibrationOcrToken(token.text, token.rect, 0),
          ],
        ),
      ],
    );
    expect(alignment.accepted, isTrue);
  });

  test(
    'keeps a repeated dialogue candidate with sparse distributed positions',
    () {
      const String first = '「かきゃっかきゃっかきゃっかきゃっかきゃっ！！';
      const String second = '！」」』';
      final List<GalCalibrationOcrLine> lines = <GalCalibrationOcrLine>[
        _sparsePositionLine(first, top: 300),
        _sparsePositionLine(second, top: 348),
      ];

      final GalCalibrationOcrAlignment alignment = alignGalCalibrationOcrLines(
        sourceText: '$first\n$second',
        lines: lines,
      );

      expect(alignment.accepted, isTrue);
      expect(alignment.confidence, lessThan(.65));
      expect(alignment.lines, hasLength(2));
    },
  );

  test('detector unclip margins cannot create overlapping hit rows', () async {
    final lines = [
      _line('あいうえお', top: 300),
      _line('かきくけ', top: 348, indent: 1),
    ];
    final alignment = alignGalCalibrationOcrLines(
      sourceText: lines.map((l) => l.text).join(),
      lines: [
        for (final row in lines)
          GalCalibrationOcrLine(
            text: row.text,
            score: row.score,
            tokens: row.tokens,
            rect: OcrRect(
              left: row.rect.left,
              right: row.rect.right,
              top: row.rect.top - 12,
              bottom: row.rect.bottom + 12,
            ),
          ),
      ],
    );
    final fit = await _fit([_sample('あいうえおかきくけ')], [alignment]);
    expect(fit.draft, isNull);
    expect(fit.reason, 'ocr_geometry_conflict');
    expect(fit.detail, 'runtime_grid_not_representable');
  });

  test(
    'text correspondence permits weak OCR and locally observed source spans',
    () {
      expect(
        alignGalCalibrationOcrLines(
          sourceText: 'あいうえおかきくけ',
          lines: [
            const GalCalibrationOcrLine(
              text: 'あいうえおかきくけ',
              rect: OcrRect(left: 0, top: 0, right: 360, bottom: 36),
              score: .1,
            ),
          ],
        ).accepted,
        isTrue,
      );
      expect(
        alignGalCalibrationOcrLines(
          sourceText: 'あいうえおかきくけ',
          lines: [_line('あいう', top: 300)],
        ).accepted,
        isTrue,
      );
    },
  );
}

GalCalibrationOcrAlignment _spaceGeometry(List<String> rows, double ratio) {
  final String source = rows.join();
  final GalCalibrationOcrAlignment raw = alignGalCalibrationOcrLines(
    sourceText: source,
    lines: [
      for (int i = 0; i < rows.length; i++) _line(rows[i], top: 300 + i * 48),
    ],
  );
  return GalCalibrationOcrAlignment(
    confidence: raw.confidence,
    lines: [
      for (final GalCalibrationOcrMatchedLine line in raw.lines)
        GalCalibrationOcrMatchedLine(
          sourceStart: line.sourceStart,
          sourceEnd: line.sourceEnd,
          cellCount: line.cellCount,
          lineIndex: line.lineIndex,
          ocrScore: line.ocrScore,
          rect: line.rect,
          glyphs: [
            for (final GalCalibrationOcrGlyph g in line.glyphs)
              for (final double shift in [
                rows[line.lineIndex]
                        .substring(0, g.cellOffset)
                        .split(' ')
                        .length -
                    1.0,
              ])
                GalCalibrationOcrGlyph(
                  sourceIndex: g.sourceIndex,
                  charLength: g.charLength,
                  cellOffset: g.cellOffset,
                  lineIndex: g.lineIndex,
                  confidence: g.confidence,
                  matchKind: g.matchKind,
                  ocrTokenIndex: g.ocrTokenIndex,
                  syntheticOcrPosition: g.syntheticOcrPosition,
                  ocrConfidence: g.ocrConfidence,
                  ocrText: g.ocrText,
                  inkMeasured: RegExp(
                    r'^[あ-ん]$',
                  ).hasMatch(source[g.sourceIndex]),
                  rect: OcrRect(
                    left: g.rect.left + shift * (ratio - 1) * 40,
                    right: g.rect.right + shift * (ratio - 1) * 40,
                    top: g.rect.top,
                    bottom: g.rect.bottom,
                  ),
                ),
          ],
        ),
    ],
  );
}

GalCalibrationOcrAlignment _withGeometry(
  GalCalibrationOcrAlignment base,
  double Function(GalCalibrationOcrGlyph) shift, {
  int? punctuationIndex,
  double punctuationWidthRatio = 1,
}) => GalCalibrationOcrAlignment(
  confidence: base.confidence,
  lines: [
    for (final GalCalibrationOcrMatchedLine line in base.lines)
      GalCalibrationOcrMatchedLine(
        sourceStart: line.sourceStart,
        sourceEnd: line.sourceEnd,
        cellCount: line.cellCount,
        lineIndex: line.lineIndex,
        ocrScore: line.ocrScore,
        rect: line.rect,
        glyphs: [
          for (final GalCalibrationOcrGlyph g in line.glyphs)
            GalCalibrationOcrGlyph(
              sourceIndex: g.sourceIndex,
              charLength: g.charLength,
              cellOffset: g.cellOffset,
              lineIndex: g.lineIndex,
              confidence: g.confidence,
              matchKind: g.matchKind,
              ocrTokenIndex: g.ocrTokenIndex,
              syntheticOcrPosition: g.syntheticOcrPosition,
              ocrConfidence: g.ocrConfidence,
              ocrText: g.ocrText,
              inkMeasured: g.sourceIndex != punctuationIndex,
              rect: OcrRect(
                left:
                    g.rect.left +
                    shift(g) +
                    (g.sourceIndex == punctuationIndex
                        ? g.rect.width * (1 - punctuationWidthRatio) / 2
                        : 0),
                top: g.rect.top,
                right:
                    g.rect.right +
                    shift(g) -
                    (g.sourceIndex == punctuationIndex
                        ? g.rect.width * (1 - punctuationWidthRatio) / 2
                        : 0),
                bottom: g.rect.bottom,
              ),
            ),
        ],
      ),
  ],
);

GalCalibrationOcrLine _line(
  String text, {
  required double top,
  double scale = 1,
  int indent = 0,
  double shiftX = 0,
  List<int>? offsets,
}) {
  final List<String> chars = text.runes.map(String.fromCharCode).toList();
  return GalCalibrationOcrLine(
    text: text,
    score: .99,
    rect: OcrRect(
      left: (100 + indent * 40 + shiftX) * scale,
      top: top * scale,
      right:
          (100 +
              (indent + (offsets?.last ?? chars.length - 1) + 1) * 40 +
              shiftX) *
          scale,
      bottom: (top + 36) * scale,
    ),
    tokens: [
      for (int i = 0; i < chars.length; i++)
        GalCalibrationOcrToken(
          chars[i],
          OcrRect(
            left: (100 + (indent + (offsets?[i] ?? i)) * 40 + shiftX) * scale,
            right:
                (100 + (indent + (offsets?[i] ?? i) + 1) * 40 + shiftX) * scale,
            top: top * scale,
            bottom: (top + 36) * scale,
          ),
          .99,
        ),
    ],
  );
}

GalCalibrationOcrLine _sparsePositionLine(String text, {required double top}) {
  final GalCalibrationOcrLine line = _line(text, top: top);
  final int visible = line.tokens.length;
  return GalCalibrationOcrLine(
    text: line.text,
    rect: line.rect,
    score: line.score,
    tokens: <GalCalibrationOcrToken>[
      for (int i = 0; i < visible; i++)
        GalCalibrationOcrToken(
          line.tokens[i].text,
          line.tokens[i].rect,
          (i < 6 || i >= visible - 6) ? .42 : 0,
        ),
    ],
  );
}

GalCalibrationOcrAlignment _alignment(
  List<String> rows, {
  double scale = 1,
  double shiftX = 0,
  String? source,
}) => alignGalCalibrationOcrLines(
  sourceText: source ?? rows.join(),
  lines: [
    for (int i = 0; i < rows.length; i++)
      _line(
        rows[i],
        top: 300 + i * 48,
        scale: scale,
        indent: i == 0 ? 0 : 1,
        shiftX: shiftX,
      ),
  ],
);

GalCalibrationSample _sample(
  String text, {
  double scale = 1,
  bool validation = false,
}) => GalCalibrationSample(
  validation: validation,
  capture: GalLookupCalibrationCapture(
    sourceText: text,
    pngBytes: Uint8List.fromList([1]),
    referenceClient: GalLookupReferenceClientV1(
      widthPx: (1000 * scale).round(),
      heightPx: (500 * scale).round(),
      dpi: 96,
    ),
    exePath: 'game.exe',
    exeSha256: 'a' * 64,
    sessionEpoch: 1,
    occurrenceId: 'occurrence',
    targetHwnd: 1,
    capturedAt: DateTime.utc(2026),
    selectedThreadKey: 'thread',
  ),
);

Future<GalCalibrationImageFit> _fit(
  List<GalCalibrationSample> samples,
  List<GalCalibrationOcrAlignment> alignments, {
  GalCalibrationPreviewBuilder build = _preview,
}) => fitGalCalibrationOcrGrid(
  GalLookupCalibrationDraft(
    rect: const GalLookupNormalizedRectV1(left: 0, top: 0, width: 1, height: 1),
    layout: const GalLookupTextLayoutV1(),
    samples: samples,
  ),
  alignments,
  build: build,
);

// Independent preview double implements the native grid's row/UTF-16 contract,
// so acceptance requires actual coordinate agreement rather than a dummy box.
Future<GalCalibrationPreview> _preview({
  required String text,
  required GalLookupReferenceClientV1 client,
  required GalLookupNormalizedRectV1 rect,
  required GalLookupTextLayoutV1 layout,
}) async {
  final GalLookupCellGridV1 grid = layout.cellGrid!;
  final double pitch = grid.advancePerClientHeight * client.heightPx;
  final double height = grid.cellHeightPerClientHeight * client.heightPx;
  final double advance = grid.lineAdvancePerClientHeight * client.heightPx;
  final double capacity = grid.lineWidthInCells ?? grid.columns.toDouble();
  if (capacity * pitch > rect.width * client.widthPx + .5) {
    return const GalCalibrationPreview(boxes: [], reason: 'overflow');
  }
  final double indent = text.startsWith('「') || text.startsWith('『')
      ? grid.quotedContinuationIndent
      : grid.continuationIndent;
  final List<GalCalibrationBox> boxes = [];
  int row = 0, index = 0;
  double column = indent < 0 ? -indent : 0;
  final Map<int, double> widths = {
    for (final a in layout.characterAdvances) a.codePoint: a.advanceRatio,
  };
  int previous = 0;
  bool pendingWrapSpace = false;
  for (final int rune in text.runes) {
    final int length = String.fromCharCode(rune).length;
    if (rune == 13 || rune == 10) {
      pendingWrapSpace = false;
      if (rune != 10 || previous != 13) {
        row++;
        column = indent > 0 ? indent : 0;
      }
    } else {
      final double characterWidth = widths[rune] ?? 1;
      final bool whitespace = rune == 32 || rune == 9 || rune == 0x3000;
      if (grid.trimWrapWhitespace &&
          whitespace &&
          (pendingWrapSpace || column + characterWidth > capacity + 1e-6)) {
        pendingWrapSpace = true;
        index += length;
        previous = rune;
        continue;
      }
      if (pendingWrapSpace) {
        row++;
        column = indent > 0 ? indent : 0;
        pendingWrapSpace = false;
      }
      if (!grid.explicitLineBreaks &&
          column + characterWidth > capacity + 1e-6 &&
          !(grid.hangingPunctuation &&
              (column - capacity).abs() < 1e-6 &&
              '」』）)]｝}】〕〉》、。，．！？!?ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ'.contains(
                String.fromCharCode(rune),
              ))) {
        row++;
        column = indent > 0 ? indent : 0;
      }
      final Rect box = Rect.fromLTWH(
        rect.left * client.widthPx + column * pitch,
        rect.top * client.heightPx + row * advance,
        pitch * characterWidth,
        height,
      );
      if (box.bottom >
          (grid.explicitLineBreaks
                  ? client.heightPx
                  : rect.bottom * client.heightPx) +
              .5) {
        return const GalCalibrationPreview(boxes: [], reason: 'overflow');
      }
      if (String.fromCharCode(rune).trim().isNotEmpty) {
        boxes.add(GalCalibrationBox(index, length, box));
      }
      column += characterWidth;
    }
    index += length;
    previous = rune;
  }
  return GalCalibrationPreview(boxes: boxes);
}
