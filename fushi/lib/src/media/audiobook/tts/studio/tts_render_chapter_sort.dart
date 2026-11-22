/// 整书制作一章开合成前的分拣（纯函数，`_synthesizeChapter` 用，单测直接覆盖）。
///
/// 一章的句子按缓存键（同文同声 = 同键）去重后分三类：
/// - **纯标点 / 符号句**（[ttsTextIsSilent]，「！」「……」）：进 `silent`，不解析声音、
///   不进合成池，由调用方放一段停顿；它没有要念的内容，不算失败、不进账本；
/// - **声音解析不到**的句子：进 `failures`（键 → [unavailableOf] 给的失败），占位记账；
/// - 其余进 `byKey`（保持首次出现顺序），带上要念的文字、声音与演出参数。
///
/// `occurrences` 是每个键在本章出现的次数（进度按句数记，同键多句一次合成）。
library;

import 'dart:collection';

import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:fushi_engine/tts/tts_silence.dart';

/// 一个要送合成池的键。
typedef TtsChapterSentence<V> = ({
  String text,
  V voice,
  TtsDirection direction,
});

/// [sortTtsChapterSentences] 的结果。
typedef TtsChapterSorting<V> = ({
  LinkedHashMap<String, TtsChapterSentence<V>> byKey,
  Map<String, int> occurrences,
  Map<String, Object> failures,
  Set<String> silent,
});

/// 分拣一章：[keys] 与 [planIndices] 一一对应（第 k 句的缓存键与全书句序号）。
///
/// [voiceOf] 返回 null = 这句的声音解析不到，此时取 [unavailableOf] 作失败原因。
/// 纯标点句不调用 [voiceOf] / [directionOf]：它不需要声音，声音缺失也不该让它失败。
TtsChapterSorting<V> sortTtsChapterSentences<V extends Object>({
  required List<String> keys,
  required List<int> planIndices,
  required String Function(int planIndex) textOf,
  required TtsDirection Function(int planIndex) directionOf,
  required V? Function(int planIndex) voiceOf,
  required Object Function(int planIndex) unavailableOf,
}) {
  assert(keys.length == planIndices.length);
  final LinkedHashMap<String, TtsChapterSentence<V>> byKey =
      LinkedHashMap<String, TtsChapterSentence<V>>();
  final Map<String, int> occurrences = <String, int>{};
  final Map<String, Object> failures = <String, Object>{};
  final Set<String> silent = <String>{};
  for (int k = 0; k < keys.length; k++) {
    final String key = keys[k];
    final int planIndex = planIndices[k];
    occurrences[key] = (occurrences[key] ?? 0) + 1;
    final String text = textOf(planIndex);
    if (ttsTextIsSilent(text)) {
      silent.add(key);
      continue;
    }
    final V? voice = voiceOf(planIndex);
    if (voice == null) {
      failures[key] = unavailableOf(planIndex);
      continue;
    }
    byKey.putIfAbsent(
      key,
      () => (text: text, voice: voice, direction: directionOf(planIndex)),
    );
  }
  return (
    byKey: byKey,
    occurrences: occurrences,
    failures: failures,
    silent: silent,
  );
}
