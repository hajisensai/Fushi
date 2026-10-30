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

  group('integration tests', () {
    test('the generated entry imports and dispatches every manifest test', () {
      final String bash = distBashExecutable();
      final ProcessResult r = Process.runSync(bash, <String>[
        'tool/dist_test/itest_entry.sh',
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final String entry = '${r.stdout}';
      final List<String> files = readDistItests(
        File(kDistItestManifestPath).readAsStringSync(),
      ).keys.toList();
      for (final String f in files) {
        expect(
          entry,
          contains("import '../${f.substring('integration_test/'.length)}'"),
        );
        expect(entry, contains("'$f': t"));
      }
      expect(
        RegExp(r'^import ', multiLine: true).allMatches(entry),
        hasLength(files.length + 1),
      );
      expect(entry, contains("Platform.environment['FUSHI_DIST_ITEST']"));
    });

    test('never on an ssh-shim worker', () {
      expect(
        () => readDistWorkers(
          '{"workers": [{"name": "fw", "kind": "ssh-shim", "os": "windows", '
          '"host": "u@h", "capabilities": ["itest"]}]}',
        ),
        throwsA(isA<DistConfigError>()),
      );
    });

    test('only on the first slot of a machine', () {
      final List<DistWorker> workers = createDistWorkers(
        readDistWorkers(
          '{"workers": [{"name": "mac", "kind": "ssh-trusted", "os": "macos", '
          '"host": "u@h", "slots": 2, "capabilities": ["itest"]}]}',
        ).single,
        repoRoot: '.',
      );
      final DistUnit itest = distItestUnits(<String, Set<DistPlatform>>{
        'integration_test/a_test.dart': <DistPlatform>{DistPlatform.macos},
      }).single;
      expect(workers.map((DistWorker w) => w.eligible(itest)), <bool>[
        true,
        false,
      ]);
      const DistUnit unit = DistUnit(path: 'test/a_test.dart', weightMs: 1);
      expect(workers.map((DistWorker w) => w.eligible(unit)), <bool>[
        true,
        true,
      ]);
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

  group('analyze / build go only where hello says they can', () {
    Map<String, String> hello(String extra) =>
        parseDistHello('os=windows\r\nflutter=3.47.6\npaused=no\n$extra');
    const DistJob analyze = DistJob.analyze();
    final DistJob apk = DistJob.build(
      distBuildOf(<String>['flutter', 'build', 'apk'])!,
    );
    final DistJob mac = DistJob.build(
      distBuildOf(<String>['flutter', 'build', 'macos', '--debug'])!,
    );

    test('a shim from before the verb is passed over', () {
      expect(
        distJobBlocker(hello(''), analyze, shim: true),
        contains('analyze'),
      );
      expect(distJobBlocker(hello(''), analyze, shim: false), isNull);
      expect(
        distJobBlocker(hello('analyze=yes'), apk, shim: true),
        contains('predates builds'),
      );
    });

    test('a build needs its toolchain there and the owner\'s consent', () {
      expect(
        distJobBlocker(hello('build=android,windows'), apk, shim: true),
        isNull,
      );
      expect(
        distJobBlocker(hello('build=windows'), apk, shim: true),
        'no android toolchain there (has: windows)',
      );
      expect(
        distJobBlocker(hello('build='), mac, shim: false),
        'no macos toolchain there',
      );
      expect(
        distJobBlocker(hello('build=off'), apk, shim: true),
        contains('ALLOW_BUILD=0'),
      );
    });

    test('paused is paused for every job', () {
      expect(
        distJobBlocker(
          parseDistHello('paused=yes\nanalyze=yes\nbuild=android'),
          apk,
          shim: true,
        ),
        'paused by the owner',
      );
    });
  });

  test('build requests reach the shim as plain words', () {
    expect(
      shimRequest('build', <String>[
        '1',
        ...distBuildOf(<String>[
          'gradlew',
          ':app:assembleRelease',
          '-Ptarget-platform=android-arm64,android-x64',
        ])!.request,
      ]),
      'build 1 gradle :app:assembleRelease '
      '-Ptarget-platform=android-arm64,android-x64',
    );
  });

  test('shellQuote survives single quotes', () {
    expect(shellQuote("it's"), r"'it'\''s'");
    expect(shellQuote(r'$HOME'), r"'$HOME'");
  });
}
