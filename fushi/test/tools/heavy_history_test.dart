// tool/test_flow/heavy_history.dart: one line per finished heavy.dart run,
// and what `heavy.dart --stats` makes of them.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_history.dart';

HeavyHistoryEntry _entry({
  DateTime? at,
  String kind = 'test',
  HeavyRanWhere where = HeavyRanWhere.here,
  int queued = 0,
  int ran = 10,
  int exitCode = 0,
  int? peakMb,
}) => HeavyHistoryEntry(
  at: at ?? DateTime.utc(2026, 11, 15, 12),
  kind: kind,
  label: 'flutter test a_test.dart',
  where: where,
  queued: Duration(seconds: queued),
  ran: Duration(seconds: ran),
  exitCode: exitCode,
  bookMb: 4096,
  peakMb: peakMb,
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('heavy_history_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('an entry survives the file', () {
    appendHeavyHistory(
      dir,
      _entry(queued: 75, ran: 31, exitCode: 1, peakMb: 3300),
    );
    appendHeavyHistory(
      dir,
      _entry(where: HeavyRanWhere.elsewhere, kind: 'analyze'),
    );

    final List<HeavyHistoryEntry> read = readHeavyHistory(dir);
    expect(read, hasLength(2));
    expect(read[0].kind, 'test');
    expect(read[0].where, HeavyRanWhere.here);
    expect(read[0].queued, const Duration(seconds: 75));
    expect(read[0].ran, const Duration(seconds: 31));
    expect(read[0].exitCode, 1);
    expect(read[0].bookMb, 4096);
    expect(read[0].peakMb, 3300);
    expect(read[0].at, DateTime.utc(2026, 11, 15, 12));
    expect(read[1].where, HeavyRanWhere.elsewhere);
    expect(read[1].peakMb, isNull);
  });

  test('lines that are not entries are skipped, not fatal', () {
    appendHeavyHistory(dir, _entry());
    File('${dir.path}/$kHeavyHistoryFile').writeAsStringSync(
      '{"at":"2026-11-15T12:00:00Z","kind":"test"\n'
      'not json\n'
      '{"at":"2026-11-15T12:00:00Z","kind":"test","where":"mars",'
      '"queuedS":1,"ranS":1,"exit":0}\n'
      '[]\n',
      mode: FileMode.append,
    );
    appendHeavyHistory(dir, _entry(kind: 'build'));
    expect(readHeavyHistory(dir).map((HeavyHistoryEntry e) => e.kind), <String>[
      'test',
      'build',
    ]);
  });

  test('since leaves older runs out; no file reads as no runs', () {
    expect(readHeavyHistory(dir), isEmpty);
    appendHeavyHistory(dir, _entry(at: DateTime.utc(2026, 11, 1)));
    appendHeavyHistory(dir, _entry(at: DateTime.utc(2026, 11, 14)));
    expect(
      readHeavyHistory(dir, since: DateTime.utc(2026, 11, 8)),
      hasLength(1),
    );
  });

  test('past its size limit the older half goes', () {
    for (int i = 0; i < 40; i++) {
      appendHeavyHistory(dir, _entry(exitCode: i), maxBytes: 2000);
    }
    final List<HeavyHistoryEntry> read = readHeavyHistory(dir);
    expect(read.length, lessThan(40));
    expect(read.last.exitCode, 39, reason: 'the newest is kept');
    expect(File('${dir.path}/$kHeavyHistoryFile').lengthSync(), lessThan(4000));
    // Still in order.
    for (int i = 1; i < read.length; i++) {
      expect(read[i].exitCode, read[i - 1].exitCode + 1);
    }
  });

  test('a state directory that cannot be written does not fail the run', () {
    final File blocker = File('${dir.path}/blocked')..writeAsStringSync('x');
    // A file where the directory should be.
    expect(
      () => appendHeavyHistory(Directory(blocker.path), _entry()),
      returnsNormally,
    );
  });

  test('nearest-rank percentiles', () {
    expect(heavyPercentile(<int>[], 0.5), 0);
    expect(heavyPercentile(<int>[7], 0.9), 7);
    expect(heavyPercentile(<int>[4, 1, 3, 2], 0.5), 2);
    expect(heavyPercentile(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9);
    expect(heavyPercentile(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 1), 10);
  });

  test('the report: share elsewhere, queueing per kind and place', () {
    expect(
      renderHeavyStats(<HeavyHistoryEntry>[], days: 7),
      contains('no finished run recorded in the last 7 day(s)'),
    );
    final String report = renderHeavyStats(<HeavyHistoryEntry>[
      _entry(queued: 0, ran: 20),
      _entry(queued: 600, ran: 40),
      _entry(queued: 9000, ran: 60),
      _entry(where: HeavyRanWhere.elsewhere, queued: 30, ran: 64),
      _entry(kind: 'analyze', where: HeavyRanWhere.elsewhere, ran: 200),
    ], days: 7);
    expect(
      report,
      contains('5 run(s) in the last 7 day(s), 2 on another machine (40%)'),
    );
    expect(report, contains('2h40m queued in all'));
    final String here = report
        .split('\n')
        .firstWhere((String l) => l.contains('test') && l.contains(' here '));
    expect(here, contains('   3  '));
    expect(here, contains('10m00s / 2h30m / 2h30m'));
    expect(here, contains('40s / 60s'));
    expect(
      report.split('\n').where((String l) => l.contains('elsewhere')),
      hasLength(2),
    );
    expect(report, isNot(contains('caller was gone')));
  });

  // 2026-11-20: runs whose caller was gone used to be admitted and die with
  // -1073741502; they now end with kHeavyCallerGoneExit.
  test('runs whose caller was gone are counted apart', () {
    final String report = renderHeavyStats(<HeavyHistoryEntry>[
      _entry(queued: 60, ran: 20),
      _entry(queued: 7000, ran: 0, exitCode: kHeavyCallerGoneExit),
      _entry(queued: 200, ran: 0, exitCode: kHeavyCallerGoneExit),
    ], days: 7);
    expect(
      report,
      contains(
        '2 run(s) cancelled because their caller was gone '
        '(exit $kHeavyCallerGoneExit), 2h00m queued by them',
      ),
    );
    expect(report, contains('1 run(s) in the last 7 day(s)'));
    expect(report, contains('60s queued in all'));
  });

  test('a run killed because its caller was gone books nothing', () {
    final DateTime now = DateTime.utc(2026, 11, 20, 12);
    List<HeavyHistoryEntry> runs(int exitCode) => <HeavyHistoryEntry>[
      for (int i = 0; i < kHeavyMeasuredMinSamples; i++)
        HeavyHistoryEntry(
          at: now.subtract(Duration(hours: i + 1)),
          kind: 'test',
          label: 'flutter test',
          where: HeavyRanWhere.here,
          queued: Duration.zero,
          ran: const Duration(seconds: 60),
          exitCode: exitCode,
          bookMb: 4096,
          staticMb: 4096,
          peakMb: 1000,
        ),
    ];
    int? book(int exitCode) => heavyMeasuredBookMb(
      runs(exitCode),
      kind: 'test',
      staticMb: 4096,
      capMb: 12288,
      now: now,
    );
    expect(book(1), isNotNull);
    expect(book(kHeavyCallerGoneExit), isNull);
  });
}
