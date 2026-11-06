import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/ocr/ppocr_line_detector.dart';
import 'package:fushi_engine/ocr/ppocr_line_recognizer.dart';
import 'package:image/image.dart' as img;

// HBK-AUDIT-009: GalCalibrationOcrEngine.read now runs its pure computation in
// three background stages around the two session.run calls, so the former
// detect()/recognizeLineDetailed() overrides are no longer the seam. These
// tests drive the same stage functions directly (on this isolate) with the
// same fixtures and assertions: detector/recognizer inputs are compared as the
// exact tensors the old padded images would have produced.

const GalLookupReferenceClientV1 _client = GalLookupReferenceClientV1(
  widthPx: 20,
  heightPx: 12,
  dpi: 96,
);

const GalLookupNormalizedRectV1 _selection = GalLookupNormalizedRectV1(
  left: .25,
  top: .25,
  width: .5,
  height: .5,
);

img.Image _sourceImage() {
  final img.Image image = img.Image(width: 20, height: 12, numChannels: 4);
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      image.setPixelRgba(x, y, x * 11 % 256, y * 17 % 256, x + y, 255);
    }
  }
  return image;
}

Uint8List _sourcePng() => Uint8List.fromList(img.encodePng(_sourceImage()));

PpOcrCtcToken _token(
  String text, {
  required double left,
  required double right,
}) => PpOcrCtcToken(
  tokenId: 1,
  text: text,
  frameStart: 0,
  frameEndExclusive: 1,
  inputLeft: left,
  inputRight: right,
  left: left,
  right: right,
  confidence: .99,
);

PpOcrCtcToken _unpositionedToken(String text) => PpOcrCtcToken(
  tokenId: 1,
  text: text,
  frameStart: 0,
  frameEndExclusive: 1,
  inputLeft: 0,
  inputRight: 1,
  left: null,
  right: null,
  confidence: .99,
);

PpOcrLineRecognition _recognition(
  GalCalibrationOcrLineMeta line, {
  required String text,
  required List<PpOcrCtcToken> tokens,
}) => PpOcrLineRecognition(
  text: text,
  tokens: tokens,
  lineWidth: line.lineWidth,
  lineHeight: line.lineHeight,
  contentWidth: line.lineWidth,
  inputWidth: line.lineWidth,
);

GalCalibrationOcrDetectionPlan _prepare() => galCalibrationOcrPrepare(
  GalCalibrationOcrPrepareRequest(
    pngBytes: _sourcePng(),
    rect: _selection,
    clientWidth: _client.widthPx,
    clientHeight: _client.heightPx,
  ),
);

/// [line] is in the padded detector image's pixels, exactly what the old fake
/// detector returned from detect().
List<GalCalibrationOcrLine> _read({
  required PpTextLine line,
  required PpOcrLineRecognition Function(GalCalibrationOcrLineMeta meta)
  buildRecognition,
}) {
  final GalCalibrationOcrDetectionPlan plan = _prepare();
  return <GalCalibrationOcrLine?>[
    for (final GalCalibrationOcrLinePlan linePlan in galCalibrationOcrPlanLines(
      plan.crop,
      <PpTextLine>[line],
    ))
      galCalibrationOcrLineOf(
        plan.crop.geometry,
        linePlan.meta,
        buildRecognition(linePlan.meta),
      ),
  ].nonNulls.toList();
}

/// An RGBA image whose pixel (x, y) is [_sourceImage] at [sourceAt](x, y).
img.Image _expectedImage(
  int width,
  int height,
  (int, int) Function(int x, int y) sourceAt,
) {
  final img.Image source = _sourceImage();
  final img.Image image = img.Image(
    width: width,
    height: height,
    numChannels: 4,
  );
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final (int sx, int sy) = sourceAt(x, y);
      final img.Pixel pixel = source.getPixel(sx, sy);
      image.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, pixel.a);
    }
  }
  return image;
}

void main() {
  test(
    'detector/recognizer only receive selected pixels and map padding back',
    () async {
      final GalCalibrationOcrDetectionPlan plan = _prepare();
      expect(plan.crop.width, 10);
      expect(plan.crop.height, 6);
      expect(plan.crop.detectorPadding, 2);
      // Detector input == the old 14x10 edge-padded crop of selected pixels.
      final ({Float32List data, int width, int height}) expectedDet =
          ppDetPrepareInput(
            _expectedImage(
              14,
              10,
              (int x, int y) =>
                  (5 + (x - 2).clamp(0, 9), 3 + (y - 2).clamp(0, 5)),
            ),
          );
      expect(plan.detWidth, expectedDet.width);
      expect(plan.detHeight, expectedDet.height);
      expect(plan.detInput, orderedEquals(expectedDet.data));

      const PpTextLine detected = PpTextLine(
        rect: OcrRect(left: 4, top: 3, right: 10, bottom: 6),
        score: .99,
      );
      final List<GalCalibrationOcrLinePlan> linePlans =
          galCalibrationOcrPlanLines(plan.crop, <PpTextLine>[detected]);
      expect(linePlans, hasLength(1));
      // Recognizer input == the old 10x7 edge-padded line crop.
      final PpRecDetailedInput expectedRec = ppRecPrepareDetailed(
        _expectedImage(
          10,
          7,
          (int x, int y) => (7 + (x - 2).clamp(0, 5), 4 + (y - 2).clamp(0, 2)),
        ),
      )!;
      expect(linePlans.single.meta.lineWidth, 10);
      expect(linePlans.single.meta.lineHeight, 7);
      expect(linePlans.single.meta.inputWidth, expectedRec.inputWidth);
      expect(linePlans.single.meta.contentWidth, expectedRec.contentWidth);
      expect(linePlans.single.recInput, orderedEquals(expectedRec.data));

      final List<GalCalibrationOcrLine> lines = _read(
        line: detected,
        buildRecognition: (GalCalibrationOcrLineMeta meta) => _recognition(
          meta,
          text: 'あ',
          tokens: <PpOcrCtcToken>[_token('あ', left: 3, right: 5)],
        ),
      );

      expect(lines, hasLength(1));
      expect(lines.single.text, 'あ');
      expect(lines.single.rect.left, 7);
      expect(lines.single.rect.top, 4);
      expect(lines.single.rect.right, 13);
      expect(lines.single.rect.bottom, 7);
      expect(lines.single.tokens.single.rect.left, 8);
      expect(lines.single.tokens.single.rect.top, 4);
      expect(lines.single.tokens.single.rect.right, 10);
      expect(lines.single.tokens.single.rect.bottom, 7);
    },
  );

  test(
    'short tail without positioned tokens remains an OCR candidate',
    () async {
      const PpTextLine detected = PpTextLine(
        rect: OcrRect(left: 4, top: 3, right: 12, bottom: 6),
        score: .99,
      );
      PpOcrLineRecognition recognize(GalCalibrationOcrLineMeta meta) =>
          _recognition(
            meta,
            text: '」',
            tokens: <PpOcrCtcToken>[_unpositionedToken('」')],
          );

      final List<GalCalibrationOcrLine> lines = _read(
        line: detected,
        buildRecognition: recognize,
      );

      expect(lines, hasLength(1));
      expect(lines.single.text, '」');
      expect(lines.single.tokens.single.confidence, 0);
    },
  );

  test(
    'positioned token touching a horizontal crop edge remains a candidate',
    () async {
      const PpTextLine detected = PpTextLine(
        rect: OcrRect(left: 4, top: 3, right: 12, bottom: 6),
        score: .99,
      );
      PpOcrLineRecognition recognize(GalCalibrationOcrLineMeta meta) =>
          _recognition(
            meta,
            text: 'あ',
            // line padding is 2; after it is removed, right == lineCrop.width.
            tokens: <PpOcrCtcToken>[_token('あ', left: 7, right: 10)],
          );

      expect(_read(line: detected, buildRecognition: recognize), hasLength(1));
    },
  );

  test(
    'vertical crop-edge contact alone does not reject a positioned line',
    () async {
      const PpTextLine detected = PpTextLine(
        rect: OcrRect(left: 4, top: 2, right: 10, bottom: 5),
        score: .99,
      );
      PpOcrLineRecognition recognize(GalCalibrationOcrLineMeta meta) =>
          _recognition(
            meta,
            text: 'あ',
            tokens: <PpOcrCtcToken>[_token('あ', left: 4, right: 6)],
          );

      expect(_read(line: detected, buildRecognition: recognize), hasLength(1));
    },
  );
}
