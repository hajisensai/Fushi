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
          body: JSON.stringify({ term: msg.term, record: true }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'mine') {
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ fields: msg.fields, sentence: msg.sentence || '' }),
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
