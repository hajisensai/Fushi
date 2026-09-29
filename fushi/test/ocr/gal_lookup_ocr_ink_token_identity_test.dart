import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

GalCalibrationOcrGlyph _token(int index, double x, {double confidence = .99}) =>
    GalCalibrationOcrGlyph(
      sourceIndex: index,
      charLength: 1,
      cellOffset: index,
      lineIndex: 0,
      confidence: confidence,
      rect: OcrRect(left: x - 3, top: 10, right: x + 3, bottom: 45),
    );

OcrRect _ink(double x) =>
    OcrRect(left: x - 14, top: 14, right: x + 14, bottom: 40);

void main() {
  test('a letter cannot acquire the neighbouring long-mark pixels', () {
    final List<GalCalibrationOcrGlyph> tokens = [
      _token(0, 34),
      _token(1, 64),
      _token(2, 96, confidence: .83),
      _token(3, 124),
    ];
    expect(
      galCalibrationInkBelongsToToken(
        glyph: tokens[1],
        measured: _ink(88),
        tokens: tokens,
      ),
      isFalse,
    );
    expect(
      galCalibrationInkBelongsToToken(
        glyph: tokens[0],
        measured: _ink(54),
        tokens: tokens,
      ),
      isFalse,
    );
  });

  test('pixel correction within its token keeps useful CTC drift repair', () {
    final List<GalCalibrationOcrGlyph> tokens = [
      _token(0, 34),
      _token(1, 56),
      _token(2, 78),
    ];
    expect(
      galCalibrationInkBelongsToToken(
        glyph: tokens[1],
        measured: _ink(51),
        tokens: tokens,
      ),
      isTrue,
    );
    expect(
      galCalibrationInkBelongsToToken(
        glyph: tokens[1],
        measured: _ink(42),
        tokens: tokens,
      ),
      isFalse,
    );
  });

  test('uncertain or coincident emissions cannot veto pixel evidence', () {
    final GalCalibrationOcrGlyph token = _token(1, 64);
    expect(
      galCalibrationInkBelongsToToken(
        glyph: token,
        measured: _ink(70),
        tokens: [_token(0, 64), token, _token(2, 68, confidence: .2)],
      ),
      isTrue,
    );
  });
}
