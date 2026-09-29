import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:image/image.dart' as img;

/// Geometry measurement of a frozen sample, not text recognition. The Hook
/// supplies every character. Only a regular, horizontal full-width grid is
/// inferred; ambiguous images/text leave the existing draft untouched.
class GalCalibrationImageFit {
  const GalCalibrationImageFit({
    this.draft,
    this.reason,
    this.sampleIndex,
    this.detail,
  });
  final GalLookupCalibrationDraft? draft;
  final String? reason;

  /// Payload-free diagnostic, such as the native preview rejection reason.
  final String? detail;

  /// Zero-based failing sample, without including private text or pixels.
  final int? sampleIndex;
}

/// Optional offline OCR assistant installed by the app host.
///
/// The lookup geometry code deliberately knows nothing about OCR.  The host
/// may install a calibration-only assistant from `src/ocr/`; tests and headless
/// builds leave this null and keep the deterministic pixel fallback below.
typedef GalCalibrationOcrAssist =
    Future<GalCalibrationImageFit?> Function(
      GalLookupCalibrationDraft draft, {
      required GalCalibrationPreviewBuilder build,
    });

GalCalibrationOcrAssist? galCalibrationOcrAssist;

/// UI-facing model status kept as a tiny value object so the lookup dialog
/// does not import the OCR implementation (and therefore cannot accidentally
/// make OCR part of the runtime lookup path).
class GalCalibrationOcrModelInfo {
  const GalCalibrationOcrModelInfo({
    required this.ready,
    required this.obtainedBytes,
    required this.totalBytes,
  });

  final bool ready;
  final int obtainedBytes;
  final int totalBytes;
}

class GalCalibrationOcrDownloadProgress {
  const GalCalibrationOcrDownloadProgress({
    required this.fileName,
    required this.receivedBytes,
    required this.totalBytes,
    this.done = false,
  });

  final String fileName;
  final int receivedBytes;
  final int totalBytes;
  final bool done;
}

typedef GalCalibrationOcrModelStatusReader =
    Future<GalCalibrationOcrModelInfo> Function();
typedef GalCalibrationOcrModelDownloader =
    Stream<GalCalibrationOcrDownloadProgress> Function();

GalCalibrationOcrModelStatusReader? galCalibrationOcrModelStatus;
GalCalibrationOcrModelDownloader? galCalibrationOcrModelDownloader;

Future<GalCalibrationImageFit> fitGalCalibrationImages(
  GalLookupCalibrationDraft draft, {
  GalCalibrationPreviewBuilder build = GalLookupCalibrationPreviewChannel.build,
}) async {
  final GalLookupCalibrationDraft fittingDraft = _quotedTextFittingDraft(draft);
  final GalCalibrationOcrAssist? ocr = galCalibrationOcrAssist;
  if (ocr != null) {
    // OCR is an offline calibration aid only.  A null result means that its
    // small model pack is not installed; retain the old pixel fitter as a
    // useful zero-download fallback.  A non-null failure is authoritative so
    // an installed model never silently falls back to a worse fit.
    final GalCalibrationImageFit? assisted = await ocr(
      fittingDraft,
      build: build,
    );
    if (assisted != null) {
      if (!draft.layout.quotedTextOnly) return assisted;
      return _restoreQuotedFit(assisted, draft, build: build);
    }
  }
  final GalCalibrationImageFit fit = await compute(
    inferGalCalibrationGrid,
    fittingDraft,
  );
  return _restoreQuotedFit(fit, draft, build: build);
}

GalLookupCalibrationDraft _quotedTextFittingDraft(
  GalLookupCalibrationDraft draft,
) {
  if (!draft.layout.quotedTextOnly) return draft;
  return GalLookupCalibrationDraft(
    rect: draft.rect,
    searchRect: draft.searchRect,
    layout: draft.layout,
    slot: draft.slot,
    layoutReferenceClient: draft.layoutReferenceClient,
    layoutCaptureMetadata: draft.layoutCaptureMetadata,
    samples: <GalCalibrationSample>[
      for (final GalCalibrationSample sample in draft.samples)
        if (galLookupGridSourceText(
              sample.capture.sourceText,
              quotedTextOnly: true,
            ) ==
            sample.capture.sourceText)
          sample
        else
          GalCalibrationSample(
            capture: GalLookupCalibrationCapture(
              sourceText: galLookupGridSourceText(
                sample.capture.sourceText,
                quotedTextOnly: true,
              ),
              pngBytes: sample.capture.pngBytes,
              referenceClient: sample.capture.referenceClient,
              exePath: sample.capture.exePath,
              exeSha256: sample.capture.exeSha256,
              sessionEpoch: sample.capture.sessionEpoch,
              occurrenceId: sample.capture.occurrenceId,
              targetHwnd: sample.capture.targetHwnd,
              capturedAt: sample.capture.capturedAt,
              selectedThreadKey: sample.capture.selectedThreadKey,
              sourceSequence: sample.capture.sourceSequence,
              captureMetadata: sample.capture.captureMetadata,
            ),
            validation: sample.validation,
          ),
    ],
  );
}

Future<GalCalibrationImageFit> _restoreQuotedFit(
  GalCalibrationImageFit fit,
  GalLookupCalibrationDraft original, {
  required GalCalibrationPreviewBuilder build,
}) async {
  final GalLookupCalibrationDraft? candidate = fit.draft;
  if (candidate == null) return fit;
  if (candidate.samples.length != original.samples.length) {
    return const GalCalibrationImageFit(reason: 'inconsistent_samples');
  }
  final GalLookupCalibrationDraft fitted = original.layout.quotedTextOnly
      ? GalLookupCalibrationDraft(
          rect: candidate.rect,
          searchRect: candidate.searchRect,
          layout: candidate.layout,
          samples: original.samples,
          slot: candidate.slot ?? original.slot,
          layoutReferenceClient: candidate.layoutReferenceClient,
          layoutCaptureMetadata: candidate.layoutCaptureMetadata,
        )
      : candidate;
  for (int index = 0; index < fitted.samples.length; index++) {
    final GalCalibrationSample sample = fitted.samples[index];
    final GalCalibrationPreview preview = await build(
      text: sample.capture.sourceText,
      client: sample.capture.referenceClient,
      rect: fitted.rect,
      layout: fitted.layout,
    );
    if (!preview.accepted) {
      return GalCalibrationImageFit(
        reason: 'preview_rejected',
        sampleIndex: index,
      );
    }
  }
  return original.layout.quotedTextOnly
      ? GalCalibrationImageFit(draft: fitted)
      : fit;
}

class _InkRow {
  const _InkRow(this.top, this.bottom, this.left, this.right, this.columns);
  final int top;
  final int bottom;
  final int left;
  final int right;
  final List<int> columns;
  int get height => bottom - top;
}

class _SampleInk {
  const _SampleInk(this.sample, this.rows, this.width, this.height);
  final GalCalibrationSample sample;
  final List<_InkRow> rows;
  final int width;
  final int height;
}

class _GridFit {
  const _GridFit(this.columns, this.indent, this.pitch, this.left, this.score);
  final int columns;
  final int indent;
  final double pitch;
  final double left;
  final double score;
}

enum _InkMode { light, dark, brightColor, darkColor, localContrast, edge }

bool _space(int unit) => unit == 0x20 || unit == 0x3000;
bool _newline(int unit) => unit == 10 || unit == 13;
bool _quoted(String text) => text.startsWith('「') || text.startsWith('『');
bool _centered(int unit) =>
    unit >= 0x3041 && unit <= 0x3096 ||
    unit >= 0x30a1 && unit <= 0x30fa ||
    unit >= 0x3400 && unit <= 0x9fff;

bool _combining(int rune) =>
    rune >= 0x0300 && rune <= 0x036f ||
    rune >= 0x1ab0 && rune <= 0x1aff ||
    rune >= 0x1dc0 && rune <= 0x1dff ||
    rune >= 0x20d0 && rune <= 0x20ff ||
    rune >= 0xfe00 && rune <= 0xfe0f ||
    rune >= 0xfe20 && rune <= 0xfe2f ||
    rune >= 0x1f3fb && rune <= 0x1f3ff ||
    rune >= 0xe0100 && rune <= 0xe01ef;

/// The native grid consumes one logical glyph cell.  The old allow-list made
/// the screenshot fitter reject otherwise usable sentences before it even
/// looked at the pixels (Latin, symbols and combining marks were common
/// examples).  Reject only control text here; the runtime performs the same
/// logical-unit grouping and can still fail closed on an invalid layout.
bool _eligible(String text) {
  if (text.isEmpty || text.length > GalLookupCalibrationCapture.maxTextLength) {
    return false;
  }
  for (final int rune in text.runes) {
    if (_space(rune) || _newline(rune) || rune == 0x09) continue;
    if (rune < 0x20 || rune >= 0x7f && rune <= 0x9f) return false;
  }
  return true;
}

List<int> _logicalUnits(String text) {
  final List<int> units = <int>[];
  for (final int rune in text.runes) {
    if (_combining(rune) &&
        units.isNotEmpty &&
        !_newline(units.last) &&
        !_space(units.last) &&
        units.last != 0x09) {
      continue;
    }
    units.add(rune);
  }
  return units;
}

List<List<int>> _lines(String text, int capacity, int indent) {
  final String content = text.trimRight();
  final bool hasHookBreak = content.contains('\r') || content.contains('\n');
  final List<List<int>> lines = [[]];
  int previous = 0;
  for (final int unit in _logicalUnits(text)) {
    if (_newline(unit)) {
      if (unit != 10 || previous != 13) lines.add([]);
    } else {
      final int limit = capacity - (lines.length == 1 ? 0 : indent);
      if (!hasHookBreak && lines.last.length == limit) lines.add([]);
      lines.last.add(unit);
    }
    previous = unit;
  }
  while (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// A rough selection can include a few bright pixels from the surrounding
/// artwork. Discard only tiny, isolated islands, never another text-sized run.
/// Punctuation near its neighbours stays part of the same run; a whole short
/// line is also retained. The remaining ink still has to explain every cell.
void _removeIsolatedSpecks(List<int> columns, int rowHeight) {
  final List<(int, int)> groups = [];
  int start = -1;
  int previous = -1;
  for (int x = 0; x < columns.length; x++) {
    if (columns[x] < 2) continue;
    if (start < 0) {
      start = x;
    } else if (x - previous > rowHeight * 1.5) {
      groups.add((start, previous + 1));
      start = x;
    }
    previous = x;
  }
  if (start >= 0) groups.add((start, previous + 1));
  if (groups.length < 2) return;
  final int total = columns.fold<int>(0, (int a, int b) => a + b);
  for (final (int left, int right) in groups) {
    if (right - left > rowHeight * 0.5) continue;
    int ink = 0;
    for (int x = left; x < right; x++) {
      ink += columns[x];
    }
    if (ink <= math.max(4, rowHeight * 0.5) && ink <= total * 0.01) {
      columns.fillRange(left, right, 0);
    }
  }
}

_SampleInk? _measure(
  GalCalibrationSample sample,
  GalLookupNormalizedRectV1 rect,
  _InkMode mode,
) {
  final img.Image? decoded = img.decodePng(sample.capture.pngBytes);
  if (decoded == null ||
      decoded.width != sample.capture.referenceClient.widthPx ||
      decoded.height != sample.capture.referenceClient.heightPx) {
    return null;
  }
  final double scale = math.min(1, 1600 / decoded.width);
  final img.Image image = scale == 1
      ? decoded
      : img.copyResize(
          decoded,
          width: (decoded.width * scale).round(),
          height: (decoded.height * scale).round(),
        );
  final int left = (rect.left * image.width).floor();
  final int right = (rect.right * image.width).ceil().clamp(0, image.width);
  final int top = (rect.top * image.height).floor();
  final int bottom = (rect.bottom * image.height).ceil().clamp(0, image.height);
  final int width = right - left;
  final int height = bottom - top;
  if (width < 16 || height < 8) return null;
  final Uint8List mask = Uint8List(width * height);
  final List<int> totals = List<int>.filled(height, 0);
  Float64List? integral;
  int integralStride = 0;
  Float32List? luminance;
  if (mode == _InkMode.localContrast) {
    // The local window is queried only inside the selected body crop.  Keep
    // the integral image crop-sized; allocating one for a full 32 MP capture
    // would waste hundreds of MB while adding no signal to the fit.
    integralStride = width + 1;
    integral = Float64List((height + 1) * integralStride);
    for (int y = 0; y < height; y++) {
      double rowSum = 0;
      for (int x = 0; x < width; x++) {
        final img.Pixel pixel = image.getPixel(left + x, top + y);
        final double value =
            pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
        rowSum += value;
        integral[(y + 1) * integralStride + x + 1] =
            integral[y * integralStride + x + 1] + rowSum;
      }
    }
  } else if (mode == _InkMode.edge) {
    // A dialogue line without a panel can have nearly the same average
    // brightness as the artwork behind it.  Keep one cheap grayscale plane
    // for an edge mask so outlines/shadows remain detectable without OCR.
    luminance = Float32List(width * height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final img.Pixel pixel = image.getPixel(left + x, top + y);
        luminance[y * width + x] =
            pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
      }
    }
  }
  for (int y = top; y < bottom; y++) {
    for (int x = left; x < right; x++) {
      final img.Pixel pixel = image.getPixel(x, y);
      final num low = math.min(pixel.r, math.min(pixel.g, pixel.b));
      final num high = math.max(pixel.r, math.max(pixel.g, pixel.b));
      final double brightness =
          pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114;
      bool ink;
      switch (mode) {
        case _InkMode.light:
          ink = high - low < 65 && low >= 195;
        case _InkMode.dark:
          ink = high - low < 65 && high <= 60;
        case _InkMode.brightColor:
          ink = brightness >= 175;
        case _InkMode.darkColor:
          ink = brightness <= 100;
        case _InkMode.localContrast:
          final Float64List contrastIntegral = integral!;
          const int radius = 4;
          final int localX = x - left;
          final int localY = y - top;
          final int x0 = math.max(0, localX - radius);
          final int y0 = math.max(0, localY - radius);
          final int x1 = math.min(width - 1, localX + radius);
          final int y1 = math.min(height - 1, localY + radius);
          final double area = (x1 - x0 + 1) * (y1 - y0 + 1).toDouble();
          final double sum =
              contrastIntegral[(y1 + 1) * integralStride + x1 + 1] -
              contrastIntegral[y0 * integralStride + x1 + 1] -
              contrastIntegral[(y1 + 1) * integralStride + x0] +
              contrastIntegral[y0 * integralStride + x0];
          // Anti-aliased and saturated glyphs may have only a modest
          // luminance delta from the artwork behind them.  Keep the local
          // threshold below the old binary-mask cutoff; isolated background
          // texture is removed by the row/grid consistency checks below.
          ink = (brightness - sum / area).abs() >= 12;
        case _InkMode.edge:
          final Float32List edgeLuminance = luminance!;
          final int localX = x - left;
          final int localY = y - top;
          final int offset = localY * width + localX;
          final double center = edgeLuminance[offset];
          double edge = 0;
          if (localX > 0) {
            edge = math.max(edge, (center - edgeLuminance[offset - 1]).abs());
          }
          if (localX + 1 < width) {
            edge = math.max(edge, (center - edgeLuminance[offset + 1]).abs());
          }
          if (localY > 0) {
            edge = math.max(
              edge,
              (center - edgeLuminance[offset - width]).abs(),
            );
          }
          if (localY + 1 < height) {
            edge = math.max(
              edge,
              (center - edgeLuminance[offset + width]).abs(),
            );
          }
          ink = edge >= 10;
      }
      if (ink) {
        mask[(y - top) * width + x - left] = 1;
        totals[y - top]++;
      }
    }
  }
  // Blank scanlines separate text rows. A border alone cannot form a row.
  final int peak = totals.fold<int>(0, math.max);
  final double threshold = mode == _InkMode.edge
      ? math.max(4, peak * 0.07)
      : math.max(3, peak * 0.04);
  final List<(int, int)> bands = [];
  int start = -1;
  int end = -1;
  for (int y = 0; y <= height; y++) {
    if (y < height && totals[y] >= threshold) {
      if (start < 0) start = y;
      end = y + 1;
    } else if (start >= 0 && (y == height || y - end >= 2)) {
      if (end - start >= math.max(6, image.height * 0.012)) {
        bands.add((start, end));
      }
      start = -1;
    }
  }
  final List<_InkRow> rows = [];
  for (final (int a, int b) in bands) {
    if (b - a > image.height * 0.12) continue;
    final List<int> columns = List<int>.filled(image.width, 0);
    for (int y = a; y < b; y++) {
      for (int x = 0; x < width; x++) {
        columns[left + x] += mask[y * width + x];
      }
    }
    _removeIsolatedSpecks(columns, b - a);
    final int first = columns.indexWhere((int v) => v >= 2);
    final int last = columns.lastIndexWhere((int v) => v >= 2);
    if (first < 0 || last - first < (b - a) * 1.2) continue;
    rows.add(_InkRow(top + a, top + b, first, last + 1, columns));
  }
  if (rows.isEmpty) return null;
  final int tallest = rows.map((_InkRow r) => r.height).reduce(math.max);
  final List<_InkRow> textRows = rows
      .where((_InkRow r) => r.height >= tallest * 0.7)
      .toList();
  if (textRows.isEmpty || textRows.length > 6) return null;
  return _SampleInk(sample, textRows, image.width, image.height);
}

double _score(
  _SampleInk sample,
  int capacity,
  int indent,
  double pitch,
  double origin,
) {
  final List<List<int>> lines = _lines(
    sample.sample.capture.sourceText,
    capacity,
    indent,
  );
  if (lines.length != sample.rows.length) return double.infinity;
  double score = 0;
  int glyphs = 0;
  for (int r = 0; r < lines.length; r++) {
    final _InkRow row = sample.rows[r];
    final List<int> units = lines[r];
    final double start = origin + (r == 0 ? 0 : indent * pitch);
    if (units.isEmpty ||
        start > row.left + 1 ||
        start + units.length * pitch < row.right - 1) {
      return double.infinity;
    }
    // A match must explain every visible stroke, not only a convenient subset.
    if (row.left - start > pitch * 0.85 ||
        start + units.length * pitch - row.right > pitch * 0.85) {
      return double.infinity;
    }
    for (int c = 0; c < units.length; c++) {
      final int a = (start + c * pitch).round().clamp(0, sample.width);
      final int b = (start + (c + 1) * pitch).round().clamp(0, sample.width);
      int ink = 0;
      int first = -1;
      int last = -1;
      int boundary = 0;
      final int margin = math.max(1, (pitch * 0.055).round());
      for (int x = a; x < b; x++) {
        final int value = row.columns[x];
        ink += value;
        if (value >= 2) {
          if (first < 0) first = x;
          last = x;
        }
        if (x - a < margin || b - x <= margin) boundary += value;
      }
      if (_space(units[c])) {
        if (ink > row.height * 0.3) return double.infinity;
        continue;
      }
      if (first < 0 || ink < 4) return double.infinity;
      glyphs++;
      score += 4 * boundary / ink;
      if (_centered(units[c])) {
        final double offset = ((first + last + 1) / 2 - (a + b) / 2) / pitch;
        score += offset * offset * 4;
      }
    }
  }
  return glyphs < 4 ? double.infinity : score / glyphs;
}

_GridFit? _fitSample(_SampleInk sample) {
  if (sample.rows.length < 2) return null;
  final int length = _logicalUnits(sample.sample.capture.sourceText).length;
  final double inkHeight = _median(
    sample.rows.map((_InkRow r) => r.height.toDouble()).toList(),
  );
  final List<_GridFit> candidates = [];
  for (int capacity = 4; capacity <= math.min(128, length); capacity++) {
    for (int indent = 0; indent <= 8 && indent < capacity; indent++) {
      final List<List<int>> lines = _lines(
        sample.sample.capture.sourceText,
        capacity,
        indent,
      );
      if (lines.length != sample.rows.length ||
          lines.any((List<int> l) => l.isEmpty)) {
        continue;
      }
      final double nominal = _median([
        for (int row = 0; row < lines.length; row++)
          (sample.rows[row].right - sample.rows[row].left) / lines[row].length,
      ]);
      _GridFit? best;
      // Use all visible rows as the pitch estimate and search on both sides of
      // it. The old first-row-only, positive-only search rejected games whose
      // first line had punctuation/spacing unlike the continuation line.
      for (int step = -50; step <= 50; step++) {
        final double pitch = nominal * (1 + step * 0.003);
        if (pitch < inkHeight * 0.65 || pitch > inkHeight * 1.6) continue;
        for (int phase = 0; phase <= 20; phase++) {
          final double origin = sample.rows.first.left - pitch * phase * 0.025;
          if (origin < 0 || origin + capacity * pitch > sample.width) continue;
          final double score = _score(sample, capacity, indent, pitch, origin);
          if (best == null || score < best.score) {
            best = _GridFit(capacity, indent, pitch, origin, score);
          }
        }
      }
      if (best != null && best.score.isFinite) candidates.add(best);
    }
  }
  candidates.sort((_GridFit a, _GridFit b) => a.score.compareTo(b.score));
  if (candidates.isEmpty || candidates.first.score >= 0.09) return null;
  // E.g. explicit newlines reveal row locations but not the soft-wrap column.
  // Do not turn two equally plausible wrap/indent rules into a saved profile.
  if (candidates.length > 1 &&
      candidates[1].score - candidates.first.score < 0.025) {
    return null;
  }
  return candidates.first;
}

/// Pure worker entry point. Held-out samples never select the grid, but every
/// saved sample must agree with it before a replacement draft is returned.
GalCalibrationImageFit inferGalCalibrationGrid(
  GalLookupCalibrationDraft draft,
) {
  if (draft.samples.isEmpty || !draft.searchRect.isValid) {
    return const GalCalibrationImageFit(reason: 'unsupported_text');
  }
  for (int index = 0; index < draft.samples.length; index++) {
    if (!_eligible(draft.samples[index].capture.sourceText)) {
      return GalCalibrationImageFit(
        reason: 'unsupported_text',
        sampleIndex: index,
      );
    }
  }
  String failure = 'image_grid_ambiguous';
  int? failedSample;
  bool multilineEvidence = false;
  GalLookupCalibrationDraft? bestDraft;
  double bestQuality = double.infinity;
  for (final _InkMode mode in _InkMode.values) {
    final List<_SampleInk> samples = [];
    for (final GalCalibrationSample sample in draft.samples) {
      final _SampleInk? measured = _measure(sample, draft.searchRect, mode);
      if (measured == null) {
        if (failedSample == null) {
          failure = 'text_rows_not_found';
          failedSample = samples.length;
        }
        break;
      }
      samples.add(measured);
    }
    if (samples.length != draft.samples.length) continue;
    final List<_SampleInk> trainingSamples = samples
        .where((_SampleInk s) => !s.sample.validation)
        .toList();
    if (trainingSamples.any((_SampleInk s) => s.rows.length >= 2)) {
      multilineEvidence = true;
    }
    final List<(_SampleInk, _GridFit)> training = [];
    for (final _SampleInk sample in trainingSamples) {
      final _GridFit? fitted = _fitSample(sample);
      if (fitted != null) training.add((sample, fitted));
    }
    if (training.isEmpty) continue;
    final int columns = training.first.$2.columns;
    if (training.any((item) => item.$2.columns != columns)) continue;
    final List<int> plainIndents = [
      for (final item in training)
        if (!_quoted(item.$1.sample.capture.sourceText)) item.$2.indent,
    ];
    final List<int> quoteIndents = [
      for (final item in training)
        if (_quoted(item.$1.sample.capture.sourceText)) item.$2.indent,
    ];
    if (plainIndents.toSet().length > 1 || quoteIndents.toSet().length > 1) {
      continue;
    }
    final int plainIndent = plainIndents.isEmpty ? 0 : plainIndents.first;
    final int quoteIndent = quoteIndents.isEmpty
        ? plainIndent
        : quoteIndents.first;
    final double pitch = _median([
      for (final item in training) item.$2.pitch / item.$1.height,
    ]);
    final double left = _median([
      for (final item in training) item.$2.left / item.$1.width,
    ]);
    final double top = _median([
      for (final item in training)
        (item.$1.rows.first.top - 1) / item.$1.height,
    ]);
    final double cellHeight = _median([
      for (final item in training)
        for (final _InkRow row in item.$1.rows)
          (row.height + 2) / item.$1.height,
    ]);
    final double lineAdvance = _median([
      for (final item in training)
        for (int i = 1; i < item.$1.rows.length; i++)
          (item.$1.rows[i].top - item.$1.rows[i - 1].top) / item.$1.height,
    ]);
    if (lineAdvance < cellHeight) continue;
    bool valid = true;
    // Edge masks are a deliberate last resort for text over artwork. Prefer
    // a color/contrast mask whenever both explain the same samples; edge
    // pixels sit on the outline and otherwise bias the fitted body upward.
    double quality = mode == _InkMode.edge ? 100 : 0;
    for (int index = 0; index < samples.length; index++) {
      final _SampleInk sample = samples[index];
      final double sampleScore = _score(
        sample,
        columns,
        _quoted(sample.sample.capture.sourceText) ? quoteIndent : plainIndent,
        pitch * sample.height,
        left * sample.width,
      );
      if (sampleScore > 0.12) {
        valid = false;
        failure = 'inconsistent_samples';
        failedSample = index;
        break;
      }
      quality += sampleScore;
      for (int row = 0; row < sample.rows.length; row++) {
        final double rowError =
            ((top + row * lineAdvance) * sample.height +
                    1 -
                    sample.rows[row].top)
                .abs();
        if (rowError > math.max(2, cellHeight * sample.height * 0.12)) {
          valid = false;
          failure = 'inconsistent_samples';
          failedSample = index;
          break;
        }
        quality += rowError / math.max(1, sample.height);
      }
      if (!valid) break;
    }
    if (!valid) continue;
    final double aspect = training.first.$1.width / training.first.$1.height;
    final double width = columns * pitch / aspect;
    if (left < 0 || top < 0 || left + width > 1 || top + cellHeight > 1) {
      continue;
    }
    final GalLookupCellGridV1 grid = GalLookupCellGridV1(
      advancePerClientHeight: pitch,
      lineAdvancePerClientHeight: lineAdvance,
      cellHeightPerClientHeight: cellHeight,
      columns: columns,
      continuationIndent: plainIndent.toDouble(),
      quotedContinuationIndent: quoteIndent.toDouble(),
    );
    if (!grid.isValid) continue;
    final GalLookupTextLayoutV1 layout = GalLookupTextLayoutV1(
      cellGrid: grid,
      quotedTextOnly: draft.layout.quotedTextOnly,
    );
    final GalLookupCalibrationDraft candidate = GalLookupCalibrationDraft(
      searchRect: draft.searchRect,
      rect: GalLookupNormalizedRectV1(
        left: left,
        top: top,
        width: width,
        height: math
            .max(cellHeight, draft.searchRect.bottom - top)
            .clamp(cellHeight, 1 - top),
      ),
      layout: layout,
      samples: draft.samples,
    );
    if (quality < bestQuality) {
      bestQuality = quality;
      bestDraft = candidate;
    }
  }
  if (bestDraft != null) {
    return GalCalibrationImageFit(draft: bestDraft);
  }
  return GalCalibrationImageFit(
    reason: multilineEvidence ? failure : 'multiline_required',
    sampleIndex: multilineEvidence ? failedSample : null,
  );
}

double _median(List<double> values) {
  values.sort();
  return values.length.isOdd
      ? values[values.length ~/ 2]
      : (values[values.length ~/ 2 - 1] + values[values.length ~/ 2]) / 2;
}
