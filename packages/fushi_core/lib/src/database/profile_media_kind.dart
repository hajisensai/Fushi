/// Profile 绑定值域（media_type_profiles 表的 `media_type` 列）。
///
/// ⚠️ 与合集/书架域（`MediaKind`）**互不通用**：`srtbook` ≠ `srt`、本域另有
/// `audiobook` / `lyrics` 两个「阅读模式」种类（同一本 `MediaKind.epub` 书按
/// 是否挂有声书 / 字幕 / 歌词模式解析到不同 Profile 绑定），不存在
/// `MediaKind → ProfileMediaKind` 的忠实映射——解析依赖运行时挂载状态
/// （见 reader_fushi `_resolveAndApplyProfile`），不是静态种类换算。
library;

/// Profile 绑定的媒体种类（命名统一 Phase 3.4，模式照 `SentenceSourceKind` /
/// `MediaKind`）。落库仍存原字符串（字节不变），边界上用 [tryParse] 显式解析、
/// 用 [dbValue] 显式落库。
enum ProfileMediaKind {
  /// EPUB 书（无有声书 / 字幕挂载时的默认阅读绑定）。
  epub('epub'),

  /// 字幕书（SRT 文本导入的书）。
  srtbook('srtbook'),

  /// 有声书（EPUB + 音频对齐）。
  audiobook('audiobook'),

  /// 歌词模式。
  lyrics('lyrics'),

  /// 视频。
  video('video');

  const ProfileMediaKind(this.dbValue);

  /// 落 DB 的字符串。永不改变；持久化场景只用本字段，绝不用 `.name`。
  final String dbValue;

  /// 严格解析：精确匹配五个落库值之一，未知 / null → null，绝不抛
  /// （`media_type_profiles` 表接受任意串，历史行可能含旧值域）。
  static ProfileMediaKind? tryParse(String? raw) {
    for (final ProfileMediaKind kind in ProfileMediaKind.values) {
      if (kind.dbValue == raw) return kind;
    }
    return null;
  }
}
