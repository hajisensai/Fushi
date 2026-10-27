import 'dart:convert';

import 'package:fushi/src/web_browser/features/furigana/web_furigana_annotator.dart';

/// 页内注音脚本回调 Dart 的 handler 名（一次一批文本）。
const String kWebFuriganaHandler = 'fushiFuriganaAnnotate';

/// 页内一批最多带几段 / 多少字（与 Dart 侧 [kWebFuriganaMaxBatchItems] 同口径：
/// 页内按这个攒批，Dart 侧再按同一上限切分词调用，二者一致时一批 = 一次 FFI）。
const int kWebFuriganaPageBatchItems = kWebFuriganaMaxBatchItems;
const int kWebFuriganaPageBatchChars = kWebFuriganaMaxBatchChars;

/// 页内注音机制（幂等安装，装上后只认 `window.__fushiFurigana.configure`）。
///
/// - 只处理**可见附近**的文本：首次全树走一遍，把含日文的文本节点的父元素交给一个
///   `IntersectionObserver`（上下各放一屏余量），元素进入视口才把它的直接文本子节点
///   排队；
/// - 攒批：同一时刻只有一批在途，一批 ≤ [kWebFuriganaPageBatchItems] 段、
///   ≤ [kWebFuriganaPageBatchChars] 字，一次 `callHandler` 送给 Dart（Dart 侧一次分词
///   FFI），回来后整批替换再发下一批；
/// - 动态内容：`MutationObserver` 看新增节点（去抖 200ms），新节点同样经视口门进队；
///   本脚本自己插入的 `span.fushi-furi` 不再处理；
/// - 关掉 / 换配置：把所有 `span.fushi-furi` 还原成原文文本节点再按新配置重来。
///
/// 跳过 `script` / `style` / 表单 / `code` / 已有 `ruby` / 可编辑区里的文字。
String webFuriganaInstallSource() => _kWebFuriganaInstallTemplate
    .replaceAll('@MAX_ITEM@', '$kWebFuriganaMaxItemChars')
    .replaceAll('@BATCH_ITEMS@', '$kWebFuriganaPageBatchItems')
    .replaceAll('@BATCH_CHARS@', '$kWebFuriganaPageBatchChars')
    .replaceAll('@HANDLER@', kWebFuriganaHandler);

const String _kWebFuriganaInstallTemplate = r'''
(function(){
  if (window.__fushiFurigana) return;
  var MAX_ITEM = @MAX_ITEM@, BATCH_ITEMS = @BATCH_ITEMS@,
    BATCH_CHARS = @BATCH_CHARS@;
  var SKIP = {SCRIPT:1,STYLE:1,NOSCRIPT:1,TEXTAREA:1,INPUT:1,SELECT:1,OPTION:1,
    RT:1,RP:1,RUBY:1,CODE:1,KBD:1,SAMP:1,SVG:1,svg:1,CANVAS:1,TEMPLATE:1,
    IFRAME:1,BUTTON:1};
  var JA = /[぀-ヿ㐀-鿿豈-﫿々]/;
  var enabled = false;
  var version = 0, queue = [], queued = new WeakSet(), observed = new WeakSet();
  var io = null, mo = null, inflight = false, pending = [], moTimer = 0;
  function on(){ return enabled; }
  function okParent(el){
    for (var n = el; n && n !== document.documentElement; n = n.parentNode) {
      if (n.nodeType !== 1) continue;
      if (SKIP[n.tagName]) return false;
      if (n.isContentEditable) return false;
      if (n.classList && n.classList.contains('fushi-furi')) return false;
    }
    return true;
  }
  function okText(t){
    var s = t.nodeValue;
    return !!s && s.length <= MAX_ITEM && JA.test(s) && !!t.parentNode &&
      okParent(t.parentNode);
  }
  function enqueue(t){ queued.add(t); queue.push(t); }
  function consider(t){
    if (queued.has(t) || !okText(t)) return;
    var el = t.parentNode;
    if (!observed.has(el)) { observed.add(el); io.observe(el); }
    else if (el.__fushiFuriVisible) enqueue(t);
  }
  function scan(root){
    if (!io || !root) return;
    if (root.nodeType === 3) { consider(root); return; }
    if (root.nodeType !== 1 || (root.classList &&
        root.classList.contains('fushi-furi'))) return;
    var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), t;
    while ((t = w.nextNode())) consider(t);
  }
  function onIntersect(entries){
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i], el = e.target;
      el.__fushiFuriVisible = e.isIntersecting;
      if (!e.isIntersecting) continue;
      for (var c = el.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3 && !queued.has(c) && okText(c)) enqueue(c);
      }
    }
    pump();
  }
  function onMutations(list){
    for (var i = 0; i < list.length; i++) {
      var added = list[i].addedNodes;
      for (var j = 0; j < added.length; j++) pending.push(added[j]);
    }
    if (moTimer) return;
    moTimer = setTimeout(function(){
      moTimer = 0;
      var nodes = pending; pending = [];
      for (var k = 0; k < nodes.length; k++) {
        if (nodes[k].isConnected) scan(nodes[k]);
      }
      pump();
    }, 200);
  }
  function text(s){ return document.createTextNode(s); }
  function render(span, tokens){
    for (var i = 0; i < tokens.length; i++) {
      var tok = tokens[i], parts = tok[1];
      if (!parts) { span.appendChild(text(tok[0])); continue; }
      for (var j = 0; j + 1 < parts.length; j += 2) {
        if (!parts[j + 1]) { span.appendChild(text(parts[j])); continue; }
        var r = document.createElement('ruby');
        r.appendChild(text(parts[j]));
        var rt = document.createElement('rt');
        rt.textContent = parts[j + 1];
        r.appendChild(rt);
        span.appendChild(r);
      }
    }
  }
  function apply(nodes, texts, res){
    for (var i = 0; i < nodes.length; i++) {
      var t = nodes[i], tokens = res[i];
      if (!tokens || !tokens.length || !t.parentNode ||
          t.nodeValue !== texts[i]) continue;
      var span = document.createElement('span');
      span.className = 'fushi-furi';
      span.__fushiSrc = texts[i];
      render(span, tokens);
      t.parentNode.replaceChild(span, t);
    }
  }
  function pump(){
    if (inflight || !on() || !queue.length) return;
    var bridge = window.flutter_inappwebview;
    if (!bridge || !bridge.callHandler) return;
    var nodes = [], texts = [], chars = 0;
    while (queue.length && nodes.length < BATCH_ITEMS) {
      var t = queue[0], s = t.nodeValue || '';
      if (nodes.length && chars + s.length > BATCH_CHARS) break;
      queue.shift();
      if (!t.isConnected || !t.parentNode) continue;
      nodes.push(t); texts.push(s); chars += s.length;
    }
    if (!nodes.length) return;
    inflight = true;
    var mine = version;
    bridge.callHandler('@HANDLER@', {texts: texts}).then(function(res){
      if (mine !== version) return;
      inflight = false;
      if (res && res.length === nodes.length) apply(nodes, texts, res);
      pump();
    }, function(){ if (mine === version) inflight = false; });
  }
  function plain(el){
    if (typeof el.__fushiSrc === 'string') return el.__fushiSrc;
    var c = el.cloneNode(true), rts = c.querySelectorAll('rt,rp');
    for (var i = 0; i < rts.length; i++) rts[i].remove();
    return c.textContent;
  }
  function unwrapAll(){
    var spans = document.querySelectorAll('span.fushi-furi');
    for (var i = 0; i < spans.length; i++) {
      var s = spans[i];
      if (s.parentNode) s.parentNode.replaceChild(text(plain(s)), s);
    }
  }
  function style(){
    if (document.getElementById('fushi-furigana-css')) return;
    var el = document.createElement('style');
    el.id = 'fushi-furigana-css';
    el.textContent = '.fushi-furi rt{font-size:.5em;line-height:1;}';
    (document.head || document.documentElement).appendChild(el);
  }
  function configure(c){
    version++;
    if (io) io.disconnect();
    if (mo) mo.disconnect();
    if (moTimer) { clearTimeout(moTimer); moTimer = 0; }
    io = null; mo = null; inflight = false; pending = []; queue = [];
    queued = new WeakSet(); observed = new WeakSet();
    unwrapAll();
    enabled = !!c.enabled;
    if (!on() || !document.body) return;
    style();
    io = new IntersectionObserver(onIntersect,
      {rootMargin: '100% 0px 100% 0px'});
    mo = new MutationObserver(onMutations);
    mo.observe(document.body, {childList: true, subtree: true});
    scan(document.body);
  }
  window.__fushiFurigana = {configure: configure};
})();
''';

/// 安装（幂等）并按 [enabled] 重新配置；关掉时还原页面原文。
String webFuriganaConfigureInvocation({required bool enabled}) =>
    '${webFuriganaInstallSource()}\n'
    'window.__fushiFurigana.configure('
    '${jsonEncode(<String, Object>{'enabled': enabled})});';

/// 解析页内脚本送来的一批（`{texts: [...]}`）；形状不对返回 null。
List<String>? parseWebFuriganaRequest(List<dynamic> args) {
  if (args.isEmpty || args.first is! Map) return null;
  final Map<dynamic, dynamic> body = args.first as Map<dynamic, dynamic>;
  final Object? raw = body['texts'];
  if (raw is! List || raw.length > kWebFuriganaPageBatchItems) return null;
  final List<String> texts = <String>[];
  for (final Object? t in raw) {
    if (t is! String) return null;
    texts.add(t);
  }
  return texts;
}
