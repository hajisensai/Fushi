// Contract of tool/dist_test/worker_slot.sh: who has a worker checkout, one
// batch at a time, in the order the runs asked. The script is run for real
// (bash) on a throwaway git checkout, alone and behind worker_shim.sh.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

const String _slot = 'tool/dist_test/worker_slot.sh';
const String _shim = 'tool/dist_test/worker_shim.sh';
const String _runA = '20261115-120000-aaaa';
const String _runB = '20261115-120001-bbbb';
const String _runC = '20261115-120002-cccc';

/// Git Bash on Windows (never the WSL `bash.exe` System32 may put first),
/// `bash` elsewhere.
String _bash() {
  if (!Platform.isWindows) return 'bash';
  final String exec =
      '${Process.runSync('git', <String>['--exec-path']).stdout}'.trim();
  final String root = File(exec).parent.parent.parent.path;
  return '$root/bin/bash.exe';
}

void main() {
  late Directory home;
  late String bash;
  late String checkout;

  setUp(() {
    bash = _bash();
    home = Directory.systemTemp.createTempSync('dist_slot_');
    checkout = '${home.path.replaceAll(r'\', '/')}/work';
    Directory(checkout).createSync();
    final ProcessResult init = Process.runSync('git', <String>[
      'init',
      '-q',
      checkout,
    ]);
    expect(init.exitCode, 0, reason: '${init.stderr}');
  });

  tearDown(() => home.deleteSync(recursive: true));

  ProcessResult slot(String verb, String run, [String? wait]) =>
      Process.runSync(bash, <String>[_slot, verb, checkout, run, ?wait]);

  File ticket(String run) => File('$checkout/.git/fushi-dist/queue/$run');
  String owner() =>
      File('$checkout/.git/fushi-dist/lock/owner').readAsStringSync().trim();
  bool locked() => Directory('$checkout/.git/fushi-dist/lock').existsSync();

  test('a free checkout is taken at once and leaves no ticket', () {
    final ProcessResult r = slot('take', _runA, '0');
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect('${r.stdout}', contains('locked'));
    expect(owner(), _runA);
    expect(ticket(_runA).existsSync(), isFalse);
    // Asked again by the run that has it (a lost answer): still its lock.
    expect(slot('take', _runA, '0').exitCode, 0);
  });

  test('a second run is turned down as busy and keeps its place', () {
    expect(slot('take', _runA, '0').exitCode, 0);
    final ProcessResult b = slot('take', _runB, '0');
    expect(b.exitCode, 75);
    expect('${b.stderr}', contains('busy: in use by dist_test run $_runA'));
    expect(ticket(_runB).existsSync(), isTrue);
    expect(owner(), _runA);
  });

  test('yield keeps the checkout when nobody waits', () {
    expect(slot('take', _runA, '0').exitCode, 0);
    final ProcessResult y = slot('yield', _runA);
    expect(y.exitCode, 0);
    expect('${y.stdout}'.trim(), 'kept');
    expect(owner(), _runA);
  });

  test('yield hands the checkout to a waiting run, which then goes first', () {
    // B has it, A asks and waits.
    expect(slot('take', _runB, '0').exitCode, 0);
    expect(slot('take', _runA, '0').exitCode, 75);

    final ProcessResult y = slot('yield', _runB);
    expect('${y.stdout}'.trim(), 'yielded');
    expect(locked(), isFalse);

    // B wants its next batch at once: A asked first, so B is turned down
    // although the lock is free ...
    final ProcessResult again = slot('take', _runB, '0');
    expect(again.exitCode, 75, reason: '${again.stdout}${again.stderr}');
    expect(locked(), isFalse);
    // ... and A gets it.
    expect(slot('take', _runA, '0').exitCode, 0);
    expect(owner(), _runA);
    // After A's batch the checkout goes back to B, which still waits.
    expect('${slot('yield', _runA).stdout}'.trim(), 'yielded');
    expect(slot('take', _runB, '0').exitCode, 0);
    expect(owner(), _runB);
  });

  test('the order is when a run first asked, not its name', () {
    expect(slot('take', _runC, '0').exitCode, 0);
    Directory('$checkout/.git/fushi-dist/queue').createSync(recursive: true);
    // B queued long before A; both are asking right now.
    ticket(_runB).writeAsStringSync('100\n');
    ticket(_runA).writeAsStringSync('200\n');
    expect(slot('drop', _runC).exitCode, 0);

    expect(slot('take', _runA, '0').exitCode, 75);
    expect(ticket(_runA).readAsStringSync().trim(), '200', reason: 'kept');
    expect(slot('take', _runB, '0').exitCode, 0);
    expect(owner(), _runB);
  });

  test('a run that stopped asking does not hold the others up', () {
    expect(slot('take', _runC, '0').exitCode, 0);
    expect(slot('take', _runB, '0').exitCode, 75);
    // B went silent half a minute ago: not asking right now.
    ticket(
      _runB,
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(seconds: 40)));
    expect('${slot('yield', _runC).stdout}'.trim(), 'kept');
    expect(slot('drop', _runC).exitCode, 0);
    expect(slot('take', _runA, '0').exitCode, 0);
    expect(owner(), _runA);
    expect(ticket(_runB).existsSync(), isTrue, reason: 'place kept for now');

    // Silent for minutes: the ticket goes.
    ticket(
      _runB,
    ).setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
    expect(slot('yield', _runA).exitCode, 0);
    expect(ticket(_runB).existsSync(), isFalse);
  });

  test('yield by a run whose lock was taken over says lost', () {
    expect(slot('take', _runA, '0').exitCode, 0);
    expect('${slot('yield', _runB).stdout}'.trim(), 'lost');
    expect(owner(), _runA);
  });

  test('drop removes the ticket and only the run\'s own lock', () {
    expect(slot('take', _runA, '0').exitCode, 0);
    expect(slot('take', _runB, '0').exitCode, 75);
    expect(slot('drop', _runB).exitCode, 0);
    expect(ticket(_runB).existsSync(), isFalse);
    expect(owner(), _runA, reason: 'not B\'s lock');
    expect(slot('drop', _runA).exitCode, 0);
    expect(locked(), isFalse);
  });

  test('a waiting take gets the checkout as soon as it is given up', () async {
    expect(slot('take', _runA, '0').exitCode, 0);
    final Stopwatch sw = Stopwatch()..start();
    final Future<ProcessResult> waiting = Process.run(bash, <String>[
      _slot,
      'take',
      checkout,
      _runB,
      '30',
    ]);
    // Until B's ticket is there.
    while (!ticket(_runB).existsSync() && sw.elapsed.inSeconds < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect('${slot('yield', _runA).stdout}'.trim(), 'yielded');
    final ProcessResult b = await waiting;
    expect(b.exitCode, 0, reason: '${b.stderr}');
    expect(owner(), _runB);
    expect(sw.elapsed.inSeconds, lessThan(25), reason: 'not the whole wait');
  });

  test('a take that waits stops when its run is dropped', () async {
    expect(slot('take', _runA, '0').exitCode, 0);
    final Stopwatch sw = Stopwatch()..start();
    final Future<ProcessResult> waiting = Process.run(bash, <String>[
      _slot,
      'take',
      checkout,
      _runB,
      '30',
    ]);
    while (!ticket(_runB).existsSync() && sw.elapsed.inSeconds < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(slot('drop', _runB).exitCode, 0);
    final ProcessResult b = await waiting;
    expect(b.exitCode, 75);
    expect('${b.stderr}', contains('gave the checkout up'));
    expect(owner(), _runA);
    expect(sw.elapsed.inSeconds, lessThan(25));
  });

  test('arguments are checked before anything is touched', () {
    expect(slot('take', 'not-a-run', '0').exitCode, 2);
    expect(slot('take', _runA, 'x').exitCode, 2);
    expect(slot('steal', _runA).exitCode, 2);
    expect(
      Process.runSync(bash, <String>[
        _slot,
        'take',
        '${home.path.replaceAll(r'\', '/')}/nowhere',
        _runA,
        '0',
      ]).exitCode,
      2,
    );
    expect(locked(), isFalse);
  });

  group('behind worker_shim.sh', () {
    String workerHome() => home.path.replaceAll(r'\', '/');

    ProcessResult shim(String request) => Process.runSync(
      bash,
      <String>[_shim],
      environment: <String, String>{
        for (final MapEntry<String, String> e in Platform.environment.entries)
          if (e.key != 'SSH_ORIGINAL_COMMAND') e.key: e.value,
        'FUSHI_WORKER_HOME': workerHome(),
        'SSH_ORIGINAL_COMMAND': request,
      },
      includeParentEnvironment: false,
    );

    setUp(() {
      File('${home.path}/limits').writeAsStringSync('MIN_FREE_DISK_GB=0\n');
    });

    test('with slot.sh installed: queued lock, yield, finish', () {
      File(_slot).copySync('${home.path}/slot.sh');
      expect('${shim('hello').stdout}', contains('queue=yes'));

      final ProcessResult a = shim('lock 1 $_runA 0');
      expect(a.exitCode, 0, reason: '${a.stderr}');
      final ProcessResult b = shim('lock 1 $_runB 0');
      expect(b.exitCode, 75);
      expect('${b.stderr}', contains('in use by dist_test run $_runA'));

      expect('${shim('yield 1 $_runA').stdout}'.trim(), 'yielded');
      expect(shim('lock 1 $_runA').exitCode, 75, reason: 'B asked first');
      expect(shim('lock 1 $_runB 0').exitCode, 0);
      expect(owner(), _runB);

      expect(shim('finish 1 $_runA').exitCode, 0);
      expect(ticket(_runA).existsSync(), isFalse);
      expect(owner(), _runB, reason: 'not A\'s lock');
      expect(shim('finish 1 $_runB').exitCode, 0);
      expect(locked(), isFalse);
    });

    test('without slot.sh: the wait is accepted, yield keeps the lock', () {
      expect('${shim('hello').stdout}', contains('queue=no'));
      expect(shim('lock 1 $_runA 25').exitCode, 0);
      expect(shim('lock 1 $_runB 25').exitCode, 75);
      expect('${shim('yield 1 $_runA').stdout}'.trim(), 'kept');
      expect(owner(), _runA);
      expect(shim('finish 1 $_runA').exitCode, 0);
      expect(locked(), isFalse);
    });

    test('lock and yield take plain words only', () {
      expect(shim('lock 1 $_runA soon').exitCode, 2);
      expect(shim('lock 1 $_runA 1 2').exitCode, 2);
      expect(shim('yield 1').exitCode, 2);
      expect(shim('yield 9 $_runA').exitCode, 2);
    });
  });
}
