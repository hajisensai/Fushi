// TODO-895 single source of truth for the dictionary-popup WebView settings
// injection body. Both popup render paths feed the SAME popup assets and end in
// window.renderPopup(). The settings body was previously hand-copied TWICE (in-app
// _pushResults + app-outside buildFrameSettingsJs) and drifted: app-outside lost the
// dictionary font (D1), autoExpandDictionaries (D2), and the clamped/NaN-guarded zoom
// (D3). This builder is the ONE place that emits the shared body; the two call sites
// pass their own PopupSettingsOptions for the legitimate differences (app-outside
// global-lookup class + icon-font override + hidden mine button; in-app sentence i18n
// + instant-scroll + load-more orchestration).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/reader/dictionary_font_css.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:path/path.dart' as p;

/// Call-site-specific knobs for [buildPopupSettingsJs]. Everything that must be
/// IDENTICAL between the in-app popup and the app-outside global-lookup window
/// (theme/font/zoom/flags) is computed inside the builder; only the genuinely
/// different bits are toggled here.
class PopupSettingsOptions {
  const PopupSettingsOptions({
    this.globalLookup = false,
    this.mobileExternal = false,
    this.sentenceDraftEnabled = false,
  });

  /// App-outside (Windows bare-WebView2 global lookup) frame. Adds the
  /// `global-lookup` document class, the monochrome icon-font override, and
  /// hides the `.mine-button` (no card mining outside the app).
  final bool globalLookup;

  /// TODO-1065: the app-OUTSIDE / floating-subtitle popup (popup_main host). Adds
  /// the `mobile-external` document class so popup.css makes the `<html>`
  /// documentElement transparent (`html.mobile-external{background:transparent}`),
  /// killing the opaque full-viewport fill that washed the popup white over its
  /// transparent floating window. Mutually exclusive with [globalLookup] in
  /// practice (desktop bare-WebView2 vs mobile external window); the in-app popup
  /// sets neither.
  final bool mobileExternal;

  /// Whether popup.js should render the sentence-context picker. Currently gated
  /// off in both paths (kSentenceContextPickerEnabled), but the in-app path
  /// computes it from its host callbacks, so it stays a parameter.
  final bool sentenceDraftEnabled;
}

String _cssRgb(Color c) => 'rgb(${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)})';

/// spec 2026-07-10 §6 — the bare `r, g, b` triplet of [c]，供 popup.css 的
/// `rgba(var(--hibiki-card-bg-rgb), var(--hibiki-card-bg-alpha))` 组装半透明卡
/// 背景（`--background-color` 是不透明 `rgb()`，纯 CSS 无法给它加 alpha）。
String _cssRgbTriplet(Color c) => '${(c.r * 255.0).round().clamp(0, 255)}, '
    '${(c.g * 255.0).round().clamp(0, 255)}, '
    '${(c.b * 255.0).round().clamp(0, 255)}';

/// Builds the theme-derived CSS custom properties + `data-theme` (+ the
/// `global-lookup` document class when [globalLookup]). Shared by both paths so
/// the WebView surfaces follow the app ColorScheme identically.
String _themeVariablesJs({
  required AppModel appModel,
  required ThemeData theme,
  required bool globalLookup,
  required bool mobileExternal,
}) {
  final bool isDark = theme.brightness == Brightness.dark;
  final ColorScheme scheme = theme.colorScheme;
  final Color primary = scheme.primary;
  final String primaryRgba =
      'rgba(${(primary.r * 255.0).round().clamp(0, 255)}, '
      '${(primary.g * 255.0).round().clamp(0, 255)}, '
      '${(primary.b * 255.0).round().clamp(0, 255)}, 0.35)';
  final Color bgColor = appModel.overrideDictionaryColor ?? scheme.surface;
  // TODO-1065: mobileExternal tags the doc so popup.css `html.mobile-external`
  // turns the documentElement transparent (external popup washout fix), the
  // mobile analogue of the desktop global-lookup transparent-html rule.
  final String classLine = globalLookup
      ? "document.documentElement.classList.add('global-lookup');\n"
      : (mobileExternal
          ? "document.documentElement.classList.add('mobile-external');\n"
          : '');
  return '''
      $classLine      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--hoshi-primary-highlight', '$primaryRgba');
      document.documentElement.style.setProperty('--text-color', '${_cssRgb(scheme.onSurface)}');
      document.documentElement.style.setProperty('--background-color', '${_cssRgb(bgColor)}');
      document.documentElement.style.setProperty('--hibiki-card-bg-rgb', '${_cssRgbTriplet(bgColor)}');
      document.documentElement.style.setProperty('--md-surface-container', '${_cssRgb(scheme.surfaceContainer)}');
      document.documentElement.style.setProperty('--md-surface-container-high', '${_cssRgb(scheme.surfaceContainerHigh)}');
      document.documentElement.style.setProperty('--md-outline-variant', '${_cssRgb(scheme.outlineVariant)}');
      document.documentElement.style.setProperty('--md-on-surface-variant', '${_cssRgb(scheme.onSurfaceVariant)}');
      document.documentElement.style.setProperty('--md-primary', '${_cssRgb(scheme.primary)}');
      document.documentElement.style.setProperty('--md-on-primary', '${_cssRgb(scheme.onPrimary)}');
      document.documentElement.style.setProperty('--hibiki-radius-card', '${HibikiRadii.cardValue.toInt()}px');
      document.documentElement.style.setProperty('--dict-columns', '${appModel.popupDictionaryColumns}');
''';
}

/// TODO-049 / TODO-895 D1: builds the JS that injects the user's DICTIONARY font
/// as a `<style id="hoshi-dict-font">` element (system family names + inlined
/// `data:` URL `@font-face` for imported files). Returns an empty string when no
/// dictionary font is configured. Shared so the app-outside window applies the
/// SAME font the in-app popup does.
String dictionaryFontStyleJs(AppModel appModel) {
  final ReaderSettings? settings = ReaderHibikiSource.readerSettings;
  if (settings == null) return '';
  final ({String fontFamily, String fontFaces}) css = DictionaryFontCss.build(
    settings.dictionaryFonts,
    allowedDirectories: <String>[
      p.join(appModel.appDirectory.path, 'custom_fonts'),
    ],
  );
  if (css.fontFamily.isEmpty) return '';
  final String styleCss = '${css.fontFaces}\n'
      'html, body { font-family: ${css.fontFamily}, '
      '"Hiragino Sans", "Hiragino Kaku Gothic ProN", sans-serif !important; }';
  final String styleJson = jsonEncode(styleCss);
  return '''
      (function(){
        var el = document.getElementById('hoshi-dict-font');
        if (!el) {
          el = document.createElement('style');
          el.id = 'hoshi-dict-font';
          document.head.appendChild(el);
        }
        el.textContent = $styleJson;
      })();''';
}

/// TODO-867 P3c F1 / TODO-895 D6: the app-outside icon-font override. Forces the
/// monochrome "Segoe UI Symbol" font (which carries the audio/arrow/close glyphs)
/// and DROPS the colour-emoji font. In-app popups never call this (they keep
/// popup.css's default stack).
///
/// BUG-774 — this block USED to also inject `.mine-button{display:none}` on the
/// premise "no mining in the bare window". That premise was retired: TODO-1188
/// wired a full app-external mine path (overlay_bridge_handlers `mineEntry` /
/// `duplicateCheck` / `resolveMineSentence`, natively DEFERRED by the C++ window)
/// and BUG-730 added the clipboard-panel mine sentence, so both the clipboard
/// panel and the selection/overlay window CAN mine — popup.css even bumps
/// `html.global-lookup .mine-button:not(:disabled){opacity:1}` to keep it visible
/// on the translucent surface. The leftover `display:none !important` outlived its
/// premise and silently ate the button in both surfaces; removed so the wired
/// backend is actually reachable.
const String _globalLookupIconFontJs = '''
    (function(){
      var s = document.getElementById('hibiki-overlay-style');
      if (!s) {
        s = document.createElement('style');
        s.id = 'hibiki-overlay-style';
        s.textContent =
          '.audio-button,.glossary-group>summary::before{font-family:"Segoe UI Symbol","Segoe UI",sans-serif !important;}';
        document.head.appendChild(s);
      }
    })();''';

/// BUG-762 修「词典弹窗里长按释义文本弹出系统选择菜单（翻译/复制/分享/全选…）后 app
/// 卡住」：弹窗 WebView（Android 原生平台视图）默认允许原生文本选区（popup.css 全局
/// `-webkit-user-select:text` 且无触屏抑制），长按进入原生选区态 → 系统 ActionMode 浮动
/// 工具栏弹出并接管该区域后续触摸，弹窗关不掉、点击无响应 → 观感「卡死」。查词根本不
/// 依赖原生选区（走 selection.js 的 caretPositionFromPoint + CSS Custom Highlight 程序化
/// 选区），故与阅读器 reader_content_styles.dart 的 TODO-1279 修复同款：粗指针（触屏，
/// `@media (pointer: coarse)`）禁用原生 user-select + iOS 长按 callout，从根上不再进原生
/// 选区态。CSS 层自门控——桌面细指针（Windows 裸 WebView2 全局查词）不受影响，复制/右键
/// 照旧。刻意不放进共享 popup.css（那份还被 content.css 生成器 re-root 进浏览器扩展宿主页，
/// 会误杀扩展在触屏宿主页里选文本；且生成器不支持 @media 嵌套 at-rule 会直接抛错），改由本
/// 注入体以 id 守卫的 `<style>` 幂等注入，只作用于 app 内三种弹窗表面（in-app / 视频 /
/// app 外悬浮），三端 WebView 复用同一注入体，一处全覆盖。
const String _touchNoSelectStyleJs = '''
    (function(){
      var s = document.getElementById('hoshi-popup-touch-noselect');
      if (!s) {
        s = document.createElement('style');
        s.id = 'hoshi-popup-touch-noselect';
        s.textContent =
          '@media (pointer: coarse){html,body,body *{' +
          '-webkit-user-select:none !important;user-select:none !important;' +
          '-webkit-touch-callout:none !important;}}';
        document.head.appendChild(s);
      }
    })();''';

/// BUG-712 ③：静态设置负载的两半（词条行在原模板里插在 head 与 tail 之间）。
/// [combined] 供 in-app 热槽路径做串级比对去重（变了才重发）；head+entries+tail
/// 的拼接顺序与拆分前的单模板逐字节一致，合并调用方（全局查词栈 / 剪贴板面板）
/// 输出不变。
class PopupStaticSettingsJs {
  const PopupStaticSettingsJs({required this.head, required this.tail});

  final String head;
  final String tail;

  String get combined => '$head$tail';
}

/// THE single source of truth for the popup settings injection body. Emits the
/// shared theme vars + dictionary font + content zoom + every `window.*` flag
/// (audio, dedup/harmonic, collapse + autoExpandDictionaries, collapsed/hidden
/// names, lookupEntries/kanjiResults, dictionary styles + custom CSS). Each call
/// site appends its own reset hooks + window.renderPopup() AFTER this body, so the
/// body intentionally does NOT call renderPopup itself.
///
/// [globalLookup] frames also receive the `global-lookup` class (in the theme vars)
/// and the monochrome icon-font override.
///
/// BUG-712 ③：本函数保持原签名与逐字节原输出（= static.head + entries + static.tail），
/// 供全局查词栈 / 剪贴板面板整帧渲染继续使用；in-app 热槽路径改用
/// [buildPopupStaticSettingsJs] + [buildPopupEntriesJs] 分开注入，静态段串级比对
/// 去重（热槽 WebView 的 window.* 状态跨渲染持久，重复注入是纯带宽/解析浪费）。
String buildPopupSettingsJs({
  required AppModel appModel,
  required ThemeData theme,
  required DictionarySearchResult result,
  required PopupSettingsOptions options,
}) {
  final PopupStaticSettingsJs staticJs = buildPopupStaticSettingsJs(
    appModel: appModel,
    theme: theme,
    options: options,
  );
  return '${staticJs.head}${buildPopupEntriesJs(result)}${staticJs.tail}';
}

/// 每次查词都会变化的动态负载：词条与汉字卡结果。与静态段分开注入后，热路径
/// 每次只发这一段 + renderPopup 调用。
String buildPopupEntriesJs(DictionarySearchResult result) {
  final String entriesJson = result.popupJson ??
      DictionaryPopupWebViewState.buildLookupEntriesJson(result);
  final String kanjiResultsJson = jsonEncode(
    result.kanjiResults.map((HoshiKanjiResult k) => k.toMap()).toList(),
  );
  return '''    try { window.lookupEntries = $entriesJson; } catch(e) { window.lookupEntries = []; }
    try { window.kanjiResults = $kanjiResultsJson; } catch(e) { window.kanjiResults = []; }
''';
}

/// 静态设置负载（主题变量/词典字体/图标字体覆盖/zoom/开关/名单/词典样式/自定义
/// CSS）：只随主题、设置、词典集变化，不随查词变化。in-app 路径对 [PopupStaticSettingsJs.combined]
/// 做串级比对，变了才随下一次推送重发。
PopupStaticSettingsJs buildPopupStaticSettingsJs({
  required AppModel appModel,
  required ThemeData theme,
  required PopupSettingsOptions options,
}) {
  final String themeVarsJs = _themeVariablesJs(
    appModel: appModel,
    theme: theme,
    globalLookup: options.globalLookup,
    mobileExternal: options.mobileExternal,
  );
  final String fontStyleJs = dictionaryFontStyleJs(appModel);
  final double zoom = DictionaryPopupWebViewState.popupContentZoom(
    appUiScale: appModel.appUiScale,
    dictionaryFontSize: appModel.dictionaryFontSize,
  );

  final String stylesJson = DictionaryPopupWebViewState.dictionaryStylesJson();
  final String collapsedNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isCollapsed(appModel.targetLanguage))
      .map((d) => d.name)
      .toList());
  final String hiddenNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isHidden(appModel.targetLanguage))
      .map((d) => d.name)
      .toList());

  final String iconFontJs = options.globalLookup ? _globalLookupIconFontJs : '';

  final String head = '''
    $themeVarsJs
    $fontStyleJs
    $iconFontJs
    $_touchNoSelectStyleJs
    document.documentElement.style.zoom = '${zoom.toStringAsFixed(4)}';
    // TODO-1353: Ctrl+滚轮缩放查词内容需要在 JS 侧就地重算 zoom（即时反馈），故把
    // 当前「界面大小」系数与「词典字号」暴露给弹窗（与上面 zoom 同源，每次注入刷新为
    // 最新真值）。滚轮监听器（dictionary_popup_webview 的 _zoomWheelJs，onLoadStop 装一次）
    // 读这两个全局算新字号 → 立即 documentElement.style.zoom，再回调 Dart 持久化。
    window.__hoshiPopupUiScale = ${appModel.appUiScale};
    window.__hoshiPopupFontSize = ${appModel.dictionaryFontSize};
    window.audioSources = ${jsonEncode(appModel.enabledAudioSources)};
    window.needsAudio = true;
    window.i18nNoAudioAvailable = ${jsonEncode(t.popup_no_audio_available)};
    window.sentenceDraftEnabled = ${options.sentenceDraftEnabled};
    window._noResultsMessage = ${jsonEncode(t.no_search_results)};
    window.embedMedia = true;
    window.deduplicatePitchAccents = ${appModel.deduplicatePitchAccents};
    window.harmonicFrequency = ${appModel.harmonicFrequency};
    window.showExpressionTags = ${appModel.showExpressionTags};
    window.collapseDictionaries = ${appModel.collapseDictionaries};
    window.autoExpandDictionaries = ${appModel.popupAutoExpandDictionaries};
    window.collapsedDictionaryNames = $collapsedNames;
    window.hiddenDictionaryNames = $hiddenNames;
''';
  final String tail = '''    window.dictionaryStyles = $stylesJson;
    window.globalDictCSS = ${jsonEncode(appModel.globalDictCSS)};
    window.customDictCSS = ${jsonEncode(appModel.customDictCSS)};
''';
  return PopupStaticSettingsJs(head: head, tail: tail);
}
