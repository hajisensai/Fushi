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
//
// 句序号 `ln`（与文档 id `doc` 一起随帧推送）：可见正文从非空变成「不是上一份正文的
// 延续」（含被清空）时 +1。TyranoScript 在 `[p]` 之后执行下一个 tag 之前就同步清空消息层
// （kag.tag.js nextOrder 的 flag_ref_page 分支），所以 `#名字`（chara_ptext）触发的
// [vostart] 自动语音、以及显式 `[playse]` 语音播放时，旧句已经清掉 —— 播放挂钩里同步
// 读一次正文、推进句序号，语音就落在它所属的新句上，不依赖 MutationObserver 的异步时序。
// 若语音在 flag_ref_page 仍为 true（翻页清空还没发生）时播放，它属于下一句：ln + 1。
// 同一句里的多条语音（多人同时配音、`[l]` 续行后的新语音）带同一个 ln。
//
// 语音判据（引擎级，见 kag.tag_audio.js）：`[playse]` / `[fadeinse]` / [vostart] 自动语音
// 都经 `master_tag.playbgm.start`（target="se"）；引擎自己在 playbgm.play 里用
// `!!stat.map_vo.vobuf[buf]` 判定 is_voice。挂钩用同一判据：buf 是 `[voconfig sebuf=N]`
// 声明的语音缓冲区才推语音事件。没用 voconfig、直接 `[playse buf=N]` 播语音的游戏，引擎
// 状态里没有「这是语音」的证据，按「只做引擎级判据」不猜，不推事件（不配对）。挂钩在
// play_se=false / 跳过模式的早退之前，记录的是「这句的语音原件是哪个」，与是否真的出声无关。

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
  var state = {
    timer: 0, settle: 0, wait: 0, last: '', observer: null, bound: [], waitTries: 0, disposed: false,
    doc: 'd' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8),
    seq: 0, seqText: '', hook: null
  };

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
  // 一个字形的正文（与 glyphOf 同一取法：.fill 优先，跳过 <rt>/<rp>）。
  function glyphText(ch) {
    var rep = ch.querySelector(':scope > .fill') || ch;
    var walker = document.createTreeWalker(rep, NodeFilter.SHOW_TEXT);
    var text = '';
    for (var node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!inRubyText(node, rep)) text += node.data;
    }
    return text;
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
  // 当前可见正文（与 snapshot 的字形拼接结果逐字相同），播放挂钩同步调用。
  function currentText() {
    var text = '';
    var layers = messageLayers();
    for (var i = 0; i < layers.length; i++) {
      if (!isVisible(layers[i])) continue;
      var chars = layers[i].querySelectorAll('.message_inner span.char');
      for (var j = 0; j < chars.length; j++) text += glyphText(chars[j]);
    }
    return text;
  }
  // 句序号推进：上一份正文非空、这一份不是它的延续（含清空）→ 新句。
  function syncSeq(text) {
    if (state.seqText && text.indexOf(state.seqText) !== 0) state.seq++;
    state.seqText = text;
  }
  function voiceBuffersDeclared(stat) {
    var vo = stat && stat.map_vo;
    if (!vo || !vo.vobuf) return false;
    for (var key in vo.vobuf) if (vo.vobuf[key]) return true;
    return false;
  }
  function onPlay(pm) {
    if (!pm || pm.target !== 'se') return;
    var stat = window.TYRANO.kag.stat || {};
    var vo = stat.map_vo;
    // 不是 [voconfig] 声明的语音缓冲区：引擎不认为它是语音，不猜。
    if (!vo || !vo.vobuf || !vo.vobuf[pm.buf]) return;
    var storage = String(pm.storage || '');
    if (!storage) return;
    var text = currentText();
    syncSeq(text);
    var ln = state.seq + (stat.flag_ref_page === true && text ? 1 : 0);
    var path = (window.$ && typeof window.$.parseStorage === 'function')
      ? String(window.$.parseStorage(storage, 'sound'))
      : './data/sound/' + storage;
    var payload = { v: 1, k: 'voice', doc: state.doc, ln: ln, buf: String(pm.buf), path: path, b64: !!pm.base64 };
    if (typeof window[BINDING] === 'function') window[BINDING](JSON.stringify(payload));
  }
  // 挂 master_tag.playbgm.start（幂等：同一个 tag 对象只挂一次；dispose 时若仍在最外层就
  // 还原，被别人再包了一层则只把自己变成直通）。
  function installVoiceHook() {
    if (state.disposed) return;
    var kag = window.TYRANO && window.TYRANO.kag;
    var tag = kag && kag.ftag && kag.ftag.master_tag && kag.ftag.master_tag.playbgm;
    if (!tag || typeof tag.start !== 'function') return;
    if (state.hook && state.hook.tag === tag) return;
    var orig = tag.start;
    var wrapper = function () {
      if (!state.disposed) {
        try { onPlay(arguments[0]); } catch (e) { /* 观察失败绝不影响游戏播放 */ }
      }
      return orig.apply(this, arguments);
    };
    tag.start = wrapper;
    state.hook = { tag: tag, wrapper: wrapper, orig: orig };
  }
  function snapshot() {
    var kag = window.TYRANO && window.TYRANO.kag;
    var stat = (kag && kag.stat) || {};
    var config = (kag && kag.config) || {};
    var glyphs = [];
    var text = '';
    var layers = messageLayers();
    for (var i = 0; i < layers.length; i++) {
      if (!isVisible(layers[i])) continue;
      var chars = layers[i].querySelectorAll('.message_inner span.char');
      for (var j = 0; j < chars.length; j++) {
        var g = glyphOf(chars[j]);
        if (g.t) { glyphs.push(g); text += g.t; }
      }
    }
    syncSeq(text);
    return {
      v: 1,
      doc: state.doc,
      ln: state.seq,
      vo: voiceBuffersDeclared(stat),
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
    installVoiceHook();
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
    if (state.hook && state.hook.tag.start === state.hook.wrapper) state.hook.tag.start = state.hook.orig;
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
