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
// 上面是**默认**键位；每个动作的组合键可在设置页「快捷键」里改（videoShortcutKeys）。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) root.FUSHI_VIDEO_SHORTCUTS = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';
  function tr(key, params) {
    return (typeof window !== 'undefined' && typeof window.fushiT === 'function') ? window.fushiT(key, params) : key;
  }

  // ── 可自定义的组合键（用户群 10-09「快捷键可自定义」）──
  // 组合键的规范串：修饰键按 Ctrl → Alt → Shift 固定顺序 + 一个布局无关的 KeyboardEvent.code，
  // 如 'Ctrl+Shift+ArrowLeft'、'Shift+KeyH'、'ArrowUp'。Meta（⌘）与 Ctrl 同义（沿用旧判定）。
  // 存储：`videoShortcutKeys` = {action: combo}，只存用户改过的；缺省回落 DEFAULT_COMBOS。
  // 每个动作的独立开关（videoShortcut*）仍是唯一的「关」——自定义只换键，不另起一套开关语义。
  var KEYS_SETTING = 'videoShortcutKeys';
  var DEFAULT_COMBOS = {
    'prev-cue': 'ArrowLeft',
    'next-cue': 'ArrowRight',
    'replay-cue': 'ArrowUp',
    'toggle-panel': 'Shift+KeyS',
    'toggle-subtitle-hide': 'Shift+KeyH',
    'offset-minus': 'Ctrl+Shift+ArrowLeft',
    'offset-plus': 'Ctrl+Shift+ArrowRight',
    'offset-reset': 'Ctrl+Shift+ArrowDown',
    'copy-cue': 'Ctrl+Shift+KeyZ',
    'rate-down': 'Ctrl+Shift+BracketLeft',
    'rate-up': 'Ctrl+Shift+BracketRight',
  };
  var ACTIONS = Object.keys(DEFAULT_COMBOS);
  // 需要「这个视频有 Fushi 字幕轨」才接管的动作（没轨时放行给站点：←/→ 是站点自己的 5s 快进）。
  // 隐藏字幕 / 变速与轨无关（见 Shift+H 的说明：它藏的是站点原生字幕）。
  var NEEDS_TRACK = {
    'prev-cue': 1, 'next-cue': 1, 'replay-cue': 1, 'toggle-panel': 1,
    'offset-minus': 1, 'offset-plus': 1, 'offset-reset': 1, 'copy-cue': 1,
  };
  // 不能单独当快捷键的键：修饰键本身。
  var MODIFIER_CODES = {
    ControlLeft: 1, ControlRight: 1, ShiftLeft: 1, ShiftRight: 1, AltLeft: 1, AltRight: 1,
    MetaLeft: 1, MetaRight: 1, OSLeft: 1, OSRight: 1, CapsLock: 1, Fn: 1,
  };

  // 能当主键的 KeyboardEvent.code（布局无关的物理键名）。不在表里的（媒体键、输入法键、
  // 存储里写歪的串）一律不成立，免得录进一个永远按不出来的组合。
  var TOKEN_RE = new RegExp('^(Key[A-Z]|Digit[0-9]|Numpad[A-Za-z0-9]+|F([1-9]|1[0-9]|2[0-4])|' +
    'Arrow(Left|Right|Up|Down)|Home|End|PageUp|PageDown|Insert|Delete|Backspace|Enter|Escape|' +
    'Space|Tab|Backquote|Minus|Equal|BracketLeft|BracketRight|Backslash|Semicolon|Quote|Comma|' +
    'Period|Slash|IntlBackslash|IntlRo|IntlYen|ContextMenu|Pause)$');

  // 事件里的「主键」：优先 code（布局无关）；只给了 key 的方向键（旧调用方 / 测试）回落 key。
  function eventToken(ev) {
    var code = ev && ev.code ? String(ev.code) : '';
    if (code) return code;
    var key = ev && ev.key ? String(ev.key) : '';
    return /^Arrow(Left|Right|Up|Down)$/.test(key) ? key : '';
  }

  // ev = {key, code, ctrl, shift, alt} → 规范组合串；纯修饰键 / 取不到主键返回 ''。
  function comboFromEvent(ev) {
    var token = eventToken(ev);
    if (!token || MODIFIER_CODES[token] || !TOKEN_RE.test(token)) return '';
    var parts = [];
    if (ev.ctrl) parts.push('Ctrl');
    if (ev.alt) parts.push('Alt');
    if (ev.shift) parts.push('Shift');
    parts.push(token);
    return parts.join('+');
  }

  // 存储里的组合串规整成规范形（修饰键排序、去重）；不成立返回 ''。
  function normalizeCombo(raw) {
    if (typeof raw !== 'string' || !raw) return '';
    var segs = raw.split('+');
    var token = segs.pop();
    if (!token || !TOKEN_RE.test(token)) return '';
    var mods = { Ctrl: false, Alt: false, Shift: false };
    for (var i = 0; i < segs.length; i++) {
      if (!Object.prototype.hasOwnProperty.call(mods, segs[i])) return '';
      mods[segs[i]] = true;
    }
    return comboFromEvent({ code: token, ctrl: mods.Ctrl, alt: mods.Alt, shift: mods.Shift });
  }

  // 生效的动作 → 组合键表：默认表叠用户覆盖（非法覆盖忽略，回落默认）。
  function resolveCombos(custom) {
    var out = {};
    for (var i = 0; i < ACTIONS.length; i++) {
      var a = ACTIONS[i];
      var c = custom && typeof custom === 'object' ? normalizeCombo(custom[a]) : '';
      out[a] = c || DEFAULT_COMBOS[a];
    }
    return out;
  }

  // 录入新组合前查重：返回已占用该组合的**其它**动作名，没有返回 ''。
  function conflictOf(combos, action, combo) {
    for (var a in combos) {
      if (a !== action && combos[a] === combo) return a;
    }
    return '';
  }

  // 给人看的组合键文字（设置页 / 提示）：方向键画成箭头，KeyZ → Z，Digit1 → 1，括号还原成符号。
  var TOKEN_LABELS = {
    ArrowLeft: '←', ArrowRight: '→', ArrowUp: '↑', ArrowDown: '↓',
    BracketLeft: '[', BracketRight: ']', Backslash: '\\', Semicolon: ';', Quote: "'",
    Comma: ',', Period: '.', Slash: '/', Minus: '-', Equal: '=', Backquote: '`',
    Space: 'Space', Enter: 'Enter', Escape: 'Esc', Backspace: 'Backspace', Tab: 'Tab',
  };
  function formatCombo(combo) {
    var c = normalizeCombo(combo);
    if (!c) return '';
    var segs = c.split('+');
    var token = segs.pop();
    var label = TOKEN_LABELS[token] ||
      (/^Key[A-Z]$/.test(token) ? token.slice(3) : (/^Digit\d$/.test(token) ? token.slice(5) :
        (/^Numpad/.test(token) ? 'Num ' + token.slice(6) : token)));
    segs.push(label);
    return segs.join('+');
  }

  // 纯函数按键判定。ev = {key, code, ctrl, shift, alt, editable}；
  // ctx = {enabled, hasVideo, hasTrack, bindings?, combos?}。返回 {action} 或 null（null = 不接管，放行给站点）。
  function decide(ev, ctx) {
    if (!ev || !ctx || !ctx.enabled || ev.editable || !ctx.hasVideo) return null;
    var combo = comboFromEvent(ev);
    if (!combo) return null;
    var combos = ctx.combos || DEFAULT_COMBOS;
    for (var i = 0; i < ACTIONS.length; i++) {
      var action = ACTIONS[i];
      if (combos[action] !== combo) continue;
      if (ctx.bindings && ctx.bindings[action] === false) return null;
      if (NEEDS_TRACK[action] && !ctx.hasTrack) return null;
      return { action: action };
    }
    return null;
  }

  // 播放速度步进（clamp 0.25–4，步长由调用方传）。返回 clamp 后的新值。
  function nextRate(current, delta) {
    var cur = typeof current === 'number' && current > 0 ? current : 1;
    return Math.round(Math.min(4, Math.max(0.25, cur + delta)) * 100) / 100;
  }

  return {
    decide: decide,
    nextRate: nextRate,
    comboFromEvent: comboFromEvent,
    normalizeCombo: normalizeCombo,
    resolveCombos: resolveCombos,
    conflictOf: conflictOf,
    formatCombo: formatCombo,
    DEFAULT_COMBOS: DEFAULT_COMBOS,
    KEYS_SETTING: KEYS_SETTING,
  };
});

// ── 浏览器运行时（node 单测里 window/document 缺省 → 整段跳过）──
(function () {
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  // 设置页（扩展自己的页面）只借用上面的纯函数做改键录入，不挂视频页键盘监听。
  if (typeof location !== 'undefined' && location && location.protocol === 'chrome-extension:') return;
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
  var combos = api.resolveCombos(null);
  var comboSet = Object.create(null);
  function rebuildComboSet() {
    comboSet = Object.create(null);
    for (var a in combos) comboSet[combos[a]] = true;
  }
  rebuildComboSet();

  function applySettings(saved) {
    saved = saved || {};
    for (var k in saved) rawSettings[k] = saved[k];
    var legacyEnabled = rawSettings.videoShortcutsEnabled !== false;
    for (var action in bindingKeys) {
      var value = rawSettings[bindingKeys[action]];
      bindings[action] = typeof value === 'boolean' ? value : legacyEnabled;
    }
    combos = api.resolveCombos(rawSettings[api.KEYS_SETTING]);
    rebuildComboSet();
  }
  try {
    var keys = ['videoShortcutsEnabled', api.KEYS_SETTING];
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
      if (changes[api.KEYS_SETTING]) {
        patch[api.KEYS_SETTING] = changes[api.KEYS_SETTING].newValue;
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
      if (typeof window.fushiToast === 'function') window.fushiToast(tr('playback_rate_toast', { rate: next }));
    } catch (_) {}
    return true;
  }

  // capture 阶段监听，接管时 stopPropagation 压过站点自己的键位（asb 同款策略）；
  // 未接管（decide 返回 null / 执行端没接住）绝不动事件，站点行为原样。
  window.addEventListener('keydown', function (e) {
    // 廉价预筛：组合键不在当前绑定表里的（绝大多数普通打字）直接跳过，不查 DOM。
    var pre = api.comboFromEvent({
      key: e.key, code: e.code, ctrl: e.ctrlKey || e.metaKey, shift: e.shiftKey, alt: e.altKey,
    });
    if (!pre || !comboSet[pre]) return;
    // Shadow DOM 里的编辑器：e.target 被 retarget 成宿主自定义元素，isEditable 会误判 false，
    // Ctrl+Shift+Z（编辑器重做）等会被快捷键抢走。composedPath()[0] 才是真实目标。
    var realTarget = e.target;
    try {
      if (typeof e.composedPath === 'function') {
        var path = e.composedPath();
        if (path && path.length) realTarget = path[0];
      }
    } catch (_) {}
    var decision = api.decide(
      {
        key: e.key,
        code: e.code,
        ctrl: e.ctrlKey || e.metaKey,
        shift: e.shiftKey,
        alt: e.altKey,
        editable: isEditable(realTarget),
      },
      {
        enabled: true,
        hasVideo: !!document.querySelector('video'),
        hasTrack: hasTrackForVideo(),
        bindings: bindings,
        combos: combos,
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
