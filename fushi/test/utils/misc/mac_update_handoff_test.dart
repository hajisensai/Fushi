import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/mac_update_handoff.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mac_handoff_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  File marker() => MacUpdateHandoff.markerFile(dir);
  File result() => MacUpdateHandoff.resultFile(dir);

  Future<void> writeResult(String status, [String message = '']) async {
    await result().writeAsString(
      jsonEncode(<String, String>{'status': status, 'message': message}),
    );
  }

  group('writePending / read', () {
    test('round-trips target version and app path', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      final MacUpdateHandoffRecord? record =
          await MacUpdateHandoff.read(marker());
      expect(record, isNotNull);
      expect(record!.targetVersion, '1.2.0');
      expect(record.targetAppPath, '/Applications/hibiki.app');
    });

    test('read returns null on missing / malformed marker', () async {
      expect(await MacUpdateHandoff.read(marker()), isNull);
      await marker().writeAsString('not json {');
      expect(await MacUpdateHandoff.read(marker()), isNull);
    });

    test('preserves lastPrompted* when rewriting the same target', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      // Simulate a prior "incomplete" reconcile that stamped lastPromptedAppVersion.
      await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.1.0',
        now: DateTime.utc(2026, 7, 21),
      );
      // Re-arm the same target (retry): stamp must survive so we don't re-prompt.
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 22),
      );
      final MacUpdateHandoffRecord? record =
          await MacUpdateHandoff.read(marker());
      expect(record!.lastPromptedAppVersion, '1.1.0');
    });

    test('drops lastPrompted* when target version changes', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.1.0',
        now: DateTime.utc(2026, 7, 21),
      );
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.3.0', // new target
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 22),
      );
      final MacUpdateHandoffRecord? record =
          await MacUpdateHandoff.read(marker());
      expect(record!.lastPromptedAppVersion, isNull);
    });
  });

  group('reconcile', () {
    test('installed: current >= target deletes the marker', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      await writeResult('installed');
      final MacUpdateHandoffResult? r = await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.2.0',
        now: DateTime.utc(2026, 7, 21),
      );
      expect(r, isNotNull);
      expect(r!.status, MacUpdateHandoffStatus.installed);
      expect(await marker().exists(), isFalse);
      expect(await result().exists(), isFalse);
    });

    test('installed: debug seq bump is treated as newer', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.0.1-debug.6621',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      final MacUpdateHandoffResult? r = await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.0.1-debug.6621',
        now: DateTime.utc(2026, 7, 21),
      );
      expect(r!.status, MacUpdateHandoffStatus.installed);
    });

    test('incomplete: still on old version keeps the marker for backoff',
        () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      await writeResult('failed', 'copy new app failed');
      final MacUpdateHandoffResult? r = await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.1.0',
        now: DateTime.utc(2026, 7, 21),
      );
      expect(r, isNotNull);
      expect(r!.status, MacUpdateHandoffStatus.incomplete);
      expect(r.message, 'copy new app failed');
      // Marker kept (drives backoff); result consumed.
      expect(await marker().exists(), isTrue);
      expect(await result().exists(), isFalse);
    });

    test('incomplete idempotency: same version prompts only once', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      final MacUpdateHandoffResult? first = await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.1.0',
        now: DateTime.utc(2026, 7, 21),
      );
      final MacUpdateHandoffResult? second = await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.1.0',
        now: DateTime.utc(2026, 7, 21),
      );
      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('returns null when no marker exists', () async {
      final MacUpdateHandoffResult? r = await MacUpdateHandoff.reconcile(
        markerFile: marker(),
        resultFile: result(),
        currentVersion: '1.0.0',
      );
      expect(r, isNull);
    });
  });

  group('shouldBackOffAutoInstall', () {
    test('true when the same target failed last round (marker still present)',
        () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      expect(
        await MacUpdateHandoff.shouldBackOffAutoInstall(
          markerFile: marker(),
          candidateVersion: '1.2.0',
        ),
        isTrue,
      );
    });

    test('false for a different (newer) candidate version', () async {
      await MacUpdateHandoff.writePending(
        markerFile: marker(),
        targetVersion: '1.2.0',
        targetAppPath: '/Applications/hibiki.app',
        startedAt: DateTime.utc(2026, 7, 21),
      );
      expect(
        await MacUpdateHandoff.shouldBackOffAutoInstall(
          markerFile: marker(),
          candidateVersion: '1.3.0',
        ),
        isFalse,
      );
    });

    test('false when no marker (fail-open, never permanently blocks updates)',
        () async {
      expect(
        await MacUpdateHandoff.shouldBackOffAutoInstall(
          markerFile: marker(),
          candidateVersion: '1.2.0',
        ),
        isFalse,
      );
    });
  });
}
