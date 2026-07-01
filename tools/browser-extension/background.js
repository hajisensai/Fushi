async function cfg() {
  const { host = '127.0.0.1', port = 0, token = '' } =
      await chrome.storage.local.get(['host', 'port', 'token']);
  return { base: `http://${host}:${port}`, token };
}
function authHeader(token) { return 'Basic ' + btoa('hibiki:' + token); }
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
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
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({
            fields: msg.fields,
            sentence: msg.sentence || '',
            timestampMs: msg.timestampMs != null ? msg.timestampMs : null,
            netflixVideoId: msg.netflixVideoId != null ? msg.netflixVideoId : null,
            screenshotBase64: screenshotBase64,
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
