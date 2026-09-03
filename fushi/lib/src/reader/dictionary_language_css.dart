/// 查词弹窗的**按内容语言**字体 CSS 生成器。
///
/// 词典卡片里天然混排多种语言——日中词典就是「词头日文 + 释义中文」，中文释义里
/// 还会夹日文例句。混排解不了「整段是什么语言」这个问题，因为它根本不成立；能解的
/// 是**按 DOM 分区各自标注**，让 CSS 的 `:lang()` 继承机制分段生效。
///
/// ## 三层规则，特异性由低到高（后写的同特异性规则胜出）
///
/// 1. `html, body` —— 兜底链。查词弹窗是已知的 CJK 内容表面，所以这里用
///    `fallbackWhenUnknown: true`：完全无信息时也给一条受控的 face 顺序，而不是
///    让引擎按系统 locale 挑（那正是「日文词条在中文系统上显示成中文字形」的来源，
///    popup.css 原本只写了 macOS 的 Hiragino，Windows/Android 上直接掉 `sans-serif`）。
/// 2. `[data-dictionary="名"]` —— 词典级。释义区按**这本词典的释义语言**
///    （`index.json` 的 `targetLanguage`，或用户手动指定）。DOM 上早就有
///    `data-dictionary` 属性，所以这层零 JS 改动。
/// 3. `:lang(...)` —— 节点级。yomitan structured content 里词典作者标的 `lang`，
///    `popup.js` 已逐节点透传（还带 `nextLanguage` 沿树继承）。作者标注最精确，
///    所以排最后、覆盖前两层。
///
/// ## 为什么根节点**不能**设 `lang="ja"`
///
/// 设了以后每个节点都匹配 `:lang(ja)`，第 2、3 层全部失效——一个「让日文更对」的
/// 改动会把日中词典的中文释义也拽进日文字体。根节点靠第 1 层的兜底链解决缺字体
/// 问题，`:lang()` 只用来匹配**显式标注过**的子树。
library;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:fushi/src/models/cjk_font_families.dart';
import 'package:fushi/src/models/content_font_chain.dart';

/// 一本词典在字体分流里需要的全部信息。
class DictionaryLanguageEntry {
  const DictionaryLanguageEntry({
    required this.name,
    required this.glossaryLanguage,
  });

  /// 词典名 = DOM 上 `data-dictionary` 属性的值。
  final String name;

  /// 释义区语言（用户手动指定优先，其次 `index.json` 的 targetLanguage）。
  /// null = 未知，此层不生成规则（落到兜底链）。
  final String? glossaryLanguage;
}

/// `:lang()` 规则要生成的语言标签。链本身由 [contentFontFamilyCss] 按标签解析，
/// 这里只决定「生成哪几条规则、按什么顺序」。
///
/// `:lang(zh)` 按 BCP-47 前缀匹配，会一并命中 `zh-Hant` / `zh-CN`，所以繁体规则
/// 必须**写在简体之后**（同特异性，后写胜出），否则繁体子树会被简体规则接管。
const List<String> _kLangRules = <String>[
  'ja',
  'ko',
  'zh',
  'zh-Hant',
];

/// 生成注入查词弹窗的字体 CSS。
///
/// - [customFamilies]：用户在字体库里为词典配的家族名，**按用户排序**，进每一条
///   规则的链首——用户的显式选择优先于任何语言判断。
/// - [dictionaries]：词典名 → 释义语言。
/// - [platform]：解析系统字体名用的平台，测试可注入。
///
/// 返回可直接塞进 `<style>` 的 CSS 文本。
String dictionaryLanguageFontCss({
  required List<String> customFamilies,
  required List<DictionaryLanguageEntry> dictionaries,
  required TargetPlatform platform,

  /// 全局设置里的默认内容语言（`PreferencesRepository.defaultContentLanguage`）。
  /// 只影响第 1 层的兜底链：用户设了就按那个语言建链，没设才退回硬编码顺序。
  String? defaultLanguage,
}) {
  final StringBuffer out = StringBuffer();

  // 第 1 层：兜底链。语言未知也给受控顺序（见 library 注释）。
  final String rootChain = contentFontFamilyCss(
    languageTag: defaultLanguage,
    platform: platform,
    customFamilies: customFamilies,
    fallbackWhenUnknown: true,
  );
  if (rootChain.isNotEmpty) {
    out.writeln('html, body { font-family: $rootChain !important; }');
  }

  // 第 2 层：词典级。同一语言的多本词典合并成一条选择器，省得规则数随词典数线性
  // 膨胀（装 30 本词典是常态）。
  final Map<String, List<String>> byLanguage = <String, List<String>>{};
  for (final DictionaryLanguageEntry entry in dictionaries) {
    final String language = entry.glossaryLanguage?.trim() ?? '';
    if (language.isEmpty || entry.name.isEmpty) continue;
    if (cjkScriptForLanguageTag(language) == null) continue;
    byLanguage.putIfAbsent(language, () => <String>[]).add(entry.name);
  }
  for (final MapEntry<String, List<String>> group in byLanguage.entries) {
    final String chain = contentFontFamilyCss(
      languageTag: group.key,
      platform: platform,
      customFamilies: customFamilies,
    );
    if (chain.isEmpty) continue;
    final String selector = group.value
        .map((String name) => '[data-dictionary="${_escapeCssString(name)}"]')
        .join(', ');
    out.writeln('$selector { font-family: $chain !important; }');
  }

  // 第 3 层：节点级作者标注，覆盖前两层。
  for (final String tag in _kLangRules) {
    final String chain = contentFontFamilyCss(
      languageTag: tag,
      platform: platform,
      customFamilies: customFamilies,
    );
    if (chain.isEmpty) continue;
    out.writeln(':lang($tag) { font-family: $chain !important; }');
  }

  return out.toString();
}

/// 词典名是**用户导入的文件/包名**，会含引号、反斜杠、换行。不转义就是一个 CSS
/// 注入口子（`"` 提前闭合属性选择器后面的内容全部当规则解析）。
String _escapeCssString(String value) => value
    .replaceAll('\\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\A ')
    .replaceAll('\r', '');
