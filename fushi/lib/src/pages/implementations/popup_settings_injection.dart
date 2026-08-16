// TODO-895 single source of truth for the dictionary-popup WebView settings
// injection body. Both popup render paths feed the SAME popup assets and end in
// window.renderPopup(). The settings body was previously hand-copied TWICE (in-app
// _pushResults + app-outside buildFrameSettingsJs) and drifted: app-outside lost the
// dictionary font (D1), autoExpandRows (D2), and the clamped/NaN-guarded zoom
// (D3). This builder is the ONE place that emits the shared body; the two call sites
// pass their own PopupSettingsOptions for the legitimate differences (app-outside
// global-lookup class + icon-font override + hidden mine button; in-app sentence i18n
// + instant-scroll + load-more orchestration).

import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/popup_theme_css.dart';
import 'package:fushi/src/reader/dictionary_font_css.dart';
import 'package:fushi/src/reader/dictionary_language_css.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
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
  /// `global-lookup` document class and the monochrome icon-font override, and
  /// is what gates the popup keyboard-binding injection
  /// (`window.__fushiPopupKeyBindings`; in-app hosts get an explicit `null`).
  ///
  /// It does NOT hide `.mine-button` any more — this doc used to claim "no card
  /// mining outside the app", but that premise was retired by TODO-1188 /
  /// BUG-730 and the `display:none` was removed in BUG-774 (see the long note on
  /// `_globalLookupIconFontJs` below). Both app-outside surfaces CAN mine.
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
  // （FushiEinkTheme，_buildThemeData 挂上），不走 appModel.themeNotifier——
  // 本函数在弹窗 widget 测试里会被未 initialise 的裸 AppModel 调到（late
  // themeNotifier 未初始化），theme 才是这里已有的真相源。
  final bool eink = theme.extension<FushiEinkTheme>()?.einkMode ?? false;
  final String einkLine =
      "document.documentElement.classList.toggle('eink', $eink);\n";
  return '''
      $classLine      $einkLine      document.documentElement.setAttribute('data-theme', '${isDark ? 'dark' : 'light'}');
      document.documentElement.style.setProperty('--fushi-primary-highlight', '${vars['--fushi-primary-highlight']}');
      document.documentElement.style.setProperty('--text-color', '${vars['--text-color']}');
      document.documentElement.style.setProperty('--background-color', '${vars['--background-color']}');
      document.documentElement.style.setProperty('--fushi-card-bg-rgb', '${vars['--fushi-card-bg-rgb']}');
      document.documentElement.style.setProperty('--md-surface-container', '${vars['--md-surface-container']}');
      document.documentElement.style.setProperty('--md-surface-container-high', '${vars['--md-surface-container-high']}');
      document.documentElement.style.setProperty('--md-outline-variant', '${vars['--md-outline-variant']}');
      document.documentElement.style.setProperty('--md-on-surface-variant', '${vars['--md-on-surface-variant']}');
      document.documentElement.style.setProperty('--md-primary', '${vars['--md-primary']}');
      document.documentElement.style.setProperty('--md-on-primary', '${vars['--md-on-primary']}');
      document.documentElement.style.setProperty('--fushi-radius-card', '${vars['--fushi-radius-card']}');
      document.documentElement.style.setProperty('--dict-columns', '${vars['--dict-columns']}');
''';
}

/// TODO-049 / TODO-895 D1: builds the JS that injects the user's DICTIONARY font
/// as a `<style id="fushi-dict-font">` element (system family names + inlined
/// `data:` URL `@font-face` for imported files). Returns an empty string when no
/// dictionary font is configured. Shared so the app-outside window applies the
/// SAME font the in-app popup does.
String dictionaryFontStyleJs(AppModel appModel) =>
    _dictionaryFontStyleJsMemo(appModel).js;

/// BUG-717 ③：[dictionaryFontStyleJs] 最终产物的进程内 memo。
///
/// 导入字体走 `data:` URL 内联，最终 JS 串是 MB 级；此前每次查词都重建
/// （join + jsonEncode 全串转义扫描 + 模板插值 = 数遍 MB 拷贝，全在 UI isolate），
/// 而 in-app 热槽的串级比对随后把它整个丢弃。memo 键 =
/// [DictionaryFontCss.fontListFingerprint]（启用条目的 (name, path, mtime, size)
/// 指纹 + 白名单目录，与 build 内部 data:URL 缓存同键同失效语义）：换字体 /
/// 停启用 / 文件原地覆盖 / 导入换路径 / 目录变化都会换键重建；命中时返回同一
/// 实例，零拷贝。瞬时读盘失败（[DictionaryFontCss.inlineFailureCount] 变化）的
/// 降级产物不进 memo，下次查词自然重试。
String? _fontStyleJsMemoKey;
String _fontStyleJsMemoValue = '';

({String cacheKey, String js}) _dictionaryFontStyleJsMemo(AppModel appModel) {
  // BUG: `ReaderFushiSource.readerSettings` is only populated while a book /
  // reader is open. In the app-external clipboard-lookup flow (VN / game, no
  // book), it is null, so the user's configured dictionary font was never
  // injected and popup.css's hard-coded "Hiragino Sans" fell back to the system
  // font. The dictionary font list is persisted in the DB (`dict_fonts`), so
  // read it through a DB-backed ReaderSettings when no reader is live — the
  // overlay then applies the SAME font whether or not a book is open.
  // Prefer the live reader's settings; otherwise a DB-backed ReaderSettings so
  // the persisted dictionary font list still applies with no book open. Only
  // touch `appModel.database` when it is actually open — early / test seams leave
  // it uninitialised and reading it would throw LateInitializationError. When
  // unavailable, fall back to no injected font (pre-fix behaviour); in the real
  // app-external lookup flow the DB is always open by then, so the font applies.
  final ReaderSettings? settings = ReaderFushiSource.readerSettings ??
      (appModel.isDatabaseReady ? ReaderSettings(appModel.database) : null);
  if (settings == null) return const (cacheKey: 'no-settings', js: '');
  final List<Map<String, dynamic>> fonts = settings.dictionaryFonts;
  final List<String> allowedDirectories = <String>[
    p.join(appModel.appDirectory.path, 'custom_fonts'),
  ];
  // 内容语言字体链：词典名 -> 释义语言。memo 键必须带上它，否则用户在词典设置里
  // 改了语言、字体列表没变 -> 命中旧 memo -> 改了不生效。
  // `dictRepo` 是 late 字段，且 `_databaseOpened` 先于它置位，所以这里不能只看
  // 上面那个 settings 判空——初始化早期 / 测试 seam 会命中「DB 就绪但词典仓库还
  // 没建」的窗口，直接读会抛 LateInitializationError（与上面注释说的同一个坑）。
  // 未就绪时退化成空列表：只出兜底链，不做 per-dictionary 分流，不崩。
  final List<DictionaryLanguageEntry> dictionaryLanguages =
      appModel.isDictionaryRepoReady
          ? <DictionaryLanguageEntry>[
              for (final Dictionary d in appModel.dictionaries)
                DictionaryLanguageEntry(
                  name: d.name,
                  glossaryLanguage: d.effectiveTargetLanguage,
                ),
            ]
          : const <DictionaryLanguageEntry>[];
  final String languageFingerprint = dictionaryLanguages
      .map((DictionaryLanguageEntry e) => '${e.name}=${e.glossaryLanguage}')
      .join('|');
  final String cacheKey = '${DictionaryFontCss.fontListFingerprint(
    fonts,
    allowedDirectories: allowedDirectories,
  )}|$languageFingerprint|${defaultTargetPlatform.name}';
  if (cacheKey == _fontStyleJsMemoKey) {
    return (cacheKey: cacheKey, js: _fontStyleJsMemoValue);
  }
  final int inlineFailuresBefore = DictionaryFontCss.inlineFailureCount;
  final ({String fontFamily, String fontFaces, List<String> families}) css =
      DictionaryFontCss.build(
    fonts,
    allowedDirectories: allowedDirectories,
  );
  String js = '';
  // 语言分流 CSS 现在**总是**产出（哪怕用户没配任何词典字体）——popup.css 的
  // 内建链只写了 macOS 的 Hiragino，Windows/Android/Linux 上一个存在的 CJK 家族
  // 都没有，直接掉进 sans-serif，于是由系统 locale 决定 CJK 字形（中文系统上日文
  // 词条渲染成中文字形）。这与「用户是否配了自定义字体」无关。
  final String languageCss = dictionaryLanguageFontCss(
    customFamilies: css.families,
    dictionaries: dictionaryLanguages,
    platform: defaultTargetPlatform,
  );
  if (languageCss.isNotEmpty || css.fontFaces.isNotEmpty) {
    final String styleCss = '${css.fontFaces}\n$languageCss';
    final String styleJson = jsonEncode(styleCss);
    // popup.js 的 dictionaryLanguageOf 读这张表，给 structured content 的逐节点
    // lang 标注一个权威来源——没有它，纯汉字的中文释义会被字符检测判成 'ja'
    // （isStringPartiallyJapanese 把汉字算日文），再被 :lang(ja) 的日文链接管。
    final String languageMapJson = jsonEncode(<String, String>{
      for (final DictionaryLanguageEntry e in dictionaryLanguages)
        if ((e.glossaryLanguage ?? '').isNotEmpty) e.name: e.glossaryLanguage!,
    });
    js = '''
      (function(){
        window.__fushiDictionaryLanguages = $languageMapJson;
        var el = document.getElementById('fushi-dict-font');
        if (!el) {
          el = document.createElement('style');
          el.id = 'fushi-dict-font';
          document.head.appendChild(el);
        }
        el.textContent = $styleJson;
      })();''';
  }
  if (DictionaryFontCss.inlineFailureCount == inlineFailuresBefore) {
    _fontStyleJsMemoKey = cacheKey;
    _fontStyleJsMemoValue = js;
  }
  return (cacheKey: cacheKey, js: js);
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

/// BUG-1139：**app 外**两个裸 WebView2 表面（瞬态查词覆盖窗 + 常驻剪贴板面板）的
/// Ctrl+滚轮内容缩放。in-app 弹窗有自己的一份（dictionary_popup_webview 的
/// `_zoomWheelJs`，就地改 `documentElement.style.zoom` 拿即时反馈），app 外**没有**，
/// 于是 Ctrl+滚轮一路落到 WebView2 自带的页面缩放上——而覆盖窗整条几何链（host 报的
/// bbox/shellRects、Dart 的窗口物理尺寸、C++ 的 window region）全按 zoom=1 的 CSS px
/// 算，ZoomFactor 不在其中任何一环，内容放大而窗口/region 不变 → 卡片被窗口边缘切掉、
/// 露出底下的应用。原生缩放已在 `global_lookup_window.cpp ConfigureWebView` 关掉，
/// 这里把 Ctrl+滚轮接回**唯一真值**「词典字号」。
///
/// 与 in-app 的关键差异（有意为之）：这里**不在 JS 侧就地改 zoom**，而是走 Dart 改
/// 「词典字号」这一唯一真值 → 整栈重渲，避免 JS 与 Dart 两处各写一份 zoom。代价是
/// 每档多一次 Dart 往返（约 1~2 帧）。
///
/// 注意这里生效的是 CSS zoom 而非按字号重排：重渲后字号最终落到本文件下方那行
/// `documentElement.style.zoom`，本仓没有任何一处用 dictionaryFontSize 生成
/// font-size CSS。几何链能跟上是因为 BUG-1139 ③ —— host 的 measureContentHeight
/// （global_lookup_host.js 的 frameContentZoom）把 CSS `zoom` 下未乘 z 的 layout px
/// 换算回 host CSS px，窗口高度与 window region 才对得上内容的视觉高度。
///
/// 步进本身不在 JS 里算：只回传**净档数**（rAF 内合帧累加，一次快滚不会打出十几次
/// 往返），夹紧与步长仍归 Dart 的 `steppedPopupZoomFontSize` / `clampPopupZoomFontSize`
/// 单一同源（TODO-1353 已有守卫），JS 侧不再镜像一份 8..72 边界。
/// `__fushiZoomWheelInstalled` 与 in-app 那份同名：同一个 realm 永远只装一套。
const String _globalLookupZoomWheelJs = '''
    (function(){
      if (window.__fushiZoomWheelInstalled) return;
      window.__fushiZoomWheelInstalled = true;
      var pendingSteps = 0;
      var flushScheduled = false;
      function flushZoomSteps(){
        flushScheduled = false;
        var steps = pendingSteps;
        pendingSteps = 0;
        if (!steps) return;
        try {
          window.flutter_inappwebview.callHandler('popupZoomFontStep', steps);
        } catch (err) {}
      }
      window.addEventListener('wheel', function(e){
        if (!e.ctrlKey) return;
        if (!e.deltaY) return;
        e.preventDefault();
        pendingSteps += (e.deltaY < 0 ? 1 : -1);
        if (flushScheduled) return;
        flushScheduled = true;
        if (typeof requestAnimationFrame === 'function') {
          requestAnimationFrame(flushZoomSteps);
        } else {
          setTimeout(flushZoomSteps, 16);
        }
      }, { passive: false });
    })();''';

// BUG-926：撤回 BUG-762 引入的触屏全量禁选注入（旧常量在粗指针 media query 下对整棵
// body 子树强制 user-select:none !important）。
// 该规则以 !important 碾平了 popup.css 已精细分区的选区设计（正文
// `-webkit-user-select:text`，交互 chrome=按钮/标签/音高行 逐元素 `none`），导致触屏
// 上词典释义**无法选中→无法复制**（1.2.0 用户报「查词界面文字无法复制」）。桌面细指针
// 因 `pointer:coarse` 不命中而幸免，故只在触屏暴露。
//
// BUG-762 担心的「长按释义→系统 ActionMode 接管→弹窗关不掉」其实已被 popup.js 的
// document click 处理器优雅化解：`__fushiSel().toString().length>0` 时先 `removeAllRanges()`
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
/// head+entries+tail 的拼接顺序与拆分前的单模板逐字节一致，合并调用方
/// （全局查词栈 / 剪贴板面板）输出不变。
///
/// BUG-717 ③：[revision] 是产物的单调版本号——[buildPopupStaticSettingsJs] 每次
/// **真正重建**时全局 +1，memo 命中返回同一实例（同 revision）。in-app 热槽路径
/// 用 revision 整数比较代替原来的 [combined] MB 级全串比较判断「静态段是否要
/// 重发」，也不再常驻整串副本。
class PopupStaticSettingsJs {
  const PopupStaticSettingsJs({
    required this.head,
    required this.tail,
    required this.revision,
  });

  final String head;
  final String tail;

  /// 单调递增的产物版本：同 revision ⇒ 同实例 ⇒ 同内容。只由
  /// [buildPopupStaticSettingsJs] 分配。
  final int revision;

  String get combined => '$head$tail';
}

/// THE single source of truth for the popup settings injection body. Emits the
/// shared theme vars + dictionary font + content zoom + every `window.*` flag
/// (audio, dedup/harmonic, collapse + autoExpandRows, collapsed/hidden
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
    result.kanjiResults.map((FushiKanjiResult k) => k.toMap()).toList(),
  );
  return '''    try { window.lookupEntries = $entriesJson; } catch(e) { window.lookupEntries = []; }
    try { window.kanjiResults = $kanjiResultsJson; } catch(e) { window.kanjiResults = []; }
''';
}

/// 查词弹窗「上/下一个词条」的滚轮绑定 JSON（注入成 `window.__fushiEntryWheelBindings`）。
///
/// 这两个动作的执行体在 popup.js —— 弹窗内容是 WebView，滚轮事件先到它的 JS，Dart
/// 侧根本收不到（也不该收：只有指针真在弹窗内才算数）。所以「可改键」这件事就是把
/// 注册表里的绑定翻译成 JS 能直接比对的形状：
///
/// ```json
/// {"next":[{"dir":"down","mods":["alt"]}],"prev":[{"dir":"up","mods":["alt"]}]}
/// ```
///
/// `dir` 取 `WheelEvent.deltaY` 的符号，`mods` 是必须**恰好**按下的修饰键集合
/// （popup.js 侧全等比对，Alt+滚轮绝不会被 Ctrl+Alt+滚轮误触）。绑定为空时发空表，
/// popup.js 据此关掉该方向（而不是回退到默认，否则用户清空绑定等于没清）。
String popupEntryWheelBindingsJson(
  FushiShortcutRegistry registry,
  TargetPlatform platform,
) {
  // 注册表还没装载时（弹窗进程的精简初始化早于 loadShortcutRegistry，或测试里的
  // 裸 registry）每个动作都读到空绑定 —— 而空表在 popup.js 那边的语义是「用户关掉
  // 了这个方向」，直接下发会让 Alt+滚轮静默失效。这种情况下回落到平台默认表。
  final Map<ShortcutAction, ShortcutBindingSet>? fallback =
      registry.isLoaded ? null : ShortcutDefaults.forPlatform(platform);
  List<WheelBinding> bindingsOf(ShortcutAction action) => fallback == null
      ? registry.bindingsFor(action).wheelBindings
      : (fallback[action]?.wheelBindings ?? const <WheelBinding>[]);
  List<Map<String, Object>> encode(ShortcutAction action) =>
      <Map<String, Object>>[
        for (final WheelBinding b in bindingsOf(action))
          <String, Object>{
            'dir': b.direction == WheelDirection.up ? 'up' : 'down',
            'mods': b.modifiers
                .map((ModifierKey m) => m.label.toLowerCase())
                .toList(growable: false)
              ..sort(),
          },
      ];
  return jsonEncode(<String, Object>{
    'next': encode(ShortcutAction.popupNextEntry),
    'prev': encode(ShortcutAction.popupPrevEntry),
  });
}

/// 一个逻辑键在 JS `KeyboardEvent.key` 里的名字（小写归一）。
///
/// 两边各自的命名体系要对齐：Flutter 的 `keyLabel` 给的是人读的标签（`Arrow Left`、
/// `Enter`、字母是大写 `A`），JS 给的是 `ArrowLeft` / `Enter` / `a`。规则就两条——
/// 全小写 + 去掉空格，两边就重合了。空格键是唯一的例外（`keyLabel` 是 `' '`，去空格
/// 后会变成空串），显式映射成 `space`，popup.js 侧对 `e.key === ' '` 做同样的映射。
String _webKeyName(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return 'space';
  return key.keyLabel.toLowerCase().replaceAll(' ', '');
}

/// 查词弹窗 scope 的**键盘**绑定 JSON（注入成 `window.__fushiPopupKeyBindings`）。
///
/// 形状与 [popupEntryWheelBindingsJson] 同构，只是把 `dir` 换成 `key`：
///
/// ```json
/// {"mine":[{"key":"enter","mods":["ctrl"]}],"next":[],"prev":[]}
/// ```
///
/// 覆盖本 scope **全部三个动作**（制卡 + 上/下一个词条），而不只是制卡——因为
/// [ShortcutScope.channels] 是按 scope 而非按 action 开通道的：只要这个 scope 开了键盘，
/// 设置页就会给它名下每个动作都渲染出「添加键盘快捷键」入口。若只有制卡真能用，词条导航
/// 那两个入口就成了「能配、按了没反应」的死绑定（`shortcut_channel_wiring_guard_test`
/// 的文件头把这种情况称为「比压根没有这个选项更糟」）。故三个动作同表下发、popup.js 统一
/// 分派。词条导航的键盘默认为空（它默认走 Alt+滚轮），但用户可以在设置里绑上。
///
/// `mods` 是必须**恰好**按下的修饰键集合（popup.js 侧全等比对，Ctrl+Enter 绝不会被
/// Ctrl+Shift+Enter 误触）。空表 = 未绑/用户清空 → popup.js 关掉该动作的键盘触发（而不是
/// 回退默认，否则「清空」等于没清）。注册表未装载时回落平台默认，理由同滚轮那条。
String popupKeyBindingsJson(
  FushiShortcutRegistry registry,
  TargetPlatform platform,
) {
  final Map<ShortcutAction, ShortcutBindingSet>? fallback =
      registry.isLoaded ? null : ShortcutDefaults.forPlatform(platform);
  List<InputBinding> bindingsOf(ShortcutAction action) => fallback == null
      ? registry.bindingsFor(action).keyboardBindings
      : (fallback[action]?.keyboardBindings ?? const <InputBinding>[]);
  List<Map<String, Object>> encode(ShortcutAction action) =>
      <Map<String, Object>>[
        for (final InputBinding b in bindingsOf(action))
          <String, Object>{
            'key': _webKeyName(b.key),
            'mods': b.modifiers
                .map((ModifierKey m) => m.label.toLowerCase())
                .toList(growable: false)
              ..sort(),
          },
      ];
  return jsonEncode(<String, Object>{
    'mine': encode(ShortcutAction.popupMineEntry),
    'next': encode(ShortcutAction.popupNextEntry),
    'prev': encode(ShortcutAction.popupPrevEntry),
  });
}

/// BUG-717 ③：[buildPopupStaticSettingsJs] 的产物 memo（按 options 组合分槽，
/// in-app / mobile-external / global-lookup 三类调用方互不冲刷）。命中判据是
/// 产物的**全部输入**的廉价投影：小串直接 ==（Dart == 先走 identical 短路）、
/// 词典样式 JSON 用 identical（[DictionaryPopupWebViewState.dictionaryStylesJson]
/// 以 FushiDicts.dictionaryStyles 的 map 实例身份缓存，内容变 ⇒ 新实例）、MB 级
/// 字体串用其指纹键。任一输入变化 ⇒ 重建 + 新 revision（宁可失效过度）：
///   - 换字体：fontCacheKey（(name,path,mtime,size) 指纹）；
///   - 改主题（明暗/取色/eink/词典列数/覆盖底色）：themeVarsJs 小串；
///   - 改偏好（zoom 输入/滚轮速度/绑定/音源/音量/开关/折叠隐藏名单/自定义 CSS）：
///     各自的标量或小串；
///   - 切语言：localeTag（head 内嵌全部 i18n 文案）；
///   - 换词典集：stylesJson 身份 + 折叠/隐藏名单。
class _PopupStaticSettingsMemo {
  const _PopupStaticSettingsMemo({
    required this.themeVarsJs,
    required this.fontCacheKey,
    required this.appUiScale,
    required this.dictionaryFontSize,
    required this.popupWheelSpeed,
    required this.wheelBindingsJson,
    required this.audioSourcesJson,
    required this.lookupAudioVolume,
    required this.localeTag,
    required this.deduplicatePitchAccents,
    required this.harmonicFrequency,
    required this.showExpressionTags,
    required this.collapseDictionaries,
    required this.autoExpandRows,
    required this.collapsedNames,
    required this.hiddenNames,
    required this.stylesJson,
    required this.globalDictCSS,
    required this.customDictCSSJson,
    required this.product,
  });

  final String themeVarsJs;
  final String fontCacheKey;
  final double appUiScale;
  final double dictionaryFontSize;
  final double popupWheelSpeed;
  final String wheelBindingsJson;
  final String audioSourcesJson;
  final String lookupAudioVolume;
  final String localeTag;
  final bool deduplicatePitchAccents;
  final bool harmonicFrequency;
  final bool showExpressionTags;
  final bool collapseDictionaries;
  final int autoExpandRows;
  final String collapsedNames;
  final String hiddenNames;
  final String stylesJson;
  final String globalDictCSS;
  final String customDictCSSJson;
  final PopupStaticSettingsJs product;
}

final Map<String, _PopupStaticSettingsMemo> _staticSettingsMemo =
    <String, _PopupStaticSettingsMemo>{};
int _staticSettingsRevision = 0;

/// 测试专用：清空本文件的进程内 memo（字体注入串 + 静态设置产物），避免用例间
/// 互相污染。revision 计数不重置（单调性是契约）。
@visibleForTesting
void debugResetPopupSettingsInjectionCaches() {
  _fontStyleJsMemoKey = null;
  _fontStyleJsMemoValue = '';
  _staticSettingsMemo.clear();
}

/// 静态设置负载（主题变量/词典字体/图标字体覆盖/zoom/开关/名单/词典样式/自定义
/// CSS）：只随主题、设置、词典集变化，不随查词变化。in-app 路径按产物
/// [PopupStaticSettingsJs.revision] 去重，变了才随下一次推送重发（BUG-717 ③：
/// 原先命中后仍有 4~5 遍 MB 级串拷贝/转义/比较，现在命中路径零 MB 级操作）。
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
  final ({String cacheKey, String js}) fontStyle =
      _dictionaryFontStyleJsMemo(appModel);
  final String wheelBindingsJson = popupEntryWheelBindingsJson(
    appModel.shortcutRegistry,
    theme.platform,
  );
  // 弹窗键盘绑定只对 **app 外**的裸 WebView2 表面（全局查词窗 / 剪贴板面板）下发真值。
  // in-app 宿主（app 内弹窗 / Android 悬浮词典 / 独立查词页）显式收 `null` 关掉 JS 侧
  // 判定——那里键盘由 Flutter 派发（阅读器 readerCreateCardFromPopup、视频页读
  // popupMineEntry 绑定）。两边同时开的话，一旦 WebView 把同一次按键既交给 JS 又冒泡回
  // Flutter，就会制出两张卡；按宿主切开是结构上杜绝，而不是靠去重兜底。
  final String popupKeyBindings = options.globalLookup
      ? popupKeyBindingsJson(appModel.shortcutRegistry, theme.platform)
      : 'null';
  final String audioSourcesJson = jsonEncode(appModel.enabledAudioSources);
  final String lookupAudioVolume = ReaderFushiSource
      .instance.lookupAudioVolumeGain
      .clamp(0.0, 1.0)
      .toStringAsFixed(4);
  final String localeTag = LocaleSettings.currentLocale.languageTag;

  final String stylesJson = DictionaryPopupWebViewState.dictionaryStylesJson();
  final String collapsedNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isCollapsed(JapaneseLanguage.instance))
      .map((d) => d.name)
      .toList());
  final String hiddenNames = jsonEncode(appModel.dictionaries
      .where((d) => d.isHidden(JapaneseLanguage.instance))
      .map((d) => d.name)
      .toList());
  final String globalDictCSS = appModel.globalDictCSS;
  final String customDictCSSJson = jsonEncode(appModel.customDictCSS);

  final String slotKey = '${options.globalLookup}|${options.mobileExternal}'
      '|${options.sentenceDraftEnabled}';
  final _PopupStaticSettingsMemo? cached = _staticSettingsMemo[slotKey];
  if (cached != null &&
      cached.themeVarsJs == themeVarsJs &&
      cached.fontCacheKey == fontStyle.cacheKey &&
      cached.appUiScale == appModel.appUiScale &&
      cached.dictionaryFontSize == appModel.dictionaryFontSize &&
      cached.popupWheelSpeed == appModel.popupWheelSpeed &&
      cached.wheelBindingsJson == wheelBindingsJson &&
      cached.audioSourcesJson == audioSourcesJson &&
      cached.lookupAudioVolume == lookupAudioVolume &&
      cached.localeTag == localeTag &&
      cached.deduplicatePitchAccents == appModel.deduplicatePitchAccents &&
      cached.harmonicFrequency == appModel.harmonicFrequency &&
      cached.showExpressionTags == appModel.showExpressionTags &&
      cached.collapseDictionaries == appModel.collapseDictionaries &&
      cached.autoExpandRows == appModel.popupAutoExpandDictionaries &&
      cached.collapsedNames == collapsedNames &&
      cached.hiddenNames == hiddenNames &&
      identical(cached.stylesJson, stylesJson) &&
      cached.globalDictCSS == globalDictCSS &&
      cached.customDictCSSJson == customDictCSSJson) {
    return cached.product;
  }

  final String fontStyleJs = fontStyle.js;
  final double zoom = DictionaryPopupWebViewState.popupContentZoom(
    appUiScale: appModel.appUiScale,
    dictionaryFontSize: appModel.dictionaryFontSize,
  );

  final String iconFontJs = options.globalLookup ? _globalLookupIconFontJs : '';
  // BUG-1139：Ctrl+滚轮内容缩放只装给 app 外裸 WebView2 表面。in-app 三个表面由
  // dictionary_popup_webview 的 _zoomWheelJs 在 onLoadStop 装同名 guard 的另一套
  // （就地 zoom + 即时反馈），两边永不同装。
  final String zoomWheelJs =
      options.globalLookup ? _globalLookupZoomWheelJs : '';

  final String head = '''
    $themeVarsJs
    $fontStyleJs
    // popupRendered is the host reveal gate. Let popup.js wait for the injected
    // custom font on cold/nested lookups, while keeping the no-custom-font path
    // synchronous.
    window.__fushiDictionaryFontsConfigured = ${fontStyleJs.isNotEmpty};
    $iconFontJs
    $zoomWheelJs
    document.documentElement.style.zoom = '${zoom.toStringAsFixed(4)}';
    // TODO-1353: Ctrl+滚轮缩放查词内容需要在 JS 侧就地重算 zoom（即时反馈），故把
    // 当前「界面大小」系数与「词典字号」暴露给弹窗（与上面 zoom 同源，每次注入刷新为
    // 最新真值）。滚轮监听器（dictionary_popup_webview 的 _zoomWheelJs，onLoadStop 装一次）
    // 读这两个全局算新字号 → 立即 documentElement.style.zoom，再回调 Dart 持久化。
    window.__fushiPopupUiScale = ${appModel.appUiScale};
    window.__fushiPopupFontSize = ${appModel.dictionaryFontSize};
    // BUG-1026: 查词弹窗滚轮速度倍率。popup.js 的 wheel 监听器把 factor 乘以它
    // （缺省 1.0）。三种 in-app 弹窗都经此 head 注入；浏览器扩展走 theme 通道另发。
    window.__fushiPopupWheelSpeed = ${appModel.popupWheelSpeed};
    // 查词弹窗「上/下一个词条」的滚轮绑定（ShortcutAction.popupNextEntry /
    // popupPrevEntry，默认 Alt+滚轮下/上）。popup.js 的 wheel 监听读它，命中即调
    // fushiFocusDictionaryEntryMove 并吃掉该事件（不滚动内容）。三种 in-app 弹窗
    // 都经此 head 注入；浏览器扩展没有这条注入通道，用 popup.js 里的同款默认值。
    window.__fushiEntryWheelBindings = $wheelBindingsJson;
    // 查词弹窗 scope 的键盘绑定：制卡（popupMineEntry，默认 Ctrl+Enter）+ 上/下一个词条
    // （默认无键盘绑定，走 Alt+滚轮）。popup.js 的 keydown 监听读它并分派。
    // null = 本宿主由 Dart 派发，JS 侧不参与（见上方 popupKeyBindings 的注释）；
    // 浏览器扩展没有这条注入通道，读到 undefined，用 popup.js 里的同款内置默认值。
    window.__fushiPopupKeyBindings = $popupKeyBindings;
    window.audioSources = $audioSourcesJson;
    window.needsAudio = true;
    window.lookupAudioVolume = $lookupAudioVolume;
    window.i18nNoAudioAvailable = ${jsonEncode(t.popup_no_audio_available)};
    // BUG-1064：点已制卡 ✓ 的「卡片已在 Anki 中」操作面板归属。
    // true  = 宿主自己接了 `minedCardAction` JS handler，会弹 Flutter 居中对话框
    //         （dictionary_popup_webview 的三个 in-app 表面：app 内弹窗 / Android
    //         悬浮词典 / 独立查词页），popup.js 原样把点击交给宿主，行为不变。
    // false = app 外的裸 WebView2 表面（剪贴板面板 + 瞬态查词窗）。主窗在外部程序
    //         后面（甚至最小化），Flutter 对话框根本无法呈现，C++ 因此把
    //         minedCardAction 立即解析成 null——而 popup.js 旧代码把 null 当成
    //         「宿主已处理」，于是点 ✓ 彻底没反应。此时改由 popup.js 在自己的
    //         WebView 里画同款面板（数据走 findMinedMatches / openMinedNote 两根
    //         deferred 桥，动作复用 updateEntry / mineEntry）。
    // 取 !globalLookup 而不是新开参数：globalLookup 恰好就是「这一帧属于 app 外
    // 裸窗口」的既有真相。浏览器扩展不经本注入 → undefined → 同样走页内面板
    // （它的 bridge-shim 对 minedCardAction 也只回 null）。
    window.__fushiMinedCardActionNative = ${!options.globalLookup};
    window.i18nMinedCardTitle = ${jsonEncode(t.anki_mined_card_title)};
    window.i18nMinedCardSubtitle = ${jsonEncode(t.anki_mined_card_subtitle)};
    window.i18nMinedMultipleMatches = ${jsonEncode(t.anki_mined_multiple_matches(count: '{count}'))};
    window.i18nMinedActionOverwrite = ${jsonEncode(t.anki_mined_action_overwrite)};
    window.i18nMinedActionView = ${jsonEncode(t.anki_mined_action_view)};
    window.i18nMinedActionAddDuplicate = ${jsonEncode(t.anki_mined_action_add_duplicate)};
    window.i18nMinedActionCancel = ${jsonEncode(t.dialog_cancel)};
    window.i18nMinedOpenFailed = ${jsonEncode(t.anki_note_open_failed)};
    window.i18nMinedOpenNoCard = ${jsonEncode(t.anki_open_no_card)};
    window.i18nMinedActionFailed = ${jsonEncode(t.anki_card_action_failed)};
    window.sentenceDraftEnabled = ${options.sentenceDraftEnabled};
    window._noResultsMessage = ${jsonEncode(t.no_search_results)};
    window.embedMedia = true;
    window.deduplicatePitchAccents = ${appModel.deduplicatePitchAccents};
    window.harmonicFrequency = ${appModel.harmonicFrequency};
    window.showExpressionTags = ${appModel.showExpressionTags};
    window.collapseDictionaries = ${appModel.collapseDictionaries};
    window.autoExpandRows = ${appModel.popupAutoExpandDictionaries};
    window.collapsedDictionaryNames = $collapsedNames;
    window.hiddenDictionaryNames = $hiddenNames;
''';
  final String tail = '''    window.dictionaryStyles = $stylesJson;
    window.globalDictCSS = ${jsonEncode(globalDictCSS)};
    window.customDictCSS = $customDictCSSJson;
''';
  final PopupStaticSettingsJs product = PopupStaticSettingsJs(
    head: head,
    tail: tail,
    revision: ++_staticSettingsRevision,
  );
  _staticSettingsMemo[slotKey] = _PopupStaticSettingsMemo(
    themeVarsJs: themeVarsJs,
    fontCacheKey: fontStyle.cacheKey,
    appUiScale: appModel.appUiScale,
    dictionaryFontSize: appModel.dictionaryFontSize,
    popupWheelSpeed: appModel.popupWheelSpeed,
    wheelBindingsJson: wheelBindingsJson,
    audioSourcesJson: audioSourcesJson,
    lookupAudioVolume: lookupAudioVolume,
    localeTag: localeTag,
    deduplicatePitchAccents: appModel.deduplicatePitchAccents,
    harmonicFrequency: appModel.harmonicFrequency,
    showExpressionTags: appModel.showExpressionTags,
    collapseDictionaries: appModel.collapseDictionaries,
    autoExpandRows: appModel.popupAutoExpandDictionaries,
    collapsedNames: collapsedNames,
    hiddenNames: hiddenNames,
    stylesJson: stylesJson,
    globalDictCSS: globalDictCSS,
    customDictCSSJson: customDictCSSJson,
    product: product,
  );
  return product;
}
