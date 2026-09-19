// 视频上自绘字幕（#fushi-subtitle-overlay）的外观设置：字体、大小、字重、字间距、行高、对齐、
// 文字颜色、描边，以及底板的颜色 / 不透明度 / 圆角 / 内边距。
//
// 存储：chrome.storage.local.subtitleStyle = 一个对象（部分字段也可缺省），字段名对齐 app 侧
// VideoSubtitleStyle（fontSize / fontWeight / textColor / shadow* / background*）。底板开关仍是
// 既有布尔键 subtitleOverlayBackground（旧用户设置不迁移）。
//
// 落地方式：content-css-overlay.css 里覆盖层的每一项外观都读 --fushi-sub-* 变量并给默认值；
// 这里把设置对象翻成「与默认不同的那几个变量」，subtitle-panel.js 逐个 setProperty 到覆盖层根，
// 默认值的变量 removeProperty 交还 CSS。options 页的实时预览走同一份 toCssVars。
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
  });
  var LIMITS = Object.freeze({
    fontScale: [50, 300],
    fontWeight: [100, 900],
    letterSpacing: [-5, 30],
    lineHeight: [100, 250],
    backgroundOpacity: [0, 100],
    borderRadius: [0, 32],
    padding: [0, 300],
  });
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
    var f = family.replace(/["'\\]/g, '').replace(/\s+/g, ' ').trim().slice(0, 100);
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
    SHADOWS: SHADOWS,
    FONT_SUGGESTIONS: FONT_SUGGESTIONS,
    DEFAULT_FONT_FAMILY: DEFAULT_FONT_FAMILY,
    DEFAULT_TEXT_COLOR: DEFAULT_TEXT_COLOR,
    DEFAULT_BACKGROUND_COLOR: DEFAULT_BACKGROUND_COLOR,
    normalize: normalize,
    isDefault: isDefault,
    toCssVars: toCssVars,
    applyTo: applyTo,
    fontStackLabel: fontStackLabel,
    fontFamilyValueOf: fontFamilyValueOf,
    matchesFushiFont: matchesFushiFont,
    fontFaceCss: fontFaceCss,
  };
})();
