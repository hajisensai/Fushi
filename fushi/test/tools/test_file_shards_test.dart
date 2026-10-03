import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/test_flow/test_file_shards.dart';

void main() {
  group('TestFileShard.tryParse', () {
    test('accepts <index>/<total> with a 0-based index', () {
      final TestFileShard? shard = TestFileShard.tryParse('2/4');
      expect(shard?.index, 2);
      expect(shard?.total, 4);
    });

    test('rejects malformed or out-of-range values', () {
      for (final String raw in <String>[
        '4/4',
        '-1/4',
        '1/0',
        '1',
        'a/b',
        '1/2/3'
      ]) {
        expect(TestFileShard.tryParse(raw), isNull, reason: raw);
      }
    });
  });

  group('selectTestFileShard', () {
    Map<String, int> weights(int count) => <String, int>{
          for (int i = 0; i < count; i++)
            'test/f${i.toString().padLeft(3, '0')}_test.dart':
                (i * 37) % 101 + 1,
        };

    test('every file lands in exactly one shard (union = whole suite)', () {
      final Map<String, int> files = weights(250);
      for (final int total in <int>[1, 2, 4, 7]) {
        final List<String> all = <String>[
          for (int i = 0; i < total; i++)
            ...selectTestFileShard(files, TestFileShard(i, total)),
        ];
        expect(all.length, files.length, reason: 'total=$total');
        expect(all.toSet(), files.keys.toSet(), reason: 'total=$total');
      }
    });

    test('is deterministic regardless of map insertion order', () {
      final Map<String, int> files = weights(120);
      final Map<String, int> reversed =
          Map<String, int>.fromEntries(files.entries.toList().reversed);
      for (int i = 0; i < 4; i++) {
        expect(selectTestFileShard(reversed, TestFileShard(i, 4)),
            selectTestFileShard(files, TestFileShard(i, 4)));
      }
    });

    test('balances weight across shards', () {
      final Map<String, int> files = weights(400);
      final List<int> loads = <int>[
        for (int i = 0; i < 4; i++)
          selectTestFileShard(files, TestFileShard(i, 4))
              .fold<int>(0, (int sum, String p) => sum + files[p]!),
      ];
      final int heaviestFile =
          files.values.reduce((int a, int b) => a > b ? a : b);
      final int spread = loads.reduce((int a, int b) => a > b ? a : b) -
          loads.reduce((int a, int b) => a < b ? a : b);
      expect(spread, lessThanOrEqualTo(heaviestFile), reason: '$loads');
    });

    test('partitions the real test/ tree with no shard left empty', () {
      final Map<String, int> files = <String, int>{
        for (final FileSystemEntity e
            in Directory('test').listSync(recursive: true, followLinks: false))
          if (e is File && e.path.endsWith('_test.dart'))
            e.path: e.lengthSync(),
      };
      expect(files.length, greaterThan(1000));
      int covered = 0;
      for (int i = 0; i < 4; i++) {
        final List<String> shard =
            selectTestFileShard(files, TestFileShard(i, 4));
        expect(shard, isNotEmpty);
        covered += shard.length;
      }
      expect(covered, files.length);
    });
  });
}
