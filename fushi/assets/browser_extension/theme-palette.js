// 扩展主题的调色板引擎——与 Fushi 本体**同一套算法**（种子色 → M3 动态配色方案）。
//
// app 侧（theme_notifier.dart buildFushiColorScheme）：主题 = `system-theme` | M3 经典预设（m3-*）|
// `custom-theme:<id>`；每款只有一个种子色 + 一个 DynamicScheme 变体，浅色 / 深色两套 ColorScheme
// 都从它派生，明暗由独立的明暗设置决定；「纯黑深色背景」是明暗旁的独立开关。之后统一过一道
// Fushi 表面阶梯（applyFushiSurfaceLadder / applyFushiPureBlackSurfaceLadder）。
//
// 这里逐步照搬同一条流水线：material-color.js（material_color_utilities 0.13.0 的 JS 移植，Flutter
// ColorScheme.fromSeed 用的就是这一版）出 DynamicScheme 角色 → 中性派生 / 无彩度种子 → 表面阶梯
// （同一份 tone 表、同一个 hctToneKeepingHue）→ 角色映射成扩展的 --fushi-* token。所以扩展与 app
// 选同一个预设，颜色逐位相同（theme-palette.test.js 用 app 真值钉）。
//
//   palette = 'app'（跟随 Fushi：直接用查词响应镜像下来的 app 配色）| 预设 key（m3-*，与 app 同名同
//             种子同变体）| 'custom:<id>'
//   旧扩展预设 id（'fushi' / 'light-theme' / … / 'black-theme'）只读映射到最接近的新预设（与 app
//   legacyPresetReplacement 同一规则：中性 → m3-neutral，其余按种子 HCT 色相最近），**不改写存储**；
//   旧 'black-theme' 的纯黑语义由 theme.js 的 extensionPureBlack 缺省值继承。
//   customThemes = [{ id, name, seed, surface?, text?, neutral }]
//
// 纯函数、无 DOM、无 chrome.*：theme.js（决议与落地）、options.js（编辑器预览）、测试共用。
// 依赖 material-color.js 先装入（manifest / 各页面 <script> 顺序保证；测试同序）。
(function () {
  'use strict';
  var g = (typeof window !== 'undefined') ? window : ((typeof self !== 'undefined') ? self : null);
  if (!g) return;
  var MC = g.fushiMaterialColor || null;

  // ── 颜色工具 ──────────────────────────────────────────────────────────────
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

  // app 侧 `popup_theme_css.dart` 的 cssRgb() 下发的是 `rgb(r, g, b)`；这里兼收 `#hex` / `rgb()` /
  // `rgba()`（alpha 忽略，token 只描述不透明表面）。
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

  // sRGB → OKLCH（只给测试 / 编辑器读明度用；派生本身走 HCT）。
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

  function rgbTriple(hex) { var c = parseHex(hex); return c ? (c.r + ', ' + c.g + ', ' + c.b) : '0, 0, 0'; }
  function rgba(hex, a) { var c = parseHex(hex); return c ? ('rgba(' + c.r + ', ' + c.g + ', ' + c.b + ', ' + a + ')') : 'transparent'; }

  // ARGB int ↔ 通道（与 Flutter Color 同口径：不透明，通道 0..255）。
  function argbOf(rgb) { return ((255 << 24) | (rgb.r << 16) | (rgb.g << 8) | rgb.b) >>> 0; }
  function rgbOfArgb(argb) { return { r: (argb >>> 16) & 255, g: (argb >>> 8) & 255, b: argb & 255 }; }
  function hexOfArgb(argb) { return toHex(rgbOfArgb(argb)); }
  function argbOfHex(hex) { var c = parseCssColor(hex); return c ? argbOf(c) : null; }
  var WHITE = 0xffffffff, BLACK = 0xff000000;

  // Flutter Color.computeLuminance（WCAG 相对亮度）。
  function luminance(argb) {
    function lin(c) { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
    var c = rgbOfArgb(argb);
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
  }
  // Flutter ThemeData.estimateBrightnessForColor：true = 深色。
  function isDarkColor(argb) {
    var l = luminance(argb);
    return !((l + 0.05) * (l + 0.05) > 0.15);
  }
  // theme_notifier.dart _readableOnColor。
  function readableOn(argb) {
    var l = luminance(argb);
    return (1.05 / (l + 0.05)) >= ((l + 0.05) / 0.05) ? WHITE : BLACK;
  }
  // Flutter Color.lerp（不透明两色，按通道线性插值后取整）。
  function lerpArgb(a, b, t) {
    var x = rgbOfArgb(a), y = rgbOfArgb(b);
    return argbOf({
      r: Math.round(x.r + (y.r - x.r) * t),
      g: Math.round(x.g + (y.g - x.g) * t),
      b: Math.round(x.b + (y.b - x.b) * t),
    });
  }
  // 半透明前景（如 0xDE 黑字）合成到底色上：token 只能是不透明 hex。
  function compositeAlpha(fg, alpha, bg) { return lerpArgb(bg, fg, alpha / 255); }

  function hct(argb) { return MC.Hct.fromInt(argb); }
  function hctArgb(h, c, t) { return MC.Hct.from(h, c, t).toInt() >>> 0; }

  // theme_notifier.dart isAchromaticSeed：HCT 彩度 < 4 的种子没有色相可言。
  function isAchromatic(argb) { return hct(argb).chroma < 4; }

  // theme_notifier.dart hctToneKeepingHue：按色相 / 彩度 / 色调取色，但不许色相漂移。
  function hctToneKeepingHue(hue, chroma, tone) {
    var gray = hctArgb(hue, 0, tone);
    var grayChroma = hct(gray).chroma;
    if (chroma <= grayChroma + 0.5) return hctArgb(hue, chroma, tone);
    var c = chroma;
    while (c > grayChroma) {
      var argb = hctArgb(hue, c, tone);
      var back = hct(argb);
      var d = Math.abs(back.hue - hue) % 360;
      var hueDistance = d > 180 ? 360 - d : d;
      if (hueDistance <= 10 && back.chroma <= chroma + 1.5) return argb;
      c /= 2;
    }
    return gray;
  }

  // ── 表面阶梯（theme_notifier.dart 同名常量，逐值相同）─────────────────────
  // 顺序：containerLowest / surface / containerLow / container / containerHigh / containerHighest。
  var LIGHT_SURFACE_TONES = [100, 99.5, 96.5, 93.5, 90.5, 87];
  var DARK_SURFACE_TONES = [3, 5, 9.5, 14, 19, 24];
  var PURE_BLACK_SURFACE_TONES = [0, 0, 4.5, 9, 14, 19];

  function applyLadder(s, dark, pureBlack) {
    var black = dark && pureBlack;
    var tones = black ? PURE_BLACK_SURFACE_TONES : (dark ? DARK_SURFACE_TONES : LIGHT_SURFACE_TONES);
    var anchor = hct(s.surfaceContainer);
    function at(t) { return hctToneKeepingHue(anchor.hue, anchor.chroma, t); }
    s.surfaceContainerLowest = at(tones[0]);
    s.surface = at(tones[1]);
    s.surfaceContainerLow = at(tones[2]);
    s.surfaceContainer = at(tones[3]);
    s.surfaceContainerHigh = at(tones[4]);
    s.surfaceContainerHighest = at(tones[5]);
    if (black) {
      s.surfaceBright = at(24);
      s.surfaceDim = at(0);
    } else {
      s.surfaceBright = at(dark ? 26 : tones[1]);
      s.surfaceDim = at(dark ? 4 : 85);
    }
    return s;
  }

  // theme_notifier.dart deriveSurfaceRolesFrom：用户钉死的底色推出整套中性角色。
  function surfaceRolesFrom(surface) {
    var dark = isDarkColor(surface);
    var contrast = dark ? WHITE : BLACK;
    function step(t) { return lerpArgb(surface, contrast, t); }
    var anchor = hct(surface);
    function tone(delta) {
      var t = anchor.tone + (dark ? delta : -delta);
      t = t < 0 ? 0 : (t > 100 ? 100 : t);
      return hctArgb(anchor.hue, anchor.chroma, t);
    }
    return {
      surface: surface,
      surfaceDim: dark ? tone(-1) : tone(14.5),
      surfaceBright: surface,
      surfaceContainerLowest: surface,
      surfaceContainerLow: tone(dark ? 4.5 : 3),
      surfaceContainer: tone(dark ? 9 : 6),
      surfaceContainerHigh: tone(dark ? 14 : 9),
      surfaceContainerHighest: tone(dark ? 19 : 12.5),
      // app 用 0xDE / 0x99 半透明黑白；token 只能是不透明色，合成到底色上（视觉等价）。
      onSurface: compositeAlpha(contrast, 0xde, surface),
      onSurfaceVariant: compositeAlpha(contrast, 0x99, surface),
      outline: step(0.5),
      outlineVariant: step(0.2),
      inverseSurface: step(0.85),
      onInverseSurface: surface,
    };
  }

  // 用户钉的底色 / 文字色与当前明暗冲突（白底却在深色模式）时，同色相彩度折到对侧色调。
  // app 的自定义底色不分明暗；扩展自定义主题沿用旧行为：两套明暗都要能用。
  function foldTone(argb, wantDark, lo, hi) {
    var h = hct(argb);
    var t = h.tone;
    if (wantDark && t > 50) t = 100 - t;
    if (!wantDark && t < 50) t = 100 - t;
    t = Math.max(lo, Math.min(hi, t));
    return Math.abs(t - h.tone) < 0.01 ? argb : hctArgb(h.hue, h.chroma, t);
  }

  // ── 预设（与 app theme_notifier.dart themePresets 同名同种子同变体，顺序按色相）──────────
  var PRESETS = [
    { key: 'm3-baseline', seed: '#6750a4', variant: 'vibrant', labelKey: 'theme_preset_baseline' },
    { key: 'm3-indigo', seed: '#3f51b5', variant: 'vibrant', labelKey: 'theme_preset_indigo' },
    { key: 'm3-blue', seed: '#0b57d0', variant: 'vibrant', labelKey: 'theme_preset_blue' },
    { key: 'm3-teal', seed: '#00796b', variant: 'vibrant', labelKey: 'theme_preset_teal' },
    { key: 'm3-green', seed: '#146c2e', variant: 'vibrant', labelKey: 'theme_preset_green' },
    { key: 'm3-yellow', seed: '#fbbc04', variant: 'vibrant', labelKey: 'theme_preset_yellow' },
    { key: 'm3-orange', seed: '#ff6d00', variant: 'vibrant', labelKey: 'theme_preset_orange' },
    { key: 'm3-red', seed: '#b3261e', variant: 'vibrant', labelKey: 'theme_preset_red' },
    { key: 'm3-pink', seed: '#e91e63', variant: 'vibrant', labelKey: 'theme_preset_pink' },
    { key: 'm3-neutral', seed: '#5f6368', variant: 'neutral', labelKey: 'theme_preset_neutral' },
  ];
  var PRESET_BY_KEY = Object.create(null);
  for (var pi = 0; pi < PRESETS.length; pi++) PRESET_BY_KEY[PRESETS[pi].key] = PRESETS[pi];
  var NEUTRAL_PRESET = 'm3-neutral';
  // app kFushiDefaultSchemeVariant。
  var DEFAULT_VARIANT = 'vibrant';

  // 旧扩展预设（2026-10 前与 app 七款同名同种子，外加扩展自己的 'fushi' 绿）：种子 + 是否中性 +
  // 是否纯黑。只读映射，见 legacyReplacement。
  var LEGACY_PRESETS = {
    'fushi': { seed: '#3f7a5a', neutral: false, pureBlack: false },
    'light-theme': { seed: '#1f4959', neutral: false, pureBlack: false },
    'ecru-theme': { seed: '#8b7355', neutral: false, pureBlack: false },
    'water-theme': { seed: '#3a6ea5', neutral: false, pureBlack: false },
    'eyecare-theme': { seed: '#5e8c63', neutral: false, pureBlack: false },
    'gray-theme': { seed: '#5c6b73', neutral: true, pureBlack: false },
    'dark-theme': { seed: '#1f4959', neutral: false, pureBlack: false },
    'black-theme': { seed: '#3f51b5', neutral: false, pureBlack: true },
  };
  // 映射结果的静态表（与 app ThemeNotifier.legacyPresetReplacement 同一规则算出，
  // theme-palette.test.js 用 nearestPresetForSeed 复算钉住）；material-color.js 缺席时也能用。
  var LEGACY_REPLACEMENT = {
    'fushi': 'm3-green',
    'light-theme': 'm3-blue',
    'ecru-theme': 'm3-yellow',
    'water-theme': 'm3-blue',
    'eyecare-theme': 'm3-green',
    'gray-theme': 'm3-neutral',
    'dark-theme': 'm3-blue',
    'black-theme': 'm3-indigo',
  };

  // app ThemeNotifier.nearestPresetForSeed：与种子 HCT 色相环形距离最近的彩色预设（不含中性）。
  function nearestPresetForSeed(seedHex) {
    var hue = hct(argbOfHex(seedHex)).hue;
    var best = 'm3-baseline', bestDistance = Infinity;
    for (var i = 0; i < PRESETS.length; i++) {
      var p = PRESETS[i];
      if (p.variant === 'neutral') continue;
      var d = Math.abs(hue - hct(argbOfHex(p.seed)).hue) % 360;
      var distance = d > 180 ? 360 - d : d;
      if (distance < bestDistance) { bestDistance = distance; best = p.key; }
    }
    return best;
  }

  function legacyReplacement(key) {
    var legacy = LEGACY_PRESETS[key];
    if (!legacy) return null;
    return LEGACY_REPLACEMENT[key] || (legacy.neutral ? NEUTRAL_PRESET : 'm3-baseline');
  }

  var DEFAULT_SEED = '#1f4959'; // app kCustomThemeDefaultSeed / kFushiDefaultSeed

  // ── 自定义主题条目 ───────────────────────────────────────────────────────
  function normalizeHexOrNull(v) { var c = parseCssColor(v); return c ? toHex(c) : null; }

  function normalizeCustomTheme(v) {
    if (!v || typeof v !== 'object') return null;
    var id = typeof v.id === 'string' ? v.id.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 40) : '';
    if (!id) return null;
    var name = typeof v.name === 'string' ? v.name.trim().slice(0, 40) : '';
    return {
      id: id,
      name: name,
      seed: normalizeHexOrNull(v.seed) || DEFAULT_SEED,
      surface: normalizeHexOrNull(v.surface),
      text: normalizeHexOrNull(v.text),
      neutral: v.neutral === true,
    };
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

  // 'app' / 预设 key / 'custom:<id>'；旧预设 id 映射到新预设；缺省与坏值回 'app'（跟随 Fushi）。
  var DEFAULT_PALETTE = 'app';
  function normalizePaletteId(v) {
    if (typeof v !== 'string') return DEFAULT_PALETTE;
    if (v === 'app' || PRESET_BY_KEY[v]) return v;
    var legacy = legacyReplacement(v);
    if (legacy) return legacy;
    if (/^custom:[A-Za-z0-9_-]{1,40}$/.test(v)) return v;
    return DEFAULT_PALETTE;
  }

  // palette id → 规格 {seed, variant, surface, text, neutral}；'app' 与找不到的自定义 id 回 null。
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
    return { seed: p.seed, variant: p.variant, surface: null, text: null, neutral: false };
  }

  // ── 派生：种子 → ColorScheme（app buildFushiColorScheme 的同一条流水线）────────────────
  // spec = { seed, variant?, surface?, text?, neutral? }；opts = { pureBlack }。
  // 返回 Flutter ColorScheme 同名角色 → ARGB。
  function schemeFor(spec, scheme, opts) {
    var dark = scheme === 'dark';
    var pureBlack = !!(opts && opts.pureBlack);
    var seed = argbOfHex(spec && spec.seed) || argbOfHex(DEFAULT_SEED);
    var variant = (spec && typeof spec.variant === 'string' && MC.VARIANTS.indexOf(spec.variant) >= 0)
      ? spec.variant : DEFAULT_VARIANT;
    var achromatic = isAchromatic(seed);
    // app 的系统取色（buildSystemThemeColorScheme）直接 fromSeed，不走无彩度中性派生。
    var neutral = !!(spec && spec.neutral) || (achromatic && !(spec && spec.systemAccent));
    var s = MC.schemeFromSeed(seed, dark, neutral ? 'monochrome' : variant, 0);
    var out = {};
    for (var k in s) out[k] = s[k] >>> 0;
    if (neutral) {
      // 中性派生下主色相关角色仍来自种子自己的调色板（monochrome 会把 primary 也压成灰）；无彩度
      // 种子 + vibrant 用 tonalSpot（vibrant 会把噪声色相拉成满彩度蓝）。
      var accentBase = MC.schemeFromSeed(seed, dark,
        (achromatic && variant === 'vibrant') ? 'tonalSpot' : variant, 0);
      var accent = accentBase.primary >>> 0;
      var container = accentBase.primaryContainer >>> 0;
      out.primary = accent;
      out.onPrimary = readableOn(accent);
      var ph = hct(accent);
      out.inversePrimary = hctArgb(ph.hue, ph.chroma, dark ? 40 : 80);
      out.primaryContainer = container;
      out.onPrimaryContainer = readableOn(container);
    }
    var surface = spec && spec.surface ? argbOfHex(spec.surface) : null;
    if (surface != null) {
      surface = foldTone(surface, dark, dark ? 0 : 82, dark ? 32 : 100);
      var roles = surfaceRolesFrom(surface);
      for (var r in roles) out[r] = roles[r];
    } else {
      applyLadder(out, dark, pureBlack);
    }
    var text = spec && spec.text ? argbOfHex(spec.text) : null;
    if (text != null) out.onSurface = foldTone(text, !dark, dark ? 78 : 0, dark ? 100 : 36);
    return out;
  }

  // ColorScheme 角色 → 扩展 --fushi-* token。theme.css ② 把 --md-sys-color-* 别名到这些 token，
  // 映射与 app 的 FushiSurfaceColors 同一口径：页面底 = surface，卡片 = containerLowest，
  // 分组 = containerLow，muted = container，strong = containerHighest。
  function tokensFromRoles(s, dark) {
    function hx(k) { return hexOfArgb(s[k]); }
    var p = hct(s.primary);
    return {
      '--fushi-bg': hx('surface'),
      '--fushi-surface': hx('surfaceContainerLowest'),
      '--fushi-surface-low': hx('surfaceContainerLow'),
      '--fushi-surface-muted': hx('surfaceContainer'),
      '--fushi-surface-high': hx('surfaceContainerHigh'),
      '--fushi-surface-strong': hx('surfaceContainerHighest'),
      '--fushi-text': hx('onSurface'),
      '--fushi-muted': hx('onSurfaceVariant'),
      '--fushi-outline': hx('outlineVariant'),
      '--fushi-outline-strong': hx('outline'),
      '--fushi-primary': hx('primary'),
      // 悬停 / 按压时的主色加深（浅色更暗、深色更亮），同色相彩度。
      '--fushi-primary-strong': hexOfArgb(hctArgb(p.hue, p.chroma, dark ? Math.min(100, p.tone + 8) : Math.max(0, p.tone - 8))),
      '--fushi-primary-soft': hx('primaryContainer'),
      '--fushi-on-primary': hx('onPrimary'),
      '--fushi-on-primary-soft': hx('onPrimaryContainer'),
      '--fushi-secondary': hx('secondary'),
      '--fushi-on-secondary': hx('onSecondary'),
      '--fushi-secondary-soft': hx('secondaryContainer'),
      '--fushi-on-secondary-soft': hx('onSecondaryContainer'),
      '--fushi-tertiary': hx('tertiary'),
      '--fushi-on-tertiary': hx('onTertiary'),
      '--fushi-tertiary-soft': hx('tertiaryContainer'),
      '--fushi-on-tertiary-soft': hx('onTertiaryContainer'),
      '--fushi-inverse-surface': hx('inverseSurface'),
      '--fushi-inverse-on-surface': hx('onInverseSurface'),
      '--fushi-inverse-primary': hx('inversePrimary'),
      '--fushi-focus': hx('primary'),
      // 警示色不跟主题色相走（黄色语义固定，M3 没有 warning 角色），与 theme.css 同值。
      '--fushi-warn': dark ? '#deaa54' : '#b07a00',
      '--fushi-danger': hx('error'),
      '--fushi-on-danger': hx('onError'),
      '--fushi-danger-soft': hx('errorContainer'),
      '--fushi-on-danger-soft': hx('onErrorContainer'),
    };
  }

  function derive(spec, scheme, opts) {
    var dark = scheme === 'dark';
    return tokensFromRoles(schemeFor(spec, dark ? 'dark' : 'light', opts), dark);
  }

  // 「跟随 Fushi」：查词响应镜像的 app 配色（background.js 落 storage appThemeMirror[scheme]）——
  // 就是 app 当前 ColorScheme 的原值（含纯黑底、明暗、自定义角色），按同一映射落成 --fushi-*。
  // 旧 app 缺的角色键回落到同一份镜像里最接近的角色。缺核心键回 null。
  // scheme（'light' / 'dark'）= 这份镜像所属的明暗（镜像按明暗分槽存）；缺省按底色亮度判。
  function tokensFromAppTheme(mirror, scheme) {
    if (!mirror || typeof mirror !== 'object') return null;
    var card = normalizeHexOrNull(mirror['--background-color']);
    var text = normalizeHexOrNull(mirror['--md-on-surface'] || mirror['--text-color']);
    var primary = normalizeHexOrNull(mirror['--md-primary']);
    if (!card || !text || !primary) return null;
    function role(key, fallback) { return normalizeHexOrNull(mirror[key]) || fallback; }
    var sc = role('--md-surface-container', card);
    var sch = role('--md-surface-container-high', sc);
    var mutedText = role('--md-on-surface-variant', text);
    var outline = role('--md-outline-variant', mutedText);
    var onPrimary = role('--md-on-primary', card);
    var dark = scheme === 'dark' || (scheme !== 'light' && rgbToOklch(parseHex(card)).L < 0.5);
    var p = MC ? hct(argbOfHex(primary)) : null;
    var primaryStrong = p
      ? hexOfArgb(hctArgb(p.hue, p.chroma, dark ? Math.min(100, p.tone + 8) : Math.max(0, p.tone - 8)))
      : primary;
    var surface = role('--md-surface', card);
    var low = role('--md-surface-container-low', sc);
    return {
      '--fushi-bg': surface,
      '--fushi-surface': role('--md-surface-container-lowest', card),
      '--fushi-surface-low': low,
      '--fushi-surface-muted': sc,
      '--fushi-surface-high': sch,
      '--fushi-surface-strong': role('--md-surface-container-highest', sch),
      '--fushi-text': text,
      '--fushi-muted': mutedText,
      '--fushi-outline': outline,
      '--fushi-outline-strong': role('--md-outline', mutedText),
      '--fushi-primary': primary,
      '--fushi-primary-strong': primaryStrong,
      '--fushi-primary-soft': role('--md-primary-container', sch),
      '--fushi-on-primary': onPrimary,
      '--fushi-on-primary-soft': role('--md-on-primary-container', text),
      '--fushi-secondary': role('--md-secondary', primary),
      '--fushi-on-secondary': role('--md-on-secondary', onPrimary),
      '--fushi-secondary-soft': role('--md-secondary-container', sch),
      '--fushi-on-secondary-soft': role('--md-on-secondary-container', text),
      '--fushi-tertiary': role('--md-tertiary', primary),
      '--fushi-on-tertiary': role('--md-on-tertiary', onPrimary),
      '--fushi-tertiary-soft': role('--md-tertiary-container', sch),
      '--fushi-on-tertiary-soft': role('--md-on-tertiary-container', text),
      '--fushi-inverse-surface': role('--md-inverse-surface', text),
      '--fushi-inverse-on-surface': role('--md-inverse-on-surface', card),
      '--fushi-inverse-primary': role('--md-inverse-primary', primary),
      '--fushi-focus': primary,
      '--fushi-warn': dark ? '#deaa54' : '#b07a00',
      '--fushi-danger': role('--md-error', dark ? '#ffb4ab' : '#ba1a1a'),
      '--fushi-on-danger': role('--md-on-error', dark ? '#690005' : '#ffffff'),
      '--fushi-danger-soft': role('--md-error-container', dark ? '#93000a' : '#ffdad6'),
      '--fushi-on-danger-soft': role('--md-on-error-container', dark ? '#ffdad6' : '#410002'),
    };
  }

  // app 镜像里随 theme 下发的种子 / 变体 / 纯黑（app_model.dart browserExtensionThemeColors）：
  // app 只下发过一种明暗时，扩展按同一种子同一变体派生另一种明暗，与 app 切过去的结果一致。
  function specFromAppTheme(mirror) {
    if (!mirror || typeof mirror !== 'object') return null;
    var seed = normalizeHexOrNull(mirror['--fushi-theme-seed']);
    var fromPrimary = false;
    if (!seed) { seed = normalizeHexOrNull(mirror['--md-primary']); fromPrimary = true; }
    if (!seed) return null;
    var variant = mirror['--fushi-theme-variant'];
    return {
      spec: {
        seed: seed,
        variant: (typeof variant === 'string' && MC && MC.VARIANTS.indexOf(variant) >= 0) ? variant : DEFAULT_VARIANT,
        neutral: mirror['--fushi-theme-neutral'] === '1',
        systemAccent: mirror['--fushi-theme-system'] === '1',
      },
      pureBlack: mirror['--fushi-pure-black'] === '1',
      approximate: fromPrimary,
    };
  }

  // 查词弹窗（popup.css 吃 app 下发的 --md-* / --text-color / --background-color）在非「跟随
  // Fushi」调色板下要按扩展主题重着色。键名与 app_model.dart browserExtensionThemeColors 一致。
  function popupVarsFromTokens(tokens) {
    if (!tokens) return null;
    var primary = tokens['--fushi-primary'];
    return {
      '--text-color': tokens['--fushi-text'],
      // 弹窗卡面 = app popupCardSurface = scheme.surface。
      '--background-color': tokens['--fushi-bg'],
      '--fushi-card-bg-rgb': rgbTriple(tokens['--fushi-bg']),
      '--fushi-primary-highlight': rgba(primary, 0.35),
      '--md-surface-container': tokens['--fushi-surface-muted'],
      '--md-surface-container-high': tokens['--fushi-surface-high'],
      '--md-on-surface': tokens['--fushi-text'],
      '--md-on-surface-variant': tokens['--fushi-muted'],
      '--md-outline-variant': tokens['--fushi-outline'],
      '--md-primary': primary,
      '--md-on-primary': tokens['--fushi-on-primary'],
      '--md-primary-container': tokens['--fushi-primary-soft'],
      '--md-on-primary-container': tokens['--fushi-on-primary-soft'],
      '--md-secondary-container': tokens['--fushi-secondary-soft'],
      '--md-on-secondary-container': tokens['--fushi-on-secondary-soft'],
      '--md-tertiary': tokens['--fushi-tertiary'],
      '--md-on-tertiary': tokens['--fushi-on-tertiary'],
      '--md-tertiary-container': tokens['--fushi-tertiary-soft'],
      '--md-on-tertiary-container': tokens['--fushi-on-tertiary-soft'],
      '--md-surface-container-low': tokens['--fushi-surface-low'],
      '--md-surface-container-highest': tokens['--fushi-surface-strong'],
      '--md-outline': tokens['--fushi-outline-strong'],
      '--md-inverse-surface': tokens['--fushi-inverse-surface'],
      '--md-inverse-on-surface': tokens['--fushi-inverse-on-surface'],
      '--md-error': tokens['--fushi-danger'],
    };
  }

  var TOKEN_NAMES = MC ? Object.keys(derive({ seed: DEFAULT_SEED }, 'light')) : [];

  g.fushiThemePalette = {
    PRESETS: PRESETS,
    LEGACY_PRESETS: LEGACY_PRESETS,
    DEFAULT_PALETTE: DEFAULT_PALETTE,
    DEFAULT_SEED: DEFAULT_SEED,
    DEFAULT_VARIANT: DEFAULT_VARIANT,
    TOKEN_NAMES: TOKEN_NAMES,
    available: !!MC,
    parseHex: parseHex,
    parseCssColor: parseCssColor,
    toHex: toHex,
    rgbToOklch: rgbToOklch,
    normalizePaletteId: normalizePaletteId,
    legacyReplacement: legacyReplacement,
    nearestPresetForSeed: nearestPresetForSeed,
    normalizeCustomTheme: normalizeCustomTheme,
    normalizeCustomThemes: normalizeCustomThemes,
    newThemeId: newThemeId,
    presetFor: function (key) { return PRESET_BY_KEY[key] || null; },
    specFor: specFor,
    schemeFor: schemeFor,
    derive: derive,
    tokensFromAppTheme: tokensFromAppTheme,
    specFromAppTheme: specFromAppTheme,
    popupVarsFromTokens: popupVarsFromTokens,
  };
})();
