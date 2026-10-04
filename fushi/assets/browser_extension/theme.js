// 扩展主题的唯一决议点：明暗 + 调色板。
//
// 明暗：chrome.storage.local.extensionTheme = 'auto' | 'light' | 'dark'（缺省 auto = 跟随系统）。
// 所有表面都问这里，不再各自 matchMedia：options 页、字幕侧边栏、工具栏菜单、嵌套查词壳
// 走 applyToDocument()（把显式值写成根节点 data-theme，theme.css 据此切换调色板）；
// 页内浮层（查词弹窗 / 字幕覆盖层 / 抽屉）走 resolve(fallback)——弹窗在 auto 下跟 app 当前
// 明暗（查词响应 --fushi-color-scheme），显式值则压过它，并由 background.js 把同一个值作为
// colorScheme 提示带进查词请求，让 app 按该明暗生成 --md-* 配色（否则 data-theme 深、
// --md-* 浅就是 BUG-688 那种主题分裂）。
//
// 调色板（与 Fushi 本体同一套主题模型，见 theme-palette.js）：
//   extensionPalette = 'fushi'（theme.css 默认绿）| 'app'（跟随 Fushi：用查词响应镜像的 app
//   配色 appThemeMirror[light|dark]）| 预设 key | 'custom:<id>'；extensionCustomThemes 是
//   自定义主题列表。非默认调色板时把派生出的 --fushi-* 落成一条 <style>：扩展页面写在 :root，
//   宿主网页里只写到 #fushi-* 浮层宿主（与 generate-content-css.mjs 重根同一份宿主清单），
//   绝不碰宿主页 :root。查词弹窗的 --md-* 由 popupVars() 给三处弹窗壳覆盖，弹窗与其它表面
//   同一款主题。
//
// 材质（与调色板正交，同 app 设计系统 glass_material 独立于颜色主题）：
//   extensionMaterial = 'auto'（跟随 Fushi：app 设计系统选了玻璃即玻璃，镜像自查词响应的
//   --fushi-glass → appGlassMirror）| 'solid' | 'glass'。扩展页面根上写 data-material="glass"
//   （glass.css 全部规则挂在这个属性下）；网页里的查词弹窗经 resolveGlass(appFlag) 决议是否
//   套 content.js 的玻璃变体（auto 时照旧吃本次查词响应的 --fushi-glass）。宿主网页的 <html>
//   绝不写 data-material。
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
  var MATERIAL_KEY = 'extensionMaterial';
  var APP_GLASS_KEY = 'appGlassMirror';
  var STYLE_ID = 'fushi-theme-palette';
  // 与 scripts/generate-content-css.mjs 的 IN_PAGE_THEME_HOSTS 同一份清单。
  var IN_PAGE_HOSTS = ':where(#fushi-drawer, #fushi-subtitle-overlay, #fushi-subtitle-drop-hint, #fushi-queue-chip, #fushi-toast, #fushi-player-btn, #fushi-player-controls)';
  var VALID = { auto: true, light: true, dark: true };
  var VALID_MATERIAL = { auto: true, solid: true, glass: true };
  var material = 'auto';
  var appGlass = null;
  var pref = 'auto';
  var paletteId = 'fushi';
  var customThemes = [];
  var appMirror = null;
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

  function normalizeMaterial(v) {
    return typeof v === 'string' && VALID_MATERIAL[v] === true ? v : 'auto';
  }

  // 本刻是否用玻璃材质。appFlag 是「跟随 Fushi」时的即时来源（查词弹窗传本次响应的
  // --fushi-glass === '1'）；不传则用镜像下来的 app 设计系统（appGlassMirror，从未查过词 = 实心）。
  function resolveGlass(appFlag) {
    if (material === 'glass') return true;
    if (material === 'solid') return false;
    if (typeof appFlag === 'boolean') return appFlag;
    return appGlass === true;
  }

  // 显式明暗（'light' / 'dark'），auto 时为 null。
  function explicit() {
    return (pref === 'light' || pref === 'dark') ? pref : null;
  }

  // 本刻应生效的明暗。fallback 是「跟随」时的次级来源（查词弹窗传 app 的
  // --fushi-color-scheme），没有则跟随系统。
  function resolve(fallback) {
    var e = explicit();
    if (e) return e;
    if (fallback === 'light' || fallback === 'dark') return fallback;
    return systemScheme();
  }

  // 当前调色板在某明暗下的 --fushi-* token；默认 'fushi'（或 app 镜像缺席、自定义 id 失效）
  // 回 null = 交给 theme.css 原样。
  function tokens(scheme) {
    if (!palette) return null;
    var s = (scheme === 'light' || scheme === 'dark') ? scheme : resolve();
    if (paletteId === 'app') {
      return palette.tokensFromAppTheme(appMirror && appMirror[s]);
    }
    if (paletteId === 'fushi') return null;
    var spec = palette.specFor(paletteId, customThemes);
    return spec ? palette.derive(spec, s) : null;
  }

  // 查词弹窗要覆盖的 app 下发变量（键名同 browserExtensionThemeColors）；'app' / 'fushi' 下为
  // null（弹窗照旧吃 app 自己的配色）。
  function popupVars(scheme) {
    if (!palette || paletteId === 'app' || paletteId === 'fushi') return null;
    return palette.popupVarsFromTokens(tokens(scheme));
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

  function setPalette(v) {
    var n = palette ? palette.normalizePaletteId(v) : 'fushi';
    if (n === paletteId) return;
    paletteId = n;
    notify();
  }

  function setCustomThemes(list) {
    customThemes = palette ? palette.normalizeCustomThemes(list) : [];
    notify();
  }

  function setAppMirror(v) {
    appMirror = (v && typeof v === 'object') ? v : null;
    if (paletteId === 'app') notify();
  }

  function setMaterial(v) {
    var n = normalizeMaterial(v);
    if (n === material) return;
    material = n;
    notify();
  }

  function setAppGlass(v) {
    var n = typeof v === 'boolean' ? v : null;
    if (n === appGlass) return;
    appGlass = n;
    if (material === 'auto') notify();
  }

  function onChange(fn) {
    if (typeof fn === 'function') subscribers.push(fn);
  }

  // 把显式值写到根节点：theme.css 的 :root[data-theme=...] 块据此切换；auto 时摘掉属性，
  // 让 @media (prefers-color-scheme) 那块接管。调色板 style 一并维护。
  function applyToDocument(doc) {
    doc = doc || document;
    function apply() {
      var e = explicit();
      try {
        var root = doc.documentElement;
        if (!root) return;
        if (e) root.setAttribute('data-theme', e);
        else root.removeAttribute('data-theme');
        if (resolveGlass()) root.setAttribute('data-material', 'glass');
        else root.removeAttribute('data-material');
      } catch (_) {}
      applyPaletteStyle(doc);
    }
    apply();
    onChange(apply);
  }

  // 宿主网页里：只维护 #fushi-* 浮层宿主的调色板 style，绝不动宿主的 <html>。
  function applyToHostPage(doc) {
    doc = doc || document;
    function apply() { applyPaletteStyle(doc); }
    apply();
    onChange(apply);
  }

  function readAll(c) {
    if (!c) return;
    pref = normalize(c[KEY]);
    paletteId = palette ? palette.normalizePaletteId(c[PALETTE_KEY]) : 'fushi';
    customThemes = palette ? palette.normalizeCustomThemes(c[CUSTOM_KEY]) : [];
    appMirror = (c[APP_MIRROR_KEY] && typeof c[APP_MIRROR_KEY] === 'object') ? c[APP_MIRROR_KEY] : null;
    material = normalizeMaterial(c[MATERIAL_KEY]);
    appGlass = typeof c[APP_GLASS_KEY] === 'boolean' ? c[APP_GLASS_KEY] : null;
    notify();
  }

  try {
    var keys = [KEY, PALETTE_KEY, CUSTOM_KEY, APP_MIRROR_KEY, MATERIAL_KEY, APP_GLASS_KEY];
    var p = chrome.storage.local.get(keys, readAll);
    if (p && typeof p.then === 'function') p.then(readAll, function () {});
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      if (changes[KEY]) setPreference(changes[KEY].newValue);
      if (changes[PALETTE_KEY]) setPalette(changes[PALETTE_KEY].newValue);
      if (changes[CUSTOM_KEY]) setCustomThemes(changes[CUSTOM_KEY].newValue);
      if (changes[APP_MIRROR_KEY]) setAppMirror(changes[APP_MIRROR_KEY].newValue);
      if (changes[MATERIAL_KEY]) setMaterial(changes[MATERIAL_KEY].newValue);
      if (changes[APP_GLASS_KEY]) setAppGlass(changes[APP_GLASS_KEY].newValue);
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
    MATERIAL_KEY: MATERIAL_KEY,
    APP_GLASS_KEY: APP_GLASS_KEY,
    get preference() { return pref; },
    get material() { return material; },
    get palette() { return paletteId; },
    get customThemes() { return customThemes.slice(); },
    get appMirror() { return appMirror; },
    explicit: explicit,
    resolve: resolve,
    resolveGlass: resolveGlass,
    tokens: tokens,
    popupVars: popupVars,
    applyPopupPalette: applyPopupPalette,
    paletteCss: paletteCss,
    onChange: onChange,
    applyToDocument: applyToDocument,
    applyToHostPage: applyToHostPage,
    setPreference: setPreference,
    setPalette: setPalette,
    setCustomThemes: setCustomThemes,
    setAppMirror: setAppMirror,
    setMaterial: setMaterial,
    setAppGlass: setAppGlass,
  };
})();
