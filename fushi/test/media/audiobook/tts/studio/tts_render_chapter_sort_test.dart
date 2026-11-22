import 'package:test/test.dart';
import 'package:fushi_engine/tts/tts_direction.dart';

import 'package:fushi/src/media/audiobook/tts/studio/tts_render_chapter_sort.dart';

/// 整书制作一章开合成前的分拣：纯标点句不进合成池、不解析声音、不算失败。
void main() {
  group('sortTtsChapterSentences', () {
    const List<String> texts = <String>[
      'こんにちは。', // 0
      '！', // 1 纯标点
      '……', // 2 纯标点
      '声がない。', // 3 声音解析不到
      'こんにちは。', // 4 与 0 同键
      '♪', // 5 纯标点、声音也解析不到
    ];
    const List<String> keys = <String>['k0', 'k1', 'k2', 'k3', 'k0', 'k5'];
    const Set<int> noVoice = <int>{3, 5};

    TtsChapterSorting<String> sort({
      required List<int> voiceAsked,
      required List<int> directionAsked,
    }) => sortTtsChapterSentences<String>(
      keys: keys,
      planIndices: <int>[for (int i = 0; i < keys.length; i++) i],
      textOf: (int i) => texts[i],
      directionOf: (int i) {
        directionAsked.add(i);
        return TtsDirection(seed: i);
      },
      voiceOf: (int i) {
        voiceAsked.add(i);
        return noVoice.contains(i) ? null : 'voice$i';
      },
      unavailableOf: (int i) => 'unavailable$i',
    );

    test('纯标点句进 silent，不进合成池也不进 failures', () {
      final TtsChapterSorting<String> r = sort(
        voiceAsked: <int>[],
        directionAsked: <int>[],
      );
      expect(r.silent, <String>{'k1', 'k2', 'k5'});
      expect(r.byKey.keys, <String>['k0']);
      expect(r.failures, <String, Object>{'k3': 'unavailable3'});
      for (final String key in r.silent) {
        expect(r.byKey.containsKey(key), isFalse, reason: key);
        expect(r.failures.containsKey(key), isFalse, reason: key);
      }
    });

    test('纯标点句不解析声音：声音缺失也不让它变成未配音', () {
      final List<int> voiceAsked = <int>[];
      final List<int> directionAsked = <int>[];
      sort(voiceAsked: voiceAsked, directionAsked: directionAsked);
      expect(voiceAsked, <int>[0, 3, 4]);
      expect(directionAsked, <int>[0], reason: '同键只取第一次出现的演出参数');
    });

    test('同键多句只合成一次，occurrences 记句数；保持首次出现顺序', () {
      final TtsChapterSorting<String> r = sort(
        voiceAsked: <int>[],
        directionAsked: <int>[],
      );
      expect(r.occurrences, <String, int>{
        'k0': 2,
        'k1': 1,
        'k2': 1,
        'k3': 1,
        'k5': 1,
      });
      final TtsChapterSentence<String> first = r.byKey['k0']!;
      expect(first.text, 'こんにちは。');
      expect(first.voice, 'voice0');
      expect(first.direction.seed, 0);
      // 句数总账：合成池 + 停顿 + 占位 = 本章句数。
      final int total = r.occurrences.values.fold(0, (int a, int b) => a + b);
      expect(total, keys.length);
    });
  });
}
