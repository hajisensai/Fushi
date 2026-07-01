async function cfg() {
  const { host = '127.0.0.1', port = 0, token = '' } =
      await chrome.storage.local.get(['host', 'port', 'token']);
  return { base: `http://${host}:${port}`, token };
}
function authHeader(token) { return 'Basic ' + btoa('hibiki:' + token); }

// TODO-1000 Netflix GIF：offscreen 文档承载 tabCapture MediaRecorder（分段滚动录最近一段）。
// 用户点扩展图标在 Netflix 标签开始录制（需 activeTab 手势 + 关硬件加速才非黑）；一键制卡时
// background 向 offscreen 取最近一段 webm，随 mine 一起发给 Hibiki 转 GIF+音频。
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

async function startTabCapture(tabId) {
  await ensureOffscreen();
  const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
  const resp = await chrome.runtime.sendMessage({
    target: 'offscreen', type: 'startCapture', streamId,
  });
  captureActive = !!(resp && resp.ok);
  return captureActive;
}

async function recentClip() {
  if (!captureActive) return null;
  try {
    return await chrome.runtime.sendMessage({ target: 'offscreen', type: 'getRecentClip' });
  } catch (_) { return null; }
}

// 点扩展图标 → 在当前标签开始/切换录制（Netflix GIF 需先开这个）。
chrome.action.onClicked.addListener((tab) => {
  if (tab && tab.id != null) startTabCapture(tab.id).catch(() => {});
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
        // TODO-1000：流媒体制卡带截图（不回放）。Netflix DRM 下需用户关硬件加速才非黑帧；
        // 黑帧/截图失败不阻塞，仍出文本卡。captureVisibleTab 需 activeTab 权限。
        let screenshotBase64 = null;
        if (msg.timestampMs != null || msg.netflixVideoId != null) {
          try {
            const shot = await chrome.tabs.captureVisibleTab(null, { format: 'jpeg', quality: 85 });
            screenshotBase64 = shot ? shot.split(',')[1] : null;
          } catch (_) { /* black/unavailable -> text-only card */ }
        }
        // TODO-1000：若正在录制（用户点了图标启动 tabCapture）→ 取最近一段 webm 送 Hibiki 转 GIF。
        // 服务端优先用 clip（→GIF+音频），失败/无 clip 时回落 screenshot 截图卡。
        let clipBase64 = null;
        let clipDurationMs = null;
        const clip = await recentClip();
        if (clip && clip.clipBase64) {
          clipBase64 = clip.clipBase64;
          clipDurationMs = clip.clipDurationMs || null;
        }
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({
            fields: msg.fields,
            sentence: msg.sentence || '',
            timestampMs: msg.timestampMs != null ? msg.timestampMs : null,
            netflixVideoId: msg.netflixVideoId != null ? msg.netflixVideoId : null,
            screenshotBase64: screenshotBase64,
            clipBase64: clipBase64,
            clipDurationMs: clipDurationMs,
          }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else {
        sendResponse({ ok: false, error: 'unknown' });
      }
    } catch (e) {
      sendResponse({ ok: false, error: String(e) });
    }
  })();
  return true;
});
