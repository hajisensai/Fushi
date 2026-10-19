import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_draft.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/image_kernels.dart';
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
///
/// [isStale] 由调用方给（例如对话框的 `() => !mounted`）：返回 true 表示结果已经
/// 没人要了，助手应尽快停下并返回 [kGalCalibrationImageFitStale] 结果。
typedef GalCalibrationOcrAssist =
    Future<GalCalibrationImageFit?> Function(
      GalLookupCalibrationDraft draft, {
      required GalCalibrationPreviewBuilder build,
      bool Function()? isStale,
    });

/// [fitGalCalibrationImages] 的签名（校准对话框注入用）。
typedef GalCalibrationImageFitter =
    Future<GalCalibrationImageFit> Function(
      GalLookupCalibrationDraft draft, {
      GalCalibrationPreviewBuilder build,
      bool Function()? isStale,
    });

/// 拟合因调用方 `isStale()` 变 true 而中途放弃时的 [GalCalibrationImageFit.reason]。
/// 这个结果不是失败诊断，调用方（已关闭的对话框）应直接丢弃它。
const String kGalCalibrationImageFitStale = 'stale';

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
  bool Function()? isStale,
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
      isStale: isStale,
    );
    if (assisted != null) {
      if (assisted.reason == kGalCalibrationImageFitStale) return assisted;
      if (!draft.layout.quotedTextOnly) return assisted;
      return _restoreQuotedFit(assisted, draft, build: build);
    }
  }
  if (isStale?.call() ?? false) {
    return const GalCalibrationImageFit(reason: kGalCalibrationImageFitStale);
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
  final Int32List columns;
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

/// Hook 自带换行（去掉尾部空白后仍含 `\r` / `\n`）时只按换行切行、不按容量折行。
bool _hookBreak(String text) {
  final String content = text.trimRight();
  return content.contains('\r') || content.contains('\n');
}

/// The pixel measurement (decode, shrink to ≤1600 px wide, ink masks for all
/// six [_InkMode]s, blank-scanline row bands, speck removal) runs in the
/// native kernel (`ffc_gal_measure_ink`, bit-identical to the former Dart
/// loops). A rough selection can include a few bright pixels from the
/// surrounding artwork; only tiny, isolated islands are discarded, never
/// another text-sized run, and the remaining ink still has to explain every
/// cell. Returns one entry per mode, null where no text rows were found.
List<_SampleInk?> _measureAllModes(
  GalCalibrationSample sample,
  GalLookupNormalizedRectV1 rect,
) {
  const List<_SampleInk?> none = <_SampleInk?>[
    null,
    null,
    null,
    null,
    null,
    null,
  ];
  final img.Image? decoded = decodePngNative(sample.capture.pngBytes);
  if (decoded == null ||
      decoded.width != sample.capture.referenceClient.widthPx ||
      decoded.height != sample.capture.referenceClient.heightPx) {
    return none;
  }
  final ({Uint8List pixels, int stride, int channels, int width, int height})
  px = uint8Pixels(decoded);
  final List<FfcGalInk?> measured = FushiComputeGal.instance.measureInk(
    px,
    left: rect.left,
    top: rect.top,
    right: rect.right,
    bottom: rect.bottom,
  );
  return <_SampleInk?>[
    for (final FfcGalInk? m in measured)
      m == null
          ? null
          : _SampleInk(
              sample,
              <_InkRow>[
                for (final FfcGalInkRow r in m.rows)
                  _InkRow(r.top, r.bottom, r.left, r.right, r.columns),
              ],
              m.imageWidth,
              m.imageHeight,
            ),
  ];
}

List<FfcGalInkRow> _nativeRows(_SampleInk sample) => <FfcGalInkRow>[
  for (final _InkRow r in sample.rows)
    (
      top: r.top,
      bottom: r.bottom,
      left: r.left,
      right: r.right,
      columns: r.columns,
    ),
];

/// Grid score of one sample (native `ffc_gal_score`): every visible stroke
/// must be explained, spaces must stay empty, centred glyphs are penalised
/// for drifting off their cell centre.
double _score(
  _SampleInk sample,
  int capacity,
  int indent,
  double pitch,
  double origin,
) {
  final String text = sample.sample.capture.sourceText;
  return FushiComputeGal.instance.score(
    _nativeRows(sample),
    sample.width,
    units: _logicalUnits(text),
    hookBreak: _hookBreak(text),
    capacity: capacity,
    indent: indent,
    pitch: pitch,
    origin: origin,
  );
}

/// Searches capacity, continuation indent, pitch and phase for one sample
/// (native `ffc_gal_fit_sample`). All visible rows provide the pitch
/// estimate and the search runs on both sides of it; two equally plausible
/// wrap/indent rules are rejected rather than turned into a saved profile.
_GridFit? _fitSample(_SampleInk sample) {
  final String text = sample.sample.capture.sourceText;
  final FfcGalGridFit? fit = FushiComputeGal.instance.fitSample(
    _nativeRows(sample),
    sample.width,
    units: _logicalUnits(text),
    hookBreak: _hookBreak(text),
  );
  if (fit == null) return null;
  return _GridFit(fit.columns, fit.indent, fit.pitch, fit.left, fit.score);
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
  // Each sample is measured once for all six modes, on first use (the old
  // per-mode loop reached a sample only after every earlier one succeeded).
  final Map<int, List<_SampleInk?>> measuredModes = <int, List<_SampleInk?>>{};
  for (final _InkMode mode in _InkMode.values) {
    final List<_SampleInk> samples = [];
    for (int s = 0; s < draft.samples.length; s++) {
      final GalCalibrationSample sample = draft.samples[s];
      final _SampleInk? measured = (measuredModes[s] ??= _measureAllModes(
        sample,
        draft.searchRect,
      ))[mode.index];
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
