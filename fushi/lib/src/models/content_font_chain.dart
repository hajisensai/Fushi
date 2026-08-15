/// **内容**文字的字体回退链——词典释义、EPUB 正文、例句这类「语言由内容决定」
/// 的文字，产出 WebView 用的 CSS `font-family` 值。
///
/// ## 与界面链的分界
///
/// `app_ui_font_chain.dart` 管界面，跟**显示语言**（`AppModel.appLocale`）；本文件
/// 管内容，跟**内容自身的语言**。两者共用同一张平台字体表
/// （`cjk_font_families.dart`）但策略不同，不要合并：中文界面下打开一本日文书，
/// 界面该是中文字形、正文该是日文字形，这是两个独立的正确答案。
///
/// ## 语言从哪来（优先级，高到低）
///
/// 1. **用户手动指定**——词典的 `Dictionary.languageOverride`、书的
///    `EpubBooks.language`。用户说了算，永远压过一切自动判断。
/// 2. **内容自带的元数据**——EPUB OPF 的 `dc:language`、yomitan `index.json` 的
///    `sourceLanguage` / `targetLanguage`、字幕轨的 language。
/// 3. **节点级标注**——yomitan structured content 里词典作者标的 `lang` 属性
///    （`popup.js` 已逐节点透传），由 CSS `:lang()` 消费，混排天然分段生效。
/// 4. **字符检测**——只在以上都缺失时兜底，且带已知偏向（汉字会被判成日文），
///    所以排最后。
///
/// ## 为什么未知语言不猜
///
/// [contentFontFamilies] 在语言无法确定且没有兜底要求时返回空链，调用方应保持
/// 原样（CSS 里就是不写 `font-family`）。理由与界面链同构：CSS 的 `font-family`
/// 列表里**第一个含有该字形的 face 就胜出**，拉丁字母几乎每个 CJK face 都有，
/// 所以链首放一个 CJK face 等于把拉丁排版也交给它。对语言真的未知的内容，这是把
/// 「少数汉字字形不对」换成「整段西文排版变样」——不划算。
///
/// 例外是 [fallbackWhenUnknown]：查词弹窗这类**已知一定是 CJK 内容**的表面可以
/// 打开它，拿到一条按 app 内容分布排序（日文在前）的兜底链。这不是「假设内容恒为
/// 日语」——不存在全局学习语言这回事——而是「在完全无信息时，选一个受控的 face
/// 顺序，而不是让引擎按系统 locale 随机挑」。用户随时可以手动指定来推翻它。
library;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:fushi/src/models/cjk_font_families.dart';

/// 兜底段的书写系统顺序。与 `app_ui_font_chain.dart` 的兜底段同序，理由相同：
/// 本 app 的内容以日文居多，日文假名/专用汉字在中文字体里缺字率最高，让它排在
/// 最前能把最常见的缺字挡在受控的 face 上。
const List<CjkScript> _kFallbackScriptOrder = <CjkScript>[
  CjkScript.japanese,
  CjkScript.simplifiedChinese,
  CjkScript.traditionalChinese,
  CjkScript.korean,
];

/// 构造内容文字的字体家族名链。
///
/// - [languageTag]：内容语言（BCP-47 风格，如 `ja` / `zh-Hant`）。null 或无法识别
///   为 CJK 时按 [fallbackWhenUnknown] 决定是给兜底链还是空链。
/// - [platform]：解析系统字体名用的平台，测试可注入。
/// - [style]：黑体还是明朝体/宋体。阅读器正文用 [CjkFontStyle.serif]，
///   查词弹窗用 [CjkFontStyle.sansSerif]。
/// - [customFamilies]：用户自定义字体（词典字体设置 / 阅读器字体），**按用户排序**
///   放在链首——用户的显式选择永远优先于系统字体。
/// - [fallbackWhenUnknown]：语言未知时是否给兜底链。见 library 注释。
List<String> contentFontFamilies({
  required String? languageTag,
  required TargetPlatform platform,
  CjkFontStyle style = CjkFontStyle.sansSerif,
  List<String> customFamilies = const <String>[],
  bool fallbackWhenUnknown = false,
}) {
  // 保序 + 去重：用户把某个系统字体名手动加进自定义列表时，不该在链里出现两次。
  final Set<String> chain = <String>{};
  for (final String family in customFamilies) {
    final String trimmed = family.trim();
    if (trimmed.isNotEmpty) chain.add(trimmed);
  }

  final Map<CjkScript, List<String>> fonts = cjkFontsFor(platform, style);
  final CjkScript? script = cjkScriptForLanguageTag(languageTag);

  if (script != null) {
    chain.addAll(fonts[script]!);
  } else if (!fallbackWhenUnknown && chain.isEmpty) {
    // 语言未知、用户也没指定字体 → 不接管，保持调用方原样（见 library 注释）。
    return const <String>[];
  }

  // 缺字续接：内容里混进别的 CJK 语言（日中词典的中文释义、中文书里的日文引文）
  // 时，让它落到受控的 face 上，而不是引擎默认。
  for (final CjkScript fallback in _kFallbackScriptOrder) {
    chain.addAll(fonts[fallback]!);
  }
  return List<String>.unmodifiable(chain);
}

/// [contentFontFamilies] 的 CSS 形态：产出可直接拼进 `font-family: ...` 的值。
///
/// 家族名一律加双引号（含空格的名字必须引，不含的引了也合法，统一比分支更不容易
/// 出错），末尾追加 CSS generic family 作最终兜底。链为空时返回空串，调用方据此
/// 决定「整条 `font-family` 声明都不要写」。
String contentFontFamilyCss({
  required String? languageTag,
  required TargetPlatform platform,
  CjkFontStyle style = CjkFontStyle.sansSerif,
  List<String> customFamilies = const <String>[],
  bool fallbackWhenUnknown = false,
}) {
  final List<String> families = contentFontFamilies(
    languageTag: languageTag,
    platform: platform,
    style: style,
    customFamilies: customFamilies,
    fallbackWhenUnknown: fallbackWhenUnknown,
  );
  if (families.isEmpty) return '';

  final String generic = style == CjkFontStyle.serif ? 'serif' : 'sans-serif';
  final String quoted =
      families.map((String f) => '"${_escapeCssFamily(f)}"').join(', ');
  return '$quoted, $generic';
}

/// 家族名里的 `"` 和 `\` 需要转义才能安全放进 CSS 双引号串。系统字体名不会有这些
/// 字符，但用户自定义字体名是用户输入——不转义就是一个 CSS 注入口子。
String _escapeCssFamily(String family) =>
    family.replaceAll('\\', r'\\').replaceAll('"', r'\"');
