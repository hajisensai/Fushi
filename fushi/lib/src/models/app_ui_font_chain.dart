/// 应用界面（app chrome）文字的**字体回退链**。
///
/// ## 为什么需要「链」而不是单个家族名
///
/// 字体选择的本质是有序回退：一个 face 只覆盖部分码位，缺字时引擎按链向后找。
/// 但历史实现把链压成了单值，一处压缩产生了三个症状：
///
/// 1. 用户在「外观 · 排版 · 字体库」里配的是一个**有序列表**，
///    `AppFontLoader.resolveAndLoad` 却只返回第一个 enabled 条目，其余全部丢弃——
///    用户排在第 2、3 位的字体从来没有机会参与缺字回退。
/// 2. 没配自定义字体时 `fontFamily` 为 null，CJK 字形完全交给引擎默认 fallback。
///    该回退不看 [Locale]（Windows/Skia 尤甚），中文界面常落到一套并非为简中优化
///    的 face 上——用户口中的「中文默认字体很烂」。
/// 3. 主字体是日文 face 时，简中特有汉字（们/东/为…）在日文字体里缺字，逐字掉到
///    引擎默认 face：同一行里字形忽宽忽窄、忽粗忽细。
///
/// 视频字幕层早就承认了这个事实（TODO-088 的 `subtitleCjkFontFallbacks`），但那条链
/// 是**字幕专用**且只面向日文（顺序还要与 mpv/libass 对齐，见 BUG-929），不能直接
/// 复用为界面链——界面链必须跟随**显示语言**（BUG-068 定下的规矩：界面字形跟
/// `appLocale`，不跟内容语言）。
///
/// ## 界面链 vs 内容链
///
/// 本文件只管**界面**。内容（词典释义、EPUB 正文、字幕）的字体跟**内容自身的语言**
/// 走，与显示语言无关，见 `content_font_chain.dart`。两者共用同一张平台字体表
/// （`cjk_font_families.dart`），但策略不同，不要合并。
///
/// ## 链的构造规则（[appUiFontChain]）
///
/// ```
/// [用户自定义字体（全部 enabled，按序）] + [显示语言的系统字体] + [其余 CJK 语言字体]
/// ```
///
/// 关键的一条**不做**：显示语言不是 CJK 且用户没配自定义字体时，返回空链，
/// `fontFamily`/`fontFamilyFallback` 双 null，与改造前逐像素一致。原因是
/// `fontFamily == null` 时引擎会把 fallback 的第一项**当作主字体**（拉丁字形也归它
/// 管），此时若强塞一条 CJK 链，英文/法文界面的拉丁文字就会被 CJK 字体的拉丁部分
/// 接管——把一个 CJK 缺字问题换成一个全语言排版问题。有主字体时链只在缺字时生效，
/// 不影响拉丁，所以可以放心追加。
library;

import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:fushi/src/models/cjk_font_families.dart';

/// 缺字续接顺序：显示语言的字体排完后，按此序补齐其余 CJK 语言。
///
/// 日文排第一是内容分布决定的——本 app 的内容（书名 / 字幕 / 词条 / 例句）以日文
/// 为主，界面语言却常是中文；日文假名和日文专用汉字在中文字体里缺字率最高，让它紧
/// 跟在显示语言之后，能把最常见的缺字挡在**受控的 face** 上，而不是引擎随机挑选。
/// 注意这只是**兜底段**的排序偏好，不代表 app 假设内容恒为日语（不存在全局学习
/// 语言这回事）；内容的真实语言由 `content_font_chain.dart` 按内容真值决定。
const List<CjkScript> _kFallbackScriptOrder = <CjkScript>[
  CjkScript.japanese,
  CjkScript.simplifiedChinese,
  CjkScript.traditionalChinese,
  CjkScript.korean,
];

/// 构造界面文字的完整字体链：`[0]` 是主字体（喂 `TextStyle.fontFamily`），其余喂
/// `TextStyle.fontFamilyFallback`。
///
/// - [customFamilies]：用户在字体库 `appUi` 目标里启用的家族名，**按用户排序**，
///   已由 `AppFontLoader` 注册进引擎。
/// - [locale]：显示语言（`AppModel.appLocale`），不是内容语言。
/// - [platform]：解析系统字体名用的平台，测试可注入。
///
/// 返回空列表表示「保持平台默认」——调用方应把 fontFamily 与 fontFamilyFallback
/// 都留成 null。
List<String> appUiFontChain({
  required List<String> customFamilies,
  required Locale locale,
  required TargetPlatform platform,
}) {
  // LinkedHashSet 语义：保序 + 去重。用户把某个系统字体名手动加进字体库时，不该在
  // 链里出现第二次（重复项只会拖慢引擎解析，且让「第几个生效」变得难以推理）。
  final Set<String> chain = <String>{};
  for (final String family in customFamilies) {
    final String trimmed = family.trim();
    if (trimmed.isNotEmpty) chain.add(trimmed);
  }

  final Map<CjkScript, List<String>> fonts =
      cjkFontsFor(platform, CjkFontStyle.sansSerif);
  final CjkScript? uiScript = cjkScriptForLocale(locale);
  if (uiScript != null) {
    chain.addAll(fonts[uiScript]!);
  }

  // 非 CJK 界面 + 无自定义字体 → 不接管平台默认（见 library 注释）。
  if (chain.isEmpty) return const <String>[];

  for (final CjkScript script in _kFallbackScriptOrder) {
    chain.addAll(fonts[script]!);
  }
  return List<String>.unmodifiable(chain);
}
