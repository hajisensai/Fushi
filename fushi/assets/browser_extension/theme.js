// 扩展主题（明暗）的唯一决议点。设置键 chrome.storage.local.extensionTheme =
// 'auto' | 'light' | 'dark'（缺省 auto = 跟随系统）。
//
// 所有表面都问这里，不再各自 matchMedia：options 页、字幕侧边栏、工具栏菜单、嵌套查词壳
// 走 applyToDocument()（把显式值写成根节点 data-theme，theme.css 据此切换调色板）；
// 页内浮层（查词弹窗 / 字幕覆盖层 / 抽屉）走 resolve(fallback)——弹窗在 auto 下跟 app 当前
// 明暗（查词响应 --fushi-color-scheme），显式值则压过它，并由 background.js 把同一个值作为
// colorScheme 提示带进查词请求，让 app 按该明暗生成 --md-* 配色（否则 data-theme 深、
// --md-* 浅就是 BUG-688 那种主题分裂）。
//
// content script / 扩展页面共用一份；没有 chrome.storage 的环境（纯 vm 测试）退化为
// 跟随系统、setPreference 仍可用。
(function () {
  'use strict';
  if (typeof window === 'undefined') return;

  var KEY = 'extensionTheme';
  var VALID = { auto: true, light: true, dark: true };
  var pref = 'auto';
  var subscribers = [];

  function normalize(v) {
    return typeof v === 'string' && VALID[v] === true ? v : 'auto';
  }

  function systemScheme() {
    try {
      return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
        ? 'dark' : 'light';
    } catch (_) { return 'light'; }
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

  function onChange(fn) {
    if (typeof fn === 'function') subscribers.push(fn);
  }

  // 把显式值写到根节点：theme.css 的 :root[data-theme=...] 块据此切换；auto 时摘掉属性，
  // 让 @media (prefers-color-scheme) 那块接管。
  function applyToDocument(doc) {
    doc = doc || document;
    function apply() {
      var e = explicit();
      try {
        var root = doc.documentElement;
        if (!root) return;
        if (e) root.setAttribute('data-theme', e);
        else root.removeAttribute('data-theme');
      } catch (_) {}
    }
    apply();
    onChange(apply);
  }

  try {
    var p = chrome.storage.local.get(KEY, function (c) { setPreference(c && c[KEY]); });
    if (p && typeof p.then === 'function') {
      p.then(function (c) { setPreference(c && c[KEY]); }, function () {});
    }
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes || !changes[KEY]) return;
      setPreference(changes[KEY].newValue);
    });
  } catch (_) {}
  try {
    var mq = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
    if (mq && typeof mq.addEventListener === 'function') {
      mq.addEventListener('change', function () { if (!explicit()) notify(); });
    }
  } catch (_) {}

  // 扩展自己的页面（options / 侧边栏 / 工具栏菜单 / 嵌套查词壳）直接把主题写到根上；
  // 宿主网页里（content script）绝不动宿主的 <html>。
  try {
    var proto = window.location && window.location.protocol;
    if (proto === 'chrome-extension:' || proto === 'moz-extension:') applyToDocument(document);
  } catch (_) {}

  window.fushiTheme = {
    KEY: KEY,
    get preference() { return pref; },
    explicit: explicit,
    resolve: resolve,
    onChange: onChange,
    applyToDocument: applyToDocument,
    setPreference: setPreference,
  };
})();
