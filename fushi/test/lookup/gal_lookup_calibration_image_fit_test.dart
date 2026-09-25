import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_image_fit.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:image/image.dart' as img;

// Synthetic ink, deliberately not rendered by the production layout. These
// fixtures contain no game assets and no manually marked character centres.
GalCalibrationSample _sample({
  bool validation = false,
  int indent = 1,
  bool wrongSecondRow = false,
  bool blank = false,
  bool explicitBreak = false,
  bool trailingBreak = false,
  bool borderSpecks = false,
  bool extraGlyph = false,
  img.ColorRgb8? backgroundColor,
  img.ColorRgb8? inkColor,
}) {
  final img.Image image = img.Image(width: 600, height: 300);
  final img.ColorRgb8 background = backgroundColor ?? img.ColorRgb8(30, 40, 60);
  final img.ColorRgb8 ink = inkColor ?? img.ColorRgb8(245, 245, 245);
  img.fill(image, color: background);
  const String text = '「春夏秋冬山川海空花鳥風月日光森林大地雨雪水火石土星夜朝夕音夢ー」';
  if (!blank) {
    for (int i = 0; i < text.length; i++) {
      final int row = i < 20 ? 0 : 1;
      final int col = i < 20 ? i : i - 20 + indent;
      final int x = 42 + col * 24;
      final int y = 110 + row * 31 + (row == 1 && wrongSecondRow ? 11 : 0);
      if (i == 0) {
        img.fillRect(
          image,
          x1: x + 15,
          y1: y,
          x2: x + 18,
          y2: y + 14,
          color: ink,
        );
        img.fillRect(
          image,
          x1: x + 9,
          y1: y,
          x2: x + 18,
          y2: y + 2,
          color: ink,
        );
      } else {
        img.drawRect(
          image,
          x1: x + 3,
          y1: y,
          x2: x + 20,
          y2: y + 19,
          color: ink,
          thickness: 2,
        );
        img.drawLine(
          image,
          x1: x + 4,
          y1: y + 10,
          x2: x + 19,
          y2: y + 10,
          color: ink,
          thickness: 2,
        );
      }
    }
    if (borderSpecks) {
      for (final (int x, int y) in [(588, 118), (10, 149)]) {
        img.fillRect(image, x1: x, y1: y, x2: x + 1, y2: y + 2, color: ink);
      }
    }
    if (extraGlyph) {
      img.drawRect(
        image,
        x1: 580,
        y1: 110,
        x2: 591,
        y2: 129,
        color: ink,
        thickness: 2,
      );
    }
  }
  return GalCalibrationSample(
    validation: validation,
    capture: GalLookupCalibrationCapture(
      sourceText: explicitBreak
          ? '${text.substring(0, 20)}\n${text.substring(20)}'
          : '$text${trailingBreak ? '\r\n' : ''}',
      pngBytes: Uint8List.fromList(img.encodePng(image)),
      referenceClient: const GalLookupReferenceClientV1(
        widthPx: 600,
        heightPx: 300,
        dpi: 96,
      ),
      exePath: r'C:\synthetic\grid.exe',
      exeSha256: 'a' * 64,
      sessionEpoch: 1,
      occurrenceId: 'synthetic',
      targetHwnd: 1,
      capturedAt: DateTime.utc(2026),
      selectedThreadKey: 'synthetic',
    ),
  );
}

GalLookupCalibrationDraft _draft(List<GalCalibrationSample> samples) =>
    GalLookupCalibrationDraft(
      rect: const GalLookupNormalizedRectV1(
        left: 0.03,
        top: 0.3,
        width: 0.94,
        height: 0.35,
      ),
      layout: const GalLookupTextLayoutV1(fontSizePerClientHeight: 0.2),
      samples: samples,
    );

void main() {
  test('rough regions tolerate isolated background specks beside text', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([_sample(borderSpecks: true)]),
    );
    expect(result.draft?.layout.cellGrid?.columns, 20);
    expect(result.draft?.layout.cellGrid?.quotedContinuationIndent, 1);
  });

  test('does not discard an unexplained full glyph outside the text run', () {
    expect(
      inferGalCalibrationGrid(_draft([_sample(extraGlyph: true)])).draft,
      isNull,
    );
  });

  test('finds dark glyphs on a light dialogue panel', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([
        _sample(
          backgroundColor: img.ColorRgb8(238, 238, 238),
          inkColor: img.ColorRgb8(24, 24, 24),
        ),
      ]),
    );
    expect(result.draft?.layout.cellGrid?.columns, 20);
  });

  test('finds colored glyphs by local contrast without a text box color', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([
        _sample(
          backgroundColor: img.ColorRgb8(76, 108, 132),
          inkColor: img.ColorRgb8(184, 84, 156),
        ),
      ]),
    );
    expect(result.draft?.layout.cellGrid?.columns, 20);
  });

  test('finds low-contrast outlined text without a dialogue panel', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([
        _sample(
          backgroundColor: img.ColorRgb8(120, 120, 120),
          inkColor: img.ColorRgb8(135, 135, 135),
        ),
      ]),
    );
    expect(result.draft?.layout.cellGrid?.columns, 20);
  });

  test(
    'measures ink grid and quoted continuation without any centre marks',
    () {
      final GalCalibrationImageFit result = inferGalCalibrationGrid(
        _draft([_sample()]),
      );
      expect(result.reason, isNull);
      final GalLookupCalibrationDraft fitted = result.draft!;
      expect(fitted.layout.cellGrid!.columns, 20);
      expect(fitted.layout.cellGrid!.quotedContinuationIndent, 1);
      expect(
        fitted.layout.cellGrid!.advancePerClientHeight * 300,
        closeTo(24, 0.7),
      );
      expect(
        fitted.layout.cellGrid!.lineAdvancePerClientHeight * 300,
        closeTo(31, 1),
      );
      expect(fitted.rect.left * 600, closeTo(42, 2));
      expect(fitted.rect.top * 300, closeTo(109, 1));
      expect(fitted.samples.single.anchors, isEmpty);
    },
  );

  test('does not assume that every game indents continued lines', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([_sample(indent: 0)]),
    );
    expect(result.draft!.layout.cellGrid!.quotedContinuationIndent, 0);
  });

  test('measures larger indentation and ignores a trailing empty line', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([_sample(indent: 4, trailingBreak: true)]),
    );
    expect(result.draft!.layout.cellGrid!.quotedContinuationIndent, 4);
  });

  test('held-out samples reject an inconsistent line position', () {
    final GalCalibrationImageFit result = inferGalCalibrationGrid(
      _draft([_sample(), _sample(validation: true, wrongSecondRow: true)]),
    );
    expect(result.draft, isNull);
  });

  test('blank screenshots and validation-only sets never create a grid', () {
    expect(
      inferGalCalibrationGrid(_draft([_sample(blank: true)])).draft,
      isNull,
    );
    expect(
      inferGalCalibrationGrid(_draft([_sample(validation: true)])).draft,
      isNull,
    );
  });

  test('explicit line breaks alone cannot prove a soft-wrap column', () {
    expect(
      inferGalCalibrationGrid(_draft([_sample(explicitBreak: true)])).draft,
      isNull,
    );
  });
}
