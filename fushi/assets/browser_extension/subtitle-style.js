// 视频上自绘字幕（#fushi-subtitle-overlay）的外观设置：字体、大小、字重、字间距、行高、对齐、
// 文字颜色、描边，以及底板的颜色 / 不透明度 / 圆角 / 内边距 / 宽 / 高。
//
// 存储：chrome.storage.local.subtitleStyle = 一个对象（部分字段也可缺省），字段名对齐 app 侧
// VideoSubtitleStyle（fontSize / fontWeight / textColor / shadow* / background*）。底板开关仍是
// 既有布尔键 subtitleOverlayBackground（旧用户设置不迁移）。
//
// 落地方式：content-css-overlay.css 里覆盖层的每一项外观都读 --fushi-sub-* 变量并给默认值；
// 这里把设置对象翻成「与默认不同的那几个变量」，subtitle-panel.js 逐个 setProperty 到覆盖层根，
// 默认值的变量 removeProperty 交还 CSS。options 页的实时预览走同一份 toCssVars。
// 底板宽 / 高是例外：它们是**视频盒的百分比**，而覆盖层是 position:fixed，CSS 百分比只会对
// 视口算，所以不走变量——boxPx 按当前视频盒折成 px，applyBox 写进 style.width / minHeight
// （覆盖层每次重摆、预览每次改动 / 视口变化各调一次）。0 = 随内容（默认，即旧观感）。
//
// 纯函数、无 DOM、无 chrome.*；content script（subtitle-panel.js）、options 页、测试共用。
(function () {
  'use strict';
  var g = (typeof window !== 'undefined') ? window : ((typeof self !== 'undefined') ? self : null);
  if (!g) return;

  var KEY = 'subtitleStyle';
  var DEFAULT_FONT_FAMILY = '"Hiragino Sans", "Yu Gothic UI", sans-serif';
  var DEFAULT_TEXT_COLOR = '#f7f8f2';      // theme.css --fushi-on-scrim
  var DEFAULT_BACKGROUND_COLOR = '#0c0f0d'; // theme.css --fushi-scrim 的 rgb(12, 15, 13)
  var DEFAULTS = Object.freeze({
    fontFamily: '',        // '' = 默认字体栈
    fontScale: 100,        // 百分比；100 = clamp(18px, 2.2vw, 32px) 的响应式基准
    fontWeight: 600,
    letterSpacing: 1,      // 单位 0.01em；默认 0.01em
    lineHeight: 145,       // 百分比；有振假名的句子取 max(200%, 本值)
    textAlign: 'center',
    textColor: '',         // '' = 跟随主题 --fushi-on-scrim
    shadow: 'soft',        // none | soft | strong
    backgroundColor: '',   // '' = 跟随主题 --fushi-scrim 的颜色
    backgroundOpacity: 72, // 百分比
    borderRadius: 8,       // px
    padding: 100,          // 百分比（默认 6px 12px 7px）
    boxWidth: 0,           // 视频宽的百分比；0 = 随内容（文字撑开，最宽到 subtitle-panel 的视口夹取）
    boxHeight: 0,          // 视频高的百分比（下限，内容更高时自动加高）；0 = 随内容
    boxAutoFit: true,      // 自适应缩放：底板定了高度时，字号随盒伸缩到整句刚好放下（见 nextFitScale）
  });
  var LIMITS = Object.freeze({
    fontScale: [50, 300],
    fontWeight: [100, 900],
    letterSpacing: [-5, 30],
    lineHeight: [100, 250],
    backgroundOpacity: [0, 100],
    borderRadius: [0, 32],
    padding: [0, 300],
    boxWidth: [0, 100],
    boxHeight: [0, 60],
  });
  // 宽 / 高非 0 时的下限：再窄就一字一行、再矮就等于没设。0 单独表示「随内容」，不受下限约束。
  var BOX_FLOOR = Object.freeze({ boxWidth: 20, boxHeight: 5 });
  // 自适应缩放倍率（--fushi-sub-fit）的允许区间。下限 0.35 是「还读得清」的底：压到这里仍放不下
  // 的超长句**不再继续压**，改让底板按 min-height 自己长高（字一个都不许裁掉）；上限 2.5 防止
  // 用户把底板拉得极大时字大到糊满画面。
  var FIT_RANGE = Object.freeze([0.35, 2.5]);
  // 收敛容差：实测高落在可用高的 [1-TOL, 1] 区间内就算「刚好放下」，不再迭代。
  var FIT_TOLERANCE = 0.04;
  var ALIGNS = { left: true, center: true, right: true };
  var SHADOWS = {
    none: 'none',
    soft: '0 1px 3px #000, 1px 0 2px #000, -1px 0 2px #000',
    strong: '0 0 2px #000, 0 0 4px #000, 1px 1px 2px #000, -1px -1px 2px #000, 1px -1px 2px #000, -1px 1px 2px #000',
  };
  // options 页字体下拉的「本机字体栈」组；值就是 CSS font-family 串（不是文案，不进 i18n）。
  // Fushi 字体库里的字体另成一组（family 名来自 app，经 fontFaceCss 以 @font-face 挂进页面）。
  var FONT_SUGGESTIONS = Object.freeze([
    '"Hiragino Sans", "Yu Gothic UI", sans-serif',
    '"Hiragino Maru Gothic ProN", "BIZ UDPGothic", "Yu Gothic UI", sans-serif',
    '"Hiragino Mincho ProN", "Yu Mincho", serif',
    '"Noto Sans JP", "Noto Sans CJK JP", sans-serif',
    '"Noto Serif JP", "Noto Serif CJK JP", serif',
    'system-ui, sans-serif',
    'sans-serif',
    'serif',
    'monospace',
  ]);

  function clampInt(v, range, fallback) {
    var n = typeof v === 'string' ? parseFloat(v) : v;
    if (typeof n !== 'number' || !isFinite(n)) return fallback;
    n = Math.round(n);
    if (n < range[0]) n = range[0];
    if (n > range[1]) n = range[1];
    return n;
  }

  // 底板宽 / 高：0 原样保留（随内容），其余夹进 [下限, 上限]。
  function clampBox(v, key) {
    var n = clampInt(v, LIMITS[key], DEFAULTS[key]);
    if (n === 0) return 0;
    return Math.max(BOX_FLOOR[key], n);
  }

  function normalizeHex(v) {
    if (typeof v !== 'string') return '';
    var m = /^#?([0-9a-f]{6})$/i.exec(v.trim());
    if (m) return '#' + m[1].toLowerCase();
    var s = /^#?([0-9a-f]{3})$/i.exec(v.trim());
    if (!s) return '';
    var t = s[1];
    return ('#' + t[0] + t[0] + t[1] + t[1] + t[2] + t[2]).toLowerCase();
  }

  // 字体串只允许字体名、引号、逗号、空格、连字符；分号/花括号等一律剥掉——setProperty 本就
  // 不会让值逃出声明，这里再收紧一层，顺带限长。范围上界必须写成 \uffff 转义：裸 U+FFFF 是
  // Unicode 非字符，Chrome 会把整个文件判成「不是 UTF-8」拒绝加载扩展（守卫 utf8-shippable.test.js）。
  function normalizeFontFamily(v) {
    if (typeof v !== 'string') return '';
    var s = v.replace(/[^\w\s,"'\-.\u00a0-\uffff]/g, '').replace(/\s+/g, ' ').trim().slice(0, 200);
    return s;
  }

  function normalize(v) {
    var c = (v && typeof v === 'object') ? v : {};
    var weight = clampInt(c.fontWeight, LIMITS.fontWeight, DEFAULTS.fontWeight);
    return {
      fontFamily: normalizeFontFamily(c.fontFamily),
      fontScale: clampInt(c.fontScale, LIMITS.fontScale, DEFAULTS.fontScale),
      fontWeight: Math.round(weight / 100) * 100,
      letterSpacing: clampInt(c.letterSpacing, LIMITS.letterSpacing, DEFAULTS.letterSpacing),
      lineHeight: clampInt(c.lineHeight, LIMITS.lineHeight, DEFAULTS.lineHeight),
      textAlign: ALIGNS[c.textAlign] ? c.textAlign : DEFAULTS.textAlign,
      textColor: normalizeHex(c.textColor),
      shadow: SHADOWS[c.shadow] !== undefined ? c.shadow : DEFAULTS.shadow,
      backgroundColor: normalizeHex(c.backgroundColor),
      backgroundOpacity: clampInt(c.backgroundOpacity, LIMITS.backgroundOpacity, DEFAULTS.backgroundOpacity),
      borderRadius: clampInt(c.borderRadius, LIMITS.borderRadius, DEFAULTS.borderRadius),
      padding: clampInt(c.padding, LIMITS.padding, DEFAULTS.padding),
      boxWidth: clampBox(c.boxWidth, 'boxWidth'),
      boxHeight: clampBox(c.boxHeight, 'boxHeight'),
      boxAutoFit: c.boxAutoFit !== false,
    };
  }

  function isDefault(style) {
    var s = normalize(style);
    for (var k in DEFAULTS) if (s[k] !== DEFAULTS[k]) return false;
    return true;
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
  }

  function rgbaOf(hex, opacityPercent) {
    var c = hexToRgb(hex);
    var a = Math.round(opacityPercent) / 100;
    return 'rgba(' + c.r + ', ' + c.g + ', ' + c.b + ', ' + a + ')';
  }

  // 设置 → 覆盖层根上要写的 CSS 变量。值为 null 的项表示「用 CSS 默认」（调用方 removeProperty）。
  // 全部变量名都在 content-css-overlay.css 的 #fushi-subtitle-overlay 块里有默认值。
  function toCssVars(style) {
    var s = normalize(style);
    var vars = {
      '--fushi-sub-family': s.fontFamily ? s.fontFamily : null,
      '--fushi-sub-scale': s.fontScale === DEFAULTS.fontScale ? null : String(s.fontScale / 100),
      '--fushi-sub-weight': s.fontWeight === DEFAULTS.fontWeight ? null : String(s.fontWeight),
      '--fushi-sub-spacing': s.letterSpacing === DEFAULTS.letterSpacing ? null : (s.letterSpacing / 100) + 'em',
      '--fushi-sub-line-height': s.lineHeight === DEFAULTS.lineHeight ? null : String(s.lineHeight / 100),
      '--fushi-sub-align': s.textAlign === DEFAULTS.textAlign ? null : s.textAlign,
      '--fushi-sub-color': s.textColor ? s.textColor : null,
      '--fushi-sub-shadow': s.shadow === DEFAULTS.shadow ? null : SHADOWS[s.shadow],
      '--fushi-sub-radius': s.borderRadius === DEFAULTS.borderRadius ? null : s.borderRadius + 'px',
      '--fushi-sub-padding': s.padding === DEFAULTS.padding ? null
        : (6 * s.padding / 100).toFixed(1) + 'px ' + (12 * s.padding / 100).toFixed(1) + 'px ' + (7 * s.padding / 100).toFixed(1) + 'px',
    };
    // 底板颜色：颜色或不透明度任一非默认就整体给 rgba；两者都默认交给主题 --fushi-scrim。
    if (s.backgroundColor || s.backgroundOpacity !== DEFAULTS.backgroundOpacity) {
      vars['--fushi-sub-bg'] = rgbaOf(s.backgroundColor || DEFAULT_BACKGROUND_COLOR, s.backgroundOpacity);
    } else {
      vars['--fushi-sub-bg'] = null;
    }
    return vars;
  }

  // 下拉里给一条 font-family 串起个可读标签：取前两个 family 去引号（"Hiragino Sans" → Hiragino Sans /
  // Yu Gothic UI）；关键字栈（sans-serif / monospace）原样。
  function fontStackLabel(stack) {
    if (typeof stack !== 'string') return '';
    var parts = stack.split(',').map(function (x) { return x.trim().replace(/^["']|["']$/g, ''); })
      .filter(function (x) { return x; });
    return parts.slice(0, 2).join(' / ');
  }

  // Fushi 字体库条目 → 要存进设置的 font-family 值（family 加双引号；引号/反斜杠剥掉）。
  function fontFamilyValueOf(family) {
    if (typeof family !== 'string') return '';
    // 与 normalizeFontFamily 同一字符集：存进 style 的值会被它过滤，这里若留下
    // `[ ] ( ) + / &`（NotoSansJP[wght] 这类导入文件名），下拉回显与 @font-face 的
    // family 两边就对不上——永远选不中、也载不进。@font-face 的 family 只是标签，
    // 两边一致即可。
    var f = family.replace(/["'\\]/g, '').replace(/[^\w\s,\-.\u00a0-\uffff]/g, '')
      .replace(/\s+/g, ' ').trim().slice(0, 100);
    return f ? '"' + f + '"' : '';
  }

  // 是否「就是」某个 Fushi 字体库条目（下拉回显与 @font-face 命中用同一判据）。
  function matchesFushiFont(fontFamily, family) {
    var v = fontFamilyValueOf(family);
    return !!v && normalizeFontFamily(fontFamily) === v;
  }

  var FONT_FORMATS = { ttf: 'truetype', otf: 'opentype', woff: 'woff', woff2: 'woff2', ttc: 'collection' };

  // Fushi 字体库（app 经 /api/extension/fonts 回的 [{family, url, ext}]）→ 注进页面的 @font-face 文本。
  // 浏览器只会为真被 font-family 命中的 family 去取字节，所以全量声明也不会多下载一个字体。
  // url 只收 http(s)（app 本机服务），family 经 fontFamilyValueOf 消毒后已带引号、不可能逃出声明。
  function fontFaceCss(fonts) {
    if (!Array.isArray(fonts)) return '';
    var out = [];
    for (var i = 0; i < fonts.length; i++) {
      var f = fonts[i] || {};
      var fam = fontFamilyValueOf(f.family);
      var url = typeof f.url === 'string' ? f.url.trim() : '';
      if (!fam || !/^https?:\/\//i.test(url) || /["'()\s]/.test(url)) continue;
      var fmt = FONT_FORMATS[String(f.ext || '').toLowerCase()];
      out.push('@font-face{font-family:' + fam + ';src:url("' + url + '")' + (fmt ? ' format("' + fmt + '")' : '') +
        ';font-display:swap;}');
    }
    return out.join('\n');
  }

  // 底板宽 / 高 → px。frame 是「视频盒」（覆盖层传 video.getBoundingClientRect()，预览传预览
  // 舞台的盒），只认 {width, height} 两个有限正数；缺 / 坏 frame 与 0 值都给 0 = 随内容。
  function boxPx(style, frame) {
    var s = normalize(style);
    var fw = frame && isFinite(frame.width) && frame.width > 0 ? frame.width : 0;
    var fh = frame && isFinite(frame.height) && frame.height > 0 ? frame.height : 0;
    return {
      width: s.boxWidth > 0 && fw > 0 ? Math.round(fw * s.boxWidth / 100) : 0,
      minHeight: s.boxHeight > 0 && fh > 0 ? Math.round(fh * s.boxHeight / 100) : 0,
    };
  }

  // 把底板宽 / 高写到元素上：非 0 写 px，0 清空交还 CSS（覆盖层 = 随内容 + max-width 视口夹取）。
  // 宽写的是 width 而非 min-width：固定底板就该固定，文字在其中换行；高写 min-height，内容更
  // 高时只加高不裁字。两者都以 border-box 计（CSS 里已设 box-sizing）。
  function applyBox(el, style, frame) {
    if (!el || !el.style) return;
    var box = boxPx(style, frame);
    try {
      el.style.width = box.width > 0 ? box.width + 'px' : '';
      el.style.minHeight = box.minHeight > 0 ? box.minHeight + 'px' : '';
    } catch (_) {}
  }

  // 拖拽把手量到的像素尺寸 → 要存进设置的百分比（boxPx 的逆）。覆盖层右下角把手与 options
  // 两根滑杆写的是同一对字段，所以夹取必须走同一处 clampBox——否则拖拽能写出滑杆写不出的越界值。
  // frame 坏掉（视频盒还没量到）时返回 null = 「这次拖拽算不出尺寸，别写」。
  function boxFromPx(widthPx, heightPx, frame) {
    var fw = frame && isFinite(frame.width) && frame.width > 0 ? frame.width : 0;
    var fh = frame && isFinite(frame.height) && frame.height > 0 ? frame.height : 0;
    if (!fw || !fh) return null;
    var w = Number(widthPx), h = Number(heightPx);
    if (!isFinite(w) || !isFinite(h)) return null;
    // 注意这里**不**走 clampBox：0 在设置里专指「随内容」，而拖拽永远是在指定一个尺寸——
    // 拖得再小也只该落到下限（20% / 5%），不能四舍五入成 0 把底板变回随内容
    // （那是双击把手的语义）。上下限仍与滑杆同一组常量。
    // 向下取整而不是四舍五入：拖拽给的是「最多延伸到这里」，向上取整会让底板比指针走得还远
    // （百分点在 1280px 宽的画面上值 13px）——指针已经夹在视频盒边缘时，那就是探出画面。
    function pct(v, total, key) {
      var n = Math.floor(v / total * 100);
      if (!isFinite(n)) n = BOX_FLOOR[key];
      return Math.min(LIMITS[key][1], Math.max(BOX_FLOOR[key], n));
    }
    return { boxWidth: pct(w, fw, 'boxWidth'), boxHeight: pct(h, fh, 'boxHeight') };
  }

  // 自适应缩放是否该介入。条件是**底板有高度**：高是 0（随内容）时盒子本来就随字长高，
  // 没有「放不放得下」可言，此时再缩放字号只会让同一句忽大忽小。右下角把手一次写宽 + 高，
  // 所以拖过的用户自然满足这条。
  function fitEnabled(style) {
    var s = normalize(style);
    return s.boxAutoFit && s.boxHeight > 0;
  }

  function clampFit(v) {
    var n = Number(v);
    if (!isFinite(n) || n <= 0) return 1;
    return Math.min(FIT_RANGE[1], Math.max(FIT_RANGE[0], n));
  }

  // 自适应缩放的一步迭代（纯函数，DOM 测量由调用方做）。
  //
  // m = { contentH, availH, contentW, availW }：contentH/W 是文字层在**当前 fit 下**的实测尺寸，
  // availH/W 是底板扣掉内边距后的可用尺寸（高来自设置里的底板高，不是实测高——底板写的是
  // min-height，内容一溢出盒子自己就长高了，拿实测高做分母永远判不出「放不下」）。
  //
  // 返回 { fit, done }：fit 是下一轮该用的倍率，done=true 表示已经「刚好放下」可以收手。
  // 换行是非线性的（缩小字号可能少折一行，高度阶跃式下降），所以一次比例外推不保证到位，
  // 由调用方迭代几轮；横向溢出（一个长到断不开的词）只许收、不许放。
  function nextFitScale(current, m, opts) {
    var fit = clampFit(current);
    var contentH = m && isFinite(m.contentH) ? m.contentH : 0;
    var availH = m && isFinite(m.availH) ? m.availH : 0;
    if (contentH <= 0 || availH <= 0) return { fit: fit, done: true };
    var tol = opts && isFinite(opts.tolerance) ? opts.tolerance : FIT_TOLERANCE;
    var ratio = availH / contentH;
    var contentW = m && isFinite(m.contentW) ? m.contentW : 0;
    var availW = m && isFinite(m.availW) ? m.availW : 0;
    if (contentW > 0 && availW > 0 && contentW > availW + 0.5) {
      ratio = Math.min(ratio, availW / contentW);
    }
    var next = clampFit(fit * ratio);
    // 收手条件：① 已经「放得下且基本填满」——ratio 是「可用 / 实测」，放得下是
    // ratio >= 1，填得满是 ratio <= 1 + 容差（写反边界就是「刚好溢出一点反而判收手」）；
    // ② 倍率顶到区间边界后还想继续同方向走（再迭代也只会原地踏步）；③ 倍率变化小到看不出来。
    var done = (ratio >= 1 && ratio <= 1 + tol) ||
      (next === fit) ||
      (Math.abs(next - fit) / fit < 0.01);
    return { fit: next, done: done };
  }

  // 把自适应倍率写到元素上（1 = 不缩放，交还 CSS 默认）。
  function applyFit(el, fit) {
    if (!el || !el.style) return;
    var f = clampFit(fit);
    try {
      if (Math.abs(f - 1) < 0.005) el.style.removeProperty('--fushi-sub-fit');
      else el.style.setProperty('--fushi-sub-fit', String(Math.round(f * 1000) / 1000));
    } catch (_) {}
  }

  // 元素的内边距（自适应缩放要从底板尺寸里扣掉它才是文字的可用空间）。getComputedStyle 拿不到
  // （老内核 / 纯 vm 测试壳）时按 0 算：只会让可用空间被高估一点，不会写出坏值。
  function paddingOf(el) {
    var view = null;
    try { view = el && el.ownerDocument && el.ownerDocument.defaultView; } catch (_) {}
    var cs = null;
    try { if (view && typeof view.getComputedStyle === 'function') cs = view.getComputedStyle(el); } catch (_) {}
    if (!cs) return { v: 0, h: 0 };
    function px(v) { var n = parseFloat(v); return isFinite(n) ? n : 0; }
    return {
      v: px(cs.paddingTop) + px(cs.paddingBottom),
      h: px(cs.paddingLeft) + px(cs.paddingRight),
    };
  }

  // 自适应缩放的落地：把 textEl 里的整句缩放到「box 里刚好放下」，返回最终倍率。
  // el = 底板（写 --fushi-sub-fit 的那个），textEl = 文字层（被测量的那个），frame = 视频盒 /
  // 预览舞台盒。网页覆盖层与 options 预览共用这一份，观感不可能对不上。
  //
  // 可用高取**设置里的底板高**而不是实测高：applyBox 写的是 min-height，内容一溢出盒子自己就
  // 长高了，拿实测高当分母永远判不出「放不下」。宽同理（0 = 随内容时才退回实测宽）。
  // 迭代而非一次外推：换行是非线性的（字号小一点可能少折一行，高度阶跃下降）。
  // 收手后再验一次——迭代次数用尽也绝不让用户看到溢出的半句。
  function fitTextInto(el, textEl, style, frame, opts) {
    if (!el || !el.style || !textEl) return 1;
    if (!fitEnabled(style)) { applyFit(el, 1); return 1; }
    var box = boxPx(style, frame);
    if (!(box.minHeight > 0)) { applyFit(el, 1); return 1; }
    var pad = paddingOf(el);
    var availH = Math.max(1, box.minHeight - pad.v);
    var wpx = box.width > 0 ? box.width : (isFinite(el.clientWidth) ? el.clientWidth : 0);
    var availW = wpx > 0 ? Math.max(1, wpx - pad.h) : 0;
    var rounds = opts && isFinite(opts.rounds) ? opts.rounds : 6;

    function measure() {
      return {
        contentH: isFinite(textEl.scrollHeight) ? textEl.scrollHeight : 0,
        contentW: isFinite(textEl.scrollWidth) ? textEl.scrollWidth : 0,
        availH: availH,
        availW: availW,
      };
    }
    function fits(m) {
      if (!(m.contentH > 0)) return false;
      if (m.contentH > availH + 0.5) return false;
      return !(availW > 0 && m.contentW > availW + 0.5);
    }

    // 一点都量不到（节点还没排版 / 隐藏 / 测试壳没提供尺寸）：什么都不知道就什么都不改。
    // 这条必须在迭代前就拦：下面的「没验证到能放下就退到下限」是为超长句准备的，
    // 拿它处理「量不到」会把一句正常字幕无缘无故缩成最小字号。
    applyFit(el, 1);
    if (!(measure().contentH > 0)) return 1;

    var fit = 1;
    var best = 0;            // 已验证「放得下」的最大倍率；0 = 一个都没验证到
    var worst = Infinity;    // 已验证「放不下」的最小倍率
    for (var i = 0; i < rounds; i++) {
      applyFit(el, fit);
      var m = measure();
      if (fits(m)) best = Math.max(best, fit); else worst = Math.min(worst, fit);
      var step = nextFitScale(fit, m, opts);
      if (step.done) { fit = step.fit; break; }
      // 换行是阶跃的，比例外推会在「少折一行」与「多折一行」两个值之间来回跳，
      // 把下一步夹进已知区间（放得下的最大值, 放不下的最小值），跳出区间就改二分。
      var next = step.fit;
      if (!(next > best && next < worst)) {
        if (best > 0 && worst < Infinity) next = (best + worst) / 2;
      }
      if (Math.abs(next - fit) / fit < 0.01) { fit = next; break; }
      fit = next;
    }
    applyFit(el, fit);
    if (!fits(measure())) {
      // 最后一轮的倍率没验证过就收手了：退回已验证的最大倍率。真放不下（超长句压到下限仍
      // 溢出）时 best 为 0，取下限——底板按 min-height 自己长高，字一个都不裁。
      fit = best > 0 ? best : FIT_RANGE[0];
      applyFit(el, fit);
    }
    return fit;
  }

  // 把变量套到元素上（覆盖层根 / options 预览）。
  function applyTo(el, style) {
    if (!el || !el.style) return;
    var vars = toCssVars(style);
    for (var k in vars) {
      try {
        if (vars[k] == null) el.style.removeProperty(k);
        else el.style.setProperty(k, vars[k]);
      } catch (_) {}
    }
  }

  g.fushiSubtitleStyle = {
    KEY: KEY,
    DEFAULTS: DEFAULTS,
    LIMITS: LIMITS,
    BOX_FLOOR: BOX_FLOOR,
    FIT_RANGE: FIT_RANGE,
    FIT_TOLERANCE: FIT_TOLERANCE,
    SHADOWS: SHADOWS,
    FONT_SUGGESTIONS: FONT_SUGGESTIONS,
    DEFAULT_FONT_FAMILY: DEFAULT_FONT_FAMILY,
    DEFAULT_TEXT_COLOR: DEFAULT_TEXT_COLOR,
    DEFAULT_BACKGROUND_COLOR: DEFAULT_BACKGROUND_COLOR,
    normalize: normalize,
    isDefault: isDefault,
    toCssVars: toCssVars,
    applyTo: applyTo,
    boxPx: boxPx,
    boxFromPx: boxFromPx,
    applyBox: applyBox,
    fitEnabled: fitEnabled,
    clampFit: clampFit,
    nextFitScale: nextFitScale,
    applyFit: applyFit,
    fitTextInto: fitTextInto,
    fontStackLabel: fontStackLabel,
    fontFamilyValueOf: fontFamilyValueOf,
    matchesFushiFont: matchesFushiFont,
    fontFaceCss: fontFaceCss,
  };
})();
