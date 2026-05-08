/// Reader 上次阅读位置 —— 跟音频状态解耦，纯 EPUB 和有声书走同一路。
///
/// 不依赖 ttu 自己的 IDB bookmark（paginated + audiobook 场景下它有几重
/// bug：`exploredCharCount` 只写到 section 起点、`scrollX/Y` 是 window 尺度
/// 永远 0、`getSectionIndexByCharCount` 在边界把位置弹到相邻空章）。
///
/// 位置用 `(sectionIndex, normCharOffset)`：`normCharOffset` 是 **章内** 的
/// Sasayaki 归一化字符偏移（跟 AudioCue.normCharStart 同基准，ruby 已剥、
/// 标点/空白 skippable），字号/pageColumns/viewport 变了也不会飘。
class ReaderPosition {
  int? id;

  /// ッツ Ebook Reader IndexedDB 中的 book ID，按书一条。
  late int ttuBookId;

  /// ttu spine 段 index（0-based）。
  late int sectionIndex;

  /// 章内归一化字符偏移。`0` = 章首。
  late int normCharOffset;

  /// TTU 原生章内字符偏移（包含 ruby/空白/标点）。
  /// null 表示旧数据未采集此值，恢复时 fallback 到 normCharOffset。
  int? ttuCharOffset;

  /// 更新时间戳（ms since epoch）。
  late int updatedAt;
}
