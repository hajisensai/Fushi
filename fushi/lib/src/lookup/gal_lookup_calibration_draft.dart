import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:fushi/src/lookup/gal_lookup_calibration_capture.dart';
import 'package:fushi/src/lookup/gal_lookup_calibration_preview.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:path/path.dart' as p;

/// Reference points belong to a frozen screenshot, never the live game. Their
/// normalized coordinates survive preview zoom without changing calibration.
class GalCalibrationSample {
  GalCalibrationSample({
    required this.capture,
    this.validation = false,
    Map<int, Offset> anchors = const {},
  }) : anchors = Map.unmodifiable(anchors);

  final GalLookupCalibrationCapture capture;
  final bool validation;
  final Map<int, Offset> anchors;

  GalCalibrationSample copyWith({
    bool? validation,
    Map<int, Offset>? anchors,
  }) => GalCalibrationSample(
    capture: capture,
    validation: validation ?? this.validation,
    anchors: anchors ?? this.anchors,
  );

  Map<String, Object?> toJson() => {
    'capture': capture.toJson(),
    'validation': validation,
    'anchors': [
      for (final MapEntry<int, Offset> anchor in anchors.entries)
        {'index': anchor.key, 'x': anchor.value.dx, 'y': anchor.value.dy},
    ],
  };

  static GalCalibrationSample fromJson(Map<String, dynamic> json) {
    const Set<String> expectedKeys = <String>{
      'capture',
      'validation',
      'anchors',
    };
    if (!_hasExactStringKeys(json, expectedKeys)) {
      throw const FormatException('sample_schema');
    }
    final GalLookupCalibrationCapture? capture =
        GalLookupCalibrationCapture.tryFromJson(json['capture']);
    if (capture == null) throw const FormatException('invalid_capture');
    final Map<int, Offset> anchors = {};
    if (json['validation'] is! bool || json['anchors'] is! List) {
      throw const FormatException('sample_schema');
    }
    final List<dynamic> rawAnchors = json['anchors'] as List<dynamic>;
    if (rawAnchors.length > 128) throw const FormatException('too_many_points');
    for (final dynamic raw in rawAnchors) {
      if (raw is! Map) throw const FormatException('invalid_point');
      final Map<Object?, Object?> pointMap = raw.cast<Object?, Object?>();
      if (!_hasExactStringKeys(pointMap, const <String>{'index', 'x', 'y'}) ||
          pointMap['index'] is! int ||
          pointMap['x'] is! num ||
          pointMap['y'] is! num) {
        throw const FormatException('invalid_point');
      }
      final int index = pointMap['index']! as int;
      final Offset point = Offset(
        (pointMap['x']! as num).toDouble(),
        (pointMap['y']! as num).toDouble(),
      );
      if (index < 0 ||
          index >= capture.sourceText.length ||
          !point.dx.isFinite ||
          !point.dy.isFinite ||
          point.dx < 0 ||
          point.dx > 1 ||
          point.dy < 0 ||
          point.dy > 1) {
        throw const FormatException('invalid_point');
      }
      if (anchors.containsKey(index)) {
        throw const FormatException('duplicate_point');
      }
      anchors[index] = point;
    }
    return GalCalibrationSample(
      capture: capture,
      validation: json['validation'] as bool,
      anchors: anchors,
    );
  }
}

class GalLookupCalibrationDraft {
  GalLookupCalibrationDraft({
    required this.rect,
    required this.layout,
    required List<GalCalibrationSample> samples,
    GalLookupNormalizedRectV1? searchRect,
    GalLookupReferenceClientV1? layoutReferenceClient,
    this.layoutCaptureMetadata,
    this.slot,
  }) : searchRect = searchRect ?? rect,
       samples = List.unmodifiable(samples),
       layoutReferenceClient =
           layoutReferenceClient ??
           (samples.isEmpty ? null : samples.first.capture.referenceClient);

  static const int maxSamples = 8;
  static const int maxSamplesPerSlot = 1;
  static const int maxImageBytes = 64 * 1024 * 1024;
  final GalLookupNormalizedRectV1 rect;

  /// User-owned OCR crop; fitted runtime geometry is stored separately in rect.
  final GalLookupNormalizedRectV1 searchRect;
  final GalLookupTextLayoutV1 layout;
  final List<GalCalibrationSample> samples;

  /// The frozen client dimensions that the fitted layout was measured against.
  /// Older notebooks did not persist this and therefore use their first sample.
  final GalLookupReferenceClientV1? layoutReferenceClient;

  /// Provenance of the image used to fit this layout, independent of which
  /// sample is currently selected or subsequently removed.
  final WindowCaptureMetadata? layoutCaptureMetadata;
  final GalLookupCalibrationSlotV1? slot;

  static const Set<String> _requiredJsonKeys = <String>{
    'version',
    'bodyRect',
    'layout',
    'samples',
  };
  static const Set<String> _optionalJsonKeys = <String>{
    'searchRect',
    'slot',
    'layoutReferenceClient',
    'layoutCaptureMetadata',
  };

  bool validFor(String hash) =>
      RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) &&
      rect.isValid &&
      searchRect.isValid &&
      layout.isValid &&
      (layoutReferenceClient?.isValid ?? true) &&
      (layoutCaptureMetadata == null ||
          (layoutReferenceClient != null &&
              layoutCaptureMetadata!.imageWidthPx ==
                  layoutReferenceClient!.widthPx &&
              layoutCaptureMetadata!.imageHeightPx ==
                  layoutReferenceClient!.heightPx &&
              layoutCaptureMetadata!.dpi == layoutReferenceClient!.dpi)) &&
      samples.length <= maxSamples &&
      (slot == null || samples.length <= maxSamplesPerSlot) &&
      samples.every((GalCalibrationSample s) => s.capture.exeSha256 == hash) &&
      samples.fold<int>(
            0,
            (int n, GalCalibrationSample s) => n + s.capture.pngBytes.length,
          ) <=
          maxImageBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'bodyRect': rect.toJson(),
    'searchRect': searchRect.toJson(),
    'layout': layout.toJson(),
    'samples': samples.map((GalCalibrationSample s) => s.toJson()).toList(),
    if (slot != null) 'slot': slot!.wireName,
    if (layoutReferenceClient != null)
      'layoutReferenceClient': layoutReferenceClient!.toJson(),
    if (layoutCaptureMetadata != null)
      'layoutCaptureMetadata': layoutCaptureMetadata!.toJson(),
  };

  static GalLookupCalibrationDraft fromJson(Map<String, dynamic> json) {
    if (!_requiredJsonKeys.every(json.containsKey) ||
        json.keys.any(
          (String key) =>
              !_requiredJsonKeys.contains(key) &&
              !_optionalJsonKeys.contains(key),
        )) {
      throw const FormatException('draft_schema');
    }
    if (json['version'] != 1) throw const FormatException('draft_version');
    final GalLookupCalibrationSlotV1? slot = json.containsKey('slot')
        ? GalLookupCalibrationSlotV1.fromWireName(json['slot'])
        : null;
    if (json.containsKey('slot') && slot == null) {
      throw const FormatException('draft_slot');
    }
    final GalLookupNormalizedRectV1? rect =
        GalLookupNormalizedRectV1.tryFromJson(json['bodyRect']);
    final GalLookupTextLayoutV1? layout = GalLookupTextLayoutV1.tryFromJson(
      json['layout'],
    );
    final GalLookupNormalizedRectV1? searchRect = json.containsKey('searchRect')
        ? GalLookupNormalizedRectV1.tryFromJson(json['searchRect'])
        : rect;
    final List<dynamic> raw = json['samples'] as List<dynamic>;
    if (rect == null ||
        searchRect == null ||
        layout == null ||
        raw.length > maxSamples ||
        (slot != null && raw.length > maxSamplesPerSlot)) {
      throw const FormatException('invalid_draft');
    }
    final List<GalCalibrationSample> samples = raw
        .map(
          (dynamic item) => GalCalibrationSample.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
        )
        .toList();
    final bool hasLayoutReference = json.containsKey('layoutReferenceClient');
    final GalLookupReferenceClientV1? layoutReferenceClient = hasLayoutReference
        ? GalLookupReferenceClientV1.tryFromJson(json['layoutReferenceClient'])
        : null;
    if (hasLayoutReference && layoutReferenceClient == null) {
      throw const FormatException('invalid_draft');
    }
    final WindowCaptureMetadata? layoutCaptureMetadata =
        WindowCaptureMetadata.tryFromMap(json['layoutCaptureMetadata']);
    if (json.containsKey('layoutCaptureMetadata') &&
        layoutCaptureMetadata == null) {
      throw const FormatException('invalid_draft');
    }
    return GalLookupCalibrationDraft(
      rect: rect,
      searchRect: searchRect,
      layout: layout,
      samples: samples,
      layoutReferenceClient: layoutReferenceClient,
      layoutCaptureMetadata: layoutCaptureMetadata,
      slot: slot,
    );
  }

  GalLookupCalibrationDraft copyWith({
    GalLookupCalibrationSlotV1? slot,
    bool clearSlot = false,
  }) => GalLookupCalibrationDraft(
    rect: rect,
    searchRect: searchRect,
    layout: layout,
    samples: samples,
    layoutReferenceClient: layoutReferenceClient,
    layoutCaptureMetadata: layoutCaptureMetadata,
    slot: clearSlot ? null : slot ?? this.slot,
  );
}

/// Private, bounded drafts live under the app support root. No images/text are
/// placed in the source checkout, logs, preferences or an exported profile.
class GalLookupCalibrationStore {
  const GalLookupCalibrationStore({this.directory});
  final Directory? directory;

  Future<File> _file(String hash, {GalLookupCalibrationSlotV1? slot}) async {
    if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('invalid_executable_hash');
    }
    final Directory root =
        directory ??
        Directory(
          p.join(
            (await AppPaths.supportRootDirectory()).path,
            'gal_lookup_calibration',
          ),
        );
    await root.create(recursive: true);
    final String suffix = slot == null ? '' : '.${slot.wireName}';
    return File(p.join(root.path, '${hash.toLowerCase()}$suffix.json'));
  }

  Future<GalLookupCalibrationDraft?> load(
    String hash, {
    GalLookupCalibrationSlotV1? slot,
  }) async {
    File file = await _file(hash, slot: slot);
    // A legacy shared draft remains a readable seed for either fixed slot. It
    // is never overwritten when a slot-specific draft is later saved.
    if (slot != null && !await file.exists()) {
      file = await _file(hash);
    }
    if (!await file.exists()) return null;
    if (await file.length() > 92 * 1024 * 1024) {
      throw const FormatException('draft_too_large');
    }
    final GalLookupCalibrationDraft draft = GalLookupCalibrationDraft.fromJson(
      (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>(),
    );
    if (!draft.validFor(hash)) throw const FormatException('draft_identity');
    if (slot != null && draft.slot != null && draft.slot != slot) {
      throw const FormatException('draft_slot_mismatch');
    }
    return draft;
  }

  Future<void> save(
    String hash,
    GalLookupCalibrationDraft draft, {
    GalLookupCalibrationSlotV1? slot,
  }) async {
    if (!draft.validFor(hash)) throw const FormatException('invalid_draft');
    if (slot != null && draft.slot != null && draft.slot != slot) {
      throw const FormatException('draft_slot_mismatch');
    }
    final GalLookupCalibrationDraft persisted =
        slot != null && draft.slot == null ? draft.copyWith(slot: slot) : draft;
    if (!persisted.validFor(hash)) {
      throw const FormatException('invalid_draft');
    }
    final File file = await _file(hash, slot: slot ?? draft.slot);
    // A newer or invalid on-disk draft must survive a failed load. Capturing a
    // replacement cannot silently downgrade or erase fields we cannot read.
    if (await file.exists()) {
      await load(hash, slot: slot ?? draft.slot);
    }
    final File pending = File('${file.path}.pending');
    await pending.writeAsString(jsonEncode(persisted.toJson()), flush: true);
    await pending.rename(file.path);
  }
}

bool _hasExactStringKeys(Map<Object?, Object?> map, Set<String> expected) =>
    map.length == expected.length &&
    map.keys.every((Object? key) => key is String && expected.contains(key));

GalLookupTextLayoutV1 copyGalCalibrationLayout(
  GalLookupTextLayoutV1 layout, {
  String? fontFamily,
  double? fontSize,
  double? tracking,
  double? lineHeight,
  bool clearCellGrid = false,
  bool? quotedTextOnly,
  List<GalLookupPunctuationVisualBoundV1>? punctuationVisualBounds,
}) => GalLookupTextLayoutV1(
  fontFamily: fontFamily ?? layout.fontFamily,
  fontSizePerClientHeight: fontSize ?? layout.fontSizePerClientHeight,
  letterSpacingPerClientHeight: tracking ?? layout.letterSpacingPerClientHeight,
  lineHeight: lineHeight ?? layout.lineHeight,
  textAlign: layout.textAlign,
  verticalAlign: layout.verticalAlign,
  paddingPerClientHeight: layout.paddingPerClientHeight,
  cellGrid: clearCellGrid ? null : layout.cellGrid,
  quotedTextOnly: quotedTextOnly ?? layout.quotedTextOnly,
  punctuationVisualBounds: clearCellGrid
      ? const <GalLookupPunctuationVisualBoundV1>[]
      : punctuationVisualBounds ?? layout.punctuationVisualBounds,
  characterAdvances: clearCellGrid
      ? const <GalLookupCharacterAdvanceV1>[]
      : layout.characterAdvances,
);

/// Fits only translation and character spacing. Font, wrapping area and line
/// spacing remain explicit user choices; held-out samples never train the fit.
/// Numerical derivatives come from the SAME native layout as click handling.
Future<GalLookupCalibrationDraft?> fitGalCalibrationAnchors(
  GalLookupCalibrationDraft draft, {
  GalCalibrationPreviewBuilder build = GalLookupCalibrationPreviewChannel.build,
}) async {
  final List<GalCalibrationSample> training = draft.samples
      .where((GalCalibrationSample s) => !s.validation && s.anchors.isNotEmpty)
      .toList();
  if (training.isEmpty ||
      draft.layout.textAlign != 'left' ||
      draft.layout.cellGrid != null) {
    return null;
  }
  final List<
    ({double derivative, double dx, double dy, double aspect, double pixel})
  >
  rows = [];
  bool hasSeparatedPair = false;
  for (final GalCalibrationSample sample in training) {
    final GalLookupReferenceClientV1 client = sample.capture.referenceClient;
    final GalCalibrationPreview baseline = await build(
      text: sample.capture.sourceText,
      client: client,
      rect: draft.rect,
      layout: draft.layout,
    );
    if (!baseline.accepted) return null;
    // One physical pixel of tracking makes finite differences observable even
    // though the production hit regions round their edges to integer pixels.
    final double step = -1 / client.heightPx;
    final GalCalibrationPreview shifted = await build(
      text: sample.capture.sourceText,
      client: client,
      rect: draft.rect,
      layout: copyGalCalibrationLayout(
        draft.layout,
        tracking: draft.layout.letterSpacingPerClientHeight + step,
      ),
    );
    if (!shifted.accepted) return null;
    final List<GalCalibrationBox> marked = [];
    for (final MapEntry<int, Offset> anchor in sample.anchors.entries) {
      final GalCalibrationBox? box = baseline.boxForIndex(anchor.key);
      final GalCalibrationBox? moved = shifted.boxForIndex(anchor.key);
      if (box == null ||
          moved == null ||
          (box.rect.center.dy - moved.rect.center.dy).abs() > 1) {
        return null;
      }
      marked.add(box);
      rows.add((
        derivative:
            (moved.rect.center.dx - box.rect.center.dx) / client.widthPx / step,
        dx: anchor.value.dx - box.rect.center.dx / client.widthPx,
        dy: anchor.value.dy - box.rect.center.dy / client.heightPx,
        aspect: client.widthPx / client.heightPx,
        pixel: 1 / client.heightPx,
      ));
    }
    for (final GalCalibrationBox a in marked) {
      for (final GalCalibrationBox b in marked) {
        if ((a.rect.center.dy - b.rect.center.dy).abs() <= 1 &&
            (a.rect.center.dx - b.rect.center.dx).abs() > a.rect.width) {
          hasSeparatedPair = true;
        }
      }
    }
  }
  if (!hasSeparatedPair || rows.length < 2) return null;
  // Two points cannot reveal an inaccurate mark. With enough redundancy,
  // median pair slopes provide an initial estimate independent of a single
  // extreme mark. Tukey weights then limit that mark's influence. The UI's
  // reported error still includes EVERY mark, including held-out samples.
  final List<double> weights = List<double>.filled(rows.length, 1);
  if (rows.length >= 6) {
    final List<double> slopes = [];
    for (int a = 0; a < rows.length; a++) {
      for (int b = a + 1; b < rows.length; b++) {
        final double separation = rows[b].derivative - rows[a].derivative;
        if (separation.abs() > 1e-6) {
          slopes.add((rows[b].dx - rows[a].dx) / separation);
        }
      }
    }
    if (slopes.isNotEmpty) {
      final double slope = _calibrationMedian(slopes);
      final double origin = _calibrationMedian([
        for (final row in rows) row.dx - slope * row.derivative,
      ]);
      final double vertical = _calibrationMedian([
        for (final row in rows) row.dy,
      ]);
      final List<double> residuals = [
        for (final row in rows)
          Offset(
            (row.dx - origin - slope * row.derivative) * row.aspect,
            row.dy - vertical,
          ).distance,
      ];
      final double cutoff = math.max(
        4.685 * 1.4826 * _calibrationMedian(residuals.toList()),
        rows.map((row) => row.pixel * 2).reduce(math.max),
      );
      final List<double> robust = [
        for (final double residual in residuals)
          residual >= cutoff
              ? 0
              : math.pow(1 - math.pow(residual / cutoff, 2), 2).toDouble(),
      ];
      if (robust.where((double weight) => weight > 0).length >= 4) {
        weights.setAll(0, robust);
      }
    }
  }
  final double weightTotal = weights.reduce((double a, double b) => a + b);
  final double meanD =
      List<double>.generate(
        rows.length,
        (int i) => rows[i].derivative * weights[i],
      ).reduce((double a, double b) => a + b) /
      weightTotal;
  final double meanX =
      List<double>.generate(
        rows.length,
        (int i) => rows[i].dx * weights[i],
      ).reduce((double a, double b) => a + b) /
      weightTotal;
  final double meanY =
      List<double>.generate(
        rows.length,
        (int i) => rows[i].dy * weights[i],
      ).reduce((double a, double b) => a + b) /
      weightTotal;
  double variance = 0;
  double covariance = 0;
  for (int i = 0; i < rows.length; i++) {
    final row = rows[i];
    variance += weights[i] * math.pow(row.derivative - meanD, 2).toDouble();
    covariance += weights[i] * (row.derivative - meanD) * (row.dx - meanX);
  }
  if (variance < 1e-8) return null;
  final double spacingDelta = covariance / variance;
  final GalLookupNormalizedRectV1 rect = GalLookupNormalizedRectV1(
    left: draft.rect.left + meanX - meanD * spacingDelta,
    top: draft.rect.top + meanY,
    width: draft.rect.width,
    height: draft.rect.height,
  );
  final GalLookupTextLayoutV1 layout = copyGalCalibrationLayout(
    draft.layout,
    tracking: draft.layout.letterSpacingPerClientHeight + spacingDelta,
  );
  if (!rect.isValid || !layout.isValid) return null;
  for (final GalCalibrationSample sample in draft.samples) {
    final GalCalibrationPreview candidate = await build(
      text: sample.capture.sourceText,
      client: sample.capture.referenceClient,
      rect: rect,
      layout: layout,
    );
    if (!candidate.accepted) return null;
  }
  // Reject a fit that changes the line of any marked character. A linear
  // spacing model cannot prove correspondence across a wrapping discontinuity.
  double before = 0;
  double after = 0;
  int rowIndex = 0;
  for (final GalCalibrationSample sample in training) {
    final GalLookupReferenceClientV1 client = sample.capture.referenceClient;
    final GalCalibrationPreview original = await build(
      text: sample.capture.sourceText,
      client: client,
      rect: draft.rect,
      layout: draft.layout,
    );
    final GalCalibrationPreview fitted = await build(
      text: sample.capture.sourceText,
      client: client,
      rect: rect,
      layout: layout,
    );
    if (!fitted.accepted) return null;
    for (final MapEntry<int, Offset> anchor in sample.anchors.entries) {
      final GalCalibrationBox? a = original.boxForIndex(anchor.key);
      final GalCalibrationBox? b = fitted.boxForIndex(anchor.key);
      if (a == null ||
          b == null ||
          ((b.rect.center.dy - a.rect.center.dy) / client.heightPx - meanY)
                  .abs() >
              2 / client.heightPx) {
        return null;
      }
      final Offset target = Offset(
        anchor.value.dx * client.widthPx,
        anchor.value.dy * client.heightPx,
      );
      before +=
          weights[rowIndex] *
          (a.rect.center - target).distanceSquared /
          (client.heightPx * client.heightPx);
      after +=
          weights[rowIndex] *
          (b.rect.center - target).distanceSquared /
          (client.heightPx * client.heightPx);
      rowIndex++;
    }
  }
  if (after > before + 1e-10) return null;
  return GalLookupCalibrationDraft(
    rect: rect,
    searchRect: draft.searchRect,
    layout: layout,
    samples: draft.samples,
    layoutReferenceClient: draft.layoutReferenceClient,
    layoutCaptureMetadata: draft.layoutCaptureMetadata,
    slot: draft.slot,
  );
}

double _calibrationMedian(List<double> values) {
  values.sort();
  final int middle = values.length ~/ 2;
  return values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2;
}
