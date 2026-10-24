// Fushi 应用内浏览器 · YouTube 页面内可点字幕（取词走浏览页现有查词链路）。
//
// 注入顺序（同一个 document-start 脚本块里，按 YouTube 主机守卫，见
// lib/src/web_browser/features/youtube_subtitles/youtube_subtitles_scripts.dart）：
//   youtube-bridge.js → subtitle-adapters.js → subtitle-providers.js → 本文件。
// 前三样与浏览器扩展 / 内置网页播放器**逐字节同一份**（assets/browser_extension/ 镜像，由
// browser_extension_mirror_full_guard_test 守住），负责把 YouTube 整轨字幕抓进
// window.fushiEpisodeCues。本文件只做「消费 store」那一半：选一条轨，按 <video> 当前时间
// 把当前句画在播放器里，点字时调浏览页已装好的阅读器选区脚本（window.fushiSelection）取词，
// 由它照常投 callHandler('onTextSelected')。本脚本不查词、不改站点 DOM 的其它部分。
//
// 纯逻辑（chooseTrackKey / cueAt）挂在 __fushiYtSubs._pure 供 node 测试。
(function () {
  'use strict';
  if (window.__fushiYtSubs) return;

  var EL_ID = 'fushi-yt-subtitle';
  var HIDE_NATIVE_ID = 'fushi-yt-hide-native-subtitles';
  // visibility 而非 display：providers 的 DOM 采样（live 轨）要继续读得到站点字幕文本。
  var HIDE_NATIVE_CSS =
    '.ytp-caption-window-container,.captions-text,.caption-window' +
    '{visibility:hidden !important}';
  var LIVE_LANG = 'live';
  var TAP_SLOP_PX = 12;

  var st = {
    enabled: false, lang: '', videoKey: '', key: null, cues: [], cue: undefined, requested: {},
    el: null, line: null, timer: null, downX: 0, downY: 0, down: false,
  };

  // ── 纯逻辑 ──────────────────────────────────────────────────────────────

  function langOf(key) {
    var sep = key.indexOf('|');
    var seg = sep >= 0 ? key.slice(sep + 1) : '';
    var tilde = seg.indexOf('~');
    return tilde >= 0 ? seg.slice(0, tilde) : seg;
  }

  // ── 选轨 ──
  // 不能信 store 的登记顺序：youtube-bridge 按「当前音轨默认字幕轨 → 音轨同语言 → 人工轨」
  // 排序，但 m.youtube.com 上拿不到音轨语言 / 默认轨（runtime 轨为空，走 android 接口兜底），
  // 排序退化成 YouTube 的语言名字母序——德语人工轨排第一、还被急取，页内字幕显示德语。
  // 这里自己排：① 用户的学习语言（Dart 经 setEnabled 下发）② 原声（音轨默认轨 / 与自动
  // 字幕同语言——YouTube 只给口语语言生成自动字幕）③ 其余人工轨 ④ 英文 ⑤ 其余；同档人工轨
  // 先于自动轨，再按登记顺序。首选轨还是占位（没 cue）时由 reselect 请桥按需取，取到前先
  // 显示已有的次优轨。

  var ASR_RE = /auto|自动/i; // bridge 的 trackLabel 保证自动轨标签含其一

  function primaryLang(code) {
    return String(code || '').toLowerCase().split(/[-_]/)[0];
  }

  // 标签去掉末尾括注（「English (United States)」「日本語 (自動生成) (自动)」）后的语言名。
  function baseName(label) {
    var s = String(label || '').trim();
    for (var i = 0; i < 4; i++) {
      var next = s.replace(/\s*[(（][^()（）]*[)）]\s*$/, '');
      if (next === s) break;
      s = next;
    }
    return s.trim().toLowerCase();
  }

  // 语言码 code 在若干界面语言下的名字（「ja」→ 日本語 / Japanese / Japanisch …）。
  function langNames(code, uiLangs) {
    var names = [];
    var c = primaryLang(code);
    if (!c) return names;
    names.push(c);
    var locales = [c].concat(uiLangs || [], ['en']);
    for (var i = 0; i < locales.length; i++) {
      try {
        var n = new Intl.DisplayNames([locales[i]], { type: 'language' }).of(c);
        if (n && n !== c) names.push(String(n).toLowerCase());
      } catch (_) {}
    }
    return names;
  }

  // 标签所属语言是不是 code：页面给了这条轨的元数据就按语言码，否则按语言名比标签。
  function labelIsLang(label, code, opts) {
    var c = primaryLang(code);
    if (!c) return false;
    var meta = opts && opts.meta && opts.meta[label];
    if (meta && meta.lang) return meta.lang === c;
    var base = baseName(label);
    var names = langNames(c, opts && opts.uiLangs);
    for (var i = 0; i < names.length; i++) {
      if (base === names[i] || base.indexOf(names[i] + ' ') === 0) return true;
    }
    return false;
  }

  function isAsr(label, opts) {
    var meta = opts && opts.meta && opts.meta[label];
    if (meta && typeof meta.asr === 'boolean') return meta.asr;
    return ASR_RE.test(label);
  }

  // 当前视频的整轨（不含 live）按优先级排好的 key 列表，含还没取的占位轨。
  function rankTrackKeys(store, videoKey, opts) {
    if (!store || !videoKey) return [];
    var prefix = videoKey + '|';
    var keys = Object.keys(store).filter(function (k) {
      return k.indexOf(prefix) === 0 && Array.isArray(store[k]) && langOf(k) !== LIVE_LANG;
    });
    var labels = keys.map(function (k) { return k.slice(prefix.length); });
    // 原声：页面元数据里的默认轨 / 其语言；否则自动字幕轨的语言名。
    var origLang = '';
    var origBase = '';
    for (var i = 0; i < labels.length; i++) {
      var m = opts && opts.meta && opts.meta[labels[i]];
      if (m && m.def && m.lang) { origLang = m.lang; break; }
    }
    if (!origLang) {
      for (var j = 0; j < labels.length; j++) {
        if (!isAsr(labels[j], opts)) continue;
        var am = opts && opts.meta && opts.meta[labels[j]];
        if (am && am.lang) origLang = am.lang; else origBase = baseName(labels[j]);
        break;
      }
    }
    var target = primaryLang(opts && opts.lang);
    function rank(label) {
      var asr = isAsr(label, opts) ? 1 : 0;
      if (target && labelIsLang(label, target, opts)) return asr;
      var meta = opts && opts.meta && opts.meta[label];
      var original = (meta && meta.def) ||
        (origLang ? labelIsLang(label, origLang, opts) : (origBase && baseName(label) === origBase));
      if (original) return 2 + asr;
      if (!asr) return 4;
      if (labelIsLang(label, 'en', opts)) return 5;
      return 6;
    }
    return keys
      .map(function (k, i) { return { k: k, i: i, r: rank(labels[i]) }; })
      .sort(function (a, b) { return a.r - b.r || a.i - b.i; })
      .map(function (e) { return e.k; });
  }

  // 优先级最高的轨（可能还是占位、没有 cue）；没有整轨 → null。
  function preferredTrackKey(store, videoKey, opts) {
    var ranked = rankTrackKeys(store, videoKey, opts);
    return ranked.length ? ranked[0] : null;
  }

  // 选当前视频要显示的轨：首选轨有 cue 就用它；首选还在取时，当前轨仍有效就保持（不来回
  // 跳），否则按优先级取第一条有 cue 的整轨；没有整轨才用 DOM 采样的 live 轨。都没有 → null。
  function chooseTrackKey(store, videoKey, current, opts) {
    if (!store || !videoKey) return null;
    var prefix = videoKey + '|';
    var hasCues = function (k) {
      var v = store[k];
      return Array.isArray(v) && v.length > 0;
    };
    var ranked = rankTrackKeys(store, videoKey, opts);
    if (ranked.length && hasCues(ranked[0])) return ranked[0];
    if (current && current.indexOf(prefix) === 0 && hasCues(current)) return current;
    for (var i = 0; i < ranked.length; i++) {
      if (hasCues(ranked[i])) return ranked[i];
    }
    var keys = Object.keys(store);
    for (var j = 0; j < keys.length; j++) {
      var k = keys[j];
      if (k.indexOf(prefix) === 0 && langOf(k) === LIVE_LANG && hasCues(k)) return k;
    }
    return null;
  }

  // cues 按 startMs 升序（providers 保证）；取覆盖 ms 的那条。
  function cueAt(cues, ms) {
    if (!cues || !cues.length) return null;
    var lo = 0, hi = cues.length - 1, idx = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= ms) { idx = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (idx < 0) return null;
    var c = cues[idx];
    return c.endMs > ms ? c : null;
  }

  // ── DOM ─────────────────────────────────────────────────────────────────

  function videoEl() {
    return document.querySelector('video.html5-main-video') || document.querySelector('video');
  }

  function playerOf(video) {
    if (!video) return null;
    return (video.closest && video.closest('.html5-video-player')) ||
      document.getElementById('movie_player') || video.parentElement;
  }

  function currentVideoKey() {
    try {
      if (typeof window.fushiVideoKey === 'function') return String(window.fushiVideoKey() || '');
    } catch (_) {}
    return '';
  }

  // 与 youtube-bridge 的 trackLabel 同一规则（store key 的 lang 段就是它），用来把页面自带的
  // 轨元数据（语言码 / 是否自动 / 是否音轨默认轨）对回 store 的标签。
  function trackLabel(track) {
    var label = track && track.name && (
      track.name.simpleText || (track.name.runs && track.name.runs[0] && track.name.runs[0].text)
    );
    label = label || track.displayName || track.languageName || track.languageCode || 'und';
    if (track.kind === 'asr' && !/auto|自动/i.test(label)) label += ' (自动)';
    return String(label).replace(/\|/g, '_');
  }

  // 页面能读到的字幕轨元数据：label → {lang, asr, def}。读不到（m.youtube.com 常见）→ {}，
  // 选轨退回按语言名比标签。
  function pageTrackMeta(videoKey) {
    var out = {};
    function add(tracks, defIdx) {
      if (!Array.isArray(tracks)) return;
      for (var i = 0; i < tracks.length; i++) {
        var t = tracks[i];
        if (!t) continue;
        var label = trackLabel(t);
        if (out[label]) continue;
        out[label] = {
          lang: primaryLang(t.languageCode),
          asr: t.kind === 'asr',
          def: i === defIdx || t.isDefault === true,
        };
      }
    }
    var id = videoKey.indexOf('yt-') === 0 ? videoKey.slice(3) : '';
    try {
      var player = document.getElementById('movie_player');
      var data = player && player.getVideoData && player.getVideoData();
      var audio = player && player.getAudioTrack && player.getAudioTrack();
      if (audio && (!data || !data.video_id || data.video_id === id)) {
        add(audio.captionTracks, typeof audio.defaultCaptionTrackIndex === 'number' ? audio.defaultCaptionTrackIndex : -1);
      }
    } catch (_) {}
    try {
      var response = window.ytInitialPlayerResponse;
      var details = response && response.videoDetails;
      var renderer = response && response.captions && response.captions.playerCaptionsTracklistRenderer;
      if (renderer && details && details.videoId === id) add(renderer.captionTracks, -1);
    } catch (_) {}
    return out;
  }

  function uiLangs() {
    var out = [];
    try { if (document.documentElement && document.documentElement.lang) out.push(document.documentElement.lang); } catch (_) {}
    try { if (navigator.language) out.push(navigator.language); } catch (_) {}
    return out;
  }

  function setNativeHidden(hidden) {
    var el = document.getElementById(HIDE_NATIVE_ID);
    if (hidden && !el) {
      el = document.createElement('style');
      el.id = HIDE_NATIVE_ID;
      el.textContent = HIDE_NATIVE_CSS;
      (document.head || document.documentElement).appendChild(el);
    } else if (!hidden && el) {
      el.remove();
    }
  }

  // 点按取词：浏览页的取词门控（window.__fushiSrsLookup，由 Dart 下发）关着、或查词弹窗开着时
  // 不取（弹窗开着时点按交给 Flutter 的 dismiss barrier）。
  function lookupAt(x, y) {
    var gate = window.__fushiSrsLookup || {};
    if (!gate.tap || gate.open) return;
    var sel = window.fushiSelection;
    if (sel && typeof sel.selectText === 'function') sel.selectText(x, y, 400, false);
  }

  // 字幕条上的指针事件不冒泡给播放器（否则点字同时暂停 / 唤出控件）；取词在这里直接做。
  function stop(e) { e.stopPropagation(); }
  function onPointerDown(e) {
    stop(e);
    if (e.pointerType === 'touch' || e.button !== 0) return;
    st.down = true; st.downX = e.clientX; st.downY = e.clientY;
  }
  function onPointerUp(e) {
    stop(e);
    if (e.pointerType === 'touch' || e.button !== 0 || !st.down) return;
    st.down = false;
    if (Math.abs(e.clientX - st.downX) > TAP_SLOP_PX ||
        Math.abs(e.clientY - st.downY) > TAP_SLOP_PX) return;
    var s = window.getSelection ? window.getSelection() : null;
    if (s && !s.isCollapsed && String(s).length > 0) return; // 拖选文字时不取词
    lookupAt(e.clientX, e.clientY);
  }
  function onTouchStart(e) {
    stop(e);
    var t = e.touches && e.touches[0];
    if (!t || e.touches.length !== 1) { st.down = false; return; }
    st.down = true; st.downX = t.clientX; st.downY = t.clientY;
  }
  function onTouchEnd(e) {
    stop(e);
    var t = e.changedTouches && e.changedTouches[0];
    if (!t || !st.down) return;
    st.down = false;
    if (Math.abs(t.clientX - st.downX) > TAP_SLOP_PX ||
        Math.abs(t.clientY - st.downY) > TAP_SLOP_PX) return;
    if (e.cancelable) e.preventDefault(); // 不再合成 click / mouse 事件
    lookupAt(t.clientX, t.clientY);
  }

  function ensureEl(player) {
    if (!st.el) {
      var el = document.createElement('div');
      el.id = EL_ID;
      var es = el.style;
      es.position = 'absolute'; es.left = '0'; es.right = '0'; es.bottom = '14%';
      es.textAlign = 'center'; es.zIndex = '60'; es.pointerEvents = 'none';
      var line = document.createElement('span');
      var ls = line.style;
      ls.display = 'inline-block'; ls.pointerEvents = 'auto'; ls.cursor = 'text';
      ls.userSelect = 'text'; ls.webkitUserSelect = 'text';
      ls.color = '#fff'; ls.background = 'rgba(8,8,8,.72)'; ls.padding = '2px 10px';
      ls.borderRadius = '4px'; ls.lineHeight = '1.4'; ls.whiteSpace = 'pre-wrap';
      ls.maxWidth = '86%'; ls.fontFamily = 'inherit';
      line.addEventListener('pointerdown', onPointerDown);
      line.addEventListener('pointerup', onPointerUp);
      line.addEventListener('mousedown', stop);
      line.addEventListener('mouseup', stop);
      line.addEventListener('click', stop);
      line.addEventListener('dblclick', stop);
      line.addEventListener('touchstart', onTouchStart, { passive: true });
      line.addEventListener('touchend', onTouchEnd, { passive: false });
      el.appendChild(line);
      st.el = el; st.line = line;
    }
    if (player && st.el.parentNode !== player) player.appendChild(st.el);
    if (player) {
      var h = player.clientHeight || 360;
      st.line.style.fontSize = Math.max(14, Math.round(h * 0.048)) + 'px';
    }
    return st.el;
  }

  function render(cue, player) {
    if (cue === st.cue) {
      if (cue && player) ensureEl(player); // 播放器换了节点 / 尺寸变了
      return;
    }
    st.cue = cue;
    if (!cue || !player) {
      if (st.el && st.el.parentNode) st.el.parentNode.removeChild(st.el);
      return;
    }
    ensureEl(player);
    // 整句一个文本节点：阅读器选区脚本按文本节点取句子与词。
    st.line.textContent = String(cue.text || '');
  }

  function reselect() {
    var store = window.fushiEpisodeCues || {};
    var opts = { lang: st.lang, meta: pageTrackMeta(st.videoKey), uiLangs: uiLangs() };
    // 首选轨还是占位：请桥按需取一次（取到后 providers 调钩子 → 再 reselect 换过去）。
    var best = preferredTrackKey(store, st.videoKey, opts);
    if (best && !(store[best] && store[best].length) && !st.requested[best] &&
        typeof window.fushiRequestLazyTrack === 'function') {
      st.requested[best] = true;
      try { window.fushiRequestLazyTrack(best); } catch (_) {}
    }
    var next = chooseTrackKey(store, st.videoKey, st.key, opts);
    st.key = next;
    st.cues = next ? store[next] : [];
    st.cue = undefined; // 强制重绘
    setNativeHidden(st.enabled && st.cues.length > 0);
  }

  function tick() {
    if (!st.enabled) return;
    var key = currentVideoKey();
    if (key !== st.videoKey) { st.videoKey = key; st.key = null; reselect(); }
    var video = videoEl();
    if (!video || !st.cues.length) { render(null, null); return; }
    render(cueAt(st.cues, Math.round(video.currentTime * 1000)), playerOf(video));
  }

  // lang：用户的学习语言（BCP-47，Dart 下发；空 = 不指定）。
  function setEnabled(on, lang) {
    st.enabled = !!on;
    if (typeof lang === 'string') st.lang = lang;
    if (st.enabled) {
      st.videoKey = currentVideoKey();
      reselect();
      if (!st.timer) st.timer = setInterval(tick, 120);
      tick();
    } else {
      if (st.timer) { clearInterval(st.timer); st.timer = null; }
      render(null, null);
      setNativeHidden(false);
    }
    return st.enabled;
  }

  // providers 每到一条新轨 / 新句就调这个钩子（与扩展字幕面板、网页播放器 glue 同一契约）。
  var previousHook = window.fushiSubtitlePanelOnCues;
  window.fushiSubtitlePanelOnCues = function (key) {
    if (typeof previousHook === 'function') { try { previousHook(key); } catch (_) {} }
    if (st.enabled) reselect();
  };

  window.__fushiYtSubs = {
    setEnabled: setEnabled,
    state: function () {
      return { enabled: st.enabled, lang: st.lang, videoKey: st.videoKey, key: st.key, cues: st.cues.length };
    },
    _pure: {
      chooseTrackKey: chooseTrackKey, preferredTrackKey: preferredTrackKey,
      rankTrackKeys: rankTrackKeys, cueAt: cueAt, langOf: langOf, baseName: baseName,
    },
  };
})();
