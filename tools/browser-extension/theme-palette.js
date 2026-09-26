// 扩展主题的调色板引擎——与 Fushi 本体同一套主题模型（一个种子色派生明暗两套配色）。
//
// app 侧（theme_notifier.dart）：主题 = `system-theme` | 七款预设 | `custom-theme:<id>`，
// 每款只有一个种子色，浅色/深色两套 ColorScheme 都从它派生，明暗由独立的 brightness 决定。
// 这里镜像同一结构：
//   palette = 'fushi'（扩展默认绿，即 theme.css 里写死的那套）| 'app'（跟随 Fushi：直接用
//             查词响应镜像下来的 app 配色）| 预设 key（与 app 七款同名同种子）| 'custom:<id>'
//   customThemes = [{ id, name, seed, surface?, text?, neutral }]（与 app CustomThemeEntry
//             的 seed / surfaceColor / fontColor / neutralDerived 同义）
//   明暗仍由 theme.js 的 extensionTheme（auto / light / dark）决议。
//
// 派生走 OKLCH：theme.css 的默认调色板本来就是「固定明度/彩度阶梯 + 绿色相」，把色相换成种子
// 色的色相、彩度按种子缩放，就得到同一观感的另一款主题；surface 覆盖改整条表面阶梯的起点，
// text 覆盖改正文/次要文字色，neutral=true 让表面不带种子色调（对应 app 的灰色系预设）。
// 输出一律 hex / rgba 字符串：查词弹窗要的 --fushi-card-bg-rgb 需要裸 r, g, b，oklch() 串给不了。
//
// 纯函数、无 DOM、无 chrome.*：theme.js（决议与落地）、options.js（编辑器预览）、测试共用。
(function () {
  'use strict';
  var g = (typeof window !== 'undefined') ? window : ((typeof self !== 'undefined') ? self : null);
  if (!g) return;

  // ── 颜色空间 ──────────────────────────────────────────────────────────────
  function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }

  function parseHex(hex) {
    if (typeof hex !== 'string') return null;
    var m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
    if (!m) {
      var s = /^#?([0-9a-f]{3})$/i.exec(hex.trim());
      if (!s) return null;
      m = [null, s[1][0] + s[1][0] + s[1][1] + s[1][1] + s[1][2] + s[1][2]];
    }
    var n = parseInt(m[1], 16);
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
  }

  // app 侧 `popup_theme_css.dart` 的 cssRgb() 下发的是 `rgb(r, g, b)`（BUG-688 起 content.css /
  // popup.css 直接读 --text-color / --background-color），「跟随 Fushi」镜像里没有一个是 hex；
  // 这里兼收 `#hex` / `rgb()` / `rgba()`（alpha 忽略，token 只描述不透明表面）。
  function parseCssColor(v) {
    var c = parseHex(v);
    if (c) return c;
    if (typeof v !== 'string') return null;
    var m = /^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*[\d.]+\s*)?\)$/i.exec(v.trim());
    if (!m) return null;
    var r = +m[1], gg = +m[2], b = +m[3];
    if (r > 255 || gg > 255 || b > 255) return null;
    return { r: r, g: gg, b: b };
  }

  function toHex(rgb) {
    function h(v) { var s = Math.round(clamp01(v / 255) * 255).toString(16); return s.length < 2 ? '0' + s : s; }
    return '#' + h(rgb.r) + h(rgb.g) + h(rgb.b);
  }

  function srgbToLinear(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  function linearToSrgb(c) { c = clamp01(c); return 255 * (c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055); }

  // sRGB → OKLCH（Björn Ottosson 的 OKLab 公式）。
  function rgbToOklch(rgb) {
    var r = srgbToLinear(rgb.r), gg = srgbToLinear(rgb.g), b = srgbToLinear(rgb.b);
    var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * gg + 0.0514459929 * b);
    var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * gg + 0.1073969566 * b);
    var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * gg + 0.6299787005 * b);
    var L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
    var A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    var B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    var C = Math.sqrt(A * A + B * B);
    var h = C < 1e-6 ? 0 : (Math.atan2(B, A) * 180 / Math.PI + 360) % 360;
    return { L: L, C: C, h: h };
  }

  function oklchToRgbRaw(L, C, h) {
    var rad = h * Math.PI / 180;
    var A = C * Math.cos(rad), B = C * Math.sin(rad);
    var l_ = L + 0.3963377774 * A + 0.2158037573 * B;
    var m_ = L - 0.1055613458 * A - 0.0638541728 * B;
    var s_ = L - 0.0894841775 * A - 1.2914855480 * B;
    var l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return {
      r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
  }

  function inGamut(c) { return c.r >= -0.0005 && c.r <= 1.0005 && c.g >= -0.0005 && c.g <= 1.0005 && c.b >= -0.0005 && c.b <= 1.0005; }

  // OKLCH → sRGB，超出色域时沿彩度轴收敛（保明度与色相，与浏览器 oklch() 的裁剪取向一致）。
  function oklchToRgb(L, C, h) {
    L = clamp01(L);
    var lin = oklchToRgbRaw(L, C, h);
    if (!inGamut(lin)) {
      var lo = 0, hi = C;
      for (var i = 0; i < 18; i++) {
        var mid = (lo + hi) / 2;
        if (inGamut(oklchToRgbRaw(L, mid, h))) lo = mid; else hi = mid;
      }
      lin = oklchToRgbRaw(L, lo, h);
    }
    return { r: linearToSrgb(lin.r), g: linearToSrgb(lin.g), b: linearToSrgb(lin.b) };
  }

  function oklchHex(L, C, h) { return toHex(oklchToRgb(L, C, h)); }
  function rgbTriple(hex) { var c = parseHex(hex); return c ? (c.r + ', ' + c.g + ', ' + c.b) : '0, 0, 0'; }
  function rgba(hex, a) { var c = parseHex(hex); return c ? ('rgba(' + c.r + ', ' + c.g + ', ' + c.b + ', ' + a + ')') : 'transparent'; }

  // ── 预设（与 app theme_notifier.dart themePresets 同名同种子）────────────────
  // brightness 是预设的「出厂明暗」（app 未显式选 brightness 时的回落值）；这里同义：选预设
  // 时 options 页把它写进 extensionTheme。'fushi' 是扩展自己的默认绿（theme.css 原样），无
  // 出厂明暗（跟随系统）。
  var FUSHI_SEED = '#3f7a5a'; // oklch(0.46 0.085 155)：theme.css 浅色 --fushi-primary 的 hex
  var PRESETS = [
    { key: 'fushi', seed: FUSHI_SEED, brightness: null, neutral: false, labelKey: 'theme_preset_fushi' },
    { key: 'light-theme', seed: '#1f4959', brightness: 'light', neutral: false, labelKey: 'theme_preset_light' },
    { key: 'ecru-theme', seed: '#8b7355', brightness: 'light', neutral: false, labelKey: 'theme_preset_ecru' },
    { key: 'water-theme', seed: '#3a6ea5', brightness: 'light', neutral: false, labelKey: 'theme_preset_water' },
    { key: 'eyecare-theme', seed: '#5e8c63', brightness: 'light', neutral: false, labelKey: 'theme_preset_eyecare' },
    { key: 'gray-theme', seed: '#5c6b73', brightness: 'dark', neutral: true, labelKey: 'theme_preset_gray' },
    { key: 'dark-theme', seed: '#1f4959', brightness: 'dark', neutral: false, labelKey: 'theme_preset_dark' },
    { key: 'black-theme', seed: '#3f51b5', brightness: 'dark', neutral: true, surface: '#000000', labelKey: 'theme_preset_black' },
  ];
  var PRESET_BY_KEY = Object.create(null);
  for (var pi = 0; pi < PRESETS.length; pi++) PRESET_BY_KEY[PRESETS[pi].key] = PRESETS[pi];

  var DEFAULT_SEED = '#1f4959'; // app kCustomThemeDefaultSeed

  // ── 自定义主题条目 ───────────────────────────────────────────────────────
  function normalizeHexOrNull(v) { var c = parseCssColor(v); return c ? toHex(c) : null; }

  function normalizeCustomTheme(v) {
    if (!v || typeof v !== 'object') return null;
    var id = typeof v.id === 'string' ? v.id.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 40) : '';
    if (!id) return null;
    var name = typeof v.name === 'string' ? v.name.trim().slice(0, 40) : '';
    var out = {
      id: id,
      name: name,
      seed: normalizeHexOrNull(v.seed) || DEFAULT_SEED,
      surface: normalizeHexOrNull(v.surface),
      text: normalizeHexOrNull(v.text),
      neutral: v.neutral === true,
    };
    return out;
  }

  function normalizeCustomThemes(list) {
    if (!Array.isArray(list)) return [];
    var out = [], seen = Object.create(null);
    for (var i = 0; i < list.length; i++) {
      var t = normalizeCustomTheme(list[i]);
      if (!t || seen[t.id]) continue;
      seen[t.id] = true;
      out.push(t);
    }
    return out;
  }

  function newThemeId() {
    return 't' + Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36);
  }

  // 'fushi' / 'app' / 预设 key / 'custom:<id>'；坏值回 'fushi'。
  function normalizePaletteId(v) {
    if (typeof v !== 'string') return 'fushi';
    if (v === 'app' || PRESET_BY_KEY[v]) return v;
    if (/^custom:[A-Za-z0-9_-]{1,40}$/.test(v)) return v;
    return 'fushi';
  }

  // 把 palette id 解析成规格 {seed, surface, text, neutral}；'app' 与找不到的自定义 id 回 null
  // （调用方按 'fushi' 兜底——app 镜像另走 appTokens）。
  function specFor(paletteId, customThemes) {
    var id = normalizePaletteId(paletteId);
    if (id === 'app') return null;
    if (id.indexOf('custom:') === 0) {
      var want = id.slice(7);
      var list = normalizeCustomThemes(customThemes);
      for (var i = 0; i < list.length; i++) if (list[i].id === want) return list[i];
      return null;
    }
    var p = PRESET_BY_KEY[id];
    return { seed: p.seed, surface: p.surface || null, text: null, neutral: p.neutral };
  }

  // ── 派生 ─────────────────────────────────────────────────────────────────
  // 阶梯照抄 theme.css（浅色 :root / 深色块）的 L/C；色相换成种子，彩度按种子缩放。
  function derive(spec, scheme) {
    var dark = scheme === 'dark';
    var seed = rgbToOklch(parseHex(spec && spec.seed) || parseHex(DEFAULT_SEED));
    var h = seed.h;
    // 主色彩度：theme.css 是 .085（浅）/.085（深），种子彩度太低（灰）就跟着低，太高夹到可读范围。
    var pc = Math.min(0.16, Math.max(0.02, seed.C));
    var neutralScale = spec && spec.neutral ? 0 : Math.min(1, pc / 0.085);
    function nC(base) { return base * neutralScale; }

    // 表面阶梯：默认起点浅 .965 / 深 .18；surface 覆盖给起点与色相。
    var surfaceL = dark ? 0.18 : 0.965, sh = h, sC = nC(dark ? 0.018 : 0.012);
    var sOverride = spec && spec.surface ? rgbToOklch(parseHex(spec.surface)) : null;
    if (sOverride) {
      surfaceL = sOverride.L;
      // 覆盖色的明暗与当前 scheme 冲突（用户给了白底却在深色模式）时，把它折到本模式的合理区间。
      if (dark && surfaceL > 0.5) surfaceL = 1 - surfaceL;
      if (!dark && surfaceL < 0.5) surfaceL = 1 - surfaceL;
      if (dark) surfaceL = Math.min(0.32, surfaceL); else surfaceL = Math.max(0.82, surfaceL);
      sh = sOverride.h;
      sC = Math.min(0.06, sOverride.C);
    }
    var bg, surface, muted, strong;
    if (dark) {
      // 纯黑起点（black-theme / 用户给 #000）：底保持全黑，卡片阶梯从可辨的近黑起，否则
      // 0 + 0.045 在 OKLCH 里仍是肉眼全黑，卡片与页面糊成一片。
      var ladder = Math.max(surfaceL, 0.1);
      bg = surfaceL; surface = ladder + 0.045; muted = ladder + 0.09; strong = ladder + 0.13;
    } else {
      bg = surfaceL; surface = Math.min(0.995, surfaceL + 0.025); muted = surfaceL - 0.03; strong = surfaceL - 0.065;
    }

    // 文字：默认 theme.css 的 .245/.91；text 覆盖给色相与（夹住的）明度。
    var textL = dark ? 0.91 : 0.245, th = h, tC = nC(dark ? 0.018 : 0.026);
    var tOverride = spec && spec.text ? rgbToOklch(parseHex(spec.text)) : null;
    if (tOverride) {
      textL = tOverride.L;
      if (dark && textL < 0.5) textL = 1 - textL;
      if (!dark && textL > 0.5) textL = 1 - textL;
      if (dark) textL = Math.max(0.78, textL); else textL = Math.min(0.36, textL);
      th = tOverride.h;
      tC = Math.min(0.08, tOverride.C);
    }
    var mutedL = dark ? 0.72 : 0.47;
    var outlineL = dark ? 0.39 : 0.79;

    var primary = dark ? oklchHex(0.78, Math.min(pc, 0.12), h) : oklchHex(0.46, pc, h);
    var primarySoft = dark ? oklchHex(0.31, Math.min(0.065, pc * 0.8), h) : oklchHex(0.89, Math.min(0.055, pc * 0.65), h);
    var tokens = {
      '--fushi-bg': oklchHex(bg, sC, sh),
      '--fushi-surface': oklchHex(surface, sC * 0.7, sh),
      '--fushi-surface-muted': oklchHex(muted, sC * 1.4, sh),
      '--fushi-surface-strong': oklchHex(strong, sC * 1.6, sh),
      '--fushi-text': oklchHex(textL, tC, th),
      '--fushi-muted': oklchHex(mutedL, Math.min(tC, 0.025), th),
      '--fushi-outline': oklchHex(outlineL, nC(0.025), sh),
      '--fushi-primary': primary,
      '--fushi-primary-strong': dark ? oklchHex(0.84, Math.min(pc, 0.1), h) : oklchHex(0.37, pc, h),
      '--fushi-primary-soft': primarySoft,
      '--fushi-on-primary': dark ? oklchHex(0.19, Math.min(0.03, pc), h) : oklchHex(0.985, 0.008, h),
      '--fushi-focus': dark ? oklchHex(0.78, Math.min(0.11, pc), h) : oklchHex(0.61, Math.min(0.13, pc * 1.3), h),
      // 警示/危险色不跟主题色相走（红黄语义固定），与 theme.css 同值。
      '--fushi-warn': dark ? oklchHex(0.77, 0.12, 78) : oklchHex(0.62, 0.135, 78),
      '--fushi-danger': dark ? oklchHex(0.72, 0.15, 28) : oklchHex(0.55, 0.18, 28),
    };
    return tokens;
  }

  // 「跟随 Fushi」：查词响应镜像的 app 配色（background.js 落 storage appThemeMirror[scheme]），
  // 映射到 --fushi-* 表面阶梯。缺项回 null（调用方回 'fushi' 默认）。
  function tokensFromAppTheme(mirror) {
    if (!mirror || typeof mirror !== 'object') return null;
    var surface = normalizeHexOrNull(mirror['--background-color']);
    var text = normalizeHexOrNull(mirror['--text-color'] || mirror['--md-on-surface']);
    var primary = normalizeHexOrNull(mirror['--md-primary']);
    if (!surface || !text || !primary) return null;
    var sc = normalizeHexOrNull(mirror['--md-surface-container']) || surface;
    var sch = normalizeHexOrNull(mirror['--md-surface-container-high']) || sc;
    var mutedText = normalizeHexOrNull(mirror['--md-on-surface-variant']) || text;
    var outline = normalizeHexOrNull(mirror['--md-outline-variant']) || mutedText;
    var onPrimary = normalizeHexOrNull(mirror['--md-on-primary']) || surface;
    var p = rgbToOklch(parseHex(primary));
    var dark = rgbToOklch(parseHex(surface)).L < 0.5;
    return {
      '--fushi-bg': sc,
      '--fushi-surface': surface,
      '--fushi-surface-muted': sc,
      '--fushi-surface-strong': sch,
      '--fushi-text': text,
      '--fushi-muted': mutedText,
      '--fushi-outline': outline,
      '--fushi-primary': primary,
      '--fushi-primary-strong': oklchHex(dark ? Math.min(0.95, p.L + 0.06) : Math.max(0.2, p.L - 0.09), p.C, p.h),
      '--fushi-primary-soft': oklchHex(dark ? 0.31 : 0.89, Math.min(0.065, p.C * 0.7), p.h),
      '--fushi-on-primary': onPrimary,
      '--fushi-focus': primary,
      '--fushi-warn': dark ? oklchHex(0.77, 0.12, 78) : oklchHex(0.62, 0.135, 78),
      '--fushi-danger': dark ? oklchHex(0.72, 0.15, 28) : oklchHex(0.55, 0.18, 28),
    };
  }

  // 查词弹窗（popup.css 吃 app 下发的 --md-* / --text-color / --background-color）在非「跟随
  // Fushi」调色板下要按扩展主题重着色，否则设置页/侧边栏一款、弹窗另一款又是主题分裂。
  // 键名与 app_model.dart browserExtensionThemeColors 完全一致，只覆盖颜色项。
  function popupVarsFromTokens(tokens) {
    if (!tokens) return null;
    var primary = tokens['--fushi-primary'];
    return {
      '--text-color': tokens['--fushi-text'],
      '--background-color': tokens['--fushi-surface'],
      '--fushi-card-bg-rgb': rgbTriple(tokens['--fushi-surface']),
      '--fushi-primary-highlight': rgba(primary, 0.35),
      '--md-surface-container': tokens['--fushi-surface-muted'],
      '--md-surface-container-high': tokens['--fushi-surface-strong'],
      '--md-on-surface': tokens['--fushi-text'],
      '--md-on-surface-variant': tokens['--fushi-muted'],
      '--md-outline-variant': tokens['--fushi-outline'],
      '--md-primary': primary,
      '--md-on-primary': tokens['--fushi-on-primary'],
    };
  }

  var TOKEN_NAMES = Object.keys(derive({ seed: FUSHI_SEED }, 'light'));

  g.fushiThemePalette = {
    PRESETS: PRESETS,
    DEFAULT_SEED: DEFAULT_SEED,
    TOKEN_NAMES: TOKEN_NAMES,
    parseHex: parseHex,
    parseCssColor: parseCssColor,
    toHex: toHex,
    rgbToOklch: rgbToOklch,
    oklchHex: oklchHex,
    normalizePaletteId: normalizePaletteId,
    normalizeCustomTheme: normalizeCustomTheme,
    normalizeCustomThemes: normalizeCustomThemes,
    newThemeId: newThemeId,
    presetFor: function (key) { return PRESET_BY_KEY[key] || null; },
    specFor: specFor,
    derive: derive,
    tokensFromAppTheme: tokensFromAppTheme,
    popupVarsFromTokens: popupVarsFromTokens,
  };
})();
