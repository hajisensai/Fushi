import 'dart:math' as math;

import 'package:fushi/src/media/manga/manga_reader_preferences.dart';

/// A rectangle in image (source) coordinates.
class MangaImageRect {
  const MangaImageRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
}

/// Deterministic projection used by the HTML renderer and by OCR hit testing.
///
/// Keeping this math out of the injected JavaScript is deliberate: the same
/// transform is used for OCR, selection and card screenshots, so a change to
/// CSS sizing cannot silently move a hit box.
class MangaPageGeometry {
  const MangaPageGeometry({
    required this.imageWidth,
    required this.imageHeight,
    required this.viewportWidth,
    required this.viewportHeight,
    this.scaleType = MangaScaleType.fitScreen,
    this.cropBorders = false,
    this.rotateQuarterTurns = 0,
  });

  final double imageWidth;
  final double imageHeight;
  final double viewportWidth;
  final double viewportHeight;
  final MangaScaleType scaleType;
  final bool cropBorders;
  final int rotateQuarterTurns;

  double get _sourceWidth =>
      rotateQuarterTurns.isOdd ? imageHeight : imageWidth;
  double get _sourceHeight =>
      rotateQuarterTurns.isOdd ? imageWidth : imageHeight;

  /// Scale before the user zoom is applied.
  double get scale {
    final double sx = viewportWidth / _sourceWidth;
    final double sy = viewportHeight / _sourceHeight;
    if (cropBorders &&
        (scaleType == MangaScaleType.fitScreen ||
            scaleType == MangaScaleType.smart)) {
      return math.max(sx, sy);
    }
    return switch (scaleType) {
      MangaScaleType.fitScreen => math.min(sx, sy),
      MangaScaleType.smart => math.min(sx, sy),
      MangaScaleType.stretch => 1,
      MangaScaleType.fitWidth => sx,
      MangaScaleType.fitHeight => sy,
      MangaScaleType.original => 1,
    };
  }

  double get displayedWidth => scaleType == MangaScaleType.stretch
      ? viewportWidth
      : _sourceWidth * scale;
  double get displayedHeight => scaleType == MangaScaleType.stretch
      ? viewportHeight
      : _sourceHeight * scale;

  double get offsetX => (viewportWidth - displayedWidth) / 2;
  double get offsetY => (viewportHeight - displayedHeight) / 2;

  /// Converts a viewport point to the original, unrotated image.
  MangaImagePoint viewportToImage(double x, double y) {
    final double sx = scaleType == MangaScaleType.stretch
        ? viewportWidth / _sourceWidth
        : scale;
    final double sy = scaleType == MangaScaleType.stretch
        ? viewportHeight / _sourceHeight
        : scale;
    double rx = (x - offsetX) / sx;
    double ry = (y - offsetY) / sy;
    if (cropBorders) {
      rx = rx.clamp(0, _sourceWidth);
      ry = ry.clamp(0, _sourceHeight);
    }
    final int turns = ((rotateQuarterTurns % 4) + 4) % 4;
    return switch (turns) {
      1 => MangaImagePoint(ry, imageHeight - rx),
      2 => MangaImagePoint(imageWidth - rx, imageHeight - ry),
      3 => MangaImagePoint(imageWidth - ry, rx),
      _ => MangaImagePoint(rx, ry),
    };
  }

  /// Converts an original image point into viewport coordinates.
  MangaViewportPoint imageToViewport(double x, double y) {
    final int turns = ((rotateQuarterTurns % 4) + 4) % 4;
    final MangaImagePoint p = switch (turns) {
      1 => MangaImagePoint(imageHeight - y, x),
      2 => MangaImagePoint(imageWidth - x, imageHeight - y),
      3 => MangaImagePoint(y, imageWidth - x),
      _ => MangaImagePoint(x, y),
    };
    final double sx = scaleType == MangaScaleType.stretch
        ? viewportWidth / _sourceWidth
        : scale;
    final double sy = scaleType == MangaScaleType.stretch
        ? viewportHeight / _sourceHeight
        : scale;
    return MangaViewportPoint(p.x * sx + offsetX, p.y * sy + offsetY);
  }
}

class MangaImagePoint {
  const MangaImagePoint(this.x, this.y);
  final double x;
  final double y;
}

class MangaViewportPoint {
  const MangaViewportPoint(this.x, this.y);
  final double x;
  final double y;
}

/// Small LRU-free cache for the hot OCR/capture path.  The reader invalidates
/// it by calling [clear] when viewport or preferences change; entries are
/// immutable and therefore safe to share between hit testing and screenshots.
class MangaPageGeometryCache {
  final Map<String, MangaPageGeometry> _entries = <String, MangaPageGeometry>{};

  MangaPageGeometry resolve({
    required double imageWidth,
    required double imageHeight,
    required double viewportWidth,
    required double viewportHeight,
    MangaScaleType scaleType = MangaScaleType.fitScreen,
    bool cropBorders = false,
    int rotateQuarterTurns = 0,
  }) {
    final String key =
        '${imageWidth.toStringAsPrecision(12)}:${imageHeight.toStringAsPrecision(12)}:'
        '${viewportWidth.toStringAsPrecision(12)}:${viewportHeight.toStringAsPrecision(12)}:'
        '${scaleType.key}:$cropBorders:$rotateQuarterTurns';
    return _entries.putIfAbsent(
      key,
      () => MangaPageGeometry(
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        scaleType: scaleType,
        cropBorders: cropBorders,
        rotateQuarterTurns: rotateQuarterTurns,
      ),
    );
  }

  void clear() => _entries.clear();
}
