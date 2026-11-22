import 'package:test/test.dart';

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
}
