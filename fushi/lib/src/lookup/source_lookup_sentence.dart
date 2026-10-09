import 'package:characters/characters.dart';
import 'package:fushi/src/lookup/sentence_extraction.dart';
import 'package:fushi/src/utils/components/clipboard_lookup_text_panel.dart'
    show SourceLookupHighlight;

/// 查词页（`HomeDictionaryPage`）制卡用的例句（BUG-3092）。
///
/// 查词页的结果卡没有书 / 视频那样的「当前句」，但源文本条上就是用户粘贴 / 输入 /
/// 桌面取词送来的那段原文，扫描高亮 [highlight] 标着这次查的是其中哪几个字。
/// 与 Yomitan 搜索页同口径：取高亮所在的那**一句**（[extractSentenceAt]，句读表与
/// 阅读器一致）作例句。
///
/// 返回空串（卡片 Sentence 照旧留空）的情形：
/// - 源文本为空；
/// - [stripRedundant] 为真——整段源文本恰好就是命中的那个词（只在搜索框里查了一个
///   词），此时没有句子可言，把词本身塞进 Sentence 反而是噪声。
///
/// [highlight] 的下标是**字素簇**下标，落在 `sourceText.trim()` 上（源文本条按
/// trim 后的字素簇渲染，见 `ClipboardLookupTextPanel`）；这里换算成 UTF-16 下标再
/// 交给 [extractSentenceAt]。高亮缺失时以整段为一句。
String sourceLookupMiningSentence({
  required String sourceText,
  required SourceLookupHighlight? highlight,
  required bool stripRedundant,
}) {
  final String text = sourceText.trim();
  if (text.isEmpty || stripRedundant) return '';
  if (highlight == null) {
    return extractSentenceAt(text, 0, text.length).sentence;
  }
  final Characters chars = text.characters;
  final int start = chars.take(highlight.start).string.length;
  final int length = chars
      .skip(highlight.start)
      .take(highlight.length)
      .string
      .length;
  return extractSentenceAt(text, start, length).sentence;
}

/// 制卡字段里没有 JS 给的例句时，补上 [sentence]；JS 已带非空例句或 [sentence] 为空
/// 时原样返回（不覆盖调用方已有的句子）。
Map<String, String> withFallbackMiningSentence(
  Map<String, String> fields,
  String sentence,
) {
  if (sentence.isEmpty || (fields['sentence'] ?? '').isNotEmpty) {
    return fields;
  }
  return Map<String, String>.from(fields)..['sentence'] = sentence;
}
