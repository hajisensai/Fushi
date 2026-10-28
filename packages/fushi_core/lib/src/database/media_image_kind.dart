/// 媒体附加图种类值域（`MediaImages.kind` 列，Jellyfin 图组对齐）。
///
/// 只覆盖 `media_images.kind` 一列；与 media_kind.dart 说明的其余字符串值域
/// **互不通用**。定义在 fushi_core 是因为它是 schema 值域的一部分。
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
  titleCard('title_card'),

  /// 原盘自带的横版盘面图（`BDMV/META/DL`，厂商给的，通常带片名）。归属盘合集、
  /// 由源库扫描写入、`sourceUrl` 恒为 null（手动附加图同契约）；**不属于刮削
  /// 投影**——刮削重写图组只替换 [scrapeOwned] 那几种，不碰它。竖版盘面图不进
  /// 本表，直接做合集主封面（`MediaCollections.coverPath`）。
  discArt('disc_art');

  /// 刮削整组重写时归它管的种类（[discArt] 之外全部）。
  static const List<MediaImageKind> scrapeOwned = <MediaImageKind>[
    backdrop,
    logo,
    titleCard,
  ];

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
