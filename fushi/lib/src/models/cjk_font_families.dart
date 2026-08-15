/// CJK 系统字体家族名的**唯一真值**：平台 × 书写系统 × 字形风格 → 家族名列表。
///
/// 这里只有数据，没有策略。两条链共用它：
///
/// - [appUiFontChain]（`app_ui_font_chain.dart`）：**界面**文字，按显示语言
///   （`AppModel.appLocale`）建链，产出 Flutter `TextStyle` 用的家族名列表。
/// - [contentFontFamilies]（`content_font_chain.dart`）：**内容**文字，按内容
///   自身的语言建链，产出 WebView 用的 CSS `font-family` 值。
///
/// 拆出来的原因很直白：同一张表被抄成两份，就等于埋了一颗「改了一处忘了另一处」的雷。
/// 界面链和内容链的**策略**必须分开（前者跟显示语言，后者跟内容语言），但它们对
/// 「Windows 上的日文黑体叫什么」这个问题的答案必须永远一致。
///
/// 家族名按「该平台上的实际安装名」写。引擎/浏览器解析时会自动跳过当前平台不存在
/// 的名字，因此多写一两个同族别名是安全的，只影响解析时的字符串比较成本。
library;

import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show TargetPlatform;

/// CJK 书写系统。繁简分开：Han 统一码位下二者字形差异对读者可见（门/門、发/發），
/// 共用一条链等于放弃字形正确性。
enum CjkScript { japanese, simplifiedChinese, traditionalChinese, korean }

/// 字形风格。CJK 的黑体/明朝体差异远大于拉丁的 sans/serif——阅读器正文默认明朝体
/// （日文书的排版惯例），查词弹窗和界面用黑体。
enum CjkFontStyle { sansSerif, serif }

// ── 黑体（sans-serif）──────────────────────────────────────────────

const Map<CjkScript, List<String>> _kWindowsSans = <CjkScript, List<String>>{
  CjkScript.japanese: <String>[
    'Yu Gothic UI',
    'Yu Gothic',
    'Meiryo',
    'MS Gothic',
  ],
  CjkScript.simplifiedChinese: <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
  ],
  CjkScript.traditionalChinese: <String>[
    'Microsoft JhengHei UI',
    'Microsoft JhengHei',
  ],
  CjkScript.korean: <String>['Malgun Gothic'],
};

const Map<CjkScript, List<String>> _kAppleSans = <CjkScript, List<String>>{
  CjkScript.japanese: <String>['Hiragino Sans', 'Hiragino Kaku Gothic ProN'],
  CjkScript.simplifiedChinese: <String>['PingFang SC', 'Heiti SC'],
  CjkScript.traditionalChinese: <String>['PingFang TC', 'Heiti TC'],
  CjkScript.korean: <String>['Apple SD Gothic Neo'],
};

/// Android / Linux / Fuchsia：Noto CJK 是这些平台的事实标准。
const Map<CjkScript, List<String>> _kNotoSans = <CjkScript, List<String>>{
  CjkScript.japanese: <String>['Noto Sans CJK JP', 'Noto Sans JP'],
  CjkScript.simplifiedChinese: <String>[
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
  ],
  CjkScript.traditionalChinese: <String>['Noto Sans CJK TC', 'Noto Sans TC'],
  CjkScript.korean: <String>['Noto Sans CJK KR', 'Noto Sans KR'],
};

// ── 明朝体 / 宋体（serif）──────────────────────────────────────────

const Map<CjkScript, List<String>> _kWindowsSerif = <CjkScript, List<String>>{
  CjkScript.japanese: <String>['Yu Mincho', 'MS Mincho'],
  CjkScript.simplifiedChinese: <String>['SimSun', 'NSimSun'],
  CjkScript.traditionalChinese: <String>['PMingLiU', 'MingLiU'],
  CjkScript.korean: <String>['Batang'],
};

const Map<CjkScript, List<String>> _kAppleSerif = <CjkScript, List<String>>{
  CjkScript.japanese: <String>['Hiragino Mincho ProN', 'YuMincho'],
  CjkScript.simplifiedChinese: <String>['Songti SC', 'STSong'],
  CjkScript.traditionalChinese: <String>['Songti TC', 'STSong'],
  CjkScript.korean: <String>['AppleMyungjo'],
};

const Map<CjkScript, List<String>> _kNotoSerif = <CjkScript, List<String>>{
  CjkScript.japanese: <String>['Noto Serif CJK JP', 'Noto Serif JP'],
  CjkScript.simplifiedChinese: <String>['Noto Serif CJK SC', 'Noto Serif SC'],
  CjkScript.traditionalChinese: <String>['Noto Serif CJK TC', 'Noto Serif TC'],
  CjkScript.korean: <String>['Noto Serif CJK KR', 'Noto Serif KR'],
};

/// 平台 + 字形风格 → 该平台每个书写系统的家族名。
Map<CjkScript, List<String>> cjkFontsFor(
  TargetPlatform platform,
  CjkFontStyle style,
) {
  switch (platform) {
    case TargetPlatform.windows:
      return style == CjkFontStyle.serif ? _kWindowsSerif : _kWindowsSans;
    case TargetPlatform.macOS:
    case TargetPlatform.iOS:
      return style == CjkFontStyle.serif ? _kAppleSerif : _kAppleSans;
    case TargetPlatform.android:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return style == CjkFontStyle.serif ? _kNotoSerif : _kNotoSans;
  }
}

/// BCP-47 语言标签 → CJK 书写系统；非 CJK（或无法识别）返回 null。
///
/// 接受 `ja`、`ja-JP`、`zh`、`zh-Hant`、`zh-TW`、`cmn`、`yue`、`ko` 等形态——
/// 这些值来自**内容**（EPUB `dc:language`、词典 `index.json`、字幕轨），
/// 上游写法五花八门，不能假设规范化过。
CjkScript? cjkScriptForLanguageTag(String? tag) {
  if (tag == null) return null;
  final String normalized = tag.trim().toLowerCase().replaceAll('_', '-');
  if (normalized.isEmpty) return null;

  final List<String> parts = normalized.split('-');
  final String base = parts.first;

  switch (base) {
    case 'ja':
    case 'jpn':
      return CjkScript.japanese;
    case 'ko':
    case 'kor':
      return CjkScript.korean;
    case 'zh':
    case 'zho':
    case 'cmn':
    case 'yue':
      // 粤语（yue）书面语以繁体为主，但 `yue-Hans` 等显式写法要尊重，所以仍走
      // 下面的通用繁简判定，只是默认值不同。
      return _chineseScriptFromSubtags(
        parts.skip(1),
        defaultTraditional: base == 'yue',
      );
    default:
      return null;
  }
}

/// [Locale] 版本：显示语言用。与 [cjkScriptForLanguageTag] 共用同一套繁简判据。
CjkScript? cjkScriptForLocale(Locale locale) {
  final String? script = locale.scriptCode;
  final String? country = locale.countryCode;
  final StringBuffer tag = StringBuffer(locale.languageCode);
  if (script != null && script.isNotEmpty) tag.write('-$script');
  if (country != null && country.isNotEmpty) tag.write('-$country');
  return cjkScriptForLanguageTag(tag.toString());
}

/// 繁简判定：显式 script 子标签优先（`Hant` / `Hans`），否则按地区推断。
/// 本 app 出货的 `zh-HK` 走繁体、`zh-CN` 走简体。
CjkScript _chineseScriptFromSubtags(
  Iterable<String> subtags, {
  required bool defaultTraditional,
}) {
  for (final String subtag in subtags) {
    switch (subtag) {
      case 'hant':
        return CjkScript.traditionalChinese;
      case 'hans':
        return CjkScript.simplifiedChinese;
      case 'tw':
      case 'hk':
      case 'mo':
        return CjkScript.traditionalChinese;
      case 'cn':
      case 'sg':
        return CjkScript.simplifiedChinese;
    }
  }
  return defaultTraditional
      ? CjkScript.traditionalChinese
      : CjkScript.simplifiedChinese;
}
