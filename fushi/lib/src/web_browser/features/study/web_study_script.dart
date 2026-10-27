/// 浏览器阅读计时的页内脚本（幂等安装）。
library;

/// 页内脚本上报的 handler 名。
const String kWebStudyHandler = 'fushiStudyActivity';

/// 上报去抖间隔（毫秒）：交互 / 字数攒够这么久报一次，可见性变化立即报。
const int kWebStudyFlushMs = 4000;

/// 页面算「日文页」的门槛：正文前 2 万字里至少这么多个日文字符。
const int kWebStudyJapaneseMinChars = 60;

/// 页内脚本：
/// - **交互**：滚动 / 滚轮 / 按键 / 点按 / 触摸 / 选字标记一次「有交互」，去抖
///   [kWebStudyFlushMs] 后上报；页面可见性变化立即上报（切走 / 锁屏即停表）。
/// - **日文页**：`body` 文本前 2 万字里日文字符数 ≥ [kWebStudyJapaneseMinChars]；
///   动态加载的页面在 DOM 变化后再判（判定成立后不再算）。
/// - **字数（翻走即计）**：含日文的文本按其所在元素交给 `IntersectionObserver`，
///   元素在视口里出现过、之后整块滚出视口**上方**时，把它的文字（不含振假名 `rt`）
///   的日文字符数计入；同一页同一段文字只计一次（按文字内容去重，阅读模式
///   换掉 DOM 后不会重计相同的段落）。停在最后一屏没滚走的不计——与阅读器「翻走才
///   入账」同一口径。
String webStudyInstallSource() => _kWebStudyInstallTemplate
    .replaceAll('@FLUSH_MS@', '$kWebStudyFlushMs')
    .replaceAll('@JA_MIN@', '$kWebStudyJapaneseMinChars')
    .replaceAll('@HANDLER@', kWebStudyHandler);

const String _kWebStudyInstallTemplate = r'''
(function(){
  if (window.__fushiStudy) return;
  window.__fushiStudy = true;
  var FLUSH_MS = @FLUSH_MS@, JA_MIN = @JA_MIN@;
  var JA = /[぀-ヿ㐀-鿿豈-﫿々]/g;
  var SKIP = {SCRIPT:1,STYLE:1,NOSCRIPT:1,TEXTAREA:1,INPUT:1,SELECT:1,OPTION:1,
    RT:1,RP:1,TEMPLATE:1,SVG:1,svg:1};
  var seen = new Set(), counted = new WeakSet(), shown = new WeakSet(),
    observed = new WeakSet();
  var chars = 0, interacted = false, ja = false, timer = 0, moTimer = 0,
    pending = [];
  function countJa(s){ var m = s && s.match(JA); return m ? m.length : 0; }
  function visible(){ return document.visibilityState !== 'hidden'; }
  function send(){
    var b = window.flutter_inappwebview;
    if (!b || !b.callHandler) return;
    var payload = {visible: visible(), interacted: interacted, ja: ja,
      chars: chars};
    chars = 0; interacted = false;
    b.callHandler('@HANDLER@', payload);
  }
  function soon(){
    if (timer) return;
    timer = setTimeout(function(){
      timer = 0;
      if (interacted || chars) send();
    }, FLUSH_MS);
  }
  function mark(){ if (!visible()) return; interacted = true; soon(); }
  ['wheel','keydown','pointerdown','touchstart','selectionchange']
    .forEach(function(ev){
      document.addEventListener(ev, mark, {passive: true, capture: true});
    });
  window.addEventListener('scroll', mark, {passive: true, capture: true});
  document.addEventListener('visibilitychange', function(){ send(); });
  function checkJa(){
    if (ja || !document.body) return;
    var s = (document.body.textContent || '').slice(0, 20000);
    if (countJa(s) >= JA_MIN) ja = true;
  }
  function unitOf(t){
    for (var n = t.parentNode; n && n.nodeType === 1; n = n.parentNode) {
      if (SKIP[n.tagName] || n.isContentEditable) return null;
    }
    return t.parentNode;
  }
  function textsOf(el){
    var out = [];
    for (var c = el.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 3 && c.nodeValue) out.push(c.nodeValue);
    }
    return out;
  }
  function credit(el){
    if (counted.has(el)) return;
    counted.add(el);
    var texts = textsOf(el);
    for (var i = 0; i < texts.length; i++) {
      var s = texts[i];
      if (seen.has(s)) continue;
      seen.add(s);
      chars += countJa(s);
    }
    if (chars) soon();
  }
  var io = new IntersectionObserver(function(entries){
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i], el = e.target;
      if (e.isIntersecting) { shown.add(el); continue; }
      var top = e.rootBounds ? e.rootBounds.top : 0;
      if (shown.has(el) && visible() && e.boundingClientRect.bottom <= top) {
        credit(el);
      }
    }
  });
  function consider(t){
    if (!t.nodeValue || !JA.test(t.nodeValue)) { JA.lastIndex = 0; return; }
    JA.lastIndex = 0;
    var el = unitOf(t);
    if (!el || observed.has(el)) return;
    observed.add(el);
    io.observe(el);
  }
  function scan(root){
    if (!root) return;
    if (root.nodeType === 3) { consider(root); return; }
    if (root.nodeType !== 1) return;
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), t;
    while ((t = w.nextNode())) consider(t);
  }
  function start(){
    if (!document.body) return;
    checkJa();
    scan(document.body);
    new MutationObserver(function(list){
      for (var i = 0; i < list.length; i++) {
        var a = list[i].addedNodes;
        for (var j = 0; j < a.length; j++) pending.push(a[j]);
      }
      if (moTimer) return;
      moTimer = setTimeout(function(){
        moTimer = 0;
        var nodes = pending; pending = [];
        for (var k = 0; k < nodes.length; k++) {
          if (nodes[k].isConnected) scan(nodes[k]);
        }
        checkJa();
      }, 500);
    }).observe(document.body, {childList: true, subtree: true});
    send();
  }
  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
})();
''';
