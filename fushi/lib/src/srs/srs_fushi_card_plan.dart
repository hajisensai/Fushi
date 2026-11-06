/// 原生「Fushi 卡片」卡面的唯一派生模型：这张卡**画哪些区块**、画出来的区块里**有哪些会出声的
/// 媒体**（HrB0STYm3E）。
///
/// 以前两份判据各管各的：卡面绘制按 [srsFushiBlockVisible]（外观开关 + 字段有没有内容），
/// 复习页的自动播放 / 底栏重播 / R 重播按字段直接取全部音频（`srsFushiCardMedia`）——关掉
/// 「显示图片」后片段不画了却照样出声，例句为空时没有例句块、例句音频照样被自动播放。现在
/// 卡面（`SrsFushiCardView`）与复习页（`_mediaOf`）都从同一份 [SrsFushiCardPlan] 取：卡面上画
/// 不出来的东西，任何一条播放路径都拿不到。
library;

import 'package:flutter/foundation.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show FushiCardBlock;

import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart' show SrsFushiCardMedia;
import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsAudioSources, srsFieldFilled, srsVideoSources;

/// 区块的原生可见性（外观开关 + 字段是否有内容），与模板条件段同一判据。
bool srsFushiBlockVisible(
  FushiCardBlock block,
  Map<String, String> fields,
  SrsCardAppearance a,
) {
  bool any(List<String> names) =>
      names.any((String n) => srsFieldFilled(fields[n]));
  return switch (block) {
    FushiCardBlock.term => true,
    FushiCardBlock.reading => any(block.fields) || any(<String>['Term']),
    FushiCardBlock.picture => a.showPicture && any(block.fields),
    FushiCardBlock.sentence => srsFieldFilled(fields['Sentence']),
    FushiCardBlock.definitions => any(block.fields),
    // 跟随查词的「词频聚合」：聚合且有平均值（FreqSort）时只在读音行显示平均值，
    // 不出明细区；否则出按词典合并的明细区。两者永不同时出现（模板同一规则）。
    FushiCardBlock.frequency =>
      a.showFrequency &&
          any(block.fields) &&
          !(a.aggregateFrequency && srsFieldFilled(fields['FrequencyRank'])),
    FushiCardBlock.source => a.showSource && any(block.fields),
  };
}

/// 卡型（正面）：与模板的 Lapis 卡型开关同一语义，都空 = 单词卡。
enum SrsFushiFrontKind { word, sentence, wordAndSentence, click, audio }

SrsFushiFrontKind srsFushiFrontKind(Map<String, String> f) {
  if (srsFieldFilled(f['IsSentenceCard'])) return SrsFushiFrontKind.sentence;
  if (srsFieldFilled(f['IsWordAndSentenceCard'])) {
    return SrsFushiFrontKind.wordAndSentence;
  }
  if (srsFieldFilled(f['IsClickCard'])) return SrsFushiFrontKind.click;
  if (srsFieldFilled(f['IsAudioCard'])) return SrsFushiFrontKind.audio;
  return SrsFushiFrontKind.word;
}

/// 一张原生卡的「画什么 + 画出来的会出什么声」。
@immutable
class SrsFushiCardPlan {
  const SrsFushiCardPlan({
    required this.frontKind,
    required this.visible,
    required this.media,
    this.order = FushiCardBlock.values,
  });

  /// 正面卡型。
  final SrsFushiFrontKind frontKind;

  /// 背面会画出来的区块。
  final Set<FushiCardBlock> visible;

  /// 背面画出来的区块，自上而下（模板区块布局里的顺序，只含 [visible]）。
  final List<FushiCardBlock> order;

  /// 只来自 [visible] 区块的媒体：词条区的单词音频、图片区里的视频片段（图片区可见时）、
  /// 例句区的例句音频（例句区可见时）。听力卡正面那颗发音键见 [SrsFushiCardMedia.front]。
  final SrsFushiCardMedia media;

  bool shows(FushiCardBlock block) => visible.contains(block);
}

/// 从笔记字段（按字段名）、外观与背面区块布局（[blocks]，模板里的区块顺序，删掉的区块不在
/// 里面；见 `fushiCardBackLayoutOf`）算出原生 Fushi 卡面的唯一计划（卡面绘制、自动播放、
/// 底栏重播、R 重播共用）。
SrsFushiCardPlan srsFushiCardPlan(
  Map<String, String> fields,
  SrsCardAppearance appearance, {
  List<FushiCardBlock> blocks = FushiCardBlock.values,
}) {
  final SrsFushiFrontKind kind = srsFushiFrontKind(fields);
  final List<FushiCardBlock> order = <FushiCardBlock>[
    for (final FushiCardBlock b in blocks.toSet())
      if (srsFushiBlockVisible(b, fields, appearance)) b,
  ];
  final Set<FushiCardBlock> visible = order.toSet();
  // 单词音频画在读音行（模板里 TermAudio 属读音区块）：布局里删掉读音区块就没有它。
  final List<String> word = visible.contains(FushiCardBlock.reading)
      ? srsAudioSources(fields['TermAudio'] ?? '')
      : const <String>[];
  // 片段只在图片区画出来时才存在：关了「显示图片」= 卡面上没有片段，也不出声。
  final String? clip = visible.contains(FushiCardBlock.picture)
      ? srsVideoSources(fields['Media'] ?? '').firstOrNull
      : null;
  // 例句发音键画在例句块里：例句为空不画例句块，也就没有例句音频。
  final List<String> sentence = visible.contains(FushiCardBlock.sentence)
      ? srsAudioSources(fields['SentenceAudio'] ?? '')
      : const <String>[];
  // 听力卡正面放一颗发音键（正面总是画它）：有例句音频播例句，否则播单词音频，与模板
  // `{{#SentenceAudio}}` 同义。正面的遮罩例句不受背面区块显隐影响，按字段取。
  final List<String> rawSentence = srsAudioSources(
    fields['SentenceAudio'] ?? '',
  );
  final List<String> front = kind != SrsFushiFrontKind.audio
      ? const <String>[]
      : <String>[?(rawSentence.firstOrNull ?? word.firstOrNull)];
  return SrsFushiCardPlan(
    frontKind: kind,
    visible: visible,
    order: List<FushiCardBlock>.unmodifiable(order),
    media: SrsFushiCardMedia(
      front: front,
      word: word,
      clip: clip,
      sentence: sentence,
    ),
  );
}
