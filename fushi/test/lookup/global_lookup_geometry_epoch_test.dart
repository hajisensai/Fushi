import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_controller.dart';

void main() {
  group('global lookup geometry epoch', () {
    test('parser accepts only non-negative integral epochs', () {
      expect(parseGlobalLookupGeometryEpoch(12), 12);
      expect(parseGlobalLookupGeometryEpoch(12.0), 12);
      expect(parseGlobalLookupGeometryEpoch(-1), isNull);
      expect(parseGlobalLookupGeometryEpoch(1.5), isNull);
      expect(parseGlobalLookupGeometryEpoch('12'), isNull);
      expect(parseGlobalLookupGeometryEpoch(null), isNull);
    });

    test('same dimensions from an older epoch cannot complete capture', () {
      // Geometry A1 (epoch 1, 960x640) -> B (epoch 2, another size) -> A2
      // (epoch 3, 960x640). A1's late captureReady has byte-identical bounds,
      // but only A2's epoch may acknowledge the pending capture.
      expect(
        globalLookupCaptureReadyMatches(
          pendingWidth: 960,
          pendingHeight: 640,
          pendingGeometryEpoch: 3,
          readyWidth: 960,
          readyHeight: 640,
          readyGeometryEpoch: 1,
        ),
        isFalse,
      );
      expect(
        globalLookupCaptureReadyMatches(
          pendingWidth: 960,
          pendingHeight: 640,
          pendingGeometryEpoch: 3,
          readyWidth: 960,
          readyHeight: 640,
          readyGeometryEpoch: 3,
        ),
        isTrue,
      );
      expect(
        globalLookupCaptureReadyMatches(
          pendingWidth: 960,
          pendingHeight: 640,
          pendingGeometryEpoch: 3,
          readyWidth: 960,
          readyHeight: 640,
          readyGeometryEpoch: null,
        ),
        isFalse,
        reason: 'an unversioned reply cannot acknowledge a versioned resize',
      );
    });

    test('dedupe treats a new epoch at identical bounds as new geometry', () {
      expect(
        globalLookupGeometryChanged(
          lastWidth: 960,
          lastHeight: 640,
          lastDx: -20,
          lastDy: 0,
          lastGeometryEpoch: 1,
          width: 960,
          height: 640,
          dx: -20,
          dy: 0,
          geometryEpoch: 3,
        ),
        isTrue,
      );
      expect(
        globalLookupGeometryChanged(
          lastWidth: 960,
          lastHeight: 640,
          lastDx: -20,
          lastDy: 0,
          lastGeometryEpoch: 3,
          width: 960,
          height: 640,
          dx: -20,
          dy: 0,
          geometryEpoch: 3,
        ),
        isFalse,
      );
    });

    test('begin lookup clears Dart handshake before the async search', () {
      final String source = File(
        'lib/src/lookup/global_lookup_controller.dart',
      ).readAsStringSync();
      final int lookupStart = source.indexOf('Future<void> _lookupExternal(');
      final int reset = source.indexOf(
        '_resetGeometryHandshakeForLookup();',
        lookupStart,
      );
      final int search = source.indexOf(
        'await model.searchDictionary(',
        lookupStart,
      );
      expect(reset, greaterThan(lookupStart));
      expect(
        reset,
        lessThan(search),
        reason: 'old pending capture must be retired before search yields',
      );

      final int resetBody = source.indexOf(
        'void _resetGeometryHandshakeForLookup()',
      );
      final int resetEnd = source.indexOf(
        'void _cancelPendingGalCapture()',
        resetBody,
      );
      final String body = source.substring(resetBody, resetEnd);
      expect(body, contains('_lastSentGeometryEpoch = -1'));
      expect(body, contains('_cancelPendingGalCapture()'));
      expect(
        body,
        isNot(contains('nextGeometryEpoch')),
        reason:
            'the host owns its monotonic epoch; begin only resets Dart state',
      );
    });
  });
}
