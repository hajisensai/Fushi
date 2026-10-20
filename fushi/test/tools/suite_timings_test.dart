import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/suite_timings.dart';

void main() {
  group('suiteDurationsFromEvents', () {
    Map<String, Object?> suite(int id, String path) => <String, Object?>{
      'type': 'suite',
      'suite': <String, Object?>{'id': id, 'platform': 'vm', 'path': path},
      'time': 0,
    };
    Map<String, Object?> start(
      int id,
      int suiteId,
      int time,
    ) => <String, Object?>{
      'type': 'testStart',
      'test': <String, Object?>{'id': id, 'suiteID': suiteId, 'name': 't$id'},
      'time': time,
    };
    Map<String, Object?> done(int id, int time) => <String, Object?>{
      'type': 'testDone',
      'testID': id,
      'result': 'success',
      'time': time,
    };

    const Set<String> known = <String>{
      'test/a_test.dart',
      'test/sub/b_test.dart',
      'test/tools/test_c_test.dart',
    };

    test(
      'spans the first testStart (loading included) to the last testDone',
      () {
        final Map<String, int> durations = suiteDurationsFromEvents(
          <Map<String, Object?>>[
            suite(0, 'test/a_test.dart'),
            start(1, 0, 100), // hidden "loading" test
            done(1, 900),
            start(2, 0, 900),
            start(3, 0, 950),
            done(3, 2400),
            done(2, 1800),
          ],
          known,
        );
        expect(durations, <String, int>{'test/a_test.dart': 2300});
      },
    );

    test(
      'maps absolute, Windows-faster-testing and relative paths by suffix',
      () {
        final Map<String, int>
        durations = suiteDurationsFromEvents(<Map<String, Object?>>[
          suite(0, '/home/runner/work/Fushi/Fushi/fushi/test/sub/b_test.dart'),
          suite(1, r'/D:\work\fushi\test\a_test.dart'),
          // The first "test/" segment is fushi/test, not a later one.
          suite(2, '/w/fushi/test/tools/test_c_test.dart'),
          suite(3, 'test/not_in_tree_test.dart'),
          start(10, 0, 0),
          done(10, 10),
          start(11, 1, 0),
          done(11, 20),
          start(12, 2, 0),
          done(12, 30),
          start(13, 3, 0),
          done(13, 40),
        ], known);
        expect(durations, <String, int>{
          'test/sub/b_test.dart': 10,
          'test/a_test.dart': 20,
          'test/tools/test_c_test.dart': 30,
        });
      },
    );

    test('IDs restart per run when batches share one log', () {
      final Map<String, int> durations = suiteDurationsFromEvents(
        <Map<String, Object?>>[
          <String, Object?>{'type': 'start', 'time': 0},
          suite(0, 'test/a_test.dart'),
          start(1, 0, 0),
          done(1, 500),
          <String, Object?>{'type': 'start', 'time': 0},
          suite(0, 'test/sub/b_test.dart'),
          start(1, 0, 100),
          done(1, 400),
        ],
        known,
      );
      expect(durations, <String, int>{
        'test/a_test.dart': 500,
        'test/sub/b_test.dart': 300,
      });
    });

    test('a suite that never finished is not reported', () {
      final Map<String, int> durations = suiteDurationsFromEvents(
        <Map<String, Object?>>[suite(0, 'test/a_test.dart'), start(1, 0, 100)],
        known,
      );
      expect(durations, isEmpty);
    });
  });

  group('suiteShardWeights', () {
    test('without timings it is the byte-size proxy', () {
      expect(
        suiteShardWeights(<String, int>{
          'test/a_test.dart': 1000,
        }, <String, int>{}),
        <String, int>{'test/a_test.dart': 1000 + kPerSuiteByteWeight},
      );
    });

    test(
      'measured suites use their time; new ones scale by the median rate',
      () {
        // Size weight = bytes + kPerSuiteByteWeight: 5000 for the small suites,
        // 14000 for the new one.
        const int small = 5000 - kPerSuiteByteWeight;
        const int large = 14000 - kPerSuiteByteWeight;
        final Map<String, int> weights = suiteShardWeights(
          <String, int>{
            'test/a_test.dart': small,
            'test/b_test.dart': small,
            'test/slow_test.dart': small,
            'test/new_test.dart': large,
          },
          <String, int>{
            'test/a_test.dart': 5000, // 1 ms per weight unit
            'test/b_test.dart': 5000,
            'test/slow_test.dart': 600000, // a Chrome suite: must not skew it
            'test/deleted_test.dart': 99999, // not on disk: ignored
          },
        );
        expect(weights, <String, int>{
          'test/a_test.dart': 5000,
          'test/b_test.dart': 5000,
          'test/slow_test.dart': 600000,
          'test/new_test.dart': 14000,
        });
      },
    );
  });

  test('roundSuiteTiming keeps a measured suite above zero', () {
    expect(roundSuiteTiming(0), kSuiteTimingResolutionMs);
    expect(roundSuiteTiming(149), 100);
    expect(roundSuiteTiming(1250), 1300);
  });

  test('the table round-trips through write/read', () {
    final Directory dir = Directory.systemTemp.createTempSync('suite_timings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File file = File('${dir.path}/suite_timings.json');
    expect(readSuiteTimings(file), isEmpty);
    final Map<String, int> timings = <String, int>{
      'test/b_test.dart': 300,
      'test/a_test.dart': 1200,
    };
    writeSuiteTimings(file, timings);
    expect(readSuiteTimings(file), timings);
    expect(
      file.readAsStringSync(),
      startsWith('{\n  "suites": {\n    "test/a_test.dart": 1200,\n'),
    );
  });

  test('the checked-in table parses and only names suites under test/', () {
    final Map<String, int> timings = readSuiteTimings(File(kSuiteTimingsPath));
    for (final MapEntry<String, int> e in timings.entries) {
      expect(e.key, startsWith('test/'));
      expect(e.key, endsWith('_test.dart'));
      expect(e.value, greaterThan(0), reason: e.key);
    }
  });
}
