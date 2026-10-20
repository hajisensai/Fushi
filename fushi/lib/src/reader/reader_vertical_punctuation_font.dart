import 'package:fushi/src/reader/reader_settings.dart';

/// 竖排标点子集字体（BUG-3606）。
///
/// 竖排 `text-orientation: mixed` 下，「」、。（）等 UAX #50 标为 Tu / Tr 的标点由
/// 浏览器保持直立、靠字体的 OpenType `vert` / `vrt2` 替换成竖排字形。Blink（Android
/// WebView / WebView2 / Chrome）在提供该字符的字体**没有**这条替换时不会退回旋转，
/// 直接画横排字形；而 ー …… —— 这类字符按旋转处理、与字体无关，总是竖的。于是正文
/// 字体（用户导入 / 按名选的系统字体、书自带字体、系统回退字体）只要缺 `vert`，同一页
/// 就会「引号横着、长音和省略号竖着」。
///
/// 修法：竖排时把一款随包、确定带 `vert` 的标点子集（Noto Serif JP，SIL OFL 1.1，
/// 由 `fushi/tool/fonts/gen_vertical_punctuation.py` 生成，3.7 KB）放在正文字体链
/// **最前面**，`unicode-range` 只覆盖子集里的标点——这些标点一律用它的竖排字形，其余
/// 字符照旧落到原来的链。横排不注入，渲染与改动前逐字节相同。
///
/// 代价：竖排时这些标点的字形风格固定为 Noto Serif JP（即使正文字体自己带 `vert`）。
abstract final class ReaderVerticalPunctuationFont {
  /// CSS 字族名。
  static const String family = 'Fushi Vertical Punctuation';

  /// 随包资产 key（`pubspec.yaml` 整体登记了 `assets/fonts/`）。
  static const String assetKey = 'assets/fonts/FushiVerticalPunctuation.woff2';

  /// 阅读器请求拦截器识别的路径（阅读器正文与歌词 WebView 共用同一个拦截器）。
  static const String urlPath = '/fushi-assets/FushiVerticalPunctuation.woff2';

  /// 子集实际收录的码位（生成脚本只收上游 `vert` / `vrt2` 确实替换了的候选）。
  /// 守卫测试从字体文件的 cmap 反推校验两者一致。
  static const List<(int, int)> codepointRanges = <(int, int)>[
    (0x3001, 0x3002), // 、。
    (0x3008, 0x3011), // 〈〉《》「」『』【】
    (0x3014, 0x301F), // 〔〕〖〗〘〙〚〛〜〝〞〟
    (0x30A0, 0x30A0), // ゠
    (0xFF08, 0xFF09), // （）
    (0xFF0C, 0xFF0C), // ，
    (0xFF0E, 0xFF0E), // ．
    (0xFF1A, 0xFF1A), // ：
    (0xFF1D, 0xFF1D), // ＝
    (0xFF3B, 0xFF3B), // ［
    (0xFF3D, 0xFF3D), // ］
    (0xFF3F, 0xFF3F), // ＿
    (0xFF5B, 0xFF60), // ｛｜｝～｟｠
    (0xFFE3, 0xFFE3), // ￣
  ];

  /// `@font-face` 的 `unicode-range` 值。
  static String get unicodeRange => codepointRanges
      .map(
        ((int, int) r) =>
            r.$1 == r.$2 ? 'U+${_hex(r.$1)}' : 'U+${_hex(r.$1)}-${_hex(r.$2)}',
      )
      .join(', ');

  /// 竖排时注入的 `@font-face`。`font-display: block`：本地拦截下发、几 KB，
  /// 不让首帧先画一遍横排标点再换掉（分页脚本本来就等 `document.fonts.ready`）。
  static String fontFace() =>
      '@font-face { font-family: "$family"; '
      'src: url("${ReaderCustomFontCss.resourceUrl(urlPath)}") format("woff2"); '
      'unicode-range: $unicodeRange; font-display: block; }';

  /// 把子集放到 [chain]（一条 CSS `font-family` 值）最前面。
  static String prependTo(String chain) =>
      chain.isEmpty ? '"$family"' : '"$family", $chain';

  static String _hex(int v) => v.toRadixString(16).toUpperCase();
}
