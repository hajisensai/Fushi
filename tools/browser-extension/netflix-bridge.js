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
  // 抓到的 cue payload 一律存档；content.js 就绪后发 {__hibikiNf:'replayCues'} 请求，这里整批重放。
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

  function langOf(track) {
    return (track && (track.language || track.bcp47 || track.new_track_id)) || 'und';
  }

  function fetchCues(videoId, track) {
    try {
      if (track && (track.isNoneTrack || track.isForcedNarrative)) return; // 跳过 [None]/强制窄轨
      var picked = pickTrackUrl(track);
      if (!picked || seenTimedTextUrls[picked.url]) return;
      seenTimedTextUrls[picked.url] = 1;
      var lang = langOf(track);
      fetch(picked.url, { credentials: 'include' })
        .then(function (r) { return r.text(); })
        .then(function (text) {
          if (!text) return;
          var payload = { __hibikiNf: 'cues', videoId: videoId, lang: lang, format: picked.format, text: text };
          cueArchive.push(payload);
          if (cueArchive.length > CUE_ARCHIVE_MAX) cueArchive.shift();
          postCuesMessage(payload);
        })
        .catch(function () {});
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

  // TODO-1217：player.seek(ms) **返回 ≠ 视频真正重定位完成**。若调完就立刻回 seekDone，content 侧
  // seekTo 会在 Netflix 实际跳转**前**就 resolve → 先 play/录、Netflix 随后才跳 → 用户看到「跳过去又
  // 秒挑回来」的二次跳动。故这里 seek 后轮询 getCurrentTime 逼近目标 ms 再回 seekDone（带超时兜底，
  // 4s 不到位也放行，绝不卡死批量）。
  function nfSeek(ms, done) {
    var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
    var ids = vp.getAllPlayerSessionIds();
    if (!ids || !ids.length) throw new Error('no player session');
    // 取最近的会话（看片会话通常是最后一个）。
    var player = vp.getVideoPlayerBySessionId(ids[ids.length - 1]);
    player.seek(ms);
    var deadline = Date.now() + 4000;
    (function poll() {
      var cur = null;
      try { cur = player.getCurrentTime(); } catch (_) { cur = null; }
      if (cur != null && Math.abs(cur - ms) < 300) { done(); return; } // 已逼近目标：真重定位完成
      if (Date.now() > deadline) { done(); return; } // 超时兜底：不卡死批量
      setTimeout(poll, 80);
    })();
  }

  window.addEventListener('message', function (e) {
    if (e.origin !== ORIGIN || e.source !== window) return;
    var d = e.data;
    if (!d) return;
    if (d.__hibikiNf === 'replayCues') {
      // content.js（隔离世界）接收端就绪：重放全部已存档 cue，消除注入时序竞态。
      for (var i = 0; i < cueArchive.length; i++) postCuesMessage(cueArchive[i]);
      return;
    }
    if (d.__hibikiNf !== 'seek') return;
    var replied = false;
    var reply = function (ok, err) {
      if (replied) return; replied = true;
      try { window.postMessage({ __hibikiNf: 'seekDone', ok: ok, err: err || '' }, '/'); } catch (_) {}
    };
    try { nfSeek(d.ms, function () { reply(true, ''); }); }
    catch (x) { reply(false, String(x)); }
  });
})();
