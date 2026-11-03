import 'dart:convert';

/// 标签页 WebView 注入的页内脚本（全部幂等、只装在顶层框架）。
///
/// JS 实现而不是各平台原生回调的原因：Windows 的 WebView2 fork 没有
/// `onScrollChanged` / 全屏 / 页内查找 / 长按命中这些回调，五端统一走页内脚本，
/// 行为才一致、可测。

/// 页内滚动上报：`fushiBrowserScroll(y, dy)`。用捕获阶段监听 `scroll`，内部容器
/// 滚动（很多单页应用滚的是 body 下的某个 div）也算；按帧合并。
const String kWebBrowserScrollHandler = 'fushiBrowserScroll';

/// 全屏变化：`fushiBrowserFullscreen(bool)`。
const String kWebBrowserFullscreenHandler = 'fushiBrowserFullscreen';

/// 桌面右键命中：`fushiBrowserContextMenu({link, linkText, image, x, y})`。
const String kWebBrowserContextMenuHandler = 'fushiBrowserContextMenu';

const String kWebBrowserScrollScript =
    '''
(function(){
  if (window.__fushiBrowserScroll) return;
  window.__fushiBrowserScroll = true;
  var last = -1, pending = false, target = null;
  function yOf(t){
    if (!t || t === document || t === document.documentElement || t === document.body) {
      return window.scrollY || document.documentElement.scrollTop || 0;
    }
    return t.scrollTop || 0;
  }
  function flush(){
    pending = false;
    var y = Math.round(yOf(target));
    if (last < 0) { last = y; return; }
    var dy = y - last;
    last = y;
    if (dy === 0) return;
    var b = window.flutter_inappwebview;
    if (b && b.callHandler) b.callHandler('$kWebBrowserScrollHandler', y, dy);
  }
  document.addEventListener('scroll', function(e){
    var t = e.target;
    if (t !== target) { target = t; last = Math.round(yOf(t)); return; }
    if (!pending) { pending = true; requestAnimationFrame(flush); }
  }, {capture: true, passive: true});
})();
''';

const String kWebBrowserFullscreenScript =
    '''
(function(){
  if (window.__fushiBrowserFullscreen) return;
  window.__fushiBrowserFullscreen = true;
  function report(){
    var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
    var b = window.flutter_inappwebview;
    if (b && b.callHandler) b.callHandler('$kWebBrowserFullscreenHandler', on);
  }
  document.addEventListener('fullscreenchange', report);
  document.addEventListener('webkitfullscreenchange', report);
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
