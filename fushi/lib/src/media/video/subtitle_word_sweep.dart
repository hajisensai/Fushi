import 'package:characters/characters.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 视频暂停句「整句扫词」的纯逻辑层（无 Flutter / 无页面状态，可直接单测）。
///
/// 设计：把「选谁」与「做什么」正交——扫词只在数据层移动一个**词游标**（暂停句分词
/// 后的词序列下标），每停一词就复用点击查词链路弹/换同一张浮层；动词（翻词条 /
/// 制卡 / 发音）全部交给既有 `dictionaryPopup` 表。因为不进 caret，浮层的
/// X=制卡 / Y=发音在扫词中永远可达（进 caret 会被模态路由吞掉）。
///
/// 本文件只回答两个问题：① 一句话怎么切成词、每个词首字在哪；② 游标怎么前进/后退
/// （句尾按用户要求循环回句首）。页面侧的接线在 `video_fushi/word_sweep.part.dart`。

/// 一个扫词单元：词本身 + 它在整句 **grapheme 序列**里的首字下标。
///
/// 下标是 grapheme（不是 UTF-16 码元）：字幕登记表 / `_handleSubtitleLookupTap` /
/// `SubtitleCharHit.graphemeIndex` 全部按 grapheme 计数（见
/// `subtitle_transcript_text.dart` 里的 `sentence.characters`），而
/// [JapaneseLanguage.textToWords] 按 UTF-16 码元切分。二者只在纯汉字 / 假名下相等，
/// 带组合字符 / emoji / 代理对就会错位，故这里统一折算回 grapheme——**不照抄**
/// `texthooker_page.dart` 的 `_indexedWordRows`（那份算的是 UTF-16 偏移）。
class SubtitleSweepToken {
  const SubtitleSweepToken({required this.graphemeStart, required this.word});

  /// 词首字在整句 grapheme 序列里的下标。
  final int graphemeStart;

  /// 词本身（与词典引擎在该位置的最长匹配一致）。
  final String word;

  @override
  String toString() => 'SubtitleSweepToken($graphemeStart, "$word")';
}

/// 分词器签名：把一句话切成按序排列、拼接回即原文的词。
///
/// 默认实现是引擎最长匹配 [JapaneseLanguage.textToWords]；只有单测需要注入确定性
/// 输入时才传别的（真机 / 生产一律走默认）。
typedef SubtitleSweepTokenizer = List<String> Function(String text);

/// 把暂停句切成扫词单元。
///
/// 复用 [JapaneseLanguage.textToWords] 的**切分不变式**（各片段按序拼回即原文，见
/// `texthooker_page.dart` 的同名注释），因此词的 UTF-16 长度前缀和就是它的码元偏移；
/// 再把该偏移折算成 grapheme 下标（用每个 grapheme 的 UTF-16 长度累进，绝不劈开
/// 代理对 / 组合字符）。
///
/// 空句 / 空词返回空表；引擎未就绪时 [JapaneseLanguage.textToWords] 退化为逐码元，
/// 本函数照常产出（只是粒度变细），不抛异常。
List<SubtitleSweepToken> buildSubtitleSweepTokens(
  String sentence, {
  SubtitleSweepTokenizer? tokenize,
}) {
  if (sentence.isEmpty) return const <SubtitleSweepToken>[];
  final List<String> words =
      (tokenize ?? JapaneseLanguage.instance.textToWords)(sentence);
  final List<String> graphemes = sentence.characters.toList();
  final List<SubtitleSweepToken> tokens = <SubtitleSweepToken>[];
  int graphemeIndex = 0;
  for (final String word in words) {
    if (word.isEmpty) continue;
    final int start = graphemeIndex;
    // 词的 UTF-16 码元长度 → 前进多少 grapheme。词若在代理对中间被切开（引擎未就绪
    // 的逐码元回退），remaining 会提前 <=0，循环照样终止，不会越界。
    int remaining = word.length;
    while (remaining > 0 && graphemeIndex < graphemes.length) {
      remaining -= graphemes[graphemeIndex].length;
      graphemeIndex++;
    }
    tokens.add(SubtitleSweepToken(graphemeStart: start, word: word));
  }
  return tokens;
}

/// 扫词游标的下一格 / 上一格。
///
/// 句尾按用户拍板**循环**回句首（[length] 为 1 时恒停在 0）。[index] 传 -1 表示
/// 「尚未开始」：前进落到 0、后退落到末词（用户首次按「上一词」也应落在句尾，而不是
/// 被夹到句首）。[length] <= 0（无词）恒返回 -1，调用方据此早退。
int advanceSubtitleSweepIndex(int index, int length, {required bool forward}) {
  if (length <= 0) return -1;
  if (index < 0 || index >= length) {
    return forward ? 0 : length - 1;
  }
  return forward ? (index + 1) % length : (index - 1 + length) % length;
}
