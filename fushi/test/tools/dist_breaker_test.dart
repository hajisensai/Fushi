// tool/test_flow/dist_breaker.dart: a machine that had no connection or no
// disk is left out of offloaded runs for a while.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/dist_breaker.dart';
import '../../tool/test_flow/dist_plan.dart';
import '../../tool/test_flow/dist_workers.dart';

void main() {
  late Directory dir;
  late DateTime now;
  late DistBreaker breaker;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dist_breaker_');
    now = DateTime(2026, 11, 15, 12);
    breaker = DistBreaker(
      File('${dir.path}/state/dist-breaker.json'),
      now: () => now,
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('the hold doubles per failure in a row up to an hour', () {
    expect(distBreakerHold(1), const Duration(minutes: 5));
    expect(distBreakerHold(2), const Duration(minutes: 10));
    expect(distBreakerHold(3), const Duration(minutes: 20));
    expect(distBreakerHold(4), const Duration(minutes: 40));
    expect(distBreakerHold(5), const Duration(hours: 1));
    expect(distBreakerHold(50), const Duration(hours: 1));
  });

  test('only answers that are not about the run trip it', () {
    expect(
      distBreakerReason(DistWorkerUnreachable('lock failed (exit 255)')),
      'unreachable',
    );
    expect(
      distBreakerReason(
        DistWorkerBusy(
          'lock failed on w (exit 1): busy: only 1 GB free disk '
          '(MIN_FREE_DISK_GB=20)',
        ),
      ),
      'short of disk',
    );
    // Ends by itself; the worker's queue waits for it.
    expect(
      distBreakerReason(
        DistWorkerBusy('busy: in use by dist_test run 20261115-120000-aaaa'),
      ),
      isNull,
    );
    expect(
      distBreakerReason(DistWorkerBusy('busy: paused by the owner')),
      isNull,
    );
    // May be the snapshot's doing.
    expect(
      distBreakerReason(DistWorkerError('prepare failed (exit 1)')),
      isNull,
    );
  });

  test('a tripped machine is held, then asked again', () {
    expect(breaker.held('wight-win'), isNull);
    expect(
      breaker.trip('wight-win', 'unreachable'),
      const Duration(minutes: 5),
    );
    final DistBreakerEntry held = breaker.held('wight-win')!;
    expect(held.why, 'unreachable');
    expect(held.fails, 1);
    expect(held.until, now.add(const Duration(minutes: 5)));
    expect(breaker.held('self-mac'), isNull, reason: 'per machine');

    now = now.add(const Duration(minutes: 5, seconds: 1));
    expect(breaker.held('wight-win'), isNull);
  });

  test('the same answer after the hold doubles it; an answer resets', () {
    breaker.trip('wight-win', 'unreachable');
    now = now.add(const Duration(minutes: 6));
    expect(
      breaker.trip('wight-win', 'unreachable'),
      const Duration(minutes: 10),
    );
    expect(breaker.held('wight-win')!.fails, 2);

    breaker.reset('wight-win');
    expect(breaker.held('wight-win'), isNull);
    expect(
      breaker.trip('wight-win', 'short of disk'),
      const Duration(minutes: 5),
    );
  });

  test('another process sees the entry; a damaged file holds nobody', () {
    breaker.trip('wight-mac', 'unreachable');
    final DistBreaker other = DistBreaker(breaker.file, now: () => now);
    expect(other.held('wight-mac'), isNotNull);

    breaker.file.writeAsStringSync('{"wight-mac": {"until": "soon"');
    expect(other.held('wight-mac'), isNull);
    breaker.file.writeAsStringSync('[1, 2]');
    expect(other.held('wight-mac'), isNull);
    // And it can be written again.
    other.trip('wight-mac', 'unreachable');
    expect(breaker.held('wight-mac'), isNotNull);
  });

  test('the slots of one machine share its entry', () {
    const DistWorkerConfig mac = DistWorkerConfig(
      name: 'self-mac',
      kind: DistWorkerKind.sshTrusted,
      platform: DistPlatform.macos,
      host: 'me@mac',
      slots: 2,
    );
    final List<DistWorker> workers = createDistWorkers(mac, repoRoot: '.');
    expect(workers.map((DistWorker w) => w.name), <String>[
      'self-mac',
      'self-mac.2',
    ]);
    expect(workers.map((DistWorker w) => w.breakerKey).toSet(), <String>{
      'self-mac',
    });
  });
}
