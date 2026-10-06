import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

import 'sync_orchestrator_source_corpus.dart';
import 'sync_settings_schema_source_corpus.dart';

/// Unit + wiring guard for the manual-sync inline progress bar.
void main() {
  group('SyncProgress.fraction', () {
    test('zero total → null (indeterminate)', () {
      const p = SyncProgress(
          phase: SyncPhase.dictionaries, itemIndex: 0, itemTotal: 0);
      expect(p.fraction, isNull);
    });

    test('atomic item follows the visible one-based ordinal', () {
      const p = SyncProgress(
        phase: SyncPhase.books,
        itemIndex: 2,
        itemTotal: 4,
      );
      expect(p.fraction, closeTo(0.75, 1e-9));
    });

    test('BUG-1973: final atomic item makes a 2/2 label a full bar', () {
      const p = SyncProgress(
        phase: SyncPhase.readingData,
        itemIndex: 1,
        itemTotal: 2,
      );
      expect(p.fraction, 1.0);
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

    test('explicit measurable fraction still starts from zero', () {
      const p = SyncProgress(
        phase: SyncPhase.localAudio,
        itemIndex: 0,
        itemTotal: 2,
        fileFraction: 0.0,
      );
      expect(p.fraction, 0.0);
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

  group('TransferRateMeter', () {
    late DateTime clock;
    late TransferRateMeter meter;

    setUp(() {
      clock = DateTime(2026, 10, 6);
      meter = TransferRateMeter(now: () => clock);
    });

    void advance(int ms) => clock = clock.add(Duration(milliseconds: ms));

    test('no rate until the samples span the minimum window', () {
      expect(meter.sample('a', 0), isNull);
      advance(100);
      expect(meter.sample('a', 100000), isNull);
    });

    test('bytes over elapsed time within the window', () {
      meter.sample('a', 0);
      advance(500);
      meter.sample('a', 500000);
      advance(500);
      expect(meter.sample('a', 1000000), closeTo(1000000, 1e-6));
    });

    test('a new file is folded in even when its count is not lower', () {
      meter.sample('small', 0);
      advance(500);
      meter.sample('small', 10000); // small file done: 10 KB
      advance(500);
      // Next file's first report (64 KB) exceeds the small file's final count;
      // only the file name tells the meter a new count started.
      expect(meter.sample('big', 64000), closeTo(74000, 1e-6));
    });

    test('a retry of the same file restarting at zero is not negative', () {
      meter.sample('a', 0);
      advance(500);
      meter.sample('a', 1000000);
      advance(500);
      // Same file restarted and is 400 KB in: 1.4 MB moved over 1 s.
      expect(meter.sample('a', 400000), closeTo(1400000, 1e-6));
    });

    test('samples older than the window stop counting', () {
      meter.sample('a', 0);
      advance(10000); // host packaging the next item, nothing moving
      meter.sample('a', 1000);
      advance(1000);
      // Only the last second counts: 9000 B / 1 s, not 10000 B / 11 s.
      expect(meter.sample('a', 10000), closeTo(9000, 1e-6));
    });
  });

  group('syncProgressLine', () {
    test('appends the rate only while bytes are moving', () {
      const SyncProgress idle = SyncProgress(
        phase: SyncPhase.dictionaries,
        itemIndex: 25,
        itemTotal: 36,
        title: '大辞泉 第二版',
      );
      expect(syncProgressLine(idle), endsWith('(26/36) 大辞泉 第二版'));

      const SyncProgress moving = SyncProgress(
        phase: SyncPhase.dictionaries,
        itemIndex: 25,
        itemTotal: 36,
        title: '大辞泉 第二版',
        fileFraction: 0.5,
        bytesPerSecond: 3.5 * 1024 * 1024,
      );
      expect(syncProgressLine(moving), endsWith('(26/36) 大辞泉 第二版 · 3.5 MB/s'));
    });

    test('rate without a title still follows the count', () {
      const SyncProgress p = SyncProgress(
        phase: SyncPhase.videos,
        itemIndex: 0,
        itemTotal: 1,
        bytesPerSecond: 512,
      );
      expect(syncProgressLine(p), endsWith('(1/1) · 512 B/s'));
    });
  });

  test('source guard: manual sync threads progress end-to-end', () {
    // B2 拆分后 SyncPhase 发射点分散在主库 + sync_orchestrator/*.part.dart。
    final String orchestrator = readSyncOrchestratorSource();
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
