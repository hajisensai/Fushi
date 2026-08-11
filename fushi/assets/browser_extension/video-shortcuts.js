// 视频页快捷键（content script 隔离世界，manifest bundle 里排在 subtitle-panel.js
// 之后加载）。每个动作在 options 里有独立开关：
//   ←/→        上一句 / 下一句字幕（仅当前视频有字幕轨时接管，否则放行给站点）
//   ↑           回当前句句首重播
//   Shift+S     打开浏览器原生字幕侧边栏
//   Shift+H     隐藏/显示字幕（站点原生字幕 + 扩展覆盖层，与 app 内视频页同键）
//   Ctrl+Enter  制卡（等同点查词弹窗里的「＋」；判定不在本文件，见 vendor/popup.js）
//   Ctrl+Shift+←/→/↓  字幕时轴偏移 −100ms / ＋100ms / 重置
//   Ctrl+Shift+Z      复制当前字幕句到剪贴板（配合 Fushi 剪贴板监看即查词）
//   Ctrl+Shift+[ / ]  播放速度 −0.25x / ＋0.25x
// 判定是纯函数 decide()（node 可测）；执行端是 subtitle-panel.js 暴露的
// window.fushiSubtitleShortcut(action)（控制器持有轨/偏移/模式状态），播放速度直接操作 <video>。
// 输入框/可编辑区一律放行；旧 videoShortcutsEnabled 只作为升级时各动作的缺省值。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) root.FUSHI_VIDEO_SHORTCUTS = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 纯函数按键判定。ev = {key, code, ctrl, shift, alt, editable}；
  // ctx = {enabled, hasVideo, hasTrack}。返回 {action} 或 null（null = 不接管，放行给站点）。
  function decide(ev, ctx) {
    if (!ev || !ctx || !ctx.enabled || ev.editable || !ctx.hasVideo) return null;
    if (ev.alt) return null;
    var key = ev.key || '';
    var code = ev.code || '';
    function result(action) {
      return !ctx.bindings || ctx.bindings[action] !== false ? { action: action } : null;
    }
    if (ev.ctrl && ev.shift) {
      if (key === 'ArrowLeft') return ctx.hasTrack ? result('offset-minus') : null;
      if (key === 'ArrowRight') return ctx.hasTrack ? result('offset-plus') : null;
      if (key === 'ArrowDown') return ctx.hasTrack ? result('offset-reset') : null;
      if (code === 'KeyZ') return ctx.hasTrack ? result('copy-cue') : null;
      // 括号键在 Shift 下 e.key 会变成 '{' / '}'，用布局无关的 e.code。
      if (code === 'BracketLeft') return result('rate-down');
      if (code === 'BracketRight') return result('rate-up');
      return null;
    }
    if (ev.ctrl) return null;
    if (ev.shift) {
      // 隐藏字幕（Shift+H）刻意排在 hasTrack 门之前：它藏的是**站点原生字幕**（Netflix /
      // YouTube 自带轨）+ 扩展自绘覆盖层，而 hasTrack 问的是「扩展这边有没有加载过字幕轨」。
      // 二者正交——绝大多数用户是在看站点原生字幕、根本没往扩展里挂轨，若卡在 hasTrack 后面，
      // 这个键在最主要的使用场景下会永远不触发。与 app 的 videoToggleSubtitleHide 默认键一致。
      if (code === 'KeyH') return result('toggle-subtitle-hide');
      if (!ctx.hasTrack) return null;
      if (code === 'KeyS') return result('toggle-panel');
      return null;
    }
    if (key === 'ArrowLeft') return ctx.hasTrack ? result('prev-cue') : null;
    if (key === 'ArrowRight') return ctx.hasTrack ? result('next-cue') : null;
    if (key === 'ArrowUp') return ctx.hasTrack ? result('replay-cue') : null;
    return null;
  }

  // 播放速度步进（clamp 0.25–4，步长由调用方传）。返回 clamp 后的新值。
  function nextRate(current, delta) {
    var cur = typeof current === 'number' && current > 0 ? current : 1;
    return Math.round(Math.min(4, Math.max(0.25, cur + delta)) * 100) / 100;
  }

  return { decide: decide, nextRate: nextRate };
});

// ── 浏览器运行时（node 单测里 window/document 缺省 → 整段跳过）──
(function () {
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  var api = (typeof self !== 'undefined' ? self : window).FUSHI_VIDEO_SHORTCUTS;
  var bindingKeys = {
    'prev-cue': 'videoShortcutPrevCue',
    'next-cue': 'videoShortcutNextCue',
    'replay-cue': 'videoShortcutReplayCue',
    'toggle-panel': 'videoShortcutTogglePanel',
    'toggle-subtitle-hide': 'videoShortcutToggleSubtitleHide',
    'offset-minus': 'videoShortcutOffsetMinus',
    'offset-plus': 'videoShortcutOffsetPlus',
    'offset-reset': 'videoShortcutOffsetReset',
    'copy-cue': 'videoShortcutCopyCue',
    'rate-down': 'videoShortcutRateDown',
    'rate-up': 'videoShortcutRateUp',
  };
  var rawSettings = Object.create(null);
  var bindings = Object.create(null);

  function applySettings(saved) {
    saved = saved || {};
    for (var k in saved) rawSettings[k] = saved[k];
    var legacyEnabled = rawSettings.videoShortcutsEnabled !== false;
    for (var action in bindingKeys) {
      var value = rawSettings[bindingKeys[action]];
      bindings[action] = typeof value === 'boolean' ? value : legacyEnabled;
    }
  }
  try {
    var keys = ['videoShortcutsEnabled'];
    for (var action in bindingKeys) keys.push(bindingKeys[action]);
    var p = chrome.storage.local.get(keys, applySettings);
    if (p && typeof p.then === 'function') p.then(applySettings, function () {});
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      var patch = {};
      var changed = false;
      if (changes.videoShortcutsEnabled) {
        patch.videoShortcutsEnabled = changes.videoShortcutsEnabled.newValue;
        changed = true;
      }
      for (var action in bindingKeys) {
        var key = bindingKeys[action];
        if (!changes[key]) continue;
        patch[key] = changes[key].newValue;
        changed = true;
      }
      if (changed) applySettings(patch);
    });
  } catch (_) {}

  function isEditable(t) {
    if (!t) return false;
    if (t.isContentEditable) return true;
    var tag = String(t.tagName || '').toUpperCase();
    return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
  }

  // 当前视频是否已有任一字幕轨（store key 前缀匹配，与 subtitle-panel 同一契约）。
  function hasTrackForVideo() {
    var store = window.fushiEpisodeCues;
    if (!store || typeof window.fushiVideoKey !== 'function') return false;
    var vid;
    try { vid = String(window.fushiVideoKey()); } catch (_) { return false; }
    if (!vid) return false;
    for (var k in store) {
      if (k.indexOf(vid + '|') === 0 && store[k] && store[k].length) return true;
    }
    return false;
  }

  function adjustRate(delta) {
    var v = document.querySelector('video');
    if (!v || typeof v.playbackRate !== 'number') return false;
    var next = api.nextRate(v.playbackRate, delta);
    try { v.playbackRate = next; } catch (_) { return false; }
    try {
      if (typeof window.fushiToast === 'function') window.fushiToast('播放速度 ' + next + 'x');
    } catch (_) {}
    return true;
  }

  // capture 阶段监听，接管时 stopPropagation 压过站点自己的键位（asb 同款策略）；
  // 未接管（decide 返回 null / 执行端没接住）绝不动事件，站点行为原样。
  window.addEventListener('keydown', function (e) {
    // 廉价预筛：绝大多数按键（无修饰的普通打字）直接跳过，不查 DOM。
    if (!e.shiftKey && !e.ctrlKey && !e.metaKey &&
        e.key !== 'ArrowLeft' && e.key !== 'ArrowRight' && e.key !== 'ArrowUp') {
      return;
    }
    var decision = api.decide(
      {
        key: e.key,
        code: e.code,
        ctrl: e.ctrlKey || e.metaKey,
        shift: e.shiftKey,
        alt: e.altKey,
        editable: isEditable(e.target),
      },
      {
        enabled: true,
        hasVideo: !!document.querySelector('video'),
        hasTrack: hasTrackForVideo(),
        bindings: bindings,
      });
    if (!decision) return;
    var handled = false;
    if (decision.action === 'rate-up') handled = adjustRate(0.25);
    else if (decision.action === 'rate-down') handled = adjustRate(-0.25);
    else if (typeof window.fushiSubtitleShortcut === 'function') {
      handled = window.fushiSubtitleShortcut(decision.action) === true;
    }
    if (handled) {
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);
})();
