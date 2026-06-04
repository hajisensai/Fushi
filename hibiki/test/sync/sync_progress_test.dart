import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_progress.dart';

/// Unit + wiring guard for the manual-sync inline progress bar.
void main() {
  group('SyncProgress.fraction', () {
    test('zero total → null (indeterminate)', () {
      const p = SyncProgress(
          phase: SyncPhase.dictionaries, itemIndex: 0, itemTotal: 0);
      expect(p.fraction, isNull);
    });

    test('completed-item count without a file fraction', () {
      const p =
          SyncProgress(phase: SyncPhase.books, itemIndex: 2, itemTotal: 4);
      expect(p.fraction, closeTo(0.5, 1e-9));
    });

    test('blends the in-flight file fraction into the current item', () {
      const p = SyncProgress(
        phase: SyncPhase.dictionaries,
        itemIndex: 1,
        itemTotal: 4,
        fileFraction: 0.5,
      );
      // (1 + 0.5) / 4
      expect(p.fraction, closeTo(0.375, 1e-9));
    });

    test('clamps a degenerate over-unity result to 1.0', () {
      const p = SyncProgress(
        phase: SyncPhase.audiobooks,
        itemIndex: 1,
        itemTotal: 1,
        fileFraction: 5.0,
      );
      expect(p.fraction, 1.0);
    });

    test('clamps a negative file fraction', () {
      const p = SyncProgress(
        phase: SyncPhase.localAudio,
        itemIndex: 0,
        itemTotal: 2,
        fileFraction: -3.0,
      );
      expect(p.fraction, 0.0);
    });
  });

  test('source guard: manual sync threads progress end-to-end', () {
    final orchestrator =
        File('lib/src/sync/sync_orchestrator.dart').readAsStringSync();
    // Orchestrator accepts and emits structured progress for every phase.
    expect(orchestrator.contains('SyncProgressCallback? onProgress'), isTrue);
    for (final String phase in <String>[
      'SyncPhase.books',
      'SyncPhase.readingData',
      'SyncPhase.dictionaries',
      'SyncPhase.localAudio',
      'SyncPhase.audiobooks',
    ]) {
      expect(orchestrator.contains(phase), isTrue,
          reason: 'orchestrator must emit progress for $phase');
    }

    final autoTrigger =
        File('lib/src/sync/sync_auto_trigger.dart').readAsStringSync();
    expect(autoTrigger.contains('SyncProgressCallback? onProgress'), isTrue,
        reason: 'runManualFullSync must forward a progress callback');
    expect(autoTrigger.contains('onProgress: onProgress'), isTrue);

    final widget =
        File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
    // The Sync-now widget must render the inline determinate bar.
    expect(
        widget.contains('LinearProgressIndicator(value: p?.fraction)'), isTrue,
        reason: 'the Sync-now row must show an inline progress bar');
  });
}
