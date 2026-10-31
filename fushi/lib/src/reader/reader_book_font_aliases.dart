import 'package:flutter/foundation.dart' show TargetPlatform;

/// 電書協 EPUB 3 制作ガイド的黑体别名族（反馈 KFtRi4FjnO：章标题文字叠成一团）。
///
/// 電書協 / KADOKAWA 系的书在 `style-standard.css` 里给黑体段落（`.gfont`、竖排标题）
/// 写的是 `font-family: sans-serif-ja, sans-serif`（竖排还有 `sans-serif-ja-v`）——这两个
/// 名字是规范留给**阅读系统**去定义的别名，书里不带 `@font-face`。阅读器以前没定义它们，
/// 于是这些文字直接落到 generic `sans-serif`。
///
/// Android 上 generic `sans-serif` 是可被 OEM 主题换掉的槽位（小米 HyperOS 实测是
/// `MiSansVF_Overlay.ttf`，用户换了主题字体就是那款字体）。主题字体常常缺竖排度量：用户
/// 截图里标题用的是一款毛笔字体，竖排时字形逐字叠在一起；正文不受影响，因为 body 的
/// `font-family` 由阅读器 `!important` 钉住了。Windows / Apple 上 generic `sans-serif`
/// 就是系统日文黑体，所以同一本书在 Windows 正常。
///
/// 修法：Android 上把这两个别名声明成 `@font-face`，`src` 用 `local()` 指向系统自带、
/// 不随主题替换的 Noto Sans CJK JP（AOSP 的 `NotoSansCJK-Regular.ttc`）。
///
/// - **只能用 `local()`**：Android 的 Blink 不按 family 名匹配系统字体（`"Noto Sans CJK JP"`
///   当 family 名写进 `font-family` 实测不命中），但 `local()` 认全名与 PostScript 名
///   （小米 Pad 5 / HyperOS 4 / Chrome 实测 `Noto Sans CJK JP Regular`、`NotoSansCJKjp-Regular`、
///   `NotoSansCJKJP-Regular` 三个都命中）。
/// - **落空即原样**：所有 `local()` 都不命中时这条 `@font-face` 加载失败，浏览器按规范跳到
///   `font-family` 列表下一项（书里写的 `sans-serif`），与改动前完全一致。
/// - **不声明粗体 face**：AOSP 只带 Regular，粗体本来就是合成的；同族再挂一个必然失败的
///   700 face 反而会让粗体请求整族落空。
/// - **不做明朝体别名**（`serif-ja` / `serif-ja-v`）：Noto Serif CJK 在 fonts.xml 里只登记为
///   `fallbackFor="serif"`，`local()` 名表不收它（实测不命中），声明了也只会落回 `serif`。
/// - **只在 Android 发**：Windows / Apple 的 generic 黑体就是正确的系统日文黑体，不该被换掉。
abstract final class ReaderBookFontAliases {
  /// 電書協规范的黑体别名（横排 / 竖排）。
  static const List<String> sansSerifFamilies = <String>[
    'sans-serif-ja',
    'sans-serif-ja-v',
  ];

  /// Android 系统 Noto Sans CJK JP 的 `local()` 候选（全名、PostScript 名、fonts.xml 写法）。
  static const List<String> androidSansLocalNames = <String>[
    'Noto Sans CJK JP Regular',
    'NotoSansCJKjp-Regular',
    'NotoSansCJKJP-Regular',
  ];

  /// 该平台要注入的 `@font-face`；不需要时返回空串。
  static String fontFaces(TargetPlatform platform) {
    if (platform != TargetPlatform.android) return '';
    final String src = androidSansLocalNames
        .map((String name) => 'local("$name")')
        .join(', ');
    return sansSerifFamilies
        .map(
          (String family) =>
              '@font-face { font-family: "$family"; src: $src; }',
        )
        .join('\n');
  }
}
