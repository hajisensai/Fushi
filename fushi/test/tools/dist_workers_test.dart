// Contract of the dist_test worker config and the ssh hardening every
// connection carries (docs/specs/2026-10-24-distributed-unit-tests.md §7.1).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/dist_console.dart';
import '../../tool/test_flow/dist_plan.dart';
import '../../tool/test_flow/dist_workers.dart';

void main() {
  test('every ssh call turns off agent / X11 / port forwarding', () {
    final String joined = kDistSshOptions.join(' ');
    for (final String option in <String>[
      'ForwardAgent=no',
      'ForwardX11=no',
      'ClearAllForwardings=yes',
      'PermitLocalCommand=no',
      'BatchMode=yes',
    ]) {
      expect(joined, contains('-o $option'));
    }
  });

  test('no child process gets a console window of its own', () {
    // Children started in the default mode share dist_test's console; these
    // are the ways to get a fresh (visible, focus-stealing) cmd window.
    final List<File> sources = <File>[
      File('tool/dist_test.dart'),
      for (final FileSystemEntity e in Directory('tool/test_flow').listSync())
        if (e is File && e.path.contains('dist_')) e,
      for (final FileSystemEntity e in Directory('tool/dist_test').listSync())
        if (e is File) e,
    ];
    expect(sources.length, greaterThan(5));
    final RegExp forbidden = RegExp(
      r'ProcessStartMode\.detached|Start-Process|cmd(\.exe)?\s+/[ck]\s+start\b'
      r"|'start',|\bwt(\.exe)?\b|-WindowStyle",
      caseSensitive: false,
    );
    for (final File f in sources) {
      expect(
        forbidden.hasMatch(f.readAsStringSync()),
        isFalse,
        reason: '${f.path} starts a process in its own window',
      );
    }
  });

  test('the console check sees the console flutter test runs in', () {
    // flutter_tester is started with a console of its own (or none needed
    // off Windows); the check must not refuse a normal run.
    expect(hasSharedConsole(), isTrue);
  });

  test('test processes run without proxy variables, as on CI', () {
    expect(
      distTestEnvironment(<String, String>{
        'PATH': 'p',
        'HTTPS_PROXY': 'x',
        'http_proxy': 'x',
        'NO_PROXY': '127.0.0.1',
        'all_proxy': 'x',
      }),
      <String, String>{'PATH': 'p'},
    );
  });

  test('the checked-in example config parses', () {
    final List<DistWorkerConfig> workers = readDistWorkers(
      File('tool/dist_test/workers.example.json').readAsStringSync(),
    );
    expect(
      workers.map((DistWorkerConfig w) => w.kind),
      containsAll(DistWorkerKind.values),
    );
    final DistWorkerConfig mac = workers.firstWhere(
      (DistWorkerConfig w) => w.kind != DistWorkerKind.local,
    );
    expect(mac.platform, DistPlatform.macos);
    expect(mac.workdir, 'fushi-dist/work');
  });

  group('rejects', () {
    void rejects(String json) => expect(
      () => readDistWorkers(json),
      throwsA(isA<DistConfigError>()),
      reason: json,
    );

    test('bad names, kinds, hosts, paths, env keys, duplicates', () {
      rejects(
        '{"workers": [{"name": "a b", "kind": "local", "os": "windows"}]}',
      );
      rejects('{"workers": [{"name": "a", "kind": "rdp", "os": "windows"}]}');
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "host-without-user"}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "u@h", "workdir": "../escape"}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "u@h", "path": ["\$(evil)"]}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "macos", "host": "u@h", "prepareEnv": {"a;b": "x"}}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "local", "os": "windows"}, '
        '{"name": "a", "kind": "local", "os": "windows"}]}',
      );
      rejects(
        '{"workers": [{"name": "a", "kind": "local", "os": "windows"}, '
        '{"name": "b", "kind": "local", "os": "windows"}]}',
      );
    });
  });

  test('slots: one checkout per slot, seeded from and copying the primary', () {
    final List<DistWorkerConfig> configs = readDistWorkers(
      '{"workers": [{"name": "mac", "kind": "ssh-trusted", "os": "macos", '
      '"host": "u@h", "slots": 3, "workdir": "fd/work"}]}',
    );
    final List<DistWorker> workers = createDistWorkers(
      configs.single,
      repoRoot: '.',
    );
    expect(workers.map((DistWorker w) => w.name), <String>[
      'mac',
      'mac.2',
      'mac.3',
    ]);
    expect(workers.map((DistWorker w) => w.config.workdir), <String>[
      'fd/work',
      'fd/work-2',
      'fd/work-3',
    ]);
    expect(workers[2].config.seedRepo, 'fd/work');
    expect(workers[2].config.nativePeer, 'fd/work');
    expect(workers.first.config.nativePeer, isNull);
    expect(
      () => readDistWorkers(
        '{"workers": [{"name": "a", "kind": "local", "os": "windows", '
        '"slots": 2}]}',
      ),
      throwsA(isA<DistConfigError>()),
    );
  });

  group('ssh-shim workers', () {
    test('parse, and address their checkouts by slot', () {
      final List<DistWorkerConfig> configs = readDistWorkers(
        '{"workers": [{"name": "fw", "kind": "ssh-shim", "os": "windows", '
        '"host": "fushitest@fw.ts.net", "identity": "k", "slots": 2}]}',
      );
      final List<DistWorker> workers = createDistWorkers(
        configs.single,
        repoRoot: '.',
      );
      expect(workers.map((DistWorker w) => w.config.slotIndex), <int>[1, 2]);
      expect(workers.map((DistWorker w) => w.machine).toSet(), <String>{
        'fushitest@fw.ts.net',
      });
      expect(shimCheckoutName(1), 'work');
      expect(shimCheckoutName(2), 'work-2');
    });

    test('paths, PATH and env are the owner\'s, not the config\'s', () {
      for (final String extra in <String>[
        '"workdir": "w"',
        '"seedRepo": "s"',
        '"path": ["/x"]',
        '"prepareEnv": {"A": "b"}',
      ]) {
        expect(
          () => readDistWorkers(
            '{"workers": [{"name": "fw", "kind": "ssh-shim", "os": "macos", '
            '"host": "u@h", $extra}]}',
          ),
          throwsA(isA<DistConfigError>()),
          reason: extra,
        );
      }
    });

    test('a Windows machine is only reachable through the shim', () {
      expect(
        () => readDistWorkers(
          '{"workers": [{"name": "w", "kind": "ssh-trusted", "os": "windows", '
          '"host": "u@h"}]}',
        ),
        throwsA(isA<DistConfigError>()),
      );
    });

    test('requests are plain words; anything else fails here', () {
      expect(
        shimRequest('run', <String>['2', '0', '--exclude-tags', 'golden']),
        'run 2 0 --exclude-tags golden',
      );
      expect(
        shimRequest('run', <String>['1', '4', '--tags=a,b']),
        'run 1 4 --tags=a,b',
      );
      for (final String bad in <String>[
        r'--name=$(id)',
        '--x;y',
        "--plain-name='a b'",
        '--file-reporter=json:/tmp/x',
        '-x',
        'a b',
      ]) {
        expect(
          () => shimRequest('run', <String>['1', '0', bad]),
          throwsA(isA<DistWorkerError>()),
          reason: bad,
        );
      }
      expect(
        () => shimRequest('lock', <String>['1', 'r;rm']),
        throwsA(isA<DistWorkerError>()),
      );
    });
  });

  test('FUSHI_DIST_SSH carries the snapshot push too', () {
    expect(distGitSshProgram(<String, String>{}), 'ssh');
    expect(
      distGitSshProgram(<String, String>{
        'FUSHI_DIST_SSH': r'C:\tools\fake ssh.sh',
      }),
      "'C:/tools/fake ssh.sh'",
    );
  });

  test('shellQuote survives single quotes', () {
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote(r'$HOME'), r"'$HOME'");
  });
}
