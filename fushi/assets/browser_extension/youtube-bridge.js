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

  async function fetchAndPublish(id, tracks) {
    var unique = [];
    var seen = new Set();
    for (var i = 0; i < tracks.length && unique.length < 12; i++) {
      var raw = tracks[i] && (tracks[i].url || tracks[i].baseUrl);
      if (!raw) continue;
      var identity = String(tracks[i].languageCode || '') + '|' + String(tracks[i].kind || '') + '|' + raw;
      if (seen.has(identity)) continue;
      seen.add(identity);
      unique.push(tracks[i]);
    }
    var results = await Promise.all(unique.map(async function (track) {
      var cues = await fetchTrack(track);
      if (!cues.length || id !== videoId()) return false;
      publish(id, track, cues);
      return true;
    }));
    return results.filter(Boolean).length;
  }

  function publish(id, track, cues) {
    var message = {
      __fushiStream: 'cues',
      videoKey: 'yt-' + id,
      lang: trackLabel(track),
      format: 'cues',
      cues: cues,
    };
    var key = message.videoKey + '|' + message.lang;
    cache.delete(key); // 重设已存在的键不会移动插入顺序，先删再插才能让 FIFO 淘汰真正淘汰最旧项
    cache.set(key, message);
    while (cache.size > CACHE_LIMIT) {
      var oldest = cache.keys().next();
      if (oldest.done) break;
      cache.delete(oldest.value);
    }
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
