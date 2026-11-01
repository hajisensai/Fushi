// TODO-1000 主世界桥（manifest 里 world:MAIN 注入）：content script 跑在隔离世界，够不到页面的
// window.netflix。这里接 content 发来的 postMessage，用 Netflix **官方播放器 API** seek——走它正规
// 的缓冲/授权通道，和你手动拖进度条一样，不会 desync → 不触发 M7375（直接改 video.currentTime 才炸）。
//
// TODO-1219 P1：本文件 run_at 已改为 document_start（manifest.json），以便在 Netflix 发出播放清单
// **之前**装好 JSON.parse hook，拦到整集字幕轨。seek 路径不受影响：nfSeek 里 videoPlayer 是收到
// seek 消息时才惰性解析（非脚本加载时），document_start 只是提前注册 listener + hook，安全。
(function () {
  // BUG-769：跨世界自投消息全部用 targetOrigin '/'（仅同源同窗才投递），而非 location.origin。
  // file:// 页 opaque origin 序列化成 'null'，但 location.origin 返回 'file://' → 二者不匹配，
  // postMessage 直接抛异常/静默丢弃。'/' 对不透明源同样成立（同窗自投恒同源），且不做 URL 解析。
  // 接收端比对期望源用 window.origin（不透明源返回 'null'，与 e.origin 一致），location.origin 会错序列化。
  var ORIGIN = window.origin;

  // ── TODO-1219 P1：整集字幕拦截（数据源） ──
  // Netflix 播放清单 timedtexttracks[] 列出每条字幕轨的下载地址（明文 WebVTT/TTML，非 DRM；只有
  // 视频帧/音频受 DRM）。这里用 JSON.parse hook 嗅探清单 → 页面 origin 带 cookie 抓字幕原文 →
  // 跨世界 postMessage 送隔离世界 content.js 解析。切集/切轨会产生新清单，hook 自然重放刷新。
  var FMT_PREF = ['webvtt-lssdh-ios8', 'webvtt', 'dfxp-ls-sdh', 'imsc1.1', 'simplesdh', 'nflx-cmisc'];
  var seenTimedTextUrls = Object.create(null); // URL 去重，同一轨只抓一次

  // TODO-1219/1363（面板要刷新/列表空的根因）：本脚本 document_start 抓字幕，隔离世界 content.js
  // document_idle 才注册接收端——postMessage fire-and-forget，先于接收端发出的 cue 消息永久丢失。
  // 抓到的 cue payload 一律存档；content.js 就绪后发 {__fushiNf:'replayCues'} 请求，这里整批重放。
  // 上限防呆：一部剧全部语言轨也就几十条，超上限丢最旧（绝不无界增长）。
  var cueArchive = [];
  var CUE_ARCHIVE_MAX = 80;
  function postCuesMessage(payload) {
    try { window.postMessage(payload, '/'); } catch (_) {}
  }

  function pickTrackUrl(track) {
    var dls = track && track.ttDownloadables;
    if (!dls) return null;
    var keys = FMT_PREF.slice();
    for (var k in dls) { if (keys.indexOf(k) < 0) keys.push(k); } // 未知格式兜底
    for (var i = 0; i < keys.length; i++) {
      var dl = dls[keys[i]];
      if (!dl) continue;
      var isVtt = keys[i].indexOf('vtt') >= 0 || keys[i] === 'webvtt';
      var fmt = isVtt ? 'webvtt' : 'ttml';
      // 新形状 urls:[{url,cdnId}]；旧形状 downloadUrls:{cdnId:url}。
      if (dl.urls && dl.urls.length && dl.urls[0] && dl.urls[0].url) return { url: dl.urls[0].url, format: fmt };
      if (dl.downloadUrls) { for (var c in dl.downloadUrls) { if (dl.downloadUrls[c]) return { url: dl.downloadUrls[c], format: fmt }; } }
    }
    return null;
  }

  // 轨身份（语言 / trackId / 显示名）只在这三个函数里取值：清单通道（timedtexttracks 条目）、正文
  // 嗅探（播放器当前轨）与播放器状态通道（getTimedTextTrackList 条目）一律经它们。同一条轨三条通道
  // 必须算出同一个 store key（`vid|lang~trackId`）——否则状态通道登记的占位轨与别的通道投来的真 cue
  // 落在两个 key 上：菜单里同一条轨列两遍，占位那条永远「待加载」。
  // 语言 bcp47 优先：播放器 API 的轨只保证 bcp47（asbplayer 同样只认它），清单条目缺它时回落 language。
  function trackLangOf(track) {
    return String((track && (track.bcp47 || track.language)) || '');
  }
  function langOf(track) {
    return trackLangOf(track) || 'und';
  }
  // 轨身份：同一语言常有「普通字幕」与「CC / SDH」两条轨，只按语言区分会互相覆盖。trackId 与
  // 播放器 API 的 getTimedTextTrackList()[i].trackId 同值（清单里叫 new_track_id）。
  function trackIdOf(track) {
    return String((track && (track.new_track_id || track.trackId || track.id)) || '');
  }
  function trackLabelOf(track) {
    return String((track && (track.languageDescription || track.displayName)) || '');
  }
  // 整轨抓取失败（网络 / CORS / 非 2xx）的确定性回执：消费端据此把「加载中」落成「失败」，
  // 而不是永远等一份不会来的 cue。
  function postCuesFailed(videoId, lang, trackId, err) {
    postCuesMessage({ __fushiNf: 'cuesFailed', videoId: videoId, lang: lang, trackId: trackId, err: String(err || '') });
  }

  function fetchCues(videoId, track) {
    try {
      if (track && (track.isNoneTrack || track.isForcedNarrative)) return; // 跳过 [None]/强制窄轨
      var picked = pickTrackUrl(track);
      if (!picked) return;
      fetchTimedText(videoId, { lang: langOf(track), trackId: trackIdOf(track), label: trackLabelOf(track) }, picked.url, picked.format);
    } catch (_) {}
  }

  // 整轨下载（清单通道与播放器状态通道共用）。formatHint 缺省时按正文开头判格式，判不出按 TTML
  //（播放器状态里的下载地址是 IMSC 1.1，asbplayer 记作 nfimsc）。
  function fetchTimedText(videoId, meta, url, formatHint) {
    try {
      if (!url || seenTimedTextUrls[url]) return;
      // BUG-1728：去重标记先占坑防并发清单重复抓取，但失败必须在 .catch 里撤销——旧代码把
      // 标记写死在 fetch 前且失败纯静默，一次网络/CORS 失败 = 该 URL 本页永不重试，用户只剩
      // DOM 实时采集轨，还完全不知道整轨链路挂了。
      seenTimedTextUrls[url] = 1;
      var lang = meta.lang;
      var trackId = meta.trackId;
      var label = meta.label;
      // BUG-1728：裸 fetch、**不带 credentials**。字幕在跨源 CDN（*.oca.nflxvideo.net），
      // credentials:'include' 要求响应 ACAO 是精确 origin；CDN 回 `*` 时整个请求被 CORS 拒掉
      // → 整轨抓取静默失败。字幕 URL 自带鉴权参数、不需要 cookie（asbplayer 同款裸 fetch）。
      fetch(url)
        .then(function (r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.text();
        })
        .then(function (text) {
          if (!text) return;
          var format = formatHint || subtitleFormatOf(text) || 'ttml';
          var payload = { __fushiNf: 'cues', videoId: videoId, lang: lang, trackId: trackId, label: label, format: format, text: text };
          cueArchive.push(payload);
          if (cueArchive.length > CUE_ARCHIVE_MAX) cueArchive.shift();
          postCuesMessage(payload);
        })
        .catch(function (e) {
          // 撤去重标记：切轨/切集清单重放时同一 URL 可重试。保持 best-effort 不外抛，
          // 只留一条诊断（旧代码零日志，用户端无从判断整轨为何消失）。
          delete seenTimedTextUrls[url];
          try { console.warn('[Fushi][TODO-1219] timedtext fetch failed:', url, e); } catch (_) {}
          postCuesFailed(videoId, lang, trackId, e && e.message ? e.message : e);
        });
    } catch (_) {}
  }

  function harvestManifest(manifest) {
    try {
      if (!manifest || !Array.isArray(manifest.timedtexttracks)) return;
      var videoId = String(manifest.movieId || manifest.viewableId || '');
      var tracks = manifest.timedtexttracks;
      for (var i = 0; i < tracks.length; i++) fetchCues(videoId, tracks[i]);
    } catch (_) {}
  }

  // JSON.parse 纯透传 hook（红线）：先原样拿到 Netflix 自己的解析结果，再旁路嗅探，任何异常绝不
  // 外泄——绝不能连带炸 Netflix 自身的解析/播放。
  var origParse = JSON.parse;
  JSON.parse = function () {
    var r = origParse.apply(this, arguments);
    try {
      if (r && typeof r === 'object') {
        if (Array.isArray(r.timedtexttracks)) harvestManifest(r);
        if (r.result) {
          if (Array.isArray(r.result.timedtexttracks)) harvestManifest(r.result);
          if (Array.isArray(r.result.manifests)) {
            for (var i = 0; i < r.result.manifests.length; i++) harvestManifest(r.result.manifests[i]);
          }
        }
      }
    } catch (_) {}
    return r;
  };

  // ── BUG-1949：播放器自下的字幕文件嗅探（现在的主数据源） ──
  // 当前 Netflix 的播放清单经 MSL 解密后**不再经过主世界 JSON.parse**（实测 75 s 零命中，疑似用干净
  // iframe 的原生 JSON 防篡改），上面的清单钩子失效，扩展和 app 都只剩 DOM 实时采集轨。但播放器随后
  // 用 XHR 把**选中轨的字幕文件**（明文 TTML / WebVTT，oca.nflxvideo.net/?o=…）整份下下来。这里直接
  // 嗅探 XHR / fetch 响应正文：像字幕就当整集轨投出去，语言取播放器 API 的当前轨 bcp47。不依赖清单
  // 形状、不依赖 URL 形状——MSL 再怎么变都不影响；用户切轨会触发新下载，每种语言各抓一次。
  // 清单钩子保留作次要通道（老版本页面仍走它，且能一次拿到全部语言）。
  var seenSubtitleBodies = Object.create(null);
  function bodyKey(url, text) { return String(url || '') + '#' + String(text || '').length; }
  function subtitleFormatOf(head) {
    var h = String(head || '').slice(0, 4000);
    if (/^﻿?\s*WEBVTT/.test(h)) return 'webvtt';
    if (/<tt[\s>]/.test(h)) return 'ttml';
    return null;
  }
  // 正片播放器：Netflix 同页同时挂着多个播放器会话（浏览页的 billboard 预告、悬停预览、正片），
  // 正片会话 id 以 'watch' 开头。只认它——没有正片会话就是没有（返回 null），绝不退化成「随便
  // 最后一个」：那会把 seek / 暂停 / 选轨打到预告片播放器上，正片纹丝不动。
  function nfPlayer() {
    try {
      var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
      var ids = vp.getAllPlayerSessionIds() || [];
      for (var i = ids.length - 1; i >= 0; i--) {
        if (String(ids[i]).indexOf('watch') === 0) return vp.getVideoPlayerBySessionId(ids[i]) || null;
      }
    } catch (_) {}
    return null;
  }
  // 主世界其它脚本（app 的 web_video_glue.js）共用同一个选会话判据，不各写一份。
  window.fushiNetflixPlayer = nfPlayer;
  function currentTextTrack() {
    try {
      var p = nfPlayer();
      var t = p && p.getTimedTextTrack();
      return {
        lang: langOf(t),
        trackId: trackIdOf(t),
        label: trackLabelOf(t),
      };
    } catch (_) { return { lang: 'und', trackId: '', label: '' }; }
  }
  function currentVideoId() {
    try {
      var m = String(window.location.pathname || '').match(/\/watch\/(\d+)/);
      return m ? m[1] : '';
    } catch (_) { return ''; }
  }
  function sniffSubtitleBody(url, text) {
    try {
      if (!text || text.length < 32) return;
      // 清单路径自己抓的轨（URL 在 fetch 前已登记）由 fetchCues 投递，这里不再重复。
      if (url && seenTimedTextUrls[url]) return;
      var format = subtitleFormatOf(text);
      if (!format) return;
      var key = bodyKey(url, text);
      if (seenSubtitleBodies[key]) return;
      seenSubtitleBodies[key] = 1;
      var cur = currentTextTrack();
      var payload = { __fushiNf: 'cues', videoId: currentVideoId(), lang: cur.lang, trackId: cur.trackId, label: cur.label, format: format, text: String(text) };
      cueArchive.push(payload);
      if (cueArchive.length > CUE_ARCHIVE_MAX) cueArchive.shift();
      postCuesMessage(payload);
    } catch (_) {}
  }
  function decodeBytes(buf, limit) {
    try {
      var n = Math.min(buf.byteLength, limit);
      return new TextDecoder('utf-8').decode(new Uint8Array(buf, 0, n));
    } catch (_) { return ''; }
  }
  if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype) {
    var xhrOpen = XMLHttpRequest.prototype.open;
    var xhrSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { this.__fushiUrl = String(url); } catch (_) {}
      return xhrOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var rt = xhr.responseType;
            if (rt === '' || rt === 'text') {
              sniffSubtitleBody(xhr.__fushiUrl, xhr.responseText);
            } else if (rt === 'arraybuffer' && xhr.response && xhr.response.byteLength < 4000000) {
              // 媒体分片同样走 arraybuffer（每片 MB 级）：先只解码开头判格式，命中才解码整份。
              if (subtitleFormatOf(decodeBytes(xhr.response, 4000))) {
                sniffSubtitleBody(xhr.__fushiUrl, decodeBytes(xhr.response, xhr.response.byteLength));
              }
            }
          } catch (_) {}
        });
      } catch (_) {}
      return xhrSend.apply(this, arguments);
    };
  }
  if (typeof Response !== 'undefined' && Response.prototype && Response.prototype.text) {
    var respText = Response.prototype.text;
    Response.prototype.text = function () {
      var url = this.url;
      var p = respText.apply(this, arguments);
      try { p.then(function (t) { sniffSubtitleBody(url, t); }, function () {}); } catch (_) {}
      return p;
    };
  }
  // fetch 拿二进制再自己解码（与 XHR arraybuffer 同一判据：先解开头判格式，命中才整份解码）。
  // Response.json() 不拦：TTML / WebVTT 都不是 JSON，能被 json() 成功解析的正文不可能是字幕。
  // Worker 里的下载够不到（Worker 有自己的全局，主世界补丁不生效）——那种情况由消费端的确定性
  // 失败判据兜底（播放器已在显示该轨文字、整轨却没截到 → 标失败）。
  if (typeof Response !== 'undefined' && Response.prototype && Response.prototype.arrayBuffer) {
    var respArrayBuffer = Response.prototype.arrayBuffer;
    Response.prototype.arrayBuffer = function () {
      var url = this.url;
      var p = respArrayBuffer.apply(this, arguments);
      try {
        p.then(function (buf) {
          if (!buf || buf.byteLength >= 4000000) return;
          if (subtitleFormatOf(decodeBytes(buf, 4000))) sniffSubtitleBody(url, decodeBytes(buf, buf.byteLength));
        }, function () {});
      } catch (_) {}
      return p;
    };
  }

  // ── 播放器状态通道（2026-10 起的主数据源） ──
  // 清单钩子（MSL 不经主世界 JSON.parse）和正文嗅探（播放器的字幕下载不再经主世界 XHR/fetch 原型）
  // 实测都零命中，菜单里只剩「这个视频还没有字幕轨」；同页 asbplayer 照常拿到轨。它现在的做法是：
  // 轨清单取播放器 API getTimedTextTrackList()，下载地址从正片会话的播放器状态里按**结构**找
  // （type==='timedtext' 且带 urls[] 的对象，不依赖混淆后的属性路径）。这里同判据：
  //   · 全部文字轨先作「待加载」占位投给隔离世界（{__fushiNf:'tracks'}），菜单 / 侧边栏立刻能列出；
  //   · 状态里已有地址的轨（当前显示的那条，或用户在网飞里切过的）直接整轨下载；
  //   · 用户选中仍无地址的占位轨（{__fushiNf:'fetchTrack'}）→ 临时把网飞字幕切到那条让播放器下发
  //     地址，拿到后切回原轨（asbplayer fetchDataForLanguage 同款）。
  function nfWatchSessionId() {
    try {
      var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
      var ids = vp.getAllPlayerSessionIds() || [];
      for (var i = ids.length - 1; i >= 0; i--) {
        if (String(ids[i]).indexOf('watch') === 0) return String(ids[i]);
      }
    } catch (_) {}
    return null;
  }
  // 会话状态里 trackId → 下载地址。时序上 timedtext 对象在会话根下约 12 层，深度 20 封顶留余量。
  //
  // 节点预算（状态树是页面数据，大小不由我们定）：遍历跑在网飞页主线程上，一次不封顶的整树遍历
  // 会把播放卡住。所以遍历是**可续的**——每片最多 STATE_WALK_STEP_NODES 个节点，做完一片让出
  // 主线程（拍子里留到下一拍、按需取轨里 setTimeout 0 续上），已找到的地址每片都立即可用。
  //   · 每片 20 000 节点：本机实测（60 万节点的合成状态树）约 0.67 µs / 节点，一片 ≈ 13 ms；
  //     按低端机慢 4 倍算 ≈ 55 ms，与 Long Task（50 ms）门槛同量级，不会造成可感知的卡顿。
  //   · 单次遍历总上限 1 000 000 节点：asbplayer 在线上网飞对同一棵子树做的是**不封顶的同步遍历**
  //     （每次按需取轨都扫），百万节点在那条路上要阻塞 0.7–3 s，用户必然察觉——据此推断真实状态
  //     远小于此（推断，未在真网飞上计数）。超过上限只可能是网飞改版后状态里挂进了无关的大对象图：
  //     放弃这次遍历、只用已找到的部分，打一条诊断，状态通道降级（占位轨仍在，按需取轨投 cuesFailed）。
  var STATE_WALK_STEP_NODES = 20000;
  var STATE_WALK_MAX_NODES = 1000000;
  var stateWalkOverBudgetWarned = false;
  function startStateWalk(sessionId) {
    var walk = { sessionId: sessionId, urls: Object.create(null), stack: [], visited: 0, done: false, overBudget: false,
      seen: typeof WeakSet === 'function' ? new WeakSet() : null, seenList: null };
    if (!walk.seen) walk.seenList = [];
    var root = null;
    try {
      root = window.netflix.appContext.state.playerApp.getState().videoPlayer
        .cadmiumPlayerRepository.playersById[sessionId];
    } catch (_) { root = null; }
    if (root && typeof root === 'object') walk.stack.push({ node: root, depth: 0 });
    else walk.done = true;
    return walk;
  }
  // 推进至多 budget 个节点；栈空 → done；累计超上限 → done + overBudget（降级）。
  function stepStateWalk(walk, budget) {
    var stack = walk.stack;
    var spent = 0;
    while (stack.length && spent < budget) {
      var top = stack.pop();
      var node = top.node;
      if (node === null || typeof node !== 'object' || top.depth > 20) continue;
      if (walk.seen) { if (walk.seen.has(node)) continue; walk.seen.add(node); }
      else { if (walk.seenList.indexOf(node) >= 0) continue; walk.seenList.push(node); }
      spent++;
      walk.visited++;
      if (walk.visited > STATE_WALK_MAX_NODES) {
        walk.overBudget = true;
        stack.length = 0;
        if (!stateWalkOverBudgetWarned) {
          stateWalkOverBudgetWarned = true;
          try { console.warn('[Fushi][BUG-3571] Netflix player state exceeds ' + STATE_WALK_MAX_NODES + ' nodes; state channel degraded'); } catch (_) {}
        }
        break;
      }
      if ((typeof ArrayBuffer !== 'undefined') && (node instanceof ArrayBuffer || ArrayBuffer.isView(node))) continue;
      try {
        if (node.type === 'timedtext' && typeof node.trackId === 'string' && Array.isArray(node.urls) &&
            node.urls.length && node.urls[0] && typeof node.urls[0].url === 'string' && !walk.urls[node.trackId]) {
          walk.urls[node.trackId] = node.urls[0].url;
        }
      } catch (_) {}
      var keys;
      try { keys = Array.isArray(node) ? null : Object.keys(node); } catch (_) { continue; }
      var n = keys ? keys.length : node.length;
      for (var i = 0; i < n; i++) {
        var v;
        try { v = keys ? node[keys[i]] : node[i]; } catch (_) { continue; }
        if (v !== null && typeof v === 'object') stack.push({ node: v, depth: top.depth + 1 });
      }
    }
    if (!stack.length) walk.done = true;
    return walk;
  }
  // 按需取轨用：分片走完整棵树（片间 setTimeout 0 让出主线程），找到 wantTrackId 就提前收工。
  function walkStateUntil(sessionId, wantTrackId, cb) {
    var walk = startStateWalk(sessionId);
    (function next() {
      try { stepStateWalk(walk, STATE_WALK_STEP_NODES); } catch (_) { walk.done = true; }
      if (walk.done || (wantTrackId && walk.urls[wantTrackId])) { cb(walk); return; }
      setTimeout(next, 0);
    })();
  }
  // 可读文字轨（跳过「关」、强制窄轨与图片字幕——后者解析不出文字）。
  function textTrackMetaOf(t) {
    if (!t || t.isNoneTrack || t.isForcedNarrative || t.isImageBased) return null;
    var lang = trackLangOf(t);
    if (!lang) return null;
    return { lang: String(lang), trackId: trackIdOf(t), label: trackLabelOf(t) };
  }
  function textTracksOf(p) {
    var out = [];
    var list = null;
    try { list = p && p.getTimedTextTrackList ? p.getTimedTextTrackList() : null; } catch (_) { list = null; }
    if (!list || !list.length) return out;
    for (var i = 0; i < list.length; i++) {
      var meta = textTrackMetaOf(list[i]);
      if (meta && meta.trackId) out.push({ meta: meta, track: list[i] });
    }
    return out;
  }
  var lastTracksPayload = null;
  var lastTracksSig = '';
  var stateWalkBurst = 0; // 轨清单 / 当前轨变化后接连几拍都扫状态（地址常比切轨晚到）
  var stateTicks = 0;
  var harvestWalk = null; // 拍子里在途的分片遍历（跨拍续上）
  function harvestPlayerState() {
    try {
      var videoId = currentVideoId();
      if (!videoId) return;
      var sid = nfWatchSessionId();
      if (!sid) return;
      var p = nfPlayer();
      var tracks = textTracksOf(p);
      if (!tracks.length) return;
      var active = currentTextTrack().trackId;
      var sig = videoId + '|' + active + '|' + tracks.map(function (t) { return t.meta.trackId; }).join(',');
      if (sig !== lastTracksSig) {
        lastTracksSig = sig;
        stateWalkBurst = 5;
        harvestWalk = null; // 清单 / 当前轨变了：旧快照作废，下面从新状态重扫
        lastTracksPayload = { __fushiNf: 'tracks', videoId: videoId, tracks: tracks.map(function (t) { return t.meta; }) };
        postCuesMessage(lastTracksPayload);
      }
      stateTicks++;
      if (!harvestWalk || harvestWalk.sessionId !== sid) {
        if (stateWalkBurst > 0) stateWalkBurst--;
        else if (stateTicks % 8 !== 0) return; // 平时约 16 s 才起一次新遍历，不每拍遍历整棵状态
        harvestWalk = startStateWalk(sid);
      }
      // 每拍只推进一片（见 STATE_WALK_STEP_NODES），大状态分几拍走完；已找到的地址立即下载。
      stepStateWalk(harvestWalk, STATE_WALK_STEP_NODES);
      var urls = harvestWalk.urls;
      if (harvestWalk.done) harvestWalk = null;
      for (var i = 0; i < tracks.length; i++) {
        var url = urls[tracks[i].meta.trackId];
        if (url) fetchTimedText(videoId, tracks[i].meta, url, null);
      }
    } catch (_) {}
  }
  if (typeof setInterval === 'function') {
    try { setInterval(harvestPlayerState, 2000); } catch (_) {}
  }

  // 按需取一条还没有地址的轨。串行：同时切两条轨会互相把对方切回去。
  var fetchTrackChain = null;
  function nfFetchTrack(trackId) {
    var videoId = currentVideoId();
    var p = nfPlayer();
    var sid = nfWatchSessionId();
    var tracks = textTracksOf(p);
    var hit = null;
    for (var i = 0; i < tracks.length; i++) if (tracks[i].meta.trackId === trackId) hit = tracks[i];
    if (!p || !sid || !hit) {
      postCuesFailed(videoId, hit ? hit.meta.lang : 'und', trackId, 'track not found');
      return Promise.resolve();
    }
    var overBudget = false;
    function findUrl() {
      return new Promise(function (resolve) {
        walkStateUntil(sid, trackId, function (walk) {
          if (walk.overBudget) overBudget = true;
          resolve(walk.urls[trackId] || null);
        });
      });
    }
    var prev = null;
    function revert() {
      if (!prev) return Promise.resolve();
      try { return Promise.resolve(p.setTimedTextTrack(prev)).catch(function () {}); } catch (_) { return Promise.resolve(); }
    }
    return findUrl().then(function (known) {
      if (known) {
        // 地址已在（之前取过），去重标记可能还在：撤掉让这次真下载一遍。
        delete seenTimedTextUrls[known];
        fetchTimedText(videoId, hit.meta, known, null);
        return null;
      }
      if (overBudget) {
        // 状态树超预算（见 STATE_WALK_MAX_NODES）：不去临时切轨——切过去也找不到地址，只会让用户
        // 白看 10 s 别的字幕。直接投确定失败。
        postCuesFailed(videoId, hit.meta.lang, trackId, 'player state too large');
        return null;
      }
      try { prev = p.getTimedTextTrack(); } catch (_) { prev = null; }
      return Promise.resolve()
        .then(function () { return p.setTimedTextTrack(hit.track); })
        .then(function () {
          // 轮询地址（计次封顶而不是按墙钟：40 轮 × 250 ms ≈ 10 s；每轮是一次分片完整遍历）。
          return new Promise(function (resolve) {
            var tries = 0;
            (function poll() {
              findUrl().then(function (url) {
                if (url || overBudget || ++tries >= 40) { resolve(url || null); return; }
                setTimeout(poll, 250);
              });
            })();
          });
        })
        .then(function (url) {
          return revert().then(function () {
            if (url) fetchTimedText(videoId, hit.meta, url, null);
            else postCuesFailed(videoId, hit.meta.lang, trackId, overBudget ? 'player state too large' : 'timedtext url never appeared');
          });
        }, function (e) {
          return revert().then(function () {
            postCuesFailed(videoId, hit.meta.lang, trackId, e && e.message ? e.message : e);
          });
        });
    });
  }

  // TODO-1217：player.seek(ms) **返回 ≠ 视频真正重定位完成**。若调完就立刻回 seekDone，content 侧
  // seekTo 会在 Netflix 实际跳转**前**就 resolve → 先 play/录、Netflix 随后才跳 → 用户看到「跳过去又
  // 秒挑回来」的二次跳动。故这里 seek 后轮询 getCurrentTime 逼近目标 ms 再回 seekDone（带超时兜底，
  // 4s 不到位也放行，绝不卡死批量）。
  // done(ok, err)：逼近目标 → ok；4 s 没到位 → ok=false（'timeout'），调用方据此记日志、放弃
  // 「跳转在途」状态，不再把旧位置当成 seek 的结果死等。
  // 新 seek 到来时旧 seek 的轮询立即作废（回 superseded），不叠出成片 80 ms 轮询各等 4 s。
  var nfSeekGen = 0;
  function nfSeek(ms, done) {
    var player = nfPlayer();
    if (!player) throw new Error('no watch player session');
    var gen = ++nfSeekGen;
    player.seek(ms);
    var deadline = Date.now() + 4000;
    (function poll() {
      if (gen !== nfSeekGen) { done(false, 'superseded'); return; }
      var cur = null;
      try { cur = player.getCurrentTime(); } catch (_) { cur = null; }
      if (cur != null && Math.abs(cur - ms) < 300) { done(true, ''); return; } // 已逼近目标：真重定位完成
      if (Date.now() > deadline) { done(false, 'timeout'); return; } // 超时兜底：不卡死批量
      setTimeout(poll, 80);
    })();
  }

  window.addEventListener('message', function (e) {
    if (e.origin !== ORIGIN || e.source !== window) return;
    var d = e.data;
    if (!d) return;
    if (d.__fushiNf === 'replayCues') {
      // content.js（隔离世界）接收端就绪：重放全部已存档 cue，消除注入时序竞态。
      if (lastTracksPayload) postCuesMessage(lastTracksPayload);
      for (var i = 0; i < cueArchive.length; i++) postCuesMessage(cueArchive[i]);
      return;
    }
    if (d.__fushiNf === 'fetchTrack') {
      var trackId = String(d.trackId || '');
      if (!trackId) return;
      var prevChain = fetchTrackChain || Promise.resolve();
      var next = prevChain.catch(function () {}).then(function () { return nfFetchTrack(trackId); });
      fetchTrackChain = next;
      next.catch(function () {}).then(function () { if (fetchTrackChain === next) fetchTrackChain = null; });
      return;
    }
    if (d.__fushiNf !== 'seek') return;
    var replied = false;
    // id 原样回显：同时有多次 seek 在途（拖进度条）时，调用方只认最后一次的回执。
    var reply = function (ok, err) {
      if (replied) return; replied = true;
      try { window.postMessage({ __fushiNf: 'seekDone', ok: ok, err: err || '', id: d.id }, '/'); } catch (_) {}
    };
    try { nfSeek(d.ms, reply); }
    catch (x) { reply(false, String(x)); }
  });
})();
