import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';

/// Converts a screenshot fit to the original game's client. The screenshot
/// and its preview stay in image pixels, including when Magpie crops/scales.
GalLookupSurfaceVariantV1? projectGalCalibrationToSource({
  required GalLookupReferenceClientV1 client,
  required GalLookupNormalizedRectV1 rect,
  required GalLookupTextLayoutV1 layout,
  WindowCaptureMetadata? metadata,
  GalLookupCalibrationSlotV1? slot,
}) {
  if (!client.isValid || !rect.isValid || !layout.isValid) return null;
  if (metadata == null || !metadata.usedPresentationCapture) {
    return GalLookupSurfaceVariantV1(
      aspectRatio: client.aspectRatio,
      referenceClient: client,
      bodyRect: rect,
      layout: layout,
      slot: slot,
    );
  }
  if (!metadata.hasSourceClientMapping ||
      metadata.imageWidthPx != client.widthPx ||
      metadata.imageHeightPx != client.heightPx) {
    // Legacy presentation samples lack the crop origin. Keep them readable,
    // but never guess a source rectangle when applying them to a live game.
    return null;
  }
  final GalLookupReferenceClientV1 source = GalLookupReferenceClientV1(
    widthPx: metadata.sourceClientWidthPx,
    heightPx: metadata.sourceClientHeightPx,
    dpi: metadata.sourceClientDpi.toDouble(),
  );
  final double widthFraction = metadata.sourceViewportWidthPx / source.widthPx;
  final double heightFraction =
      metadata.sourceViewportHeightPx / source.heightPx;
  final GalLookupNormalizedRectV1 sourceRect = GalLookupNormalizedRectV1(
    left:
        (metadata.sourceViewportLeftPx - metadata.sourceClientLeftPx) /
            source.widthPx +
        rect.left * widthFraction,
    top:
        (metadata.sourceViewportTopPx - metadata.sourceClientTopPx) /
            source.heightPx +
        rect.top * heightFraction,
    width: rect.width * widthFraction,
    height: rect.height * heightFraction,
  );
  final double horizontal =
      client.heightPx /
      client.widthPx *
      metadata.sourceViewportWidthPx /
      source.heightPx;
  final double vertical = heightFraction;
  final GalLookupCellGridV1? grid = layout.cellGrid;
  // DirectWrite font sizing cannot encode anisotropic font stretching.
  if (grid == null && (horizontal - vertical).abs() > 0.0001) return null;
  final GalLookupTextLayoutV1 sourceLayout = GalLookupTextLayoutV1(
    fontFamily: layout.fontFamily,
    fontSizePerClientHeight: layout.fontSizePerClientHeight * vertical,
    letterSpacingPerClientHeight:
        layout.letterSpacingPerClientHeight * horizontal,
    lineHeight: layout.lineHeight,
    textAlign: layout.textAlign,
    verticalAlign: layout.verticalAlign,
    paddingPerClientHeight: layout.paddingPerClientHeight * vertical,
    cellGrid: grid == null
        ? null
        : GalLookupCellGridV1(
            advancePerClientHeight: grid.advancePerClientHeight * horizontal,
            lineAdvancePerClientHeight:
                grid.lineAdvancePerClientHeight * vertical,
            cellHeightPerClientHeight:
                grid.cellHeightPerClientHeight * vertical,
            columns: grid.columns,
            continuationIndent: grid.continuationIndent,
            quotedContinuationIndent: grid.quotedContinuationIndent,
            hangingPunctuation: grid.hangingPunctuation,
            trimWrapWhitespace: grid.trimWrapWhitespace,
            lineWidthInCells: grid.lineWidthInCells,
          ),
    quotedTextOnly: layout.quotedTextOnly,
    punctuationVisualBounds: layout.punctuationVisualBounds,
    characterAdvances: layout.characterAdvances,
  );
  if (!source.isValid || !sourceRect.isValid || !sourceLayout.isValid) {
    return null;
  }
  return GalLookupSurfaceVariantV1(
    aspectRatio: source.aspectRatio,
    referenceClient: source,
    bodyRect: sourceRect,
    layout: sourceLayout,
    slot: slot,
  );
}
