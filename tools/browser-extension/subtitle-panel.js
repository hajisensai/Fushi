// TODO-1219 P2：Netflix 整集字幕列表面板（content script 隔离世界，manifest bundle 里排在
// content.js 之后加载）。消费 P1 拦截并存档到 window.hibikiEpisodeCues 的整集字幕，渲染成
// 近似 app 内 VideoSubtitleJumpPanel 的侧栏：头部标题 + 语言/轨切换 + A-/A+ 字号 + 自动滚动
// 开关 + 关闭；每行时间戳 + 文本 + 当前句高亮。行为：
//   · 时间戳点击 → 复用 P1 的 nfSeek（postMessage {__hibikiNf:'seek',ms}，走 Netflix 官方
//     player.seek，不触发 M7375，不碰 DRM）。
//   · 文本点击 → window.hibikiLookupAtPoint（content.js 暴露，复用同一套 hoshiSelection 取词
//     + 查词弹窗 hibikiRender）；文本保留真实 DOM，全局 mousemove+Shift 划词照常生效。
//   · 制卡入口 = 上述查词弹窗自带的「制卡」按钮（bridge-shim mineEntry → window.hibikiEnqueue，
//     携带真实词 fields + 句子），面板不再另造合成 fields 的行级按钮。行的精确 [startMs,endMs]
//     窗留给 P3（截图剪裁 + 精确窗覆盖 DOM 采样）。
//   · 当前句高亮 + 自动滚动：面板自持 200ms 计时器读 <video>.currentTime，对当前轨 cues 二分
//     命中当前句（精确窗，胜过 DOM 文本匹配），高亮对应行并（开启时）滚入视图。
// 面板只依赖 window.hibikiEpisodeCues / window.hibikiLookupAtPoint / postMessage 三个契约，
// 不跨文件依赖 content.js 的 const 词法作用域，Netflix DOM 抖动时降级为纯覆盖（不推挤）。
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  if (!/(^|\.)netflix\.com$/.test(location.hostname)) return;

  var PANEL_ID = 'hibiki-subtitle-panel';
  var REOPEN_ID = 'hibiki-subtitle-reopen';
  var PANEL_WIDTH = 320;
  var FONT_STEPS = [0.85, 1.0, 1.15, 1.3];
  var PUSH_SELECTORS = ['.watch-video--player-view', '.watch-video', '.nfp.nf-player-container', '#appMountPoint'];

  // TODO-1219：面板默认关闭——enabled 由扩展 options 的 netflixSubtitlePanel 开关驱动（默认 false）。
  var st = {
    activeLang: null, videoId: null, cues: [], rowEls: [], currentIndex: -1,
    autoScroll: true, fontScaleIndex: 1, hidden: false, panel: null, listEl: null,
    langSelect: null, builtLang: null, builtLen: -1, pushedEl: null, prevWidth: '', tickTimer: null,
    pushSuspended: false, enabled: false,
  };

  // ── TODO-1219：字幕列表面板开关（默认关）──
  // 面板不再默认打开：只有用户在扩展 options 勾选「Netflix 字幕列表」（chrome.storage.local 的
  // netflixSubtitlePanel === true）时才在 Netflix 播放页显示。键缺省或非 true 一律视为关闭，
  // 即什么都不挂（无面板、无重开小按钮）。options 里改动经 chrome.storage.onChanged 实时生效。
  var SETTING_KEY = 'netflixSubtitlePanel';
  function readEnabled(cb) {
    try {
      var p = chrome.storage.local.get(SETTING_KEY);
      if (p && typeof p.then === 'function') {
        p.then(function (c) { cb(!!(c && c[SETTING_KEY] === true)); }, function () { cb(false); });
      } else {
        chrome.storage.local.get(SETTING_KEY, function (c) { cb(!!(c && c[SETTING_KEY] === true)); });
      }
    } catch (_) { cb(false); }
  }
  function teardownAll() {
    clearPush();
    if (st.panel && st.panel.parentNode) st.panel.parentNode.removeChild(st.panel);
    hideReopen();
  }
  function applyEnabled(on) {
    st.enabled = !!on;
    if (!st.enabled) { teardownAll(); return; }
    try { if (window.hibikiEpisodeCues && tracksForVideo().length) showPanel(); } catch (_) {}
  }

  function nfVideoId() {
    var m = (location.pathname || '').match(/\/watch\/(\d+)/);
    return m ? m[1] : null;
  }
  function videoEl() { return document.querySelector('video'); }
  function videoTimeMs() {
    var v = videoEl();
    return v && typeof v.currentTime === 'number' ? Math.round(v.currentTime * 1000) : 0;
  }
  function fmtTs(ms) {
    var total = ms < 0 ? 0 : Math.floor(ms / 1000);
    var h = Math.floor(total / 3600);
    var m = Math.floor((total % 3600) / 60);
    var s = total % 60;
    var ss = s < 10 ? '0' + s : '' + s;
    if (h > 0) { var mm = m < 10 ? '0' + m : '' + m; return h + ':' + mm + ':' + ss; }
    return m + ':' + ss;
  }
  function resolveTheme() {
    return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  }

  function tracksForVideo() {
    var store = window.hibikiEpisodeCues || null;
    var vid = nfVideoId();
    var out = [];
    if (!store || !vid) return out;
    for (var key in store) {
      var sep = key.indexOf('|');
      if (sep < 0) continue;
      if (key.slice(0, sep) !== String(vid)) continue;
      var cues = store[key];
      if (cues && cues.length) out.push({ lang: key.slice(sep + 1), key: key, cues: cues });
    }
    out.sort(function (a, b) { return a.lang < b.lang ? -1 : (a.lang > b.lang ? 1 : 0); });
    return out;
  }

  function cueIndexAt(cues, t) {
    var lo = 0, hi = cues.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (ans < 0) return -1;
    return t < cues[ans].endMs ? ans : -1;
  }

  function parentForOverlay() { return document.fullscreenElement || document.body; }

  function seekTo(ms) {
    try { window.postMessage({ __hibikiNf: 'seek', ms: Math.max(0, Math.round(ms)) }, location.origin); } catch (_) {}
  }

  function applyPush() {
    // TODO-1219 P3：录制期间推挤被挂起（video 需全宽），此时不重挂（refresh/fullscreenchange 也不）。
    if (st.pushSuspended || st.pushedEl) return;
    for (var i = 0; i < PUSH_SELECTORS.length; i++) {
      var el = document.querySelector(PUSH_SELECTORS[i]);
      if (el) {
        st.pushedEl = el;
        st.prevWidth = el.style.width || '';
        el.style.width = 'calc(100% - ' + PANEL_WIDTH + 'px)';
        return;
      }
    }
  }
  function clearPush() {
    if (!st.pushedEl) return;
    try { st.pushedEl.style.width = st.prevWidth; } catch (_) {}
    st.pushedEl = null;
    st.prevWidth = '';
  }

  function buildPanel() {
    var panel = document.createElement('div');
    panel.id = PANEL_ID;
    panel.setAttribute('data-theme', resolveTheme());
    panel.style.width = PANEL_WIDTH + 'px';

    var header = document.createElement('div');
    header.className = 'hibiki-sub-header';

    var titleRow = document.createElement('div');
    titleRow.className = 'hibiki-sub-title-row';

    var title = document.createElement('div');
    title.className = 'hibiki-sub-title';
    title.textContent = '字幕列表';
    titleRow.appendChild(title);

    function iconBtn(label, tip, onClick) {
      var b = document.createElement('button');
      b.className = 'hibiki-sub-iconbtn';
      b.type = 'button';
      b.textContent = label;
      b.title = tip;
      b.addEventListener('click', function (e) { e.stopPropagation(); onClick(b); });
      return b;
    }
    var smaller = iconBtn('A-', '缩小字号', function () { stepFont(-1); });
    var larger = iconBtn('A+', '放大字号', function () { stepFont(1); });
    var autoBtn = iconBtn('AS', '自动滚动到当前句', function () { toggleAutoScroll(autoBtn); });
    autoBtn.classList.toggle('is-on', st.autoScroll);
    var closeBtn = iconBtn('X', '关闭', function () { hidePanel(); });
    titleRow.appendChild(smaller);
    titleRow.appendChild(larger);
    titleRow.appendChild(autoBtn);
    titleRow.appendChild(closeBtn);
    header.appendChild(titleRow);

    var langSelect = document.createElement('select');
    langSelect.className = 'hibiki-sub-lang';
    langSelect.addEventListener('change', function () {
      st.activeLang = langSelect.value;
      st.builtLang = null;
      refresh();
    });
    st.langSelect = langSelect;
    header.appendChild(langSelect);

    panel.appendChild(header);

    var list = document.createElement('div');
    list.className = 'hibiki-sub-list';
    panel.appendChild(list);
    st.listEl = list;

    st.panel = panel;
    applyFontScale();
    return panel;
  }

  function stepFont(delta) {
    var next = Math.max(0, Math.min(FONT_STEPS.length - 1, st.fontScaleIndex + delta));
    if (next === st.fontScaleIndex) return;
    st.fontScaleIndex = next;
    applyFontScale();
  }
  function applyFontScale() {
    if (st.panel) st.panel.style.setProperty('--hibiki-sub-font-scale', String(FONT_STEPS[st.fontScaleIndex]));
  }
  function toggleAutoScroll(btn) {
    st.autoScroll = !st.autoScroll;
    if (btn) btn.classList.toggle('is-on', st.autoScroll);
    if (st.autoScroll) { st.currentIndex = -1; tick(); }
  }

  function refreshLangSelect(tracks) {
    var sel = st.langSelect;
    if (!sel) return;
    var want = st.activeLang;
    var haveWant = false;
    for (var i = 0; i < tracks.length; i++) if (tracks[i].lang === want) haveWant = true;
    if (!haveWant) { st.activeLang = tracks.length ? tracks[0].lang : null; }
    var sig = tracks.map(function (t) { return t.lang; }).join(',');
    if (sel.getAttribute('data-sig') !== sig) {
      sel.textContent = '';
      for (var j = 0; j < tracks.length; j++) {
        var o = document.createElement('option');
        o.value = tracks[j].lang;
        o.textContent = tracks[j].lang;
        sel.appendChild(o);
      }
      sel.setAttribute('data-sig', sig);
    }
    sel.value = st.activeLang || '';
    sel.style.display = tracks.length > 1 ? '' : 'none';
  }

  function rebuildList(tracks) {
    var active = null;
    for (var i = 0; i < tracks.length; i++) if (tracks[i].lang === st.activeLang) active = tracks[i];
    st.cues = active ? active.cues : [];
    if (st.builtLang === st.activeLang && st.builtLen === st.cues.length) return;
    var list = st.listEl;
    if (!list) return;
    list.textContent = '';
    st.rowEls = [];
    st.currentIndex = -1;
    if (!st.cues.length) {
      var empty = document.createElement('div');
      empty.className = 'hibiki-sub-empty';
      empty.textContent = '暂无整集字幕（切到有字幕的剧集或语言后自动出现）';
      list.appendChild(empty);
      st.builtLang = st.activeLang;
      st.builtLen = 0;
      return;
    }
    var frag = document.createDocumentFragment();
    for (var k = 0; k < st.cues.length; k++) {
      frag.appendChild(buildRow(st.cues[k], k));
    }
    list.appendChild(frag);
    st.builtLang = st.activeLang;
    st.builtLen = st.cues.length;
  }

  function buildRow(cue, idx) {
    var row = document.createElement('div');
    row.className = 'hibiki-sub-row';

    var ts = document.createElement('button');
    ts.className = 'hibiki-sub-ts';
    ts.type = 'button';
    ts.textContent = fmtTs(cue.startMs);
    ts.title = '跳转到此句';
    ts.addEventListener('click', function (e) { e.stopPropagation(); seekTo(cue.startMs); });
    row.appendChild(ts);

    var text = document.createElement('div');
    text.className = 'hibiki-sub-text';
    text.textContent = cue.text;
    text.addEventListener('click', function (e) {
      e.stopPropagation();
      if (typeof window.hibikiLookupAtPoint === 'function') {
        // TODO-1219 P3：带上该行整集拦截的精确窗，制卡（hibikiEnqueue）用它而非 DOM 采样。
        window.hibikiLookupAtPoint(e.clientX, e.clientY, { startMs: cue.startMs, endMs: cue.endMs, text: cue.text });
      } else {
        seekTo(cue.startMs);
      }
    });
    row.appendChild(text);

    st.rowEls[idx] = row;
    return row;
  }

  function tick() {
    if (!st.panel || st.hidden || !st.cues.length) return;
    var idx = cueIndexAt(st.cues, videoTimeMs());
    if (idx === st.currentIndex) return;
    var prev = st.rowEls[st.currentIndex];
    if (prev) prev.classList.remove('is-current');
    st.currentIndex = idx;
    var cur = st.rowEls[idx];
    if (cur) {
      cur.classList.add('is-current');
      if (st.autoScroll) {
        try { cur.scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (_) { cur.scrollIntoView(); }
      }
    }
  }

  function ensureMounted() {
    if (!st.panel) buildPanel();
    var parent = parentForOverlay();
    if (st.panel.parentNode !== parent) parent.appendChild(st.panel);
    st.panel.setAttribute('data-theme', resolveTheme());
    applyPush();
    hideReopen();
  }
  function showPanel() {
    st.hidden = false;
    ensureMounted();
    refresh();
  }
  function hidePanel() {
    st.hidden = true;
    clearPush();
    if (st.panel && st.panel.parentNode) st.panel.parentNode.removeChild(st.panel);
    showReopen();
  }

  function showReopen() {
    var chip = document.getElementById(REOPEN_ID);
    var parent = parentForOverlay();
    if (!chip) {
      chip = document.createElement('button');
      chip.id = REOPEN_ID;
      chip.type = 'button';
      chip.textContent = '字幕';
      chip.title = '打开字幕列表';
      chip.addEventListener('click', function (e) { e.stopPropagation(); showPanel(); });
    }
    chip.setAttribute('data-theme', resolveTheme());
    if (chip.parentNode !== parent) parent.appendChild(chip);
  }
  function hideReopen() {
    var chip = document.getElementById(REOPEN_ID);
    if (chip && chip.parentNode) chip.parentNode.removeChild(chip);
  }

  function refresh() {
    if (st.hidden) return;
    st.videoId = nfVideoId();
    var tracks = tracksForVideo();
    ensureMounted();
    refreshLangSelect(tracks);
    rebuildList(tracks);
    st.currentIndex = -1;
    tick();
  }

  // TODO-1219 P3：Netflix 批量录制（content.js hibikiRunNetflixBatch）录整标签页前调用，撤销推挤让
  // 播放器全宽（录制画面不带面板黑边）；录完调 resume 重挂。挂起期间 applyPush 被 pushSuspended 门控。
  window.hibikiSubtitlePanelSuspendPush = function () {
    st.pushSuspended = true;
    clearPush();
  };
  window.hibikiSubtitlePanelResumePush = function () {
    st.pushSuspended = false;
    if (!st.hidden && st.panel && st.panel.parentNode) applyPush();
  };

  window.hibikiSubtitlePanelOnCues = function (_key) {
    if (!st.enabled) return;
    if (st.hidden) { showReopen(); return; }
    refresh();
  };

  document.addEventListener('fullscreenchange', function () {
    if (!st.enabled) return;
    clearPush();
    if (st.hidden) { if (document.getElementById(REOPEN_ID)) showReopen(); return; }
    ensureMounted();
  });

  var lastPath = location.pathname;
  setInterval(function () {
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      st.builtLang = null; st.builtLen = -1; st.activeLang = null;
      if (st.enabled && !st.hidden) refresh();
    }
  }, 500);

  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes || !changes[SETTING_KEY]) return;
      applyEnabled(changes[SETTING_KEY].newValue === true);
    });
  } catch (_) {}

  st.tickTimer = setInterval(tick, 200);

  // 默认关：读取开关，仅在开启（且已有整集字幕）时才自动显示面板。
  readEnabled(applyEnabled);
})();
