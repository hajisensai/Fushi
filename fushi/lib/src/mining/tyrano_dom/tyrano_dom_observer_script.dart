// 注入 TyranoScript 页面的观察脚本：MutationObserver 观察消息层 / 角色名 / 舞台缩放，
// 加 resize / scroll / animationend / transitionend 监听，32 ms 节流后取一次快照，与上次
// 推送内容不同才经 Runtime.addBinding 的绑定函数推回 Fushi。逐字显示未完成期间脚本自己
// 每 120 ms 补查一次（is_adding_text 翻转与 CSS 动画结束不一定产生 DOM 变化），完成后停。
//
// 字形取法（对照 TyranoScript 5 kag.tag.js 的 message_html 构造）：
//   * 每个 `.message_inner span.char` 是一个字形；描边 / 阴影装饰模式下 span.char 里有
//     多份同一字（.stroke/.dummy/.fill），取 `.fill`；
//   * ruby 是 `<ruby><rb>字</rb><rt>注音</rt></ruby>` 包在字外面：正文与矩形都只取不在
//     `<rt>`/`<rp>` 里的文本节点（矩形用 Range 量 rb 文本）；
//   * 半角空格是常驻 opacity:0 的 span.char，Dart 侧不让它阻塞完成判定。
//
// 重复注入（重连 / 新文档脚本 + 当前文档补注）时先 dispose 旧实例再装新的。

/// 观察脚本调用的绑定函数名（`Runtime.addBinding`）。
const String kTyranoDomBindingName = '__fushiTyranoDomV1';

/// 页面全局上观察脚本实例的名字（用于卸载）。
const String kTyranoDomObserverGlobal = '__fushiTyranoDomObserverV1';

/// 卸载观察脚本的表达式。
const String kTyranoDomDisposeExpression =
    'window.$kTyranoDomObserverGlobal && window.$kTyranoDomObserverGlobal.dispose()';

/// 观察脚本源码。
const String kTyranoDomObserverScript = r'''
(function () {
  'use strict';
  var BINDING = '__fushiTyranoDomV1';
  var previous = window.__fushiTyranoDomObserverV1;
  if (previous && typeof previous.dispose === 'function') previous.dispose();
  var state = { timer: 0, settle: 0, wait: 0, last: '', observer: null, bound: [], waitTries: 0, disposed: false };

  function isVisible(el) {
    var cs = window.getComputedStyle(el);
    return cs.display !== 'none' && cs.visibility !== 'hidden';
  }
  function inRubyText(node, stop) {
    for (var n = node.parentNode; n && n !== stop; n = n.parentNode) {
      var tag = n.nodeName;
      if (tag === 'RT' || tag === 'RP') return true;
    }
    return false;
  }
  // 一个字形：.fill（描边 / 阴影装饰模式里真正的字）优先，否则 span.char 本身；
  // 正文与矩形都只取不在 <rt>/<rp> 里的文本节点（ruby 只取 rb 部分）。
  function glyphOf(ch) {
    var rep = ch.querySelector(':scope > .fill') || ch;
    var walker = document.createTreeWalker(rep, NodeFilter.SHOW_TEXT);
    var text = '';
    var l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
    var hasRuby = !!rep.querySelector('ruby');
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      if (inRubyText(node, rep)) continue;
      text += node.data;
      if (hasRuby) {
        var range = document.createRange();
        range.selectNodeContents(node);
        var rr = range.getBoundingClientRect();
        if (rr.width > 0 || rr.height > 0) {
          l = Math.min(l, rr.left); t = Math.min(t, rr.top);
          r = Math.max(r, rr.right); b = Math.max(b, rr.bottom);
        }
      }
    }
    if (!hasRuby || l === Infinity) {
      var br = rep.getBoundingClientRect();
      l = br.left; t = br.top; r = br.right; b = br.bottom;
    }
    var cs = window.getComputedStyle(ch);
    var shown = parseFloat(cs.opacity) > 0 && cs.visibility !== 'hidden';
    return { t: text, x: l, y: t, w: r - l, h: b - t, s: shown };
  }
  function messageLayers() {
    var all = document.querySelectorAll('.layer');
    var out = [];
    for (var i = 0; i < all.length; i++) {
      if (/(^|\s)message\d+_fore(\s|$)/.test(all[i].className)) out.push(all[i]);
    }
    return out;
  }
  function speakerText() {
    var areas = document.querySelectorAll('.chara_name_area');
    for (var i = 0; i < areas.length; i++) {
      if (!isVisible(areas[i])) continue;
      var s = (areas[i].textContent || '').trim();
      if (s) return s;
    }
    return '';
  }
  function snapshot() {
    var kag = window.TYRANO && window.TYRANO.kag;
    var stat = (kag && kag.stat) || {};
    var config = (kag && kag.config) || {};
    var glyphs = [];
    var layers = messageLayers();
    for (var i = 0; i < layers.length; i++) {
      if (!isVisible(layers[i])) continue;
      var chars = layers[i].querySelectorAll('.message_inner span.char');
      for (var j = 0; j < chars.length; j++) {
        var g = glyphOf(chars[j]);
        if (g.t) glyphs.push(g);
      }
    }
    return {
      v: 1,
      adding: stat.is_adding_text === true,
      vertical: String(config.vertical) === 'true',
      dpr: window.devicePixelRatio || 1,
      vw: window.innerWidth,
      vh: window.innerHeight,
      speaker: speakerText(),
      glyphs: glyphs
    };
  }
  function settled(snap) {
    if (snap.adding) return false;
    for (var i = 0; i < snap.glyphs.length; i++) {
      var g = snap.glyphs[i];
      if (!g.s && g.t.trim()) return false;
    }
    return true;
  }
  function rebind() {
    var targets = messageLayers();
    var base = document.getElementById('tyrano_base') || document.querySelector('.tyrano_base');
    var names = document.querySelectorAll('.chara_name_area');
    var want = targets.slice();
    if (base) want.push(base);
    for (var i = 0; i < names.length; i++) want.push(names[i]);
    var same = want.length === state.bound.length;
    for (var k = 0; same && k < want.length; k++) same = want[k] === state.bound[k];
    if (same) return;
    state.observer.disconnect();
    state.bound = want;
    for (var m = 0; m < targets.length; m++) {
      state.observer.observe(targets[m], { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['style', 'class'] });
      if (targets[m].parentNode) state.observer.observe(targets[m].parentNode, { childList: true });
    }
    if (base) state.observer.observe(base, { attributes: true, attributeFilter: ['style', 'class'] });
    for (var n = 0; n < names.length; n++) {
      state.observer.observe(names[n], { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['style', 'class'] });
    }
  }
  function flush(force) {
    state.timer = 0;
    rebind();
    var snap = snapshot();
    var json = JSON.stringify(snap);
    if (force || json !== state.last) {
      state.last = json;
      if (typeof window[BINDING] === 'function') window[BINDING](json);
    }
    if (state.settle) { clearTimeout(state.settle); state.settle = 0; }
    // 逐字显示 / 淡入动画不一定产生 DOM 变化（is_adding_text 翻转、CSS 动画结束），
    // 未稳定期间由脚本自己补查，稳定后停。
    if (!settled(snap)) state.settle = setTimeout(schedule, 120);
  }
  function schedule() {
    if (state.timer || state.disposed) return;
    state.timer = setTimeout(function () { flush(false); }, 32);
  }
  function start() {
    state.wait = 0;
    if (state.disposed) return;
    if (!(window.TYRANO && window.TYRANO.kag && document.body)) {
      // 页面刚建好时 TyranoScript 还没初始化：脚本侧等它（约 5 分钟上限）。
      if (state.waitTries++ < 1500) state.wait = setTimeout(start, 200);
      return;
    }
    state.observer = new MutationObserver(schedule);
    window.addEventListener('resize', schedule);
    window.addEventListener('scroll', schedule, true);
    document.addEventListener('animationend', schedule, true);
    document.addEventListener('transitionend', schedule, true);
    flush(true);
  }
  function dispose() {
    state.disposed = true;
    clearTimeout(state.timer); clearTimeout(state.settle); clearTimeout(state.wait);
    state.timer = state.settle = state.wait = 0;
    if (state.observer) state.observer.disconnect();
    window.removeEventListener('resize', schedule);
    window.removeEventListener('scroll', schedule, true);
    document.removeEventListener('animationend', schedule, true);
    document.removeEventListener('transitionend', schedule, true);
    document.removeEventListener('DOMContentLoaded', start);
  }
  window.__fushiTyranoDomObserverV1 = { dispose: dispose };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
''';
