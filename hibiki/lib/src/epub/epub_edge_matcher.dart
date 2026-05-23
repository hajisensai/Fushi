import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Compares the inner edges of two images to detect whether they form
/// a two-page spread (e.g. scanned book pages split in half).
class EpubEdgeMatcher {
  EpubEdgeMatcher._();

  static const double spreadThreshold = 0.85;

  /// Returns a similarity score 0.0–1.0 between the right edge of
  /// [leftBytes] and the left edge of [rightBytes].
  ///
  /// 1.0 = identical edges (very likely a spread);
  /// 0.0 = completely different or undecodable.
  ///
  /// Safe to call in an isolate (pure Dart, no dart:ui).
  static double compareEdges(
    Uint8List leftBytes,
    Uint8List rightBytes, {
    int stripWidth = 3,
    int sampleHeight = 64,
  }) {
    final img.Image? leftImg = img.decodeImage(leftBytes);
    final img.Image? rightImg = img.decodeImage(rightBytes);
    if (leftImg == null || rightImg == null) return 0.0;

    final img.Image leftResized = img.copyResize(leftImg, height: sampleHeight);
    final img.Image rightResized =
        img.copyResize(rightImg, height: sampleHeight);

    double totalDiff = 0;
    int pixelCount = 0;

    for (int y = 0; y < sampleHeight; y++) {
      for (int dx = 0; dx < stripWidth; dx++) {
        final int lx = leftResized.width - 1 - dx;
        final int rx = dx;
        if (lx < 0 || rx >= rightResized.width) continue;

        final img.Pixel lp = leftResized.getPixel(lx, y);
        final img.Pixel rp = rightResized.getPixel(rx, y);

        final double dr = (lp.r - rp.r).abs().toDouble();
        final double dg = (lp.g - rp.g).abs().toDouble();
        final double db = (lp.b - rp.b).abs().toDouble();
        totalDiff += (dr + dg + db) / (3.0 * 255.0);
        pixelCount++;
      }
    }
    if (pixelCount == 0) return 0.0;
    return 1.0 - (totalDiff / pixelCount);
  }
}
