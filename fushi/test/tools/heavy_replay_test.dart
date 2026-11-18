// tool/test_flow/heavy_replay.dart: the recorded runs queued again by the
// lease's own rules (`heavy.dart --replay`).

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_history.dart';
import '../../tool/test_flow/heavy_replay.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 18, 12);

/// A run submitted [at] seconds after [_t0] (same second: in list order) that queued [queued] s and ran
/// [ran] s.
HeavyHistoryEntry _run({
  required int at,
  required int ran,
  int queued = 0,
  String kind = 'test',
  int? bookMb = 6144,
  int? staticMb,
  int? peakMb,
  HeavyRanWhere where = HeavyRanWhere.here,
}) => HeavyHistoryEntry(
  at: _t0.add(Duration(seconds: at + queued + ran)),
  kind: kind,
  label: kind,
  where: where,
  queued: Duration(seconds: queued),
  ran: Duration(seconds: ran),
  exitCode: 0,
  bookMb: bookMb,
  staticMb: staticMb,
  peakMb: peakMb,
);

Map<int, int> _replay(
  List<HeavyHistoryEntry> entries, {
  int slots = 3,
  int budgetMb = 32768,
  int Function(HeavyHistoryEntry e)? bookOf,
}) => replayHeavyHistory(
  entries,
  slots: slots,
  budgetMb: budgetMb,
  bookOf: bookOf ?? heavyReplayStaticBook,
).map((int i, Duration d) => MapEntry<int, int>(i, d.inSeconds));

void main() {
  test('runs that fit start at once', () {
    expect(
      _replay(<HeavyHistoryEntry>[
        _run(at: 0, ran: 100),
        _run(at: 0, ran: 100),
        _run(at: 0, ran: 100, kind: 'analyze', bookMb: 8192),
      ]),
      <int, int>{0: 0, 1: 0, 2: 0},
    );
  });

  test('a run waits for a slot, looking again every 5 s', () {
    expect(
      _replay(<HeavyHistoryEntry>[
        _run(at: 0, ran: 100, bookMb: 2048),
        _run(at: 0, ran: 300, bookMb: 2048),
        _run(at: 0, ran: 10, bookMb: 2048),
      ], slots: 2),
      <int, int>{0: 0, 1: 0, 2: 100},
    );
  });

  test('analyze takes a light slot, not a regular one', () {
    expect(
      _replay(<HeavyHistoryEntry>[
        _run(at: 0, ran: 100, bookMb: 2048),
        _run(at: 0, ran: 100, kind: 'analyze', bookMb: 2048),
        _run(at: 0, ran: 100, kind: 'analyze', bookMb: 2048),
        // Both light slots are busy; the regular slot next to it is not its.
        _run(at: 0, ran: 10, kind: 'analyze', bookMb: 2048),
      ], slots: 2),
      <int, int>{0: 0, 1: 0, 2: 0, 3: 100},
    );
  });

  test('the booking, not the slots, keeps the third test waiting next to two '
      'analyze runs -- and a measured analyze booking lets it in', () {
    final List<HeavyHistoryEntry> runs = <HeavyHistoryEntry>[
      _run(at: 0, ran: 600, kind: 'analyze', bookMb: 8192),
      _run(at: 0, ran: 600, kind: 'analyze', bookMb: 8192),
      _run(at: 0, ran: 600),
      _run(at: 0, ran: 600),
      _run(at: 0, ran: 60),
    ];
    // 2 x 8192 + 2 x 6144 = 28672; a third 6144 is over 32768.
    expect(_replay(runs)[4], 600);
    // 2 x 6400 + 3 x 6144 = 31232 fits.
    expect(
      _replay(
        runs,
        bookOf: (HeavyHistoryEntry e) => e.kind == 'analyze' ? 6400 : e.bookMb!,
      )[4],
      0,
    );
  });

  test('a later small run goes ahead of a head that does not fit, within '
      'the room that keeps the head its share', () {
    final Map<int, int> waited = _replay(<HeavyHistoryEntry>[
      _run(at: 0, ran: 300, bookMb: 12288),
      // Head: 12288 + 12288 is over the 16384 budget.
      _run(at: 0, ran: 50, bookMb: 12288),
      // 12288 + 2048 fits, and leaves the head its 12288 once run 0 is done.
      _run(at: 0, ran: 50, bookMb: 2048),
    ], budgetMb: 16384);
    expect(waited[2], 0);
    expect(waited[1], 300);
  });

  test('a later run does not go ahead of a head that fits', () {
    final Map<int, int> waited = _replay(<HeavyHistoryEntry>[
      _run(at: 0, ran: 100, bookMb: 2048),
      _run(at: 0, ran: 100, bookMb: 2048),
      _run(at: 0, ran: 100, bookMb: 2048),
    ], slots: 1);
    expect(waited[1], 100);
    expect(waited[2], 200);
  });

  test('a run another machine took at once is no part of the queue', () {
    expect(
      _replay(<HeavyHistoryEntry>[
        _run(at: 0, ran: 500, where: HeavyRanWhere.elsewhere),
        _run(at: 0, ran: 10),
      ], slots: 1),
      <int, int>{1: 0},
    );
  });

  test('a run another machine took while it queued here leaves then, unless '
      'the replay admits it here first', () {
    final List<HeavyHistoryEntry> runs = <HeavyHistoryEntry>[
      _run(at: 0, ran: 1000),
      _run(at: 0, ran: 50, queued: 200, where: HeavyRanWhere.elsewhere),
      _run(at: 0, ran: 50),
    ];
    final Map<int, int> oneSlot = _replay(runs, slots: 1);
    expect(oneSlot[1], 200);
    // It never ran here, so the next one waits only for run 0.
    expect(oneSlot[2], 1000);
    final Map<int, int> twoSlots = _replay(runs, slots: 2);
    expect(twoSlots[1], 0);
    // Admitted here, it holds the second slot for as long as it ran there.
    expect(twoSlots[2], 50);
  });

  test(
    'a run that recorded no booking (a build) books the largest ceiling',
    () {
      expect(heavyReplayStaticBook(_run(at: 0, ran: 1, bookMb: null)), 16384);
      expect(
        heavyReplayStaticBook(
          _run(at: 0, ran: 1, bookMb: 6400, staticMb: 8192),
        ),
        8192,
      );
    },
  );

  test('measured bookings use only the runs that ended before the run was '
      'submitted', () {
    final List<HeavyHistoryEntry> runs = <HeavyHistoryEntry>[
      for (int i = 0; i < kHeavyMeasuredMinSamples; i++)
        _run(at: i * 100, ran: 60, kind: 'analyze', bookMb: 8192, peakMb: 5599),
      _run(
        at: kHeavyMeasuredMinSamples * 100,
        ran: 60,
        kind: 'analyze',
        bookMb: 8192,
        peakMb: 5599,
      ),
      _run(at: 5000, ran: 60, kind: 'build', bookMb: null, peakMb: 900),
    ];
    final List<int> books = heavyReplayMeasuredBooks(runs);
    // Not enough runs on record yet for the first twenty.
    expect(books.take(kHeavyMeasuredMinSamples), everyElement(8192));
    expect(books[kHeavyMeasuredMinSamples], 6400);
    expect(books.last, 16384);
  });

  test('the report names each replay and the runs that ended up here', () {
    final List<HeavyHistoryEntry> runs = <HeavyHistoryEntry>[
      _run(at: 0, ran: 100),
      _run(at: 0, ran: 10),
      _run(at: 0, ran: 10, queued: 30, where: HeavyRanWhere.elsewhere),
    ];
    final String report = renderHeavyReplay(runs, <String, HeavyReplay>{
      'one slot': replayHeavyHistory(
        runs,
        slots: 1,
        budgetMb: 32768,
        bookOf: heavyReplayStaticBook,
      ),
    });
    // Run 1 waits 100 s, the one taken elsewhere 30 s.
    expect(report, contains('one slot: 2m10s queued in all'));
    expect(report, contains('test        2 run(s) here'));
    expect(report, contains('max 100s'));
  });
}
