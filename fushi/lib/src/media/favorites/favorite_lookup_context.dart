import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 收藏一个词时所处的上下文：查词所在的原句与它的定位锚点。
///
/// 锚点口径与收藏句（`FavoriteSentence`）逐字段一致，收藏夹因此能用同一套跳转 /
/// 截音频逻辑处理「收藏词」：
/// - 书 / 有声书：[sectionIndex] = 章节下标，[normCharOffset] / [normCharLength] =
///   章内归一化字符偏移 / 长度（`getNormalizedOffset` 坐标）；
/// - 视频：[sectionIndex] = 集下标（单视频为 null），[normCharOffset] = cue 起点毫秒、
///   [normCharLength] = cue 时长毫秒——**不是字符偏移**。
///
/// 由宿主页（阅读器 / 视频页）在收藏那一刻提供；没有句子概念的宿主（首页查词）
/// 返回 null，收藏词只记词形与释义。
class FavoriteLookupContext {
  const FavoriteLookupContext({
    required this.sentence,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
  });

  final String sentence;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;
}

/// 一次查词结果的首个词头（表记 + 读音）。收藏句时用它记下「这句是因为哪个词收藏
/// 的」——收藏夹据此在句子旁显示对应的词。无结果返回 null。
({String expression, String reading})? leadingHeadwordOf(
  DictionarySearchResult? result,
) {
  if (result == null || result.entries.isEmpty) return null;
  final DictionaryEntry entry = result.entries.first;
  if (entry.word.isEmpty) return null;
  return (expression: entry.word, reading: entry.reading);
}
