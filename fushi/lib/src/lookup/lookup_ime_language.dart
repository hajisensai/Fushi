/// 查词输入框的「输入法语言」偏好——把用户选的 BCP-47 标签翻成各端能用的形态。
///
/// 为什么不挂在 `AppModel.targetLanguage` 上：那个假抽象 2026-07-26 已删（恒返回
/// 日语、从来没有 UI 调用方），守卫 `test/models/target_language_removed_guard_test.dart`
/// 钉着不许复活。这里是**输入法偏好**——有真 UI、真可配置，而且**不进查词流水线**
/// （「查词语言无关、18 种变换表全量加载」那条结论不受影响）。同名不同物，别再合并。
///
/// 各端消费方式（都是「按语言码去匹配系统已装的输入源」，所以自定义语言几乎零成本）：
/// - Android：`TextField.hintLocales`（EditorInfo.hintLocales，API 24+），本文件的
///   [lookupImeHintLocalesOf]。
/// - iOS：`UITextInputMode.activeInputModes` 里按 `primaryLanguage` 前缀匹配。
/// - macOS：`TISCreateInputSourceList` 按 `primaryLanguage` 筛。
/// - Windows：`GetKeyboardLayoutList` 枚举已装 HKL，低 16 位 LANGID 比对。
/// - Linux：ibus/fcitx 引擎名与语言不是一一映射，另行处理。
library;

import 'dart:ui' show Locale;

/// 把 BCP-47 标签解析成 [Locale]。
///
/// 只认「语言[-脚本][-地区]」：`ja` / `zh-Hans` / `ja-JP` / `zh-Hans-CN`（`_` 也当
/// 分隔符收，旧持久化值里有）。认不出来一律返回 null，**绝不猜**——猜错会把用户的
/// 键盘切成另一种语言，比不切更糟。
Locale? lookupImeLocaleOf(String? tag) {
  final String raw = tag?.trim() ?? '';
  if (raw.isEmpty) return null;
  final List<String> parts = raw.split(RegExp('[-_]'));
  final String language = parts.first.toLowerCase();
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) return null;

  String? script;
  String? country;
  for (final String part in parts.skip(1)) {
    if (RegExp(r'^[A-Za-z]{4}$').hasMatch(part)) {
      if (script != null) return null;
      script = part[0].toUpperCase() + part.substring(1).toLowerCase();
    } else if (RegExp(r'^([A-Za-z]{2}|[0-9]{3})$').hasMatch(part)) {
      if (country != null) return null;
      country = part.toUpperCase();
    } else {
      // 扩展子标签（`-x-foo` 之类）：整条作废，宁可不设提示。
      return null;
    }
  }
  return Locale.fromSubtags(
    languageCode: language,
    scriptCode: script,
    countryCode: country,
  );
}

/// 两个语言标签是不是「同一种输入法语言」。
///
/// 规则必须和原生侧一致（Windows `LanguageTagMatchesLangId`、macOS
/// `LookupImeLanguage.matches`、iOS 的 primaryLanguage 前缀匹配），否则设置页会说
/// 「装了」而原生侧找不到、或者反过来：
/// - 主语言相同才算；
/// - 中文要分简繁（装了拼音打不出繁体），标签没说简繁（裸 `zh`）时不挑；
/// - 其它语言不比地区（en-GB 和 en-US 都能打英文）。
bool lookupImeLanguageMatches(String tag, String candidate) {
  final List<String> wanted = tag.trim().toLowerCase().split(RegExp('[-_]'));
  final List<String> other = candidate.trim().toLowerCase().split(
        RegExp('[-_]'),
      );
  if (wanted.first.isEmpty || wanted.first != other.first) return false;
  if (wanted.first != 'zh') return true;
  final int wantedScript = _chineseScript(wanted);
  if (wantedScript == 0) return true;
  return wantedScript == _chineseScript(other);
}

/// 0 = 没说，1 = 简体，2 = 繁体。
int _chineseScript(List<String> subtags) {
  for (final String part in subtags.skip(1)) {
    if (part == 'hans' || part == 'cn' || part == 'sg') {
      return 1;
    }
    if (part == 'hant' || part == 'tw' || part == 'hk' || part == 'mo') {
      return 2;
    }
  }
  return 0;
}

/// 给 Flutter `TextField.hintLocales` 用的值（消费方一般用 `AppModel.lookupImeHintLocales`，
/// 它多带一层偏好就绪判断）。
///
/// 返回 null = 没有偏好；**不返回空 list**——Flutter 的契约里空 list 是「明确表示
/// 不要任何提示」，语义比「用户没设过」强，会压掉输入法自己的记忆。
List<Locale>? lookupImeHintLocalesOf(String? tag) {
  final Locale? locale = lookupImeLocaleOf(tag);
  return locale == null ? null : <Locale>[locale];
}
