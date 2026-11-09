/// 连续（滚动）模式「章节无缝衔接」的引擎模块（反馈 R7k887yaJI ③，设计见
/// `docs/specs/2026-11-07-continuous-seamless-chapters-design.md`）。
///
/// 模型：活动章正文留在 `document.body` 的 light DOM（引擎所有索引只覆盖它），前后各一章
/// 挂在 `<fushi-seamless-chapter>` 宿主的 shadow root 里一起排版滚动。body 上的
/// TreeWalker / querySelectorAll / getElementById 看不到 shadow 里的内容，所以邻章不会
/// 混进字符偏移、学习单位、高亮、cue 的任何索引——边界由平台保证，而不是靠几十处 walker
/// 各自记得排除。视口中心被用户滚过邻章边界时「晋升」它：节点在 shadow 与 light 之间
/// 搬家、引擎重建索引、回调 Dart `onSeamlessChapterActivated(to, from, seq)`，Dart 换章号
/// 并按章重新下发 cue / 高亮，再 `ack(seq, generation)`。
///
/// 安装方式是**装饰**而不是改写：模块只在连续 shell 里、`C.seamlessChapters === true` 时
/// 安装，把需要感知「活动章边界」的几个方法（章首 / 章末落点、isAtEnd、首可见字、
/// 程序化滚动入口、换样式、重锚落定、恢复完成、进度快照）包一层。开关关闭时
/// `window.__fushiSeamless` 不存在、没有任何方法被包，连续 shell 的行为与原来逐字一致；
/// 分页 / VN shell 的源码里没有本模块。
library;

/// 宿主元素标签名（自定义元素名，必须含连字符）。
const String kSeamlessChapterHostTag = 'fushi-seamless-chapter';

/// 晋升迟滞带（CSS px）：视口中心越过邻章边界这么多才切换，来回抖动不会反复切。
const int kSeamlessPromoteHysteresisPx = 24;

/// 轻点判定半径（CSS px），与 `ReaderSettings.tapSlopPx` 同量级。
const int kSeamlessTapSlopPx = 12;

/// 安装脚本：放在连续 shell 工厂函数体内（`C` 在词法作用域里），`window.fushiReader`
/// 已建好、`_sharedInitBoot` 之前。
final String kSeamlessChaptersInstallJs =
    r'''
(function() {
  if (C.seamlessChapters !== true) return;
  if (window.__fushiSeamless) return;
  var HOST_TAG = '__HOST_TAG__';
  var HYSTERESIS = __HYSTERESIS__;
  var TAP_SLOP = __TAP_SLOP__;
  var ORDER = Array.isArray(C.seamlessChapterOrder) ? C.seamlessChapterOrder : [];
  var RESET_CSS =
    ':host{display:block!important;margin:0!important;border:0!important;' +
      'padding-block:1em!important;padding-inline:0!important;}' +
    '.fushi-seamless-html.fushi-seamless-html,.fushi-seamless-body.fushi-seamless-body{' +
      'margin:0!important;padding:0!important;border:0!important;' +
      'width:auto!important;min-width:0!important;max-width:none!important;' +
      'height:auto!important;min-height:0!important;max-height:none!important;' +
      'clip-path:none!important;position:static!important;overflow:visible!important;' +
      'columns:auto!important;background:transparent!important;box-sizing:border-box!important;}' +
    '.fushi-seamless-html.fushi-seamless-html::after,.fushi-seamless-body.fushi-seamless-body::after{' +
      'content:none!important;display:none!important;}';
  // 不含 Space：它被桥接给 Dart（播放 / 暂停或翻页），翻页经装饰过的 paginate 记为用户意图。
  var SCROLL_KEYS = {ArrowUp: 1, ArrowDown: 1, ArrowLeft: 1, ArrowRight: 1, PageUp: 1, PageDown: 1, Home: 1, End: 1};

  function reader() { return window.fushiReader; }
  function vertical() { var r = reader(); return !!(r && r.isVertical()); }
  function posOf(chapter) {
    for (var i = 0; i < ORDER.length; i++) if (ORDER[i].index === chapter) return i;
    return -1;
  }
  function neighborOf(chapter, dir) {
    var p = posOf(chapter);
    if (p < 0) return null;
    var e = ORDER[p + dir];
    return e ? e : null;
  }
  function absUrl(raw, base) {
    if (!raw) return raw;
    var t = String(raw).trim();
    if (!t) return raw;
    if (/^(data|blob|javascript|about|mailto):/i.test(t)) return raw;
    try { return new URL(t, base).href; } catch (e) { return raw; }
  }
  function absolutizeCssUrls(text, base) {
    return String(text || '').replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi, function(m, q, u) {
      return 'url("' + absUrl(u, base) + '")';
    });
  }
  // 选择器改写：html / :root → .fushi-seamless-html，body → .fushi-seamless-body。
  // 只改「类型选择器位置」上的 token（前面是串首 / 组合子 / 逗号 / 左括号），属性值、类名
  // 里出现的 body 字样不动。改写走 CSSOM 的 selectorText，不对整段 CSS 文本做替换。
  var SELECTOR_TOKEN = /(^|[\s>+~,(])(html|body|:root)(?=$|[\s>+~,.:#\[)])/gi;
  function rewriteSelector(sel) {
    return sel.replace(SELECTOR_TOKEN, function(m, pre, tok) {
      return pre + (tok.toLowerCase() === 'body' ? '.fushi-seamless-body' : '.fushi-seamless-html');
    });
  }
  function rewriteRules(rules) {
    if (!rules) return;
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      if (typeof rule.selectorText === 'string') {
        var next = rewriteSelector(rule.selectorText);
        if (next !== rule.selectorText) rule.selectorText = next;
      }
      if (rule.cssRules) rewriteRules(rule.cssRules);
    }
  }
  function rewriteStyleElement(el) {
    if (!el.sheet) return;
    rewriteRules(el.sheet.cssRules);
  }
  // 正文里自带的 <style>（不在 head）随节点在 shadow / light 之间搬家：进 shadow 时记下原文
  // 并改写选择器，回到 light 时恢复原文（重新解析），保证两边各自按原语义生效。
  function contentStylesToShadow(root) {
    var styles = root.querySelectorAll('style');
    for (var i = 0; i < styles.length; i++) {
      var el = styles[i];
      if (el.getAttribute('data-role')) continue;
      if (el.__fushiSeamlessText === undefined) el.__fushiSeamlessText = el.textContent;
      rewriteStyleElement(el);
    }
  }
  function contentStylesToLight(nodes) {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (n.nodeType !== 1) continue;
      var list = n.localName === 'style' ? [n] : n.querySelectorAll('style');
      for (var j = 0; j < list.length; j++) {
        var el = list[j];
        if (el.__fushiSeamlessText !== undefined) {
          el.textContent = el.__fushiSeamlessText;
          el.__fushiSeamlessText = undefined;
        }
      }
    }
  }
  function isHost(n) { return n && n.nodeType === 1 && n.localName === HOST_TAG; }
  // 活动章正文 = body 的直接子节点里除宿主与引擎自有节点之外的全部。引擎往 body 里挂的
  // 只有高亮窄条层 <fushi-hl-lanes>（绝对定位）以及 id 以 fushi / __fushi 开头的元素。
  function isEngineNode(n) {
    if (!n || n.nodeType !== 1) return false;
    if (n.localName === 'fushi-hl-lanes') return true;
    var id = n.id || '';
    return id.indexOf('fushi') === 0 || id.indexOf('__fushi') === 0;
  }
  function contentNodes() {
    var out = [];
    var kids = document.body.childNodes;
    for (var i = 0; i < kids.length; i++) {
      var n = kids[i];
      if (isHost(n) || isEngineNode(n)) continue;
      out.push(n);
    }
    return out;
  }
  function hosts() {
    var out = [];
    var kids = document.body.children;
    for (var i = 0; i < kids.length; i++) if (isHost(kids[i])) out.push(kids[i]);
    return out;
  }
  function hostChapter(h) { return h.__fushiSeamless ? h.__fushiSeamless.chapter : -1; }
  function hostFor(chapter) {
    var hs = hosts();
    for (var i = 0; i < hs.length; i++) if (hostChapter(hs[i]) === chapter) return hs[i];
    return null;
  }
  // 宿主相对活动章的方向：阅读序在活动章之前 = -1，之后 = +1。
  function sideOf(h) {
    var p = posOf(hostChapter(h));
    var a = posOf(S.activeChapter);
    return p < a ? -1 : 1;
  }
  function adjacentHost(dir) {
    var e = neighborOf(S.activeChapter, dir);
    return e ? hostFor(e.index) : null;
  }
  function mainRange(rect) {
    // 书写轴上的 [起边, 止边]，按阅读前进方向：横排 top→bottom；竖排（vertical-rl）
    // 右→左，用「到视口右缘的距离」归一化成递增坐标。
    if (vertical()) {
      var w = window.innerWidth;
      return {start: w - rect.right, end: w - rect.left};
    }
    return {start: rect.top, end: rect.bottom};
  }
  function viewportMain() { return vertical() ? window.innerWidth : window.innerHeight; }
  function intersectsViewport(el) {
    var r = mainRange(el.getBoundingClientRect());
    return r.end > 0 && r.start < viewportMain();
  }
  function scrollMain(delta) {
    // delta 是归一化主轴坐标的增量（正 = 往阅读前进方向）。竖排 rl 前进 = 往左滚。
    if (Math.abs(delta) < 0.5) return;
    if (vertical()) window.scrollBy({left: -delta, top: 0, behavior: 'auto'});
    else window.scrollBy({left: 0, top: delta, behavior: 'auto'});
  }
  // ── 视口锚点补偿 ──
  function deepElementAt(x, y) {
    var el = document.elementFromPoint(x, y);
    var guard = 0;
    while (el && el.shadowRoot && guard++ < 4) {
      var inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  }
  function fallbackAnchor() {
    // 中心点落在 body / html 本身（段间空白）时，取主轴上覆盖或最靠近视口中心的直接子元素。
    var c = viewportMain() / 2;
    var best = null, bestDist = Infinity;
    var kids = document.body.children;
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i];
      if (isEngineNode(k)) continue;
      var r = mainRange(k.getBoundingClientRect());
      if (r.end <= r.start) continue;
      var d = c < r.start ? r.start - c : (c > r.end ? c - r.end : 0);
      if (d < bestDist) { best = k; bestDist = d; }
      if (d === 0) break;
    }
    return best;
  }
  function captureAnchor() {
    var x = window.innerWidth / 2, y = window.innerHeight / 2;
    var el = deepElementAt(x, y);
    if (!el || el === document.body || el === document.documentElement ||
        (el.classList && (el.classList.contains('fushi-seamless-body') || el.classList.contains('fushi-seamless-html')))) {
      el = fallbackAnchor();
    }
    if (!el) return null;
    return {el: el, pos: mainRange(el.getBoundingClientRect()).start};
  }
  function restoreAnchor(a) {
    if (!a || !a.el.isConnected) return;
    var now = mainRange(a.el.getBoundingClientRect()).start;
    scrollMain(now - a.pos);
  }
  function preserveViewport(fn) {
    var a = captureAnchor();
    fn();
    restoreAnchor(a);
  }
  // ── 章节样式数据 ──
  function sigOfLink(href) { return 'L:' + href; }
  function sigOfText(text) {
    var h = 0;
    for (var i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
    return 'S:' + text.length + ':' + h;
  }
  function isReaderOwnedStyle(el) {
    var id = el.id || '';
    return id === 'fushi-cloak' || id === 'fushi-reader-style' || id.indexOf('__fushi') === 0;
  }
  // 解析出来的章节文档里属于 EPUB 的样式表：<link rel=stylesheet>（拉取文本）与内联 <style>，
  // 排除净化管线注入的 cloak 与阅读器样式。url() 一律按样式表自己的地址改成绝对地址。
  async function epubStylesOf(doc, base) {
    var out = [];
    var head = doc.head;
    if (!head) return out;
    var els = head.querySelectorAll('link[rel~="stylesheet"], style');
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (isReaderOwnedStyle(el)) continue;
      if (el.localName === 'link') {
        var href = absUrl(el.getAttribute('href'), base);
        if (!href) continue;
        var resp = await fetch(href);
        var css = resp.ok ? await resp.text() : '';
        out.push({sig: sigOfLink(href), href: href, raw: null, text: absolutizeCssUrls(css, href)});
      } else {
        var raw = el.textContent || '';
        out.push({sig: sigOfText(raw), href: null, raw: raw, text: absolutizeCssUrls(raw, base)});
      }
    }
    return out;
  }
  function readerStyleText() {
    var el = document.getElementById('fushi-reader-style');
    return el ? el.textContent : '';
  }
  // ── 宿主构建 ──
  function buildHost(chapter, data) {
    var host = document.createElement(HOST_TAG);
    host.setAttribute('data-chapter', String(chapter));
    host.setAttribute('aria-hidden', 'false');
    var root = host.attachShadow({mode: 'open'});
    var epub = document.createElement('style');
    epub.setAttribute('data-role', 'epub');
    epub.textContent = data.styles.map(function(s) { return s.text; }).join('\n');
    var rs = document.createElement('style');
    rs.setAttribute('data-role', 'reader');
    rs.textContent = readerStyleText();
    var reset = document.createElement('style');
    reset.setAttribute('data-role', 'reset');
    reset.textContent = RESET_CSS;
    var html = document.createElement('div');
    html.className = 'fushi-seamless-html';
    var body = document.createElement('div');
    body.className = ('fushi-seamless-body ' + (data.bodyClass || '')).trim();
    html.appendChild(body);
    root.appendChild(epub);
    root.appendChild(rs);
    root.appendChild(reset);
    root.appendChild(html);
    host.__fushiSeamless = {chapter: chapter, body: body};
    return host;
  }
  // 宿主接入文档后才有 CSSOM（脱离文档的 shadow root 里 style.sheet 为 null），所以选择器
  // 改写在插入之后、同一任务里做，首次布局前就已经是改写后的规则。
  function finishHostStyles(host) {
    var root = host.shadowRoot;
    var tagged = root.querySelectorAll('style[data-role="epub"], style[data-role="reader"]');
    for (var i = 0; i < tagged.length; i++) rewriteStyleElement(tagged[i]);
    contentStylesToShadow(host.__fushiSeamless.body);
  }
  // ── 图片：与 _sharedInitImages 同一套归类规则（block-img-wrapper / 遮罩），根换成邻章容器 ──
  var revealed = Object.create(null);
  (C.revealedKeys || []).forEach(function(k) { revealed[k] = true; });
  if (typeof window.__fushiMarkImageRevealed === 'function') {
    var origMark = window.__fushiMarkImageRevealed;
    window.__fushiMarkImageRevealed = function(key) { if (key) revealed[key] = true; return origMark.apply(this, arguments); };
  }
  if (typeof window.__fushiUnmarkImageRevealed === 'function') {
    var origUnmark = window.__fushiUnmarkImageRevealed;
    window.__fushiUnmarkImageRevealed = function(key) { if (key) delete revealed[key]; return origUnmark.apply(this, arguments); };
  }
  function maybeBlur(el) {
    if (!C.blurImages) return;
    var key = typeof window.__fushiImageRevealKey === 'function' ? window.__fushiImageRevealKey(el) : '';
    if (key && revealed[key]) return;
    el.classList.add('blurred');
  }
  function isGaiji(el) { return el.classList.contains('gaiji') || el.classList.contains('gaiji-line'); }
  function wrapBlock(el) {
    el.classList.add('block-img');
    var wrapper = document.createElement('div');
    wrapper.className = 'block-img-wrapper';
    el.parentNode.insertBefore(wrapper, el);
    wrapper.appendChild(el);
    maybeBlur(el);
  }
  function prepareSvgs(root) {
    var svgs = root.querySelectorAll('svg');
    for (var i = 0; i < svgs.length; i++) {
      var svg = svgs[i];
      var im = svg.querySelector('image');
      if (!im) continue;
      if (svg.getAttribute('preserveAspectRatio') === 'none') svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
      if (isGaiji(svg)) continue;
      var iw = parseFloat(im.getAttribute('width')) || 0;
      var ih = parseFloat(im.getAttribute('height')) || 0;
      if (iw <= 256 && ih <= 256) {
        var vb = (svg.getAttribute('viewBox') || '').split(/[ ,]+/);
        iw = parseFloat(vb[2]) || iw;
        ih = parseFloat(vb[3]) || ih;
      }
      if ((iw > 256 || ih > 256) && !svg.closest('.block-img-wrapper')) wrapBlock(svg);
    }
  }
  function prepareImgs(root) {
    var imgs = root.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      img.removeAttribute('loading');
      img.setAttribute('decoding', 'async');
      if (isGaiji(img) || img.closest('.block-img-wrapper')) continue;
      if (img.naturalWidth > 256 || img.naturalHeight > 256) wrapBlock(img);
    }
  }
  // 插入文档前等图片解码完：上方邻章若先插入、图片后加载，视口内容会被往下推。先解码，
  // 插入后的几何就是终态。失败的图（404）照样放行，只是没有尺寸。
  function decodeImages(root) {
    var jobs = [];
    var imgs = root.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      jobs.push(imgs[i].decode().then(function() {}, function() {}));
    }
    var svgImages = root.querySelectorAll('image');
    for (var j = 0; j < svgImages.length; j++) {
      var href = svgImages[j].getAttribute('href') || svgImages[j].getAttribute('xlink:href');
      if (!href) continue;
      var probe = new Image();
      probe.src = href;
      jobs.push(probe.decode().then(function() {}, function() {}));
    }
    return Promise.all(jobs);
  }
  var URL_ATTRS = [
    ['img', 'src'], ['source', 'src'], ['video', 'src'], ['video', 'poster'], ['audio', 'src'],
    ['image', 'href'], ['image', 'xlink:href'], ['a', 'href'], ['use', 'href'], ['use', 'xlink:href']
  ];
  function absolutizeUrls(root, base) {
    for (var i = 0; i < URL_ATTRS.length; i++) {
      var tag = URL_ATTRS[i][0], attr = URL_ATTRS[i][1];
      var els = root.getElementsByTagName(tag);
      for (var j = 0; j < els.length; j++) {
        var v = els[j].getAttribute(attr);
        if (v === null) continue;
        // 章内纯 fragment 链接（#note1）也改成「该章 URL#note1」：晋升后文档 URL 仍是最初
        // 那一章，留着裸 fragment 就会指向错章。内链处理照常走 onInternalLink。
        var next = absUrl(v, base);
        if (next !== v) els[j].setAttribute(attr, next);
      }
    }
    var styled = root.querySelectorAll('[style]');
    for (var k = 0; k < styled.length; k++) {
      var s = styled[k].getAttribute('style');
      if (s && s.indexOf('url(') >= 0) styled[k].setAttribute('style', absolutizeCssUrls(s, base));
    }
  }

  var S = {
    activeChapter: typeof C.seamlessChapterIndex === 'number' ? C.seamlessChapterIndex : -1,
    started: false,
    seq: 0,
    ackedSeq: 0,
    lastViewportSource: 'program',
    chapterData: Object.create(null),
    pending: Object.create(null),
    deferred: [],
    mountFailures: Object.create(null),
    tap: null,
    evalRaf: 0
  };
  window.__fushiSeamless = S;

  function busy() {
    var r = reader();
    return !r || r._reanchorPending === true;
  }
  function runWhenIdle(fn) {
    if (busy()) { S.deferred.push(fn); return; }
    fn();
  }
  S._flushDeferred = function() {
    var q = S.deferred;
    S.deferred = [];
    for (var i = 0; i < q.length; i++) runWhenIdle(q[i]);
  };
  S.noteUser = function() { S.lastViewportSource = 'user'; };
  S.noteProgram = function() { S.lastViewportSource = 'program'; };
  S.awaitingAck = function() { return S.seq !== S.ackedSeq; };
  S.ack = function(seq, generation) {
    if (seq !== S.seq) return false;
    S.ackedSeq = seq;
    if (typeof generation === 'number') C.navigationGeneration = generation;
    return true;
  };
  S.mountedChapters = function() {
    return hosts().map(hostChapter);
  };

  // 初次恢复落定后启动：先认出当前文档 head 里哪些样式表属于本章（与重新拉取的同一份
  // 净化 HTML 比对），再挂邻章。
  S.start = async function() {
    if (S.started || S._starting) return;
    S._starting = true;
    // 待确认期间（JS 已换章、Dart 还没 ack）进度快照返回 null：所有调用方本来就把 null 当
    // 「未落定」，不会把新章的偏移记到旧章号上。fushiProgressDetails 在 setup 里、shell
    // 安装之后才定义，所以在启动时包。
    if (typeof window.fushiProgressDetails === 'function' && !window.fushiProgressDetails.__fushiSeamless) {
      var origDetails = window.fushiProgressDetails;
      var gatedDetails = function seamlessGatedProgressDetails() {
        if (S.awaitingAck()) return null;
        return origDetails.apply(this, arguments);
      };
      gatedDetails.__fushiSeamless = true;
      window.fushiProgressDetails = gatedDetails;
    }
    var entry = ORDER[posOf(S.activeChapter)];
    if (!entry) { S._starting = false; return; }
    var resp = await fetch(entry.url);
    if (!resp.ok) { S._starting = false; return; }
    var doc = new DOMParser().parseFromString(await resp.text(), 'text/html');
    var styles = await epubStylesOf(doc, entry.url);
    var bySig = Object.create(null);
    styles.forEach(function(s) { bySig[s.sig] = s; });
    var headEls = document.head ? document.head.querySelectorAll('link[rel~="stylesheet"], style') : [];
    for (var i = 0; i < headEls.length; i++) {
      var el = headEls[i];
      if (isReaderOwnedStyle(el)) continue;
      var sig = el.localName === 'link' ? sigOfLink(el.href) : sigOfText(el.textContent || '');
      if (bySig[sig]) el.setAttribute('data-fushi-seamless-css', sig);
    }
    S.chapterData[S.activeChapter] = {
      styles: styles,
      bodyClass: doc.body ? doc.body.className : ''
    };
    S.started = true;
    S._starting = false;
    S.ensureWindow();
  };

  function mount(chapter, dir) {
    if (S.pending[chapter] || hostFor(chapter) || S.mountFailures[chapter]) return;
    var entry = ORDER[posOf(chapter)];
    if (!entry) return;
    S.pending[chapter] = true;
    (async function() {
      var resp = await fetch(entry.url);
      if (!resp.ok) throw new Error('seamless fetch ' + resp.status + ' ' + entry.url);
      var doc = new DOMParser().parseFromString(await resp.text(), 'text/html');
      var data = {styles: await epubStylesOf(doc, entry.url), bodyClass: doc.body ? doc.body.className : ''};
      absolutizeUrls(doc.body, entry.url);
      var host = buildHost(chapter, data);
      var kids = doc.body ? Array.prototype.slice.call(doc.body.childNodes) : [];
      for (var i = 0; i < kids.length; i++) {
        if (kids[i].nodeType === 1 && kids[i].localName === 'script') continue;
        host.__fushiSeamless.body.appendChild(document.importNode(kids[i], true));
      }
      prepareSvgs(host.__fushiSeamless.body);
      await decodeImages(host.__fushiSeamless.body);
      prepareImgs(host.__fushiSeamless.body);
      return {host: host, data: data};
    })().then(function(res) {
      runWhenIdle(function() {
        delete S.pending[chapter];
        var want = neighborOf(S.activeChapter, dir);
        if (!want || want.index !== chapter || hostFor(chapter)) return;
        S.chapterData[chapter] = res.data;
        preserveViewport(function() {
          insertHost(res.host, dir);
          finishHostStyles(res.host);
        });
      });
    }, function(err) {
      delete S.pending[chapter];
      // 挂载失败不重试：该方向退回原来的「拉过边界整章重载」。错误照常上报控制台。
      S.mountFailures[chapter] = true;
      if (window.console && console.error) console.error('[seamless] mount failed', chapter, err);
    });
  }
  function insertHost(host, dir) {
    var body = document.body;
    var content = contentNodes();
    if (dir < 0) {
      var ref = content.length ? content[0] : null;
      if (!ref) {
        var after = hosts().filter(function(h) { return sideOf(h) > 0; });
        ref = after.length ? after[0] : null;
      }
      body.insertBefore(host, ref);
    } else {
      var last = content.length ? content[content.length - 1] : null;
      if (!last) {
        var before = hosts().filter(function(h) { return sideOf(h) < 0; });
        last = before.length ? before[before.length - 1] : null;
      }
      body.insertBefore(host, last ? last.nextSibling : body.firstChild);
    }
  }
  function unmountFar() {
    var prev = neighborOf(S.activeChapter, -1);
    var next = neighborOf(S.activeChapter, 1);
    var keep = Object.create(null);
    if (prev) keep[prev.index] = true;
    if (next) keep[next.index] = true;
    var victims = hosts().filter(function(h) {
      return !keep[hostChapter(h)] && !intersectsViewport(h);
    });
    if (!victims.length) return;
    preserveViewport(function() {
      victims.forEach(function(h) {
        delete S.chapterData[hostChapter(h)];
        h.remove();
      });
    });
  }
  S.ensureWindow = function() {
    if (!S.started) return;
    runWhenIdle(function() {
      unmountFar();
      var prev = neighborOf(S.activeChapter, -1);
      var next = neighborOf(S.activeChapter, 1);
      if (next) mount(next.index, 1);
      if (prev) mount(prev.index, -1);
    });
  };

  function syncBodyClasses(fromData, toData) {
    var cl = document.body.classList;
    String(fromData && fromData.bodyClass || '').split(/\s+/).forEach(function(c) { if (c) cl.remove(c); });
    String(toData && toData.bodyClass || '').split(/\s+/).forEach(function(c) { if (c) cl.add(c); });
  }
  function applyHeadStyles(toData) {
    var want = Object.create(null);
    toData.styles.forEach(function(s) { want[s.sig] = s; });
    var present = Object.create(null);
    var managed = document.head.querySelectorAll('[data-fushi-seamless-css]');
    for (var i = 0; i < managed.length; i++) {
      var sig = managed[i].getAttribute('data-fushi-seamless-css');
      present[sig] = true;
      managed[i].disabled = !want[sig];
    }
    var readerStyle = document.getElementById('fushi-reader-style');
    var anchor = readerStyle && readerStyle.parentNode === document.head ? readerStyle : null;
    toData.styles.forEach(function(s) {
      if (present[s.sig]) return;
      // 新增的一律用已经拉到的文本建 <style>（同步生效）；用 <link> 会异步加载，晋升补偿
      // 之后样式才到，视口会再跳一次。插在阅读器样式之前，保持阅读器样式最后生效。
      var el = document.createElement('style');
      el.textContent = s.text;
      el.setAttribute('data-fushi-seamless-css', s.sig);
      document.head.insertBefore(el, anchor);
    });
  }
  function clearChapterScopedState() {
    var r = reader();
    if (typeof r.resetSentenceAudioCues === 'function') r.resetSentenceAudioCues();
    if (typeof window.__fushiApplyHighlights === 'function') window.__fushiApplyHighlights([]);
    if (typeof r.clearSearchHighlight === 'function') r.clearSearchHighlight();
    if (window.fushiSelection && typeof window.fushiSelection.clearSelection === 'function') {
      window.fushiSelection.clearSelection();
    }
    // 收藏 / 搜索 / 句音频 / 选区 / 跳转落点都是挂在旧活动章节点上的 Range；节点即将搬进
    // shadow 宿主，注册表整份清掉，Dart 收到晋升后按新章重新下发。
    if (window.__fushiCssHighlightsSupported && window.CSS && CSS.highlights) CSS.highlights.clear();
    r.clearImageLateAnchor();
    r._setRestoreCharAnchor(null);
  }
  function rebuildEngineIndex() {
    var r = reader();
    r._textIndexCache = null;
    if (r.paginationMetrics !== undefined) r.paginationMetrics = null;
    r.buildNodeOffsets();
    if (window.__fushiLanes && typeof window.__fushiLanes.repaint === 'function') window.__fushiLanes.repaint();
  }
  // 晋升：把 [host] 里的章节换成活动章。一个任务内同步完成，前后视口不动。
  S.promote = function(host) {
    if (!host || !host.isConnected || !S.started) return false;
    var to = hostChapter(host);
    var from = S.activeChapter;
    var fromData = S.chapterData[from];
    var toData = S.chapterData[to];
    if (!fromData || !toData || to === from) return false;
    clearChapterScopedState();
    preserveViewport(function() {
      var body = document.body;
      var old = contentNodes();
      var oldHost = buildHost(from, fromData);
      body.insertBefore(oldHost, old.length ? old[0] : host);
      for (var i = 0; i < old.length; i++) oldHost.__fushiSeamless.body.appendChild(old[i]);
      var inner = host.__fushiSeamless.body;
      var moved = Array.prototype.slice.call(inner.childNodes);
      for (var j = 0; j < moved.length; j++) body.insertBefore(moved[j], host);
      host.remove();
      contentStylesToLight(moved);
      syncBodyClasses(fromData, toData);
      applyHeadStyles(toData);
      finishHostStyles(oldHost);
      S.activeChapter = to;
      unmountFarSync();
    });
    rebuildEngineIndex();
    S.seq += 1;
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('onSeamlessChapterActivated', to, from, S.seq);
    }
    S.ensureWindow();
    return true;
  };
  // 晋升内部用的同步卸载（已经在 preserveViewport 里，不再嵌套补偿）。
  function unmountFarSync() {
    var prev = neighborOf(S.activeChapter, -1);
    var next = neighborOf(S.activeChapter, 1);
    hosts().forEach(function(h) {
      var c = hostChapter(h);
      if ((prev && c === prev.index) || (next && c === next.index)) return;
      if (intersectsViewport(h)) return;
      delete S.chapterData[c];
      h.remove();
    });
  }
  // 视口中心越过邻章边界 HYSTERESIS 才晋升；只认最近一次视口移动来自用户的情形。
  S.evaluate = function() {
    if (!S.started || busy() || S.lastViewportSource !== 'user') return false;
    if (window.__fushiTextSelectDragActive) return false;
    var c = viewportMain() / 2;
    var next = adjacentHost(1);
    if (next && c >= mainRange(next.getBoundingClientRect()).start + HYSTERESIS) return S.promote(next);
    var prev = adjacentHost(-1);
    if (prev && c <= mainRange(prev.getBoundingClientRect()).end - HYSTERESIS) return S.promote(prev);
    return false;
  };
  function scheduleEvaluate() {
    if (S.evalRaf) return;
    S.evalRaf = requestAnimationFrame(function() {
      S.evalRaf = 0;
      S.evaluate();
    });
  }
  // ── 活动章边界（供装饰后的章首 / 章末 / isAtEnd / 首可见字使用）──
  function bodyPaddingStart() {
    var cs = getComputedStyle(document.body);
    return vertical() ? (parseFloat(cs.paddingRight) || 0) : (parseFloat(cs.paddingTop) || 0);
  }
  S.alignActiveStart = function() {
    var before = hosts().filter(function(h) { return sideOf(h) < 0; });
    if (!before.length) return false;
    var last = before[before.length - 1];
    scrollMain(mainRange(last.getBoundingClientRect()).end - bodyPaddingStart());
    return true;
  };
  S.nextHostElement = function() {
    var after = hosts().filter(function(h) { return sideOf(h) > 0; });
    return after.length ? after[0] : null;
  };
  S.alignActiveEnd = function() {
    var next = S.nextHostElement();
    if (!next) return false;
    scrollMain(mainRange(next.getBoundingClientRect()).start - viewportMain());
    return true;
  };
  S.activeEndVisible = function() {
    var next = S.nextHostElement();
    if (!next) return null;
    return mainRange(next.getBoundingClientRect()).start <= viewportMain() + 1;
  };
  // 点 (x, y) 落在哪一侧的邻章里：-1 之前 / +1 之后 / 0 不在邻章里。
  S.regionAt = function(x, y) {
    var el = document.elementFromPoint(x, y);
    while (el && !isHost(el)) el = el.parentElement;
    return el ? sideOf(el) : 0;
  };
  S.onReaderStyleChanged = function(css) {
    hosts().forEach(function(h) {
      var el = h.shadowRoot.querySelector('style[data-role="reader"]');
      if (!el) return;
      el.textContent = css;
      rewriteStyleElement(el);
    });
  };

  // ── 装饰引擎方法 ──
  var r0 = window.fushiReader;
  function wrap(name, make) {
    var orig = r0[name];
    if (typeof orig !== 'function') return;
    r0[name] = make(orig);
  }
  function programmatic(orig) {
    return function() { S.noteProgram(); return orig.apply(this, arguments); };
  }
  ['scrollToTarget', 'scrollToCharOffset', 'restoreProgress', 'restoreToCharOffset', 'jumpToFragment',
   'scrollToProgressContinuous', 'alignToFragmentTarget', 'reapplyImageLateAnchor', 'updatePageSize',
   'setChromeInsets'].forEach(function(n) { wrap(n, programmatic); });
  wrap('paginate', function(orig) {
    return function() { S.noteUser(); return orig.apply(this, arguments); };
  });
  wrap('scrollToChapterStart', function(orig) {
    return function() {
      S.noteProgram();
      if (S.started && S.alignActiveStart()) return;
      return orig.apply(this, arguments);
    };
  });
  wrap('scrollToChapterEnd', function(orig) {
    return function() {
      S.noteProgram();
      if (!S.started || !S.nextHostElement()) return orig.apply(this, arguments);
      var content = contentNodes();
      var last = null;
      for (var i = content.length - 1; i >= 0 && !last; i--) {
        var n = content[i];
        if (n.nodeType !== 1) continue;
        var tag = n.tagName;
        var rect = n.getBoundingClientRect();
        if (tag !== 'SCRIPT' && tag !== 'STYLE' && tag !== 'TEMPLATE' && (rect.width > 0 || rect.height > 0)) last = n;
      }
      if (last) last.scrollIntoView({block: 'end', inline: 'nearest', behavior: 'instant'});
      else S.alignActiveEnd();
    };
  });
  wrap('isAtEnd', function(orig) {
    return function() {
      if (S.started) {
        var v = S.activeEndVisible();
        if (v !== null) return v;
      }
      return orig.apply(this, arguments);
    };
  });
  wrap('getFirstVisibleCharOffset', function(orig) {
    return function() {
      if (S.started) {
        var cs = getComputedStyle(document.body);
        var v = vertical();
        var x = v ? (window.innerWidth - (parseFloat(cs.paddingRight) || 0) - 2) : ((parseFloat(cs.paddingLeft) || 0) + 2);
        var y = (parseFloat(cs.paddingTop) || 0) + 2;
        var side = S.regionAt(x, y);
        if (side < 0) return 0;
        if (side > 0) return this.chapterCharTotal();
      }
      return orig.apply(this, arguments);
    };
  });
  wrap('beginStyleReanchor', function(orig) {
    return function(styleEl, css) {
      S.noteProgram();
      var out = orig.apply(this, arguments);
      S.onReaderStyleChanged(css);
      return out;
    };
  });
  wrap('_setReanchorPending', function(orig) {
    return function(value) {
      var out = orig.apply(this, arguments);
      if (value !== true) S._flushDeferred();
      return out;
    };
  });
  wrap('notifyRestoreComplete', function(orig) {
    return function() {
      var out = orig.apply(this, arguments);
      if (!S.started) S.start();
      return out;
    };
  });

  // ── 输入：用户驱动的视口移动 + 轻点邻章即晋升 ──
  var opts = {capture: true, passive: true};
  document.addEventListener('wheel', S.noteUser, opts);
  document.addEventListener('touchmove', S.noteUser, opts);
  document.addEventListener('keydown', function(e) { if (SCROLL_KEYS[e.key]) S.noteUser(); }, opts);
  document.addEventListener('pointerdown', function(e) { if (e.target === document.documentElement) S.noteUser(); }, opts);
  document.addEventListener('scroll', scheduleEvaluate, opts);
  function hostInPath(e) {
    var path = typeof e.composedPath === 'function' ? e.composedPath() : [];
    for (var i = 0; i < path.length; i++) if (isHost(path[i])) return path[i];
    return null;
  }
  function tapStart(e, x, y) {
    var h = hostInPath(e);
    S.tap = h ? {host: h, x: x, y: y} : null;
  }
  function tapEnd(x, y) {
    var t = S.tap;
    S.tap = null;
    if (!t || !t.host.isConnected) return;
    if (Math.abs(x - t.x) >= TAP_SLOP || Math.abs(y - t.y) >= TAP_SLOP) return;
    if (busy()) return;
    S.promote(t.host);
  }
  // window capture 先于正文的 document 级手势监听：晋升在它们看到这次点按之前完成，
  // 同一坐标落在已经回到 light DOM 的同一个字上。
  window.addEventListener('touchstart', function(e) {
    if (e.touches.length === 1) tapStart(e, e.touches[0].clientX, e.touches[0].clientY);
    else S.tap = null;
  }, opts);
  window.addEventListener('touchend', function(e) {
    if (e.changedTouches.length) tapEnd(e.changedTouches[0].clientX, e.changedTouches[0].clientY);
  }, opts);
  window.addEventListener('mousedown', function(e) { if (e.button === 0) tapStart(e, e.clientX, e.clientY); }, opts);
  window.addEventListener('mouseup', function(e) { if (e.button === 0) tapEnd(e.clientX, e.clientY); }, opts);
})();
'''
        .replaceAll('__HOST_TAG__', kSeamlessChapterHostTag)
        .replaceAll('__HYSTERESIS__', '$kSeamlessPromoteHysteresisPx')
        .replaceAll('__TAP_SLOP__', '$kSeamlessTapSlopPx');
