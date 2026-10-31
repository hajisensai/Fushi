// Which heavy commands tool/heavy.dart hands to the other machines
// (tool/test_flow/heavy_offload.dart).

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_offload.dart';

const String _flutter = r'D:\flutter_sdk\flutter_3.47.6\bin\flutter.bat';
const String _dart = r'D:\flutter_sdk\flutter_3.47.6\bin\dart.bat';

void main() {
  bool exists(String p) => <String>{
    'test',
    'test/reader',
    'test/reader/a_test.dart',
    'test/b_test.dart',
    'lib',
    'lib/src/x.dart',
    'tool',
  }.contains(p);

  HeavyOffload? planIn(
    String where,
    List<String> command, {
    bool checkOnly = false,
  }) => planHeavyOffload(
    command,
    where: where,
    cwd: 'D:/r/$where',
    checkOnly: checkOnly,
    exists: exists,
  );

  HeavyOffload? plan(List<String> args) =>
      planIn('fushi', <String>[_flutter, ...args]);

  group('flutter test', () {
    test('suites go out; dist_test owns pub and reporter', () {
      final HeavyOffload? o = plan(<String>[
        'test',
        r'test\reader\a_test.dart',
        './test/b_test.dart',
        '--no-pub',
        '--concurrency=4',
        '-r',
        'expanded',
      ]);
      expect(o?.kind, HeavyOffloadKind.test);
      expect(o!.distArgs, <String>[
        '--offload',
        '--busy-retries=$kHeavyOffloadBusyRetries',
        '--concurrency=4',
        'test/reader/a_test.dart',
        'test/b_test.dart',
      ]);
    });

    test('an explicit -j caps the workers instead of being dropped', () {
      // heavy.dart plans from the command as typed (its own default
      // --concurrency is for this machine only), so any -j here is the
      // caller's.
      for (final List<String> j in <List<String>>[
        <String>['-j', '1'],
        <String>['-j1'],
        <String>['-j=1'],
        <String>['--concurrency', '1'],
        <String>['--concurrency=1'],
      ]) {
        expect(
          plan(<String>['test', ...j, 'test/b_test.dart'])!.distArgs,
          <String>[
            '--offload',
            '--busy-retries=$kHeavyOffloadBusyRetries',
            '--concurrency=1',
            'test/b_test.dart',
          ],
          reason: j.join(' '),
        );
      }
      expect(plan(<String>['test', '-j', 'x']), isNull);
      expect(plan(<String>['test', '--concurrency=0']), isNull);
      expect(
        plan(<String>['test', 'test/b_test.dart'])!.distArgs,
        isNot(contains(startsWith('--concurrency'))),
      );
    });

    test('no paths: the whole of test/', () {
      expect(plan(<String>['test', '--no-pub'])!.distArgs, <String>[
        '--offload',
        '--busy-retries=$kHeavyOffloadBusyRetries',
      ]);
    });

    test('value options are sent in --name=value form', () {
      expect(
        plan(<String>[
          'test',
          '--plain-name',
          'testRestore',
          '-x',
          'golden',
          '--tags=slow',
          'test/reader',
        ])!.distArgs,
        <String>[
          '--offload',
          '--busy-retries=$kHeavyOffloadBusyRetries',
          '--plain-name=testRestore',
          '--exclude-tags=golden',
          '--tags=slow',
          'test/reader',
        ],
      );
    });

    test('stays here when it writes files here or cannot be shipped', () {
      for (final List<String> args in <List<String>>[
        <String>['test', '--update-goldens', 'test/b_test.dart'],
        <String>['test', '--coverage', '--merge-coverage'],
        <String>['test', '--coverage=x'],
        <String>['test', '--file-reporter=json:out.json'],
        <String>['test', '--total-shards=2', '--shard-index=0'],
        <String>['test', '--plain-name', 'has space'],
        <String>['test', '--name', r'a$(rm)'],
        <String>['test', 'integration_test/app_test.dart'],
        <String>['test', 'test/missing_test.dart'],
        <String>['test', 'test/../lib/x.dart'],
        <String>['test', '-v'],
      ]) {
        expect(plan(args), isNull, reason: args.join(' '));
      }
    });

    test(
      '--coverage goes out; the merged lcov lands where flutter puts it',
      () {
        expect(
          plan(<String>['test', '--coverage', 'test/b_test.dart'])!.distArgs,
          <String>[
            '--offload',
            '--busy-retries=$kHeavyOffloadBusyRetries',
            '--coverage',
            '--coverage-out=D:/r/fushi/coverage/lcov.info',
            'test/b_test.dart',
          ],
        );
        expect(
          plan(<String>[
            'test',
            '--coverage',
            '--coverage-path',
            r'out\cov.info',
          ])!.distArgs,
          contains('--coverage-out=D:/r/fushi/out/cov.info'),
        );
        expect(
          plan(<String>[
            'test',
            '--coverage',
            '--coverage-path=E:/elsewhere/lcov.info',
          ])!.distArgs,
          contains('--coverage-out=E:/elsewhere/lcov.info'),
        );
      },
    );

    test('only from fushi/ (the app) and only flutter there', () {
      expect(planIn('', <String>[_flutter, 'test']), isNull);
      expect(planIn('fushi/lib', <String>[_flutter, 'test']), isNull);
      expect(
        planIn('fushi', <String>[_dart, 'test', 'test/b_test.dart']),
        isNull,
      );
      expect(
        plan(<String>['build', 'windows']),
        isNull,
        reason: 'no --check-only',
      );
      expect(plan(<String>['drive']), isNull);
    });
  });

  group('package tests', () {
    test('flutter test / dart test from packages/<name> go out with it', () {
      final HeavyOffload? o = planIn('packages/fushi_engine', <String>[
        _dart,
        'test',
        '-j',
        '2',
        'test/reader',
      ]);
      expect(o?.kind, HeavyOffloadKind.test);
      expect(o!.distArgs, <String>[
        '--offload',
        '--busy-retries=$kHeavyOffloadBusyRetries',
        '--package=packages/fushi_engine',
        '--concurrency=2',
        'test/reader',
      ]);
      expect(
        planIn('packages/fushi_dictionary', <String>[
          _flutter,
          'test',
          '--coverage',
        ])!.distArgs,
        <String>[
          '--offload',
          '--busy-retries=$kHeavyOffloadBusyRetries',
          '--package=packages/fushi_dictionary',
          '--coverage',
          '--coverage-out=D:/r/packages/fushi_dictionary/coverage/lcov.info',
        ],
      );
    });

    test('dart test coverage (VM json), other dirs and other verbs stay', () {
      expect(
        planIn('packages/fushi_engine', <String>[
          _dart,
          'test',
          '--coverage=c',
        ]),
        isNull,
      );
      expect(
        planIn('packages/fushi_engine', <String>[_dart, 'test', '--coverage']),
        isNull,
      );
      expect(
        planIn('packages/fushi_engine/test', <String>[_dart, 'test']),
        isNull,
      );
      expect(planIn('packages/Bad', <String>[_dart, 'test']), isNull);
      expect(
        planIn('packages/fushi_engine', <String>[_dart, 'analyze']),
        isNull,
      );
      expect(planIn('tools/x', <String>[_dart, 'test']), isNull);
    });
  });

  group('compile checks (--check-only)', () {
    test('flutter build from fushi/ and gradlew from fushi/android/', () {
      final HeavyOffload? apk = planIn('fushi', <String>[
        _flutter,
        'build',
        'apk',
        '--release',
        '--no-pub',
        '--target-platform',
        'android-arm64',
      ], checkOnly: true);
      expect(apk?.kind, HeavyOffloadKind.build);
      expect(apk!.distArgs, <String>[
        '--build',
        '--',
        'flutter',
        'build',
        'apk',
        '--release',
        '--target-platform=android-arm64',
      ]);
      expect(
        planIn('fushi/android', <String>[
          r'.\gradlew.bat',
          ':app:assembleRelease',
        ], checkOnly: true)!.distArgs,
        <String>['--build', '--', 'gradlew', ':app:assembleRelease'],
      );
    });

    test('without --check-only, or outside the list, a build stays here', () {
      expect(
        planIn('fushi/android', <String>['gradlew', ':app:assembleRelease']),
        isNull,
      );
      for (final List<String> c in <List<String>>[
        <String>[_flutter, 'build', 'ios'],
        <String>[_flutter, 'build', 'macos'],
        <String>[_flutter, 'build', 'apk', '--dart-define=K=V'],
        <String>[_flutter, 'build', 'windows', '-t', 'lib/x.dart'],
      ]) {
        expect(
          planIn('fushi', c, checkOnly: true),
          isNull,
          reason: c.join(' '),
        );
      }
      expect(
        planIn('fushi', <String>[
          'gradlew',
          'assembleRelease',
        ], checkOnly: true),
        isNull,
        reason: 'gradlew runs from fushi/android/',
      );
      expect(
        planIn('fushi/android', <String>['gradlew', 'clean'], checkOnly: true),
        isNull,
      );
    });
  });

  test('where a directory sits in the checkout', () {
    expect(heavyOffloadWhere(r'D:\R\fushi\android', 'd:/r'), 'fushi/android');
    expect(heavyOffloadWhere('D:/r/', 'D:/r'), '');
    expect(heavyOffloadWhere('D:/rx/fushi', 'D:/r'), isNull);
    expect(
      heavyOffloadWhere('/home/a/r/packages/x', '/home/a/r'),
      'packages/x',
    );
    expect(heavyOffloadWhere('/home/a/R/fushi', '/home/a/r'), isNull);
  });

  group('flutter analyze', () {
    test('the app or paths, fatal-* switches kept, paths before them', () {
      expect(plan(<String>['analyze', '--no-pub'])!.distArgs, <String>[
        '--analyze',
      ]);
      final HeavyOffload o = plan(<String>[
        'analyze',
        '--no-fatal-infos',
        r'lib\src\x.dart',
        'tool',
      ])!;
      expect(o.kind, HeavyOffloadKind.analyze);
      expect(o.distArgs, <String>[
        '--analyze',
        'lib/src/x.dart',
        'tool',
        '--no-fatal-infos',
      ]);
    });

    test('stays here for other options or paths', () {
      for (final List<String> args in <List<String>>[
        <String>['analyze', '--watch'],
        <String>['analyze', '--write=out.txt'],
        <String>['analyze', 'android'],
        <String>['analyze', 'lib/missing.dart'],
        <String>['analyze', '../packages/fushi_core'],
      ]) {
        expect(plan(args), isNull, reason: args.join(' '));
      }
    });
  });

  test('config: FUSHI_DIST_CONFIG, else the app\'s workers.local.json', () {
    bool only(String path, String p) => p == path;
    expect(
      heavyOffloadConfig(
        <String, String>{'FUSHI_DIST_CONFIG': 'D:/d/w.json'},
        'D:/r/fushi',
        exists: (String p) => only('D:/d/w.json', p),
      ),
      'D:/d/w.json',
    );
    expect(
      heavyOffloadConfig(
        <String, String>{'FUSHI_DIST_CONFIG': 'D:/d/missing.json'},
        'D:/r/fushi',
        exists: (String p) => p != 'D:/d/missing.json',
      ),
      isNull,
      reason: 'a named config that is gone is not silently replaced',
    );
    expect(
      heavyOffloadConfig(
        const <String, String>{},
        'D:/r/fushi',
        exists: (String p) =>
            only('D:/r/fushi/tool/dist_test/workers.local.json', p),
      ),
      'D:/r/fushi/tool/dist_test/workers.local.json',
    );
    expect(
      heavyOffloadConfig(
        const <String, String>{},
        'D:/r/fushi',
        exists: (String p) => false,
      ),
      isNull,
    );
  });

  test('FUSHI_HEAVY_OFFLOAD=off', () {
    expect(
      heavyOffloadDisabled(<String, String>{'FUSHI_HEAVY_OFFLOAD': 'OFF'}),
      isTrue,
    );
    expect(heavyOffloadDisabled(const <String, String>{}), isFalse);
  });
}
