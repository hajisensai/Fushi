// asb 移植：通用流媒体字幕桥（manifest 里 world:MAIN、document_start 注入，站点见 manifest
// matches）。做的事与 netflix-bridge.js 同构——在页面主世界拦截站点自己的网络层，拿到字幕轨
// URL 后用页面身份（cookie）抓字幕原文，postMessage 送隔离世界 content.js 解析进
// window.hibikiEpisodeCues（`${host+path}|${label}` 轨）。字幕面板 / 覆盖层 / 查词 / 快捷键
// 零站点特例地消费这些轨。
//
// 四类手法全部来自 asbplayer（extension/src/entrypoints/*-page.ts，MIT；
// 完整版权与许可文本见随扩展分发的 THIRD_PARTY_LICENSES.md）：
//   · TVer / Bilibili.tv —— JSON.parse 纯透传 hook，从站点自己的播放数据里嗅探字幕轨；
//   · Hulu JP —— XMLHttpRequest load 旁路读响应（播放元数据带 tracks）；
//   · Prime Video —— 捕获 GetVodPlaybackResources 请求（URL+body），原样重放一次拿
//     timedTextUrls（TTML）。
// 红线与 netflix-bridge 相同：所有 hook 纯透传、异常绝不外泄、绝不影响站点自身播放。
//
// 时序竞态同 netflix-bridge：本脚本 document_start 抓字幕，content.js document_idle 才注册
// 接收端 → 抓到的 payload 一律存档，content.js 就绪后发 {__hibikiStream:'replayCues'} 整批重放。
//
// 验证状态（诚实标注）：Netflix/YouTube 走既有已验证路径；本文件四站点为 implemented_unverified
// ——提取逻辑逐行对照 asbplayer 已上线代码移植、纯函数部分有 node 单测，但本仓库开发环境无
// 各站点账号，未做真站点端到端验证。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* 页面自带 module 时忽略 */ }
  if (root) root.FUSHI_STREAM_ADAPTERS = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ── 纯函数 track 提取器（node 可测）──
  // 统一输出 [{ label, url, format }]；format ∈ webvtt|srt|ttml|bbjson（content.js 按此分派解析器）。

  function urlParam(url, name) {
    try { return new URL(url, 'https://invalid.example').searchParams.get(name); } catch (_) { return null; }
  }

  // TVer（asb tver-page.ts）：播放数据 JSON 的 tracks[] 里 kind==='captions' 且 type text/vtt。
  function tverTracks(value) {
    var out = [];
    var tracks = value && Array.isArray(value.tracks) ? value.tracks : null;
    if (!tracks) return out;
    for (var i = 0; i < tracks.length; i++) {
      var t = tracks[i];
      if (!t || t.kind !== 'captions') continue;
      if (t.type !== 'text/vtt' && t.type !== 'text/webvtt') continue;
      if (typeof t.src !== 'string' || !t.src || typeof t.srclang !== 'string') continue;
      var label = (typeof t.label === 'string' && t.label) ? (t.srclang + ' - ' + t.label) : t.srclang;
      out.push({ label: label, url: t.src.replace(/^http:\/\//, 'https://'), format: 'webvtt' });
    }
    return out;
  }

  // Bilibili.tv（asb bilibili-page.ts）：data.subtitles[]，url 以 .json 结尾是 bbjson，否则 srt。
  function bilibiliTracks(value) {
    var out = [];
    var subs = value && value.data && Array.isArray(value.data.subtitles) ? value.data.subtitles : null;
    if (!subs) return out;
    for (var i = 0; i < subs.length; i++) {
      var t = subs[i];
      if (!t || typeof t.lang !== 'string' || !t.lang) continue;
      var url = (t.srt && typeof t.srt === 'object' && typeof t.srt.url === 'string') ? t.srt.url
          : (typeof t.url === 'string' ? t.url : '');
      if (!url) continue;
      var format = /\.json([?#]|$)/i.test(url) ? 'bbjson' : 'srt';
      out.push({ label: t.lang, url: url, format: format });
    }
    return out;
  }

  // Hulu JP（asb hulu-jp-page.ts）：播放元数据 {ref_id, tracks[]}，kind==='subtitles'。
  function huluJpTracks(value) {
    if (!value || typeof value.ref_id !== 'string' || !Array.isArray(value.tracks)) return null;
    var out = [];
    for (var i = 0; i < value.tracks.length; i++) {
      var t = value.tracks[i];
      if (!t || t.kind !== 'subtitles') continue;
      if (typeof t.src !== 'string' || !t.src || typeof t.srclang !== 'string') continue;
      out.push({ label: String(t.label || t.srclang), url: t.src, format: 'webvtt' });
    }
    return out.length ? { videoId: value.ref_id, tracks: out } : null;
  }

  // Prime Video（asb amazon-prime-page.ts）：识别 GetVodPlaybackResources 请求（titleId 在
  // query）；捕齐 URL+body 后重放一次，从响应 timedTextUrls.result.subtitleUrls[] 取轨。
  function amazonCapture(url) {
    if (typeof url !== 'string' || url.indexOf('GetVodPlaybackResources') < 0) return null;
    var titleId = urlParam(url, 'titleId');
    return titleId ? { kind: 'vod', titleId: titleId } : null;
  }
  function amazonTracks(json) {
    var out = [];
    var urls = json && json.timedTextUrls && json.timedTextUrls.result &&
        json.timedTextUrls.result.subtitleUrls;
    if (!Array.isArray(urls)) return out;
    for (var i = 0; i < urls.length; i++) {
      var t = urls[i];
      if (!t || typeof t.url !== 'string' || !t.url) continue;
      out.push({
        label: String(t.displayName || t.languageCode || 'und'),
        url: t.url,
        format: 'ttml',
      });
    }
    return out;
  }

  function siteForHost(host) {
    var h = String(host || '');
    if (/(^|\.)tver\.jp$/.test(h)) return 'tver';
    if (/(^|\.)bilibili\.tv$/.test(h)) return 'bilibili';
    if (/^www\.hulu\.jp$/.test(h)) return 'hulu-jp';
    if (/(^|\.)primevideo\.com$/.test(h)) return 'prime';
    if (/(^|\.)amazon\.(com|co\.jp|co\.uk|de|fr|it|es)$/.test(h)) return 'prime';
    return null;
  }

  return {
    tverTracks: tverTracks,
    bilibiliTracks: bilibiliTracks,
    huluJpTracks: huluJpTracks,
    amazonCapture: amazonCapture,
    amazonTracks: amazonTracks,
    siteForHost: siteForHost,
    urlParam: urlParam,
  };
});

// ── 浏览器运行时（node 单测里 window/document 缺省 → 整段跳过）──
(function () {
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  if (window.__hibikiStreamBridge) return; // 防重复注入
  window.__hibikiStreamBridge = true;
  var A = (typeof self !== 'undefined' ? self : window).FUSHI_STREAM_ADAPTERS;
  var site = A.siteForHost(location.hostname);
  if (!site) return;

  // BUG-769 同款：跨世界自投消息用 targetOrigin '/'，接收端比对 window.origin。
  var ORIGIN = window.origin;
  var seenUrls = Object.create(null); // 字幕 URL 去重，同一轨只抓一次
  var archive = [];
  var ARCHIVE_MAX = 120;

  function post(payload) {
    try { window.postMessage(payload, '/'); } catch (_) {}
  }
  function postCues(label, format, text) {
    var payload = {
      __hibikiStream: 'cues',
      path: location.pathname,
      lang: label,
      format: format,
      text: text,
    };
    archive.push(payload);
    if (archive.length > ARCHIVE_MAX) archive.shift();
    post(payload);
  }
  // 拿到轨 URL → 页面身份抓字幕原文 → 送隔离世界。best-effort，失败静默（不影响站点播放）。
  function fetchTrack(track) {
    if (!track || !track.url || seenUrls[track.url]) return;
    seenUrls[track.url] = 1;
    fetch(track.url, { credentials: 'include' })
      .then(function (r) { return r.text(); })
      .then(function (text) { if (text) postCues(track.label, track.format, text); })
      .catch(function () {});
  }
  function fetchTracks(tracks) {
    if (!tracks) return;
    for (var i = 0; i < tracks.length; i++) fetchTrack(tracks[i]);
  }

  window.addEventListener('message', function (e) {
    if (e.origin !== ORIGIN || e.source !== window || !e.data) return;
    if (e.data.__hibikiStream === 'replayCues') {
      // content.js（隔离世界）接收端就绪：重放全部已存档 cue，消除注入时序竞态。
      for (var i = 0; i < archive.length; i++) post(archive[i]);
    }
  });

  // JSON.parse 纯透传 hook（TVer / Bilibili）：先原样返回站点自己的解析结果，再旁路嗅探。
  function installJsonHook(extract) {
    var orig = JSON.parse;
    JSON.parse = function () {
      var r = orig.apply(this, arguments);
      try { fetchTracks(extract(r)); } catch (_) {}
      return r;
    };
  }

  // Hulu JP：XHR load 旁路读响应（站点用 XHR 拉播放元数据）。
  function installHuluJpHook() {
    var origSend = window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.send = function () {
      try {
        this.addEventListener('load', function () {
          try {
            var body = this.response;
            if (typeof body === 'string') {
              try { body = JSON.parse(body); } catch (_) { body = null; }
            }
            var got = A.huluJpTracks(body);
            if (got) fetchTracks(got.tracks);
          } catch (_) {}
        });
      } catch (_) {}
      return origSend.apply(this, arguments);
    };
  }

  // Prime Video：XHR + fetch 双通道捕获 GetVodPlaybackResources 的 URL 与请求体，捕齐后
  // 原样重放一次（POST，同凭据）→ 响应里的 timedTextUrls 即字幕轨。同一 titleId 只重放一次；
  // 切集产生新 titleId 自然重来。重放的是站点自己刚发过的只读请求，无副作用。
  function installAmazonHook() {
    var captured = Object.create(null); // titleId -> { url, body, done }
    function noteUrl(url) {
      var c = A.amazonCapture(url);
      if (!c) return null;
      var slot = captured[c.titleId] || (captured[c.titleId] = {});
      slot.url = url;
      return c;
    }
    function noteBody(titleId, body) {
      var slot = captured[titleId];
      if (!slot || !body) return;
      slot.body = body;
      maybeReplay(titleId);
    }
    function maybeReplay(titleId) {
      var slot = captured[titleId];
      if (!slot || !slot.url || !slot.body || slot.done) return;
      slot.done = true;
      fetch(slot.url, {
        method: 'POST',
        body: slot.body,
        headers: { 'Content-Type': 'application/json' },
        credentials: 'include',
      })
        .then(function (r) { return r.json(); })
        .then(function (json) { fetchTracks(A.amazonTracks(json)); })
        .catch(function () {});
    }
    var origOpen = window.XMLHttpRequest.prototype.open;
    window.XMLHttpRequest.prototype.open = function () {
      try {
        var url = arguments[1];
        if (typeof url === 'string') {
          var c = noteUrl(url);
          if (c) this.__hibikiVodTitleId = c.titleId;
        }
      } catch (_) {}
      return origOpen.apply(this, arguments);
    };
    var origSend = window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.send = function () {
      try {
        if (this.__hibikiVodTitleId && typeof arguments[0] === 'string') {
          noteBody(this.__hibikiVodTitleId, arguments[0]);
        }
      } catch (_) {}
      return origSend.apply(this, arguments);
    };
    var origFetch = window.fetch;
    window.fetch = function (input, init) {
      try {
        var url = typeof input === 'string' ? input : ((input && input.url) || '');
        var c = url ? noteUrl(url) : null;
        if (c) {
          if (init && typeof init.body === 'string') {
            noteBody(c.titleId, init.body);
          } else if (input && typeof input.clone === 'function') {
            // 请求体在 Request 对象上：clone 后读，绝不消耗站点自己的 body。
            input.clone().text()
              .then(function (b) { noteBody(c.titleId, b); })
              .catch(function () {});
          }
        }
      } catch (_) {}
      return origFetch.apply(this, arguments);
    };
  }

  if (site === 'tver') installJsonHook(A.tverTracks);
  else if (site === 'bilibili') installJsonHook(A.bilibiliTracks);
  else if (site === 'hulu-jp') installHuluJpHook();
  else if (site === 'prime') installAmazonHook();
})();
