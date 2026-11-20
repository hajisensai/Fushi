import 'dart:convert';

import 'package:fushi/src/web_browser/web_browser_scroll_collapse.dart';

/// 标签页 WebView 注入的页内脚本（全部幂等、只装在顶层框架）。
///
/// JS 实现而不是各平台原生回调的原因：Windows 的 WebView2 fork 没有
/// `onScrollChanged` / 全屏 / 页内查找 / 长按命中这些回调，五端统一走页内脚本，
/// 行为才一致、可测。

/// 页内滚动上报：`fushiBrowserScroll(y, dy)`。用捕获阶段监听 `scroll`，内部容器
/// 滚动（很多单页应用滚的是 body 下的某个 div）也算。不逐帧上报（每帧过一次 JS 桥
/// 会在滚动最忙的时候跟绘制抢线程，Android Hybrid Composition 下 raster 与 platform
/// 线程合并时尤甚）：只在收起状态机可能翻转的时刻报，见 [kWebBrowserScrollScript]。
const String kWebBrowserScrollHandler = 'fushiBrowserScroll';

/// 滚动停顿超过它（毫秒）就重新允许上报（见 [kWebBrowserScrollScript]）。
const int kWebBrowserScrollRunGapMs = 250;

/// 全屏变化：`fushiBrowserFullscreen(bool)`。
const String kWebBrowserFullscreenHandler = 'fushiBrowserFullscreen';

/// 桌面右键命中：`fushiBrowserContextMenu({link, linkText, image, x, y})`。
const String kWebBrowserContextMenuHandler = 'fushiBrowserContextMenu';

const String kWebBrowserScrollScript =
    '''
(function(){
  if (window.__fushiBrowserScroll) return;
  window.__fushiBrowserScroll = true;
  // 只在宿主收起状态机（WebBrowserCollapseState）可能翻转时上报，不逐帧过桥：
  // 同方向累计（换方向清零，与状态机同一口径）越过阈值时报一次，dy = 累计量；
  // 滚到顶报一次。报过之后同方向继续滚不再报（状态机不会再变）；宿主可能从别处
  // 改了收起状态（点小地址条展开 / 甩动底栏收起 / 换标签页），所以触摸 / 指针按下、
  // 换滚动容器或停顿超过 ${kWebBrowserScrollRunGapMs}ms 后重新允许上报（累计量保留）。
  var T = $kWebBrowserCollapseScrollThreshold, GAP = $kWebBrowserScrollRunGapMs;
  var last = -1, pending = false, target = null;
  var runDir = 0, runAcc = 0, runSent = false, topSent = false, lastAt = 0;
  function rearm(){ runSent = false; }
  function yOf(t){
    if (!t || t === document || t === document.documentElement || t === document.body) {
      return window.scrollY || document.documentElement.scrollTop || 0;
    }
    return t.scrollTop || 0;
  }
  function send(y, dy){
    var b = window.flutter_inappwebview;
    if (b && b.callHandler) b.callHandler('$kWebBrowserScrollHandler', y, dy);
  }
  function flush(){
    pending = false;
    var y = Math.round(yOf(target));
    if (last < 0) { last = y; return; }
    var dy = y - last;
    last = y;
    if (dy === 0) return;
    var now = Date.now();
    if (now - lastAt > GAP) rearm();
    lastAt = now;
    if (y <= 0) {
      runDir = 0; runAcc = 0; runSent = false;
      if (!topSent) { topSent = true; send(y, dy); }
      return;
    }
    topSent = false;
    var dir = dy > 0 ? 1 : -1;
    if (dir !== runDir) { runDir = dir; runAcc = 0; runSent = false; }
    runAcc += dy;
    if (!runSent && Math.abs(runAcc) > T) { runSent = true; send(y, runAcc); }
  }
  document.addEventListener('scroll', function(e){
    var t = e.target;
    if (t !== target) { target = t; last = Math.round(yOf(t)); rearm(); return; }
    if (!pending) { pending = true; requestAnimationFrame(flush); }
  }, {capture: true, passive: true});
  window.addEventListener('pointerdown', rearm, {capture: true, passive: true});
  window.addEventListener('touchstart', rearm, {capture: true, passive: true});
})();
''';

/// 全屏脚本：上报全屏变化 `fushiBrowserFullscreen(on, fit)`，fit 是全屏视频的方向
/// （`WebBrowserFullscreenFit` 的值名）。
///
/// [takeover] 为 true（「Fushi 接管网页全屏」，默认）时还会把网站的全屏请求截下来，
/// 换成**页内伪全屏**：被请求的元素（`<video>` 自己请求时取包住它的播放器容器）
/// 改成铺满视口的 fixed 层，Dart 侧收起浏览器 chrome、隐藏系统栏、按视频方向转屏。
/// 为什么不用原生全屏：iPhone 的 WKWebView 不支持元素全屏，网站只能调
/// `webkitEnterFullscreen()` 进系统播放器，Fushi 字幕 / 查词 / 字幕按钮全部留在页面
/// 里看不到；其余平台的原生全屏也只是让 WebView 铺满，伪全屏效果相同、五端一致。
///
/// 网站和扩展脚本读到的全屏状态保持一致：`document.fullscreenElement` 等 getter
/// 返回伪全屏元素，进退时在该元素上派发冒泡的 `fullscreenchange`，`exitFullscreen()`
/// 退的是伪全屏——网站的按钮照样切成「退出全屏」，扩展的覆盖层照样挂进全屏元素。
/// `window.fushiPageFullscreen.toggle(video)` 给扩展的「全屏」按钮用。
String webBrowserFullscreenScript({required bool takeover}) =>
    '''
(function(){
  if (window.__fushiBrowserFullscreen) return;
  window.__fushiBrowserFullscreen = true;
  var TAKEOVER = ${takeover ? 'true' : 'false'};
  var ATTR = 'data-fushi-page-fullscreen';
  var ANCESTOR = 'data-fushi-page-fullscreen-ancestor';
  var ROOT = 'data-fushi-page-fullscreen-root';
  var pseudo = null, fitSent = '';
  var DP = Document.prototype;
  function origGet(name){
    var d = Object.getOwnPropertyDescriptor(DP, name);
    return d && d.get ? d.get : null;
  }
  var nativeFs = origGet('fullscreenElement');
  var nativeWebkitFs = origGet('webkitFullscreenElement');
  function call(get){
    try { return get ? get.call(document) : null; } catch (_) { return null; }
  }
  function send(on, fit){
    var b = window.flutter_inappwebview;
    if (b && b.callHandler) b.callHandler('$kWebBrowserFullscreenHandler', on, fit);
  }
  function videoOf(el){
    if (!el) return null;
    if (el.tagName === 'VIDEO') return el;
    var vs = el.querySelectorAll ? el.querySelectorAll('video') : [];
    var best = null, area = -1;
    for (var i = 0; i < vs.length; i++) {
      var r = vs[i].getBoundingClientRect();
      var a = r.width * r.height;
      if (a > area) { area = a; best = vs[i]; }
    }
    return best;
  }
  function fitOf(el){
    var v = videoOf(el);
    var w = 0, h = 0;
    if (v && v.videoWidth && v.videoHeight) { w = v.videoWidth; h = v.videoHeight; }
    else if (v) { var r = v.getBoundingClientRect(); w = r.width; h = r.height; }
    if (!w || !h) return 'unknown';
    return h > w ? 'portrait' : 'landscape';
  }
  function report(){
    var el = pseudo || call(nativeFs) || call(nativeWebkitFs);
    var fit = el ? fitOf(el) : '';
    fitSent = fit;
    send(!!el, fit);
  }
  document.addEventListener('fullscreenchange', function(e){
    if (!e.__fushiPseudo) report();
  });
  document.addEventListener('webkitfullscreenchange', function(e){
    if (!e.__fushiPseudo) report();
  });
  if (!TAKEOVER) return;

  // 视频尺寸晚到（全屏后才 loadedmetadata / 换源）：方向变了补报一次。
  function refit(e){
    if (!pseudo || !e.target || e.target.tagName !== 'VIDEO') return;
    var fit = fitOf(pseudo);
    if (fit !== fitSent) { fitSent = fit; send(true, fit); }
  }
  document.addEventListener('loadedmetadata', refit, true);
  document.addEventListener('resize', refit, true);

  // 视频自己请求全屏：取包住它、与它差不多大的最外层容器（站点控件是 video 的兄弟，
  // 只把 video 铺满会丢掉进度条 / 字幕层）。
  function targetFor(el){
    if (!el || el.tagName !== 'VIDEO') return el;
    var r = el.getBoundingClientRect();
    var area = Math.max(1, r.width * r.height);
    var best = el;
    for (var p = el.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
      var pr = p.getBoundingClientRect();
      if (pr.width * pr.height > area * 1.6) break;
      best = p;
    }
    return best;
  }
  var style = null;
  function ensureStyle(){
    if (style && style.isConnected) return;
    style = document.createElement('style');
    style.textContent =
      '[' + ATTR + ']{position:fixed!important;inset:0!important;left:0!important;top:0!important;' +
      'width:100vw!important;height:100vh!important;height:100dvh!important;max-width:none!important;' +
      'max-height:none!important;min-width:0!important;min-height:0!important;margin:0!important;' +
      'padding:0!important;transform:none!important;border:0!important;border-radius:0!important;' +
      'z-index:2147483000!important;background:#000!important;box-sizing:border-box!important}' +
      '[' + ATTR + '] video,video[' + ATTR + ']{object-fit:contain!important}' +
      '[' + ANCESTOR + ']{transform:none!important;filter:none!important;perspective:none!important;' +
      'contain:none!important;will-change:auto!important;backdrop-filter:none!important}' +
      'html[' + ROOT + '],html[' + ROOT + '] body{overflow:hidden!important}';
    (document.head || document.documentElement).appendChild(style);
  }
  function fire(el){
    var names = ['fullscreenchange', 'webkitfullscreenchange'];
    for (var i = 0; i < names.length; i++) {
      var ev;
      try { ev = new Event(names[i], {bubbles: true}); } catch (_) { continue; }
      ev.__fushiPseudo = true;
      (el && el.isConnected ? el : document).dispatchEvent(ev);
    }
  }
  function enter(req){
    var el = targetFor(req);
    if (!el || el === pseudo) return;
    if (pseudo) leave(false);
    ensureStyle();
    pseudo = el;
    el.setAttribute(ATTR, '');
    for (var p = el.parentElement; p; p = p.parentElement) p.setAttribute(ANCESTOR, '');
    document.documentElement.setAttribute(ROOT, '');
    var vs = el.tagName === 'VIDEO' ? [el] : el.querySelectorAll('video');
    for (var i = 0; i < vs.length; i++) {
      vs[i].setAttribute('playsinline', '');
      vs[i].setAttribute('webkit-playsinline', '');
    }
    fire(el);
    report();
  }
  function leave(notify){
    var el = pseudo;
    if (!el) return;
    pseudo = null;
    el.removeAttribute(ATTR);
    var marked = document.querySelectorAll('[' + ANCESTOR + ']');
    for (var i = 0; i < marked.length; i++) marked[i].removeAttribute(ANCESTOR);
    document.documentElement.removeAttribute(ROOT);
    if (notify) { fire(el); report(); }
  }
  // 伪全屏元素被网站摘掉（SPA 换页）：当作退出。
  new MutationObserver(function(){
    if (pseudo && !pseudo.isConnected) leave(true);
  }).observe(document.documentElement, {childList: true, subtree: true});

  function requestPseudo(){ enter(this); return Promise.resolve(); }
  function exitPseudo(orig){
    return function(){
      if (pseudo) { leave(true); return Promise.resolve(); }
      return orig ? orig.apply(this, arguments) : Promise.resolve();
    };
  }
  var EP = Element.prototype;
  EP.requestFullscreen = requestPseudo;
  EP.webkitRequestFullscreen = requestPseudo;
  EP.webkitRequestFullScreen = requestPseudo;
  if (window.HTMLVideoElement) {
    var VP = HTMLVideoElement.prototype;
    VP.webkitEnterFullscreen = requestPseudo;
    VP.webkitEnterFullScreen = requestPseudo;
    VP.webkitExitFullscreen = exitPseudo(null);
    VP.webkitExitFullScreen = exitPseudo(null);
    try {
      Object.defineProperty(VP, 'webkitDisplayingFullscreen', {configurable: true,
        get: function(){ return !!pseudo && (pseudo === this || pseudo.contains(this)); }});
      Object.defineProperty(VP, 'webkitSupportsFullscreen', {configurable: true,
        get: function(){ return true; }});
    } catch (_) {}
  }
  DP.exitFullscreen = exitPseudo(DP.exitFullscreen);
  DP.webkitExitFullscreen = exitPseudo(DP.webkitExitFullscreen);
  DP.webkitCancelFullScreen = exitPseudo(DP.webkitCancelFullScreen);
  function define(name, get){
    try { Object.defineProperty(DP, name, {configurable: true, get: get}); } catch (_) {}
  }
  function pseudoOr(orig){
    return function(){ return pseudo || call(orig); };
  }
  define('fullscreenElement', pseudoOr(nativeFs));
  define('webkitFullscreenElement', pseudoOr(nativeWebkitFs));
  define('webkitCurrentFullScreenElement', pseudoOr(origGet('webkitCurrentFullScreenElement')));
  define('fullscreenEnabled', function(){ return true; });
  define('webkitFullscreenEnabled', function(){ return true; });
  define('fullscreen', function(){ return !!pseudo; });
  define('webkitIsFullScreen', function(){ return !!pseudo; });
  // 桌面键盘：Esc 退伪全屏（原生全屏的 Esc 由内核处理）。扩展查词弹窗开着时它自己
  // 先吞掉这次 Esc，这里只在没人处理（defaultPrevented 为假）时退。
  window.addEventListener('keydown', function(e){
    if (pseudo && e.key === 'Escape' && !e.defaultPrevented) leave(true);
  });
  window.fushiPageFullscreen = {
    toggle: function(video){
      if (pseudo) { leave(true); return; }
      var v = video || videoOf(document.body);
      if (v) enter(v);
    }
  };
})();
''';

/// 只在链接 / 图片上接管右键（换成本 app 的菜单）；正文上的右键留给系统菜单（复制
/// 等）。
const String kWebBrowserContextMenuScript =
    '''
(function(){
  if (window.__fushiBrowserContextMenu) return;
  window.__fushiBrowserContextMenu = true;
  document.addEventListener('contextmenu', function(e){
    var link = null, linkText = '', image = null;
    for (var n = e.target; n && n.nodeType === 1; n = n.parentElement) {
      var tag = n.tagName;
      if (!image && tag === 'IMG') image = n.currentSrc || n.src || null;
      if (!image && tag === 'PICTURE') {
        var img = n.querySelector('img');
        if (img) image = img.currentSrc || img.src || null;
      }
      if (!link && tag === 'A' && n.href) {
        link = n.href;
        linkText = (n.innerText || n.textContent || '').trim().slice(0, 200);
      }
    }
    if (!link && !image) return;
    e.preventDefault();
    var b = window.flutter_inappwebview;
    if (b && b.callHandler) {
      b.callHandler('$kWebBrowserContextMenuHandler', {
        link: link, linkText: linkText, image: image,
        x: e.clientX, y: e.clientY
      });
    }
  }, true);
})();
''';

/// 退出网页全屏（返回键 / 壳上的退出全屏）。
const String kWebBrowserExitFullscreenScript =
    'if (document.fullscreenElement && document.exitFullscreen) '
    'document.exitFullscreen(); '
    'else if (document.webkitFullscreenElement && document.webkitExitFullscreen) '
    'document.webkitExitFullscreen();';

/// 取站点图标：`link[rel~=icon]`（取声明尺寸最接近 32 的），退到 apple-touch-icon，
/// 再退到 `/favicon.ico`。返回绝对地址字符串。
///
/// SVG 图标（`type=image/svg+xml` / `.svg` / `data:image/svg`）一律跳过：标签栏用
/// Flutter `Image` 解码，不认 SVG，选中它只会退回首字母色块（jiten.moe 的
/// `favicon.svg` 声明 `sizes="any"`，与 48px ico 同分且排在前面）。
const String kWebBrowserFaviconScript = '''
(function(){
  function abs(h){ try { return new URL(h, location.href).href; } catch (e) { return null; } }
  var best = null, bestScore = 1e9;
  var links = document.querySelectorAll('link[rel]');
  for (var i = 0; i < links.length; i++) {
    var l = links[i];
    var rel = (l.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
    if (rel.indexOf('icon') < 0 && rel.indexOf('apple-touch-icon') < 0) continue;
    var href = l.getAttribute('href');
    if (!href) continue;
    var type = (l.getAttribute('type') || '').toLowerCase();
    if (type.indexOf('svg') >= 0 || /\\.svgz?(\\?|#|\$)/i.test(href) ||
        /^data:image\\/svg/i.test(href)) continue;
    var size = 0;
    var m = /(\\d+)x(\\d+)/.exec(l.getAttribute('sizes') || '');
    if (m) size = parseInt(m[1], 10);
    var score = rel.indexOf('icon') >= 0 ? 0 : 1000;
    score += size ? Math.abs(size - 32) : 16;
    if (score < bestScore) { bestScore = score; best = abs(href); }
  }
  if (best) return best;
  if (location.protocol === 'http:' || location.protocol === 'https:') {
    return location.origin + '/favicon.ico';
  }
  return null;
})();
''';

// ── 页内查找 ──────────────────────────────────────────────────────────────

/// 页内查找的安装脚本：`window.__fushiFind.run(q) / step(dir) / clear()`，都返回
/// `JSON {count, current}`（current 从 1 起，0 = 无结果）。高亮走 CSS Custom
/// Highlight（不改 DOM），平台没有时退到用选区标出当前一处。
const String kWebBrowserFindInstallScript = r'''
(function(){
  if (window.__fushiFind) return;
  var MAX = 1000;
  var ranges = [], index = -1;
  var hasHl = typeof CSS !== 'undefined' && CSS.highlights && typeof Highlight !== 'undefined';
  function ensureStyle(){
    if (document.getElementById('fushi-find-style')) return;
    var s = document.createElement('style');
    s.id = 'fushi-find-style';
    s.textContent = '::highlight(fushi-find){background-color:rgba(255,213,0,.55);color:inherit;}' +
      '::highlight(fushi-find-current){background-color:#ff9632;color:#000;}';
    (document.head || document.documentElement).appendChild(s);
  }
  function result(){ return JSON.stringify({count: ranges.length, current: index + 1}); }
  function paint(){
    if (!hasHl) {
      var sel = window.getSelection();
      if (sel) { sel.removeAllRanges(); if (index >= 0) sel.addRange(ranges[index]); }
      return;
    }
    CSS.highlights.set('fushi-find', new Highlight(...ranges));
    if (index >= 0) CSS.highlights.set('fushi-find-current', new Highlight(ranges[index]));
    else CSS.highlights.delete('fushi-find-current');
  }
  function reveal(){
    if (index < 0) return;
    var r = ranges[index];
    var el = r.startContainer.parentElement;
    if (el && el.scrollIntoView) el.scrollIntoView({block: 'center', inline: 'nearest'});
  }
  function clear(){
    ranges = []; index = -1;
    if (hasHl) { CSS.highlights.delete('fushi-find'); CSS.highlights.delete('fushi-find-current'); }
    return result();
  }
  function run(q){
    clear();
    if (!q || !document.body) return result();
    ensureStyle();
    var needle = q.toLowerCase();
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n){
        var p = n.parentElement;
        if (!p) return NodeFilter.FILTER_REJECT;
        var tag = p.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var node;
    while ((node = walker.nextNode()) && ranges.length < MAX) {
      var hay = node.nodeValue.toLowerCase();
      var from = 0, at;
      while ((at = hay.indexOf(needle, from)) >= 0 && ranges.length < MAX) {
        var r = document.createRange();
        r.setStart(node, at);
        r.setEnd(node, at + needle.length);
        if (r.getClientRects().length) ranges.push(r);
        from = at + needle.length;
      }
    }
    index = ranges.length ? 0 : -1;
    paint(); reveal();
    return result();
  }
  function step(dir){
    if (!ranges.length) return result();
    index = (index + dir + ranges.length) % ranges.length;
    paint(); reveal();
    return result();
  }
  window.__fushiFind = {run: run, step: step, clear: clear};
})();
''';

String webBrowserFindRunScript(String query) =>
    '$kWebBrowserFindInstallScript\nwindow.__fushiFind.run(${jsonEncode(query)});';

String webBrowserFindStepScript({required bool forward}) =>
    '$kWebBrowserFindInstallScript\nwindow.__fushiFind.step(${forward ? 1 : -1});';

const String kWebBrowserFindClearScript =
    'window.__fushiFind ? window.__fushiFind.clear() : null;';

/// 页内查找结果（`current` 从 1 起，0 = 没有结果）。
typedef WebBrowserFindResult = ({int count, int current});

/// 解析 `__fushiFind` 回的 JSON；解析不了按「无结果」。
WebBrowserFindResult parseWebBrowserFindResult(Object? raw) {
  Object? value = raw;
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return (count: 0, current: 0);
    }
  }
  if (value is Map) {
    final Object? count = value['count'];
    final Object? current = value['current'];
    if (count is num && current is num) {
      return (count: count.toInt(), current: current.toInt());
    }
  }
  return (count: 0, current: 0);
}
