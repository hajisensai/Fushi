import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/mining/galgame_window_gif.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';

/// A locally captured screenshot and the exact selected Hook occurrence that
/// remained current throughout capture. Users still confirm visible text:
/// unchanged Hook identity cannot prove that a typewriter animation has ended.
@immutable
class GalLookupCalibrationCapture {
  GalLookupCalibrationCapture({
    required this.sourceText,
    required Uint8List pngBytes,
    required this.referenceClient,
    required this.exePath,
    required this.exeSha256,
    required this.sessionEpoch,
    required this.occurrenceId,
    required this.targetHwnd,
    required this.capturedAt,
    required this.selectedThreadKey,
    this.sourceSequence,
    this.captureMetadata,
  }) : pngBytes = Uint8List.fromList(pngBytes).asUnmodifiableView();

  static const int maxPngBytes = 12 * 1024 * 1024;
  static const int maxTextLength = 8192;
  static const int maxImagePixels = 32 * 1024 * 1024;

  final String sourceText;
  final Uint8List pngBytes;

  /// Pixel space of [pngBytes]. Magpie captures use the visible destination
  /// viewport; application converts the fitted layout back to source space.
  final GalLookupReferenceClientV1 referenceClient;
  final String exePath;
  final String exeSha256;
  final int sessionEpoch;
  final String occurrenceId;
  final int? sourceSequence;
  final int targetHwnd;
  final DateTime capturedAt;
  final String selectedThreadKey;
  final WindowCaptureMetadata? captureMetadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceText': sourceText,
    'pngBase64': base64Encode(pngBytes),
    'referenceClient': referenceClient.toJson(),
    'exePath': exePath,
    'exeSha256': exeSha256,
    'sessionEpoch': sessionEpoch,
    'occurrenceId': occurrenceId,
    'sourceSequence': sourceSequence,
    'targetHwnd': targetHwnd,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    'selectedThreadKey': selectedThreadKey,
    'captureMetadata': captureMetadata?.toJson(),
  };

  static GalLookupCalibrationCapture? tryFromJson(Object? value) {
    if (value is! Map) return null;
    const List<String> stringKeys = <String>[
      'sourceText',
      'pngBase64',
      'exePath',
      'exeSha256',
      'occurrenceId',
      'capturedAt',
      'selectedThreadKey',
    ];
    if (stringKeys.any((String key) => value[key] is! String) ||
        value['sessionEpoch'] is! int ||
        value['targetHwnd'] is! int ||
        (value['sourceSequence'] != null && value['sourceSequence'] is! int)) {
      return null;
    }
    final String text = value['sourceText'] as String;
    final String encoded = value['pngBase64'] as String;
    final String exePath = value['exePath'] as String;
    final String sha = value['exeSha256'] as String;
    final String occurrence = value['occurrenceId'] as String;
    final String thread = value['selectedThreadKey'] as String;
    final int epoch = value['sessionEpoch'] as int;
    final int hwnd = value['targetHwnd'] as int;
    final GalLookupReferenceClientV1? client =
        GalLookupReferenceClientV1.tryFromJson(value['referenceClient']);
    final WindowCaptureMetadata? metadata = WindowCaptureMetadata.tryFromMap(
      value['captureMetadata'],
    );
    final DateTime? capturedAt = DateTime.tryParse(
      value['capturedAt'] as String,
    );
    if (text.trim().isEmpty ||
        text.length > maxTextLength ||
        encoded.length > ((maxPngBytes + 2) ~/ 3) * 4 ||
        exePath.isEmpty ||
        exePath.length > 32768 ||
        !GalLookupSurfaceProfileV1.isValidSha256(sha) ||
        occurrence.isEmpty ||
        occurrence.length > 1024 ||
        thread.isEmpty ||
        thread.length > 4096 ||
        epoch <= 0 ||
        hwnd == 0 ||
        client == null ||
        capturedAt == null ||
        metadata == null ||
        !(metadata.usedPresentationCapture
            ? metadata.isCompletePresentation && metadata.sourceHwnd == hwnd
            : metadata.isCompleteClient && metadata.capturedHwnd == hwnd) ||
        metadata.imageWidthPx != client.widthPx ||
        metadata.imageHeightPx != client.heightPx ||
        metadata.dpi != client.dpi ||
        client.widthPx * client.heightPx > maxImagePixels) {
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      return null;
    }
    if (bytes.length > maxPngBytes || !_pngMatchesClient(bytes, metadata)) {
      return null;
    }
    return GalLookupCalibrationCapture(
      sourceText: text,
      pngBytes: bytes,
      referenceClient: client,
      exePath: exePath,
      exeSha256: sha,
      sessionEpoch: epoch,
      occurrenceId: occurrence,
      sourceSequence: value['sourceSequence'] as int?,
      targetHwnd: hwnd,
      capturedAt: capturedAt,
      selectedThreadKey: thread,
      captureMetadata: metadata,
    );
  }
}

/// Immutable boundary read from the existing selected-session pipeline.
@immutable
class GalLookupCalibrationCaptureSnapshot {
  const GalLookupCalibrationCaptureSnapshot({
    required this.sourceText,
    required this.referenceClient,
    required this.exePath,
    required this.exeSha256,
    required this.sessionEpoch,
    required this.occurrenceId,
    required this.targetHwnd,
    required this.targetPid,
    required this.selectedThreadKey,
    required this.sourceIdentity,
    this.sourceSequence,
  });

  final String sourceText;
  final GalLookupReferenceClientV1 referenceClient;
  final String exePath;
  final String exeSha256;
  final int sessionEpoch;
  final String occurrenceId;
  final int? sourceSequence;
  final int targetHwnd;
  final int targetPid;
  final String selectedThreadKey;
  final String sourceIdentity;

  bool sameOccurrenceAs(GalLookupCalibrationCaptureSnapshot other) =>
      sessionEpoch == other.sessionEpoch &&
      occurrenceId == other.occurrenceId &&
      sourceSequence == other.sourceSequence &&
      targetHwnd == other.targetHwnd &&
      targetPid == other.targetPid &&
      selectedThreadKey == other.selectedThreadKey &&
      sourceIdentity == other.sourceIdentity &&
      sourceText == other.sourceText &&
      referenceClient == other.referenceClient &&
      exePath == other.exePath &&
      exeSha256 == other.exeSha256;
}

typedef GalCalibrationSnapshotReader =
    GalLookupCalibrationCaptureSnapshot Function();
typedef GalCalibrationWindowCapture =
    Future<WindowCaptureResult> Function(int hwnd);
typedef GalCalibrationCaptureLeaseFactory =
    Future<GalHookCaptureLease?> Function();

/// A privacy-safe, stable terminal category for calibration capture.
///
/// This deliberately carries no Hook text, executable path, window handle, or
/// platform error. The UI can choose a specific recovery message and desktop
/// diagnostics can record the category without retaining game content.
enum GalLookupCalibrationCaptureFailure {
  busy,
  sourceNotReady,
  surfaceNotReady,
  surfaceMappingUnavailable,
  rubyUnsupported,
  overlayHideFailed,
  suppressionUnavailable,
  restoreFailed,
  invalidSource,
  sceneChanged,
  windowCaptureFailed,
  clientMappingUnavailable,
  imageTooLarge,
  imageDimensionsInvalid,
  unknown,
}

final RegExp _calibrationCaptureReasonPattern = RegExp(r'^[a-z0-9_]{1,64}$');

const Set<String> _surfaceMappingCaptureReasons = <String>{
  'magpie_source_viewport_invalid',
  'magpie_viewport_invalid',
  'magpie_viewport_outside_presentation',
  'magpie_viewport_unavailable',
  'presentation_content_size_invalid',
  'presentation_destination_size_mismatch',
  'presentation_viewport_incomplete',
  'presentation_viewport_invalid',
  'presentation_viewport_outside_content',
  'presentation_viewport_unavailable',
  'target_mapping_unavailable',
};

/// Returns the bounded reason when it identifies a known source/presentation
/// mapping failure. Native status names use camelCase in one path; normalize
/// that spelling before it reaches logs or UI diagnostics.
String? normalizeGalLookupCalibrationSurfaceMappingReason(String? value) {
  if (value == null) return null;
  final String reason = value.trim();
  if (reason == 'targetMappingUnavailable') {
    return 'target_mapping_unavailable';
  }
  if (!_calibrationCaptureReasonPattern.hasMatch(reason) ||
      !_surfaceMappingCaptureReasons.contains(reason)) {
    return null;
  }
  return reason;
}

/// Keeps a native capture reason safe for diagnostics while preserving the
/// machine-readable reason used by existing capture failure logs.
String? normalizeGalLookupCalibrationCaptureReason(String? value) {
  if (value == null) return null;
  final String reason = value.trim();
  if (reason == 'targetMappingUnavailable') {
    return 'target_mapping_unavailable';
  }
  if (!_calibrationCaptureReasonPattern.hasMatch(reason)) return null;
  return reason;
}

class GalLookupCalibrationCaptureException implements Exception {
  const GalLookupCalibrationCaptureException(
    this.failure, {
    this.captureReason,
    this.captureMetadata,
    this.captureErrorCodes = const <String>[],
  });

  final GalLookupCalibrationCaptureFailure failure;
  final String? captureReason;
  final WindowCaptureMetadata? captureMetadata;
  final List<String> captureErrorCodes;

  @override
  String toString() => 'GalLookupCalibrationCaptureException(${failure.name})';
}

/// Captures once, fails closed on a scene change, and always releases the exact
/// visibility lease. No delay, string search, historical-line or latest fallback.
Future<GalLookupCalibrationCapture> captureGalLookupCalibrationSample({
  required GalCalibrationSnapshotReader readSnapshot,
  required GalCalibrationWindowCapture captureWindow,
  required GalCalibrationCaptureLeaseFactory acquireLease,
}) async {
  final GalLookupCalibrationCaptureSnapshot before = readSnapshot();
  if (before.sourceText.trim().isEmpty ||
      before.sourceText.length > GalLookupCalibrationCapture.maxTextLength ||
      !before.referenceClient.isValid ||
      before.sessionEpoch <= 0 ||
      before.occurrenceId.isEmpty ||
      before.targetHwnd == 0 ||
      before.targetPid <= 0 ||
      before.selectedThreadKey.isEmpty ||
      !GalLookupSurfaceProfileV1.isValidSha256(before.exeSha256)) {
    throw const GalLookupCalibrationCaptureException(
      GalLookupCalibrationCaptureFailure.invalidSource,
    );
  }
  void requireCurrent() {
    if (!before.sameOccurrenceAs(readSnapshot())) {
      throw const GalLookupCalibrationCaptureException(
        GalLookupCalibrationCaptureFailure.sceneChanged,
      );
    }
  }

  final GalHookCaptureLease? lease = await acquireLease();
  late final WindowCaptureResult result;
  late final DateTime capturedAt;
  try {
    requireCurrent();
    try {
      result = await captureWindow(before.targetHwnd);
    } catch (_) {
      throw const GalLookupCalibrationCaptureException(
        GalLookupCalibrationCaptureFailure.windowCaptureFailed,
      );
    }
    capturedAt = DateTime.now().toUtc();
    try {
      requireCurrent();
    } on GalLookupCalibrationCaptureException catch (error) {
      throw GalLookupCalibrationCaptureException(
        error.failure,
        captureReason: normalizeGalLookupCalibrationCaptureReason(
          result.captureReason,
        ),
        captureMetadata: result.metadata,
        captureErrorCodes: _captureErrorCodes(result.diagnostics),
      );
    }
  } finally {
    if (lease != null) {
      try {
        await lease.release();
      } catch (_) {
        throw const GalLookupCalibrationCaptureException(
          GalLookupCalibrationCaptureFailure.restoreFailed,
        );
      }
    }
  }
  requireCurrent();
  GalLookupCalibrationCaptureException captureFailure(
    GalLookupCalibrationCaptureFailure failure,
  ) {
    final String? captureReason = normalizeGalLookupCalibrationCaptureReason(
      result.captureReason,
    );
    final String? mappingReason =
        normalizeGalLookupCalibrationSurfaceMappingReason(captureReason);
    return GalLookupCalibrationCaptureException(
      (failure == GalLookupCalibrationCaptureFailure.windowCaptureFailed ||
                  failure ==
                      GalLookupCalibrationCaptureFailure
                          .clientMappingUnavailable) &&
              mappingReason != null
          ? GalLookupCalibrationCaptureFailure.surfaceMappingUnavailable
          : failure,
      captureReason: captureReason,
      captureMetadata: result.metadata,
      captureErrorCodes: _captureErrorCodes(result.diagnostics),
    );
  }

  if (!result.ok) {
    throw captureFailure(
      GalLookupCalibrationCaptureFailure.windowCaptureFailed,
    );
  }
  final WindowCaptureMetadata? metadata = result.metadata;
  if (metadata == null ||
      !(metadata.usedPresentationCapture
          ? metadata.isCompletePresentation
          : metadata.isCompleteClient)) {
    throw captureFailure(
      GalLookupCalibrationCaptureFailure.clientMappingUnavailable,
    );
  }
  final bool sameTarget =
      metadata.capturedHwnd == before.targetHwnd &&
      metadata.capturedPid == before.targetPid;
  final bool presentationTarget =
      metadata.isCompletePresentation &&
      metadata.sourceHwnd == before.targetHwnd &&
      metadata.sourcePid == before.targetPid;
  final bool sameClient =
      sameTarget &&
      metadata.clientWidthPx == before.referenceClient.widthPx &&
      metadata.clientHeightPx == before.referenceClient.heightPx &&
      metadata.dpi == before.referenceClient.dpi;
  // Magpie deliberately makes the attached surface follow its presentation
  // window while the capture backend reads the source HWND.  Both images are
  // still in the same normalized game coordinate system when their aspect
  // ratio agrees; keep the captured source dimensions as the sample's pixel
  // reference so the fitter never compares source pixels to output pixels.
  final double capturedAspect = metadata.imageWidthPx / metadata.imageHeightPx;
  final double referenceAspect = before.referenceClient.aspectRatio;
  final bool sourceClient =
      (sameTarget || presentationTarget) &&
      metadata.dpi == before.referenceClient.dpi &&
      capturedAspect.isFinite &&
      referenceAspect.isFinite &&
      ((capturedAspect - referenceAspect).abs() / referenceAspect) <= 0.01;
  final bool hasSourceProvenance =
      metadata.sourceClientWidthPx != 0 ||
      metadata.sourceClientHeightPx != 0 ||
      metadata.sourceClientDpi != 0;
  final bool validPresentation =
      presentationTarget &&
      (hasSourceProvenance
          ? metadata.hasSourceClientMapping &&
                metadata.sourceClientWidthPx ==
                    before.referenceClient.widthPx &&
                metadata.sourceClientHeightPx ==
                    before.referenceClient.heightPx &&
                metadata.sourceClientDpi == before.referenceClient.dpi
          : sourceClient &&
                ((metadata.sourceViewportWidthPx /
                                    metadata.sourceViewportHeightPx -
                                capturedAspect)
                            .abs() /
                        capturedAspect) <=
                    0.01);
  if (metadata.usedPresentationCapture
      ? !validPresentation
      : !sameClient && !sourceClient) {
    throw captureFailure(
      GalLookupCalibrationCaptureFailure.clientMappingUnavailable,
    );
  }
  final Uint8List bytes = result.pngBytes!;
  if (bytes.length > GalLookupCalibrationCapture.maxPngBytes ||
      metadata.imageWidthPx * metadata.imageHeightPx >
          GalLookupCalibrationCapture.maxImagePixels) {
    throw captureFailure(GalLookupCalibrationCaptureFailure.imageTooLarge);
  }
  if (!_pngMatchesClient(bytes, metadata)) {
    throw captureFailure(
      GalLookupCalibrationCaptureFailure.imageDimensionsInvalid,
    );
  }
  return GalLookupCalibrationCapture(
    sourceText: before.sourceText,
    pngBytes: bytes,
    referenceClient: sameClient
        ? before.referenceClient
        : GalLookupReferenceClientV1(
            widthPx: metadata.imageWidthPx,
            heightPx: metadata.imageHeightPx,
            dpi: metadata.dpi,
          ),
    exePath: before.exePath,
    exeSha256: before.exeSha256,
    sessionEpoch: before.sessionEpoch,
    occurrenceId: before.occurrenceId,
    sourceSequence: before.sourceSequence,
    targetHwnd: before.targetHwnd,
    capturedAt: capturedAt,
    selectedThreadKey: before.selectedThreadKey,
    captureMetadata: metadata,
  );
}

List<String> _captureErrorCodes(String? diagnostics) {
  if (diagnostics == null) return const <String>[];
  // Keep numeric HRESULTs, never arbitrary platform messages or game paths.
  return RegExp(r'\bhr=(0x[0-9a-fA-F]{8})\b')
      .allMatches(
        diagnostics.length > 4096
            ? diagnostics.substring(0, 4096)
            : diagnostics,
      )
      .take(4)
      .map((RegExpMatch match) => match.group(1)!)
      .toList(growable: false);
}

bool _pngMatchesClient(Uint8List bytes, WindowCaptureMetadata metadata) {
  const List<int> signature = <int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    0,
    0,
    0,
    13,
    73,
    72,
    68,
    82,
  ];
  if (bytes.length < 33) return false;
  for (int i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  final ByteData header = ByteData.sublistView(bytes);
  return header.getUint32(16) == metadata.imageWidthPx &&
      header.getUint32(20) == metadata.imageHeightPx;
}
