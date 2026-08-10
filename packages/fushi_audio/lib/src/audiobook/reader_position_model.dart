/// Reader 上次阅读位置 —— 跟音频状态解耦，纯 EPUB 和有声书走同一路。
///
/// 位置用 `(sectionIndex, normCharOffset)`：`normCharOffset` 是 **章内** 的
/// 归一化字符偏移（跟 AudioCue.normCharStart 同基准，ruby 已剥、
/// 标点/空白 skippable），字号/pageColumns/viewport 变了也不会飘。
class ReaderPosition {
  int? id;

  /// 书稳定身份（v82 起 = EpubBooks.uid；非 epub 域沿用其既有稳定键），按书一条。
  late String bookUid;

  /// EPUB spine 章节 index（0-based）。
  late int sectionIndex;

  /// 章内归一化字符偏移（0-10000 分数基准）。`0` = 章首。书签/收藏/统计仍用它。
  late int normCharOffset;

  /// BUG-162: section 内精确绝对字符偏移（恢复锚）。`null` = 无精确偏移
  /// （恢复回退 normCharOffset 分数）。退出再进用它做「存→取」不动点。
  int? charOffset;

  /// 更新时间戳（ms since epoch）。
  late int updatedAt;
}
