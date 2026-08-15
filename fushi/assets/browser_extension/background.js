// TODO-1087：自动配置默认值。app 安装助手在解压时把当前 server 真值写进 fushi-defaults.js，
// 于是加载已解压扩展后无需手填。用户仍可在 options 手动覆盖（chrome.storage.local 优先于默认）。
try { importScripts('fushi-defaults.js', 'connection-diagnostics.js', 'self-update.js'); } catch (_) { /* 缺省文件时回落硬编码默认 */ }
const FUSHI_DEFAULTS =
    (self.FUSHI_DEFAULTS) || { host: '127.0.0.1', port: 19633, token: '' };

let connectionConfigPromise = null;
const LOOKUP_PERF_STORAGE_KEY = 'fushiLookupPerfLogs';
const LOOKUP_PERF_LIMIT = 80;
let lookupPerfSequence = 0;
let lookupPerfLogs = [];
let lookupPerfFlushTimer = null;
let lookupPerfStorageEpoch = 0;
let lookupPerfWritePromise = Promise.resolve();
const lookupPerfReady = chrome.storage.local.get(LOOKUP_PERF_STORAGE_KEY)
  .then((saved) => {
    const items = saved && saved[LOOKUP_PERF_STORAGE_KEY];
    lookupPerfLogs = Array.isArray(items) ? items.slice(-LOOKUP_PERF_LIMIT) : [];
  })
  .catch(() => { lookupPerfLogs = []; });

function nextLookupPerfId() {
  try {
    if (crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  } catch (_) {}
  return Date.now().toString(36) + '-' + (++lookupPerfSequence).toString(36);
}

function parseLookupServerTiming(header) {
  if (!header) return {};
  const names = {
    'request-json': 'serverRequestJsonMs',
    'handler-map': 'serverHandlerMapMs',
    'normalize': 'serverNormalizeMs',
    'popup-cache': 'serverPopupCacheMs',
    'full-cache': 'serverFullCacheMs',
    'ffi-cache': 'serverFfiCacheMs',
    'ffi-lookup': 'serverFfiLookupMs',
    'popup-json': 'serverPopupJsonMs',
    'service-total': 'serverServiceTotalMs',
    'json-encode': 'serverJsonEncodeMs',
    'server-total': 'serverTotalMs',
  };
  const out = {};
  for (const part of String(header).split(',')) {
    const match = /^\s*([a-z-]+)\s*;\s*dur=([0-9]+(?:\.[0-9]+)?)/i.exec(part);
    if (!match) continue;
    const key = names[match[1].toLowerCase()];
    if (!key) continue;
    const value = Number(match[2]);
    if (Number.isFinite(value)) out[key] = value;
  }
  return out;
}

function scheduleLookupPerfFlush() {
  if (lookupPerfFlushTimer !== null) clearTimeout(lookupPerfFlushTimer);
  const epoch = lookupPerfStorageEpoch;
  lookupPerfFlushTimer = setTimeout(() => {
    lookupPerfFlushTimer = null;
    const snapshot = lookupPerfLogs.slice();
    lookupPerfWritePromise = lookupPerfWritePromise.then(async () => {
      if (epoch !== lookupPerfStorageEpoch) return;
      await chrome.storage.local.set({ [LOOKUP_PERF_STORAGE_KEY]: snapshot });
    }).catch(() => {});
  }, 250);
}

function recordLookupPerf(entry, persist = true) {
  const source = entry && typeof entry === 'object' ? entry : {};
  const item = {
    at: new Date().toISOString(),
    ...source,
  };
  // 阅读/字幕原文属于敏感浏览数据。性能日志只保留字符数，不把词句写入 console、
  // chrome.storage 或“复制完整日志”；复现者用时间与 lookup id 关联即可。
  if (typeof item.term === 'string') {
    item.termLength = Array.from(item.term).length;
    delete item.term;
  }
  lookupPerfReady.then(() => {
    lookupPerfLogs.push(item);
    if (lookupPerfLogs.length > LOOKUP_PERF_LIMIT) {
      lookupPerfLogs.splice(0, lookupPerfLogs.length - LOOKUP_PERF_LIMIT);
    }
    if (persist) scheduleLookupPerfFlush();
  });
}
async function cfg() {
  if (!connectionConfigPromise) {
    // Yomitan 的热路径不会在每次扫描前重新读取扩展存储。连接配置在 service worker
    // 生命周期内复用；options 写入时由 storage.onChanged 精确失效。
    connectionConfigPromise = chrome.storage.local.get(['host', 'port', 'token']).then((saved) => {
      const host = (saved.host != null && saved.host !== '')
          ? saved.host : FUSHI_DEFAULTS.host;
      const port = (saved.port != null && saved.port !== 0)
          ? saved.port : FUSHI_DEFAULTS.port;
      const token = (saved.token != null && saved.token !== '')
          ? saved.token : FUSHI_DEFAULTS.token;
      return { base: `http://${host}:${port}`, token };
    }).catch((error) => {
      connectionConfigPromise = null;
      throw error;
    });
  }
  return connectionConfigPromise;
}
function authHeader(token) { return 'Basic ' + btoa('fushi:' + token); }

// BUG-1079：/api/extension/status 请求体统一自报「浏览器中实际加载的版本」
// （FUSHI_DEFAULTS.build + manifest version）。此前写死 '{}'，app 端对浏览器里实际
// 跑的是哪个 build 零感知。旧 app 忽略 body → 向后兼容。
function statusRequestBody() {
  try {
    return self.FUSHI_SELF_UPDATE.statusRequestBody(
        FUSHI_DEFAULTS, chrome.runtime.getManifest().version);
  } catch (_) { return '{}'; }
}

let connectionCache = null;
try {
  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== 'local') return;
    if (changes.host || changes.port || changes.token) {
      connectionConfigPromise = null;
      connectionCache = null;
    }
  });
} catch (_) { /* 非扩展测试壳没有 storage.onChanged。 */ }
async function responseJson(resp) {
  try { return await resp.json(); } catch (_) { return null; }
}
async function diagnoseConnection(force) {
  const { base, token } = await cfg();
  const cacheKey = base + '|' + token;
  const now = Date.now();
  if (!force && connectionCache && connectionCache.key === cacheKey && now - connectionCache.at < 5000) {
    return connectionCache.value;
  }
  let primary = null;
  let legacy = null;
  let version = null;
  let networkError = false;
  try {
    const r = await fetch(base + '/api/extension/status', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
      body: statusRequestBody(),
    });
    primary = { status: r.status, body: await responseJson(r) };
    if (r.status === 404 || r.status === 405) {
      const old = await fetch(base + '/api/lookup/dictionary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
        body: JSON.stringify({ term: '', popupOnly: true }),
      });
      legacy = { status: old.status, body: await responseJson(old) };
    }
    const preliminary = self.FUSHI_CONNECTION.classify(primary, legacy, null, false);
    if (preliminary !== self.FUSHI_CONNECTION.states.connected &&
        preliminary !== self.FUSHI_CONNECTION.states.legacy &&
        preliminary !== self.FUSHI_CONNECTION.states.unauthorized) {
      const v = await fetch(base + '/serverVersion', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      });
      version = { status: v.status, body: await responseJson(v) };
    }
  } catch (_) {
    networkError = true;
  }
  const state = self.FUSHI_CONNECTION.classify(primary, legacy, version, networkError);
  const value = { state, base, port: Number(new URL(base).port) || 19633 };
  connectionCache = { key: cacheKey, at: now, value };
  return value;
}

async function diagnoseConnectionCapped(base, timeoutMs = 750) {
  let timer = null;
  let port = 19633;
  try { port = Number(new URL(base).port) || port; } catch (_) {}
  const fallback = { state: 'offline', base, port };
  try {
    return await Promise.race([
      diagnoseConnection(true).catch(() => fallback),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(fallback), timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== null) clearTimeout(timer);
  }
}

// BUG-726：扩展自更新。app 启动时会把 <appSupport> 的已解压副本刷新到当前内置版本，并把
// 内容指纹写进 fushi-defaults.js（build）+ 随查词响应下发（extensionBuild）。这里比对
// 两者：不一致 = 磁盘上已有新版而当前加载的还是旧版 → chrome.runtime.reload() 从磁盘拉新
// （等价于扩展管理页的「重新加载」，未解压包路径不变）。防护：
// - 任一侧缺指纹（旧 app / 占位默认）→ 不动（向后兼容，绝不空转 reload）；
// - storage 记录已为该指纹 reload 过 → 不再重复 reload（防「磁盘没刷成」时无限循环）；
// - 正在 Netflix 逐句回放录制 → 跳过（reload 会杀掉 offscreen 录制，等录完下次查词再说）。
// BUG-1079：latch 不再是「永久静默」——每次心跳仍重新比对（决策抽成 self-update.js 的
// 纯状态机）：已 reload 过仍不一致 = 自更新失效（用户从别的目录加载 / 磁盘没刷成 /
// 浏览器拒绝 reload），落 chrome.storage.local.fushiUpdateStale {remote, local} 供
// action-popup 显示「需手动重载」提示 + 图标角标；恢复一致时清除 stale 与角标。
async function maybeSelfReload(data) {
  try {
    const remote = data && data.extensionBuild;
    const local = FUSHI_DEFAULTS.build;
    const st = await chrome.storage.local.get(
        ['fushiReloadedForBuild', 'fushiUpdateStale']);
    const decision = self.FUSHI_SELF_UPDATE.decide(
        remote, local, st.fushiReloadedForBuild, await isOffscreenRecording());
    if (decision.action === 'clear') {
      if (st.fushiUpdateStale) {
        await chrome.storage.local.remove(['fushiUpdateStale']);
        refreshUpdateBadge();
      }
      return;
    }
    if (decision.action === 'stale') {
      const prev = st.fushiUpdateStale;
      if (!prev || prev.remote !== remote || prev.local !== local) {
        await chrome.storage.local.set({ fushiUpdateStale: decision.stale });
      }
      refreshUpdateBadge();
      return;
    }
    if (decision.action !== 'reload') return;
    // BUG-1047：置重注入标记，reload 后新 SW 据此把 content script 补回已打开网页
    // （chrome.runtime.reload() 会让所有已注入页的 content script 上下文失效 → 不补的话
    // 用户必须手动刷新浏览器才恢复）。
    await chrome.storage.local.set({
      fushiReloadedForBuild: remote,
      fushiReinjectPending: true,
    });
    chrome.runtime.reload();
  } catch (_) { /* 自更新失败不影响查词本身 */ }
}

// BUG-1079：自更新失效角标。stale 存在且**不在录制**时在扩展图标打「↑」提醒；录制角标
// 优先（红点 ● 绝不被盖掉——录制中本函数整个跳过，录制结束由 setRecordingBadge(false)
// 回调这里恢复）。只动 badge，不动 title（title 归录制状态机管）。
async function refreshUpdateBadge() {
  try {
    if (await isOffscreenRecording()) return; // 录制角标优先
    const st = await chrome.storage.local.get(['fushiUpdateStale']);
    const stale = !!st.fushiUpdateStale;
    chrome.action.setBadgeBackgroundColor({ color: stale ? '#F9A825' : '#00000000' });
    chrome.action.setBadgeText({ text: stale ? '↑' : '' });
  } catch (_) { /* badge 在某些上下文不可用：忽略 */ }
}

// BUG-1047：自更新 chrome.runtime.reload() 会让所有已打开标签页里注入的 content script
// 上下文失效（"Extension context invalidated"），这些页在用户手动刷新前扩展就是死的。
// reload 后由新 SW 把 content script 重新注入已打开的普通网页，页面无感恢复，无需刷新浏览器。
// - 仅对 reload 前置的 fushiReinjectPending 标记生效，普通 SW 冷启动不全量重注入；
// - 逐页探测 window.__fushiExtension（content.js 注入后置真、隔离世界随 reload 被拆即丢），
//   已有活着的 content script 就跳过，避免重复注入导致重复监听；
// - 受限页（chrome:// / 扩展页 / file://）与注入被拒的 tab 逐个 try/catch 忽略。
async function reinjectOpenTabs() {
  if (!chrome.scripting || !chrome.tabs) return;
  const groups = (chrome.runtime.getManifest().content_scripts || [])
      .filter((g) => Array.isArray(g.matches) && g.matches.includes('<all_urls>'));
  if (!groups.length) return;
  let tabs = [];
  try { tabs = await chrome.tabs.query({}); } catch (_) { return; }
  for (const tab of tabs) {
    if (!tab || tab.id == null) continue;
    const url = tab.url || '';
    if (!/^https?:\/\//i.test(url)) continue;
    for (const g of groups) {
      try {
        const probe = await chrome.scripting.executeScript({
          target: { tabId: tab.id },
          func: () => !!window.__fushiExtension,
        });
        if (probe && probe[0] && probe[0].result === true) continue;
        if (Array.isArray(g.css) && g.css.length) {
          await chrome.scripting.insertCSS({ target: { tabId: tab.id }, files: g.css });
        }
        if (Array.isArray(g.js) && g.js.length) {
          await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: g.js });
        }
      } catch (_) { /* 受限页/注入被拒：忽略该 tab */ }
    }
  }
}

async function maybeReinjectAfterReload() {
  try {
    const st = await chrome.storage.local.get(['fushiReinjectPending']);
    if (!st.fushiReinjectPending) return;
    await chrome.storage.local.set({ fushiReinjectPending: false });
    await reinjectOpenTabs();
  } catch (_) { /* 重注入失败：用户仍可手动刷新恢复，不影响其它功能 */ }
}

// 自更新升级点：启动即主动检查版本（此前只有用户实际查词后才比对 → app 升级当天不查词
// 就一直停在旧弹窗）。SW 每次唤醒（顶层）+ 浏览器启动（onStartup）+ 安装/更新（onInstalled）
// 都打一次 /api/extension/status 拿当前内置指纹，走同一个 maybeSelfReload：不一致即从磁盘
// 拉新。附带效果：这次请求也刷新 app 侧扩展 last-seen（连接检测据此判断「插件已正常启用」）。
async function checkVersionOnStartup() {
  try {
    const { base, token } = await cfg();
    // BUG-1079：请求体自报 build/version（不再写死 '{}'），app 端据此显示「浏览器中
    // 实际加载的版本」并在与内置指纹不一致时给出更新提示。
    const r = await fetch(base + '/api/extension/status', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
      body: statusRequestBody(),
    });
    if (!r.ok) return;
    const status = await responseJson(r);
    if (status) await maybeSelfReload(status);
  } catch (_) { /* server 未开 / 离线：启动检查静默失败，下次查词仍会兜底比对 */ }
}
checkVersionOnStartup(); // SW 每次启动都主动检查一次版本 + 刷新 last-seen。
chrome.runtime.onStartup.addListener(() => { checkVersionOnStartup(); });
chrome.runtime.onInstalled.addListener((details) => {
  checkVersionOnStartup();
  // 用户反馈「扩展配置根本看不见」：工具栏图标被 default_popup 占着（onClicked 永不触发，
  // 见下方注释），options_page 在 Chrome 里只能经「chrome://extensions → 详情 → 扩展程序
  // 选项」或右键图标进入，装完扩展的人根本不知道有这一页。首装（且仅首装）自动打开一次，
  // 让用户至少见过它一面；后续更新（details.reason === 'update'）不打扰。
  try {
    if (details && details.reason === 'install') chrome.runtime.openOptionsPage();
  } catch (_) { /* 无 UI 环境 / 已被用户关闭：忽略 */ }
});
maybeReinjectAfterReload(); // BUG-1047：若上一轮是自更新 reload，补回已打开网页的 content script。

// BUG-1045：app 侧「插件已连接」判定 = 扩展最近 120s 内打过本机 server，且该 last-seen
// 只存在 app 内存里（app 重启即丢）。MV3 SW 空闲 ~30s 被回收、无常驻定时器 → 用户不主动
// 划词就会在 ~120s 后被判「未连接」，app 重启后更是一直「未连接」直到下次划词唤醒 SW。
// 用 chrome.alarms 每 60s（< 120s 窗口）唤醒 SW 打一次 /api/extension/status 刷新 last-seen，
// 让连接指示真实反映「扩展已加载可达」，app 重启后 ≤60s 自愈。复用 checkVersionOnStartup
// （既刷 last-seen 又顺带比对版本），自更新仍只在 build 变化时触发一次、由 BUG-1047 无感恢复。
try { chrome.alarms.create('fushiHeartbeat', { periodInMinutes: 1 }); } catch (_) { /* 无 alarms 权限：跳过心跳 */ }
if (chrome.alarms && chrome.alarms.onAlarm) {
  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm && alarm.name === 'fushiHeartbeat') checkVersionOnStartup();
  });
}

// TODO-1000 Netflix：offscreen 文档承载 tabCapture MediaRecorder。批量生成时按字幕逐句「回放
// 录制」——每句 seek 到句首、播到句尾录成一段自包含 webm（beginClip/endClip），随 mineClip 发给
// Fushi 转 GIF+句子音频。点扩展图标启动（需 activeTab 手势 + 关硬件加速才非黑），跨集自动切换。
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
          ? 'Fushi：正在生成 Netflix 制卡（逐句回放录制中）'
          : 'Fushi：点击生成 Netflix 制卡队列（逐集自动回放录制）',
    });
  } catch (_) { /* setBadge 在某些上下文不可用：忽略，不影响录制 */ }
  // BUG-1079：录制角标撤下后恢复自更新失效角标（若 stale 仍在）。录制中绝不动录制红点。
  if (!on) refreshUpdateBadge();
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
async function fushiIconClick(tab) {
  const got = await chrome.storage.local.get(['fushiQueue', 'fushiNfBatch']);
  if (got.fushiNfBatch && got.fushiNfBatch.active) {
    await stopTabCapture();
    try { await chrome.storage.local.remove(['fushiNfBatch']); } catch (_) {}
    try { await chrome.tabs.sendMessage(tab.id, { type: 'fushiToastMsg', text: '已取消生成' }); } catch (_) {}
    return;
  }
  const url = tab.url || '';
  if (url.indexOf('youtube.com') >= 0) {
    try { await chrome.tabs.sendMessage(tab.id, { type: 'fushiRunYoutube' }); } catch (_) {}
    return;
  }
  if (url.indexOf('netflix.com') < 0) return;
  const q = Array.isArray(got.fushiQueue) ? got.fushiQueue : [];
  // 队列里所有含待生成项的剧集（去重）。当前正播这集若在其中，排到最前 → 它就地录（不导航、手势
  // 现成，最稳）；其余集靠导航（导航时**不录**，到位再录，避开「加载中录屏」的 M7375）。
  const episodes = [];
  for (const it of q) {
    if (it && it.site === 'netflix' && it.netflixId && episodes.indexOf(it.netflixId) < 0) episodes.push(it.netflixId);
  }
  if (!episodes.length) {
    try { await chrome.tabs.sendMessage(tab.id, { type: 'fushiToastMsg', text: '队列里没有 Netflix 待生成项' }); } catch (_) {}
    return;
  }
  const curId = (url.match(/\/watch\/(\d+)/) || [])[1];
  if (curId && episodes.indexOf(curId) > 0) { episodes.splice(episodes.indexOf(curId), 1); episodes.unshift(curId); }
  await chrome.storage.local.set({ fushiNfBatch: { active: true, episodes: episodes, idx: 0, originalUrl: url } });
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
// fushiIconAction 消息到这里，由下方 onMessage 分支调用同一个 fushiIconClick（逻辑不变，只换触发口）。

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  // 发给 offscreen 的消息由 offscreen 处理，background 不插手。
  if (msg && msg.target === 'offscreen') return false;
  // TODO-1184：来自 action popup「开始生成/录制」按钮的手势入口（替代已失效的 onClicked）。
  // popup 已 query 到当前 tab（{id,url}），这里直接跑原 fushiIconClick（Netflix 就地录 / YouTube 队列）。
  if (msg && msg.type === 'fushiIconAction') {
    fushiIconClick(msg.tab || {}).catch(() => {});
    sendResponse({ ok: true });
    return true;
  }
  // 原生浏览器侧边栏入口（**尽力而为的兜底路径**，不是主路径）。
  //
  // chrome.sidePanel.open() 要求「瞬态用户激活」，而扩展消息**不传递**用户激活：内容脚本里
  // Shift+S 那个真实按键的激活，跨 runtime.sendMessage 到达 service worker 时已经没有了。
  // 内容脚本自己又调不到 sidePanel API（该命名空间只存在于扩展页面/SW 上下文）。所以页面内
  // 的任何手势都开不了侧边栏——唯一可靠入口是扩展图标 popup，它本身就在扩展上下文里，
  // vendor/action-popup.js 已改成在 click 的同步栈第一句直接调 open()，不再绕这条消息。
  //
  // 这里保留本分支的意义有两条：① 若将来 Chrome 放宽（或 popup 兜底转发到这里）能直接生效；
  // ② **把失败原样回报给调用方**，让页面侧给用户可见提示，而不是静默什么都不发生。
  // 另外：open() 必须是拿到激活后的第一句——原实现先 `await setOptions(...)`，其 resolve 落在
  // 新的宏任务里，激活早已过期，等于自己把仅有的机会也丢掉了。setOptions 不需要激活，挪到
  // open() 之后补（manifest 的 side_panel.default_path 已足以让 open() 用对页面）。
  if (msg && msg.type === 'openSubtitleSidePanel') {
    const tabId = Number.isInteger(msg.tabId)
      ? msg.tabId
      : (_sender && _sender.tab && Number.isInteger(_sender.tab.id) ? _sender.tab.id : null);
    if (tabId == null || !chrome.sidePanel || typeof chrome.sidePanel.open !== 'function') {
      sendResponse({ ok: false, error: 'side-panel-unavailable' });
      return true;
    }
    let opening = null;
    try {
      opening = chrome.sidePanel.open({ tabId });
    } catch (error) {
      sendResponse({ ok: false, error: String(error && error.message || error) });
      return true;
    }
    Promise.resolve(opening).then(
      () => {
        try { chrome.sidePanel.setOptions({ tabId, path: 'side-panel.html', enabled: true }); } catch (_) {}
        sendResponse({ ok: true });
      },
      (error) => { sendResponse({ ok: false, error: String(error && error.message || error) }); });
    return true;
  }
  // 「打开扩展设置」：content script 里 chrome.runtime.openOptionsPage 不可用（只在扩展页面
  // 上下文存在），故页面侧（字幕面板齿轮、报错 toast）统一发这条消息，由 SW 代开。
  if (msg && msg.type === 'openOptions') {
    try { chrome.runtime.openOptionsPage(); } catch (_) {}
    sendResponse({ ok: true });
    return true;
  }
  // BUG-1525：查词性能诊断不走 cfg()/localhost，避免“记录日志”本身污染被测热路径。
  // 最近 80 条异步 debounce 到扩展本地存储；设置页可查看/复制/清空，SW 重启后仍在。
  if (msg && msg.type === 'lookupPerf') {
    recordLookupPerf(msg.entry);
    sendResponse({ ok: true });
    return true;
  }
  if (msg && msg.type === 'lookupPerfGet') {
    lookupPerfReady.then(() => sendResponse({ ok: true, logs: lookupPerfLogs.slice() }));
    return true;
  }
  if (msg && msg.type === 'lookupPerfClear') {
    lookupPerfReady.then(async () => {
      try {
        lookupPerfStorageEpoch += 1;
        lookupPerfLogs = [];
        if (lookupPerfFlushTimer !== null) clearTimeout(lookupPerfFlushTimer);
        lookupPerfFlushTimer = null;
        // 已经进入 storage.set 的旧写入必须先结束，再 remove；epoch 同时让尚未开始的
        // 旧快照失效，清空不会被竞态写回“复活”。
        await lookupPerfWritePromise.catch(() => {});
        await chrome.storage.local.remove(LOOKUP_PERF_STORAGE_KEY);
        sendResponse({ ok: true });
      } catch (error) {
        sendResponse({ ok: false, error: String(error && error.message || error) });
      }
    });
    return true;
  }
  const messageStartedAt = performance.now();
  const messageStartedEpochMs = performance.timeOrigin + messageStartedAt;
  const lookupTrace = msg && msg.type === 'lookup' ? {
    id: nextLookupPerfId(),
    term: String(msg.term || ''),
    maximumTerms: Number.isInteger(msg.maximumTerms)
      ? Math.max(1, Math.min(50, msg.maximumTerms))
      : 10,
    clientSentEpochMs: typeof msg.clientSentEpochMs === 'number'
      ? msg.clientSentEpochMs : null,
    phase: 'handler-enter',
    pendingTimers: [],
  } : null;
  if (lookupTrace) {
    // 正常的快速查询不在 in-flight 期间触发 storage 写入；若超过 1 秒，下面的
    // still-pending 记录会持久化 start + pending，崩溃/永久挂起也有证据。
    recordLookupPerf({
      id: lookupTrace.id,
      surface: 'service-worker',
      stage: 'request-start',
      term: lookupTrace.term,
      maximumTerms: lookupTrace.maximumTerms,
      ...(lookupTrace.clientSentEpochMs != null ? {
        dispatchToHandlerMs: Number(
          Math.max(0, messageStartedEpochMs - lookupTrace.clientSentEpochMs).toFixed(1)),
      } : {}),
    }, false);
    for (const thresholdMs of [1000, 3000]) {
      lookupTrace.pendingTimers.push(setTimeout(() => recordLookupPerf({
        id: lookupTrace.id,
        surface: 'service-worker',
        stage: 'still-pending',
        term: lookupTrace.term,
        maximumTerms: lookupTrace.maximumTerms,
        phase: lookupTrace.phase,
        pendingElapsedMs: thresholdMs,
        actualElapsedMs: Number((performance.now() - messageStartedAt).toFixed(1)),
      }), thresholdMs));
    }
  }
  (async () => {
    let base = `http://${FUSHI_DEFAULTS.host}:${FUSHI_DEFAULTS.port}`;
    let token = FUSHI_DEFAULTS.token;
    let cfgMs = 0;
    try {
      if (lookupTrace) lookupTrace.phase = 'config';
      const cfgStartedAt = performance.now();
      ({ base, token } = await cfg());
      cfgMs = performance.now() - cfgStartedAt;
      if (msg.type === 'dictMediaConfig') {
        // TODO-1215: content-script dict media image rewrite needs the server
        // base URL + token to build GET /api/media/dictionary. Same source as
        // lookup/mine (cfg()): installer-injected defaults or options override.
        sendResponse({ ok: true, base, token });
      } else if (msg.type === 'connectionStatus') {
        sendResponse({ ok: true, connection: await diagnoseConnection(msg.force === true) });
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
        const lookupId = lookupTrace.id;
        const maximumTerms = lookupTrace.maximumTerms;
        lookupTrace.phase = 'fetch-headers';
        const fetchStartedAt = performance.now();
        // 查词 fetch 必须有上限：app 侧一旦长阻塞（词典重载/磁盘 stall），无超时的 await 会让
        // sendResponse 永不被调——Side Panel 的「正在查词…」就永久停留。超时走下方 catch 分支
        // 回错误响应，用户看到可重试的失败文案而不是无限转圈。上限 > Side Panel 兜底(8s)，
        // 正常慢查询不受影响。
        const r = await fetch(base + '/api/lookup/dictionary', {
          method: 'POST',
          signal: AbortSignal.timeout(10000),
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({
            term: msg.term,
            record: msg.record === true,
            // BUG-871: popup HTML already contains the entries; only bestLength is
            // consumed from result, so avoid transferring the full duplicate result.
            popupOnly: true,
            maximumTerms,
            lookupTraceId: lookupId,
          }),
        });
        const headersAt = performance.now();
        const serverTiming = parseLookupServerTiming(r.headers.get('server-timing'));
        const serverCache = r.headers.get('x-fushi-lookup-cache');
        const reflectedTraceId = r.headers.get('x-fushi-lookup-id');
        lookupTrace.phase = 'response-body';
        const raw = r.ok ? await r.text() : '';
        const bodyAt = performance.now();
        let data = null;
        let parseError = null;
        const parseStartedAt = performance.now();
        lookupTrace.phase = 'outer-json-parse';
        if (r.ok) {
          try { data = JSON.parse(raw); } catch (error) { parseError = String(error && error.message || error); }
        }
        const finishedAt = performance.now();
        lookupTrace.phase = 'response-ready';
        for (const timer of lookupTrace.pendingTimers) clearTimeout(timer);
        lookupTrace.pendingTimers = [];
        const lookupPerf = {
          id: lookupId,
          surface: 'service-worker',
          stage: 'response',
          term: String(msg.term || ''),
          maximumTerms,
          status: r.status,
          ok: r.ok && data !== null,
          ...(lookupTrace.clientSentEpochMs != null ? {
            dispatchToHandlerMs: Number(
              Math.max(0, messageStartedEpochMs - lookupTrace.clientSentEpochMs).toFixed(1)),
          } : {}),
          cfgMs: Number(cfgMs.toFixed(1)),
          fetchHeadersMs: Number((headersAt - fetchStartedAt).toFixed(1)),
          responseBodyMs: Number((bodyAt - headersAt).toFixed(1)),
          outerJsonParseMs: Number((finishedAt - parseStartedAt).toFixed(1)),
          totalMs: Number((finishedAt - messageStartedAt).toFixed(1)),
          slow: finishedAt - messageStartedAt >= 1000,
          responseChars: raw.length,
          responseBytes: Number(r.headers.get('content-length')) || null,
          contentEncoding: r.headers.get('content-encoding') || 'identity',
          ...(serverCache ? { serverCache } : {}),
          ...(reflectedTraceId ? { serverTraceMatched: reflectedTraceId === lookupId } : {}),
          ...serverTiming,
          ...(parseError ? { parseError } : {}),
        };
        let connection = null;
        if (!r.ok) {
          // HTTP 失败本身已经终态，先持久化；连接分类另设上限并单独计时，不能让
          // 一个无 timeout 的诊断把查词回调继续挂住或伪装成 SW/IPC 延迟。
          recordLookupPerf(lookupPerf);
          lookupTrace.phase = 'connection-diagnostic';
          const diagnosticStartedAt = performance.now();
          connection = await diagnoseConnectionCapped(base);
          lookupPerf.diagnosticMs = Number(
            (performance.now() - diagnosticStartedAt).toFixed(1));
          recordLookupPerf({
            id: lookupId,
            surface: 'service-worker',
            stage: 'connection-diagnostic',
            term: lookupTrace.term,
            diagnosticMs: lookupPerf.diagnosticMs,
            connectionState: connection.state,
          });
        }
        lookupPerf.responseReadyEpochMs = performance.timeOrigin + performance.now();
        sendResponse({
          ok: r.ok && data !== null,
          status: r.status,
          data,
          lookupPerf,
          ...(!r.ok ? { connection } : {}),
        });
        // 先把结果交给页面，再异步写环形日志；诊断绝不延长弹框首显。
        if (r.ok) recordLookupPerf(lookupPerf);
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
      } else if (msg.type === 'youtubeCaptions') {
        // A（BUG-783 后续）：扩展抓 YouTube 网页视频**真整集字幕**——POST /api/youtube/captions
        // {videoId,preferLang} → server 复用 app 内已修的解析器（androidVr getPlayerResponse +
        // format-3 timedtext），回全部轨（自动/人工）+ cue。Basic auth 与查词同源。best-effort：
        // 失败/无字幕回 {tracks:[]}，content.js 回退 live 采样。
        const r = await fetch(base + '/api/youtube/captions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ videoId: msg.videoId || '', preferLang: msg.preferLang || 'ja' }),
        });
        sendResponse({
          ok: r.ok,
          status: r.status,
          data: r.ok ? await r.json() : null,
          ...(!r.ok ? { connection: await diagnoseConnection(true) } : {}),
        });
      } else if (msg.type === 'parseSubtitle') {
        // B（asb 招牌）：给任意网页视频加载用户自己的外挂字幕文件——扩展读本地 srt/ass/vtt 文本
        // POST /api/subtitle/parse {filename,content} → server 复用 app 内已测 parser 解析成 cue。
        const r = await fetch(base + '/api/subtitle/parse', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ filename: msg.filename || '', content: msg.content || '' }),
        });
        sendResponse({
          ok: r.ok,
          status: r.status,
          data: r.ok ? await r.json() : null,
          ...(!r.ok ? { connection: await diagnoseConnection(true) } : {}),
        });
      } else if (msg.type === 'jimakuSearch') {
        // Jimaku 查字幕①：Side Panel 搜索框 → server /api/subtitle/jimaku/search（server 持
        // 用户在 app 设置里填的 Jimaku API key；真人剧 anime=false 补搜也在 server 侧）。
        const r = await fetch(base + '/api/subtitle/jimaku/search', {
          method: 'POST',
          signal: AbortSignal.timeout(20000),
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({
            query: msg.query || '',
            ...(Number.isInteger(msg.episode) ? { episode: msg.episode } : {}),
            ...(typeof msg.anime === 'boolean' ? { anime: msg.anime } : {}),
          }),
        });
        sendResponse({
          ok: r.ok,
          status: r.status,
          data: r.ok ? await r.json() : null,
          ...(!r.ok ? { connection: await diagnoseConnection(true) } : {}),
        });
      } else if (msg.type === 'jimakuFetch') {
        // Jimaku 查字幕②：候选 handle → server 下载+自动识别编码+解析，响应与
        // /api/subtitle/parse 同形（{format,cues}），Side Panel 直接走既有 InstallTrack。
        const r = await fetch(base + '/api/subtitle/jimaku/fetch', {
          method: 'POST',
          signal: AbortSignal.timeout(30000),
          headers: { 'Content-Type': 'application/json', Authorization: authHeader(token) },
          body: JSON.stringify({ handle: msg.handle || '' }),
        });
        sendResponse({
          ok: r.ok,
          status: r.status,
          data: r.ok ? await r.json() : null,
          ...(!r.ok ? { connection: await diagnoseConnection(true) } : {}),
        });
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
            // BUG-1416：片段时间基锚点 + 句首 + 制卡那一刻（都是**视频时间**），服务端在静态帧
            // 模式下据此在片段里定位取帧。null（老队列项/采样失败）就不发 → 服务端退片段起点。

            ...(typeof msg.clipAnchorMs === 'number' ? { clipAnchorMs: msg.clipAnchorMs } : {}),
            ...(typeof msg.clipAnchorUncertaintyMs === 'number'
              ? { clipAnchorUncertaintyMs: msg.clipAnchorUncertaintyMs } : {}),
            ...(typeof msg.cueStartMs === 'number' ? { cueStartMs: msg.cueStartMs } : {}),
            ...(typeof msg.mineAtMs === 'number' ? { mineAtMs: msg.mineAtMs } : {}),
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
        try { await chrome.storage.local.remove(['fushiNfBatch']); } catch (_) {}
        if (_sender.tab && _sender.tab.id != null && msg.originalUrl && _sender.tab.url !== msg.originalUrl) {
          try { await chrome.tabs.update(_sender.tab.id, { url: msg.originalUrl }); } catch (_) {}
        }
        sendResponse({ ok: true });
      } else {
        sendResponse({ ok: false, error: 'unknown' });
      }
    } catch (e) {
      let lookupPerf = null;
      if (lookupTrace) {
        for (const timer of lookupTrace.pendingTimers) clearTimeout(timer);
        lookupTrace.pendingTimers = [];
        lookupPerf = {
          id: lookupTrace.id,
          surface: 'service-worker',
          stage: 'error',
          term: lookupTrace.term,
          maximumTerms: lookupTrace.maximumTerms,
          cfgMs: Number(cfgMs.toFixed(1)),
          totalMs: Number((performance.now() - messageStartedAt).toFixed(1)),
          error: String(e && e.message || e),
        };
      }
      // 错误日志先落内存，连接诊断若本身超时也不会把真正失败阶段吞掉。
      if (lookupPerf) recordLookupPerf(lookupPerf);
      const diagnosticStartedAt = performance.now();
      const connection = lookupTrace
        ? await diagnoseConnectionCapped(base)
        : await diagnoseConnection(true)
            .catch(() => ({ state: 'offline', base, port: 19633 }));
      if (lookupPerf) {
        lookupPerf.diagnosticMs = Number(
          (performance.now() - diagnosticStartedAt).toFixed(1));
        lookupPerf.responseReadyEpochMs = performance.timeOrigin + performance.now();
        recordLookupPerf({
          id: lookupTrace.id,
          surface: 'service-worker',
          stage: 'connection-diagnostic',
          term: lookupTrace.term,
          diagnosticMs: lookupPerf.diagnosticMs,
          connectionState: connection.state,
        });
      }
      sendResponse({
        ok: false,
        error: String(e),
        ...(lookupPerf ? { lookupPerf } : {}),
        connection,
      });
    }
  })();
  return true;
});
