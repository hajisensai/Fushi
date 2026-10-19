import 'dart:typed_data';

import 'package:fushi_engine/media/image_kernels.dart';

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
  /// Safe to call in an isolate (no dart:ui).
  static double compareEdges(
    Uint8List leftBytes,
    Uint8List rightBytes, {
    int stripWidth = 3,
    int sampleHeight = 64,
  }) {
    // 解码（转正）、按高 [sampleHeight] 最近邻缩放、逐像素比较都在原生内核。
    return edgeSimilarityNative(
          leftBytes,
          rightBytes,
          stripWidth: stripWidth,
          sampleHeight: sampleHeight,
        ) ??
        0.0;
  }
}
