part of 'gal_lookup_calibration_ocr.dart';

/// OCR emission times are not glyph centers. Refine only lines whose repeated
/// foreground strokes provide independent, regular geometric evidence. Color
/// candidates come from the image, never a game/font-specific threshold.
GalCalibrationOcrAlignment refineGalCalibrationOcrGeometry(
  ({
    Uint8List pngBytes,
    String text,
    GalLookupNormalizedRectV1 searchRect,
    GalCalibrationOcrAlignment alignment,
  })
  input,
) {
  if (!input.alignment.accepted) return input.alignment;
  final img.Image? image = img.decodePng(input.pngBytes);
  if (image == null) {
    return const GalCalibrationOcrAlignment(
      lines: [],
      confidence: 0,
      reason: 'ocr_capture_decode_failed',
    );
  }
  final List<GalCalibrationOcrMatchedLine> lines =
      <GalCalibrationOcrMatchedLine>[
        for (final GalCalibrationOcrMatchedLine line in input.alignment.lines)
          _refineInkSegments(image, input.text, input.searchRect, line) ??
              _refineInkLine(image, input.text, input.searchRect, line) ??
              line,
      ];
  return GalCalibrationOcrAlignment(
    confidence: input.alignment.confidence,
    lines: lines,
  );
}

/// Punctuation can change the pen advance without changing glyph height.
/// Measure ordinary runs independently so a narrow comma does not force both
/// sides onto a fictitious uniform grid. Their relative origins then provide
/// width evidence to the fitter; the comma's ink rectangle does not.
GalCalibrationOcrMatchedLine? _refineInkSegments(
  img.Image image,
  String text,
  GalLookupNormalizedRectV1 search,
  GalCalibrationOcrMatchedLine line,
) {
  final List<_SourceUnit> source = _sourceUnits(text);
  if (!source
      .sublist(line.sourceStart, line.sourceEnd)
      .any(
        (_SourceUnit unit) =>
            unit.value == ' ' ||
            _singlePunctuationCodePoint(unit.value) != null,
      )) {
    return null;
  }
  final List<GalCalibrationOcrMatchedLine> measured = [];
  int start = line.sourceStart;
  bool split = false;
  for (int end = start; end <= line.sourceEnd; end++) {
    if (end < line.sourceEnd &&
        source[end].value != ' ' &&
        _singlePunctuationCodePoint(source[end].value) == null) {
      continue;
    }
    if (end < line.sourceEnd) split = true;
    final int offset = start - line.sourceStart;
    final List<GalCalibrationOcrGlyph> glyphs = [
      for (final GalCalibrationOcrGlyph g in line.glyphs)
        if (g.cellOffset >= offset && g.cellOffset < end - line.sourceStart)
          GalCalibrationOcrGlyph(
            sourceIndex: g.sourceIndex,
            charLength: g.charLength,
            cellOffset: g.cellOffset - offset,
            lineIndex: g.lineIndex,
            rect: g.rect,
            confidence: g.confidence,
            matchKind: g.matchKind,
            ocrTokenIndex: g.ocrTokenIndex,
            syntheticOcrPosition: g.syntheticOcrPosition,
            ocrConfidence: g.ocrConfidence,
            ocrText: g.ocrText,
          ),
    ];
    if (glyphs.length >= 4) {
      final GalCalibrationOcrMatchedLine? refined = _refineInkLine(
        image,
        text,
        search,
        GalCalibrationOcrMatchedLine(
          sourceStart: start,
          sourceEnd: end,
          cellCount: end - start,
          lineIndex: line.lineIndex,
          rect: line.rect,
          glyphs: glyphs,
        ),
      );
      if (refined != null) measured.add(refined);
    }
    start = end + 1;
  }
  if (!split || measured.isEmpty) return null;
  final Map<int, GalCalibrationOcrGlyph> evidence = {
    for (final GalCalibrationOcrMatchedLine segment in measured)
      for (final GalCalibrationOcrGlyph g in segment.glyphs)
        if (g.inkMeasured) g.sourceIndex: g,
  };
  final double centerY = _median([
    for (final GalCalibrationOcrMatchedLine segment in measured)
      segment.rect.centerY,
  ]);
  final double height = measured
      .map((GalCalibrationOcrMatchedLine segment) => segment.rect.height)
      .reduce(math.max);
  return GalCalibrationOcrMatchedLine(
    sourceStart: line.sourceStart,
    sourceEnd: line.sourceEnd,
    cellCount: line.cellCount,
    lineIndex: line.lineIndex,
    rect: OcrRect(
      left: line.rect.left,
      right: line.rect.right,
      top: centerY - height / 2,
      bottom: centerY + height / 2,
    ),
    glyphs: [
      for (final GalCalibrationOcrGlyph g in line.glyphs)
        GalCalibrationOcrGlyph(
          sourceIndex: g.sourceIndex,
          charLength: g.charLength,
          cellOffset: g.cellOffset,
          lineIndex: g.lineIndex,
          rect: evidence[g.sourceIndex]?.rect ?? g.rect,
          confidence: g.confidence,
          inkMeasured: evidence.containsKey(g.sourceIndex),
          matchKind: g.matchKind,
          ocrTokenIndex: g.ocrTokenIndex,
          syntheticOcrPosition: g.syntheticOcrPosition,
          ocrConfidence: g.ocrConfidence,
          ocrText: g.ocrText,
        ),
    ],
  );
}

bool _fullSizeInkCharacter(String text) {
  if (text.runes.length != 1) return false;
  final int rune = text.runes.single;
  return ((rune >= 0x3041 && rune <= 0x30fa) ||
          (rune >= 0x3400 && rune <= 0x9fff)) &&
      !'ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶー'.contains(text);
}

class _InkGeometryCandidate {
  const _InkGeometryCandidate(this.score, this.left, this.pitch, this.mask);
  final double score;
  final double left;
  final double pitch;
  final Uint8List mask;
}

/// A periodic stroke grid can accidentally associate a letter with its next
/// neighbour (especially a long vowel mark). Keep the OCR token ordering as
/// independent evidence of identity before promoting pixels to ink anchors.
@visibleForTesting
bool galCalibrationInkBelongsToToken({
  required GalCalibrationOcrGlyph glyph,
  required OcrRect measured,
  required List<GalCalibrationOcrGlyph> tokens,
}) {
  final double center = glyph.rect.centerX;
  if (!center.isFinite || !measured.centerX.isFinite) return false;
  for (final GalCalibrationOcrGlyph other in tokens) {
    if (other.cellOffset == glyph.cellOffset ||
        !other.confidence.isFinite ||
        other.confidence < .5 ||
        !other.rect.centerX.isFinite) {
      continue;
    }
    final double neighbour = other.rect.centerX;
    // Only ordered observations establish a boundary. Coincident or reversed
    // CTC emissions do not prove which side a glyph occupies.
    if (other.cellOffset < glyph.cellOffset &&
        neighbour < center &&
        measured.centerX <= (neighbour + center) / 2) {
      return false;
    }
    if (other.cellOffset > glyph.cellOffset &&
        neighbour > center &&
        measured.centerX >= (neighbour + center) / 2) {
      return false;
    }
  }
  return true;
}

GalCalibrationOcrMatchedLine? _refineInkLine(
  img.Image image,
  String text,
  GalLookupNormalizedRectV1 search,
  GalCalibrationOcrMatchedLine line,
) =>
    _measureInkLine(image, text, search, line, relaxed: false) ??
    _measureInkLine(image, text, search, line, relaxed: true);

GalCalibrationOcrMatchedLine? _measureInkLine(
  img.Image image,
  String text,
  GalLookupNormalizedRectV1 search,
  GalCalibrationOcrMatchedLine line, {
  required bool relaxed,
}) {
  final List<GalCalibrationOcrGlyph> anchors = line.glyphs
      .where(
        (GalCalibrationOcrGlyph g) =>
            g.confidence >= (relaxed ? .55 : .7) &&
            _fullSizeInkCharacter(
              text.substring(g.sourceIndex, g.sourceIndex + g.charLength),
            ),
      )
      .toList();
  if (anchors.length < (relaxed ? 4 : 5)) return null;
  final List<double> slopes = <double>[
    for (final GalCalibrationOcrGlyph a in anchors)
      for (final GalCalibrationOcrGlyph b in anchors)
        if (b.cellOffset - a.cellOffset >= 3)
          (b.rect.centerX - a.rect.centerX) / (b.cellOffset - a.cellOffset),
  ];
  if (slopes.isEmpty) return null;
  final double pitch = _median(slopes);
  if (!pitch.isFinite || pitch < 5) return null;
  final double searchLeft = search.left * image.width;
  final double searchTop = search.top * image.height;
  final double searchRight = search.right * image.width;
  final double searchBottom = search.bottom * image.height;
  final double initialLeft = _median(<double>[
    for (final GalCalibrationOcrGlyph g in anchors)
      g.rect.centerX - (g.cellOffset + .5) * pitch,
  ]);
  final int x0 = math
      .max(searchLeft.floor(), (initialLeft - pitch * .35).floor())
      .clamp(0, image.width - 1);
  final int x1 = math
      .min(
        searchRight.ceil(),
        (initialLeft + (line.cellCount + .35) * pitch).ceil(),
      )
      .clamp(x0 + 1, image.width);
  final int y0 = math
      .max(searchTop.floor(), line.rect.top.floor())
      .clamp(0, image.height - 1);
  final int y1 = math
      .min(searchBottom.ceil(), line.rect.bottom.ceil())
      .clamp(y0 + 1, image.height);
  final int width = x1 - x0;
  final int height = y1 - y0;
  if (width < pitch * 4 || height < 5) return null;
  final Uint8List rgb = Uint8List(width * height * 3);
  final List<int> histogram = List<int>.filled(512, 0);
  final List<List<int>> sums = List<List<int>>.generate(
    512,
    (_) => <int>[0, 0, 0],
  );
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final img.Pixel p = image.getPixel(x0 + x, y0 + y);
      final int r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
      final int offset = (y * width + x) * 3;
      rgb[offset] = r;
      rgb[offset + 1] = g;
      rgb[offset + 2] = b;
      final int bucket = (r ~/ 32) * 64 + (g ~/ 32) * 8 + b ~/ 32;
      histogram[bucket]++;
      sums[bucket][0] += r;
      sums[bucket][1] += g;
      sums[bucket][2] += b;
    }
  }
  final List<int> colors = List<int>.generate(512, (int i) => i)
    ..sort((int a, int b) => histogram[b].compareTo(histogram[a]));
  _InkGeometryCandidate? best;
  for (final int color in colors.take(10)) {
    final int count = histogram[color];
    if (count == 0) continue;
    final List<double> mean = <double>[
      for (final int v in sums[color]) v / count,
    ];
    final Uint8List mask = Uint8List(width * height);
    final List<double> projection = List<double>.filled(width, 0);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int offset = (y * width + x) * 3;
        if ((rgb[offset] - mean[0]).abs() < 25 &&
            (rgb[offset + 1] - mean[1]).abs() < 25 &&
            (rgb[offset + 2] - mean[2]).abs() < 25) {
          mask[y * width + x] = 1;
        }
      }
    }
    _retainGlyphComponents(mask, width, height, pitch);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        projection[x] += mask[y * width + x];
      }
    }
    final List<double> support = <double>[];
    for (final GalCalibrationOcrGlyph g in anchors) {
      final int a = (g.rect.centerX - pitch * .35 - x0).floor().clamp(0, width);
      final int b = (g.rect.centerX + pitch * .35 - x0).ceil().clamp(a, width);
      double sum = 0;
      for (int x = a; x < b; x++) {
        sum += projection[x];
      }
      support.add(b == a ? 0 : sum / ((b - a) * height));
    }
    support.sort();
    if (support[(support.length * .2).floor()] < .045 ||
        _median(support) > .65) {
      continue;
    }
    final List<double> smooth = <double>[
      for (int x = 0; x < width; x++)
        (projection[math.max(0, x - 1)] +
                projection[x] +
                projection[math.min(width - 1, x + 1)]) /
            3,
    ];
    final double average =
        projection.reduce((double a, double b) => a + b) / width;
    for (int step = -14; step <= 14; step++) {
      final double trialPitch = pitch * (1 + step * .0025);
      for (int phase = -16; phase <= 16; phase++) {
        final double left = initialLeft + phase * .02 * pitch;
        double cut = 0;
        int edges = 0;
        for (final GalCalibrationOcrGlyph g in anchors) {
          for (int side = 0; side <= 1; side++) {
            final double x = left + (g.cellOffset + side) * trialPitch - x0;
            // A crop edge cannot establish a stroke-free character boundary.
            if (x < 1 || x >= width - 1) continue;
            final int lo = x.floor();
            cut += smooth[lo] * (1 - (x - lo)) + smooth[lo + 1] * (x - lo);
            edges++;
          }
        }
        if (edges < anchors.length * 1.6) continue;
        final double score =
            cut / edges / (average + .01) +
            .03 * (phase * .02).abs() +
            .2 * (step * .0025).abs();
        if (best == null || score < best.score) {
          best = _InkGeometryCandidate(score, left, trialPitch, mask);
        }
      }
    }
  }
  final _InkGeometryCandidate? selected = best;
  if (selected == null || selected.score > .4) return null;
  final Map<int, OcrRect> measured = <int, OcrRect>{};
  for (final GalCalibrationOcrGlyph g in anchors) {
    final int a = (selected.left + g.cellOffset * selected.pitch - x0)
        .round()
        .clamp(0, width);
    final int b = (selected.left + (g.cellOffset + 1) * selected.pitch - x0)
        .round()
        .clamp(a, width);
    final List<int> xs = List<int>.filled(b - a, 0);
    final List<int> ys = List<int>.filled(height, 0);
    int total = 0;
    for (int y = 0; y < height; y++) {
      for (int x = a; x < b; x++) {
        if (selected.mask[y * width + x] != 0) {
          xs[x - a]++;
          ys[y]++;
          total++;
        }
      }
    }
    if (total < pitch * 2) continue;
    final double l = _inkQuantile(xs, total, .01),
        r = _inkQuantile(xs, total, .99);
    final double t = _inkQuantile(ys, total, .01),
        bottom = _inkQuantile(ys, total, .99);
    if (r - l < pitch * .35 ||
        r - l > pitch * 1.02 ||
        bottom - t < pitch * .35) {
      continue;
    }
    final OcrRect bounds = OcrRect(
      left: x0 + a + l,
      right: x0 + a + r + 1,
      top: y0 + t,
      bottom: y0 + bottom + 1,
    );
    if (!galCalibrationInkBelongsToToken(
      glyph: g,
      measured: bounds,
      tokens: line.glyphs,
    )) {
      continue;
    }
    measured[g.sourceIndex] = bounds;
  }
  // A slightly rough search rectangle can cut the first or last visible
  // glyph.  Do not use that partial component as pixel evidence, but retain
  // the interior measurements and the OCR candidate itself.
  measured.removeWhere(
    (int _, OcrRect rect) =>
        rect.left <= searchLeft + .5 ||
        rect.right >= searchRight - .5 ||
        rect.top <= searchTop + .5 ||
        rect.bottom >= searchBottom - .5,
  );
  if (measured.length < (relaxed ? 4 : 5) ||
      measured.length < anchors.length * (relaxed ? .45 : .65)) {
    return null;
  }
  final List<GalCalibrationOcrGlyph> usable = anchors
      .where((GalCalibrationOcrGlyph g) => measured.containsKey(g.sourceIndex))
      .toList();
  // Repeated scenery can have beautifully regular gaps. Distinct characters
  // must also show distinct stroke shapes, not identical wallpaper tiles.
  final Map<int, List<double>> shapes = <int, List<double>>{};
  for (final GalCalibrationOcrGlyph g in usable) {
    final OcrRect bounds = measured[g.sourceIndex]!;
    final List<double> shape = List<double>.filled(16, 0);
    final List<int> areas = List<int>.filled(16, 0);
    for (int y = bounds.top.floor(); y < bounds.bottom.ceil(); y++) {
      for (int x = bounds.left.floor(); x < bounds.right.ceil(); x++) {
        final int cell =
            ((y - bounds.top) * 4 / bounds.height).floor().clamp(0, 3) * 4 +
            ((x - bounds.left) * 4 / bounds.width).floor().clamp(0, 3);
        areas[cell]++;
        shape[cell] += selected.mask[(y - y0) * width + x - x0];
      }
    }
    shapes[g.sourceIndex] = <double>[
      for (int i = 0; i < 16; i++) areas[i] == 0 ? 0 : shape[i] / areas[i],
    ];
  }
  final List<double> differences = <double>[];
  for (int a = 0; a < usable.length; a++) {
    for (int b = a + 1; b < usable.length; b++) {
      final GalCalibrationOcrGlyph ga = usable[a], gb = usable[b];
      if (text.substring(ga.sourceIndex, ga.sourceIndex + ga.charLength) ==
          text.substring(gb.sourceIndex, gb.sourceIndex + gb.charLength)) {
        continue;
      }
      double difference = 0;
      for (int i = 0; i < 16; i++) {
        difference += (shapes[ga.sourceIndex]![i] - shapes[gb.sourceIndex]![i])
            .abs();
      }
      differences.add(difference / 16);
    }
  }
  if (differences.length >= 5 && _median(differences) < .035) return null;
  final List<double> refinedSlopes = <double>[
    for (final GalCalibrationOcrGlyph a in usable)
      for (final GalCalibrationOcrGlyph b in usable)
        if (b.cellOffset - a.cellOffset >= 3)
          (measured[b.sourceIndex]!.centerX -
                  measured[a.sourceIndex]!.centerX) /
              (b.cellOffset - a.cellOffset),
  ];
  if (refinedSlopes.isEmpty) return null;
  final double refinedPitch = _median(refinedSlopes);
  final double center = _median(<double>[
    for (final GalCalibrationOcrGlyph g in usable)
      measured[g.sourceIndex]!.centerX - g.cellOffset * refinedPitch,
  ]);
  final double error = _median(<double>[
    for (final GalCalibrationOcrGlyph g in usable)
      (measured[g.sourceIndex]!.centerX - center - g.cellOffset * refinedPitch)
          .abs(),
  ]);
  if (error > math.max(1.5, pitch * .06) ||
      (refinedPitch / pitch - 1).abs() > .06) {
    return null;
  }
  final double y = _median(
    measured.values.map((OcrRect r) => r.centerY).toList(),
  );
  // Include antialiasing and outline margins; do not inflate to DB's unclip box.
  final double inkHeight =
      measured.values
          .map((OcrRect r) => 2 * math.max(y - r.top, r.bottom - y))
          .reduce(math.max) +
      2;
  return GalCalibrationOcrMatchedLine(
    sourceStart: line.sourceStart,
    sourceEnd: line.sourceEnd,
    cellCount: line.cellCount,
    lineIndex: line.lineIndex,
    rect: OcrRect(
      left: line.rect.left,
      right: line.rect.right,
      top: y - inkHeight / 2,
      bottom: y + inkHeight / 2,
    ),
    glyphs: <GalCalibrationOcrGlyph>[
      for (final GalCalibrationOcrGlyph g in line.glyphs)
        GalCalibrationOcrGlyph(
          sourceIndex: g.sourceIndex,
          charLength: g.charLength,
          cellOffset: g.cellOffset,
          lineIndex: g.lineIndex,
          confidence: g.confidence,
          rect: measured[g.sourceIndex] ?? g.rect,
          inkMeasured: measured.containsKey(g.sourceIndex),
          matchKind: g.matchKind,
          ocrTokenIndex: g.ocrTokenIndex,
          syntheticOcrPosition: g.syntheticOcrPosition,
          ocrConfidence: g.ocrConfidence,
          ocrText: g.ocrText,
        ),
    ],
  );
}

double _inkQuantile(List<int> histogram, int total, double fraction) {
  int sum = 0;
  for (int i = 0; i < histogram.length; i++) {
    sum += histogram[i];
    if (sum >= total * fraction) return i.toDouble();
  }
  return (histogram.length - 1).toDouble();
}

// Reject connected panels, rules and scenery that span multiple cells before
// evaluating periodic gaps. Tiny detached marks remain available to their cell.
void _retainGlyphComponents(
  Uint8List mask,
  int width,
  int height,
  double pitch,
) {
  final Uint8List visited = Uint8List(mask.length);
  final Int32List queue = Int32List(mask.length);
  for (int seed = 0; seed < mask.length; seed++) {
    if (mask[seed] == 0 || visited[seed] != 0) continue;
    int read = 0, count = 1;
    queue[0] = seed;
    visited[seed] = 1;
    int left = seed % width, right = left, top = seed ~/ width, bottom = top;
    while (read < count) {
      final int at = queue[read++];
      final int x = at % width, y = at ~/ width;
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
      for (final int next in <int>[
        if (x > 0) at - 1,
        if (x + 1 < width) at + 1,
        if (y > 0) at - width,
        if (y + 1 < height) at + width,
      ]) {
        if (mask[next] != 0 && visited[next] == 0) {
          visited[next] = 1;
          queue[count++] = next;
        }
      }
    }
    if (count < 2 ||
        right - left + 1 > pitch * 1.15 ||
        bottom - top + 1 > pitch * 1.5) {
      for (int i = 0; i < count; i++) {
        mask[queue[i]] = 0;
      }
    }
  }
}
