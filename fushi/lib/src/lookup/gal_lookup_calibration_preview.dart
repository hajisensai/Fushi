import 'package:flutter/services.dart';
import 'package:fushi/src/lookup/gal_lookup_surface_profile.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

/// The native DirectWrite hit boxes, in client physical pixels. A preview never
/// registers an input surface or changes the current game session.
class GalCalibrationBox {
  const GalCalibrationBox(
    this.charIndex,
    this.charLength,
    this.hitRect, {
    Rect? visualRect,
  }) : visualRect = visualRect ?? hitRect;

  final int charIndex;
  final int charLength;

  /// The full advance cell used for hit testing and text positioning.
  final Rect hitRect;

  /// The observed glyph bounds used for the paint/anchor layer.
  final Rect visualRect;

  /// Legacy callers use [rect] for the hit rectangle.
  Rect get rect => hitRect;
}

class GalCalibrationPreview {
  const GalCalibrationPreview({required this.boxes, this.reason});

  final List<GalCalibrationBox> boxes;
  final String? reason;
  bool get accepted => reason == null && boxes.isNotEmpty;

  GalCalibrationBox? boxForIndex(int index) {
    for (final GalCalibrationBox box in boxes) {
      if (index >= box.charIndex && index < box.charIndex + box.charLength) {
        return box;
      }
    }
    return null;
  }
}

typedef GalCalibrationPreviewBuilder =
    Future<GalCalibrationPreview> Function({
      required String text,
      required GalLookupReferenceClientV1 client,
      required GalLookupNormalizedRectV1 rect,
      required GalLookupTextLayoutV1 layout,
    });

abstract final class GalLookupCalibrationPreviewChannel {
  static const MethodChannel _channel = FushiChannels.galHookText;

  static Future<GalCalibrationPreview> build({
    required String text,
    required GalLookupReferenceClientV1 client,
    required GalLookupNormalizedRectV1 rect,
    required GalLookupTextLayoutV1 layout,
  }) async {
    if (!client.isValid ||
        !rect.isValid ||
        !layout.isValid ||
        text.isEmpty ||
        text.length > 16384) {
      return const GalCalibrationPreview(boxes: [], reason: 'invalid_input');
    }
    final Map<Object?, Object?>? result = await _channel
        .invokeMapMethod<Object?, Object?>('attachedPreviewLayout', {
          'sourceText': text,
          'referenceClient': client.toJson(),
          'bodyRect': rect.toJson(),
          'layout': layout.toJson(),
        });
    if (result?['accepted'] != true || result?['boxes'] is! List) {
      return GalCalibrationPreview(
        boxes: const [],
        reason: result?['reason'] as String? ?? 'preview_unavailable',
      );
    }
    final List<GalCalibrationBox> boxes = [];
    for (final Object? raw in result!['boxes'] as List) {
      if (raw is! Map) {
        return const GalCalibrationPreview(boxes: [], reason: 'invalid_boxes');
      }
      final Object? index = raw['charIndex'];
      final Object? length = raw['charLength'];
      final List<Object?> legacyEdges = [
        raw['left'],
        raw['top'],
        raw['right'],
        raw['bottom'],
      ];
      final bool hasVisualEdges = raw.keys.any(
        (Object? key) => key is String && key.startsWith('visual'),
      );
      final List<Object?> hitEdges = legacyEdges;
      final List<Object?> visualEdges = hasVisualEdges
          ? <Object?>[
              raw['visualLeft'],
              raw['visualTop'],
              raw['visualRight'],
              raw['visualBottom'],
            ]
          : hitEdges;
      if (index is! int ||
          length is! int ||
          index < 0 ||
          length <= 0 ||
          index + length > text.length ||
          hitEdges.any((Object? v) => v is! num || !v.isFinite) ||
          visualEdges.any((Object? v) => v is! num || !v.isFinite)) {
        return const GalCalibrationPreview(boxes: [], reason: 'invalid_boxes');
      }
      final Rect hitRect = Rect.fromLTRB(
        (hitEdges[0]! as num).toDouble(),
        (hitEdges[1]! as num).toDouble(),
        (hitEdges[2]! as num).toDouble(),
        (hitEdges[3]! as num).toDouble(),
      );
      final Rect visualRect = Rect.fromLTRB(
        (visualEdges[0]! as num).toDouble(),
        (visualEdges[1]! as num).toDouble(),
        (visualEdges[2]! as num).toDouble(),
        (visualEdges[3]! as num).toDouble(),
      );
      if (hitRect.isEmpty ||
          visualRect.isEmpty ||
          hitRect.left < 0 ||
          hitRect.top < 0 ||
          hitRect.right > client.widthPx ||
          hitRect.bottom > client.heightPx ||
          visualRect.left < hitRect.left ||
          visualRect.top < hitRect.top ||
          visualRect.right > hitRect.right ||
          visualRect.bottom > hitRect.bottom) {
        return const GalCalibrationPreview(boxes: [], reason: 'invalid_boxes');
      }
      boxes.add(
        GalCalibrationBox(index, length, hitRect, visualRect: visualRect),
      );
    }
    return GalCalibrationPreview(boxes: List.unmodifiable(boxes));
  }
}
