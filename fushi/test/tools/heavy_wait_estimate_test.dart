import 'package:test/test.dart';

import '../../tool/test_flow/heavy_budget.dart';
import '../../tool/test_flow/heavy_history.dart';
import '../../tool/test_flow/heavy_wait_estimate.dart';

void main() {
  const Duration min = Duration(minutes: 1);

  group('heavyPredictedWait', () {
    test('a free slot means no wait', () {
      expect(
        heavyPredictedWait(
          slots: 3,
          running: <HeavyRunningNow>[(held: min, typical: min * 10)],
          ahead: <Duration?>[min * 5],
        ),
        Duration.zero,
      );
    });

    test('waits for the earliest holder, then the runs ahead in turn', () {
      // Slots free at 4 and 9 min; ahead: 10 min takes the 4-min slot
      // (free at 14), 2 min takes the 9-min one (free at 11): we start at 11.
      expect(
        heavyPredictedWait(
          slots: 2,
          running: <HeavyRunningNow>[
            (held: min, typical: min * 5),
            (held: min, typical: min * 10),
          ],
          ahead: <Duration?>[min * 10, min * 2],
        ),
        min * 11,
      );
    });

    test('leans short: overdue and unknown runs count as no time', () {
      expect(
        heavyPredictedWait(
          slots: 1,
          running: <HeavyRunningNow>[(held: min * 20, typical: min * 5)],
          ahead: <Duration?>[null, min * 3],
        ),
        min * 3,
      );
      expect(
        heavyPredictedWait(
          slots: 1,
          running: <HeavyRunningNow>[(held: min, typical: null)],
          ahead: <Duration?>[],
        ),
        Duration.zero,
      );
    });
  });

  group('heavyTypicalRuns', () {
    HeavyHistoryEntry run(
      String kind,
      int ranMin, {
      HeavyRanWhere where = HeavyRanWhere.here,
      int exitCode = 0,
    }) => HeavyHistoryEntry(
      at: DateTime(2026, 11, 22),
      kind: kind,
      label: kind,
      where: where,
      queued: Duration.zero,
      ran: min * ranMin,
      exitCode: exitCode,
    );

    test('the median of a kind run here often enough, others left out', () {
      final Map<String, Duration> t = heavyTypicalRuns(<HeavyHistoryEntry>[
        for (final int m in <int>[1, 2, 3, 4, 50]) run('test', m),
        for (int i = 0; i < 4; i++) run('build', 9),
        for (int i = 0; i < 9; i++)
          run('analyze', 30, where: HeavyRanWhere.elsewhere),
        for (int i = 0; i < 9; i++)
          run('other', 30, exitCode: kHeavyCallerGoneExit),
      ]);
      expect(t, <String, Duration>{'test': min * 3});
    });
  });

  group('heavyQueuedWait', () {
    // A simulated clock: two regular slots held by tests 5 and 1 min in
    // (6 min typical: free in 1 and 5 min), an analyze in a light slot, and
    // two 20-min builds queued ahead, under a 30000 MB budget.
    const int now = 10 * 60 * 60 * 1000;
    HeavyHolder holder(int slot, String kind, int heldMin) => HeavyHolder(
      slot: slot,
      pid: 1000 + slot,
      startedAtMs: now - (min * heldMin).inMilliseconds,
      label: kind,
      cwd: '.',
      capMb: 8192,
      kind: kind,
    );
    const Map<String, Duration> typical = <String, Duration>{
      'test': Duration(minutes: 6),
      'build': Duration(minutes: 20),
      'analyze': Duration(minutes: 2),
    };
    const List<HeavyWaiterAhead> builds = <HeavyWaiterAhead>[
      (bookedMb: 8192, kind: 'build'),
      (bookedMb: 8192, kind: 'build'),
    ];

    // HBK-AUDIT-224: the light holder's 8 GB books the budget at admission,
    // so neither build fits now (3 x 8192 + 8192 > 30000) and the run may go
    // ahead of them: it starts when the first test frees its slot, in 1 min
    // -- not 21 min, as counting the builds ahead predicted.
    test("the light slots' holders book the budget as at admission", () {
      expect(
        heavyQueuedWait(
          slots: 2,
          budgetMb: 30000,
          holders: <HeavyHolder>[
            holder(0, 'test', 5),
            holder(1, 'test', 1),
            holder(kLightSlotBase, 'analyze', 1),
          ],
          ahead: builds,
          typical: typical,
          nowMs: now,
        ),
        min,
      );
    });

    test('waiters ahead that fit the budget are counted in turn', () {
      // Without the analyze the builds fit (2 x 8192 + 8192 <= 30000): the
      // first takes the 1-min slot (free at 21), the second the 5-min one
      // (free at 25), so the run waits 21 min.
      expect(
        heavyQueuedWait(
          slots: 2,
          budgetMb: 30000,
          holders: <HeavyHolder>[holder(0, 'test', 5), holder(1, 'test', 1)],
          ahead: builds,
          typical: typical,
          nowMs: now,
        ),
        min * 21,
      );
    });

    test('a light holder never frees a regular slot', () {
      expect(
        heavyQueuedWait(
          slots: 1,
          budgetMb: null,
          holders: <HeavyHolder>[
            holder(0, 'test', 1),
            holder(kLightSlotBase, 'analyze', 1),
          ],
          ahead: const <HeavyWaiterAhead>[],
          typical: typical,
          nowMs: now,
        ),
        min * 5,
      );
    });
  });
}
