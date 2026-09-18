// 扩展界面的多语言（用户 2026-09-18：「扩展要支持不同语言、和 Fushi 一致，现在默认全是中文」）。
//
// 语言决议（chrome.storage.local）：
//   extensionLanguage = 'app'（默认，跟随 Fushi：background.js 把 status / 查词响应里 app 当前
//   UI 语言写进 appLocale）| 'browser'（navigator.language）| 具体 tag（固定某一种）。
//   拿不到 app 语言（app 没开、旧 app）时回落浏览器语言；再对不上就是英文。
// 支持的 tag 与 app 的 Slang 清单一致（fushi/lib/i18n/strings_<tag>.i18n.json）。
//
// 字典：英文是源（locales/en.json，与 SUPPORTED 一起也是守卫测试的基准），其它语言
// locales/<tag>.json 键集必须与英文完全一致（i18n-catalog.test.js 钉死）。运行时先用
// 内嵌的英文兜底，目标语言 fetch 到达后整体切换并通知订阅者（文档级重渲染 / toast 下次
// 取新值）。content script 与扩展页面共用同一份；无 chrome.storage 的纯 vm 测试环境下
// 退化为英文 + setLocale 可用。
//
// 用法：fushiT('key') / fushiT('key', {n: 3})——占位符写 {n}；HTML 里 data-i18n="key"
// （textContent）、data-i18n-html="key"（innerHTML，只给我们自己写的、含 <kbd>/<b> 的文案）、
// data-i18n-title / -placeholder / -aria-label（属性）。
(function () {
  'use strict';
  // content script / 扩展页面用 window；background service worker 用 self（importScripts 装入）。
  var g = (typeof window !== 'undefined') ? window : ((typeof self !== 'undefined') ? self : null);
  if (!g) return;

  var SETTING_KEY = 'extensionLanguage';
  var APP_LOCALE_KEY = 'appLocale';
  var SUPPORTED = ['en', 'ar', 'de', 'es', 'fr', 'id', 'it', 'ja', 'ko', 'nl', 'pt-BR', 'ru',
    'th', 'tr', 'vi', 'zh-CN', 'zh-HK'];
  var RTL = { ar: true };

  var en = g.FUSHI_I18N_EN || {};
  var setting = 'app';
  var appLocale = '';
  var current = 'en';
  var table = en;
  var subscribers = [];
  var loadSeq = 0;

  // 把任意 tag 归到支持清单：精确匹配 → 语言前缀（zh → zh-CN、pt → pt-BR、zh-TW → zh-HK）→ null。
  function normalizeTag(tag) {
    if (typeof tag !== 'string' || !tag) return null;
    var t = tag.replace(/_/g, '-');
    for (var i = 0; i < SUPPORTED.length; i++) {
      if (SUPPORTED[i].toLowerCase() === t.toLowerCase()) return SUPPORTED[i];
    }
    var lang = t.split('-')[0].toLowerCase();
    if (lang === 'zh') {
      var region = (t.split('-')[1] || '').toLowerCase();
      var script = t.toLowerCase();
      if (region === 'tw' || region === 'hk' || region === 'mo' || /hant/.test(script)) return 'zh-HK';
      return 'zh-CN';
    }
    if (lang === 'pt') return 'pt-BR';
    for (var j = 0; j < SUPPORTED.length; j++) {
      if (SUPPORTED[j].split('-')[0].toLowerCase() === lang) return SUPPORTED[j];
    }
    return null;
  }

  function browserTag() {
    try {
      var langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language];
      for (var i = 0; i < langs.length; i++) {
        var n = normalizeTag(langs[i]);
        if (n) return n;
      }
    } catch (_) {}
    return 'en';
  }

  function resolveTag() {
    if (setting !== 'app' && setting !== 'browser') {
      var fixed = normalizeTag(setting);
      if (fixed) return fixed;
    }
    if (setting === 'app') {
      var fromApp = normalizeTag(appLocale);
      if (fromApp) return fromApp;
    }
    return browserTag();
  }

  function format(text, params) {
    if (!params || typeof text !== 'string') return text;
    return text.replace(/\{(\w+)\}/g, function (m, k) {
      return Object.prototype.hasOwnProperty.call(params, k) ? String(params[k]) : m;
    });
  }

  function t(key, params) {
    var v = table[key];
    if (typeof v !== 'string') v = en[key];
    if (typeof v !== 'string') return key;
    return format(v, params);
  }

  function notify() {
    for (var i = 0; i < subscribers.length; i++) {
      try { subscribers[i](current); } catch (_) {}
    }
  }

  function applyTable(tag, dict) {
    current = tag;
    table = dict || en;
    notify();
  }

  function localeUrl(tag) {
    try { return chrome.runtime.getURL('locales/' + tag + '.json'); } catch (_) { return null; }
  }

  // 目标语言字典按需取（扩展自己的资源，本地、毫秒级）。取失败 / 无 runtime 时停在英文。
  function loadLocale(tag) {
    var seq = ++loadSeq;
    if (tag === 'en') { applyTable('en', en); return; }
    var url = localeUrl(tag);
    if (!url || typeof fetch !== 'function') { applyTable('en', en); return; }
    fetch(url).then(function (r) { return r.ok ? r.json() : null; }).then(function (dict) {
      if (seq !== loadSeq) return; // 期间又换了语言：这份作废
      if (dict && typeof dict === 'object') applyTable(tag, dict);
      else applyTable('en', en);
    }, function () { if (seq === loadSeq) applyTable('en', en); });
  }

  function refresh() {
    var tag = resolveTag();
    if (tag === current && (tag === 'en' || table !== en)) return;
    loadLocale(tag);
  }

  function setSetting(v) {
    var n = (typeof v === 'string' && v) ? v : 'app';
    if (n === setting) return;
    setting = n;
    refresh();
  }
  function setAppLocale(v) {
    var n = typeof v === 'string' ? v : '';
    if (n === appLocale) return;
    appLocale = n;
    refresh();
  }

  function onChange(fn) {
    if (typeof fn === 'function') subscribers.push(fn);
  }

  // 文档级套用：data-i18n* 属性的节点全部按当前字典重写，并把 <html lang / dir> 对齐。
  function applyToDocument(doc) {
    doc = doc || document;
    function apply() {
      var root = doc.documentElement;
      try {
        if (root) {
          root.setAttribute('lang', current);
          root.setAttribute('dir', RTL[current] ? 'rtl' : 'ltr');
        }
      } catch (_) {}
      var nodes;
      try {
        nodes = doc.querySelectorAll('[data-i18n],[data-i18n-html],[data-i18n-title],[data-i18n-placeholder],[data-i18n-aria-label]');
      } catch (_) { return; }
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var k = el.getAttribute('data-i18n');
        if (k) el.textContent = t(k);
        var kh = el.getAttribute('data-i18n-html');
        if (kh) el.innerHTML = t(kh);
        var kt = el.getAttribute('data-i18n-title');
        if (kt) el.setAttribute('title', t(kt));
        var kp = el.getAttribute('data-i18n-placeholder');
        if (kp) el.setAttribute('placeholder', t(kp));
        var ka = el.getAttribute('data-i18n-aria-label');
        if (ka) el.setAttribute('aria-label', t(ka));
      }
      try {
        var title = doc.querySelector('title[data-i18n]');
        if (title) doc.title = t(title.getAttribute('data-i18n'));
      } catch (_) {}
    }
    apply();
    onChange(apply);
  }

  try {
    var p = chrome.storage.local.get([SETTING_KEY, APP_LOCALE_KEY], function (c) {
      if (!c) return;
      appLocale = typeof c[APP_LOCALE_KEY] === 'string' ? c[APP_LOCALE_KEY] : '';
      setting = (typeof c[SETTING_KEY] === 'string' && c[SETTING_KEY]) ? c[SETTING_KEY] : 'app';
      refresh();
    });
    if (p && typeof p.then === 'function') {
      p.then(function (c) {
        if (!c) return;
        appLocale = typeof c[APP_LOCALE_KEY] === 'string' ? c[APP_LOCALE_KEY] : '';
        setting = (typeof c[SETTING_KEY] === 'string' && c[SETTING_KEY]) ? c[SETTING_KEY] : 'app';
        refresh();
      }, function () {});
    }
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      if (changes[SETTING_KEY]) setSetting(changes[SETTING_KEY].newValue);
      if (changes[APP_LOCALE_KEY]) setAppLocale(changes[APP_LOCALE_KEY].newValue);
    });
  } catch (_) {}

  try {
    var proto = g.location && g.location.protocol;
    if (typeof document !== 'undefined' && (proto === 'chrome-extension:' || proto === 'moz-extension:')) {
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { applyToDocument(document); });
      } else {
        applyToDocument(document);
      }
    }
  } catch (_) {}

  g.fushiI18n = {
    SUPPORTED: SUPPORTED.slice(),
    t: t,
    get locale() { return current; },
    get setting() { return setting; },
    normalizeTag: normalizeTag,
    resolveTag: resolveTag,
    onChange: onChange,
    applyToDocument: applyToDocument,
    setSetting: setSetting,
    setAppLocale: setAppLocale,
    // 测试 / 同步注入：直接装一份字典（不走 fetch）。
    setLocale: function (tag, dict) { loadSeq++; applyTable(tag, dict); },
  };
  g.fushiT = t;
})();
