import 'package:characters/characters.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 字幕句分词的纯逻辑层（无 Flutter / 无页面状态，可直接单测）。
///
/// 回答一个问题：一句话怎么切成词、每个词覆盖哪段 grapheme。消费方是统一手柄查词
/// 模式的按词步进（`controller_lookup_steps.dart`，视频 / 歌词 / 漫画同一分词）。
/// 曾经的视频「整句扫词」动作已在 2026-11-22 手柄查词统一中删除
/// （docs/specs/2026-11-22-gamepad-lookup-unification-design.md），名字里的 sweep
/// 是历史沿用。

/// 一个扫词单元：词本身 + 它在整句 **grapheme 序列**里覆盖的区间
/// `[graphemeStart, graphemeEnd)`。
///
/// 下标是 grapheme（不是 UTF-16 码元）：字幕登记表 / `_handleSubtitleLookupTap` /
/// `SubtitleCharHit.graphemeIndex` 全部按 grapheme 计数（见
/// `subtitle_transcript_text.dart` 里的 `sentence.characters`），而
/// [JapaneseLanguage.textToWords] 按 UTF-16 码元切分。二者只在纯汉字 / 假名下相等，
/// 带组合字符 / emoji / 代理对就会错位，故这里统一折算回 grapheme——**不照抄**
/// `texthooker_page.dart` 的 `_indexedWordRows`（那份算的是 UTF-16 偏移）。
class SubtitleSweepToken {
  const SubtitleSweepToken({
    required this.graphemeStart,
    required this.graphemeEnd,
    required this.word,
  });

  /// 词首字在整句 grapheme 序列里的下标。
  final int graphemeStart;

  /// 词覆盖区间的右端（不含）。恒 `> graphemeStart`。
  final int graphemeEnd;

  /// 词本身（与词典引擎在该位置的最长匹配一致；落在同一 grapheme 内的分词碎片已
  /// 合并进来，见 [buildSubtitleSweepTokens]）。
  final String word;

  @override
  String toString() =>
      'SubtitleSweepToken($graphemeStart..$graphemeEnd, "$word")';
}

/// 分词器签名：把一句话切成按序排列、拼接回即原文的词。
///
/// 默认实现是引擎最长匹配 [JapaneseLanguage.textToWords]；只有单测需要注入确定性
/// 输入时才传别的（真机 / 生产一律走默认）。
typedef SubtitleSweepTokenizer = List<String> Function(String text);

/// 把暂停句切成扫词单元。
///
/// 复用 [JapaneseLanguage.textToWords] 的**切分不变式**（各片段按序拼回即原文，见
/// `texthooker_page.dart` 的同名注释）：每个片段的 UTF-16 起点 = 前面片段长度之和。
/// 再把这个**码元偏移**映射到 grapheme 下标——绝不按「每个词前进几个 grapheme」去
/// 累加，因为分词器未命中时按 UTF-16 码元逐个切（`text[pos]`），代理对 / 组合字符会被
/// 劈成半个 grapheme 的碎片；按碎片个数累加会让之后每个词的下标整体错位（BUG-3086）。
///
/// 起点落在某个 grapheme **中间**的碎片（代理对后半、组合浊点等）不另成一词，而是
/// 并入前一个词：它和前一个词共享同一个 grapheme，单独成词既查不到东西、又会让
/// 游标在同一个字上停两次。空片段直接丢弃。
///
/// 空句返回空表；引擎未就绪时 [JapaneseLanguage.textToWords] 退化为逐码元，本函数
/// 照常产出（只是粒度变细），不抛异常。分词结果违反不变式（拼起来比原文长）时，超出
/// 原文的部分被忽略。
List<SubtitleSweepToken> buildSubtitleSweepTokens(
  String sentence, {
  SubtitleSweepTokenizer? tokenize,
}) {
  if (sentence.isEmpty) return const <SubtitleSweepToken>[];
  final List<String> words =
      (tokenize ?? JapaneseLanguage.instance.textToWords)(sentence);

  // 每个 UTF-16 码元属于第几个 grapheme。
  final List<int> unitGrapheme = List<int>.filled(sentence.length, 0);
  int unit = 0;
  int graphemeCount = 0;
  for (final String grapheme in sentence.characters) {
    for (int i = 0; i < grapheme.length; i++) {
      unitGrapheme[unit + i] = graphemeCount;
    }
    unit += grapheme.length;
    graphemeCount++;
  }

  bool isBoundary(int offset) =>
      offset == 0 ||
      offset >= sentence.length ||
      unitGrapheme[offset - 1] != unitGrapheme[offset];

  // 码元偏移 → grapheme 区间右端：落在 grapheme 中间时向上取整（把整个字算进来）。
  int graphemeEndAt(int offset) {
    if (offset >= sentence.length) return graphemeCount;
    return isBoundary(offset) ? unitGrapheme[offset] : unitGrapheme[offset] + 1;
  }

  final List<({int start, int end, String word})> pieces =
      <({int start, int end, String word})>[];
  int offset = 0;
  for (final String word in words) {
    if (word.isEmpty) continue;
    if (offset >= sentence.length) break;
    final int start = offset;
    offset += word.length;
    final int end = graphemeEndAt(offset);
    if (!isBoundary(start) && pieces.isNotEmpty) {
      final ({int start, int end, String word}) last = pieces.removeLast();
      pieces.add((
        start: last.start,
        end: end > last.end ? end : last.end,
        word: last.word + word,
      ));
      continue;
    }
    pieces.add((start: unitGrapheme[start], end: end, word: word));
  }
  return <SubtitleSweepToken>[
    for (final ({int start, int end, String word}) piece in pieces)
      SubtitleSweepToken(
        graphemeStart: piece.start,
        graphemeEnd: piece.end,
        word: piece.word,
      ),
  ];
}
