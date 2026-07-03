// TODO-1087：自动配置默认值。app 安装助手在解压时把当前 server 真值写进 hibiki-defaults.js，
// 于是加载已解压扩展后无需手填。用户仍可在 options 手动覆盖（chrome.storage.local 优先于默认）。
try { importScripts('hibiki-defaults.js'); } catch (_) { /* 缺省文件时回落硬编码默认 */ }
const HIBIKI_DEFAULTS =
    (self.HIBIKI_DEFAULTS) || { host: '127.0.0.1', port: 19633, token: '' };

async function cfg() {
  const saved = await chrome.storage.local.get(['host', 'port', 'token']);
  const host = (saved.host != null && saved.host !== '')
      ? saved.host : HIBIKI_DEFAULTS.host;
  const port = (saved.port != null && saved.port !== 0)
      ? saved.port : HIBIKI_DEFAULTS.port;
  const token = (saved.token != null && saved.token !== '')
      ? saved.token : HIBIKI_DEFAULTS.token;
  return { base: `http://${host}:${port}`, token };
}
function authHeader(token) { return 'Basic ' + btoa('hibiki:' + token); }

// TODO-1000 Netflix：offscreen 文档承载 tabCapture MediaRecorder。批量生成时按字幕逐句「回放
// 录制」——每句 seek 到句首、播到句尾录成一段自包含 webm（beginClip/endClip），随 mineClip 发给
// Hibiki 转 GIF+句子音频。点扩展图标启动（需 activeTab 手势 + 关硬件加速才非黑），跨集自动切换。
let captureActive = false;

async function ensureOffscreen() {
  const has = await chrome.offscreen.hasDocument?.();
  if (has) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html',
    reasons: ['USER_MEDIA'],
    justification: 'Record the streaming tab to build Anki GIF cards (TODO-1000).',
  });
}

// 徽标反馈：录制中在扩展图标上打红点，让用户**看得见**正在录（否则不知道录没录 → 制卡无音频
// 时误以为坏了）。tabCapture 需用户手势（点图标）启动，无法自动开——这是 Chrome 平台约束。
function setRecordingBadge(on) {
  try {
    chrome.action.setBadgeBackgroundColor({ color: on ? '#D32F2F' : '#00000000' });
    chrome.action.setBadgeText({ text: on ? '●' : '' });
    chrome.action.setTitle({
      title: on
          ? 'Hibiki：正在生成 Netflix 制卡（逐句回放录制中）'
          : 'Hibiki：点击生成 Netflix 制卡队列（逐集自动回放录制）',
    });
  } catch (_) { /* setBadge 在某些上下文不可用：忽略，不影响录制 */ }
}

// 录制真相源是 **offscreen 文档**（它持有 MediaStream，跨整场持续录），不是这个易失的
// captureActive 标志——MV3 的 service worker 空闲约 30s 就被杀、重启后全局变量复位成 false，
// 但 offscreen 仍在录。故所有「在不在录」的判断都回 offscreen 问真态，SW 重启也不误判。
async function isOffscreenRecording() {
  try {
    const has = await chrome.offscreen.hasDocument?.();
    if (!has) return false;
    const resp = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'isRecording' });
    return !!(resp && resp.recording);
  } catch (_) { return false; }
}

// SW 启动 / 点图标前：从 offscreen 真态回填 captureActive + 徽标（修复休眠重启后红点消失、
// 制卡误判「没录制」）。
async function syncCaptureState() {
  captureActive = await isOffscreenRecording();
  setRecordingBadge(captureActive);
  return captureActive;
}
syncCaptureState().catch(() => {}); // SW 每次启动都对齐一次真态

async function startTabCapture(tabId) {
  await ensureOffscreen();
  const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
  const resp = await chrome.runtime.sendMessage({
    target: 'offscreen', type: 'startCapture', streamId,
  });
  captureActive = !!(resp && resp.ok);
  setRecordingBadge(captureActive);
  return captureActive;
}

async function stopTabCapture() {
  try {
    await chrome.runtime.sendMessage({ target: 'offscreen', type: 'stopCapture' });
  } catch (_) { /* offscreen 已关：忽略 */ }
  captureActive = false;
  setRecordingBadge(false);
}

// Netflix 跨剧集批量：点扩展图标(手势)→ 依次自动导航到每个含待生成项的剧集，逐句回放录制出卡，
// 全部完成回原页。activeTab 在 netflix.com 同源导航间持续有效，故一次手势覆盖所有剧集。状态存
// chrome.storage（跨导航/SW 重启存活），由每次注入的 content script 驱动（见 content.js 续跑）。
async function hibikiStartNetflixBatch(tab) {
  const got = await chrome.storage.local.get(['hibikiQueue']);
  const q = Array.isArray(got.hibikiQueue) ? got.hibikiQueue : [];
  const episodes = [];
  for (const it of q) {
    if (it && it.site === 'netflix' && it.netflixId && episodes.indexOf(it.netflixId) < 0) {
      episodes.push(it.netflixId);
    }
  }
  if (!episodes.length) {
    try { await chrome.tabs.sendMessage(tab.id, { type: 'hibikiToastMsg', text: '队列里没有 Netflix 待生成项' }); } catch (_) {}
    return;
  }
  await chrome.storage.local.set({ hibikiNfBatch: { active: true, episodes: episodes, idx: 0, originalUrl: tab.url } });
  await startTabCapture(tab.id); // 手势启动录屏（Chrome 硬性要求）
  await chrome.tabs.update(tab.id, { url: 'https://www.netflix.com/watch/' + episodes[0] });
}

chrome.action.onClicked.addListener((tab) => {
  if (!tab || tab.id == null) return;
  (async () => {
    if (tab.url && tab.url.indexOf('netflix.com') >= 0) await hibikiStartNetflixBatch(tab);
  })().catch(() => {});
});

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  // 发给 offscreen 的消息由 offscreen 处理，background 不插手。
  if (msg && msg.target === 'offscreen') return false;
  (async () => {
    const { base, token } = await cfg();
    try {
      if (msg.type === 'lookup') {
        const r = await fetch(base + '/api/lookup/dictionary', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ term: msg.term, record: msg.record === true }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'mine') {
        // 纯文本挖词（非流媒体页 / 回落）：直接 POST {fields,sentence}，无媒体。
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ fields: msg.fields, sentence: msg.sentence || '' }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'mineYoutube') {
        // 批量制卡（YouTube，非 DRM）：视频ID + 视频时间窗 → 服务端 resolveYoutubeSource 从真实
        // 流精确裁 GIF+音频。无需录屏、无回放、无跳动。
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({
            fields: msg.fields, sentence: msg.sentence || '',
            youtubeVideoId: msg.youtubeVideoId,
            clipStartMs: msg.startMs, clipEndMs: msg.endMs,
          }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'mineClip') {
        // Netflix 回放录到的整段 webm → 服务端整段裁 [0,时长] 转 GIF+音频（无偏移运算）。
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ fields: msg.fields, sentence: msg.sentence || '', clipBase64: msg.clipBase64, clipDurationMs: msg.clipDurationMs }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'nfEnsureCapture') {
        // 导航后流可能已断：还在录就复用，否则用仍有效的 activeTab 重取 streamId 重启（无需新手势）。
        const rec = await isOffscreenRecording();
        if (!rec && _sender.tab && _sender.tab.id != null) await startTabCapture(_sender.tab.id);
        sendResponse({ ok: true });
      } else if (msg.type === 'nfNavigate') {
        if (_sender.tab && _sender.tab.id != null) await chrome.tabs.update(_sender.tab.id, { url: msg.url });
        sendResponse({ ok: true });
      } else if (msg.type === 'nfFinish') {
        await stopTabCapture();
        try { await chrome.storage.local.remove(['hibikiNfBatch']); } catch (_) {}
        if (_sender.tab && _sender.tab.id != null && msg.originalUrl) {
          await chrome.tabs.update(_sender.tab.id, { url: msg.originalUrl });
        }
        sendResponse({ ok: true });
      } else {
        sendResponse({ ok: false, error: 'unknown' });
      }
    } catch (e) {
      sendResponse({ ok: false, error: String(e) });
    }
  })();
  return true;
});
