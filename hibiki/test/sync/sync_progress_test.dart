import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/sync_progress.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

import 'sync_settings_schema_source_corpus.dart';

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
    // BUG-101: a single app-wide notifier carries progress for EVERY full sweep
    // (manual + app-open/background auto), so the settings "立即同步" row's bar
    // shows even for a sync the row didn't trigger (previously: bare toast).
    expect(autoTrigger.contains('ValueNotifier<SyncProgress?>'), isTrue,
        reason: 'an app-wide syncProgress notifier must exist');
    expect(autoTrigger.contains('syncProgress.value = p'), isTrue,
        reason:
            'both the manual and auto sweep must publish progress globally');
    expect(autoTrigger.contains('onProgress?.call(p)'), isTrue,
        reason: 'manual sync must still forward to the caller callback');
    expect(autoTrigger.contains('syncProgress.value = null'), isTrue,
        reason: 'the global progress must reset when no sync is in flight');

    // TODO-585: Sync-now widget 现住 sync_settings_schema/actions.part.dart；
    // 读合并语料而不是单文件。
    final widget = readSyncSettingsSchemaSource();
    // The Sync-now widget must render the inline determinate bar.
    expect(
        widget.contains('LinearProgressIndicator(value: p?.fraction)'), isTrue,
        reason: 'the Sync-now row must show an inline progress bar');
    // BUG-101: the row must reflect the GLOBAL sync state, not a local flag, so
    // the bar appears even when a background/app-open sync started the run.
    expect(widget.contains('valueListenable: syncInProgress'), isTrue,
        reason:
            'the Sync-now row must listen to the global in-flight notifier');
    expect(widget.contains('valueListenable: syncProgress'), isTrue,
        reason: 'the Sync-now row must listen to the global progress notifier');
  });

  test('logSyncReportErrors writes per-item sync failures to error log',
      () async {
    await ErrorLogService.instance.clear();

    final SyncRunReport report = SyncRunReport()
      ..errors.addAll(<String>[
        'live pull book "BookY": HTTP 500',
        'pull dictionary "明镜": invalid package',
      ]);

    logSyncReportErrors(report);

    final String log = ErrorLogService.instance.getFullLog();
    expect(log, contains('SyncRunReport.errors'));
    expect(log, contains('live pull book "BookY": HTTP 500'));
    expect(log, contains('pull dictionary "明镜": invalid package'));
  });
}
