// tool/test_flow/heavy_history.dart: one line per finished heavy.dart run,
// and what `heavy.dart --stats` makes of them.

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_budget.dart';
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
    // Lines before 2026-11-20 say no worktree: no per-worktree section.
    expect(report, isNot(contains('queued most for')));
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

  test('worktree and tool survive the file; older lines have neither', () {
    appendHeavyHistory(
      dir,
      HeavyHistoryEntry(
        at: DateTime.utc(2026, 11, 20, 8),
        kind: 'test',
        label: 'dist_test local worker r1',
        where: HeavyRanWhere.here,
        queued: const Duration(seconds: 12),
        ran: const Duration(seconds: 900),
        exitCode: 0,
        bookMb: 12288,
        cwd: 'D:/wt/a',
        via: kHeavyViaDistLocal,
      ),
    );
    // A line as heavy.dart wrote it before 2026-11-20.
    File('${dir.path}/$kHeavyHistoryFile').writeAsStringSync(
      '{"at":"2026-11-17T10:00:00.000Z","kind":"build","label":"flutter '
      'build","where":"here","queuedS":5,"ranS":60,"exit":0,"bookMb":16384}\n',
      mode: FileMode.append,
    );

    final List<HeavyHistoryEntry> read = readHeavyHistory(dir);
    expect(read, hasLength(2));
    expect(read[0].cwd, 'D:/wt/a');
    expect(read[0].via, kHeavyViaDistLocal);
    expect(read[1].cwd, isNull);
    expect(read[1].via, isNull);
    expect(read[1].bookMb, 16384);
    expect(
      read[1].toJson().keys,
      isNot(anyOf(contains('cwd'), contains('via'))),
    );
  });

  test('a tool that took the lease itself books like heavy.dart', () {
    final HeavyHistoryEntry test = heavyHolderEntry(
      via: kHeavyViaFlutterTestFailures,
      need: heavyNeedFor(HeavyKind.test),
      label: 'flutter_test_failures -> out',
      cwd: 'D:/wt/a',
      queued: const Duration(seconds: 30),
      ran: const Duration(seconds: 400),
      exitCode: 1,
      peakMb: 7000,
      at: DateTime.utc(2026, 11, 20),
    );
    expect(test.kind, 'test');
    expect(test.where, HeavyRanWhere.here);
    expect(test.bookMb, heavyNeedFor(HeavyKind.test).bookedMb);
    // A measured kind: its booking is its class, as heavy.dart writes it.
    expect(test.staticMb, heavyNeedFor(HeavyKind.test).bookedMb);
    expect(test.queued, const Duration(seconds: 30));
    expect(test.ran, const Duration(seconds: 400));
    expect(test.exitCode, 1);
    expect(test.peakMb, 7000);
    expect(test.cwd, 'D:/wt/a');
    expect(test.via, kHeavyViaFlutterTestFailures);

    final HeavyHistoryEntry build = heavyHolderEntry(
      via: kHeavyViaPrePush,
      need: heavyNeedFor(HeavyKind.build),
      label: 'pre-push build',
      cwd: null,
      queued: Duration.zero,
      ran: const Duration(seconds: 1),
      exitCode: 0,
    );
    expect(build.staticMb, isNull);
    expect(build.peakMb, isNull);
  });

  test('the report: tools apart from heavy.dart runs, then worktrees', () {
    HeavyHistoryEntry run({required int queued, String? cwd, String? via}) =>
        HeavyHistoryEntry(
          at: DateTime.utc(2026, 11, 20, 12),
          kind: 'test',
          label: 'x',
          where: HeavyRanWhere.here,
          queued: Duration(seconds: queued),
          ran: const Duration(seconds: 10),
          exitCode: 0,
          cwd: cwd,
          via: via,
        );
    final String report = renderHeavyStats(<HeavyHistoryEntry>[
      run(queued: 100, cwd: 'D:/wt/a'),
      run(queued: 50, cwd: 'D:/wt/b', via: kHeavyViaDistLocal),
      run(queued: 400, cwd: 'D:/wt/b', via: kHeavyViaDistLocal),
      run(queued: 7), // before 2026-11-20: no worktree
    ], days: 7);
    final List<String> lines = report.split('\n');
    expect(
      lines.firstWhere((String l) => l.contains('(dist-local)')),
      contains('   2  '),
    );
    expect(
      lines.firstWhere((String l) => l.contains(' here ') && !l.contains('(')),
      contains('   2  '),
    );
    expect(report, contains('queued most for (of 2 worktree(s) on record):'));
    final int b = lines.indexWhere((String l) => l.endsWith('D:/wt/b'));
    final int a = lines.indexWhere((String l) => l.endsWith('D:/wt/a'));
    expect(b, greaterThan(0));
    expect(a, greaterThan(b), reason: 'most queued first');
    expect(lines[b], contains('7m30s in    2 run(s)'));
  });
}
