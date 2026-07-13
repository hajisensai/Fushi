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

// BUG-726：扩展自更新。app 启动时会把 <appSupport> 的已解压副本刷新到当前内置版本，并把
// 内容指纹写进 hibiki-defaults.js（build）+ 随查词响应下发（extensionBuild）。这里比对
// 两者：不一致 = 磁盘上已有新版而当前加载的还是旧版 → chrome.runtime.reload() 从磁盘拉新
// （等价于扩展管理页的「重新加载」，未解压包路径不变）。防护：
// - 任一侧缺指纹（旧 app / 占位默认）→ 不动（向后兼容，绝不空转 reload）；
// - storage 记录已为该指纹 reload 过 → 不再重试（防「磁盘没刷成」时无限循环）；
// - 正在 Netflix 逐句回放录制 → 跳过（reload 会杀掉 offscreen 录制，等录完下次查词再说）。
async function maybeSelfReload(data) {
  try {
    const remote = data && data.extensionBuild;
    const local = HIBIKI_DEFAULTS.build;
    if (!remote || !local || remote === local) return;
    if (await isOffscreenRecording()) return;
    const st = await chrome.storage.local.get(['hibikiReloadedForBuild']);
    if (st.hibikiReloadedForBuild === remote) return;
    await chrome.storage.local.set({ hibikiReloadedForBuild: remote });
    chrome.runtime.reload();
  } catch (_) { /* 自更新失败不影响查词本身 */ }
}

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

// 点扩展图标（唯一手势入口）：
// - 正在生成中/残留卡住状态 → 取消并清理（逃生口）。
// - Netflix 剧集播放页且本集有待生成项 → **就地**逐句回放录制（不 reload！Netflix DRM 会拒绝
//   为一个正在被录屏的**新加载**播放器解密 → M7375；录一个**已经在放**的播放器则没问题）。
// - YouTube → 让页面跑 YouTube 队列生成（等同点浮动按钮）。
async function hibikiIconClick(tab) {
  const got = await chrome.storage.local.get(['hibikiQueue', 'hibikiNfBatch']);
  if (got.hibikiNfBatch && got.hibikiNfBatch.active) {
    await stopTabCapture();
    try { await chrome.storage.local.remove(['hibikiNfBatch']); } catch (_) {}
    try { await chrome.tabs.sendMessage(tab.id, { type: 'hibikiToastMsg', text: '已取消生成' }); } catch (_) {}
    return;
  }
  const url = tab.url || '';
  if (url.indexOf('youtube.com') >= 0) {
    try { await chrome.tabs.sendMessage(tab.id, { type: 'hibikiRunYoutube' }); } catch (_) {}
    return;
  }
  if (url.indexOf('netflix.com') < 0) return;
  const q = Array.isArray(got.hibikiQueue) ? got.hibikiQueue : [];
  // 队列里所有含待生成项的剧集（去重）。当前正播这集若在其中，排到最前 → 它就地录（不导航、手势
  // 现成，最稳）；其余集靠导航（导航时**不录**，到位再录，避开「加载中录屏」的 M7375）。
  const episodes = [];
  for (const it of q) {
    if (it && it.site === 'netflix' && it.netflixId && episodes.indexOf(it.netflixId) < 0) episodes.push(it.netflixId);
  }
  if (!episodes.length) {
    try { await chrome.tabs.sendMessage(tab.id, { type: 'hibikiToastMsg', text: '队列里没有 Netflix 待生成项' }); } catch (_) {}
    return;
  }
  const curId = (url.match(/\/watch\/(\d+)/) || [])[1];
  if (curId && episodes.indexOf(curId) > 0) { episodes.splice(episodes.indexOf(curId), 1); episodes.unshift(curId); }
  await chrome.storage.local.set({ hibikiNfBatch: { active: true, episodes: episodes, idx: 0, originalUrl: url } });
  if (curId && episodes[0] === curId) {
    // 第一集就是当前播放页 → 就地录：立刻起录屏（手势现成消费），content 收到 storage 变化即跑。
    await startTabCapture(tab.id);
  } else {
    // 当前不在第一集 → 导航过去（此时不录；到位后由 content 的 nfEnsureCapture 再开录）。
    await chrome.tabs.update(tab.id, { url: 'https://www.netflix.com/watch/' + episodes[0] });
  }
}

// TODO-1184：manifest 的 action 现在设了 default_popup（vendor/action-popup.html）→ 点图标只会
// 打开 popup，chrome.action.onClicked **永不触发**（故不再注册它）。原「点图标起录/跑队列」入口
// 迁到 action-popup.js 的「开始生成/录制」按钮：按钮点击是用户手势，query 到当前 tab 后发
// hibikiIconAction 消息到这里，由下方 onMessage 分支调用同一个 hibikiIconClick（逻辑不变，只换触发口）。

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  // 发给 offscreen 的消息由 offscreen 处理，background 不插手。
  if (msg && msg.target === 'offscreen') return false;
  // TODO-1184：来自 action popup「开始生成/录制」按钮的手势入口（替代已失效的 onClicked）。
  // popup 已 query 到当前 tab（{id,url}），这里直接跑原 hibikiIconClick（Netflix 就地录 / YouTube 队列）。
  if (msg && msg.type === 'hibikiIconAction') {
    hibikiIconClick(msg.tab || {}).catch(() => {});
    sendResponse({ ok: true });
    return true;
  }
  (async () => {
    const { base, token } = await cfg();
    try {
      if (msg.type === 'dictMediaConfig') {
        // TODO-1215: content-script dict media image rewrite needs the server
        // base URL + token to build GET /api/media/dictionary. Same source as
        // lookup/mine (cfg()): installer-injected defaults or options override.
        sendResponse({ ok: true, base, token });
      } else if (msg.type === 'popupSize') {
        // 弹窗尺寸精细化 Phase D：content.js 拖弹窗右下角把手松手后，把最终基准最大宽高经此
        // 回写 app（POST /api/extension/popup-size，Basic auth 与查词同源）。app 侧 clamp
        // (250-2000/200-1600) + 「拖即解锁」extensionPopupIndependentSize=true + 写扩展键，
        // 下次查词以新尺寸下发。lookup 样板同款鉴权头，不新开无鉴权入口。
        const r = await fetch(base + '/api/extension/popup-size', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ maxWidth: msg.maxWidth, maxHeight: msg.maxHeight }),
        });
        sendResponse({ ok: r.ok, status: r.status });
      } else if (msg.type === 'lookup') {
        const r = await fetch(base + '/api/lookup/dictionary', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ term: msg.term, record: msg.record === true }),
        });
        const data = r.ok ? await r.json() : null;
        sendResponse({ ok: r.ok, status: r.status, data });
        // BUG-726：先回结果再检查自更新（reload 杀 SW，绝不能挡在 sendResponse 前面）。
        maybeSelfReload(data);
      } else if (msg.type === 'lookupAudio') {
        // 单词音频：POST /api/lookup/audio {expression,reading}（Basic auth）→ server 用
        // 与 app 同一 lookupAudio（本地音频库）解析出音频字节，回 {url,contentType}，url 是
        // 免鉴权短命 /api/lookup/audio/file?id=。content-script 的 HTML5 Audio 直接播该 url。
        const r = await fetch(base + '/api/lookup/audio', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ expression: msg.expression || '', reading: msg.reading || '' }),
        });
        if (!r.ok) { sendResponse({ ok: false, status: r.status, url: null }); return; }
        const data = await r.json();
        sendResponse({ ok: !!(data && data.url), url: (data && data.url) || null, contentType: (data && data.contentType) || null });
      } else if (msg.type === 'mine') {
        // 纯文本挖词（非流媒体页 / 回落）：直接 POST {fields,sentence}，无媒体。
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ fields: msg.fields, sentence: msg.sentence || '' }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'duplicate') {
        // TODO-1176：查词弹窗制卡按钮真查重（+→✓，与 app 一致）。POST {expression,reading}
        // → server /api/duplicate，经 Anki 后端判断该词是否已存在，返回 {duplicate:bool}。
        const r = await fetch(base + '/api/duplicate', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ expression: msg.expression || '', reading: msg.reading || '' }),
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
        // BUG-676（TODO-1361 ③）：带上剧名 documentTitle（服务端映射到 Anki {document-title} 视频名
        // 字段）；不发时服务端回落字面「Netflix」。空串不发（保持旧行为 → 回落 Netflix）。
        const r = await fetch(base + '/api/mine', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({
            fields: msg.fields, sentence: msg.sentence || '',
            clipBase64: msg.clipBase64, clipDurationMs: msg.clipDurationMs,
            ...(msg.documentTitle ? { documentTitle: msg.documentTitle } : {}),
          }),
        });
        sendResponse({ ok: r.ok, status: r.status, data: r.ok ? await r.json() : null });
      } else if (msg.type === 'nfEnsureCapture') {
        // 到位后开录：还在录就复用，否则用仍有效的 activeTab 重取 streamId 起录（无需新手势）。
        const rec = await isOffscreenRecording();
        if (!rec && _sender.tab && _sender.tab.id != null) await startTabCapture(_sender.tab.id);
        sendResponse({ ok: true });
      } else if (msg.type === 'nfStopCapture') {
        // 切下一集前停录：录屏绝不在「切集重新加载」时活着 → 避开 M7375。
        await stopTabCapture();
        sendResponse({ ok: true });
      } else if (msg.type === 'nfNavigate') {
        if (_sender.tab && _sender.tab.id != null) await chrome.tabs.update(_sender.tab.id, { url: msg.url });
        sendResponse({ ok: true });
      } else if (msg.type === 'nfFinish') {
        await stopTabCapture();
        try { await chrome.storage.local.remove(['hibikiNfBatch']); } catch (_) {}
        if (_sender.tab && _sender.tab.id != null && msg.originalUrl && _sender.tab.url !== msg.originalUrl) {
          try { await chrome.tabs.update(_sender.tab.id, { url: msg.originalUrl }); } catch (_) {}
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
