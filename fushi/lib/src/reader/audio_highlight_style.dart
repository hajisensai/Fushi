import 'dart:ui' show Color;

/// 有声书正文「当前句」的最终外观：底色 + 字色。
///
/// [text] 为 null 表示不改字色（沿用正文色，即历史行为）。
typedef AudioHighlightStyle = ({Color background, Color? text});

/// 把三项偏好解析成当前句外观（纯函数，正文 CSS 与测试共用）。
///
/// - [highlight]：主题 / 用户设的当前句高亮色（`audio_highlight_color` 或主题派生）。
/// - [showBackground]：`audio_highlight_background`；关 = 不铺底色。
/// - [customTextColor]：`audio_highlight_text_color`（ARGB，`0` = 未设）。
///
/// 关掉底色而又没设字色时，字色退回到不透明的高亮色——否则当前句与正文完全
/// 一样、根本看不出读到哪里。这就是「只变字色、不加底色」的默认形态。
AudioHighlightStyle resolveAudioHighlightStyle({
  required Color highlight,
  required bool showBackground,
  required int customTextColor,
}) {
  final Color? custom = customTextColor == 0 ? null : Color(customTextColor);
  return (
    background: showBackground ? highlight : const Color(0x00000000),
    text: custom ?? (showBackground ? null : highlight.withValues(alpha: 1)),
  );
}
