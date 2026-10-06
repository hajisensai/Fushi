// 扩展主题的唯一决议点：明暗 + 调色板 + 外观风格。
//
// 明暗：chrome.storage.local.extensionTheme = 'auto' | 'light' | 'dark'（缺省 auto = 跟随系统）。
// 所有表面都问这里，不再各自 matchMedia：options 页、字幕侧边栏、工具栏菜单、嵌套查词壳
// 走 applyToDocument()（把显式值写成根节点 data-theme，theme.css 据此切换调色板）；
// 页内浮层（查词弹窗 / 字幕覆盖层 / 抽屉）走 resolve(fallback)——弹窗在 auto 下跟 app 当前
// 明暗（查词响应 --fushi-color-scheme），显式值则压过它，并由 background.js 把同一个值作为
// colorScheme 提示带进查词请求，让 app 按该明暗生成 --md-* 配色（否则 data-theme 深、
// --md-* 浅就是 BUG-688 那种主题分裂）。
//
// 调色板（与 Fushi 本体同一套主题模型与生成算法，见 theme-palette.js）：
//   extensionPalette = 'app'（跟随 Fushi，缺省：用查词响应镜像的 app 配色 appThemeMirror[light|dark]）|
//   M3 经典预设 key（m3-*，与 app 同名同种子同变体；旧扩展预设 id 只读映射到最接近的一款）|
//   'custom:<id>'；extensionCustomThemes 是自定义主题列表。
//   extensionPureBlack（与 app 的 pure_black_dark 同义）：深色下页面底为真黑；只作用于预设 / 自定义
//   调色板——跟随 Fushi 时纯黑随 app 下发的方案一起来。从没写过时，旧选了「纯黑」预设
//   （black-theme）的用户缺省开，与 app 的只读兜底同律。非默认调色板时把派生出的 --fushi-* 落成一条 <style>：扩展页面写在 :root，
//   宿主网页里只写到 #fushi-* 浮层宿主（与 generate-content-css.mjs 重根同一份宿主清单），
//   绝不碰宿主页 :root。查词弹窗的 --md-* 由 popupVars() 给三处弹窗壳覆盖，弹窗与其它表面
//   同一款主题。
//
// 外观风格（与调色板正交；用户 2026-10-05「两套样式 M3E 和液态玻璃」，2026-10-06「浏览器扩展也
//   统一成 m3e」）：extensionStyle = 'm3e'（Material 3 Expressive，缺省）| 'glass'（液态玻璃，第二套）。
//   风格只决定形状 / 表面材质 / 层次 / 动效，token 全在 theme.css（:root 为 M3E，
//   :root[data-style="glass"] 覆盖），material.css 按 token 落到各页控件。扩展页面写根 data-style；
//   宿主网页里只有 Fushi 自己的浮层跟风格走——页内宿主（IN_PAGE_HOST_IDS）由 stampStyle 写
//   data-style（创建时调一次，设置变化时 applyToHostPage 重盖已存在的宿主）；查词弹窗问
//   usesGlass()，M3E 下由 applyPopupStyle 给弹窗根挂 .fushi-m3e（popup.css 的「M3E 视觉层」，与
//   app 内弹窗同一套）。2026-10-04 退役的「材质」设置（extensionMaterial / appGlassMirror）仍只做清理。
//
// content script / 扩展页面共用一份；没有 chrome.storage 的环境（纯 vm 测试）退化为
// 跟随系统、setPreference 仍可用。
(function () {
  'use strict';
  if (typeof window === 'undefined') return;

  var KEY = 'extensionTheme';
  var PALETTE_KEY = 'extensionPalette';
  var CUSTOM_KEY = 'extensionCustomThemes';
  var APP_MIRROR_KEY = 'appThemeMirror';
  var STYLE_KEY = 'extensionStyle';
  var PURE_BLACK_KEY = 'extensionPureBlack';
  // 已退役的材质设置键（只用于清理旧存储）。
  var RETIRED_KEYS = ['extensionMaterial', 'appGlassMirror'];
  var STYLE_ID = 'fushi-theme-palette';
  // 与 scripts/generate-content-css.mjs 的 IN_PAGE_THEME_HOSTS 同一份清单。
  var IN_PAGE_HOSTS = ':where(#fushi-drawer, #fushi-subtitle-overlay, #fushi-subtitle-drop-hint, #fushi-queue-chip, #fushi-toast, #fushi-player-btn, #fushi-player-controls, #fushi-ctx-modal-host)';
  var VALID = { auto: true, light: true, dark: true };
  // 页内宿主 id（与 IN_PAGE_HOSTS 同一份清单）：设置变化时按 id 重盖 data-style。
  var IN_PAGE_HOST_IDS = ['fushi-drawer', 'fushi-subtitle-overlay', 'fushi-subtitle-drop-hint', 'fushi-queue-chip',
    'fushi-toast', 'fushi-player-btn', 'fushi-player-controls', 'fushi-ctx-modal-host'];
  var VALID_STYLE = { glass: true, m3e: true };
  var DEFAULT_STYLE = 'm3e';
  var pref = 'auto';
  var style = DEFAULT_STYLE;
  var paletteId = (window.fushiThemePalette && window.fushiThemePalette.DEFAULT_PALETTE) || 'app';
  var customThemes = [];
  var appMirror = null;
  var pureBlack = false;
  var subscribers = [];
  var palette = window.fushiThemePalette || null;

  function normalize(v) {
    return typeof v === 'string' && VALID[v] === true ? v : 'auto';
  }

  function systemScheme() {
    try {
      return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
        ? 'dark' : 'light';
    } catch (_) { return 'light'; }
  }

  function normalizeStyle(v) {
    return typeof v === 'string' && VALID_STYLE[v] === true ? v : DEFAULT_STYLE;
  }

  // 当前风格是否液态玻璃（查词弹窗 / 嵌套层决定要不要上模糊与半透明填充）。
  function usesGlass() {
    return style === 'glass';
  }

  // 系统「减弱动态效果」。CSS 侧各自有 @media；这里给不能写 @media 的弹窗（popup.css 生成器不处理
  // 嵌套 at-rule）挂 .fushi-reduced-motion 用。
  function reducedMotion() {
    try {
      return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    } catch (_) { return false; }
  }

  // 给一个 Fushi 自有浮层元素盖上当前风格（content.css 里重根后的 theme.css 按它切 M3E / 玻璃）。
  function stampStyle(el) {
    if (!el || typeof el.setAttribute !== 'function') return;
    try { el.setAttribute('data-style', style); } catch (_) {}
  }

  // 查词弹窗根（#entries-container）：M3E 下挂 .fushi-m3e = popup.css「M3E 视觉层」（卡片 / 标签 /
  // 动作按钮 / 菜单换成 M3E 色块与形状，与 app 内弹窗 popup_settings_injection 同一个开关）；墨水屏
  // （.eink）不挂。减弱动态效果挂 .fushi-reduced-motion。content.js / side-panel.js / nested-popup.js
  // 三处共用。eink = app 开了墨水屏（随 theme 下发 --fushi-glass: '0'）。
  function applyPopupStyle(container, eink) {
    if (!container || !container.classList) return;
    eink = eink === true;
    try { eink = eink || container.classList.contains('eink'); } catch (_) {}
    try {
      container.classList.toggle('fushi-m3e', style === 'm3e' && !eink);
      container.classList.toggle('fushi-reduced-motion', reducedMotion());
    } catch (_) {}
  }

  // 显式明暗（'light' / 'dark'），auto 时为 null。
  function explicit() {
    return (pref === 'light' || pref === 'dark') ? pref : null;
  }

  // app 最近一次下发的明暗（background.js 镜像进 appThemeMirror.current）。
  function appScheme() {
    var cur = appMirror && appMirror.current;
    return (cur === 'light' || cur === 'dark') ? cur : null;
  }

  // 本刻应生效的明暗。明暗只由明暗设置决定，调色板（预设 / 自定义 / 扩展绿）只决定配色家族
  // （用户 2026-10-06「切换主题时如果我是深色就要继续保持深色」）：
  //   · 显式 light / dark → 它；
  //   · 自动 + 跟随 Fushi → 跟 app 的明暗（查词弹窗传进来的 --fushi-color-scheme，扩展页面用镜像的
  //     appThemeMirror.current），弹窗与侧边栏 / 设置页 / 页内浮层同一明暗；
  //   · 自动 + 其它调色板 → 跟系统（弹窗也是：它的颜色由 applyPopupPalette 按这个明暗覆盖）。
  function resolve(fallback) {
    var e = explicit();
    if (e) return e;
    if (paletteId === 'app') {
      if (fallback === 'light' || fallback === 'dark') return fallback;
      var a = appScheme();
      if (a) return a;
    }
    return systemScheme();
  }

  // 扩展页面根上要写的 data-theme：显式值，或「跟随 Fushi」时 app 的明暗；否则 null（交给
  // prefers-color-scheme）。
  function documentScheme() {
    return explicit() || (paletteId === 'app' ? appScheme() : null);
  }

  // 当前调色板在某明暗下的 --fushi-* token；app 镜像缺席 / 自定义 id 失效回 null = 交给 theme.css
  // 原样（theme.css ① 是 app 缺省种子按同一算法生成的值）。
  function tokens(scheme) {
    if (!palette || !palette.available) return null;
    var s = (scheme === 'light' || scheme === 'dark') ? scheme : resolve();
    if (paletteId === 'app') {
      // 跟随 Fushi：app 下发的就是它当前 ColorScheme 的原值（纯黑、明暗、自定义角色都在里面）。
      var own = palette.tokensFromAppTheme(appMirror && appMirror[s], s);
      if (own) return own;
      // app 只下发过另一种明暗（查词弹窗跟 app 当前明暗，扩展页面 auto 时可能跟系统）：按 app 随
      // theme 下发的种子 / 变体 / 纯黑派生本明暗——与 app 自己切到这一明暗的算法相同。
      var other = palette.specFromAppTheme(appMirror && appMirror[s === 'dark' ? 'light' : 'dark']);
      return other ? palette.derive(other.spec, s, { pureBlack: other.pureBlack }) : null;
    }
    var spec = palette.specFor(paletteId, customThemes);
    return spec ? palette.derive(spec, s, { pureBlack: pureBlack }) : null;
  }

  // 查词弹窗要覆盖的 app 下发变量（键名同 browserExtensionThemeColors）。'app'（跟随 Fushi）下为
  // null——弹窗本来就吃 app 下发的配色，与扩展页面的 app 镜像同源。
  function popupVars(scheme) {
    if (!palette || paletteId === 'app') return null;
    var s = (scheme === 'light' || scheme === 'dark') ? scheme : resolve();
    return palette.popupVarsFromTokens(tokens(s));
  }

  // 把弹窗覆盖变量套到弹窗容器上（content.js / side-panel.js / nested-popup.js 三处共用）。
  function applyPopupPalette(container, scheme) {
    var vars = popupVars(scheme);
    if (!vars || !container || !container.style) return false;
    for (var k in vars) {
      try { container.style.setProperty(k, vars[k]); } catch (_) {}
    }
    return true;
  }

  function cssBlock(selector, map) {
    var out = selector + ' {';
    for (var k in map) out += ' ' + k + ': ' + map[k] + ';';
    return out + ' }';
  }

  // 调色板落成一条 <style>：扩展页面写 :root（明暗两块各自条件化，与 theme.css 语义一致），
  // 宿主网页里只写到 #fushi-* 浮层宿主。默认调色板则摘掉这条 style，theme.css 接管。
  function paletteCss(inPage) {
    var light = tokens('light'), dark = tokens('dark');
    if (!light && !dark) return '';
    var host = inPage ? IN_PAGE_HOSTS : ':root';
    var css = '';
    if (light) {
      css += cssBlock(host + ':not([data-theme="dark"])', light) + '\n';
    }
    if (dark) {
      css += cssBlock(host + '[data-theme="dark"]', dark) + '\n';
      css += '@media (prefers-color-scheme: dark) { ' + cssBlock(host + ':not([data-theme="light"])', dark) + ' }\n';
    }
    return css;
  }

  function isExtensionPage() {
    try {
      var proto = window.location && window.location.protocol;
      return proto === 'chrome-extension:' || proto === 'moz-extension:';
    } catch (_) { return false; }
  }

  function applyPaletteStyle(doc) {
    doc = doc || document;
    var css = paletteCss(!isExtensionPage());
    try {
      var el = doc.getElementById ? doc.getElementById(STYLE_ID) : null;
      if (!css) {
        if (el && el.parentNode) el.parentNode.removeChild(el);
        return;
      }
      if (!el) {
        el = doc.createElement('style');
        el.id = STYLE_ID;
        var parent = doc.head || doc.documentElement;
        if (!parent) return;
        parent.appendChild(el);
      }
      if (el.textContent !== css) el.textContent = css;
    } catch (_) {}
  }

  function notify() {
    var eff = resolve();
    for (var i = 0; i < subscribers.length; i++) {
      try { subscribers[i](eff, pref); } catch (_) {}
    }
  }

  function setPreference(v) {
    var n = normalize(v);
    if (n === pref) return;
    pref = n;
    notify();
  }

  function setStyle(v) {
    var n = normalizeStyle(v);
    if (n === style) return;
    style = n;
    notify();
  }

  function setPalette(v) {
    var n = palette ? palette.normalizePaletteId(v) : 'app';
    if (n === paletteId) return;
    paletteId = n;
    notify();
  }

  function setCustomThemes(list) {
    customThemes = palette ? palette.normalizeCustomThemes(list) : [];
    notify();
  }

  function setPureBlack(v) {
    var n = v === true;
    if (n === pureBlack) return;
    pureBlack = n;
    notify();
  }

  // extensionPureBlack 没写过时的缺省：旧「纯黑」预设用户保持纯黑（只读兜底，不改写存储）。
  function pureBlackFrom(stored, rawPalette) {
    if (typeof stored === 'boolean') return stored;
    return rawPalette === 'black-theme';
  }

  function setAppMirror(v) {
    appMirror = (v && typeof v === 'object') ? v : null;
    if (paletteId === 'app') notify();
  }

  function onChange(fn) {
    if (typeof fn === 'function') subscribers.push(fn);
  }

  // 把显式值写到根节点：theme.css 的 :root[data-theme=...] 块据此切换；auto 时摘掉属性，
  // 让 @media (prefers-color-scheme) 那块接管。调色板 style 一并维护。
  function applyToDocument(doc) {
    doc = doc || document;
    function apply() {
      var e = documentScheme();
      try {
        var root = doc.documentElement;
        if (!root) return;
        if (e) root.setAttribute('data-theme', e);
        else root.removeAttribute('data-theme');
        root.setAttribute('data-style', style);
      } catch (_) {}
      applyPaletteStyle(doc);
    }
    apply();
    onChange(apply);
  }

  // 宿主网页里：只维护 #fushi-* 浮层宿主的调色板 style 与 data-style，绝不动宿主的 <html>。
  function applyToHostPage(doc) {
    doc = doc || document;
    function apply() {
      applyPaletteStyle(doc);
      if (!doc.getElementById) return;
      for (var i = 0; i < IN_PAGE_HOST_IDS.length; i++) {
        try { stampStyle(doc.getElementById(IN_PAGE_HOST_IDS[i])); } catch (_) {}
      }
    }
    apply();
    onChange(apply);
  }

  function readAll(c) {
    if (!c) return;
    pref = normalize(c[KEY]);
    style = normalizeStyle(c[STYLE_KEY]);
    paletteId = palette ? palette.normalizePaletteId(c[PALETTE_KEY]) : 'app';
    customThemes = palette ? palette.normalizeCustomThemes(c[CUSTOM_KEY]) : [];
    appMirror = (c[APP_MIRROR_KEY] && typeof c[APP_MIRROR_KEY] === 'object') ? c[APP_MIRROR_KEY] : null;
    pureBlack = pureBlackFrom(c[PURE_BLACK_KEY], c[PALETTE_KEY]);
    notify();
  }

  try {
    var keys = [KEY, PALETTE_KEY, CUSTOM_KEY, APP_MIRROR_KEY, STYLE_KEY, PURE_BLACK_KEY];
    var p = chrome.storage.local.get(keys, readAll);
    if (p && typeof p.then === 'function') p.then(readAll, function () {});
  } catch (_) {}
  // 旧版「材质」设置留下的键：只有扩展自己的页面清（content script 每个网页都跑，不必重复写）。
  try {
    if (isExtensionPage() && chrome.storage.local.remove) {
      var r = chrome.storage.local.remove(RETIRED_KEYS);
      if (r && typeof r.then === 'function') r.then(null, function () {});
    }
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      if (changes[KEY]) setPreference(changes[KEY].newValue);
      if (changes[STYLE_KEY]) setStyle(changes[STYLE_KEY].newValue);
      if (changes[PALETTE_KEY]) setPalette(changes[PALETTE_KEY].newValue);
      if (changes[CUSTOM_KEY]) setCustomThemes(changes[CUSTOM_KEY].newValue);
      if (changes[APP_MIRROR_KEY]) setAppMirror(changes[APP_MIRROR_KEY].newValue);
      if (changes[PURE_BLACK_KEY]) setPureBlack(changes[PURE_BLACK_KEY].newValue === true);
    });
  } catch (_) {}
  try {
    var mq = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
    if (mq && typeof mq.addEventListener === 'function') {
      mq.addEventListener('change', function () { if (!explicit()) notify(); });
    }
  } catch (_) {}

  // 扩展自己的页面（options / 侧边栏 / 工具栏菜单 / 嵌套查词壳）直接把主题写到根上；
  // 宿主网页里（content script）只维护浮层宿主的调色板 style。
  try {
    if (isExtensionPage()) applyToDocument(document);
    else if (typeof document !== 'undefined' && document && document.createElement) applyToHostPage(document);
  } catch (_) {}

  window.fushiTheme = {
    KEY: KEY,
    PALETTE_KEY: PALETTE_KEY,
    CUSTOM_KEY: CUSTOM_KEY,
    APP_MIRROR_KEY: APP_MIRROR_KEY,
    STYLE_KEY: STYLE_KEY,
    PURE_BLACK_KEY: PURE_BLACK_KEY,
    pureBlackFrom: pureBlackFrom,
    get pureBlack() { return pureBlack; },
    get preference() { return pref; },
    get style() { return style; },
    get palette() { return paletteId; },
    get customThemes() { return customThemes.slice(); },
    get appMirror() { return appMirror; },
    explicit: explicit,
    usesGlass: usesGlass,
    reducedMotion: reducedMotion,
    stampStyle: stampStyle,
    applyPopupStyle: applyPopupStyle,
    resolve: resolve,
    documentScheme: documentScheme,
    tokens: tokens,
    popupVars: popupVars,
    applyPopupPalette: applyPopupPalette,
    paletteCss: paletteCss,
    onChange: onChange,
    applyToDocument: applyToDocument,
    applyToHostPage: applyToHostPage,
    setPreference: setPreference,
    setStyle: setStyle,
    setPalette: setPalette,
    setCustomThemes: setCustomThemes,
    setAppMirror: setAppMirror,
    setPureBlack: setPureBlack,
  };
})();
