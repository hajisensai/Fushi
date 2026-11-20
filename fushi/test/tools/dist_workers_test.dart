// Contract of the dist_test worker config and the ssh hardening every
// connection carries (docs/specs/2026-10-24-distributed-unit-tests.md §7.1).

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/dist_console.dart';
import '../../tool/test_flow/flutter_sdk_executables.dart';
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
      rejects(
        '{"workers": [{"name": "a", "kind": "ssh-trusted", '
        '"os": "freebsd", "host": "u@h"}]}',
      );
    });

    test('a Linux worker takes unpinned suites, never itest', () {
      final DistWorker linux = createDistWorkers(
        readDistWorkers(
          '{"workers": [{"name": "pve", "kind": "ssh-trusted", '
          '"os": "linux", "host": "u@h", "capabilities": ["ffmpeg"]}]}',
        ).single,
        repoRoot: '.',
      ).single;
      expect(linux.config.platform, DistPlatform.linux);
      expect(
        linux.eligible(const DistUnit(path: 'test/a_test.dart', weightMs: 1)),
        isTrue,
      );
      expect(
        linux.eligible(
          const DistUnit(
            path: 'test/a_test.dart',
            weightMs: 1,
            capabilities: <String>{'ffmpeg'},
          ),
        ),
        isTrue,
      );
      expect(
        linux.eligible(
          const DistUnit(
            path: 'test/a_test.dart',
            weightMs: 1,
            platform: DistPlatform.macos,
          ),
        ),
        isFalse,
      );
      rejects(
        '{"workers": [{"name": "pve", "kind": "ssh-trusted", '
        '"os": "linux", "host": "u@h", "capabilities": ["itest"]}]}',
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

  test('a Windows worker\'s squashed exit code is read back from the tag', () {
    // Its sshd reports every failure as 1; the shim's stderr tag says which.
    int code(int exit, String stderr, {bool printedNothing = true}) =>
        distRemoteExitCode(
          exit,
          printedNothing: printedNothing,
          stderr: stderr,
        );
    expect(
      code(1, 'busy: low memory: 2556 MB free (MIN_FREE_MEM_MB=6144)\r\n'),
      kDistShimBusy,
    );
    expect(code(1, 'error: not allowed: bogusverb\n'), kDistShimRefused);
    expect(code(1, 'x\ntoolchain: Android NDK 28\n'), kDistToolchainMissing);
    // The true code where the transport keeps it.
    expect(code(kDistShimBusy, 'busy: paused\n'), kDistShimBusy);
    // Anything that printed output, or carries no tag, keeps its code.
    expect(code(1, 'busy: x\n', printedNothing: false), 1);
    expect(code(1, 'Some tests failed.\n'), 1);
    expect(code(0, 'busy: x\n'), 0);
  });

  test('processCount follows how each worker splits a batch', () {
    // A batch's coverage timeout is paid per test process (dist_test.dart).
    final List<DistWorker> workers = <DistWorker>[
      for (final DistWorkerConfig c in readDistWorkers(
        '{"workers": ['
        '{"name": "here", "kind": "local", "os": "windows"}, '
        '{"name": "mac", "kind": "ssh-trusted", "os": "macos", "host": "u@m"}, '
        '{"name": "win", "kind": "ssh-shim", "os": "windows", "host": "u@w", '
        '"identity": "k"}'
        ']}',
      ))
        ...createDistWorkers(c, repoRoot: '.'),
    ];
    final DistBatch batch = DistBatch(
      id: 1,
      units: <DistUnit>[
        for (int i = 0; i < 1000; i++)
          DistUnit(path: 'test/a/suite_${i}_test.dart', weightMs: 1),
      ],
    );
    final int chars = batch.files.fold<int>(
      0,
      (int s, String f) => s + f.length + 1,
    );
    expect(chars, greaterThan(kRemoteWindowsMaxCommandChars));
    expect(workers.map((DistWorker w) => w.processCount(batch)), <int>[
      splitByPathChars(batch.files, kLocalMaxCommandChars).length,
      1,
      splitByPathChars(batch.files, kRemoteWindowsMaxCommandChars).length,
    ]);
    expect(workers.first.processCount(batch), greaterThan(2));
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

  // 2026-11-10: with all three Mac slots locked by other runs, `lock`
  // exits 75 in prepare and every worker was dropped at once, whatever
  // --busy-retries said (only a batch turned down at its start was asked
  // again); analyze / --build ignored --busy-retries altogether.
  group('turned down at prepare (lock busy)', () {
    test('asked again up to --busy-retries, then given up', () async {
      int calls = 0;
      final List<String> said = <String>[];
      await expectLater(
        distRetryWhileBusy<bool>(
          () async {
            calls++;
            throw DistWorkerBusy('lock failed on mac (exit 75): busy: x');
          },
          retries: 3,
          pause: (_) async {},
          said: said.add,
        ),
        throwsA(isA<DistWorkerBusy>()),
      );
      expect(calls, 4, reason: 'the first ask plus three retries');
      expect(said, hasLength(3));
    });

    test('a slot that frees up is taken', () async {
      int calls = 0;
      final bool? ok = await distRetryWhileBusy<bool>(
        () async {
          if (++calls < 3) throw DistWorkerBusy('busy: locked');
          return true;
        },
        retries: 5,
        pause: (_) async {},
      );
      expect(ok, isTrue);
      expect(calls, 3);
    });

    test(
      'a real prepare failure is not retried; none at --busy-retries=0',
      () async {
        int calls = 0;
        await expectLater(
          distRetryWhileBusy<bool>(
            () async {
              calls++;
              throw DistWorkerError('prepare failed: compile error');
            },
            retries: 5,
            pause: (_) async {},
          ),
          throwsA(isNot(isA<DistWorkerBusy>())),
        );
        expect(calls, 1);
        calls = 0;
        await expectLater(
          distRetryWhileBusy<bool>(
            () async {
              calls++;
              throw DistWorkerBusy('busy: locked');
            },
            retries: 0,
            pause: (_) async {},
          ),
          throwsA(isA<DistWorkerBusy>()),
        );
        expect(calls, 1, reason: 'heavy.dart passes --busy-retries=0');
      },
    );

    test('stops waiting once the others did the work', () async {
      int calls = 0;
      final bool? ok = await distRetryWhileBusy<bool>(
        () async {
          calls++;
          throw DistWorkerBusy('busy: locked');
        },
        retries: 5,
        pause: (_) async {},
        stillWanted: () => false,
      );
      expect(ok, isNull);
      expect(calls, 1);
    });

    // 2026-11-15 (#3459 review): the pause was 3 s for every worker with a
    // queue wait configured, also when this ask came back at once (paused,
    // short of disk, a shim without slot.sh, an old shim without the wait
    // argument) -- an ssh connection every 3 s per waiting run and slot.
    test('an ask turned down at once is not asked again after 3 s', () async {
      final List<Duration> pauses = <Duration>[];
      await expectLater(
        distRetryWhileBusy<bool>(
          () async => throw DistWorkerBusy(
            'lock failed on w (exit 75): busy: paused by the owner',
            waited: const Duration(seconds: 1),
          ),
          retries: 2,
          pause: (Duration d) async => pauses.add(d),
        ),
        throwsA(isA<DistWorkerBusy>()),
      );
      expect(pauses, <Duration>[
        const Duration(seconds: 29),
        const Duration(seconds: 29),
      ]);
      // A busy error that says nothing about its ask did not wait.
      expect(distBusyPause(Duration.zero), kDistBusyAskAgain);
    });

    test('an ask that waited in the queue is asked again at once', () async {
      final List<Duration> pauses = <Duration>[];
      final List<String> said = <String>[];
      int calls = 0;
      final bool? ok = await distRetryWhileBusy<bool>(
        () async {
          if (++calls < 3) {
            throw DistWorkerBusy(
              'busy: in use by dist_test run 20261115-120000-aaaa',
              waited: const Duration(seconds: 27),
            );
          }
          return true;
        },
        retries: 5,
        pause: (Duration d) async => pauses.add(d),
        said: said.add,
      );
      expect(ok, isTrue);
      expect(pauses, <Duration>[kDistQueueAskAgain, kDistQueueAskAgain]);
      expect(said.first, endsWith('asking again in 3s'));
      // Never less, however long the ask took.
      expect(distBusyPause(const Duration(minutes: 2)), kDistQueueAskAgain);
    });

    test('the pause after a queue wait keeps the place in the queue', () {
      // worker_slot.sh: a ticket not touched for PRESENT (20 s) is passed
      // over. The wait there ends up to a second early (whole seconds).
      final Duration pause = distBusyPause(
        const Duration(seconds: kDistQueueWaitSeconds - 1),
      );
      expect(pause, lessThanOrEqualTo(const Duration(seconds: 6)));
      expect(pause.inSeconds, lessThan(20 ~/ 2));
    });

    test('every busy answer is handed on, the last one too', () async {
      final List<String> answers = <String>[];
      await expectLater(
        distRetryWhileBusy<bool>(
          () async => throw DistWorkerBusy('busy: locked'),
          retries: 1,
          pause: (_) async {},
          answered: (DistWorkerBusy e) => answers.add(e.message),
        ),
        throwsA(isA<DistWorkerBusy>()),
      );
      expect(answers, hasLength(2));
    });

    // resume() used to sleep a fixed 3 s after every busy answer: 72 asks of
    // a machine paused meanwhile were over in minutes, not the half hour
    // kDistResumeAsks stands for. It goes through distRetryWhileBusy now.
    test('coming back after a rest asks with the same pauses', () {
      final String source = File(
        'tool/test_flow/dist_workers.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final int at = source.indexOf(
        'Future<bool> resume(',
        source.indexOf('class SshDistWorker'),
      );
      expect(at, greaterThan(0));
      final String body = source.substring(at, source.indexOf('\n  }\n', at));
      expect(body, contains('distRetryWhileBusy<bool>('));
      expect(body, contains('retries: kDistResumeAsks - 1'));
      expect(body, isNot(contains('Future<void>.delayed')));
      expect(kDistBusyAskAgain * kDistResumeAsks, const Duration(minutes: 30));
    });

    test('analyze / build: another pass only while it was just busy', () {
      expect(
        distJobAskAgain(busy: true, round: 0, retries: 60, lost: false),
        isTrue,
      );
      expect(
        distJobAskAgain(busy: true, round: 60, retries: 60, lost: false),
        isFalse,
      );
      expect(
        distJobAskAgain(busy: false, round: 0, retries: 60, lost: false),
        isFalse,
        reason: 'no toolchain / prepare red: not worth another pass',
      );
      expect(
        distJobAskAgain(busy: true, round: 0, retries: 60, lost: true),
        isFalse,
        reason: 'heavy.dart admitted it here meanwhile',
      );
      expect(
        distJobAskAgain(busy: true, round: 0, retries: 0, lost: false),
        isFalse,
      );
    });

    test('lock / init exit 75 reads as busy', () {
      expect(
        distRemoteExitCode(
          75,
          printedNothing: true,
          stderr: 'busy: in use by dist_test run 20261110-235126-3cd3\n',
        ),
        kDistShimBusy,
      );
    });
  });

  test('yield: only a clear answer gives the checkout up', () {
    expect(distYielded('yielded\n'), isTrue);
    expect(distYielded('lost\r\n'), isTrue);
    expect(distYielded('kept\n'), isFalse);
    // Unreadable: keeping it only makes the others wait; dropping a checkout
    // the run still has would run a batch on another run's commit.
    expect(distYielded(''), isFalse);
    expect(distYielded('yielded to nobody\n'), isFalse);
    expect(distYielded('some banner\nkept\n'), isFalse);
    expect(distYielded('some banner\nyielded\n'), isTrue);
  });

  test('queueing is off until dist_test turns it on; local never rests', () {
    final DistWorker local = createDistWorkers(
      const DistWorkerConfig(
        name: 'self-win',
        kind: DistWorkerKind.local,
        platform: DistPlatform.windows,
      ),
      repoRoot: '.',
    ).single;
    expect(local.queueWaitSeconds, 0);
    expect(local.resting, isFalse);
    // The wait there stays under worker_slot.sh's PRESENT window (20 s) plus
    // the pause before the next ask, or a waiting run would look gone.
    expect(kDistQueueAskAgain.inSeconds, lessThan(20));
  });

  group('prepare step stall watchdog (kDistPushStall)', () {
    late Directory scratch;
    setUp(() => scratch = Directory.systemTemp.createTempSync('dist_stall_'));
    tearDown(() => scratch.deleteSync(recursive: true));

    /// A dart script printing `start`, then [body]; started the way a
    /// prepare step is (dart.bat on Windows needs the shell).
    Future<Process> script(String body) {
      final File f = File('${scratch.path}/s.dart')
        ..writeAsStringSync(
          "import 'dart:io';\n"
          'Future<void> main() async {\n'
          "  stdout.writeln('start');\n"
          '$body\n'
          '}\n',
        );
      final String dart = FlutterSdkExecutables.current().dart();
      return Process.start(
        dart,
        <String>[f.path],
        // A .bat launcher (the SDK's dart on Windows) needs the shell.
        runInShell: dart.toLowerCase().endsWith('.bat'),
      );
    }

    // The production kill: the whole tree, so a shell's dart child goes too.
    Future<void> killTree(Process p) => distKillStepTree(p);

    test(
      'a step silent for the whole limit is killed and says stalled',
      () async {
        // The shape of the 2026-11-20 push: some output, then silence until
        // the far end gives up (984 s there; 60 s here, never reached).
        final Process p = await script(
          '  await Future<void>.delayed(const Duration(seconds: 60));',
        );
        final Stopwatch sw = Stopwatch()..start();
        final ({ProcessResult result, bool stalled}) r =
            await collectDistProcess(
              p,
              stallAfter: const Duration(seconds: 2),
              kill: () => killTree(p),
            );
        expect(r.stalled, isTrue);
        expect(sw.elapsed, lessThan(const Duration(seconds: 40)));
        expect(r.result.exitCode, isNot(0));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('a step that keeps printing is never killed, however long', () async {
      final Process p = await script(
        '  for (int i = 0; i < 15; i++) {\n'
        "    stdout.writeln('tick \$i');\n"
        '    await Future<void>.delayed(const Duration(milliseconds: 200));\n'
        '  }',
      );
      final ({ProcessResult result, bool stalled}) r = await collectDistProcess(
        p,
        // Above the script's own startup silence even on a loaded machine;
        // the ticks themselves take 3 s in all, longer than a tick gap.
        stallAfter: const Duration(seconds: 10),
        kill: () => killTree(p),
      );
      expect(r.stalled, isFalse);
      expect(r.result.exitCode, 0);
      expect('${r.result.stdout}', contains('tick 14'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('nothing silent runs inside a push: every worker checkout has '
        'receive-pack\'s auto gc off and gc runs in prepare', () {
      // Measured: receive-pack's post-ref-report work (auto gc, hooks) runs
      // before git push prints `To <remote>`, all of it silent -- a gc there
      // would read as a dead link and get the worker killed and benched.
      String read(String p) => File(p).readAsStringSync();
      expect(
        read('tool/dist_test/worker_prepare.sh'),
        allOf(
          contains('git config receive.autogc false'),
          contains('git gc --auto'),
        ),
        reason: 'comes with the snapshot: reaches workers with an old shim',
      );
      final String shim = read('tool/dist_test/worker_shim.sh');
      expect(shim, contains('git config receive.autogc false'));
      expect(shim, contains('git -c receive.autogc=false receive-pack'));
      expect(shim, isNot(contains('exec git receive-pack')));
      expect(
        read('tool/test_flow/dist_workers.dart'),
        contains("'git config receive.autogc false && '"),
        reason: 'the trusted worker init, before its first push',
      );
    });

    test('without a limit nothing watches', () async {
      final Process p = await script('');
      final ({ProcessResult result, bool stalled}) r = await collectDistProcess(
        p,
        kill: () async => fail('no limit, no kill'),
      );
      expect(r.stalled, isFalse);
      expect(r.result.exitCode, 0);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the limit sits between the slowest good push and the hung ones', () {
      // Measured 2026-11-20: good pushes at most 198 s in all with progress
      // at least every second; hung ones silent 312-984 s.
      expect(kDistPushStall, greaterThanOrEqualTo(const Duration(seconds: 60)));
      expect(kDistPushStall, lessThan(const Duration(seconds: 312)));
    });

    test('progress redraws collapse to what was finally shown', () {
      const String err =
          'Enumerating objects: 5, done.\r\n'
          'Writing objects:  20% (1/5)\rWriting objects:  60% (3/5)\r'
          'Writing objects: 100% (5/5), done.\n'
          'To host:work\n';
      expect(
        distCollapseProgress(err),
        'Enumerating objects: 5, done.\n'
        'Writing objects: 100% (5/5), done.\n'
        'To host:work\n',
      );
      expect(
        distLastProgressLine(
          'Writing objects:  20% (1/5)\rWriting objects:  40% (2/5)\r',
        ),
        'last: Writing objects:  40% (2/5)',
      );
      expect(distLastProgressLine(''), 'no output at all');
    });
  });
}
