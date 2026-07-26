// asb 移植：视频页快捷键（content script 隔离世界，manifest bundle 里排在 subtitle-panel.js
// 之后加载）。键位与 asbplayer 默认键对齐（差异见 README「快捷键」表）：
//   ←/→        上一句 / 下一句字幕（仅当前视频有字幕轨时接管，否则放行给站点）
//   ↑           回当前句句首重播
//   Shift+P/O/F 开关 自动暂停 / 精简播放 / 快进无字幕段
//   Shift+S     开关字幕列表面板
//   Ctrl+Shift+←/→/↓  字幕时轴偏移 −100ms / ＋100ms / 重置
//   Ctrl+Shift+Z      复制当前字幕句到剪贴板（配合 Hibiki 剪贴板监看即查词）
//   Ctrl+Shift+[ / ]  播放速度 −0.25x / ＋0.25x
// 判定是纯函数 decide()（node 可测）；执行端是 subtitle-panel.js 暴露的
// window.hibikiSubtitleShortcut(action)（面板持有轨/偏移/模式状态），播放速度直接操作 <video>。
// 输入框/可编辑区一律放行；options 的 videoShortcutsEnabled（默认开）可整体关闭。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) root.HIBIKI_VIDEO_SHORTCUTS = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 纯函数按键判定。ev = {key, code, ctrl, shift, alt, editable}；
  // ctx = {enabled, hasVideo, hasTrack}。返回 {action} 或 null（null = 不接管，放行给站点）。
  function decide(ev, ctx) {
    if (!ev || !ctx || !ctx.enabled || ev.editable || !ctx.hasVideo) return null;
    if (ev.alt) return null;
    var key = ev.key || '';
    var code = ev.code || '';
    if (ev.ctrl && ev.shift) {
      if (key === 'ArrowLeft') return ctx.hasTrack ? { action: 'offset-minus' } : null;
      if (key === 'ArrowRight') return ctx.hasTrack ? { action: 'offset-plus' } : null;
      if (key === 'ArrowDown') return ctx.hasTrack ? { action: 'offset-reset' } : null;
      if (code === 'KeyZ') return ctx.hasTrack ? { action: 'copy-cue' } : null;
      // 括号键在 Shift 下 e.key 会变成 '{' / '}'，用布局无关的 e.code。
      if (code === 'BracketLeft') return { action: 'rate-down' };
      if (code === 'BracketRight') return { action: 'rate-up' };
      return null;
    }
    if (ev.ctrl) return null;
    if (ev.shift) {
      if (code === 'KeyP') return { action: 'toggle-autopause' };
      if (code === 'KeyO') return { action: 'toggle-condensed' };
      if (code === 'KeyF') return { action: 'toggle-fastforward' };
      if (code === 'KeyS') return { action: 'toggle-panel' };
      return null;
    }
    if (key === 'ArrowLeft') return ctx.hasTrack ? { action: 'prev-cue' } : null;
    if (key === 'ArrowRight') return ctx.hasTrack ? { action: 'next-cue' } : null;
    if (key === 'ArrowUp') return ctx.hasTrack ? { action: 'replay-cue' } : null;
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
  var api = (typeof self !== 'undefined' ? self : window).HIBIKI_VIDEO_SHORTCUTS;
  var enabled = true;

  function applyEnabled(saved) {
    // 缺省/非 false 一律视为开启（默认开）。
    enabled = !(saved && saved.videoShortcutsEnabled === false);
  }
  try {
    var p = chrome.storage.local.get('videoShortcutsEnabled');
    if (p && typeof p.then === 'function') p.then(applyEnabled, function () {});
    else chrome.storage.local.get('videoShortcutsEnabled', applyEnabled);
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes || !changes.videoShortcutsEnabled) return;
      enabled = changes.videoShortcutsEnabled.newValue !== false;
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
    var store = window.hibikiEpisodeCues;
    if (!store || typeof window.hibikiVideoKey !== 'function') return false;
    var vid;
    try { vid = String(window.hibikiVideoKey()); } catch (_) { return false; }
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
      if (typeof window.hibikiToast === 'function') window.hibikiToast('播放速度 ' + next + 'x');
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
        enabled: enabled,
        hasVideo: !!document.querySelector('video'),
        hasTrack: hasTrackForVideo(),
      });
    if (!decision) return;
    var handled = false;
    if (decision.action === 'rate-up') handled = adjustRate(0.25);
    else if (decision.action === 'rate-down') handled = adjustRate(-0.25);
    else if (typeof window.hibikiSubtitleShortcut === 'function') {
      handled = window.hibikiSubtitleShortcut(decision.action) === true;
    }
    if (handled) {
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);
})();
