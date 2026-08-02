/// 媒体附加图种类值域（`MediaImages.kind` 列，Jellyfin 图组对齐）。
///
/// 只覆盖 `media_images.kind` 一列；与 media_kind.dart 说明的其余字符串值域
/// **互不通用**。定义在 hibiki_core 是因为它是 schema 值域的一部分。
///
/// 命名纪律（术语表）：主封面统一叫 cover（列仍在 `VideoBooks.coverPath` /
/// `MediaCollections.coverPath`，不进本表）；带字横图**不叫 thumb/thumbnail**
/// （淘汰词），按影视行业惯例叫 title card。
library;

/// 一张附加图的种类。
///
/// Drift 列保持 `TEXT`（不引入 TypeConverter）：边界上用 [tryParse] 显式解析、
/// 用 [dbValue] 显式落库，未知值（未来新增种类的旧版本读新库）返回 null 不抛。
enum MediaImageKind {
  /// 无字横版背景图（约 16:9）。**唯一允许多张**的种类（`position` 0..n，
  /// 对齐 Jellyfin `AllowsMultipleImages` 只放行 Backdrop 的拍板）；详情页
  /// hero 全屏背景 + 轮换用。
  backdrop('backdrop'),

  /// 标题 logo 图（透明底 PNG），详情页/hero 叠加替代纯文字标题。
  logo('logo'),

  /// 带片名文字的横版图（TMDB 里 `iso_639_1` 非空的 backdrop——Jellyfin 把它
  /// 分流为 Thumb，槽位语义：横版卡片图，与全屏背景分开）。
  titleCard('title_card');

  const MediaImageKind(this.dbValue);

  /// 落 DB 的字符串。永不改变（Never break userspace）。
  final String dbValue;

  /// DB 字符串 → 枚举；未知/空返回 null，绝不抛。
  static MediaImageKind? tryParse(String? raw) {
    for (final MediaImageKind kind in MediaImageKind.values) {
      if (kind.dbValue == raw) {
        return kind;
      }
    }
    return null;
  }
}
