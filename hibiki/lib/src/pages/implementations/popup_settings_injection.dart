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
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/popup_theme_css.dart';
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

/// Builds the theme-derived CSS custom properties + `data-theme` (+ the
/// `global-lookup` document class when [globalLookup]). Shared by both paths so
/// the WebView surfaces follow the app ColorScheme identically.
///
/// 变量取值统一来自 [buildPopupThemeCssVars]（与浏览器扩展的
/// `browserExtensionThemeColors()` 同一真源）；变量名字面量保留在本模板里，
/// 供源码扫描守卫（parity guard 等）钉住「in-app 注入了哪些变量」。
String _themeVariablesJs({
  required AppModel appModel,
  required ThemeData theme,
  required bool globalLookup,
  required bool mobileExternal,
}) {
  final bool isDark = theme.brightness == Brightness.dark;
  final ColorScheme scheme = theme.colorScheme;
  final Map<String, String> vars = buildPopupThemeCssVars(
    scheme: scheme,
    backgroundColor: appModel.overrideDictionaryColor ?? scheme.surface,
    surfaceContainerHigh: scheme.surfaceContainerHigh,
    dictionaryColumns: appModel.popupDictionaryColumns,
  );
  // TODO-1065: mobileExternal tags the doc so popup.css `html.mobile-external`
  // turns the documentElement transparent (external popup washout fix), the
  // mobile analogue of the desktop global-lookup transparent-html rule.
  final String classLine = globalLookup
      ? "document.documentElement.classList.add('global-lookup');\n"
      : (mobileExternal
          ? "document.documentElement.classList.add('mobile-external');\n"
          : '');
  // 墨水屏模式：给 <html> 挂 eink class（popup.css 末尾的 html.eink 覆盖块吃它，
  // 纯黑白/方角/实线边框/关过渡）。用 toggle 而非 add——in-app 热槽 WebView 跨渲染
  // 持久，开关关掉后重注入必须能把 class 摘掉。标志从传入的 ThemeData 扩展读
  // （HibikiEinkTheme，_buildThemeData 挂上），不走 appModel.themeNotifier——
  // 本函数在弹窗 widget 测试里会被未 initialise 的裸 AppModel 调到（late
  // themeNotifier 未初始化），theme 才是这里已有的真相源。
  final bool eink = theme.extension<HibikiEinkTheme>()?.einkMode ?? false;
  final String einkLine =
      "document.documentElement.classList.toggle('eink', $eink);\n";
  return '''
      $classLine      $einkLine      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--hoshi-primary-highlight', '${vars['--hoshi-primary-highlight']}');
      document.documentElement.style.setProperty('--text-color', '${vars['--text-color']}');
      document.documentElement.style.setProperty('--background-color', '${vars['--background-color']}');
      document.documentElement.style.setProperty('--hibiki-card-bg-rgb', '${vars['--hibiki-card-bg-rgb']}');
      document.documentElement.style.setProperty('--md-surface-container', '${vars['--md-surface-container']}');
      document.documentElement.style.setProperty('--md-surface-container-high', '${vars['--md-surface-container-high']}');
      document.documentElement.style.setProperty('--md-outline-variant', '${vars['--md-outline-variant']}');
      document.documentElement.style.setProperty('--md-on-surface-variant', '${vars['--md-on-surface-variant']}');
      document.documentElement.style.setProperty('--md-primary', '${vars['--md-primary']}');
      document.documentElement.style.setProperty('--md-on-primary', '${vars['--md-on-primary']}');
      document.documentElement.style.setProperty('--hibiki-radius-card', '${vars['--hibiki-radius-card']}');
      document.documentElement.style.setProperty('--dict-columns', '${vars['--dict-columns']}');
''';
}

/// TODO-049 / TODO-895 D1: builds the JS that injects the user's DICTIONARY font
/// as a `<style id="hoshi-dict-font">` element (system family names + inlined
/// `data:` URL `@font-face` for imported files). Returns an empty string when no
/// dictionary font is configured. Shared so the app-outside window applies the
/// SAME font the in-app popup does.
String dictionaryFontStyleJs(AppModel appModel) {
  // BUG: `ReaderHibikiSource.readerSettings` is only populated while a book /
  // reader is open. In the app-external clipboard-lookup flow (VN / game, no
  // book), it is null, so the user's configured dictionary font was never
  // injected and popup.css's hard-coded "Hiragino Sans" fell back to the system
  // font. The dictionary font list is persisted in the DB (`dict_fonts`), so
  // read it through a DB-backed ReaderSettings when no reader is live — the
  // overlay then applies the SAME font whether or not a book is open.
  final ReaderSettings settings =
      ReaderHibikiSource.readerSettings ?? ReaderSettings(appModel.database);
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

// BUG-926：撤回 BUG-762 引入的触屏全量禁选注入（旧常量在粗指针 media query 下对整棵
// body 子树强制 user-select:none !important）。
// 该规则以 !important 碾平了 popup.css 已精细分区的选区设计（正文
// `-webkit-user-select:text`，交互 chrome=按钮/标签/音高行 逐元素 `none`），导致触屏
// 上词典释义**无法选中→无法复制**（1.2.0 用户报「查词界面文字无法复制」）。桌面细指针
// 因 `pointer:coarse` 不命中而幸免，故只在触屏暴露。
//
// BUG-762 担心的「长按释义→系统 ActionMode 接管→弹窗关不掉」其实已被 popup.js 的
// document click 处理器优雅化解：`__hibikiSel().toString().length>0` 时先 `removeAllRanges()`
// 清原生选区再 return（点一下取消选择、再点才关窗），加上弹窗 chrome 的关闭按钮/横拖关
// 都在 WebView 之外、不受 ActionMode 阻挡——始终有退路。用整块 CSS 禁选去修一个已被 JS
// 处理的标准选中态，是修在了错误的层，代价是牺牲词典核心能力「复制释义」。
//
// 复制释义在触屏是刚需（安卓走 ActionMode 复制、iOS 走长按 callout 复制），恢复方式=
// 不再注入任何触屏 user-select/callout 抑制，回落到 popup.css 的跨平台逐元素选区分区
// （正文可选、chrome 不可选，无平台门控，触屏同样生效）。阅读器 reader_content_styles
// TODO-1279 的同款抑制**保留不动**——阅读器复制本就桌面门控（Ctrl+C / 右键均
// isWindowsPlatform），触屏确无原生选区消费者，正当性成立；弹窗恰相反。

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
    document.documentElement.style.zoom = '${zoom.toStringAsFixed(4)}';
    // TODO-1353: Ctrl+滚轮缩放查词内容需要在 JS 侧就地重算 zoom（即时反馈），故把
    // 当前「界面大小」系数与「词典字号」暴露给弹窗（与上面 zoom 同源，每次注入刷新为
    // 最新真值）。滚轮监听器（dictionary_popup_webview 的 _zoomWheelJs，onLoadStop 装一次）
    // 读这两个全局算新字号 → 立即 documentElement.style.zoom，再回调 Dart 持久化。
    window.__hoshiPopupUiScale = ${appModel.appUiScale};
    window.__hoshiPopupFontSize = ${appModel.dictionaryFontSize};
    window.audioSources = ${jsonEncode(appModel.enabledAudioSources)};
    window.needsAudio = true;
    window.lookupAudioVolume = ${ReaderHibikiSource.instance.lookupAudioVolumeGain.clamp(0.0, 1.0).toStringAsFixed(4)};
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
