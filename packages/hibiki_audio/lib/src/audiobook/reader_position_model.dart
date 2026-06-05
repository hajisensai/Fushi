/// Reader 上次阅读位置 —— 跟音频状态解耦，纯 EPUB 和有声书走同一路。
///
/// 位置用 `(sectionIndex, normCharOffset)`：`normCharOffset` 是 **章内** 的
/// 归一化字符偏移（跟 AudioCue.normCharStart 同基准，ruby 已剥、
/// 标点/空白 skippable），字号/pageColumns/viewport 变了也不会飘。
class ReaderPosition {
  int? id;

  /// EpubBooks.bookKey（书的主键 = sanitize 后的标题），按书一条。
  late String bookKey;

  /// EPUB spine 章节 index（0-based）。
  late int sectionIndex;

  /// 章内归一化字符偏移。`0` = 章首。
  late int normCharOffset;

  /// 旧字段，保留供数据库兼容。新代码不写入此值。
  int? ttuCharOffset;

  /// 更新时间戳（ms since epoch）。
  late int updatedAt;
}
