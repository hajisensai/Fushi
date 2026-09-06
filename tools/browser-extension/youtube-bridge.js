// YouTube full-caption bridge (MAIN world, document_start).
//
// Mirrors asbplayer's acquisition order: prefer #movie_player.getAudioTrack().captionTracks because
// those URLs include runtime-only POT parameters, then fall back to Android Innertube and the current
// player response. Caption files are fetched as srv3 and converted to complete cue arrays here. The
// bridge only reads player state and posts plain data to the isolated content script; it never inserts,
// wraps, replaces, or resizes host-page DOM.
(function () {
  'use strict';
  if (window.__fushiYoutubeBridgeInstalled) return;
  window.__fushiYoutubeBridgeInstalled = true;

  // 已抓到的 cue 报文存档，供 content.js 就绪后整批重放。SPA 连刷视频时每个视频最多 12 条轨，
  // 每条轨是整集 cue 数组（可达数百 KB）——无上限的话一次长会话就能吃掉几百 MB，故 FIFO 限容。
  var CACHE_LIMIT = 24;
  var cache = new Map();
  var fetchingFor = '';
  // 取轨失败的退避账本（按 videoId 记）。三路取轨全空是**常态**（无字幕视频），
  // 而下面是 setInterval(acquire, 1000)：不退避就等于每秒一次带 cookie 的
  // POST /youtubei/v1/player 无止境打 YouTube 自家 API，直到用户离开页面。
  var MAX_ATTEMPTS = 6;      // 1s→2s→4s→8s→16s→32s 后彻底放弃（此视频确无可用字幕轨）
  var backoff = { id: '', attempts: 0, nextAt: 0 };

  function resetBackoff() {
    backoff = { id: '', attempts: 0, nextAt: 0 };
  }

  // 一次取轨失败：解锁在途标记，并把下次允许重试的时刻按 2^n 秒推后。
  function noteAcquireFailure(id) {
    fetchingFor = '';
    if (backoff.id !== id) backoff = { id: id, attempts: 0, nextAt: 0 };
    backoff.attempts += 1;
    backoff.nextAt = Date.now() + 1000 * Math.pow(2, backoff.attempts);
  }

  function videoId() {
    var path = location.pathname || '';
    var match = path.match(/^\/(?:shorts|embed)\/([^/?]+)/);
    if (match) return match[1];
    try { return new URLSearchParams(location.search).get('v') || ''; } catch (_) { return ''; }
  }

  function trackLabel(track) {
    var label = track && track.name && (
      track.name.simpleText || (track.name.runs && track.name.runs[0] && track.name.runs[0].text)
    );
    label = label || track.displayName || track.languageName || track.languageCode || 'und';
    if (track.kind === 'asr' && !/auto|自动/i.test(label)) label += ' (自动)';
    return String(label).replace(/\|/g, '_');
  }

  // BUG-2194：一条视频的 captionTracks 可能有几十条（自动配音视频每种配音语言各带一条
  // ASR 轨）。此前为了不把整集轨 × N 全拉下来，按 YouTube 原始顺序只取前 12 条——**原语言**
  // （用户在听的那条音轨的字幕，也就是学习语言）排在后面就被截掉：用户列表里俄/孟/德/旁遮普
  // …12 条齐全，唯独没有英语。现在改成**按需加载**：整份清单（只有标签）立刻发给隔离世界
  // 进列表；只急取 EAGER_TRACKS 条（排优先级后的头一条 = 当前音轨默认字幕轨）让覆盖层/
  // 替代原生立即可用；其余等隔离世界发 {__fushiStream:'fetchTrack'}（用户在列表里选中）再取。
  // 优先级：① 当前音轨默认字幕轨（defaultCaptionTrackIndex / isDefault）② 语言码与当前
  // 音轨语言一致 ③ 人工轨（kind !== 'asr'）④ 其余按原顺序。
  var EAGER_TRACKS = 1;
  var pendingTracks = new Map(); // videoKey → Map(label → track)，供按需取
  var lazyInFlight = new Set();
  function prioritizeCaptionTracks(tracks, audioTrack) {
    if (!Array.isArray(tracks)) return [];
    var defIdx = audioTrack && typeof audioTrack.defaultCaptionTrackIndex === 'number'
      ? audioTrack.defaultCaptionTrackIndex : -1;
    var audioLang = '';
    try {
      var raw = audioTrack && (audioTrack.languageCode || audioTrack.language || '');
      audioLang = String(raw || '').toLowerCase().split(/[-_]/)[0];
    } catch (_) { audioLang = ''; }
    function rank(track, i) {
      if (!track) return 9;
      if (i === defIdx || track.isDefault === true) return 0;
      var lang = String(track.languageCode || '').toLowerCase().split(/[-_]/)[0];
      if (audioLang && lang === audioLang) return 1;
      if (track.kind !== 'asr') return 2;
      return 3;
    }
    return tracks
      .map(function (t, i) { return { t: t, i: i, r: rank(t, i) }; })
      .sort(function (a, b) { return a.r - b.r || a.i - b.i; })
      .map(function (e) { return e.t; });
  }

  function runtimeAudioTrack() {
    try {
      var player = document.querySelector('#movie_player');
      return player && player.getAudioTrack ? player.getAudioTrack() : null;
    } catch (_) { return null; }
  }

  function runtimeTracks(id) {
    try {
      var player = document.querySelector('#movie_player');
      var data = player && player.getVideoData && player.getVideoData();
      if (data && data.video_id && data.video_id !== id) return [];
      var audioTrack = player && player.getAudioTrack && player.getAudioTrack();
      return audioTrack && Array.isArray(audioTrack.captionTracks) ? audioTrack.captionTracks : [];
    } catch (_) { return []; }
  }

  function responseTracks() {
    try {
      var response = window.ytInitialPlayerResponse;
      if (!response && window.ytplayer && window.ytplayer.config && window.ytplayer.config.args) {
        response = window.ytplayer.config.args.player_response;
        if (typeof response === 'string') response = JSON.parse(response);
      }
      var renderer = response && response.captions && response.captions.playerCaptionsTracklistRenderer;
      return renderer && Array.isArray(renderer.captionTracks) ? renderer.captionTracks : [];
    } catch (_) { return []; }
  }

  async function androidTracks(id) {
    try {
      if (!window.ytcfg || typeof window.ytcfg.get !== 'function') return [];
      var key = window.ytcfg.get('INNERTUBE_API_KEY');
      if (!key) return [];
      var response = await fetch('/youtubei/v1/player?key=' + encodeURIComponent(key), {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          context: { client: {
            clientName: 'ANDROID', clientVersion: '20.10.38',
            hl: window.ytcfg.get('HL') || 'en',
          } },
          videoId: id,
        }),
      });
      if (!response.ok) return [];
      var payload = await response.json();
      var renderer = payload && payload.captions && payload.captions.playerCaptionsTracklistRenderer;
      return renderer && Array.isArray(renderer.captionTracks) ? renderer.captionTracks : [];
    } catch (_) { return []; }
  }

  function parseSrv3(text) {
    var doc = new DOMParser().parseFromString(text, 'text/xml');
    if (doc.querySelector('parsererror')) return [];
    var rows = Array.from(doc.querySelectorAll('timedtext > body > p'));
    var cues = [];
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var start = Number(row.getAttribute('t'));
      var duration = Number(row.getAttribute('d'));
      if (!Number.isFinite(start) || !Number.isFinite(duration)) continue;
      var value = String(row.textContent || '').replace(/\s+/g, ' ').trim();
      if (!value) continue;
      var next = rows[i + 1];
      if (next && String(next.textContent || '') === '\n') {
        var nextStart = Number(next.getAttribute('t'));
        if (Number.isFinite(nextStart)) duration = Math.min(duration, Math.max(0, nextStart - start));
      }
      cues.push({ startMs: start, endMs: start + Math.max(1, duration), text: value });
    }
    return cues;
  }

  function parseJson3(payload) {
    var events = payload && Array.isArray(payload.events) ? payload.events : [];
    var cues = [];
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      if (!event || !Array.isArray(event.segs)) continue;
      var value = event.segs.map(function (segment) { return segment && segment.utf8 || ''; })
        .join('').replace(/\s+/g, ' ').trim();
      var start = Number(event.tStartMs);
      var duration = Number(event.dDurationMs);
      if (!value || !Number.isFinite(start)) continue;
      if (!Number.isFinite(duration) || duration <= 0) {
        var next = events[i + 1];
        duration = next && Number.isFinite(Number(next.tStartMs))
          ? Math.max(1, Number(next.tStartMs) - start) : 1500;
      }
      cues.push({ startMs: start, endMs: start + duration, text: value });
    }
    return cues;
  }

  async function fetchTrack(track) {
    var raw = track && (track.url || track.baseUrl);
    if (!raw) return [];
    var url = new URL(raw, location.href);
    url.searchParams.set('fmt', 'srv3');
    try {
      if (window.ytcfg && typeof window.ytcfg.get === 'function') {
        url.searchParams.set('c', window.ytcfg.get('INNERTUBE_CLIENT_NAME') || 'WEB');
      }
    } catch (_) {}
    try {
      var response = await fetch(url.toString(), { credentials: 'include' });
      if (response.ok) {
        var text = await response.text();
        var cues = parseSrv3(text);
        if (cues.length) return cues;
      }
    } catch (_) {}
    try {
      url.searchParams.set('fmt', 'json3');
      var jsonResponse = await fetch(url.toString(), { credentials: 'include' });
      if (!jsonResponse.ok) return [];
      return parseJson3(await jsonResponse.json());
    } catch (_) { return []; }
  }

  function cacheMessage(key, message) {
    cache.delete(key); // 重设已存在的键不会移动插入顺序，先删再插才能让 FIFO 淘汰真正淘汰最旧项
    cache.set(key, message);
    while (cache.size > CACHE_LIMIT) {
      var oldest = cache.keys().next();
      if (oldest.done) break;
      cache.delete(oldest.value);
    }
  }

  async function fetchAndPublish(id, rawTracks) {
    var tracks = prioritizeCaptionTracks(rawTracks, runtimeAudioTrack());
    var byLabel = new Map();
    var seen = new Set();
    for (var i = 0; i < tracks.length; i++) {
      var raw = tracks[i] && (tracks[i].url || tracks[i].baseUrl);
      if (!raw) continue;
      var identity = String(tracks[i].languageCode || '') + '|' + String(tracks[i].kind || '') + '|' + raw;
      if (seen.has(identity)) continue;
      seen.add(identity);
      var label = trackLabel(tracks[i]);
      if (!byLabel.has(label)) byLabel.set(label, tracks[i]);
    }
    if (!byLabel.size) return 0;
    var videoKey = 'yt-' + id;
    pendingTracks.set(videoKey, byLabel);
    // 整份清单先到：隔离世界据此在列表里登记占位轨（无 cue），用户选中再回来取。
    var list = {
      __fushiStream: 'tracks',
      videoKey: videoKey,
      tracks: Array.from(byLabel.keys()).map(function (lang) { return { lang: lang }; }),
    };
    cacheMessage(videoKey + '|#tracks', list);
    try { window.postMessage(list, '/'); } catch (_) {}
    var eager = Array.from(byLabel.values()).slice(0, EAGER_TRACKS);
    var results = await Promise.all(eager.map(async function (track) {
      var cues = await fetchTrack(track);
      if (!cues.length || id !== videoId()) return false;
      publish(id, track, cues);
      return true;
    }));
    return results.filter(Boolean).length;
  }

  // 按需取轨：隔离世界（subtitle-providers.js fushiRequestLazyTrack）在用户选中占位轨时发
  // {__fushiStream:'fetchTrack', videoKey, lang}。已取过的直接重放缓存；在途的不重复取。
  async function fetchLazyTrack(videoKey, lang) {
    var byLabel = pendingTracks.get(videoKey);
    var track = byLabel && byLabel.get(lang);
    if (!track) return;
    var key = videoKey + '|' + lang;
    var cached = cache.get(key);
    if (cached) { try { window.postMessage(cached, '/'); } catch (_) {} return; }
    if (lazyInFlight.has(key)) return;
    lazyInFlight.add(key);
    try {
      var cues = await fetchTrack(track);
      if (cues.length) publish(videoKey.slice(3), track, cues);
    } catch (_) {
    } finally {
      lazyInFlight.delete(key);
    }
  }
  window.addEventListener('message', function (event) {
    if (event.source !== window || !event.data || event.data.__fushiStream !== 'fetchTrack') return;
    fetchLazyTrack(String(event.data.videoKey || ''), String(event.data.lang || ''));
  });

  function publish(id, track, cues) {
    var message = {
      __fushiStream: 'cues',
      videoKey: 'yt-' + id,
      lang: trackLabel(track),
      format: 'cues',
      cues: cues,
    };
    cacheMessage(message.videoKey + '|' + message.lang, message);
    try { window.postMessage(message, '/'); } catch (_) {}
  }

  // force=true 用于用户/页面显式请求（replayCues、yt-navigate-finish）：跳过退避窗口重试一次，
  // 但仍受在途锁保护。轮询（setInterval）永远 force=false，必须服从退避与放弃上限。
  async function acquire(force) {
    var id = videoId();
    if (!id || fetchingFor === id) return;
    if (backoff.id === id) {
      if (force) backoff.nextAt = 0;
      else if (backoff.attempts >= MAX_ATTEMPTS || Date.now() < backoff.nextAt) return;
    }
    fetchingFor = id;
    try {
      var tracks = runtimeTracks(id);
      var applied = tracks.length ? await fetchAndPublish(id, tracks) : 0;
      if (!applied) {
        tracks = await androidTracks(id);
        applied = tracks.length ? await fetchAndPublish(id, tracks) : 0;
      }
      if (!applied) {
        tracks = responseTracks();
        applied = tracks.length ? await fetchAndPublish(id, tracks) : 0;
      }
      if (applied) { if (backoff.id === id) resetBackoff(); }
      else noteAcquireFailure(id);
    } catch (_) { noteAcquireFailure(id); }
  }

  window.addEventListener('message', function (event) {
    if (event.source !== window || !event.data || event.data.__fushiStream !== 'replayCues') return;
    cache.forEach(function (message) {
      try { window.postMessage(message, '/'); } catch (_) {}
    });
    acquire(true);
  });

  document.addEventListener('yt-navigate-finish', function () {
    fetchingFor = '';
    resetBackoff(); // 换视频 = 换账本：上一个视频的失败次数不该拖累新视频的首次取轨
    acquire(true);
  }, true);
  // 注意传函数壳而不是 acquire 本身：setInterval 会把「第几次触发」当参数塞进来，
  // 直接传 acquire 会让它被当成 force=1 从而绕过退避。
  setInterval(function () { acquire(false); }, 1000);
  acquire(true);
})();
