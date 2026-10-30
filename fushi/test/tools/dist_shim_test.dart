// Contract of tool/dist_test/worker_shim.sh, the only thing a dist_test key
// may run on someone else's machine (docs/specs/2026-10-24-distributed-unit-
// tests.md §7.2). The script is run for real, the way sshd runs a forced
// command: the request in SSH_ORIGINAL_COMMAND, the owner's settings under
// FUSHI_WORKER_HOME.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _shim = 'tool/dist_test/worker_shim.sh';
const String _runA = '20261025-120000-aaaa';
const String _runB = '20261025-120001-bbbb';

/// Git Bash on Windows (never the WSL `bash.exe` System32 may put first),
/// `bash` elsewhere.
String _bash() {
  if (!Platform.isWindows) return 'bash';
  final String exec =
      '${Process.runSync('git', <String>['--exec-path']).stdout}'.trim();
  // <Git>/mingw64/libexec/git-core -> <Git>/bin/bash.exe
  final String root = File(exec).parent.parent.parent.path;
  return '$root/bin/bash.exe';
}

void main() {
  late Directory home;
  late String bash;

  setUp(() {
    bash = _bash();
    home = Directory.systemTemp.createTempSync('dist_shim_');
    // Room for the checkout lock regardless of the test machine's disk.
    File('${home.path}/limits').writeAsStringSync('MIN_FREE_DISK_GB=0\n');
  });

  tearDown(() => home.deleteSync(recursive: true));

  String workerHome() => home.path.replaceAll(r'\', '/');

  /// Runs the shim; [request] null means run by hand (the owner's switch).
  ProcessResult shim(String? request, {List<String> args = const <String>[]}) {
    final Map<String, String> env = <String, String>{
      for (final MapEntry<String, String> e in Platform.environment.entries)
        if (e.key != 'SSH_ORIGINAL_COMMAND') e.key: e.value,
      'FUSHI_WORKER_HOME': workerHome(),
      'SSH_ORIGINAL_COMMAND': ?request,
    };
    return Process.runSync(
      bash,
      <String>[_shim, ...args],
      environment: env,
      includeParentEnvironment: false,
    );
  }

  void refused(String request) {
    final ProcessResult r = shim(request);
    expect(r.exitCode, 2, reason: '$request\n${r.stderr}');
  }

  test('anything but the verbs is refused, and nothing runs', () {
    final String pwned = '${workerHome()}/pwned';
    for (final String request in <String>[
      'bash',
      'sh -c id',
      'hello; touch $pwned',
      'hello && touch $pwned',
      r'lock 1 $(touch PWNED)',
      'lock 1 `touch $pwned`',
      'scp -t /tmp',
      'git-upload-pack \'work\'',
      'git-receive-pack \'../work\'',
      'git-receive-pack \'/etc\'',
      "git-receive-pack 'work'; touch $pwned",
      'lock 1 not-a-run-id',
      'lock 0 $_runA',
      'prepare 1 HEAD',
      'run 1 x',
    ]) {
      refused(request);
    }
    expect(File(pwned).existsSync(), isFalse);
    expect(File('PWNED').existsSync(), isFalse);
  });

  test('every later step needs the run\'s lock', () {
    refused("git-receive-pack 'work'");
    refused('prepare 1 ${'a' * 40}');
    refused('run 1 0');
  });

  test('one run per checkout; the lock is released by its owner only', () {
    final ProcessResult a = shim('lock 1 $_runA');
    expect(a.exitCode, 0, reason: '${a.stderr}');
    expect(
      File(
        '${workerHome()}/work/.git/fushi-dist/lock/owner',
      ).readAsStringSync().trim(),
      _runA,
    );

    final ProcessResult b = shim('lock 1 $_runB');
    expect(b.exitCode, 75);
    expect('${b.stderr}', contains('in use by dist_test run $_runA'));

    expect(shim('finish 1 $_runB').exitCode, 0);
    expect(shim('lock 1 $_runB').exitCode, 75, reason: 'not B\'s lock');
    expect(shim('finish 1 $_runA').exitCode, 0);
    expect(shim('lock 1 $_runB').exitCode, 0);
  });

  test('slots beyond the owner\'s MAX_SLOTS are not offered', () {
    refused('lock 2 $_runA');
    File(
      '${home.path}/limits',
    ).writeAsStringSync('MIN_FREE_DISK_GB=0\nMAX_SLOTS=2\n');
    final ProcessResult r = shim('lock 2 $_runA');
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(Directory('${workerHome()}/work-2/.git').existsSync(), isTrue);
  });

  test('the limits file is read as numbers, never executed', () {
    final String pwned = '${workerHome()}/pwned';
    File('${home.path}/limits').writeAsStringSync(
      'MIN_FREE_DISK_GB=0\nMAX_SLOTS=\$(touch $pwned)\nMAX_SLOTS=2; touch $pwned\n',
    );
    refused('lock 2 $_runA');
    expect(File(pwned).existsSync(), isFalse);
  });

  test('pause / resume by the owner: work is turned down as busy', () {
    expect(shim(null, args: <String>['pause']).exitCode, 0);
    final ProcessResult paused = shim('lock 1 $_runA');
    expect(paused.exitCode, 75);
    expect('${paused.stderr}', contains('paused'));

    expect(shim(null, args: <String>['resume']).exitCode, 0);
    expect(shim('lock 1 $_runA').exitCode, 0);

    expect(shim(null, args: <String>['pause']).exitCode, 0);
    final ProcessResult run = shim('run 1 0');
    expect(run.exitCode, 75);
    expect('${run.stderr}', contains('paused'));
  });

  test('a batch is turned down below the owner\'s free-memory floor', () {
    expect(shim('lock 1 $_runA').exitCode, 0);
    File(
      '${home.path}/limits',
    ).writeAsStringSync('MIN_FREE_DISK_GB=0\nMIN_FREE_MEM_MB=999999999\n');
    final ProcessResult r = shim('run 1 0');
    expect(r.exitCode, 75);
    expect('${r.stderr}', contains('low memory'));
  });

  test('hello reads free memory without WMI or PowerShell', () {
    // A standard account under sshd is denied WMI: with nothing but Git's
    // own tools on PATH the shim must still see the machine's memory.
    final Map<String, String> env = <String, String>{
      for (final MapEntry<String, String> e in Platform.environment.entries)
        if (e.key != 'SSH_ORIGINAL_COMMAND') e.key: e.value,
      'FUSHI_WORKER_HOME': workerHome(),
      'SSH_ORIGINAL_COMMAND': 'hello',
      if (Platform.isWindows)
        'PATH': '${File(bash).parent.parent.path}/usr/bin',
    };
    final ProcessResult r = Process.runSync(
      bash,
      <String>[_shim],
      environment: env,
      includeParentEnvironment: false,
    );
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final String? mem = RegExp(
      r'^free_mem_mb=(\d+)\s*$',
      multiLine: true,
    ).firstMatch('${r.stdout}')?.group(1);
    expect(int.tryParse(mem ?? ''), greaterThan(0), reason: '${r.stdout}');
  });

  test('flutter test options are plain, checked before anything runs', () {
    expect(shim('lock 1 $_runA').exitCode, 0);
    refused('run 1 0 --file-reporter=json:/tmp/x');
    refused('run 1 0 -x');
  });

  test('integration tests (worker_run.sh itest) are out of reach', () {
    expect(shim('lock 1 $_runA').exitCode, 0);
    refused('run 1 itest');
  });

  test('analyze needs the lock and takes only the fatal-* switches', () {
    refused('analyze 1');
    expect(shim('lock 1 $_runA').exitCode, 0);
    refused('analyze 1 --write=lib/x.dart');
    refused('analyze 1 --watch');
    refused('analyze 1 lib');
    refused('analyze 2');
  });

  test('analyze is turned down as busy when paused or short of memory', () {
    expect(shim('lock 1 $_runA').exitCode, 0);
    expect(shim(null, args: <String>['pause']).exitCode, 0);
    final ProcessResult paused = shim('analyze 1 --no-fatal-infos');
    expect(paused.exitCode, 75);
    expect('${paused.stderr}', contains('paused'));
    expect(shim(null, args: <String>['resume']).exitCode, 0);
    File(
      '${home.path}/limits',
    ).writeAsStringSync('MIN_FREE_DISK_GB=0\nMIN_FREE_MEM_MB=999999999\n');
    final ProcessResult low = shim('analyze 1');
    expect(low.exitCode, 75);
    expect('${low.stderr}', contains('low memory'));
  });

  group('worker_analyze.sh', () {
    /// Runs it in this checkout with [paths] on stdin; it must refuse before
    /// flutter starts.
    Future<ProcessResult> analyze(
      List<String> paths, {
      List<String> options = const <String>[],
    }) async {
      final Process p = await Process.start(bash, <String>[
        'tool/dist_test/worker_analyze.sh',
        ...options,
      ]);
      p.stdin.write(paths.map((String l) => '$l\n').join());
      await p.stdin.close();
      final Future<String> out = p.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final Future<String> err = p.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      return ProcessResult(p.pid, await p.exitCode, await out, await err);
    }

    test('refuses paths outside the app sources and unknown options', () async {
      for (final String bad in <String>[
        '../secrets',
        'lib/../../x',
        '/etc',
        'android/app',
        'lib/a b.dart',
        r'lib/$(touch x)',
        'lib/no_such_file_xyz.dart',
      ]) {
        final ProcessResult r = await analyze(<String>[bad]);
        expect(r.exitCode, 2, reason: '$bad\n${r.stderr}');
      }
      final ProcessResult opt = await analyze(
        const <String>[],
        options: <String>['--write=x'],
      );
      expect(opt.exitCode, 2, reason: '${opt.stderr}');
    });
  });
}
