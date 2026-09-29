import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

const String _text = '日月山川田目口中木本大小';
const String _punctuationText = '日月山川田目口中木本。大小';
const int _punctuationIndex = 10;
const GalLookupNormalizedRectV1 _search = GalLookupNormalizedRectV1(
  left: 0,
  top: 0,
  width: 1,
  height: 1,
);

GalCalibrationOcrAlignment _alignment() => GalCalibrationOcrAlignment(
  confidence: .99,
  lines: <GalCalibrationOcrMatchedLine>[
    GalCalibrationOcrMatchedLine(
      sourceStart: 0,
      sourceEnd: _text.length,
      cellCount: _text.length,
      lineIndex: 0,
      rect: const OcrRect(left: 22, top: 9, right: 284, bottom: 41),
      glyphs: <GalCalibrationOcrGlyph>[
        for (int i = 0; i < _text.length; i++)
          GalCalibrationOcrGlyph(
            sourceIndex: i,
            charLength: 1,
            cellOffset: i,
            lineIndex: 0,
            confidence: .99,
            // Biased CTC positions drift from actual pitch 22 and center 31.
            rect: OcrRect(
              left: 33 + i * 21.7,
              top: 9,
              right: 35 + i * 21.7,
              bottom: 41,
            ),
          ),
      ],
    ),
  ],
);

img.Image _strokes({bool dark = false}) {
  final img.Image image = img.Image(width: 305, height: 55);
  img.fill(
    image,
    color: dark ? img.ColorRgb8(220, 225, 230) : img.ColorRgb8(38, 53, 70),
  );
  final img.Color ink = dark
      ? img.ColorRgb8(20, 30, 40)
      : img.ColorRgb8(241, 235, 209);
  for (int i = 0; i < _text.length; i++) {
    final int left = 24 + i * 22;
    // Synthetic varied strokes with known bounding boxes, not font/OCR output.
    img.fillRect(image, x1: left, y1: 14, x2: left + 2, y2: 35, color: ink);
    img.fillRect(
      image,
      x1: left + 11,
      y1: 14,
      x2: left + 13,
      y2: 35,
      color: ink,
    );
    img.fillRect(
      image,
      x1: left,
      y1: 17 + i % 3 * 5,
      x2: left + 13,
      y2: 19 + i % 3 * 5,
      color: ink,
    );
  }
  return image;
}

GalCalibrationOcrAlignment _punctuationAlignment() =>
    GalCalibrationOcrAlignment(
      confidence: .99,
      lines: <GalCalibrationOcrMatchedLine>[
        GalCalibrationOcrMatchedLine(
          sourceStart: 0,
          sourceEnd: _punctuationText.length,
          cellCount: _punctuationText.length,
          lineIndex: 0,
          rect: const OcrRect(left: 22, top: 9, right: 308, bottom: 41),
          glyphs: <GalCalibrationOcrGlyph>[
            for (int i = 0; i < _punctuationText.length; i++)
              GalCalibrationOcrGlyph(
                sourceIndex: i,
                charLength: 1,
                cellOffset: i,
                lineIndex: 0,
                confidence: .99,
                rect: OcrRect(
                  left: 33 + i * 21.7,
                  top: 9,
                  right: 35 + i * 21.7,
                  bottom: 41,
                ),
              ),
          ],
        ),
      ],
    );

img.Image _punctuationStrokes({
  bool cropEdge = false,
  bool singlePixelNoise = false,
}) {
  final img.Image image = img.Image(width: 330, height: 55);
  img.fill(image, color: img.ColorRgb8(38, 53, 70));
  final img.Color ink = img.ColorRgb8(241, 235, 209);
  for (int i = 0; i < _punctuationText.length; i++) {
    final int left = 24 + i * 22;
    if (i == _punctuationIndex) continue;
    img.fillRect(image, x1: left, y1: 14, x2: left + 2, y2: 35, color: ink);
    img.fillRect(
      image,
      x1: left + 11,
      y1: 14,
      x2: left + 13,
      y2: 35,
      color: ink,
    );
    img.fillRect(
      image,
      x1: left,
      y1: 17 + i % 3 * 5,
      x2: left + 13,
      y2: 19 + i % 3 * 5,
      color: ink,
    );
  }
  const int punctuationLeft = 24 + _punctuationIndex * 22;
  if (singlePixelNoise) {
    img.fillRect(
      image,
      x1: punctuationLeft + 10,
      y1: 24,
      x2: punctuationLeft + 10,
      y2: 24,
      color: ink,
    );
  } else {
    img.fillRect(
      image,
      x1: punctuationLeft + 9,
      y1: cropEdge ? 9 : 30,
      x2: punctuationLeft + 12,
      y2: cropEdge ? 12 : 34,
      color: ink,
    );
  }
  return image;
}

GalCalibrationOcrAlignment _refine(img.Image image) =>
    refineGalCalibrationOcrGeometry((
      pngBytes: Uint8List.fromList(img.encodePng(image)),
      text: _text,
      searchRect: _search,
      alignment: _alignment(),
    ));

void main() {
  test('ordinary runs keep their actual origins across a narrow comma', () {
    const String text = '日月山川田、目口中木本大小';
    final img.Image image = img.Image(width: 330, height: 55);
    img.fill(image, color: img.ColorRgb8(38, 53, 70));
    final img.Color ink = img.ColorRgb8(241, 235, 209);
    for (int i = 0; i < text.length; i++) {
      final int left = 24 + i * 22 - (i > 5 ? 11 : 0);
      if (i == 5) {
        img.fillRect(
          image,
          x1: left + 2,
          y1: 30,
          x2: left + 4,
          y2: 34,
          color: ink,
        );
      } else {
        img.fillRect(image, x1: left, y1: 14, x2: left + 2, y2: 35, color: ink);
        img.fillRect(
          image,
          x1: left + 11,
          y1: 14,
          x2: left + 13,
          y2: 35,
          color: ink,
        );
        img.fillRect(
          image,
          x1: left,
          y1: 17 + i % 3 * 5,
          x2: left + 13,
          y2: 19 + i % 3 * 5,
          color: ink,
        );
      }
    }
    final GalCalibrationOcrAlignment result = refineGalCalibrationOcrGeometry((
      pngBytes: Uint8List.fromList(img.encodePng(image)),
      text: text,
      searchRect: _search,
      alignment: GalCalibrationOcrAlignment(
        confidence: .99,
        lines: [
          GalCalibrationOcrMatchedLine(
            sourceStart: 0,
            sourceEnd: text.length,
            cellCount: text.length,
            lineIndex: 0,
            rect: const OcrRect(left: 22, top: 9, right: 310, bottom: 41),
            glyphs: [
              for (int i = 0; i < text.length; i++)
                GalCalibrationOcrGlyph(
                  sourceIndex: i,
                  charLength: 1,
                  cellOffset: i,
                  lineIndex: 0,
                  confidence: .99,
                  rect: OcrRect(
                    left: 33 + i * 22.0 - (i > 5 ? 11 : 0),
                    top: 9,
                    right: 35 + i * 22.0 - (i > 5 ? 11 : 0),
                    bottom: 41,
                  ),
                ),
            ],
          ),
        ],
      ),
    ));
    final GalCalibrationOcrGlyph before = result.lines.single.glyphs[4];
    final GalCalibrationOcrGlyph after = result.lines.single.glyphs[6];
    expect(before.inkMeasured, isTrue);
    expect(after.inkMeasured, isTrue);
    expect(after.rect.centerX - before.rect.centerX, closeTo(33, 1));
  });
  for (final bool dark in <bool>[false, true]) {
    test(
      'pixel evidence removes CTC shift and drift with ${dark ? 'dark' : 'colored'} strokes',
      () {
        final GalCalibrationOcrAlignment refined = _refine(
          _strokes(dark: dark),
        );
        expect(refined.accepted, isTrue);
        final List<GalCalibrationOcrGlyph> measured = refined
            .lines
            .single
            .glyphs
            .where((GalCalibrationOcrGlyph g) => g.inkMeasured)
            .toList();
        expect(measured.length, greaterThanOrEqualTo(10));
        for (final GalCalibrationOcrGlyph g in measured) {
          expect(g.rect.centerX, closeTo(31 + g.cellOffset * 22, .6));
          expect(g.rect.centerY, closeTo(25, .6));
        }
      },
    );
  }
  test('uniform panel cannot pass as measured character geometry', () {
    final img.Image panel = img.Image(width: 305, height: 55);
    img.fill(panel, color: img.ColorRgb8(180, 200, 220));
    final GalCalibrationOcrAlignment result = _refine(panel);
    expect(result.accepted, isTrue);
    expect(result.lines.single.glyphs.any((g) => g.inkMeasured), isFalse);
  });
  test('repeated background tiles cannot explain distinct Hook characters', () {
    final img.Image panel = img.Image(width: 305, height: 55);
    img.fill(panel, color: img.ColorRgb8(38, 53, 70));
    for (int i = 0; i < _text.length; i++) {
      img.fillRect(
        panel,
        x1: 24 + i * 22,
        y1: 14,
        x2: 37 + i * 22,
        y2: 35,
        color: img.ColorRgb8(240, 230, 220),
      );
    }
    expect(
      _refine(panel).lines.single.glyphs.any((g) => g.inkMeasured),
      isFalse,
    );
  });

  test(
    'small punctuation never changes the glyph height from its ink bounds',
    () {
      final GalCalibrationOcrAlignment refined =
          refineGalCalibrationOcrGeometry((
            pngBytes: Uint8List.fromList(img.encodePng(_punctuationStrokes())),
            text: _punctuationText,
            searchRect: _search,
            alignment: _punctuationAlignment(),
          ));
      expect(refined.accepted, isTrue);
      final GalCalibrationOcrGlyph punctuation = refined.lines.single.glyphs
          .singleWhere(
            (GalCalibrationOcrGlyph glyph) =>
                glyph.sourceIndex == _punctuationIndex,
          );
      expect(punctuation.visualMeasured, isFalse);
      expect(punctuation.inkMeasured, isFalse);
      expect(
        punctuation.rect.height,
        _punctuationAlignment().lines.single.rect.height,
      );
      final List<GalCalibrationOcrGlyph> anchors = refined.lines.single.glyphs
          .where((GalCalibrationOcrGlyph glyph) => glyph.inkMeasured)
          .toList();
      expect(anchors.length, greaterThanOrEqualTo(10));
      expect(anchors.first.rect.centerX, closeTo(31, .6));
      expect(anchors[1].rect.centerX, closeTo(53, .6));
    },
  );

  test(
    'tiny noise and crop-edge punctuation do not become visual evidence',
    () {
      for (final img.Image image in <img.Image>[
        _punctuationStrokes(singlePixelNoise: true),
        _punctuationStrokes(cropEdge: true),
      ]) {
        final GalCalibrationOcrAlignment refined =
            refineGalCalibrationOcrGeometry((
              pngBytes: Uint8List.fromList(img.encodePng(image)),
              text: _punctuationText,
              searchRect: _search,
              alignment: _punctuationAlignment(),
            ));
        expect(refined.accepted, isTrue);
        expect(
          refined.lines.single.glyphs
              .singleWhere(
                (GalCalibrationOcrGlyph glyph) =>
                    glyph.sourceIndex == _punctuationIndex,
              )
              .visualMeasured,
          isFalse,
        );
      }
    },
  );

  test('content outside the explicit crop supplies no evidence', () {
    final GalCalibrationOcrAlignment result = refineGalCalibrationOcrGeometry((
      pngBytes: Uint8List.fromList(img.encodePng(_strokes())),
      text: _text,
      searchRect: const GalLookupNormalizedRectV1(
        left: 0,
        top: .75,
        width: 1,
        height: .25,
      ),
      alignment: _alignment(),
    ));
    expect(result.lines.single.glyphs.any((g) => g.inkMeasured), isFalse);
  });
  test('an edge-clipped anchor leaves the interior geometry usable', () {
    final GalCalibrationOcrAlignment result = refineGalCalibrationOcrGeometry((
      pngBytes: Uint8List.fromList(img.encodePng(_strokes())),
      text: _text,
      searchRect: const GalLookupNormalizedRectV1(
        left: .08,
        top: 0,
        width: .92,
        height: 1,
      ),
      alignment: _alignment(),
    ));
    expect(result.accepted, isTrue);
    expect(
      result.lines.single.glyphs
          .where((GalCalibrationOcrGlyph g) => g.sourceIndex > 0)
          .any((GalCalibrationOcrGlyph g) => g.inkMeasured),
      isTrue,
    );
  });
}
