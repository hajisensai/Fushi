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

/// 收藏句 → 批量制卡输入（首页「收藏句子」小组件的「制卡（N）」用）：只有记着查词
/// 词头（弹窗顶栏 ★ 收藏）的句子才有词可制，否则为 null。映射与收藏夹页的收藏句
/// 行逐字段一致；[bookTitle] 缺省用收藏时的标题快照。
FavoriteMiningItem? favoriteMiningItemOfSentence(
  FavoriteSentence favorite, {
  String? bookTitle,
}) {
  final String? headword = favorite.expression;
  if (headword == null || headword.isEmpty) return null;
  return FavoriteMiningItem(
    expression: headword,
    reading: favorite.reading ?? '',
    sentence: favorite.text,
    source: favorite.source,
    bookKey: favorite.bookKey,
    bookTitle: bookTitle ?? favorite.bookTitle,
    sectionIndex: favorite.sectionIndex,
    normCharOffset: favorite.normCharOffset,
    normCharLength: favorite.normCharLength,
  );
}
