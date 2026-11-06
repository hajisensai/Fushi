/// 原生 Fushi 卡面上会出声的媒体清单（纯值类型 + 去重），与播放出口分开放。
///
/// 这里不碰 provider / 播放器：卡面计划（srs_fushi_card_plan.dart）只要这份清单，若跟播放出口
/// （srs_card_autoplay.dart，经 srs_providers 连到 AppModel）放在一个文件，纯逻辑的卡面计划会被
/// 一并拖进 AppModel 的 import 环（见 test/build/import_cycle_guard_test.dart）。
library;

import 'package:flutter/foundation.dart' show immutable;

/// 按出现顺序去重（同一个文件在一面卡上只算一段）。
///
/// 模板把同一音频字段渲染多份（Lapis 背面把 `{{Picture}}` / 音频容器复制进好几处，由 CSS
/// 只显示一处）时，`[sound:x]` 在 HTML 里出现好几次——以前每次都出一颗底部重播键、自动播放
/// 把同一段连播好几遍（#15：一句例句的语法卡出了 🔊1…🔊5）。
List<String> srsDedupeMediaNames(Iterable<String> names) {
  final Set<String> seen = <String>{};
  return <String>[
    for (final String n in names)
      if (n.isNotEmpty && seen.add(n)) n,
  ];
}

/// 原生 Fushi 卡面上**实际画出来**的媒体（按字段，不扫整面 HTML）。只由
/// `srsFushiCardPlan`（srs_fushi_card_plan.dart）构造：那里按区块显隐过滤，卡面上没画的区块
/// 里的媒体不进来（HrB0STYm3E：关了「显示图片」片段照样出声、例句为空例句音频照样自动播）。
///
/// 原生卡面只画三样会出声的东西：词条旁的单词音频键（`ExpressionAudio`）、Picture 里的视频
/// 片段、例句卡里的例句音频键（`SentenceAudio`）。以前复习页按整张背面 HTML 收集媒体
/// （srs_card_autoplay.dart 的 `srsCardMediaNames`）——释义区里词典自带的 `<audio>` / `[sound:]`、模板复制的多份
/// 容器都被算进来，于是卡面上只有一两颗发音键、底栏却出一排重播键，自动播放也把它们全播
/// 了（#15）。底栏重播键、自动播放、R 重播与卡面上的发音键现在是同一份清单。
@immutable
class SrsFushiCardMedia {
  const SrsFushiCardMedia({
    required this.front,
    required this.word,
    required this.clip,
    required this.sentence,
  });

  /// 问题面会出声的媒体（只有听力卡正面有发音键，见 `_buildFront`）。
  final List<String> front;

  /// 单词音频（`ExpressionAudio`）。
  final List<String> word;

  /// Picture 里的视频片段（第一个）；没有 = null。
  final String? clip;

  /// 例句音频（`SentenceAudio`）。
  final List<String> sentence;

  /// 片段自带例句声音：例句音频就是片段本身（视频制卡的同步片段，`SentenceAudio` 里的隐藏
  /// `<audio>` 与 `<video>` 是同一个文件），或卡上只有片段没有单独的例句音频。此时例句键
  /// 控制片段（在画面上从头播、有声），不再另起一路纯音频（#10：二者重复、叠音）。
  bool get clipCarriesSentence {
    final String? c = clip;
    return c != null && (sentence.isEmpty || sentence.contains(c));
  }

  /// 例句发音键播什么：片段带声 → 片段；否则例句音频（画面上的动图 / 静音片段经片段通道
  /// 跟着从头播，见 `SrsCardVideoChannel.setSentenceAudio`）。
  List<String> get sentenceUnit =>
      clipCarriesSentence ? <String>[clip!] : sentence;

  /// 只作「画面陪播」的例句音频（片段不带这段声音时）：播它们时画面从头播、片段静音。
  List<String> get companionSentence =>
      clipCarriesSentence ? const <String>[] : sentence;

  /// 答案面的全部媒体（顺序与卡面从上到下一致：单词 → 例句 / 片段）。片段不带例句声音
  /// 时它只陪播画面（静音），不单独进序列——否则例句音频之后片段再出一遍声。
  List<String> get back =>
      srsDedupeMediaNames(<String>[...word, ...sentenceUnit]);
}
