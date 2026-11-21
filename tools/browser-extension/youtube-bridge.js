// YouTube full-caption bridge (MAIN world, document_start).
//
// Mirrors asbplayer's acquisition order: prefer #movie_player.getAudioTrack().captionTracks because
// those URLs include runtime-only POT parameters, then fall back to Android Innertube and the current
// player response. Caption files are fetched as json3 (plain JSON: no Trusted Types sink in the MAIN
// world) and converted to complete cue arrays here. The bridge only reads player state and posts
// plain data to the isolated content script; it never inserts, wraps, replaces, or resizes host-page
// DOM.
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

  // 轨的语言码（`en` / `ja` / `pt-BR`）：store key 的语言段是显示名（同语言人工轨 / ASR 轨靠它
  // 区分），语言偏好匹配却只认码——随清单 / cue 消息一起发出，隔离世界记进 fushiTrackLangCodes。
  function trackLanguageCode(track) {
    return String((track && track.languageCode) || '').replace(/\|/g, '_');
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
  // 优先级：① 当前音轨默认字幕轨 ② 语言码与当前音轨语言一致（人工轨先于 ASR 轨）
  // ③ 人工轨（kind !== 'asr'）④ 其余按原顺序。
  //
  // 反馈 0RgCNJFQmJ / GitHub #3401：「默认」与「音轨语言」以前只从 getAudioTrack() 返回的
  // 播放器内部对象上按字段名读（defaultCaptionTrackIndex / languageCode）。那是 YouTube 压缩
  // 过的运行时类实例，字段名随播放器版本被混淆，读出来全空 → ① ② 同时失效，排序退化成
  // 「原始顺序里的第一条人工轨」，急取并挂上的就是阿拉伯语 / 俄语 / 韩语这类无关翻译轨。
  // 现在两项信号都从结构稳定的数据推（captionHints）：运行时字段仍认（有就用），但不再是
  // 唯一来源。
  var EAGER_TRACKS = 1;
  var pendingTracks = new Map(); // videoKey → Map(label → track)，供按需取
  var lazyInFlight = new Set();

  function langBase(code) {
    return String(code || '').toLowerCase().split(/[-_]/)[0];
  }
  function isAsrTrack(track) {
    return !!track && track.kind === 'asr';
  }

  // 排序要的两项信号：
  //   defaultTrack —— 音轨的默认字幕轨（{languageCode, asr, vssId}），没有 = null；
  //   audioLang    —— 音轨的语言（基础语言码，`en` / `ja`），推不出 = ''。
  // 注意 b) 取的是服务端的**默认音轨**（defaultAudioTrackIndex），不是用户在播放器里切到的
  // 当前音轨：当前音轨的索引只在被混淆的运行时对象上，读不到。所以 a) 的运行时字段读得到时
  // 优先（defaultIndex 先于 defaultTrack 命中）；自动配音视频里切了音轨又读不到运行时字段时，
  // b) 给的是原声音轨的默认轨。
  // 来源按可靠度依次：
  //   a) 运行时音轨对象的明文字段（未被混淆的播放器版本上仍有效）；
  //   b) 播放器响应 captions.playerCaptionsTracklistRenderer（服务端 JSON，字段名是协议的
  //      一部分，不会被前端压缩混淆）：audioTracks[defaultAudioTrackIndex] 的
  //      defaultCaptionTrackIndex（hasDefaultTrack !== false 时）给默认轨，其
  //      captionTrackIndices 圈出本音轨的轨；
  //   c) 自动字幕（ASR）只为音轨的口语语言生成：本音轨范围里 ASR 轨只有一种语言时，它就是
  //      音轨语言。范围取不到（无 renderer）就看整份轨清单。
  function captionHints(tracks, audioTrack, renderer) {
    var hints = { defaultTrack: null, defaultIndex: -1, audioLang: '' };
    try {
      if (audioTrack && typeof audioTrack.defaultCaptionTrackIndex === 'number') {
        hints.defaultIndex = audioTrack.defaultCaptionTrackIndex;
      }
      hints.audioLang = langBase(audioTrack && (audioTrack.languageCode || audioTrack.language));
    } catch (_) {}
    var scope = tracks;
    try {
      var all = renderer && Array.isArray(renderer.captionTracks) ? renderer.captionTracks : null;
      var audioTracks = renderer && Array.isArray(renderer.audioTracks) ? renderer.audioTracks : [];
      var audioIdx = typeof renderer.defaultAudioTrackIndex === 'number' ? renderer.defaultAudioTrackIndex : 0;
      var current = audioTracks[audioIdx] || audioTracks[0] || null;
      if (all && current) {
        if (current.hasDefaultTrack !== false && typeof current.defaultCaptionTrackIndex === 'number') {
          var def = all[current.defaultCaptionTrackIndex];
          if (def && def.languageCode) {
            hints.defaultTrack = { languageCode: String(def.languageCode), asr: isAsrTrack(def), vssId: String(def.vssId || '') };
          }
        }
        if (Array.isArray(current.captionTrackIndices) && current.captionTrackIndices.length) {
          scope = current.captionTrackIndices.map(function (i) { return all[i]; }).filter(Boolean);
        } else {
          scope = all;
        }
      } else if (all) {
        scope = all;
      }
    } catch (_) {}
    if (!hints.audioLang) {
      var asrLangs = new Set();
      (Array.isArray(scope) ? scope : []).forEach(function (t) {
        if (isAsrTrack(t) && t.languageCode) asrLangs.add(langBase(t.languageCode));
      });
      if (asrLangs.size === 1) hints.audioLang = Array.from(asrLangs)[0];
    }
    return hints;
  }

  function matchesDefault(track, i, hints) {
    if (i === hints.defaultIndex || track.isDefault === true) return true;
    var def = hints.defaultTrack;
    if (!def) return false;
    if (def.vssId && track.vssId) return String(track.vssId) === def.vssId;
    return String(track.languageCode || '') === def.languageCode && isAsrTrack(track) === def.asr;
  }

  function prioritizeCaptionTracks(tracks, audioTrack, renderer) {
    if (!Array.isArray(tracks)) return [];
    var hints = captionHints(tracks, audioTrack, renderer);
    function rank(track, i) {
      if (!track) return 9;
      if (matchesDefault(track, i, hints)) return 0;
      var sameLang = !!hints.audioLang && langBase(track.languageCode) === hints.audioLang;
      if (sameLang) return isAsrTrack(track) ? 2 : 1;
      if (!isAsrTrack(track)) return 3;
      return 4;
    }
    return tracks
      .map(function (t, i) { return { t: t, i: i, r: rank(t, i) }; })
      .sort(function (a, b) { return a.r - b.r || a.i - b.i; })
      .map(function (e) { return e.t; });
  }

  function captionRenderer(response) {
    var renderer = response && response.captions && response.captions.playerCaptionsTracklistRenderer;
    return renderer && typeof renderer === 'object' ? renderer : null;
  }

  // 当前视频的播放器响应（服务端 JSON，键名不混淆）。SPA 换视频后 ytInitialPlayerResponse 仍是
  // 首屏那个视频的，所以按 videoDetails.videoId 核对；对不上的不用。
  function currentPlayerResponse(id) {
    var candidates = [];
    try {
      var player = document.querySelector('#movie_player');
      if (player && typeof player.getPlayerResponse === 'function') candidates.push(player.getPlayerResponse());
    } catch (_) {}
    try { candidates.push(window.ytInitialPlayerResponse); } catch (_) {}
    for (var i = 0; i < candidates.length; i++) {
      var r = candidates[i];
      if (r && r.videoDetails && r.videoDetails.videoId === id) return r;
    }
    return null;
  }

  // 三路取轨都回 {tracks, audioTrack, renderer}：排序信号跟着轨的来源走（运行时音轨对象的
  // defaultCaptionTrackIndex 只对它自己的 captionTracks 有效，不能拿去索引 Android 响应的轨）。
  var NO_SOURCE = { tracks: [], audioTrack: null, renderer: null };

  function runtimeTracks(id) {
    try {
      var player = document.querySelector('#movie_player');
      var data = player && player.getVideoData && player.getVideoData();
      if (data && data.video_id && data.video_id !== id) return NO_SOURCE;
      var audioTrack = player && player.getAudioTrack && player.getAudioTrack();
      if (!audioTrack || !Array.isArray(audioTrack.captionTracks)) return NO_SOURCE;
      return {
        tracks: audioTrack.captionTracks,
        audioTrack: audioTrack,
        renderer: captionRenderer(currentPlayerResponse(id)),
      };
    } catch (_) { return NO_SOURCE; }
  }

  // 第三路兜底：页面里的播放器响应。与排序信号同一条「残留响应不用」规则——SPA 换片后
  // ytInitialPlayerResponse / ytplayer.config 仍是首屏那个视频的，整份轨清单（baseUrl 里 v= 是
  // 旧视频）不能当成当前视频发布，所以同样按 videoDetails.videoId 核对。
  function responseTracks(id) {
    try {
      var response = currentPlayerResponse(id);
      if (!response && window.ytplayer && window.ytplayer.config && window.ytplayer.config.args) {
        var legacy = window.ytplayer.config.args.player_response;
        if (typeof legacy === 'string') legacy = JSON.parse(legacy);
        if (legacy && legacy.videoDetails && legacy.videoDetails.videoId === id) response = legacy;
      }
      var renderer = captionRenderer(response);
      if (!renderer || !Array.isArray(renderer.captionTracks)) return NO_SOURCE;
      return { tracks: renderer.captionTracks, audioTrack: null, renderer: renderer };
    } catch (_) { return NO_SOURCE; }
  }

  async function androidTracks(id) {
    try {
      if (!window.ytcfg || typeof window.ytcfg.get !== 'function') return NO_SOURCE;
      var key = window.ytcfg.get('INNERTUBE_API_KEY');
      if (!key) return NO_SOURCE;
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
      if (!response.ok) return NO_SOURCE;
      var renderer = captionRenderer(await response.json());
      if (!renderer || !Array.isArray(renderer.captionTracks)) return NO_SOURCE;
      return { tracks: renderer.captionTracks, audioTrack: null, renderer: renderer };
    } catch (_) { return NO_SOURCE; }
  }

  // keepWords（只给自动字幕）：每行再带上词级时间 words = [{offsetMs, text}]（json3 segs 的
  // tOffsetMs，相对行起点），隔离世界的分句整合（subtitle-adapters.js fushiMergeAsrSentenceCues，
  // 设置 subtitleMergeAsrSentences）靠它把句号落在行中间的句子按词切开、按词间停顿断句。
  function parseJson3(payload, keepWords) {
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
      var cue = { startMs: start, endMs: start + duration, text: value };
      if (keepWords && event.segs.length > 1) {
        cue.words = event.segs.map(function (segment) {
          return { offsetMs: Number(segment && segment.tOffsetMs) || 0, text: segment && segment.utf8 || '' };
        }).filter(function (word) { return word.text; });
      }
      cues.push(cue);
    }
    return cues;
  }

  // YouTube 自动字幕是「滚动双行」显示：每一行 cue 的时长一直跨到**下下行**开头（它要在
  // 屏幕上停留到被顶出去为止），只靠中间那条 `\n` 追加行来截断。实测（dQw4w9WgXcQ，en asr）
  // "We're no strangers to" t=18800 d=7160 → 26 秒，而下一行 "love. You know…" 21800 就开始了。
  // 旧 srv3 解析有一条只认「下一行恰是 \n 行」的截断，json3 路径以前没有——制卡按 cue 窗裁
  // 音频，裁出来的是两行的声音，卡上却只有第一行的字（BUG-2629）。统一在解析之后收口：按起
  // 始时间排好序后，任何一条的结束不得越过下一条的开始。手工轨极少真正重叠，两人同时说话那种
  // 也只会少录被盖住的尾巴，不会多录下一句。
  function sortCuesByStart(cues) {
    if (!Array.isArray(cues) || cues.length < 2) return cues;
    return cues.slice().sort(function (a, b) { return a.startMs - b.startMs; });
  }

  // 只对自动字幕（`track.kind === 'asr'`）做：截断是「滚动双行」这一显示形态的逆运算，
  // 人工轨没有这回事——srv3 支持 `wp`/`ws` 多窗定位，双人同说 / 歌词 + 对白 / 注释窗
  // 都是有意重叠的 cue，套上去会把前一条的制卡音频砍到后一条开头（PR #1599 审查）。
  function finishTrackCues(track, cues) {
    return track && track.kind === 'asr' ? clampRollingCues(cues) : sortCuesByStart(cues);
  }

  function clampRollingCues(cues) {
    if (!Array.isArray(cues) || cues.length < 2) return cues;
    var sorted = sortCuesByStart(cues);
    for (var i = 0; i < sorted.length - 1; i++) {
      var cue = sorted[i];
      var nextStart = sorted[i + 1].startMs;
      if (nextStart > cue.startMs && cue.endMs > nextStart) cue.endMs = nextStart;
    }
    return sorted;
  }

  async function fetchTrack(track) {
    var raw = track && (track.url || track.baseUrl);
    if (!raw) return [];
    var url = new URL(raw, location.href);
    // 只取 json3：本文件跑在 MAIN world，YouTube 页面强制 Trusted Types
    // （require-trusted-types-for 'script'），DOM 解析器的 parseFromString 属 TrustedHTML
    // sink，传裸字符串直接抛 "This document requires 'TrustedHTML' assignment"。以前先取
    // srv3 再用它解析，在 YouTube 上必抛、被 catch 吞掉后才回落 json3——每条轨白发一次 srv3
    // 请求，扩展错误页还留一条报错（BUG-2697 / issue #1495）。json3 是纯 JSON，不经任何
    // HTML/XML sink；滚动双行截断由 finishTrackCues 统一收口，与原 srv3 路径输出等价（唯一
    // 差别：自动字幕截断点从 `\n` 追加行改为下一行开头，实测晚约 10ms）。
    // 守卫：main-world-trusted-types.test.js 禁止 MAIN world 脚本再出现 HTML sink。
    url.searchParams.set('fmt', 'json3');
    try {
      if (window.ytcfg && typeof window.ytcfg.get === 'function') {
        url.searchParams.set('c', window.ytcfg.get('INNERTUBE_CLIENT_NAME') || 'WEB');
      }
    } catch (_) {}
    try {
      var jsonResponse = await fetch(url.toString(), { credentials: 'include' });
      if (!jsonResponse.ok) return [];
      return finishTrackCues(track, parseJson3(await jsonResponse.json(), isAsrTrack(track)));
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

  async function fetchAndPublish(id, source) {
    var tracks = prioritizeCaptionTracks(source.tracks, source.audioTrack, source.renderer);
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
      tracks: Array.from(byLabel.entries()).map(function (entry) {
        return { lang: entry[0], languageCode: trackLanguageCode(entry[1]) };
      }),
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
  // 取不到（清单里没有这条 / 请求失败 / 轨是空的）发 {__fushiStream:'cuesFailed'} 确定回执：
  // 请求方（app 的「加载中」、扩展面板）据此落成失败，而不是永远等一条不会来的 cue。
  async function fetchLazyTrack(videoKey, lang) {
    var byLabel = pendingTracks.get(videoKey);
    var track = byLabel && byLabel.get(lang);
    if (!track) { publishFailed(videoKey, lang, 'unknown track'); return; }
    var key = videoKey + '|' + lang;
    var cached = cache.get(key);
    if (cached) { try { window.postMessage(cached, '/'); } catch (_) {} return; }
    if (lazyInFlight.has(key)) return;
    lazyInFlight.add(key);
    try {
      var cues = await fetchTrack(track);
      if (cues.length) publish(videoKey.slice(3), track, cues);
      else publishFailed(videoKey, lang, 'no cues');
    } catch (e) {
      publishFailed(videoKey, lang, String((e && e.message) || e || 'error'));
    } finally {
      lazyInFlight.delete(key);
    }
  }
  function publishFailed(videoKey, lang, err) {
    try {
      window.postMessage({ __fushiStream: 'cuesFailed', videoKey: videoKey, lang: lang, err: err }, '/');
    } catch (_) {}
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
      languageCode: trackLanguageCode(track),
      format: 'cues',
      cues: cues,
    };
    // 自动字幕标记：隔离世界据此把这条轨登记进分句整合（cue 带 words 词级时间）。
    if (isAsrTrack(track)) message.asr = true;
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
      var source = runtimeTracks(id);
      var applied = source.tracks.length ? await fetchAndPublish(id, source) : 0;
      if (!applied) {
        source = await androidTracks(id);
        applied = source.tracks.length ? await fetchAndPublish(id, source) : 0;
      }
      if (!applied) {
        source = responseTracks(id);
        applied = source.tracks.length ? await fetchAndPublish(id, source) : 0;
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
