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
import 'package:fushi_anki/fushi_anki_core.dart'
    show
        FushiCardBlock,
        FushiCardBlockItem,
        FushiCardFieldItem,
        FushiCardFrontBlock,
        FushiCardHtmlItem,
        FushiCardItem,
        kFushiCardDefaultBackItems,
        kFushiCardDefaultFrontItems,
        kFushiOptAudio;

import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsAudioSources, srsFieldFilled, srsVideoSources;
import 'package:fushi/src/srs/srs_fushi_card_media.dart';

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

/// 布局项 [item] 在这张卡上画不画得出来：内置区块按 [srsFushiBlockVisible]（正面区块按
/// 模板条件段：词频序位 / 提示有内容才有），字段区块按字段有没有内容（模板 `{{#字段}}`
/// 同义），HTML 区块按展开后有没有内容。
bool srsFushiItemVisible(
  FushiCardItem item,
  Map<String, String> fields,
  SrsCardAppearance a,
) => switch (item) {
  FushiCardBlockItem(:final FushiCardBlock block) => srsFushiBlockVisible(
    block,
    fields,
    a,
  ),
  FushiCardBlockItem(block: FushiCardFrontBlock.frequency) =>
    a.frontFrequency && srsFieldFilled(fields['FrequencyRank']),
  FushiCardBlockItem(block: FushiCardFrontBlock.hint) => srsFieldFilled(
    fields['Hint'],
  ),
  FushiCardBlockItem() => true,
  FushiCardFieldItem(:final String field) => srsFieldFilled(fields[field]),
  FushiCardHtmlItem(:final String html) => html.trim().isNotEmpty,
};

/// 一张原生卡的「画什么 + 画出来的会出什么声」。
@immutable
class SrsFushiCardPlan {
  const SrsFushiCardPlan({
    required this.frontKind,
    required this.visible,
    required this.media,
    this.front = const <FushiCardItem>[],
    this.back = const <FushiCardItem>[],
  });

  /// 正面卡型。
  final SrsFushiFrontKind frontKind;

  /// 背面会画出来的内置区块。
  final Set<FushiCardBlock> visible;

  /// 正面画出来的布局项，自上而下（模板区块布局的顺序，只含画得出来的）。
  final List<FushiCardItem> front;

  /// 背面画出来的布局项，自上而下（模板区块布局的顺序，只含画得出来的）。
  final List<FushiCardItem> back;

  /// 只来自画出来的区块的媒体：读音行的单词音频（读音区块可见且没关发音键）、图片区里的
  /// 视频片段（图片区可见时）、例句区的例句音频（例句区可见且没关发音键）。听力卡正面那颗
  /// 发音键见 [SrsFushiCardMedia.front]（正面有题面区块时）。
  final SrsFushiCardMedia media;

  bool shows(FushiCardBlock block) => visible.contains(block);

  /// 背面内置区块 [block] 的布局项（带选项）；不在布局里为 null。
  FushiCardBlockItem? itemOf(Enum block) {
    for (final FushiCardItem x in <FushiCardItem>[...back, ...front]) {
      if (x is FushiCardBlockItem && x.block == block) return x;
    }
    return null;
  }

  /// 正面画不画内置区块 [block]。
  bool showsFront(FushiCardFrontBlock block) => front.any(
    (FushiCardItem x) => x is FushiCardBlockItem && x.block == block,
  );
}

/// 从笔记字段（按字段名）、外观与正背面区块布局（[front] / [back]，模板里的布局；见
/// `fushiCardLayoutOf`）算出原生 Fushi 卡面的唯一计划（卡面绘制、自动播放、底栏重播、R 重播
/// 共用）。
SrsFushiCardPlan srsFushiCardPlan(
  Map<String, String> fields,
  SrsCardAppearance appearance, {
  List<FushiCardItem>? front,
  List<FushiCardItem>? back,
}) {
  final SrsFushiFrontKind kind = srsFushiFrontKind(fields);
  final Set<Enum> seen = <Enum>{};
  List<FushiCardItem> shown(List<FushiCardItem> items) => <FushiCardItem>[
    for (final FushiCardItem x in items)
      // 同一个内置区块只画一次（模板里重复的那段在读出布局时已当成 HTML 区块）。
      if ((x is! FushiCardBlockItem || seen.add(x.block)) &&
          srsFushiItemVisible(x, fields, appearance))
        x,
  ];
  final List<FushiCardItem> backItems = shown(
    back ?? kFushiCardDefaultBackItems,
  );
  final List<FushiCardItem> frontItems = shown(
    front ?? kFushiCardDefaultFrontItems,
  );
  final Set<FushiCardBlock> visible = <FushiCardBlock>{
    for (final FushiCardItem x in backItems)
      if (x case FushiCardBlockItem(:final FushiCardBlock block)) block,
  };
  FushiCardBlockItem? item(FushiCardBlock b) => backItems
      .whereType<FushiCardBlockItem>()
      .where((FushiCardBlockItem x) => x.block == b)
      .firstOrNull;
  // 单词音频画在读音行（模板里 TermAudio 属读音区块）：布局里删掉读音区块、或关了它的
  // 发音键，就没有它。
  final List<String> word =
      item(FushiCardBlock.reading)?.flag(kFushiOptAudio) ?? false
      ? srsAudioSources(fields['TermAudio'] ?? '')
      : const <String>[];
  // 片段只在图片区画出来时才存在：关了「显示图片」= 卡面上没有片段，也不出声。
  final String? clip = visible.contains(FushiCardBlock.picture)
      ? srsVideoSources(fields['Media'] ?? '').firstOrNull
      : null;
  // 例句发音键画在例句块里：例句为空不画例句块、关了它的发音键，也就没有例句音频。
  final List<String> sentence =
      item(FushiCardBlock.sentence)?.flag(kFushiOptAudio) ?? false
      ? srsAudioSources(fields['SentenceAudio'] ?? '')
      : const <String>[];
  // 听力卡正面放一颗发音键（正面有题面区块时）：有例句音频播例句，否则播单词音频，与模板
  // `{{#SentenceAudio}}` 同义。正面的遮罩例句不受背面区块显隐影响，按字段取。
  final List<String> rawSentence = srsAudioSources(
    fields['SentenceAudio'] ?? '',
  );
  final List<String> rawWord = srsAudioSources(fields['TermAudio'] ?? '');
  final bool prompt = frontItems.any(
    (FushiCardItem x) =>
        x is FushiCardBlockItem && x.block == FushiCardFrontBlock.prompt,
  );
  final List<String> frontAudio = kind != SrsFushiFrontKind.audio || !prompt
      ? const <String>[]
      : <String>[?(rawSentence.firstOrNull ?? rawWord.firstOrNull)];
  return SrsFushiCardPlan(
    frontKind: kind,
    visible: visible,
    front: List<FushiCardItem>.unmodifiable(frontItems),
    back: List<FushiCardItem>.unmodifiable(backItems),
    media: SrsFushiCardMedia(
      front: frontAudio,
      word: word,
      clip: clip,
      sentence: sentence,
    ),
  );
}
