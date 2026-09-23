import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_projection.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';

const GalLookupReferenceClientV1 _image = GalLookupReferenceClientV1(
  widthPx: 1600,
  heightPx: 900,
  dpi: 144,
);
const GalLookupNormalizedRectV1 _body = GalLookupNormalizedRectV1(
  left: .1,
  top: .6,
  width: .8,
  height: .3,
);
const GalLookupTextLayoutV1 _layout = GalLookupTextLayoutV1(
  cellGrid: GalLookupCellGridV1(
    advancePerClientHeight: .04,
    lineAdvancePerClientHeight: .06,
    cellHeightPerClientHeight: .05,
    columns: 30,
    continuationIndent: 0,
    quotedContinuationIndent: 1,
    trimWrapWhitespace: true,
  ),
);
const WindowCaptureMetadata _mapping = WindowCaptureMetadata(
  capturedHwnd: 88,
  capturedPid: 8,
  sourceHwnd: 77,
  sourcePid: 7,
  presentationHwnd: 88,
  presentationPid: 8,
  clientLeftPx: 0,
  clientTopPx: 0,
  clientWidthPx: 1920,
  clientHeightPx: 1080,
  imageWidthPx: 1600,
  imageHeightPx: 900,
  dpi: 144,
  clientAreaComplete: false,
  capturedAtTickMs: 1,
  usedPresentationCapture: true,
  presentationViewportComplete: true,
  sourceClientLeftPx: -1000,
  sourceClientTopPx: 20,
  sourceClientWidthPx: 1000,
  sourceClientHeightPx: 600,
  sourceClientDpi: 96,
  sourceViewportLeftPx: -900,
  sourceViewportTopPx: 70,
  sourceViewportWidthPx: 800,
  sourceViewportHeightPx: 450,
  destinationViewportWidthPx: 1600,
  destinationViewportHeightPx: 900,
);

void main() {
  test('crop with different display DPI returns original client geometry', () {
    final GalLookupSurfaceVariantV1 variant = projectGalCalibrationToSource(
      client: _image,
      rect: _body,
      layout: _layout,
      metadata: _mapping,
    )!;
    expect(variant.referenceClient.widthPx, 1000);
    expect(variant.referenceClient.heightPx, 600);
    expect(variant.referenceClient.dpi, 96);
    expect(variant.bodyRect.left, closeTo(.18, 1e-9));
    expect(variant.bodyRect.top, closeTo(320 / 600, 1e-9));
    expect(variant.bodyRect.width, closeTo(.64, 1e-9));
    expect(variant.bodyRect.height, closeTo(.225, 1e-9));
    // 36 image pixels at 2x become 18 source pixels, without moving columns.
    expect(
      variant.layout.cellGrid!.advancePerClientHeight * 600,
      closeTo(18, 1e-9),
    );
    expect(variant.layout.cellGrid!.columns, 30);
    expect(variant.layout.cellGrid!.quotedContinuationIndent, 1);
    expect(variant.layout.cellGrid!.trimWrapWhitespace, isTrue);
  });

  test('quote-only filter survives conversion to source client', () {
    final GalLookupSurfaceVariantV1 variant = projectGalCalibrationToSource(
      client: _image,
      rect: _body,
      layout: GalLookupTextLayoutV1(
        cellGrid: _layout.cellGrid,
        quotedTextOnly: true,
      ),
      metadata: _mapping,
    )!;
    expect(variant.layout.quotedTextOnly, isTrue);
  });

  test('anisotropic output independently restores x and y advances', () {
    final WindowCaptureMetadata mapping = WindowCaptureMetadata.tryFromMap({
      ..._mapping.toJson(),
      'sourceViewportWidthPx': 600,
    })!;
    final GalLookupSurfaceVariantV1 variant = projectGalCalibrationToSource(
      client: _image,
      rect: _body,
      layout: _layout,
      metadata: mapping,
    )!;
    expect(
      variant.layout.cellGrid!.advancePerClientHeight * 600,
      closeTo(13.5, 1e-9),
    );
    expect(
      variant.layout.cellGrid!.lineAdvancePerClientHeight * 600,
      closeTo(27, 1e-9),
    );
  });

  test(
    'missing, out-of-client, or mismatched provenance never guesses a crop',
    () {
      for (final Map<String, Object?> delta in [
        <String, Object?>{'sourceClientWidthPx': 0},
        <String, Object?>{'sourceViewportLeftPx': -1001},
        <String, Object?>{'sourceViewportWidthPx': 950},
        <String, Object?>{'imageWidthPx': 1601},
      ]) {
        expect(
          projectGalCalibrationToSource(
            client: _image,
            rect: _body,
            layout: _layout,
            metadata: WindowCaptureMetadata.tryFromMap({
              ..._mapping.toJson(),
              ...delta,
            }),
          ),
          isNull,
        );
      }
    },
  );

  test('ordinary full-client calibration preserves saved geometry', () {
    final GalLookupSurfaceVariantV1 variant = projectGalCalibrationToSource(
      client: _image,
      rect: _body,
      layout: _layout,
    )!;
    expect(variant.referenceClient, _image);
    expect(variant.bodyRect, _body);
    expect(variant.layout, _layout);
  });
}
