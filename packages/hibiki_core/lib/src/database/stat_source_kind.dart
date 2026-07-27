/// 统计来源值域（favorite_words / mining_statistics / lookup_mining_counters /
/// statistics_tombstones 四张表的 `source_type` 列）。
///
/// 原常量定义在 pages 层 `stat_activity.dart`；它们是 **schema 值域的一部分**
/// 且写入点跨层（lookup 浮窗 / 阅读器 / 视频页 / core DAO），故挪进 hibiki_core
/// （同 activity_event_types.dart 的理由）。
///
/// ⚠️ 与合集/书架域（`MediaKind`）**互不通用**：本域只有 book / video 两桶
/// （`book` 涵盖 EPUB / 字幕书 / PDF / 漫画等一切「阅读」表面），`book` ≠ `epub`。
library;

/// 书内阅读统计来源（落 DB 串，永不改变）。
const String kStatSourceBook = 'book';

/// 视频统计来源（落 DB 串，永不改变）。
const String kStatSourceVideo = 'video';

/// 统计来源的**内存态**枚举（命名统一 Phase 3.4，模式照 `SentenceSourceKind` /
/// `MediaKind`）。落库仍存 [kStatSourceBook] / [kStatSourceVideo] 原字符串
/// （字节不变），本枚举供边界显式解析 / 穷尽 switch。
enum StatSourceKind {
  /// 书内阅读（EPUB / 字幕书 / PDF / 漫画 / 独立查词等一切非视频表面）。
  book(kStatSourceBook),

  /// 视频。
  video(kStatSourceVideo);

  const StatSourceKind(this.dbValue);

  /// 落 DB 的字符串（与 `kStatSource*` 常量逐字节一致）。永不改变；持久化
  /// 场景只用本字段，绝不用 `.name`。
  final String dbValue;

  /// 严格解析：精确匹配两个落库值之一，未知 / null → null，绝不抛。
  static StatSourceKind? tryParse(String? raw) {
    for (final StatSourceKind kind in StatSourceKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}
