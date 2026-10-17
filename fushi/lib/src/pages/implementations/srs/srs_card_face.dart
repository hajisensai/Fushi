/// 复习页的卡面视图：渲染好的 Anki 风格 HTML（卡片 CSS + 正面 / 背面）放进 WebView。
///
/// 视图经 [srsCardFaceBuilderProvider] 注入：widget 测试里没有 WebView，覆写成纯
/// 文本实现即可（复习页的状态机与评分逻辑不依赖卡面怎么画）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerHoverEvent;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show CardSourceLink, wrapAnkiCardHtmlWithLang;
import 'package:path/path.dart' as p;

import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show isValidFontData;
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/reader/reader_host_hover_lookup.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart' show ReaderCustomFontCss;
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_dict_style.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/utils.dart';

/// 一面卡（问题面或答案面）。
@immutable
class SrsCardFace {
  const SrsCardFace({
    required this.cardId,
    required this.showingAnswer,
    required this.bodyHtml,
    required this.css,
    required this.languageCode,
    required this.onBridgeKey,
    this.bridgeKeys = kSrsReviewBridgeKeys,
    this.layout = SrsCardLayout.auto,
    this.pageZoom,
    this.fushiCard = false,
    this.onContentHeight,
    this.onWheel,
    this.onZoomWheel,
    this.hostCss = '',
    this.onSourceLink,
  });

  final String cardId;
  final bool showingAnswer;

  /// 渲染器给出的正文 HTML（问题面 = question，答案面 = answer）。
  final String bodyHtml;
  final String css;

  /// 卡面 `lang`（字形 / 断行按学习语言走）；空 = 不标。
  final String? languageCode;

  /// WebView 持有键盘焦点时，页内截获的按键 token（见 [bridgeKeys]）。
  final void Function(String token) onBridgeKey;

  /// WebView 持焦时要交回 Dart 的键：复习页用 [kSrsReviewBridgeKeys]，浏览页的预览用
  /// [kSrsBrowseBridgeKeys]。
  final List<String> bridgeKeys;

  /// 卡面版式：默认按卡面宽度自动（模板的断点）；外观页预览强制成手机 / 桌面版式。
  final SrsCardLayout layout;

  /// 页面内 CSS `zoom`（外观页在窄预览区里看桌面版式时用：按缩小后的尺寸重排重绘，
  /// 文字清晰；**不**在 Flutter 侧缩放平台视图的纹理）。null = 不缩放。
  final double? pageZoom;

  /// 这张卡是内置「Fushi 卡片」类型：只有它吃外观设置（变量 / 类名 / 字体 / 自定义配色）。
  /// 其它类型（Lapis、用户自建、Anki 导入）按自身 HTML/CSS 原样渲染，与 Anki 一致。
  final bool fushiCard;

  /// 非 null 时页面上报内容高度（逻辑像素，body 外框）：Fushi 卡片混合渲染的窄版式据此
  /// 把释义 WebView 撑到内容高度，整面卡由外层 Flutter 滚动。
  final void Function(double height)? onContentHeight;

  /// 非 null 时页面不可滚动（内容不高于视口）期间的滚轮增量交给宿主（桌面窄窗口里
  /// 指针停在释义上滚滚轮，外层卡面照样滚）。
  final void Function(double deltaY)? onWheel;

  /// 非 null 时页面截下 Ctrl（⌘）+ 滚轮交给宿主缩放卡面（WebView 自身缩放已关，且
  /// 平台视图吃掉的滚轮到不了 Flutter）。
  final void Function(double deltaY)? onZoomWheel;

  /// 宿主追加进主题样式的 CSS（随主题原地换，不重放卡片）。混合渲染的窄版式用它把
  /// 「长释义收起高度」按外层视口给成像素值：释义 WebView 高度跟内容走，页内 `vh` 不再是屏高。
  final String hostCss;

  /// 卡面里点了 Fushi 制卡写进 MiscInfo 的来源链接（`fushi://source?...`）：宿主据此
  /// 跳回书 / 漫画 / 视频的对应位置（`openCardSource`）。null = 来源链接不响应。其它
  /// 链接一律不导航（卡面外壳不能被链接带走）。
  final void Function(CardSourceLink link)? onSourceLink;

  /// 同一面卡，换版式 / 页面 zoom。
  SrsCardFace withLayout(SrsCardLayout layout, {double? pageZoom}) =>
      SrsCardFace(
        cardId: cardId,
        showingAnswer: showingAnswer,
        bodyHtml: bodyHtml,
        css: css,
        languageCode: languageCode,
        onBridgeKey: onBridgeKey,
        bridgeKeys: bridgeKeys,
        layout: layout,
        pageZoom: pageZoom,
        fushiCard: fushiCard,
        onContentHeight: onContentHeight,
        onWheel: onWheel,
        onZoomWheel: onZoomWheel,
        hostCss: hostCss,
        onSourceLink: onSourceLink,
      );
}

/// 页面 → 宿主的内容高度 / 滚轮转交（见 [SrsCardFace.onContentHeight] / [SrsCardFace.onWheel]）。
const String kSrsContentHeightHandler = 'onSrsContentHeight';
const String kSrsWheelHandler = 'onSrsWheel';
const String kSrsZoomWheelHandler = 'onSrsZoomWheel';

/// 上报内容高度（ResizeObserver 盯 body；换卡 / 展开收起 / 图片加载都会触发）与
/// 不可滚动时转交滚轮。幂等：外壳重放时不重复挂。
@visibleForTesting
String srsCardMetricsScript({
  required bool height,
  required bool wheel,
  bool zoom = false,
}) =>
    '''
(function(){
  if (window.__fushiSrsMetrics) return;
  window.__fushiSrsMetrics = true;
  function call(name, v){
    try { window.flutter_inappwebview.callHandler(name, v); } catch (e) {}
  }
  if ($height) {
    var last = -1;
    var report = function(){
      var h = Math.ceil(document.body.getBoundingClientRect().height);
      if (Math.abs(h - last) < 1) return;
      last = h;
      call('$kSrsContentHeightHandler', h);
    };
    if (window.ResizeObserver) new ResizeObserver(report).observe(document.body);
    window.addEventListener('load', report);
    document.addEventListener('fushi-srs-theme', report);
    report();
  }
  if ($wheel) {
    window.addEventListener('wheel', function(e){
      if (e.ctrlKey || e.metaKey) return;
      var el = document.scrollingElement || document.documentElement;
      if (el.scrollHeight > window.innerHeight + 1) return;
      call('$kSrsWheelHandler', e.deltaY);
    }, {passive: true});
  }
  if ($zoom) {
    window.addEventListener('wheel', function(e){
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      call('$kSrsZoomWheelHandler', e.deltaY);
    }, {passive: false});
  }
})();
''';

/// 卡面版式。
enum SrsCardLayout {
  /// 按卡面宽度自动（模板断点）。
  auto(''),

  /// 强制手机（单栏）版式。
  narrow('fushi-srs-layout-narrow'),

  /// 强制桌面（双栏）版式。
  wide('fushi-srs-layout-wide');

  const SrsCardLayout(this.hostClass);

  /// 挂在 `.card` 上的宿主类名（模板脚本据此覆盖自动断点）。
  final String hostClass;
}

/// 卡面视图构造器。
typedef SrsCardFaceBuilder =
    Widget Function(BuildContext context, SrsCardFace face);

/// 生产实现：WebView 卡面。测试覆写成纯文本。
final Provider<SrsCardFaceBuilder> srsCardFaceBuilderProvider =
    Provider<SrsCardFaceBuilder>(
      (Ref ref) =>
          (BuildContext context, SrsCardFace face) => SrsWebCardFace(
            key: const ValueKey<String>('srs-card-face-webview'),
            face: face,
          ),
    );

/// WebView 持焦时要交回 Dart 的键（token 名与 `KeyboardEvent.code` 同名）。
const List<String> kSrsReviewBridgeKeys = <String>[
  'Space',
  'Enter',
  'NumpadEnter',
  'Digit1',
  'Digit2',
  'Digit3',
  'Digit4',
  'Numpad1',
  'Numpad2',
  'Numpad3',
  'Numpad4',
  'Ctrl+KeyZ',
  'Meta+KeyZ',
  // 卡面缩放（Ctrl / ⌘ + 加号 / 减号 / 0）。
  'Ctrl+Equal',
  'Ctrl+Minus',
  'Ctrl+Digit0',
  'Ctrl+NumpadAdd',
  'Ctrl+NumpadSubtract',
  'Meta+Equal',
  'Meta+Minus',
  'Meta+Digit0',
  // 卡面查词弹窗打开时关一层（弹窗没开时复习页忽略它）。
  'Escape',
];

/// 浏览页预览持焦时要交回 Dart 的键：翻面（Enter / 空格）、上一张 / 下一张（方向键）、
/// 撤销、Esc。
const List<String> kSrsBrowseBridgeKeys = <String>[
  'Space',
  'Enter',
  'NumpadEnter',
  'ArrowLeft',
  'ArrowRight',
  'ArrowUp',
  'ArrowDown',
  'Escape',
  'Ctrl+KeyZ',
  'Meta+KeyZ',
];

const String _kSrsBridgeHandler = 'onSrsReviewKey';

/// 页内链接点击 → 宿主（见 [kSrsCardLinkScript]）。
const String kSrsSourceLinkHandler = 'onSrsSourceLink';

/// 卡面链接：捕获阶段拦下所有 `<a href>` 的默认导航（卡面外壳不能被链接带走；页内
/// `#锚点` 与 `javascript:` 不算导航，放行），其中 Fushi 来源链接（`fushi://source`）
/// 交给宿主跳回原媒体。不 stopPropagation：卡片模板自己挂在链接上的点击脚本照常执行。
const String kSrsCardLinkScript = r'''
(function(){
  if (window.__fushiSrsLinks) return;
  window.__fushiSrsLinks = true;
  document.addEventListener('click', function(e){
    var t = e.target;
    var a = t && t.closest ? t.closest('a[href]') : null;
    if (!a) return;
    var href = a.getAttribute('href') || '';
    if (href.charAt(0) === '#' || /^javascript:/i.test(href)) return;
    e.preventDefault();
    if (/^fushi:\/\/source/i.test(href)) {
      try { window.flutter_inappwebview.callHandler('onSrsSourceLink', href); } catch (err) {}
    }
  }, true);
})();
''';

/// 卡面导航策略：Fushi 来源链接交给 [onSourceLink] 后取消；外壳本身（`about:` /
/// `data:` 载入）、子框架（卡片里嵌的视频等）放行；其余主框架导航一律取消。
@visibleForTesting
NavigationActionPolicy srsCardNavigationPolicy(
  Uri? url, {
  required bool isForMainFrame,
  void Function(CardSourceLink link)? onSourceLink,
}) {
  final String scheme = url?.scheme.toLowerCase() ?? '';
  if (scheme == 'fushi') {
    final CardSourceLink? link = CardSourceLink.tryParse(url.toString());
    if (link != null) onSourceLink?.call(link);
    return NavigationActionPolicy.CANCEL;
  }
  if (!isForMainFrame ||
      scheme.isEmpty ||
      scheme == 'about' ||
      scheme == 'data' ||
      scheme == kSrsMediaScheme) {
    return NavigationActionPolicy.ALLOW;
  }
  return NavigationActionPolicy.CANCEL;
}

/// [keys] 的卡面键盘桥脚本（每次换内容后注入；生成器自带幂等守卫）。
String srsCardFaceBridgeScript(List<String> keys) => webViewKeyBridgeScript(
  handlerName: _kSrsBridgeHandler,
  keys: keys,
  forwardRepeats: false,
  stopPropagation: true,
);

/// 复习页的卡面键盘桥脚本。
final String srsReviewKeyBridgeScript = srsCardFaceBridgeScript(
  kSrsReviewBridgeKeys,
);

String _cssColor(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// 拼出整页 HTML：卡片 CSS + `<div class="card">` 包裹的正文（Anki 的卡面约定）。
///
/// 深色主题下同时挂 Anki 的两种夜间类名（`nightMode` / `night_mode`），卡片 CSS
/// 里写的夜间样式照常生效。
///
/// [mediaUrlPrefix] 非空时把正文与 CSS 里的媒体库引用改写到卡面虚拟域，`[sound:]`
/// 换成播放按钮（见 srs_card_media.dart）；[accent] / [onAccent] 是播放按钮的配色。
String srsCardHtml({
  required SrsCardFace face,
  required bool dark,
  required Color background,
  required Color foreground,
  String? mediaUrlPrefix,
  Color? accent,
  Color? onAccent,
}) {
  final String night = dark ? ' nightMode night_mode' : '';
  final String rawBody = mediaUrlPrefix == null
      ? face.bodyHtml
      : srsLocalizeCardHtml(face.bodyHtml, urlPrefix: mediaUrlPrefix);
  final String css = mediaUrlPrefix == null
      ? face.css
      : srsLocalizeCardCss(face.css, urlPrefix: mediaUrlPrefix);
  final String body = wrapAnkiCardHtmlWithLang(rawBody, face.languageCode);
  final String accentVars = accent == null
      ? ''
      : ':root{--fushi-srs-accent:${_cssColor(accent)};'
            '--fushi-srs-on-accent:${_cssColor(onAccent ?? foreground)};}';
  final String media = mediaUrlPrefix == null
      ? ''
      : '<style>$accentVars$kSrsCardMediaCss</style>'
            '<script>$kSrsCardMediaScript</script>';
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;padding:0;background:${_cssColor(background)};'
      'color:${_cssColor(foreground)};}'
      'body{padding:16px;box-sizing:border-box;}</style>'
      '$media<style>$css</style></head>'
      '<body class="card$night"><div class="card$night">$body</div></body></html>';
}

// ---------------------------------------------------------------- 外壳 + 原地换内容
//
// 复习页的卡面对齐 Anki / AnkiDroid reviewer：外壳页（基础样式、媒体脚本、按键桥、
// 卡片 CSS 槽、卡面根节点）只加载一次，换卡 / 翻面 / 换主题都经 JS 原地替换内容，
// 不再每次 `loadData` 整页重载（重载 = 新文档首帧前一帧空白 + 样式 / 脚本全重来）。

String _cssRgba(Color c, double alpha) {
  final int argb = c.toARGB32();
  return 'rgba(${(argb >> 16) & 0xFF},${(argb >> 8) & 0xFF},${argb & 0xFF},'
      '${alpha.toStringAsFixed(2)})';
}

/// 卡面细滚动条（WebView2 / Android WebView / Linux WebKit 的经典滚动条默认是带
/// 上下箭头的粗灰条）。形状与 popup.css 的主题滚动条一致：8px、透明 track、
/// 2px 内缩的全圆头 thumb、去掉箭头按钮；颜色取前景色低透明度，悬停加深。
///
/// 标准属性 `scrollbar-width` / `scrollbar-color` 只给不认 `::-webkit-scrollbar`
/// 的引擎：Chromium 121+ 一旦标准属性生效会整族禁用 `::-webkit-scrollbar` 伪元素
/// （BUG-753），悬停加深与去箭头就都没了。
@visibleForTesting
String srsCardScrollbarCss(Color foreground) {
  final String thumb = _cssRgba(foreground, 0.28);
  final String thumbActive = _cssRgba(foreground, 0.5);
  return '::-webkit-scrollbar{width:8px;height:8px;background:transparent;}'
      '::-webkit-scrollbar-track,::-webkit-scrollbar-track-piece,'
      '::-webkit-scrollbar-corner{background:transparent;border:0;}'
      '::-webkit-scrollbar-button{display:none;width:0;height:0;}'
      '::-webkit-scrollbar-thumb{min-height:36px;border:2px solid transparent;'
      'border-radius:999px;background-color:$thumb;background-clip:padding-box;}'
      '::-webkit-scrollbar-thumb:hover,::-webkit-scrollbar-thumb:active'
      '{background-color:$thumbActive;}'
      '@supports not selector(::-webkit-scrollbar){html{scrollbar-width:thin;'
      'scrollbar-color:$thumb transparent;}}';
}

/// iOS / macOS 的 WKWebView 用系统叠加滚动条，不改（macOS 上写了
/// `::-webkit-scrollbar` 反而会把叠加滚动条换成常驻的自绘条）。
bool get srsCardUsesThemedScrollbar => !(isIOSPlatform || isMacOSPlatform);

/// 卡面主题样式（外壳里 `#fushi-theme-css` 的内容）：配色、`color-scheme`、
/// 播放按钮配色变量，以及 [themedScrollbar] 时的细滚动条。[appearanceCss] 是外观设置
/// 注入的 `--fushi-srs-*` 变量与 @font-face（见 srs_card_appearance.dart），排在最后，
/// 同名变量以它为准。
@visibleForTesting
String srsCardThemeCss({
  required bool dark,
  required Color background,
  required Color foreground,
  required Color accent,
  required Color onAccent,
  required bool themedScrollbar,
  String appearanceCss = '',
}) =>
    ':root{color-scheme:${dark ? 'dark' : 'light'};'
    '--fushi-srs-accent:${_cssColor(accent)};'
    '--fushi-srs-on-accent:${_cssColor(onAccent)};}'
    'html,body{background:${_cssColor(background)};'
    'color:${_cssColor(foreground)};}'
    '${themedScrollbar ? srsCardScrollbarCss(foreground) : ''}'
    '$appearanceCss';

/// 卡面根节点 / body 上的附加类名（Anki 的两种夜间类名）。
String srsCardNightClasses({required bool dark}) =>
    dark ? 'nightMode night_mode' : '';

/// 卡面根节点 / body 上的全部宿主类名：夜间类名 + 外观类名（[appearanceClasses]）。
String srsCardHostClasses({
  required bool dark,
  String appearanceClasses = '',
}) => <String>[
  srsCardNightClasses(dark: dark),
  appearanceClasses,
].where((String c) => c.isNotEmpty).join(' ');

/// 外壳页里的换内容脚本：定义 `__fushiSrsSetTheme` / `__fushiSrsSetCard`。
///
/// `__fushiSrsSetCard(css, html, classes)` 对齐 Anki reviewer 的 `_updateQA`：
/// 清空 `onUpdateHook` / `onShownHook`、停掉旧卡的音视频、换卡片 CSS 与根节点
/// innerHTML、滚回顶部，然后**按文档顺序重放**正文里的 `<script>`（innerHTML 插入
/// 的脚本不执行，要重建 script 元素）；外部 `<script src>` 等它加载完（或失败）再
/// 跑后面的。全是内联脚本时整个过程同步完成，换卡后的第一帧就是脚本跑完的样子。
/// 脚本全部跑完后先做释义区的词典样式处理（统一 / 深色调色，见 srs_card_dict_style.dart），
/// 再依次执行卡片脚本压进 `onUpdateHook` / `onShownHook` 的函数。
/// `__fushiSrsSetTheme` 换完主题样式与类名后同样重做词典样式处理，并派发 `fushi-srs-theme`
/// 事件（卡片脚本可监听它跟随外观变化）。
/// 换卡期间又来了新卡（外部脚本还没加载完）时旧卡剩下的脚本与钩子不再执行。
const String kSrsCardShellScript = r'''
(function(){
  if (window.__fushiSrsSetCard) return;
  var seq = 0;
  window.onUpdateHook = [];
  window.onShownHook = [];
  function root(){ return document.getElementById('fushi-card-root'); }
  function setClasses(classes){
    var c = classes ? 'card ' + classes : 'card';
    document.body.className = c;
    var r = root();
    if (r) r.className = c;
  }
  function stopMedia(el){
    var list = el.querySelectorAll('video,audio');
    for (var i = 0; i < list.length; i++) {
      var m = list[i];
      try {
        m.pause();
        m.removeAttribute('src');
        while (m.firstChild) m.removeChild(m.firstChild);
        m.load();
      } catch (e) {}
    }
  }
  // 内联脚本同步执行、返回 null；外部脚本返回加载完（或失败）时 resolve 的 Promise。
  function replayScript(old){
    if (!old.parentNode) return null;
    var s = document.createElement('script');
    var attrs = old.attributes;
    for (var i = 0; i < attrs.length; i++) {
      s.setAttribute(attrs[i].name, attrs[i].value);
    }
    var external = old.hasAttribute('src');
    var done = null;
    if (external) {
      done = new Promise(function(resolve){
        s.addEventListener('load', function(){ resolve(); });
        s.addEventListener('error', function(){ resolve(); });
      });
    }
    s.text = old.text;
    old.parentNode.replaceChild(s, old);
    return done;
  }
  // 从第 i 个脚本起重放：同步跑完返回 true，被新卡打断返回 false，遇到外部脚本返回 Promise。
  function replayFrom(scripts, i, my){
    for (; i < scripts.length; i++) {
      if (my !== seq) return false;
      var pending = replayScript(scripts[i]);
      if (pending) {
        var next = i + 1;
        return pending.then(function(){ return replayFrom(scripts, next, my); });
      }
    }
    return my === seq;
  }
  function runHooks(list){
    for (var i = 0; i < list.length; i++) {
      try {
        if (typeof list[i] === 'function') list[i]();
      } catch (e) {
        if (window.console) console.error(e);
      }
    }
  }
  function dictStyle(){
    try {
      if (window.__fushiSrsDictStyle) window.__fushiSrsDictStyle();
    } catch (e) {
      if (window.console) console.error(e);
    }
  }
  function finish(my, ok){
    if (ok !== true || my !== seq) return;
    dictStyle();
    runHooks(window.onUpdateHook);
    runHooks(window.onShownHook);
  }
  window.__fushiSrsSetTheme = function(themeCss, classes){
    document.getElementById('fushi-theme-css').textContent = themeCss;
    setClasses(classes);
    dictStyle();
    // 卡片脚本可据此跟随外观变化（例如「全部释义默认展开」），不必重跑。
    try {
      document.dispatchEvent(new CustomEvent('fushi-srs-theme', { detail: classes }));
    } catch (e) {}
  };
  // 样式注册表：每段样式（笔记类型 CSS / 卡片正文里抽出的 <style>）按内容哈希只建一次
  // <style data-fushi-css>，之后换卡只传哈希引用；当前卡没引用的全部 disabled（词典样式
  // 不一定都限定了作用域，不能让上一张卡的样式串到这一张）。
  var styles = {};
  window.__fushiSrsDefineCss = function(hash, kind, text){
    if (styles[hash]) return;
    var s = document.createElement('style');
    s.setAttribute('data-fushi-css', hash);
    s.textContent = text;
    var a = document.getElementById(kind === 't' ? 'fushi-css-tpl' : 'fushi-css-body');
    a.parentNode.insertBefore(s, a);
    s.disabled = true;
    styles[hash] = s;
  };
  function useStyles(refs){
    var want = {};
    for (var i = 0; i < refs.length; i++) want[refs[i]] = true;
    for (var h in styles) {
      var off = !want[h];
      if (styles[h].disabled !== off) styles[h].disabled = off;
    }
  }
  window.__fushiSrsSetCard = function(refs, html, classes){
    var my = ++seq;
    var r = root();
    window.onUpdateHook = [];
    window.onShownHook = [];
    stopMedia(r);
    useStyles(refs);
    setClasses(classes);
    r.innerHTML = html;
    window.scrollTo(0, 0);
    var scripts = Array.prototype.slice.call(r.getElementsByTagName('script'));
    var result = replayFrom(scripts, 0, my);
    if (result && typeof result.then === 'function') {
      result.then(function(ok){ finish(my, ok); });
    } else {
      finish(my, result);
    }
  };
})();
''';

/// 卡面外壳页：只在 WebView 创建（以及 renderer 死亡重建）时加载一次，内容随后由
/// [srsCardSetCardScript] / [srsCardSetThemeScript] 原地换。
@visibleForTesting
String srsCardShellHtml({required String themeCss, required String classes}) {
  final String cls = classes.isEmpty ? 'card' : 'card $classes';
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '<style>html,body{margin:0;padding:0;}'
      'body{padding:16px;box-sizing:border-box;}</style>'
      '<style id="fushi-theme-css">$themeCss</style>'
      '<style>$kSrsCardMediaCss</style>'
      '<script>$kSrsCardMediaScript</script>'
      // 样式注册表的两个锚点：模板 / 笔记类型 CSS 在前，卡片正文里抽出的样式在后
      // （与它们原本在文档里的先后一致）。
      '<style id="fushi-css-tpl"></style><style id="fushi-css-body"></style>'
      '<script>$kSrsCardDictStyleScript</script>'
      '<script>$kSrsCardShellScript</script>'
      '</head><body class="$cls"><div id="fushi-card-root" class="$cls">'
      '</div></body></html>';
}

/// 把 Dart 字符串变成 JS 字符串字面量（JSON 子集；U+2028 / U+2029 也转义，
/// 老引擎里它们在字符串字面量中是非法换行）。
String _jsString(String s) =>
    jsonEncode(s).replaceAll(' ', r' ').replaceAll(' ', r' ');

/// 换卡调用：[styleRefs] 是这张卡用到的样式哈希（须已经 [srsCardDefineCssScript] 过）。
/// 参数全部 JSON 编码，卡面内容里的引号 / 反斜杠 / `</script>` 都不会逃出字面量。
@visibleForTesting
String srsCardSetCardScript({
  required List<String> styleRefs,
  required String bodyHtml,
  required String classes,
}) =>
    'window.__fushiSrsSetCard(${jsonEncode(styleRefs)},${_jsString(bodyHtml)},'
    '${_jsString(classes)});';

/// 往外壳的样式注册表里登记一段样式（同一哈希只登记一次）。
@visibleForTesting
String srsCardDefineCssScript(SrsCardStyle style) =>
    'window.__fushiSrsDefineCss(${_jsString(style.hash)},'
    '${_jsString(style.kind)},${_jsString(style.css)});';

/// 卡面的一段样式（注册表的一项）。[kind]：`t` = 模板 / 笔记类型 CSS，`d` = 卡片正文里的
/// `<style>`（多是 Yomitan 导出释义带的词典样式）。
@immutable
class SrsCardStyle {
  const SrsCardStyle({
    required this.hash,
    required this.kind,
    required this.css,
  });

  factory SrsCardStyle.of(String kind, String css) =>
      SrsCardStyle(hash: srsCardStyleHash(css), kind: kind, css: css);

  final String hash;
  final String kind;
  final String css;
}

final Map<String, String> _styleHashMemo = <String, String>{};

/// 样式内容哈希（sha1 前 16 位十六进制）；最近用过的样式记住结果，同一份 CSS 不重复算。
String srsCardStyleHash(String css) {
  final String? hit = _styleHashMemo.remove(css);
  final String hash =
      hit ?? sha1.convert(utf8.encode(css)).toString().substring(0, 16);
  _styleHashMemo[css] = hash;
  if (_styleHashMemo.length > 64) {
    _styleHashMemo.remove(_styleHashMemo.keys.first);
  }
  return hash;
}

final RegExp _cardScriptBlock = RegExp(
  r'<script\b[\s\S]*?</script\s*>',
  caseSensitive: false,
);
final RegExp _cardStyleBlock = RegExp(
  r'<style(\s[^>]*)?>([\s\S]*?)</style\s*>',
  caseSensitive: false,
);
final RegExp _plainStyleAttrs = RegExp(
  r'''^\s*(type\s*=\s*["']?text/css["']?\s*)?$''',
  caseSensitive: false,
);

final Map<String, ({String body, List<String> styles})> _extractMemo =
    <String, ({String body, List<String> styles})>{};

/// 小容量 LRU 记忆：键 → 值，命中挪到最新，超出 [cap] 丢最旧。
T _memo<T>(
  Map<String, T> memo,
  String key,
  T Function() compute, {
  int cap = 16,
}) {
  final T? hit = memo.remove(key);
  final T value = hit ?? compute();
  memo[key] = value;
  if (memo.length > cap) memo.remove(memo.keys.first);
  return value;
}

final Map<String, String> _localizedCssMemo = <String, String>{};
final Map<String, ({String body, List<String> styles})> _preparedBodyMemo =
    <String, ({String body, List<String> styles})>{};

/// 卡片正文的整套预处理（媒体引用改写 → 抽 `<style>`），按（URL 前缀 + 正文）记忆：
/// 复习页每次重建、换主题 / 外观、预取的下一张都会重新构造文档，同一面卡不重复跑
/// 几十 KB 的正则改写。
({String body, List<String> styles}) srsPrepareCardBody(
  String html,
  String mediaUrlPrefix,
) => _memo(
  _preparedBodyMemo,
  '$mediaUrlPrefix\u0000$html',
  () => srsExtractCardStyles(
    srsLocalizeCardHtml(html, urlPrefix: mediaUrlPrefix),
  ),
);

/// 把卡片 HTML 里的 `<style>` 块抽出来（正文里不再带样式，样式进注册表）。
///
/// 只抽不带属性（或只有 `type="text/css"`）的块：带 `media` 等属性的原样留在正文里。
/// `<script>` 里的文字不碰。同一段样式在一张卡里出现多次只留一份。结果按 HTML 内容缓存
/// （最近 16 张）：预取的下一张、问题面与答案面共用的释义都不重复抽。
({String body, List<String> styles}) srsExtractCardStyles(String html) {
  if (!html.contains('<style') && !html.contains('<STYLE')) {
    return (body: html, styles: const <String>[]);
  }
  final ({String body, List<String> styles})? hit = _extractMemo.remove(html);
  if (hit != null) {
    _extractMemo[html] = hit;
    return hit;
  }
  final List<String> styles = <String>[];
  String strip(String chunk) =>
      chunk.replaceAllMapped(_cardStyleBlock, (Match m) {
        if (!_plainStyleAttrs.hasMatch(m.group(1) ?? '')) return m.group(0)!;
        final String css = m.group(2)!;
        if (css.trim().isNotEmpty && !styles.contains(css)) styles.add(css);
        return '';
      });
  final StringBuffer body = StringBuffer();
  int last = 0;
  for (final Match m in _cardScriptBlock.allMatches(html)) {
    body
      ..write(strip(html.substring(last, m.start)))
      ..write(m.group(0));
    last = m.end;
  }
  body.write(strip(html.substring(last)));
  final ({String body, List<String> styles}) out = (
    body: body.toString(),
    styles: List<String>.unmodifiable(styles),
  );
  _extractMemo[html] = out;
  if (_extractMemo.length > 16) _extractMemo.remove(_extractMemo.keys.first);
  return out;
}

/// 换主题调用。
@visibleForTesting
String srsCardSetThemeScript({
  required String themeCss,
  required String classes,
}) =>
    'window.__fushiSrsSetTheme(${_jsString(themeCss)},${_jsString(classes)});';

/// 外壳当前该显示的东西：主题部分与卡片部分分开比对，各自只在变了时下发。
@immutable
class SrsCardFaceDocument {
  const SrsCardFaceDocument({
    required this.themeCss,
    required this.classes,
    required this.cardId,
    required this.showingAnswer,
    required this.cardCss,
    required this.bodyHtml,
    this.bodyStyles = const <String>[],
  });

  /// 由一面卡与主题算出（媒体引用改写、`lang` 包裹都在这里做）。
  factory SrsCardFaceDocument.of(
    SrsCardFace face, {
    required bool dark,
    required Color background,
    required Color foreground,
    required Color accent,
    required Color onAccent,
    required String mediaUrlPrefix,
    required bool themedScrollbar,
    String appearanceCss = '',
    String appearanceClasses = '',
  }) => SrsCardFaceDocument(
    themeCss: srsCardThemeCss(
      dark: dark,
      background: background,
      foreground: foreground,
      accent: accent,
      onAccent: onAccent,
      themedScrollbar: themedScrollbar,
      appearanceCss:
          (face.pageZoom == null
              ? appearanceCss
              : '${appearanceCss}html{zoom:${face.pageZoom!.toStringAsFixed(4)};}') +
          face.hostCss,
    ),
    classes: srsCardHostClasses(
      dark: dark,
      appearanceClasses: <String>[
        appearanceClasses,
        face.layout.hostClass,
      ].where((String c) => c.isNotEmpty).join(' '),
    ),
    cardId: face.cardId,
    showingAnswer: face.showingAnswer,
    cardCss: _memo(
      _localizedCssMemo,
      '$mediaUrlPrefix\u0000${face.css}',
      () => srsLocalizeCardCss(face.css, urlPrefix: mediaUrlPrefix),
    ),
    bodyHtml: wrapAnkiCardHtmlWithLang(
      srsPrepareCardBody(face.bodyHtml, mediaUrlPrefix).body,
      face.languageCode,
    ),
    bodyStyles: srsPrepareCardBody(face.bodyHtml, mediaUrlPrefix).styles,
  );

  final String themeCss;
  final String classes;
  final String cardId;
  final bool showingAnswer;

  /// 笔记类型 CSS（媒体引用已改写）。
  final String cardCss;

  /// 正文 HTML（`<style>` 已抽走，见 [srsExtractCardStyles]）。
  final String bodyHtml;

  /// 正文里抽出的样式块（文档顺序）。
  final List<String> bodyStyles;

  /// 这张卡用到的全部样式（注册表项）：笔记类型 CSS 在前，正文样式在后。
  List<SrsCardStyle> get styles => <SrsCardStyle>[
    if (cardCss.isNotEmpty) SrsCardStyle.of('t', cardCss),
    for (final String css in bodyStyles) SrsCardStyle.of('d', css),
  ];

  /// 在一个全新的外壳里显示这张卡的完整调用串（登记全部样式 + 换卡）。
  @visibleForTesting
  String get fullCardScript {
    final List<SrsCardStyle> all = styles;
    return <String>[
      for (final SrsCardStyle st in all) srsCardDefineCssScript(st),
      srsCardSetCardScript(
        styleRefs: <String>[for (final SrsCardStyle st in all) st.hash],
        bodyHtml: bodyHtml,
        classes: classes,
      ),
    ].join();
  }

  String get _themeKey => '$themeCss\u0000$classes';

  /// 换了卡（哪怕正文一字不差）也要重放：滚回顶部、重跑卡片脚本。夜间类名与外观
  /// （变量、类名、字体）都不在里面：只换主题 / 外观时走 `__fushiSrsSetTheme`，不重跑
  /// 卡片脚本。
  String get _cardKey =>
      '$cardId\u0000$showingAnswer\u0000'
      '${styles.map((SrsCardStyle s) => s.hash).join(',')}\u0000$bodyHtml';

  String get shellHtml =>
      srsCardShellHtml(themeCss: themeCss, classes: classes);
}

/// 外壳与「该显示什么」之间的同步：外壳就绪（首次 onLoadStop）前只记下最后一次
/// 内容，就绪后一次下发；之后主题 / 卡片各自变了才下发对应调用。WebView 无关，
/// 单测直接驱动。
@visibleForTesting
class SrsCardFaceSync {
  SrsCardFaceSync({required this.evaluate, required this.reloadShell});

  /// 在外壳里执行一段 JS，返回其值（平台视图没了返回 null）。
  final Future<Object?> Function(String source) evaluate;

  /// 外壳没了（卡片里的链接把页面导航走了）时重新加载外壳。
  final void Function() reloadShell;

  bool _ready = false;
  SrsCardFaceDocument? _wanted;
  String? _appliedTheme;
  String? _appliedCard;
  int _generation = 0;
  bool _reloadedShell = false;

  /// 当前外壳的样式注册表里已有的哈希（外壳重载 / renderer 重建时清空、整份重放）。
  final Set<String> _definedStyles = <String>{};

  /// 当前外壳已登记的样式哈希（测试观察用）。
  @visibleForTesting
  Set<String> get definedStyles => Set<String>.unmodifiable(_definedStyles);

  bool get shellReady => _ready;

  /// 当前该显示的内容（外壳没就绪时排队，只留最后一次）。
  void update(SrsCardFaceDocument document) {
    _wanted = document;
    _flush();
  }

  /// 新的平台视图 / renderer 重建 / 页面被导航走：外壳要重新加载，已下发的都作废。
  void detach() {
    _ready = false;
    _appliedTheme = null;
    _appliedCard = null;
    _definedStyles.clear();
    _generation++;
  }

  /// 一次加载完成（onLoadStop）：外壳就绪，把当前内容整份下发一次。
  void shellLoaded() {
    detach();
    _ready = true;
    _flush();
  }

  void _flush() {
    final SrsCardFaceDocument? doc = _wanted;
    if (!_ready || doc == null) return;
    final StringBuffer calls = StringBuffer();
    if (doc._themeKey != _appliedTheme) {
      calls.write(
        srsCardSetThemeScript(themeCss: doc.themeCss, classes: doc.classes),
      );
    }
    final Set<String> defining = <String>{};
    if (doc._cardKey != _appliedCard) {
      final List<SrsCardStyle> styles = doc.styles;
      for (final SrsCardStyle st in styles) {
        if (_definedStyles.contains(st.hash) || !defining.add(st.hash)) {
          continue;
        }
        calls.write(srsCardDefineCssScript(st));
      }
      calls.write(
        srsCardSetCardScript(
          styleRefs: <String>[for (final SrsCardStyle st in styles) st.hash],
          bodyHtml: doc.bodyHtml,
          classes: doc.classes,
        ),
      );
    }
    if (calls.isEmpty) return;
    _appliedTheme = doc._themeKey;
    _appliedCard = doc._cardKey;
    _definedStyles.addAll(defining);
    final int generation = ++_generation;
    final String source =
        '(function(){if(typeof window.__fushiSrsSetCard!=="function")'
        'return false;$calls return true;})()';
    unawaited(
      evaluate(source).then(
        (Object? result) {
          if (generation != _generation) return;
          if (result == false) {
            // 页面已不是外壳（被卡片链接导航走了）：重载外壳一次，onLoadStop 后重放。
            if (_reloadedShell) return;
            _reloadedShell = true;
            detach();
            reloadShell();
          } else if (result == true) {
            _reloadedShell = false;
          }
        },
        onError: (Object e, StackTrace stack) {
          ErrorLogService.instance.log('SrsWebCardFace.setCard', e, stack);
          // 下发失败：下次 update 整份重发（同一代之后没有新下发时才作废）。
          if (generation != _generation) return;
          _appliedTheme = null;
          _appliedCard = null;
          _definedStyles.removeAll(defining);
        },
      ),
    );
  }
}

/// 卡面 `[sound:]` 的播放实现（测试覆写）。参数是本地文件路径；返回是否开始播放。
typedef SrsSoundPlayer = Future<bool> Function(String path);

/// 生产实现：app 共用的 just_audio 播放器（串行化激活，见 [DesktopAudioPlayback]）。
final Provider<SrsSoundPlayer> srsSoundPlayerProvider =
    Provider<SrsSoundPlayer>(
      (Ref ref) =>
          (String path) => DesktopAudioPlayback.playFile(path),
    );

/// 卡面媒体请求的响应：[store] 里按名字取字节；不是卡面媒体 URL 时返回 null。
@visibleForTesting
Future<WebResourceResponse?> srsCardMediaResponse(
  Uri url,
  SrsMediaStore? store,
) async {
  final String? name = srsMediaNameFromUrl(url);
  if (name == null) return null;
  final Uint8List? bytes = await store?.load(name);
  if (bytes == null) {
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: const <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }
  return WebResourceResponse(
    contentType: srsMediaMimeType(name),
    statusCode: 200,
    reasonPhrase: 'OK',
    headers: const <String, String>{
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'private, max-age=3600',
    },
    data: bytes,
  );
}

/// 卡面字体请求的响应：路径必须在 [fontRoot]（app 字体库目录）之内、在当前外观引用的
/// [whitelist] 里、文件存在且文件头是字体魔数，否则 404。不是卡面字体 URL 时返回 null。
@visibleForTesting
Future<WebResourceResponse?> srsCardFontResponse(
  Uri url, {
  required String? fontRoot,
  required Set<String> whitelist,
}) async {
  final String? requested = srsFontPathFromUrl(url);
  if (requested == null) return null;
  Uint8List? bytes;
  if (fontRoot != null) {
    final String? safe = ReaderCustomFontCss.safeFontPath(
      requested,
      allowedRoots: <String>[fontRoot],
    );
    if (safe != null && whitelist.contains(p.canonicalize(safe))) {
      try {
        final File file = File(safe);
        if (file.existsSync()) {
          final Uint8List data = await file.readAsBytes();
          if (isValidFontData(data)) bytes = data;
        }
      } on FileSystemException {
        bytes = null;
      }
    }
  }
  if (bytes == null) {
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: const <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }
  return WebResourceResponse(
    contentType: srsMediaMimeType(requested),
    statusCode: 200,
    reasonPhrase: 'OK',
    headers: const <String, String>{
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'private, max-age=3600',
    },
    data: bytes,
  );
}

/// 一面卡在给定主题 / 外观下的外壳文档。外观设置只属于 Fushi 卡片
/// （[SrsCardFace.fushiCard]）：别的类型拿不到它的变量、类名、字体与自定义配色，按自身
/// HTML/CSS 原样渲染（与 Anki 一致）。
SrsCardFaceDocument srsCardFaceDocumentFor(
  SrsCardFace face, {
  required ThemeData theme,
  required SrsCardAppearance appearance,
  required SrsCardLabels labels,
  required String mediaUrlPrefix,
  required bool themedScrollbar,
  required String Function(String path) fontUrl,
  Iterable<Map<String, dynamic>> fonts = const <Map<String, dynamic>>[],
  String? fontRoot,
}) {
  final bool dark = theme.brightness == Brightness.dark;
  final bool fushi = face.fushiCard;
  final ColorScheme scheme = fushi
      ? srsCardColorScheme(appearance, theme.colorScheme)
      : theme.colorScheme;
  return SrsCardFaceDocument.of(
    face,
    dark: dark,
    background: scheme.surface,
    foreground: scheme.onSurface,
    accent: scheme.primary,
    onAccent: scheme.onPrimary,
    mediaUrlPrefix: mediaUrlPrefix,
    themedScrollbar: themedScrollbar,
    appearanceCss: fushi
        ? srsCardAppearanceCss(
            appearance: appearance,
            appScheme: theme.colorScheme,
            tokens: SrsCardTokens.fromTheme(theme),
            dark: dark,
            labels: labels,
            fontUrl: fontUrl,
            fonts: fonts,
            fontRoot: fontRoot,
          )
        : '',
    appearanceClasses: fushi ? srsCardAppearanceClasses(appearance) : '',
  );
}

/// 卡面标签文字（按 app 界面语言）。
SrsCardLabels srsCardLabels() => SrsCardLabels(
  allDefinitions: t.srs_card_label_all_definitions,
  frequency: t.srs_card_label_frequency,
  source: t.srs_card_label_source,
  showMore: t.srs_card_label_show_more,
);

/// WebView 卡面。保留同一个平台视图、外壳页只加载一次；换卡 / 翻面 / 换主题经
/// [SrsCardFaceSync] 原地换内容（对齐 Anki reviewer，不整页重载，不闪空帧）。
class SrsWebCardFace extends ConsumerStatefulWidget {
  const SrsWebCardFace({super.key, required this.face});

  final SrsCardFace face;

  /// 集成测试探针：当前卡面 WebView 的 controller（仅 debug / profile 注册，
  /// 卡面销毁时清空）。用于抓卡面像素与量换卡首帧耗时。
  @visibleForTesting
  static InAppWebViewController? debugController;

  @override
  ConsumerState<SrsWebCardFace> createState() => _SrsWebCardFaceState();
}

class _SrsWebCardFaceState extends ConsumerState<SrsWebCardFace>
    implements SrsCardLookupSurface {
  InAppWebViewController? _controller;

  /// 卡面查词（[SrsCardLookupScope] 给出；null = 这面卡不取词，如外观页预览、正面预热的
  /// 释义 WebView）。
  SrsCardLookupController? _lookup;

  /// 当前外壳里已装好取词脚本（外壳重载 / renderer 重建后重装）。
  bool _lookupInstalled = false;

  /// macOS 宿主侧悬停腿（页面收不到 mousemove，BUG-2508）。
  final ReaderHostHoverLookupGate _hostHover = ReaderHostHoverLookupGate();

  /// 取词脚本整段（选区脚本 + 卡面监听）只拼一次。
  static final String _lookupInstallScript = srsCardLookupInstallScript(
    ReaderSelectionScripts.source(),
  );

  /// 本平台卡面媒体的 URL 前缀（自定义 scheme 平台与拦截 https 的平台不同）。
  static final String _mediaPrefix = srsMediaUrlPrefix(
    customScheme: webViewUsesCustomSchemeTransport,
  );

  late final SrsCardFaceSync _sync = SrsCardFaceSync(
    evaluate: (String source) async {
      final InAppWebViewController? controller = _controller;
      if (controller == null) return null;
      return controller.evaluateJavascript(source: source);
    },
    reloadShell: _reloadShell,
  );

  /// renderer 死亡处置：卡面是纯只读渲染，内容全在 [widget.face] 里，重建零损失；
  /// flush 只需丢掉报废的 controller，重建后 initialData 是外壳，onLoadStop 时
  /// [SrsCardFaceSync] 把当前这一面整份重放。
  late final WebViewDeathGuard _deathGuard = WebViewDeathGuard(
    surface: 'srs_card_face',
    flushBeforeRebuild: () async {
      _controller = null;
      _sync.detach();
    },
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  SrsCardFaceDocument _document(BuildContext context) => srsCardFaceDocumentFor(
    widget.face,
    theme: Theme.of(context),
    appearance: ref.read(srsCardAppearanceProvider),
    labels: srsCardLabels(),
    mediaUrlPrefix: _mediaPrefix,
    themedScrollbar: srsCardUsesThemedScrollbar,
    fontUrl: (String path) =>
        srsCardFontUrl(path, customScheme: webViewUsesCustomSchemeTransport),
    fonts: ref.read(srsCardFontsProvider),
    fontRoot: ref.read(srsCardFontRootProvider),
  );

  Future<SrsMediaStore?> _mediaStore() async {
    try {
      return await ref.read(srsMediaStoreProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsWebCardFace.mediaStore', e, stack);
      return null;
    }
  }

  Future<WebResourceResponse?> _intercept(Uri url) async {
    if (srsFontPathFromUrl(url) != null) {
      return srsCardFontResponse(
        url,
        fontRoot: ref.read(srsCardFontRootProvider),
        // 只有 Fushi 卡片的卡面供给外观字体。
        whitelist: widget.face.fushiCard
            ? srsCardFontWhitelist(
                ref.read(srsCardFontsProvider),
                fontRoot: ref.read(srsCardFontRootProvider),
              )
            : const <String>{},
      );
    }
    if (srsMediaNameFromUrl(url) == null) return null;
    return srsCardMediaResponse(url, await _mediaStore());
  }

  Future<CustomSchemeResponse?> _interceptCustomScheme(
    WebResourceRequest request,
  ) async {
    if (request.url.scheme != kSrsMediaScheme) return null;
    final WebResourceResponse? r = await _intercept(request.url);
    if (r == null || r.statusCode != 200) return null;
    return CustomSchemeResponse(
      data: r.data ?? Uint8List(0),
      contentType: r.contentType ?? 'application/octet-stream',
      contentEncoding: 'binary',
    );
  }

  Future<void> _playSound(String name) async {
    final SrsMediaStore? store = await _mediaStore();
    final File? file = store?.resolve(name);
    if (file == null || !await file.exists()) {
      FushiToast.show(msg: t.srs_media_missing(name: name));
      return;
    }
    await ref.read(srsSoundPlayerProvider)(file.path);
  }

  @override
  void initState() {
    super.initState();
    // 外观改动（定制页里拖滑块 / 切开关）即时下发：只换主题部分，卡片脚本不重跑。
    ref.listenManual<SrsCardAppearance>(srsCardAppearanceProvider, (_, _) {
      if (mounted) _sync.update(_document(context));
    });
    // 字体库里「复习卡片」用途的字体变了（换序 / 增删 / 下载完成）：同样只换主题部分。
    ref.listenManual<List<Map<String, dynamic>>>(srsCardFontsProvider, (_, _) {
      if (mounted) _sync.update(_document(context));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync.update(_document(context));
    final SrsCardLookupController? lookup = SrsCardLookupScope.of(context);
    if (!identical(lookup, _lookup)) {
      _lookup?.unregister(this);
      _lookup = lookup;
      lookup?.register(this);
      final InAppWebViewController? controller = _controller;
      if (controller != null && _sync.shellReady) {
        unawaited(_installLookup(controller));
      }
    }
  }

  @override
  void dispose() {
    _lookup?.unregister(this);
    if (identical(SrsWebCardFace.debugController, _controller)) {
      SrsWebCardFace.debugController = null;
    }
    super.dispose();
  }

  // ---------------------------------------------------------------- 查词

  Future<void> _evaluateQuiet(String source) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: source);
    } catch (e, stack) {
      // 平台视图半销毁时 evaluate 抛 MissingPluginException：取词失败 no-op。
      ErrorLogService.instance.log('SrsWebCardFace.lookupEval', e, stack);
    }
  }

  String _lookupGateScript() {
    final SrsCardLookupController? lookup = _lookup;
    if (lookup == null) {
      return srsCardLookupGateScript(
        tap: false,
        hover: false,
        hostHover: false,
        open: false,
      );
    }
    final SrsCardLookupSettings settings = lookup.settings;
    return srsCardLookupGateScript(
      tap: settings.tap,
      hover: settings.hoverAuto,
      hostHover: hostOwnsWebViewHoverLookup,
      open: lookup.isOpen,
    );
  }

  /// 装取词脚本（幂等）并下发门控。没有查词作用域时只下发「全关」的门控。
  Future<void> _installLookup(InAppWebViewController controller) async {
    if (_lookup == null) {
      if (_lookupInstalled) await _evaluateQuiet(_lookupGateScript());
      return;
    }
    try {
      if (!_lookupInstalled) {
        await controller.evaluateJavascript(source: _lookupInstallScript);
        _lookupInstalled = true;
      }
      await controller.evaluateJavascript(source: _lookupGateScript());
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsWebCardFace.installLookup', e, stack);
    }
  }

  RenderBox? get _box {
    final RenderObject? r = context.findRenderObject();
    return r is RenderBox && r.attached && r.hasSize ? r : null;
  }

  void _onTextSelected(Object? raw) {
    final SrsCardLookupController? lookup = _lookup;
    final RenderBox? box = _box;
    if (lookup == null || box == null || raw is! String) return;
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    final ReaderSelectionData data = ReaderSelectionData.fromJson(json);
    if (data.text.trim().isEmpty) return;
    final Map<String, double>? r = data.rect;
    final Rect local = r == null
        ? Rect.fromCenter(
            center: box.size.center(Offset.zero),
            width: 1,
            height: 1,
          )
        : Rect.fromLTWH(
            r['x'] ?? 0,
            r['y'] ?? 0,
            r['width'] ?? 0,
            r['height'] ?? 0,
          );
    final Rect anchor = box.localToGlobal(local.topLeft) & local.size;
    lookup.lookup(
      SrsCardLookupRequest(
        term: data.text,
        anchor: anchor,
        sentence: data.sentence.isEmpty ? data.text : data.sentence,
        fromHover: data.fromHover,
        origin: this,
        onMatched: (int count) => unawaited(
          _evaluateQuiet(ReaderSelectionScripts.highlightInvocation(count)),
        ),
      ),
    );
  }

  @override
  bool lookupAt(Offset globalPosition, {required bool fromHover}) {
    final RenderBox? box = _box;
    if (_lookup == null || _controller == null || box == null || !mounted) {
      return false;
    }
    final Offset local = box.globalToLocal(globalPosition);
    if (!readerHostHoverPointInside(local, box.size)) return false;
    unawaited(
      _evaluateQuiet(
        ReaderSelectionScripts.selectInvocation(
          local.dx,
          local.dy,
          400,
          fromHover: fromHover,
        ),
      ),
    );
    return true;
  }

  @override
  void onLookupStateChanged({
    required bool open,
    required SrsCardLookupSurface? origin,
  }) {
    if (!_lookupInstalled) return;
    if (!open) _hostHover.reset();
    unawaited(
      _evaluateQuiet(
        _lookupGateScript() +
            (!open || !identical(origin, this)
                ? ReaderSelectionScripts.clearInvocation()
                : ''),
      ),
    );
  }

  /// macOS：宿主侧悬停腿（页内 mousemove 到不了，见 [ReaderHostHoverLookupGate]）。
  void _onHostHover(PointerHoverEvent event) {
    final SrsCardLookupController? lookup = _lookup;
    if (lookup == null || lookup.isOpen) return;
    if (!_hostHover.shouldLookup(
      event.localPosition,
      shiftPressed: HardwareKeyboard.instance.isShiftPressed,
      hoverAutoLookup: lookup.settings.hoverAuto,
    )) {
      return;
    }
    lookupAt(event.position, fromHover: true);
  }

  @override
  void didUpdateWidget(SrsWebCardFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync.update(_document(context));
  }

  /// 页面被卡片里的链接导航走了：把外壳装回来（onLoadStop 后重放当前内容）。
  void _reloadShell() {
    final InAppWebViewController? controller = _controller;
    if (controller == null || !mounted) return;
    unawaited(
      controller
          .loadData(
            data: _document(context).shellHtml,
            mimeType: 'text/html',
            encoding: 'utf-8',
          )
          .catchError((Object e, StackTrace stack) {
            ErrorLogService.instance.log('SrsWebCardFace.loadShell', e, stack);
          }),
    );
  }

  Future<void> _injectBridge(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: identical(widget.face.bridgeKeys, kSrsReviewBridgeKeys)
            ? srsReviewKeyBridgeScript
            : srsCardFaceBridgeScript(widget.face.bridgeKeys),
      );
      await controller.evaluateJavascript(source: kSrsCardLinkScript);
      final bool height = widget.face.onContentHeight != null;
      final bool wheel = widget.face.onWheel != null;
      final bool zoom = widget.face.onZoomWheel != null;
      if (height || wheel || zoom) {
        await controller.evaluateJavascript(
          source: srsCardMetricsScript(
            height: height,
            wheel: wheel,
            zoom: zoom,
          ),
        );
      }
    } catch (_) {
      // 平台视图正在重建：下一次 onLoadStop 会再注入（脚本自带幂等守卫）。
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget webView = KeyedSubtree(
      key: _deathGuard.rebuildKey,
      child: InAppWebView(
        // 只在平台视图创建时读一次：外壳页，内容由 _sync 在 onLoadStop 后下发。
        initialData: InAppWebViewInitialData(
          data: _document(context).shellHtml,
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: false,
          disableContextMenu: true,
          transparentBackground: false,
          // 卡面媒体经拦截器 / 自定义 scheme 从 SrsMediaStore 供字节（见 srs_card_media.dart）。
          useShouldInterceptRequest: true,
          resourceCustomSchemes: const <String>[kSrsMediaScheme],
          // BUG-3356 同款：WKWebView 默认把屏幕边缘横滑当 WebView 历史前进 / 后退。
          // 本卡面换卡 / 翻面都在同一平台视图上 `loadData`（见 [_syncContent]），历史里
          // 堆着上一张卡 / 正面，侧滑会把画面退回旧卡面而复习状态没动。卡面切换完全由
          // 宿主拥有，关掉。只作用于 iOS / macOS。
          allowsBackForwardNavigationGestures: false,
          // 链接不许把外壳导航走；来源链接交给宿主（[srsCardNavigationPolicy]）。
          // Windows 的实现是给每个文档请求开 DevTools Fetch 拦截（整页加载都要绕
          // 一圈宿主），卡面上不值：那边只靠页内链接脚本（[kSrsCardLinkScript]）拦，
          // 脚本导航走仍由 [SrsCardFaceSync] 重载外壳兜底。
          useShouldOverrideUrlLoading: !isWindowsPlatform,
        ),
        shouldOverrideUrlLoading:
            (
              InAppWebViewController controller,
              NavigationAction action,
            ) async => srsCardNavigationPolicy(
              action.request.url,
              isForMainFrame: action.isForMainFrame,
              onSourceLink: widget.face.onSourceLink,
            ),
        shouldInterceptRequest:
            (InAppWebViewController controller, WebResourceRequest request) =>
                _intercept(request.url),
        onLoadResourceWithCustomScheme:
            (InAppWebViewController controller, WebResourceRequest request) =>
                _interceptCustomScheme(request),
        onWebViewCreated: (InAppWebViewController controller) {
          _controller = controller;
          _sync.detach();
          assert(() {
            SrsWebCardFace.debugController = controller;
            return true;
          }());
          controller.addJavaScriptHandler(
            handlerName: _kSrsBridgeHandler,
            callback: (List<dynamic> arguments) {
              final Object? token = arguments.isEmpty ? null : arguments.first;
              if (token is String && mounted) widget.face.onBridgeKey(token);
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsContentHeightHandler,
            callback: (List<dynamic> arguments) {
              final Object? h = arguments.isEmpty ? null : arguments.first;
              if (h is num && mounted) {
                widget.face.onContentHeight?.call(h.toDouble());
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsWheelHandler,
            callback: (List<dynamic> arguments) {
              final Object? dy = arguments.isEmpty ? null : arguments.first;
              if (dy is num && mounted) {
                widget.face.onWheel?.call(dy.toDouble());
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsZoomWheelHandler,
            callback: (List<dynamic> arguments) {
              final Object? dy = arguments.isEmpty ? null : arguments.first;
              if (dy is num && mounted) {
                widget.face.onZoomWheel?.call(dy.toDouble());
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsSourceLinkHandler,
            callback: (List<dynamic> arguments) {
              final Object? href = arguments.isEmpty ? null : arguments.first;
              final CardSourceLink? link = href is String
                  ? CardSourceLink.tryParse(href)
                  : null;
              if (link != null && mounted) widget.face.onSourceLink?.call(link);
              return null;
            },
          );
          // 卡面取词（阅读器同一份选区脚本回调 onTextSelected，见 [_installLookup]）。
          controller.addJavaScriptHandler(
            handlerName: 'onTextSelected',
            callback: (List<dynamic> arguments) {
              if (mounted && arguments.isNotEmpty) {
                _onTextSelected(arguments.first);
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: 'onTapEmpty',
            callback: (List<dynamic> _) => null,
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsPlaySoundHandler,
            callback: (List<dynamic> arguments) {
              final Object? name = arguments.isEmpty ? null : arguments.first;
              if (name is String && name.isNotEmpty && mounted) {
                srsRunLogged(
                  'SrsWebCardFace.playSound',
                  () => _playSound(name),
                );
              }
              return null;
            },
          );
        },
        onLoadStop: (InAppWebViewController controller, _) {
          // 死亡处置已丢弃 controller：等重建后的新平台视图自己的 onLoadStop。
          if (_controller == null) return;
          _sync.shellLoaded();
          _lookupInstalled = false;
          unawaited(
            _injectBridge(controller).then((_) => _installLookup(controller)),
          );
        },
        // 非 null 本身就是救命动作：Java 侧据此 `return true`，不再连坐杀 app。
        onWebContentProcessDidTerminate: (InAppWebViewController _) =>
            unawaited(_deathGuard.handleWebContentTerminated()),
        onRenderProcessGone:
            (InAppWebViewController _, RenderProcessGoneDetail detail) =>
                unawaited(
                  _deathGuard.handleDeath(
                    didCrash: detail.didCrash,
                    rendererPriorityAtExit: detail.rendererPriorityAtExit,
                  ),
                ),
      ),
    );
    if (_lookup == null || !hostOwnsWebViewHoverLookup) return webView;
    return Listener(onPointerHover: _onHostHover, child: webView);
  }
}

/// 纯文本卡面（测试 / 无 WebView 环境用）：把 HTML 去标签后直接显示。
class SrsPlainCardFace extends StatelessWidget {
  const SrsPlainCardFace({super.key, required this.face});

  final SrsCardFace face;

  @override
  Widget build(BuildContext context) {
    final String text = face.bodyHtml
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .trim();
    // 无 WebView 时文字是原生绘制的：同样可点按 / 悬停取词（有查词作用域时）。
    return SrsNativeLookupRegion(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(FushiDesignTokens.of(context).spacing.card),
        child: srsLookupText(
          text: text,
          child: Text(
            text,
            key: ValueKey<String>(
              face.showingAnswer ? 'srs-face-answer' : 'srs-face-question',
            ),
            style: context.fushiType.titleLarge,
          ),
        ),
      ),
    );
  }
}
