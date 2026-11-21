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
    // A push that went silent is the link, not the snapshot: asked again
    // from heavy.dart's queue it would hang the full stall limit each time.
    expect(
      distBreakerReason(DistWorkerStalled('git push to wight-win printed ...')),
      'push stalled',
    );
    expect(
      distBreakerAnswered(DistWorkerStalled('git push to wight-win ...')),
      isFalse,
    );
  });

  test('a tripped machine is held, then asked again', () {
    expect(breaker.held('wight-win'), isNull);
    expect(
      breaker.trip('wight-win', 'unreachable', asked: now)!.until,
      now.add(const Duration(minutes: 5)),
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
    breaker.trip('wight-win', 'unreachable', asked: now);
    now = now.add(const Duration(minutes: 6));
    expect(
      breaker.trip('wight-win', 'unreachable', asked: now)!.until,
      now.add(const Duration(minutes: 10)),
    );
    expect(breaker.held('wight-win')!.fails, 2);

    breaker.reset('wight-win');
    expect(breaker.held('wight-win'), isNull);
    expect(
      breaker.trip('wight-win', 'short of disk', asked: now)!.until,
      now.add(const Duration(minutes: 5)),
    );
  });

  // #3459 review: runs waiting in a machine's queue (heavy keeps one
  // dist_test per queued session there) each got the same 30-second network
  // drop as their answer and each counted it: five of them, fails = 5, the
  // machine left out for an hour.
  test('one outage seen by several runs counts once', () {
    final DateTime start = now;
    for (int run = 0; run < 5; run++) {
      now = start.add(Duration(seconds: 2 * run));
      final DistBreakerEntry entry = breaker.trip(
        'self-mac',
        'unreachable',
        asked: now.subtract(const Duration(seconds: 20)),
      )!;
      expect(entry.fails, 1);
      expect(
        entry.until,
        start.add(kDistBreakerFirstHold),
        reason: 'the hold is not extended either',
      );
    }
    // Later in the hold, by a run started by hand (it asks held machines).
    now = start.add(const Duration(minutes: 4));
    expect(
      breaker.trip('self-mac', 'unreachable', asked: now)!.until,
      start.add(kDistBreakerFirstHold),
    );
    expect(breaker.held('self-mac')!.fails, 1);
  });

  test('an ask that began before the last failure is not the next one', () {
    final DateTime start = now;
    breaker.trip('self-mac', 'unreachable', asked: start);
    // The hold is over; this ask began before that failure was recorded
    // (as far as it can: it hung on a connection that never closed).
    now = start.add(const Duration(minutes: 5, seconds: 30));
    expect(
      breaker.trip(
        'self-mac',
        'unreachable',
        asked: start.subtract(const Duration(seconds: 5)),
      ),
      isNull,
    );
    expect(breaker.held('self-mac'), isNull);
    // One that began after the hold is the second in a row.
    final DistBreakerEntry second = breaker.trip(
      'self-mac',
      'unreachable',
      asked: now.subtract(const Duration(seconds: 10)),
    )!;
    expect(second.fails, 2);
    expect(second.until, now.add(const Duration(minutes: 10)));
  });

  group('what a prepare teaches', () {
    DistWorkerBusy inUse() => DistWorkerBusy(
      'lock failed on self-mac (exit 75): busy: in use by dist_test run '
      '20261115-120000-aaaa (1 other run(s) waiting)',
      waited: const Duration(seconds: 26),
    );
    DistWorkerBusy noDisk() => DistWorkerBusy(
      'lock failed on wight-win (exit 75): busy: only 3 GB free disk '
      '(MIN_FREE_DISK_GB=20)',
      waited: const Duration(seconds: 2),
    );
    DistWorkerUnreachable gone() => DistWorkerUnreachable(
      'lock failed on self-mac (exit 255): Connection closed',
      waited: const Duration(seconds: 12),
    );

    /// A second failure in a row, its hold just over.
    void twoInARow(String machine, Object Function() error) {
      expect(breaker.learn(machine, error())!.fails, 1);
      now = now.add(const Duration(minutes: 6));
      expect(breaker.learn(machine, error())!.fails, 2);
      now = now.add(const Duration(minutes: 11));
      expect(breaker.held(machine), isNull);
    }

    test('which answers end the failures in a row', () {
      expect(distBreakerAnswered(null), isTrue);
      expect(distBreakerAnswered(inUse()), isTrue);
      expect(
        distBreakerAnswered(DistWorkerBusy('busy: paused by the owner')),
        isTrue,
      );
      expect(distBreakerAnswered(noDisk()), isFalse);
      expect(distBreakerAnswered(gone()), isFalse);
      expect(
        distBreakerAnswered(DistWorkerError('prepare failed (exit 1)')),
        isFalse,
      );
    });

    // The count was only cleared by a prepare that went all the way: a Mac
    // that answered "in use" for hours kept its old count, and the next
    // unrelated drop went on doubling from there.
    for (final (String name, Object? Function() answer)
        in <(String, Object? Function())>[
          ('a prepare that went through', () => null),
          ('in use', inUse),
          ('paused', () => DistWorkerBusy('busy: paused by the owner')),
        ]) {
      test('$name: the machine answered, the count starts over', () {
        twoInARow('self-mac', gone);
        expect(breaker.learn('self-mac', answer()), isNull);
        final DistBreakerEntry next = breaker.learn('self-mac', gone())!;
        expect(next.fails, 1);
        expect(next.until, now.add(kDistBreakerFirstHold));
      });
    }

    test('short of disk is no such answer: it doubles after its hold', () {
      twoInARow('wight-win', noDisk);
      final DistBreakerEntry third = breaker.learn('wight-win', noDisk())!;
      expect(third.fails, 3);
      expect(third.why, 'short of disk');
      expect(third.until, now.add(const Duration(minutes: 20)));
    });

    test('a failed prepare neither trips nor clears', () {
      twoInARow('self-mac', gone);
      expect(
        breaker.learn('self-mac', DistWorkerError('prepare failed (exit 1)')),
        isNull,
      );
      expect(breaker.learn('self-mac', gone())!.fails, 3);
    });

    test('the ask began as long before the failure as it waited', () {
      final DateTime start = now;
      breaker.learn('self-mac', gone());
      // 10 s after the hold. An ask that hung for six minutes began before
      // that failure was recorded: the same outage. One that took 12 s is
      // the next failure.
      now = start.add(kDistBreakerFirstHold + const Duration(seconds: 10));
      expect(
        breaker.learn(
          'self-mac',
          DistWorkerUnreachable(
            'lock failed on self-mac (exit 255): timed out',
            waited: const Duration(minutes: 6),
          ),
        ),
        isNull,
      );
      expect(breaker.held('self-mac'), isNull);
      expect(breaker.learn('self-mac', gone())!.fails, 2);
    });
  });

  test('another process sees the entry; a damaged file holds nobody', () {
    breaker.trip('wight-mac', 'unreachable', asked: now);
    final DistBreaker other = DistBreaker(breaker.file, now: () => now);
    expect(other.held('wight-mac'), isNotNull);

    breaker.file.writeAsStringSync('{"wight-mac": {"until": "soon"');
    expect(other.held('wight-mac'), isNull);
    breaker.file.writeAsStringSync('[1, 2]');
    expect(other.held('wight-mac'), isNull);
    // And it can be written again.
    other.trip('wight-mac', 'unreachable', asked: now);
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
