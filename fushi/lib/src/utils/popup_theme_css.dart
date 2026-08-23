// 查词弹窗主题 CSS 变量的单一真源。
//
// 三个消费方从同一 ColorScheme 派生同一组弹窗 CSS 变量，此前各自手抄一份并已
// 出现漂移风险（BUG-688 / BUG-736 均由「漏抄一处」引发）：
//   1. AppModel.browserExtensionThemeColors()（浏览器扩展经查词响应 `theme` 字段下发）；
//   2. popup_settings_injection.dart 的 _themeVariablesJs（in-app / app 外弹窗注入体）；
//   3. dictionary_popup_webview.dart 的 _themeVariablesJs（热槽 WebView 主题重注）。
// 本文件收敛「颜色→CSS 字符串」的格式化 helper 与核心变量的取值公式；变量名字面量
// 仍保留在各调用点（多份源码扫描守卫钉死了那些字面量，见
// browser_extension_theme_var_parity_guard_test / popup_dictionary_columns_test 等）。
import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// [c] 的不透明 CSS `rgb(r, g, b)` 串。算法保持 `(分量 * 255.0).round().clamp(0, 255)`
/// 逐字节等价（与历史各手抄版一致），不得改成 `.toARGB32()` 等别的取整路径。
String cssRgb(Color c) => 'rgb(${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)})';

/// spec 2026-07-10 §6 — [c] 的裸 `r, g, b` 三元组，供 popup.css 的
/// `rgba(var(--fushi-card-bg-rgb), var(--fushi-card-bg-alpha))` 组装半透明卡
/// 背景（`--background-color` 是不透明 `rgb()`，纯 CSS 无法给它加 alpha）。
String cssRgbTriplet(Color c) => '${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)}';

/// [c] 的 `rgba(r, g, b, 0.35)` 串——查到词高亮色（primary @0.35 alpha）的固定配方。
String cssRgba035(Color c) => 'rgba(${cssRgbTriplet(c)}, 0.35)';

/// Niratan 对齐（2026-08-23）：弹窗卡面默认**纯白/纯黑**，不再用 MD3 tinted
/// `scheme.surface`。Niratan 的弹窗表面就是 #FFF/#000
/// （DictionaryPopupMaterial.GetOpaqueSurfaceColor），MD3 种子色染出的
/// surface（浅色偏米/偏绿、深色偏灰）正是「我们的弹窗观感发闷」的来源之一。
/// 用户手动指定的词典底色 [override]（overrideDictionaryColor）优先级不变；
/// 四个消费方（AppModel 扩展 theme map、两个 in-app 注入器、热槽 WebView
/// 初始 HTML）统一走本 helper，防再漂移（BUG-688/736 同型教训）。
Color popupCardSurface({required ColorScheme scheme, Color? override}) =>
    override ??
    (scheme.brightness == Brightness.dark
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF));

/// 三个弹窗表面共用的核心主题变量（变量名 → CSS 值，保序）。
///
/// 调用点差异通过参数表达，不在此分支：
/// - [backgroundColor]：`popupCardSurface(...)`（默认纯白/纯黑，词典底色覆盖优先）；
/// - [surfaceContainerHigh]：in-app 两个注入器传 `scheme.surfaceContainerHigh`，
///   浏览器扩展侧历史行为是 `overrideDictionaryColor ?? scheme.surfaceContainerHigh`；
/// - [dictionaryColumns]：`popupDictionaryColumns` 偏好。
/// 扩展独有的 `--fushi-color-scheme` / `--fushi-popup-*` / `--fushi-swipe-close`
/// 与 in-app 独有的 `data-theme` 属性、文档 class 仍留在各调用点。
Map<String, String> buildPopupThemeCssVars({
  required ColorScheme scheme,
  required Color backgroundColor,
  required Color surfaceContainerHigh,
  required int dictionaryColumns,
}) {
  return <String, String>{
    '--fushi-primary-highlight': cssRgba035(scheme.primary),
    '--text-color': cssRgb(scheme.onSurface),
    '--background-color': cssRgb(backgroundColor),
    '--fushi-card-bg-rgb': cssRgbTriplet(backgroundColor),
    '--md-surface-container': cssRgb(scheme.surfaceContainer),
    '--md-surface-container-high': cssRgb(surfaceContainerHigh),
    '--md-on-surface': cssRgb(scheme.onSurface),
    '--md-on-surface-variant': cssRgb(scheme.onSurfaceVariant),
    '--md-outline-variant': cssRgb(scheme.outlineVariant),
    '--md-primary': cssRgb(scheme.primary),
    '--md-on-primary': cssRgb(scheme.onPrimary),
    '--fushi-radius-card': '${FushiRadii.cardValue.toInt()}px',
    '--dict-columns': '$dictionaryColumns',
  };
}
