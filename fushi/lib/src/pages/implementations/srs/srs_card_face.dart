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
    show isValidFontData, kReaderWebViewCreationFailedSentinel;
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/reader/reader_host_hover_lookup.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_settings.dart' show ReaderCustomFontCss;
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_autoplay.dart'
    show kSrsCardAutoplayGateScript, srsCardSetAutoplayScript;
import 'package:fushi/src/srs/srs_card_design_skin.dart';
import 'package:fushi/src/srs/srs_card_dict_style.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/srs/srs_card_translation_blur.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:fushi/src/utils/misc/desktop_audio_playback.dart';
import 'package:fushi/src/utils/misc/dictionary_external_link.dart';
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
    this.hostScript = '',
    this.onSourceLink,
    this.autoplayMedia = false,
    this.onPlayAudio,
    this.onCardGesture,
    this.gestureArming = SrsCardGestureArming.none,
    this.onImageTap,
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

  /// WebView 持焦时要交回 Dart 的键：复习页按快捷键注册表当前绑定导出
  /// （`srsReviewBridgeTokens`，可改键），浏览页的预览用 [kSrsBrowseBridgeKeys]；
  /// 不传时是复习页出厂默认键的固定表 [kSrsReviewBridgeKeys]。
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

  /// 宿主追加的外壳脚本（随主题下发一次）。可定义 `window.__fushiSrsHostLayout`：外壳在
  /// 卡片脚本跑完、换主题后都会调它（混合渲染的释义页据此重排词典分组）。脚本内容应当
  /// 固定不变，随设置变化的参数走 [hostCss] 里的 CSS 变量（主题键只比脚本长度）。
  final String hostScript;

  /// 卡面里点了 Fushi 制卡写进 MiscInfo 的来源链接（`fushi://source?...`）：宿主据此
  /// 跳回书 / 漫画 / 视频的对应位置（`openCardSource`）。null = 来源链接不响应。其它
  /// 链接一律不导航（卡面外壳不能被链接带走）。
  final void Function(CardSourceLink link)? onSourceLink;

  /// 卡面页面自己发起的媒体播放（同步片段的 `oncanplay`、`autoplay` 属性）是否放行。
  /// false = 只放行用户在卡面上点按 / 按键直接引起的播放（牌组关了自动播放，
  /// 见 srs_card_autoplay.dart 的 [kSrsCardAutoplayGateScript]，BUG-3546）。
  ///
  /// 缺省 false（#3）：只有复习页按牌组的「自动播放」显式打开。浏览预览、笔记编辑页（查词
  /// 弹窗「跳转到卡片」打开的就是它）、模板 / 外观 / 字段说明预览都是打开或编辑卡片的场景，
  /// 以前吃到缺省 true，一打开视频片段就自己出声。
  final bool autoplayMedia;

  /// 卡面上的发音键（`[sound:]` 播放按钮、原生卡面的单词 / 例句发音键）交给宿主的那条
  /// 播放序列播。复习页给出它：卡面按钮、底栏重播、R 键与自动播放共用同一个序列，新的
  /// 一段打断上一段，同一时刻只出一路声音（#10）。null = 卡面自己直接播（预览页）。
  final void Function(List<String> names)? onPlayAudio;

  /// 卡面手势（点空白 / 双击 / 长按空白 / 滑动，见 [SrsCardGestureEvent]）：WebView 卡面经
  /// 页内指针脚本（[kSrsCardLookupScript]）、原生卡面经 [SrsCardGestureRegion] 回报，判据同一套
  /// （点在字、链接、按钮、可点元素上不算点空白）。复习页按手势映射执行（默认点空白切换
  /// 悬浮顶栏，与小说、漫画阅读器同一口径）。null = 不识别。
  final void Function(SrsCardGestureEvent event)? onCardGesture;

  /// 这一面开着的识别器（没绑动作的手势不识别：不为双击推迟单击、不接管拖动 / 长按）。
  final SrsCardGestureArming gestureArming;

  /// 卡面正文里点了图片（`src` 是页内地址：媒体库虚拟域 / 自定义 scheme / `data:`）：
  /// 宿主据此全屏查看（[srsMediaNameFromUrl] 换回媒体名）。null = 图片点击不拦。
  final void Function(String src)? onImageTap;

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
        hostScript: hostScript,
        onSourceLink: onSourceLink,
        autoplayMedia: autoplayMedia,
        onPlayAudio: onPlayAudio,
        onCardGesture: onCardGesture,
        gestureArming: gestureArming,
        onImageTap: onImageTap,
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
  // 重播音频（对齐 Anki 的 R）。
  'KeyR',
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

/// 页内词典链接 / 外链点击 → 宿主（见 [kSrsCardLinkScript]，#16）。参数是一个对象：
/// `{kind: 'external', href}` 或 `{kind: 'lookup', query, x, y, width, height}`（链接在
/// 页面里的矩形，CSS 像素）。
const String kSrsCardLinkHandler = 'onSrsCardLink';

/// 卡面链接：捕获阶段拦下所有 `<a href>` 的默认导航（卡面外壳不能被链接带走；页内
/// `#锚点` 与 `javascript:` 不算导航，放行），然后按链接种类交给宿主，与查词弹窗
/// （popup.js 的 `handleGlossaryAnchorClick` / 结构化内容链接）同一套判据（#16）：
///
/// - `fushi://source`：Fushi 来源链接，跳回书 / 漫画 / 视频（[kSrsSourceLinkHandler]）。
/// - `http(s)://`：外链，宿主用系统浏览器打开。
/// - `sound:`：词典发音媒体节点，不是查词目标，忽略。
/// - 其余（Yomitan 结构化内容的 `?query=词`、MDX 的 `entry://词`、`bword://` 等词典内部
///   交叉引用，如明鏡「➡ よほど」）：查词。查询词优先取 `?query=`，否则取链接的**基字**
///   文本（剥掉 `rt` / `rp` / `.ruby-rt` / `.ruby-reserve` 振假名，见 popup.js
///   `linkVisibleBaseText`，BUG-2456）。
///
/// 不 stopPropagation：卡片模板自己挂在链接上的点击脚本照常执行。
const String kSrsCardLinkScript = r'''
(function(){
  if (window.__fushiSrsLinks) return;
  window.__fushiSrsLinks = true;
  function call(name, arg){
    try { window.flutter_inappwebview.callHandler(name, arg); } catch (err) {}
  }
  function baseText(root){
    var out = '';
    (function walk(node){
      if (node.nodeType === 3) { out += node.textContent || ''; return; }
      if (node.nodeType !== 1) return;
      var tag = node.tagName;
      if (tag === 'RT' || tag === 'RP') return;
      var cls = node.classList;
      if (cls && (cls.contains('ruby-rt') || cls.contains('ruby-reserve'))) return;
      for (var i = 0; i < node.childNodes.length; i++) walk(node.childNodes[i]);
    })(root);
    return out.replace(/\s+/g, ' ').trim();
  }
  function queryOf(href, a){
    var q = href.indexOf('?');
    if (q >= 0) {
      try {
        var v = new URLSearchParams(href.substring(q)).get('query');
        if (v) return v;
      } catch (err) {}
    }
    return baseText(a);
  }
  document.addEventListener('click', function(e){
    var t = e.target;
    var a = t && t.closest ? t.closest('a[href]') : null;
    if (!a) return;
    var href = (a.getAttribute('href') || '').trim();
    if (href.charAt(0) === '#' || /^javascript:/i.test(href)) return;
    e.preventDefault();
    if (/^fushi:\/\/source/i.test(href)) {
      call('onSrsSourceLink', href);
      return;
    }
    if (/^https?:\/\//i.test(href)) {
      call('onSrsCardLink', {kind: 'external', href: href});
      return;
    }
    if (/^sound:/i.test(href)) return;
    var query = queryOf(href, a);
    if (!query) return;
    var r = a.getBoundingClientRect();
    call('onSrsCardLink', {kind: 'lookup', query: query, x: r.left, y: r.top,
      width: r.width, height: r.height});
  }, true);
})();
''';

/// 页内链接点击的一次解析结果（[kSrsCardLinkHandler] 的参数）。
@immutable
sealed class SrsCardLinkAction {
  const SrsCardLinkAction();

  /// 解析桥参数；不认识的形状返回 null。
  static SrsCardLinkAction? parse(Object? raw) {
    if (raw is! Map) return null;
    final Object? kind = raw['kind'];
    if (kind == 'external') {
      final Object? href = raw['href'];
      return href is String && href.isNotEmpty
          ? SrsCardExternalLink(href)
          : null;
    }
    if (kind == 'lookup') {
      final Object? query = raw['query'];
      if (query is! String || query.trim().isEmpty) return null;
      double n(String key) {
        final Object? v = raw[key];
        return v is num ? v.toDouble() : 0;
      }

      return SrsCardLookupLink(
        query.trim(),
        Rect.fromLTWH(n('x'), n('y'), n('width'), n('height')),
      );
    }
    return null;
  }
}

/// 外链：系统浏览器打开（只放行 http / https，见 [openDictionaryExternalLink]）。
final class SrsCardExternalLink extends SrsCardLinkAction {
  const SrsCardExternalLink(this.href);

  final String href;
}

/// 词典内部交叉引用：查 [query]；[rect] 是链接在页面里的矩形（弹窗锚点）。
final class SrsCardLookupLink extends SrsCardLinkAction {
  const SrsCardLookupLink(this.query, this.rect);

  final String query;
  final Rect rect;
}

/// 页内图片点击 → 宿主（见 [kSrsCardImageTapScript]）。
const String kSrsImageTapHandler = 'onSrsImageTap';

/// 卡面图片点按放大：冒泡阶段收 `.card` 里 `<img>` 的点击，把 `currentSrc` 交给宿主。
/// 卡片模板自己处理了的点击（链接里的图、带 `onclick` 的图或祖先、已
/// `preventDefault`）不抢，模板的点图翻转 / 显示提示照常。
const String kSrsCardImageTapScript = r'''
(function(){
  if (window.__fushiSrsImageTap) return;
  window.__fushiSrsImageTap = true;
  document.addEventListener('click', function(e){
    if (e.defaultPrevented || e.button !== 0) return;
    var t = e.target;
    if (!t || t.tagName !== 'IMG' || !t.closest('.card')) return;
    if (t.closest('a[href],button,[onclick]')) return;
    var src = t.currentSrc || t.src || '';
    if (!src) return;
    try { window.flutter_inappwebview.callHandler('onSrsImageTap', src); } catch (err) {}
  });
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
///
/// 挂在 `window` 捕获阶段，并由外壳 `<head>` 先于卡片内容装好（[srsCardShellHtml]）：
/// 卡片模板（导入的 Lapis 等）自己的 keydown 监听在它之后，截不走翻面 / 评分键
/// （OO3O-3ljda：macOS 上点过卡面后 WKWebView 持有 first responder，按键只剩这条桥）。
String srsCardFaceBridgeScript(List<String> keys) => webViewKeyBridgeScript(
  handlerName: _kSrsBridgeHandler,
  keys: keys,
  forwardRepeats: false,
  stopPropagation: true,
  listenOnWindow: true,
);

/// 卡面按键诊断回调（[kSrsCardKeyDiagScript]）。
const String kSrsKeyDiagHandler = 'onSrsKeyDiag';

/// 卡面按键取证（OO3O-3ljda）：翻面键（空格 / Enter）在页面里按下、却没被键盘桥接走时，
/// 在松开那一刻报一次原因——`editable`（焦点在输入框 / contenteditable，桥按设计放行）、
/// `composing`（IME 组字中）、`missed`（桥没接走：键表里没有 / 弹窗模态让位等）。被桥正常
/// 接走（`defaultPrevented`）不报。页面里根本收不到 keydown（first responder 不在
/// WebView 上）时这里什么都不报，宿主侧的焦点日志补那一半。
const String kSrsCardKeyDiagScript = r'''
(function(){
  if (window.__fushiSrsKeyDiag) return;
  window.__fushiSrsKeyDiag = true;
  var last = null;
  function watched(e){ return e && (e.code === 'Space' || e.code === 'Enter' || e.code === 'NumpadEnter'); }
  window.addEventListener('keydown', function(e){
    if (!watched(e) || e.repeat) return;
    var t = e.target;
    var tag = t && t.tagName ? t.tagName.toUpperCase() : '';
    last = { code: e.code, ev: e, bubbled: false,
      editable: tag === 'INPUT' || tag === 'TEXTAREA' || !!(t && t.isContentEditable),
      composing: !!e.isComposing, target: tag };
  }, true);
  window.addEventListener('keydown', function(e){
    if (last && last.ev === e) last.bubbled = true;
  }, false);
  window.addEventListener('keyup', function(e){
    var k = last;
    last = null;
    if (!k || !watched(e) || e.code !== k.code) return;
    if (k.ev.defaultPrevented) return;
    var reason = k.composing ? 'composing' : k.editable ? 'editable' : 'missed';
    try {
      window.flutter_inappwebview.callHandler('onSrsKeyDiag',
        JSON.stringify({ code: k.code, reason: reason, target: k.target, bubbled: k.bubbled }));
    } catch (err) {}
  }, true);
})();
''';

/// 复习页的卡面键盘桥脚本。
final String srsReviewKeyBridgeScript = srsCardFaceBridgeScript(
  kSrsReviewBridgeKeys,
);

/// [keys] 对应的卡面键盘桥脚本（复习页那份只生成一次）。
String srsCardFaceBridgeScriptFor(List<String> keys) =>
    identical(keys, kSrsReviewBridgeKeys)
    ? srsReviewKeyBridgeScript
    : srsCardFaceBridgeScript(keys);

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
///
/// [background] 为 null 时 html/body 透明：WebView 本身也是透明的，透出复习页背景，
/// 卡片 CSS 自己不铺底色（或写 `transparent`）时就不会再叠一层宿主底色。
@visibleForTesting
String srsCardThemeCss({
  required bool dark,
  required Color? background,
  required Color foreground,
  required Color accent,
  required Color onAccent,
  required bool themedScrollbar,
  String appearanceCss = '',
}) =>
    ':root{color-scheme:${dark ? 'dark' : 'light'};'
    '--fushi-srs-accent:${_cssColor(accent)};'
    '--fushi-srs-on-accent:${_cssColor(onAccent)};}'
    'html,body{background:${background == null ? 'transparent' : _cssColor(background)};'
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
  // 设计系统样式覆盖（srs_card_design_skin.dart）：只在覆盖开着时随主题下发定义；卡片脚本
  // 与钩子都跑完、DOM 定型后再判定。
  function designSkin(){
    try {
      if (window.__fushiSrsDesignSkin) window.__fushiSrsDesignSkin();
    } catch (e) {
      if (window.console) console.error(e);
    }
  }
  // 例句翻译模糊（srs_card_translation_blur.dart）：只在开关开着时随主题下发定义；按 body 的
  // 宿主类名给翻译行加 / 撤可聚焦属性。换卡后（新节点）与换主题后（开关变了）各跑一次。
  function translationBlur(){
    try {
      if (window.__fushiSrsTranslationBlur) window.__fushiSrsTranslationBlur();
    } catch (e) {
      if (window.console) console.error(e);
    }
  }
  // 宿主排版钩子（SrsCardFace.hostScript 定义）：卡片脚本与钩子都跑完后再排。
  function hostLayout(){
    try {
      if (window.__fushiSrsHostLayout) window.__fushiSrsHostLayout();
    } catch (e) {
      if (window.console) console.error(e);
    }
  }
  function finish(my, ok){
    if (ok !== true || my !== seq) return;
    dictStyle();
    runHooks(window.onUpdateHook);
    runHooks(window.onShownHook);
    designSkin();
    translationBlur();
    hostLayout();
  }
  window.__fushiSrsSetTheme = function(themeCss, classes){
    document.getElementById('fushi-theme-css').textContent = themeCss;
    setClasses(classes);
    dictStyle();
    designSkin();
    translationBlur();
    // 卡片脚本可据此跟随外观变化（例如「全部释义默认展开」），不必重跑。
    try {
      document.dispatchEvent(new CustomEvent('fushi-srs-theme', { detail: classes }));
    } catch (e) {}
    hostLayout();
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
    // 卡面根之外还在响的（脱离文档的 new Audio()、shadow root 里的）：自动播放闸门记着。
    if (window.__fushiSrsStopAllMedia) window.__fushiSrsStopAllMedia();
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
///
/// [bridgeScript]：卡面的键盘桥（[srsCardFaceBridgeScript]），排在一切卡片内容之前装好，
/// 连同按键取证脚本（[kSrsCardKeyDiagScript]）。
String srsCardShellHtml({
  required String themeCss,
  required String classes,
  String bridgeScript = '',
}) {
  final String cls = classes.isEmpty ? 'card' : 'card $classes';
  return '<!doctype html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1">'
      '${bridgeScript.isEmpty ? '' : '<script>$bridgeScript</script><script>$kSrsCardKeyDiagScript</script>'}'
      '<style>html,body{margin:0;padding:0;}'
      'body{padding:16px;box-sizing:border-box;}</style>'
      '<style id="fushi-theme-css">$themeCss</style>'
      '<style>$kSrsCardMediaCss</style>'
      '<script>$kSrsCardMediaScript</script>'
      // 自动播放闸门要在卡片内容与卡片脚本之前装好（BUG-3546）。
      '<script>$kSrsCardAutoplayGateScript</script>'
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

/// 一次下发的整段调用：外壳不在返回 `false`；各步依次执行、各自兜住异常（换主题出错
/// 不能把换卡也拦下，否则卡面停在外壳底色、什么都不报，BUG-3579），全部成功返回 `true`，
/// 有步骤抛错返回错误文本（宿主据此留痕）。
@visibleForTesting
String srsCardFaceCallsScript(List<String> steps) {
  final StringBuffer out = StringBuffer(
    '(function(){if(typeof window.__fushiSrsSetCard!=="function")'
    'return false;var errs=[];',
  );
  for (final String step in steps) {
    out.write(
      'try{$step}catch(e){errs.push(String(e&&e.stack||e).slice(0,500));}',
    );
  }
  out.write('return errs.length?errs.join("\\n"):true;})()');
  return out.toString();
}

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
    this.autoplayMedia = true,
    this.hostScript = '',
    this.bridgeScript = '',
  });

  /// 由一面卡与主题算出（媒体引用改写、`lang` 包裹都在这里做）。
  factory SrsCardFaceDocument.of(
    SrsCardFace face, {
    required bool dark,
    required Color? background,
    required Color foreground,
    required Color accent,
    required Color onAccent,
    required String mediaUrlPrefix,
    required bool themedScrollbar,
    String appearanceCss = '',
    String appearanceClasses = '',
    String hostScript = '',
  }) {
    final ({String body, List<String> styles}) prepared = srsPrepareCardBody(
      face.bodyHtml,
      mediaUrlPrefix,
    );
    return SrsCardFaceDocument(
      hostScript: hostScript,
      bridgeScript: srsCardFaceBridgeScriptFor(face.bridgeKeys),
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
      bodyHtml: wrapAnkiCardHtmlWithLang(prepared.body, face.languageCode),
      bodyStyles: prepared.styles,
      autoplayMedia: face.autoplayMedia,
    );
  }

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

  /// 见 [SrsCardFace.autoplayMedia]。
  final bool autoplayMedia;

  /// 随主题下发、先于 `__fushiSrsSetTheme` 执行的宿主脚本（幂等定义；空 = 不下发）：设计系统
  /// 样式覆盖的判定脚本、Fushi 卡片的例句翻译模糊脚本。开关关着时外壳里连脚本都没有（零注入）。
  final String hostScript;

  /// 卡面的键盘桥脚本（写进外壳 `<head>`，见 [srsCardShellHtml]）。
  final String bridgeScript;

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
      srsCardSetAutoplayScript(autoplay: autoplayMedia),
      srsCardSetCardScript(
        styleRefs: <String>[for (final SrsCardStyle st in all) st.hash],
        bodyHtml: bodyHtml,
        classes: classes,
      ),
    ].join();
  }

  String get _themeKey => '$themeCss\u0000$classes\u0000${hostScript.length}';

  /// 换了卡（哪怕正文一字不差）也要重放：滚回顶部、重跑卡片脚本。夜间类名与外观
  /// （变量、类名、字体）都不在里面：只换主题 / 外观时走 `__fushiSrsSetTheme`，不重跑
  /// 卡片脚本。
  /// 自动播放开关也在里面：复习中改了牌组设置，当前这一面按新开关重放（刚打开 →
  /// 片段按新设置自己播一次；刚关掉 → 重放时停掉正在播的媒体），与宿主侧
  /// `[sound:]` 的处理一致。
  String get _cardKey =>
      '$cardId\u0000$showingAnswer\u0000$autoplayMedia\u0000'
      '${styles.map((SrsCardStyle s) => s.hash).join(',')}\u0000$bodyHtml';

  String get shellHtml => srsCardShellHtml(
    themeCss: themeCss,
    classes: classes,
    bridgeScript: bridgeScript,
  );
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
    final List<String> steps = <String>[];
    final Set<String> defining = <String>{};
    final String themeKey = doc._themeKey;
    final String cardKey = doc._cardKey;
    if (themeKey != _appliedTheme) {
      steps.add(
        doc.hostScript +
            srsCardSetThemeScript(themeCss: doc.themeCss, classes: doc.classes),
      );
    }
    if (cardKey != _appliedCard) {
      final List<SrsCardStyle> styles = doc.styles;
      final StringBuffer card = StringBuffer();
      for (final SrsCardStyle st in styles) {
        if (_definedStyles.contains(st.hash) || !defining.add(st.hash)) {
          continue;
        }
        card.write(srsCardDefineCssScript(st));
      }
      // 开关先于换卡下发：新内容插入、卡片脚本重放时闸门已是这张卡的设置。
      card.write(srsCardSetAutoplayScript(autoplay: doc.autoplayMedia));
      steps.add(card.toString());
      steps.add(
        srsCardSetCardScript(
          styleRefs: <String>[for (final SrsCardStyle st in styles) st.hash],
          bodyHtml: doc.bodyHtml,
          classes: doc.classes,
        ),
      );
    }
    if (steps.isEmpty) return;
    _appliedTheme = themeKey;
    _appliedCard = cardKey;
    _definedStyles.addAll(defining);
    final int generation = ++_generation;
    void invalidate() {
      // 同一代之后没有新下发时才作废：下次 update / 外壳就绪整份重发。
      if (generation != _generation) return;
      _appliedTheme = null;
      _appliedCard = null;
      _definedStyles.removeAll(defining);
    }

    unawaited(
      evaluate(srsCardFaceCallsScript(steps)).then(
        (Object? result) {
          if (generation != _generation) return;
          if (result == true) {
            _reloadedShell = false;
          } else if (result == false) {
            // 页面已不是外壳（被卡片链接导航走了）：重载外壳一次，onLoadStop 后重放。
            if (_reloadedShell) return;
            _reloadedShell = true;
            detach();
            reloadShell();
          } else if (result is String) {
            // 某一步在页内抛错（其余步骤照常执行，见 [srsCardFaceCallsScript]）：留痕。
            ErrorLogService.instance.log(
              'SrsWebCardFace.setCard',
              StateError(result),
              StackTrace.current,
            );
          } else {
            // 调用整体没执行（平台视图没了 / 脚本没能运行，Windows 上页内顶层异常也是
            // null）：这一份没有上屏，不能当作已下发。
            ErrorLogService.instance.log(
              'SrsWebCardFace.setCard',
              StateError('card face calls returned $result'),
              StackTrace.current,
            );
            invalidate();
          }
        },
        onError: (Object e, StackTrace stack) {
          ErrorLogService.instance.log('SrsWebCardFace.setCard', e, stack);
          invalidate();
        },
      ),
    );
  }
}

/// 卡面 `[sound:]` 的播放实现（测试覆写）。参数是本地文件路径；返回是否开始播放。
typedef SrsSoundPlayer = Future<bool> Function(String path);

/// 生产实现：app 共用的 just_audio 播放器（串行化激活，见 [DesktopAudioPlayback]），
/// 音量取开播那一刻的 [srsReviewVolumeProvider]。
final Provider<SrsSoundPlayer> srsSoundPlayerProvider =
    Provider<SrsSoundPlayer>(
      (Ref ref) =>
          (String path) => DesktopAudioPlayback.playFile(
            path,
            volume: ref.read(srsReviewVolumeProvider),
          ),
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

/// 本平台卡面媒体的 URL 前缀（自定义 scheme 平台与拦截 https 的平台不同）。
final String srsCardMediaUrlPrefix = srsMediaUrlPrefix(
  customScheme: webViewUsesCustomSchemeTransport,
);

/// [srsCardFaceDocumentFor] 的输入（卡面 State 据此判断文档要不要重算）。字符串字段按值比
/// （同一张卡的正文是同一个对象，`==` 先比引用）；主题 / 外观按各自的 `==`；字体链按引用
/// （provider 换链才换列表）。
@immutable
class SrsCardFaceDocumentInputs {
  const SrsCardFaceDocumentInputs({
    required this.face,
    required this.theme,
    required this.appearance,
    required this.labels,
    required this.fonts,
    required this.fontRoot,
  });

  final SrsCardFace face;
  final ThemeData theme;
  final SrsCardAppearance appearance;
  final SrsCardLabels labels;
  final List<Map<String, dynamic>> fonts;
  final String? fontRoot;

  @override
  bool operator ==(Object other) {
    if (other is! SrsCardFaceDocumentInputs) return false;
    final SrsCardFace a = face, b = other.face;
    return a.cardId == b.cardId &&
        a.showingAnswer == b.showingAnswer &&
        a.fushiCard == b.fushiCard &&
        a.layout == b.layout &&
        a.pageZoom == b.pageZoom &&
        a.languageCode == b.languageCode &&
        a.bodyHtml == b.bodyHtml &&
        a.css == b.css &&
        a.hostCss == b.hostCss &&
        a.hostScript == b.hostScript &&
        // 复习中改牌组「自动播放」要立即重下发（BUG-3547）：不比它会命中旧文档。
        a.autoplayMedia == b.autoplayMedia &&
        identical(fonts, other.fonts) &&
        fontRoot == other.fontRoot &&
        appearance == other.appearance &&
        labels.allDefinitions == other.labels.allDefinitions &&
        labels.frequency == other.labels.frequency &&
        labels.source == other.labels.source &&
        labels.showMore == other.labels.showMore &&
        theme == other.theme;
  }

  @override
  int get hashCode => Object.hash(face.cardId, face.showingAnswer, theme);
}

/// 卡面 State 的文档缓存：输入 + 文档 + 外壳 HTML（外壳只在平台视图创建时用，懒算）。
class SrsCardFaceDocumentCache {
  SrsCardFaceDocumentCache(this.inputs, this.document);

  final SrsCardFaceDocumentInputs inputs;
  final SrsCardFaceDocument document;
  late final String shellHtml = document.shellHtml;
}

/// 预取到的下一张卡：提前把它的笔记类型样式与两面正文的预处理（媒体引用改写、抽 `<style>`、
/// 样式哈希）算进记忆表。真正显示时 [SrsCardFaceDocument.of] 全部命中，主 isolate 上只剩
/// 拼主题样式与下发。
void srsWarmCardFace({required String css, required List<String> bodies}) {
  final String prefix = srsCardMediaUrlPrefix;
  final String localizedCss = _memo(
    _localizedCssMemo,
    '$prefix\u0000$css',
    () => srsLocalizeCardCss(css, urlPrefix: prefix),
  );
  if (localizedCss.isNotEmpty) srsCardStyleHash(localizedCss);
  for (final String body in bodies) {
    for (final String style in srsPrepareCardBody(body, prefix).styles) {
      srsCardStyleHash(style);
    }
  }
}

/// 卡面是否自己铺底色：只有 Fushi 卡片用了自定义配色（[SrsCardColorSource.custom]）
/// 时铺它的 surface；跟随 app 主题时与页面背景同色，铺了只会盖住路由层的形状背景。
/// 原生卡面（`SrsFushiCardView`）与 WebView 外壳共用这一条判据。
bool srsCardPaintsOwnSurface(SrsCardFace face, SrsCardAppearance appearance) =>
    face.fushiCard && appearance.colorSource == SrsCardColorSource.custom;

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
  // 其它卡片类型的设计系统样式覆盖（关 = 零注入：不加样式、类名与脚本）。
  final bool skin = !fushi && appearance.designSkin;
  final ColorScheme scheme = fushi
      ? srsCardColorScheme(appearance, theme.colorScheme)
      : theme.colorScheme;
  return SrsCardFaceDocument.of(
    face,
    dark: dark,
    // 宿主默认不铺底：卡面透出复习页背景（路由层的形状背景）。只有 Fushi 卡用了自定义
    // 配色时才铺它的 surface（与页面背景不同色，是用户选的卡面底色）；其它卡片类型
    // 对齐 Anki，底色归卡片 CSS。
    background: srsCardPaintsOwnSurface(face, appearance)
        ? scheme.surface
        : null,
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
        : skin
        ? srsCardDesignSkinCss(
            scheme: scheme,
            tokens: SrsCardTokens.fromTheme(theme),
          )
        : '',
    appearanceClasses: fushi
        ? <String>[
            srsCardAppearanceClasses(appearance),
            // 墨水屏：卡面注入的过渡瞬间到位（系统「减弱动态效果」走页内 prefers-reduced-motion）。
            if (theme.extension<FushiEinkTheme>()?.einkMode ?? false)
              kSrsCardNoMotionClass,
          ].where((String c) => c.isNotEmpty).join(' ')
        : skin
        ? kSrsDesignSkinClass
        : '',
    hostScript:
        (skin ? kSrsCardDesignSkinScript : '') +
        (fushi && appearance.showTranslation && appearance.blurTranslation
            ? kSrsCardTranslationBlurScript
            : '') +
        face.hostScript,
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

  /// 集成测试探针：卡面每个经拦截器供出的媒体 / 字体请求（URL、字节数、耗时毫秒）。
  @visibleForTesting
  static void Function(Uri url, int bytes, int ms)? debugMediaServed;

  @override
  ConsumerState<SrsWebCardFace> createState() => _SrsWebCardFaceState();
}

class _SrsWebCardFaceState extends ConsumerState<SrsWebCardFace>
    implements SrsCardLookupSurface {
  InAppWebViewController? _controller;

  /// 卡面查词（[SrsCardLookupScope] 给出；null = 这面卡不取词，如外观页预览、正面预热的
  /// 释义 WebView）。
  SrsCardLookupController? _lookup;

  /// 当前外壳里已装好指针脚本（取词 + 卡面手势；外壳重载 / renderer 重建后重装）。
  bool _lookupInstalled = false;

  /// 上一次下发给页面的卡面手势门控（null = 没下发过 / 外壳重载后作废）。
  String? _pushedGestureGate;

  /// 要不要装指针脚本：有查词作用域（取词）或宿主要卡面手势。
  bool get _wantsPointerScript =>
      _lookup != null || widget.face.onCardGesture != null;

  String _gestureGateScript() => srsCardGestureGateScript(
    widget.face.onCardGesture == null ? null : widget.face.gestureArming,
  );

  /// 平台视图创建失败后重建过一次（只重来一次，再失败只留痕）。
  bool _recreatedAfterFailure = false;
  int _creationAttempt = 0;

  /// 外壳主文档加载失败后重载过一次。
  bool _reloadedAfterLoadError = false;

  /// macOS 宿主侧悬停腿（页面收不到 mousemove，BUG-2508）。
  final ReaderHostHoverLookupGate _hostHover = ReaderHostHoverLookupGate();

  /// 取词脚本整段（选区脚本 + 卡面监听）只拼一次。
  static final String _lookupInstallScript = srsCardLookupInstallScript(
    ReaderSelectionScripts.source(),
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
    // 死亡 / 重建进随反馈上传的诊断日志（缺省只 debugPrint，release 里看不到）。
    reporter: (String surface, String message) => ErrorLogService.instance
        .logDiagnostic('SrsWebCardFace.death', '$surface: $message'),
  );

  /// 这面卡报过几次「翻面键没被桥接走」（[kSrsCardKeyDiagScript]）；封顶免得刷满诊断日志。
  int _keyDiagReports = 0;
  static const int _kMaxKeyDiagReports = 5;

  /// 这面卡建过几次平台视图（正常一生只建一次；死亡重建 / 结构变动会再建）。
  int _viewsCreated = 0;

  /// 进程里此刻活着的卡面 WebView State 数（诊断用）。
  static int _liveFaces = 0;

  /// 平台视图建了第二次及以后时留一条诊断（含卡面身份与存活数）：卡面应当整段复习
  /// 复用同一个平台视图，反复重建就是卡顿与 `installLookup` 打进死通道的来源（O1yqRPUyut）。
  void _noteViewCreated() {
    _viewsCreated++;
    if (_viewsCreated == 1) return;
    ErrorLogService.instance.logDiagnostic(
      'SrsWebCardFace.lifecycle',
      'platform view created #$_viewsCreated for ${widget.face.cardId} '
          '(lookup=${_lookup != null}, liveFaces=$_liveFaces, '
          'epoch=${_deathGuard.epoch})',
    );
  }

  /// 上一次算文档用的输入与结果：复习页换一张卡要重建这面卡 4~5 次（忙碌态开 / 新卡 /
  /// 忙碌态关 / 补算预览），每次 didUpdateWidget 与 build 都要文档；输入没变就原样复用，
  /// 不再每次重拼主题样式、外壳 HTML 与几十 KB 的卡片键。
  SrsCardFaceDocumentCache? _docCache;

  SrsCardFaceDocument _document(BuildContext context) {
    final SrsCardFaceDocumentInputs inputs = SrsCardFaceDocumentInputs(
      face: widget.face,
      theme: Theme.of(context),
      appearance: ref.read(srsCardAppearanceProvider),
      labels: srsCardLabels(),
      fonts: ref.read(srsCardFontsProvider),
      fontRoot: ref.read(srsCardFontRootProvider),
    );
    final SrsCardFaceDocumentCache? hit = _docCache;
    if (hit != null && hit.inputs == inputs) return hit.document;
    final SrsCardFaceDocument document = srsCardFaceDocumentFor(
      inputs.face,
      theme: inputs.theme,
      appearance: inputs.appearance,
      labels: inputs.labels,
      mediaUrlPrefix: srsCardMediaUrlPrefix,
      themedScrollbar: srsCardUsesThemedScrollbar,
      fontUrl: (String path) =>
          srsCardFontUrl(path, customScheme: webViewUsesCustomSchemeTransport),
      fonts: inputs.fonts,
      fontRoot: inputs.fontRoot,
    );
    _docCache = SrsCardFaceDocumentCache(inputs, document);
    return document;
  }

  Future<SrsMediaStore?> _mediaStore() async {
    try {
      return await ref.read(srsMediaStoreProvider.future);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsWebCardFace.mediaStore', e, stack);
      return null;
    }
  }

  Future<WebResourceResponse?> _intercept(Uri url) async {
    final void Function(Uri, int, int)? probe = SrsWebCardFace.debugMediaServed;
    if (probe == null) return _serve(url);
    final Stopwatch sw = Stopwatch()..start();
    final WebResourceResponse? r = await _serve(url);
    if (r != null) probe(url, r.data?.length ?? 0, sw.elapsedMilliseconds);
    return r;
  }

  Future<WebResourceResponse?> _serve(Uri url) async {
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
    _liveFaces++;
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
    _liveFaces--;
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

  /// 装指针脚本（取词 + 卡面手势，幂等）并下发两份门控。既没有查词作用域、宿主也不要
  /// 手势时只给已装的脚本下发「全关」。
  Future<void> _installLookup(InAppWebViewController controller) async {
    if (!_wantsPointerScript) {
      if (_lookupInstalled) {
        await _evaluateQuiet(_lookupGateScript() + _gestureGateScript());
      }
      return;
    }
    try {
      if (!_lookupInstalled) {
        await controller.evaluateJavascript(source: _lookupInstallScript);
        // 注入期间平台视图换了（死亡重建 / 卡面卸载）：这只 controller 的通道已经没了，
        // 新视图自己的 onLoadStop 会重装。
        if (!mounted || !identical(_controller, controller)) return;
        _lookupInstalled = true;
      }
      final String gestureGate = _gestureGateScript();
      await controller.evaluateJavascript(
        source: _lookupGateScript() + gestureGate,
      );
      _pushedGestureGate = gestureGate;
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsWebCardFace.installLookup', e, stack);
    }
  }

  /// 换面 / 改了手势映射：开着的识别器变了就重发手势门控（不重装脚本、不重放卡面）。
  void _syncGestureGate() {
    final InAppWebViewController? controller = _controller;
    if (controller == null || !_sync.shellReady) return;
    if (!_lookupInstalled) {
      if (_wantsPointerScript) unawaited(_installLookup(controller));
      return;
    }
    final String gate = _gestureGateScript();
    if (gate == _pushedGestureGate) return;
    _pushedGestureGate = gate;
    unawaited(_evaluateQuiet(gate));
  }

  /// 页内脚本回报的卡面手势（[kSrsGestureHandler]）：页面 CSS 像素换成全局逻辑像素。
  void _onPageGesture(Object? raw) {
    final void Function(SrsCardGestureEvent)? onGesture =
        widget.face.onCardGesture;
    final RenderBox? box = _box;
    if (onGesture == null || box == null) return;
    final Matrix4 toGlobal = box.getTransformTo(null);
    final SrsCardGestureEvent? event = srsCardGestureFromPage(
      raw,
      viewWidth: box.size.width,
      viewHeight: box.size.height,
      toGlobal: (Offset local) => MatrixUtils.transformPoint(toGlobal, local),
    );
    if (event != null) onGesture(event);
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
    // 整个矩形经同一变换：复习页不在 FushiAppUiScaleNeutralizer 之下，「全局左上角 & 局部
    // 尺寸」会把高宽留在 1/界面缩放，弹窗按偏高的下沿摆、盖住被查的那一行。
    final Rect anchor = MatrixUtils.transformRect(
      box.getTransformTo(null),
      local,
    );
    lookup.lookup(
      SrsCardLookupRequest(
        term: data.text,
        anchor: anchor,
        sentence: data.sentence.isEmpty ? data.text : data.sentence,
        fromHover: data.fromHover,
        origin: this,
        rubySpans: data.rubySpans,
        onMatched: (int count) => unawaited(
          _evaluateQuiet(ReaderSelectionScripts.highlightInvocation(count)),
        ),
      ),
    );
  }

  /// 卡面里点了词典链接 / 外链（#16）：外链交系统浏览器；词典内部交叉引用在链接处查词
  /// （与查词弹窗里点链接同一行为）。没有查词作用域（预览页）时内部链接不响应。
  void _onCardLink(SrsCardLinkAction action) {
    switch (action) {
      case SrsCardExternalLink(:final String href):
        unawaited(openDictionaryExternalLink(href));
      case SrsCardLookupLink(:final String query, :final Rect rect):
        final SrsCardLookupController? lookup = _lookup;
        final RenderBox? box = _box;
        if (lookup == null || box == null) return;
        lookup.lookup(
          SrsCardLookupRequest(
            term: query,
            anchor: MatrixUtils.transformRect(box.getTransformTo(null), rect),
            sentence: query,
            fromHover: false,
            origin: this,
          ),
        );
    }
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
        srsCardSelectInvocation(local.dx, local.dy, 400, fromHover: fromHover),
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
    _syncGestureGate();
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
      // 外壳 `<head>` 已装好桥；这里重放只刷新键表（脚本幂等，listener 只装一次）。
      await controller.evaluateJavascript(
        source: srsCardFaceBridgeScriptFor(widget.face.bridgeKeys),
      );
      await controller.evaluateJavascript(source: kSrsCardLinkScript);
      if (widget.face.onImageTap != null) {
        await controller.evaluateJavascript(source: kSrsCardImageTapScript);
      }
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
      key: ValueKey<(Key, int)>((_deathGuard.rebuildKey, _creationAttempt)),
      child: InAppWebView(
        // 只在平台视图创建时读一次：外壳页，内容由 _sync 在 onLoadStop 后下发。
        initialData: InAppWebViewInitialData(
          data: _docCache?.shellHtml ?? _document(context).shellHtml,
          mimeType: 'text/html',
          encoding: 'utf-8',
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          supportZoom: false,
          disableContextMenu: true,
          // 透明：卡片底色只来自主题 CSS（[srsCardThemeCss]）与卡片 CSS，模板写透明时
          // 透出复习页背景，而不是平台视图自己的白底。
          transparentBackground: true,
          // 卡面媒体经拦截器 / 自定义 scheme 从 SrsMediaStore 供字节（见 srs_card_media.dart）。
          useShouldInterceptRequest: true,
          resourceCustomSchemes: const <String>[kSrsMediaScheme],
          // BUG-3356 同款：WKWebView 默认把屏幕边缘横滑当 WebView 历史前进 / 后退。
          // 本卡面换卡 / 翻面都在同一平台视图上 `loadData`（见 [_syncContent]），历史里
          // 堆着上一张卡 / 正面，侧滑会把画面退回旧卡面而复习状态没动。卡面切换完全由
          // 宿主拥有，关掉。只作用于 iOS / macOS。
          allowsBackForwardNavigationGestures: false,
          // 页面自己发起的播放由外壳里的自动播放闸门按牌组开关决定（BUG-3546），
          // 不再交给各平台默认策略：Android / iOS 默认「要手势」会让开着自动播放的
          // 同步片段也不出声，Windows 默认放行又让关掉的照样出声。iOS 内嵌播放
          // （片段带 playsinline）不全屏接管。
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
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
          _noteViewCreated();
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
            handlerName: kSrsKeyDiagHandler,
            callback: (List<dynamic> arguments) {
              final Object? info = arguments.isEmpty ? null : arguments.first;
              if (info is String && _keyDiagReports < _kMaxKeyDiagReports) {
                _keyDiagReports++;
                ErrorLogService.instance.logDiagnostic(
                  'SrsWebCardFace.keyNotBridged',
                  '${widget.face.cardId}: $info',
                );
              }
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
          controller.addJavaScriptHandler(
            handlerName: kSrsImageTapHandler,
            callback: (List<dynamic> arguments) {
              final Object? src = arguments.isEmpty ? null : arguments.first;
              if (src is String && src.isNotEmpty && mounted) {
                widget.face.onImageTap?.call(src);
              }
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
          // 卡面手势（点空白 / 双击 / 长按 / 滑动），见 [kSrsCardLookupScript]。
          controller.addJavaScriptHandler(
            handlerName: kSrsGestureHandler,
            callback: (List<dynamic> arguments) {
              if (mounted && arguments.isNotEmpty) {
                _onPageGesture(arguments.first);
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsPlaySoundHandler,
            callback: (List<dynamic> arguments) {
              final Object? name = arguments.isEmpty ? null : arguments.first;
              if (name is String && name.isNotEmpty && mounted) {
                // 复习页：交给它的播放序列（与底栏重播 / 自动播放同一路，新的打断旧的）。
                final void Function(List<String>)? host =
                    widget.face.onPlayAudio;
                if (host != null) {
                  host(<String>[name]);
                } else {
                  srsRunLogged(
                    'SrsWebCardFace.playSound',
                    () => _playSound(name),
                  );
                }
              }
              return null;
            },
          );
          controller.addJavaScriptHandler(
            handlerName: kSrsCardLinkHandler,
            callback: (List<dynamic> arguments) {
              final SrsCardLinkAction? action = SrsCardLinkAction.parse(
                arguments.isEmpty ? null : arguments.first,
              );
              if (action != null && mounted) _onCardLink(action);
              return null;
            },
          );
        },
        // 外壳没能加载 / 平台视图没建起来时不会有 onLoadStop，卡面会一直停在空白：
        // 留痕并各重来一次（BUG-3579；以前没接这个回调，失败完全无声）。
        onReceivedError:
            (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceError error,
            ) {
              if (error.description.contains(
                kReaderWebViewCreationFailedSentinel,
              )) {
                ErrorLogService.instance.log(
                  'SrsWebCardFace.creationFailed',
                  error.description,
                  null,
                );
                if (_recreatedAfterFailure || !mounted) return;
                _recreatedAfterFailure = true;
                _controller = null;
                _sync.detach();
                setState(() => _creationAttempt++);
                return;
              }
              if (request.isForMainFrame != true) return;
              ErrorLogService.instance.log(
                'SrsWebCardFace.shellLoadFailed',
                '${error.type} ${error.description} ${request.url}',
                null,
              );
              if (_reloadedAfterLoadError) return;
              _reloadedAfterLoadError = true;
              _sync.detach();
              _reloadShell();
            },
        onLoadStop: (InAppWebViewController controller, _) {
          // 死亡处置已丢弃 controller：等重建后的新平台视图自己的 onLoadStop。
          final InAppWebViewController? current = _controller;
          if (current == null) return;
          // 插件每次回调都给同一平台视图新包一只 [InAppWebViewController]，这里的参数与
          // onWebViewCreated 存下的 [_controller] 永远不 identical：一律用存下的那只，
          // [_installLookup] 的「注入期间视图换了」判断才认得出是同一视图（以前直接传参数，
          // 判断恒假、取词门控从不下发，整面 WebView 卡面点词 / 点空白全失灵）。
          if (!identical(current.platform, controller.platform)) return;
          _sync.shellLoaded();
          _lookupInstalled = false;
          _pushedGestureGate = null;
          unawaited(
            _injectBridge(current).then((_) => _installLookup(current)),
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
    // 平台视图上方的结构恒定：宿主悬停腿的 Listener 始终在，只按平台决定接不接回调，
    // **不随查词作用域变**。以前「没作用域就不包 Listener」：作用域在 null ↔ 非 null 间切换
    // （原生 Fushi 卡面的释义 WebView 正面在 Offstage 预热、无作用域，翻面后有）时根 widget
    // 类型一变，element 整棵重建、平台视图被销毁重建——macOS 上每张卡两次（翻面一次、换卡
    // 一次），重建前刚发出的取词注入打进已销毁的通道（O1yqRPUyut：`installLookup`
    // MissingPluginException，channel 号每张卡 +2，复习卡顿）。没有作用域时 [_onHostHover]
    // 自己 no-op。
    return Listener(
      onPointerHover: hostOwnsWebViewHoverLookup ? _onHostHover : null,
      child: webView,
    );
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
