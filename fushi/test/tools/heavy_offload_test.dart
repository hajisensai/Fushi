// Which heavy commands tool/heavy.dart hands to the other machines
// (tool/test_flow/heavy_offload.dart).

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/heavy_offload.dart';

const String _flutter = r'D:\flutter_sdk\flutter_3.47.6\bin\flutter.bat';

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

  HeavyOffload? plan(List<String> args, {bool inAppDir = true}) =>
      planHeavyOffload(
        <String>[_flutter, ...args],
        inAppDir: inAppDir,
        exists: exists,
      );

  group('flutter test', () {
    test('suites go out; dist_test owns pub, concurrency and reporter', () {
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
        'test/reader/a_test.dart',
        'test/b_test.dart',
      ]);
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
        <String>['test', '--coverage'],
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

    test('only from fushi/ and only flutter', () {
      expect(plan(<String>['test'], inAppDir: false), isNull);
      expect(
        planHeavyOffload(
          <String>['dart', 'test', 'test/b_test.dart'],
          inAppDir: true,
          exists: exists,
        ),
        isNull,
      );
      expect(plan(<String>['build', 'windows']), isNull);
      expect(plan(<String>['drive']), isNull);
    });
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
