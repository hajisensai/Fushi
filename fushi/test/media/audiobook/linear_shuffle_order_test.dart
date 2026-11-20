import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/linear_shuffle_order.dart';
import 'package:just_audio/just_audio.dart';

/// BUG-4957：TTS 朗读每句一个源，长篇十几万句；just_audio 默认 ShuffleOrder
/// 逐个随机 `List.insert`，构造播放列表 O(n²) 把主线程占到 ANR。
void main() {
  group('LinearShuffleOrder', () {
    test('insert(0, n) 到空表得到 0..n-1 的一个排列', () {
      final LinearShuffleOrder order = LinearShuffleOrder(random: Random(1));
      order.insert(0, 1000);
      expect(order.indices.length, 1000);
      expect(
        order.indices.toSet(),
        Set<int>.of(List<int>.generate(1000, (int i) => i)),
      );
    });

    test('中间插入：原下标后移、保持相对顺序，新下标全部出现', () {
      final LinearShuffleOrder order = LinearShuffleOrder(random: Random(2));
      order.insert(0, 5);
      final List<int> before = List<int>.of(order.indices);
      order.insert(2, 3);
      final List<int> after = order.indices;
      expect(after.length, 8);
      final List<int> oldMapped = <int>[
        for (final int v in before) v >= 2 ? v + 3 : v,
      ];
      final List<int> oldInAfter = after
          .where((int v) => !<int>{2, 3, 4}.contains(v))
          .toList();
      expect(oldInAfter, oldMapped);
      expect(after.where(<int>{2, 3, 4}.contains).toSet(), <int>{2, 3, 4});
    });

    test('removeRange 去掉区间并把后面的下标前移', () {
      final LinearShuffleOrder order = LinearShuffleOrder(random: Random(3));
      order.insert(0, 10);
      final List<int> before = List<int>.of(order.indices);
      order.removeRange(3, 6);
      expect(order.indices, <int>[
        for (final int v in before)
          if (v < 3 || v >= 6) v >= 6 ? v - 3 : v,
      ]);
      order.clear();
      expect(order.indices, isEmpty);
    });

    test('shuffle 把 initialIndex 放到队首且仍是排列', () {
      final LinearShuffleOrder order = LinearShuffleOrder(random: Random(4));
      order.insert(0, 50);
      order.shuffle(initialIndex: 37);
      expect(order.indices.first, 37);
      expect(order.indices.toSet().length, 50);
    });

    test('二十万句一次插入是线性的（默认实现逐个 List.insert 要算十几秒）', () {
      // 计算是同步的，test 的 Timeout 打断不了它，只能量耗时。线性实现在慢机上
      // 也只要几十毫秒；逐个随机 insert 的 O(n²) 实现本机实测约 20 秒。
      final LinearShuffleOrder order = LinearShuffleOrder(random: Random(5));
      final Stopwatch sw = Stopwatch()..start();
      order.insert(0, 200000);
      order.insert(100000, 1000);
      sw.stop();
      expect(order.indices.length, 201000);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('concatenateAudiobookSources 保留全部子源', () {
      final List<AudioSource> children = <AudioSource>[
        for (int i = 0; i < 3; i++)
          AudioSource.uri(Uri.parse('file:///a$i.mp3')),
      ];
      final ConcatenatingAudioSource source = concatenateAudiobookSources(
        children,
      );
      expect(source.children, children);
      expect(source.shuffleIndices.toSet(), <int>{0, 1, 2});
    });
  });

  test(
    'lib/ 里只有 concatenateAudiobookSources 一处直接构造 ConcatenatingAudioSource',
    () {
      final List<String> offenders = <String>[];
      for (final FileSystemEntity e in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final String norm = e.path.replaceAll(r'\', '/');
        if (norm.endsWith('media/audiobook/linear_shuffle_order.dart')) {
          continue;
        }
        final String src = e.readAsStringSync();
        if (RegExp(r'(?<![\w\[])ConcatenatingAudioSource\(').hasMatch(src)) {
          offenders.add(norm);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '用 concatenateAudiobookSources（O(n) 的 LinearShuffleOrder），'
            'just_audio 默认 ShuffleOrder 构造时 O(n²)（BUG-4957）',
      );
    },
  );
}
