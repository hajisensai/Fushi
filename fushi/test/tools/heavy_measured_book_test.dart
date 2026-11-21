// tool/test_flow/heavy_history.dart heavyMeasuredBookMb: what a run books
// once enough runs of its class were measured on this machine.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_history.dart';

final DateTime _now = DateTime.utc(2026, 11, 18, 12);

HeavyHistoryEntry _run({
  String kind = 'analyze',
  HeavyRanWhere where = HeavyRanWhere.here,
  int? bookMb = 8192,
  int? staticMb,
  int? peakMb = 5000,
  int ran = 200,
  Duration ago = const Duration(hours: 1),
}) => HeavyHistoryEntry(
  at: _now.subtract(ago),
  kind: kind,
  label: 'flutter $kind',
  where: where,
  queued: Duration.zero,
  ran: Duration(seconds: ran),
  exitCode: 0,
  bookMb: bookMb,
  staticMb: staticMb,
  peakMb: peakMb,
);

int? _measured(
  List<HeavyHistoryEntry> history, {
  String kind = 'analyze',
  int staticMb = 8192,
  int capMb = 16384,
}) => heavyMeasuredBookMb(
  history,
  kind: kind,
  staticMb: staticMb,
  capMb: capMb,
  now: _now,
);

void main() {
  test('too few measured runs: the fixed booking stands', () {
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < kHeavyMeasuredMinSamples - 1; i++) _run(),
      ]),
      isNull,
    );
  });

  test('books the p95 of the peaks plus a tenth, rounded up to 256 MB', () {
    // 100 runs peaking at 4001..4100 MB: p95 is 4095, +10% = 4504.5 -> 4608.
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 1; i <= 100; i++) _run(peakMb: 4000 + i),
      ]),
      4608,
    );
  });

  test('the measured analyze booking of 2026-11-15..18 (p95 5599 MB)', () {
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < 190; i++) _run(peakMb: 5100),
        for (int i = 0; i < 12; i++) _run(peakMb: 5599),
      ]),
      6400,
    );
  });

  test('lines of tools that took the lease themselves are no samples', () {
    // dist_test's local worker / pre_push_check / flutter_test_failures: the
    // peak is their whole tool's, not one run of the class.
    HeavyHistoryEntry via(int peakMb) => HeavyHistoryEntry(
      at: _now.subtract(const Duration(hours: 1)),
      kind: 'analyze',
      label: 'pre-push analyze',
      where: HeavyRanWhere.here,
      queued: Duration.zero,
      ran: const Duration(seconds: 200),
      exitCode: 0,
      bookMb: 8192,
      staticMb: 8192,
      peakMb: peakMb,
      via: kHeavyViaPrePush,
    );
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < kHeavyMeasuredMinSamples; i++) via(12000),
      ]),
      isNull,
    );
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 1; i <= 100; i++) _run(peakMb: 4000 + i),
        for (int i = 0; i < 100; i++) via(12000),
      ]),
      4608,
    );
  });

  test('a class that was booked too low books more', () {
    // Small-closure tests booked 4096 MB and peaked at p95 5358 MB.
    expect(
      _measured(
        <HeavyHistoryEntry>[
          for (int i = 0; i < 30; i++)
            _run(kind: 'test', bookMb: 4096, peakMb: 5358),
        ],
        kind: 'test',
        staticMb: 4096,
        capMb: 12288,
      ),
      6144,
    );
  });

  test('only runs of the same kind and booking class count', () {
    final List<HeavyHistoryEntry> history = <HeavyHistoryEntry>[
      for (int i = 0; i < 30; i++)
        _run(kind: 'test', bookMb: 6144, peakMb: 5000),
      for (int i = 0; i < 30; i++)
        _run(kind: 'test', bookMb: 2048, peakMb: 900),
      for (int i = 0; i < 30; i++) _run(peakMb: 7000),
    ];
    expect(
      _measured(history, kind: 'test', staticMb: 6144, capMb: 12288),
      5632,
    );
    expect(
      _measured(history, kind: 'test', staticMb: 2048, capMb: 12288),
      1024,
    );
    expect(
      _measured(history, kind: 'test', staticMb: 7680, capMb: 12288),
      isNull,
    );
  });

  test('a run booked from a measurement stays a sample of its class', () {
    // Once measured, bookMb is the measured value; staticMb names the class.
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < 30; i++)
          _run(bookMb: 6400, staticMb: 8192, peakMb: 5599),
      ]),
      6400,
    );
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < 30; i++)
          _run(bookMb: 6400, staticMb: 8192, peakMb: 5599),
      ], staticMb: 6400),
      isNull,
    );
  });

  test('builds are never measured', () {
    expect(
      _measured(
        <HeavyHistoryEntry>[
          for (int i = 0; i < 50; i++)
            _run(kind: 'build', bookMb: 16384, peakMb: 3000),
        ],
        kind: 'build',
        staticMb: 16384,
      ),
      isNull,
    );
  });

  test('runs elsewhere, without a peak, cut short, too old or not yet '
      'ended do not count', () {
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < 30; i++) _run(where: HeavyRanWhere.elsewhere),
        for (int i = 0; i < 30; i++) _run(peakMb: null),
        for (int i = 0; i < 30; i++)
          _run(ran: kHeavyMeasuredMinRun.inSeconds - 1, peakMb: 480),
        for (int i = 0; i < 30; i++)
          _run(ago: kHeavyMeasuredWindow + const Duration(hours: 1)),
        for (int i = 0; i < 30; i++) _run(ago: const Duration(hours: -1)),
      ]),
      isNull,
    );
  });

  test('only the newest runs of the class count', () {
    expect(
      _measured(<HeavyHistoryEntry>[
        // Older: the app was bigger then.
        for (int i = 0; i < 300; i++)
          _run(peakMb: 9000, ago: Duration(days: 2, minutes: i)),
        for (int i = 0; i < kHeavyMeasuredMaxSamples; i++)
          _run(peakMb: 5000, ago: Duration(minutes: 1 + i)),
      ]),
      5632,
    );
  });

  test('never under half the fixed booking, never over the ceiling', () {
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < 30; i++) _run(peakMb: 600),
      ]),
      4096,
    );
    expect(
      _measured(<HeavyHistoryEntry>[
        for (int i = 0; i < 30; i++) _run(peakMb: 16300),
      ]),
      16384,
    );
  });

  test('the booking class survives the file', () {
    final Directory dir = Directory.systemTemp.createTempSync('heavy_meas_');
    addTearDown(() => dir.deleteSync(recursive: true));
    appendHeavyHistory(dir, _run(bookMb: 6400, staticMb: 8192));
    appendHeavyHistory(dir, _run(bookMb: 8192));
    final List<HeavyHistoryEntry> back = readHeavyHistory(dir);
    expect(back[0].bookMb, 6400);
    expect(back[0].staticMb, 8192);
    expect(back[0].bookingClassMb, 8192);
    // A line from before bookings were measured: bookMb was the class.
    expect(back[1].staticMb, isNull);
    expect(back[1].bookingClassMb, 8192);
  });
}
