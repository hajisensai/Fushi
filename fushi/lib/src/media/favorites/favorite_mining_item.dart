import 'package:fushi_audio/fushi_audio.dart';

/// 收藏夹批量制卡的一条输入：一个词 + 它被收藏时的上下文。
///
/// 来自两种收藏：
/// - 收藏词（`favorite_words`，弹窗词条 ☆）：[expression] / [reading] 是词条本身，
///   [sentence] 与锚点是 v114 起记下的收藏上下文（存量行为空）；
/// - 收藏句（`FavoriteSentence`，弹窗顶栏 ★）：[expression] / [reading] 是收藏时
///   查的那个词，[sentence] 是句子本身。没有词的收藏句不进批量制卡。
///
/// [source] 取 `kFavoriteSentenceSource*` 值域（收藏词的 'book' / 'video' / 'game'
/// 与之逐字节同值）。锚点口径见 `FavoriteLookupContext`：书 = 章节下标 + 章内
/// 归一化偏移 / 长度；视频 = 集下标 + cue 起点毫秒 / 时长毫秒。
class FavoriteMiningItem {
  const FavoriteMiningItem({
    required this.expression,
    required this.reading,
    required this.sentence,
    required this.source,
    this.bookKey,
    this.bookTitle,
    this.sectionIndex,
    this.normCharOffset,
    this.normCharLength,
  });

  final String expression;
  final String reading;
  final String sentence;
  final String source;
  final String? bookKey;
  final String? bookTitle;
  final int? sectionIndex;
  final int? normCharOffset;
  final int? normCharLength;

  SentenceSourceKind get sourceKind => sentenceSourceKindOf(source);

  bool get isVideo => source == kFavoriteSentenceSourceVideo;
}
