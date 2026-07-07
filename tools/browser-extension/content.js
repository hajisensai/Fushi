// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
// 样式经 content.css 注入，全部作用域到 #entries-container，不污染宿主页（TODO-1090）。
// 版本标记：加载后在 Console 打一行，用户可据此确认加载的是**新版**扩展（排查缓存旧版）。
console.log('[Hibiki] content script v41 loaded (TODO-1270: Netflix card subtitle de-dup + hide own overlay/back+flag in capture + pre-roll)');
// 诊断标记：写进 <html> 的 data-*，页面 Console（主世界）可读，用来隔空排查划词为何不触发
// （隔离世界的全局变量在页面 console 里看不到，故用 DOM 属性桥接）。
try { document.documentElement.setAttribute('data-hibiki-cs', 'v41'); } catch (_) {}
// TODO-1190：网页源文里高亮被查的词。selection.js 默认走 CSS Custom Highlight API
// （CSS.highlights.set('hoshi-selection', …) + content.css 的 ::highlight(hoshi-selection)）。
// 但 content script 跑在**隔离世界**：在隔离世界注册的 highlight 不会被页面渲染引擎绘制
// （用户报「浏览器还是没高亮」的根因——1150 只补了调用，没绕开这条平台限制）。故在扩展里
// 强制 selection.js 回落到 **DOM 包裹**路径（<span class="hoshi-dict-highlight"> 直接改共享 DOM，
// 页面渲染引擎必然绘制，与世界隔离无关；关窗时 clearSelection→clearHighlightWrappers 还原）。
// selection.js 先于本脚本加载，这里覆盖它探测出的 true。app 内查词 selection.js 跑在主世界，
// 不加载 content.js，CSS 高亮照常，互不影响。
window.__hoshiCssHighlightsSupported = false;
// TODO-1218①：标记「本页由扩展注入」。popup.js 的页面级 selectText 监听器本为 app 内嵌套弹窗
// 设计，注入宿主页后宿主页自身 hover/click 会误触 selectText→clearSelection，拆掉刚画的划词高亮；
// popup.js 读此 flag 后只处理落在 #entries-container 内的事件（content.js 与 popup.js 同隔离世界共享 window）。
window.__hibikiExtension = true;
const HIBIKI_MOD = 'shiftKey';
const HIBIKI_MAX_LEN = 12;
let hibikiContainer = null;
// BUG-530 性能：划词监听器原来对每次 mousemove 都发查词请求 → 一直按 Shift 移动会把服务器
// 刷爆、UI 卡顿。用「位移阈值 + 同词去重 + 在途请求闸」三重节流：只在移到**不同词**上才查。
let hibikiLastTerm = '';
let hibikiLastX = -1;
let hibikiLastY = -1;
let hibikiPending = false;

// 扩展重载/更新/禁用后，已注入到**已打开标签**里的旧 content script 会「上下文失效」：
// chrome.runtime 变 undefined / 访问抛异常 → 再调 chrome.runtime.sendMessage 就报
// 「Cannot read properties of undefined (reading 'sendMessage')」。守卫掉：失效即静默停手，
// 不再抛错刷 Console；用户重载该页面会注入带有效上下文的新脚本，划词恢复。
function hibikiExtAlive() {
  try {
    return !!(typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id);
  } catch (_) {
    return false;
  }
}

// 轻量页面 toast：制卡全程反馈（开始/成功/失败）+ 解释「为什么这张卡只有截图/没音频」。
// 挂 window 上供 bridge-shim.js（制卡回调）调用。sticky=true 时常驻不自动消失（「制卡中…」要
// 一直显示到出结果），后续用非 sticky 的成功/失败提示替换它并 5s 后淡出。
let hibikiToastTimer = null;
window.hibikiToast = function (text, sticky) {
  try {
    let t = document.getElementById('hibiki-toast');
    if (!t) {
      t = document.createElement('div');
      t.id = 'hibiki-toast';
      t.style.cssText =
        'position:fixed;left:50%;bottom:64px;transform:translateX(-50%);z-index:2147483647;' +
        'max-width:70vw;padding:12px 18px;border-radius:10px;background:rgba(20,20,22,.94);' +
        'color:#fff;font:14px/1.5 "Hiragino Sans",sans-serif;box-shadow:0 6px 24px rgba(0,0,0,.5);' +
        'pointer-events:none;white-space:pre-line;text-align:center;transition:opacity .2s;';
      (document.fullscreenElement || document.body).appendChild(t);
    } else if (t.parentNode !== (document.fullscreenElement || document.body)) {
      (document.fullscreenElement || document.body).appendChild(t); // 全屏切换时迁到正确父节点
    }
    t.textContent = text;
    t.style.opacity = '1';
    if (hibikiToastTimer) clearTimeout(hibikiToastTimer);
    if (!sticky) hibikiToastTimer = setTimeout(() => { if (t) t.style.opacity = '0'; }, 5000);
  } catch (_) { /* DOM 不可用：忽略 */ }
};

// ── 站点 + 视频时间字幕追踪（批量制卡：入队时记这一句的视频时间窗，末尾统一裁）──
function hibikiSite() {
  const h = location.hostname;
  if (h.endsWith('netflix.com')) return 'netflix';
  if (h.endsWith('youtube.com') || h === 'youtu.be') return 'youtube';
  return 'other';
}
function hibikiYoutubeId() {
  try {
    const u = new URL(location.href);
    if (u.hostname === 'youtu.be') return u.pathname.slice(1) || null;
    return u.searchParams.get('v');
  } catch (_) { return null; }
}
function hibikiNetflixId() {
  const m = location.pathname.match(/\/watch\/(\d+)/);
  return m ? m[1] : null;
}
function hibikiVideoTimeMs() {
  const v = document.querySelector('video');
  return v && typeof v.currentTime === 'number' ? Math.round(v.currentTime * 1000) : 0;
}
function hibikiSubtitleTextNow() {
  // Netflix: .player-timedtext；YouTube: .ytp-caption-segment / .captions-text。
  const sels = ['.player-timedtext', '.ytp-caption-segment', '.captions-text'];
  for (const sel of sels) {
    const nodes = document.querySelectorAll(sel);
    if (!nodes.length) continue;
    let s = '';
    for (const n of nodes) s += n.textContent || '';
    if (s.trim()) return s.trim();
  }
  return '';
}
// 当前正在显示的字幕（视频时间）：文本 + 出现时的视频时间。end 在字幕变化时定格。
let hibikiCurText = '';
let hibikiCurStartV = 0;
let hibikiLastSampleV = 0;
// 最近若干句 {text, startV, endV}（视频时间），供倒退/入队时按文本回取已知完整窗。
const hibikiCueHist = [];
function hibikiPushCueV(text, startV, endV) {
  if (!text || endV <= startV) return;
  hibikiCueHist.push({ text: text, startV: startV, endV: endV });
  if (hibikiCueHist.length > 80) hibikiCueHist.shift();
}
function hibikiSampleCue() {
  const nowV = hibikiVideoTimeMs();
  const jumped = hibikiLastSampleV && (nowV < hibikiLastSampleV - 400 || nowV > hibikiLastSampleV + 1500);
  hibikiLastSampleV = nowV;
  const text = hibikiSubtitleTextNow();
  if (jumped) { hibikiCurText = text; hibikiCurStartV = text ? nowV : 0; return; }
  if (text === hibikiCurText) return;
  if (hibikiCurText) hibikiPushCueV(hibikiCurText, hibikiCurStartV, nowV); // 上一句定格
  hibikiCurText = text;
  hibikiCurStartV = text ? nowV : 0;
}
// 当前句的视频时间窗：命中历史（倒退回看过的句）用其完整 [startV,endV]；否则用当前 start +
// 现在的视频时间作暂定 end（Netflix 回放时会按字幕变化重新定 end；YouTube 用此窗即可）。
function hibikiCurrentCueWindowV() {
  if (!hibikiCurText) {
    const last = hibikiCueHist[hibikiCueHist.length - 1];
    return last ? { text: last.text, startV: last.startV, endV: last.endV } : null;
  }
  for (let i = hibikiCueHist.length - 1; i >= 0; i--) {
    if (hibikiCueHist[i].text === hibikiCurText) return { text: hibikiCueHist[i].text, startV: hibikiCueHist[i].startV, endV: hibikiCueHist[i].endV };
  }
  const endV = Math.max(hibikiCurStartV + 1200, hibikiVideoTimeMs());
  return { text: hibikiCurText, startV: hibikiCurStartV, endV: endV };
}
try { setInterval(hibikiSampleCue, 200); } catch (_) {}

// TODO-1219 P3：面板行「精确窗」制卡——从字幕面板行查词时带上该行整集拦截的精确 [startMs,endMs]
// 窗（胜过 hibikiCurrentCueWindowV 的 DOM 采样窗，DOM 采样在暂停/回放/字幕未渲染时不稳）。契约：
// 每次查词都刷新此变量——面板行查词（hibikiLookupAtPoint 带 cueWindow）设精确窗；mousemove 划词
// （无 cueWindow）清成 null 回落 DOM 采样。制卡入口 hibikiEnqueue 优先消费它。null 表示无精确窗。
let hibikiPendingCueWindow = null;

// ── TODO-1219 P1：整集字幕（主世界 netflix-bridge.js 抓清单 timedtext → 这里解析存档）──
// P1 仅存档 + console 验证；P2 面板消费 hibikiEpisodeCues。DOM 采样 hibikiCueHist 仍作回退不删。
// 解析器 parseWebVtt / parseTtml 定义在 subtitle-adapters.js（同隔离世界、先于 content.js 加载）。
const hibikiEpisodeCues = Object.create(null); // key: `${videoId}|${lang}` -> [{startMs,endMs,text}]
// TODO-1219 P2：把整集字幕存档暴露到 window，供隔离世界内后加载的 subtitle-panel.js 消费
// （面板只依赖 window.hibikiEpisodeCues 这一个契约，不跨文件依赖 const 词法作用域）。同一对象
// 引用，后续 hibikiOnFullEpisodeCues 就地写入即对面板可见。
window.hibikiEpisodeCues = hibikiEpisodeCues;
function hibikiOnFullEpisodeCues(msg) {
  try {
    const cues = msg.format === 'ttml' ? parseTtml(msg.text) : parseWebVtt(msg.text);
    if (!cues || !cues.length) return;
    const vid = String(msg.videoId || netflixVideoIdFromPath(location.pathname) || '');
    const key = vid + '|' + (msg.lang || 'und');
    hibikiEpisodeCues[key] = cues;
    try {
      console.log('[Hibiki][TODO-1219] full-episode cues intercepted:', key, cues.length, 'cues; first:', cues.slice(0, 3));
    } catch (_) {}
    // TODO-1219 P2：通知面板有新轨可用（切集/切轨会重放清单）。面板在同一隔离世界、于 content.js
    // 之后加载，注册此钩子；未加载时静默跳过。
    try {
      if (typeof window.hibikiSubtitlePanelOnCues === 'function') window.hibikiSubtitlePanelOnCues(key);
    } catch (_) {}
  } catch (_) {}
}
window.addEventListener('message', (e) => {
  if (e.source !== window || !e.data || e.data.__hibikiNf !== 'cues') return;
  hibikiOnFullEpisodeCues(e.data);
});

// ── 制卡队列（持久化：chrome.storage.local，跨刷新/跨剧集/跨会话累积，随时点击生成）──
// 内存镜像 hibikiQueue 以 storage 为真相源；storage.onChanged 让多标签/重载后计数一致。
let hibikiQueue = [];
function hibikiQueueSave() {
  try { chrome.storage.local.set({ hibikiQueue: hibikiQueue }); } catch (_) {}
}
// 移除已成功生成的项：storage 读-改-写（不改可能被 storage.onChanged 覆盖的内存镜像），跨标签安全。
// 生成过程中别的标签/别集入队都不会被这一步误删（只按 id 剔除本次成功的）。
async function hibikiRemoveQueued(okIds) {
  if (!okIds || !okIds.length) return;
  try {
    const got = await chrome.storage.local.get(['hibikiQueue']);
    const fresh = Array.isArray(got.hibikiQueue) ? got.hibikiQueue : [];
    const remaining = fresh.filter((q) => okIds.indexOf(q.id) < 0);
    hibikiQueue = remaining;
    await chrome.storage.local.set({ hibikiQueue: remaining });
  } catch (_) {}
}
// 制卡结果分类（TODO-1184）：卡已建(success)或已存在(duplicate) → 出队(done，队列才会清)；
// Anki 未配置(notConfigured) → 留队 + 提示用户去配（配好再点生成即可，出队会静默丢词）；
// 其余(error / 网络失败 / 上下文失效) → 留队下次重试。只有 done 才 push 进 okIds 被剔除。
function hibikiClassifyMineResp(resp) {
  if (!resp || !resp.ok || !resp.data) return 'retry';
  const r = resp.data.result;
  if (r === 'success' || r === 'duplicate') return 'done';
  if (r === 'notConfigured') return 'unconfigured';
  return 'retry';
}
function hibikiQueueLoad() {
  try {
    chrome.storage.local.get(['hibikiQueue'], (r) => {
      hibikiQueue = Array.isArray(r && r.hibikiQueue) ? r.hibikiQueue : [];
    });
  } catch (_) {}
}
// TODO-1222：队列去重唯一键 = 词 + 句 + 站点 + 视频ID（同一字幕行重复点「制卡」视为同一条）。
function hibikiQueueKey(q) {
  const word = (q && q.fields && (q.fields.expression || q.fields.word || q.fields.term)) || '';
  const sent = (q && q.sentence) || '';
  const site = (q && q.site) || '';
  const vid = (q && (q.youtubeId || q.netflixId)) || '';
  return String(word) + ' ' + String(sent) + ' ' + String(site) + ' ' + String(vid);
}
window.hibikiEnqueue = function (fields, sentence) {
  // TODO-1219 P3：若本次查词来自字幕面板行（hibikiPendingCueWindow 非空），用该行整集拦截的精确
  // [startMs,endMs] 窗（稳过 DOM 采样）；否则回落 hibikiCurrentCueWindowV 的 DOM 采样窗。下方
  // startV-200/endV+200 录制边距 + hibikiQueueKey 去重两路不变。
  const cw = hibikiPendingCueWindow;
  const w = cw ? { text: cw.text || '', startV: cw.startMs, endV: cw.endMs } : hibikiCurrentCueWindowV();
  if (!w) return { ok: false, reason: 'no-cue' };
  const site = hibikiSite();
  const youtubeId = site === 'youtube' ? hibikiYoutubeId() : null;
  const netflixId = site === 'netflix' ? hibikiNetflixId() : null;
  const item = {
    id: Date.now() + '-' + Math.random().toString(36).slice(2),
    fields: fields, sentence: sentence || w.text || '',
    startV: Math.max(0, w.startV - 200), endV: w.endV + 200,
    site: site,
    youtubeId: youtubeId,
    netflixId: netflixId,
  };
  // TODO-1222：已在队列（同词同句同片）→ 不重复入队，返回 duplicate 让弹窗提示「已在队列中」。
  const key = hibikiQueueKey(item);
  if (hibikiQueue.some((q) => hibikiQueueKey(q) === key)) {
    return { ok: true, count: hibikiQueue.length, duplicate: true };
  }
  hibikiQueue.push(item);
  hibikiQueueSave();
  return { ok: true, count: hibikiQueue.length };
};
// 跨标签/重载同步：storage 变了就刷新内存镜像 + 计数。
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.hibikiQueue) {
      hibikiQueue = Array.isArray(changes.hibikiQueue.newValue) ? changes.hibikiQueue.newValue : [];
    }
  });
} catch (_) {}

// TODO-1221：页面右下角制卡队列 chip 已删——队列 UI 统一到浏览器工具栏图标 popup（vendor/action-popup.html）。
// 队列数据仍以 chrome.storage.local 的 hibikiQueue 为单一真相源，供图标 popup 读取/删除/生成。
try { hibikiQueueLoad(); } catch (_) {}

/**
 * 跟随宿主页配色返回弹窗主题名。
 * @returns {'dark'|'light'}
 */
function hibikiResolveTheme() {
  return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
    ? 'dark'
    : 'light';
}

// 生成全部（YouTube）：逐条把 {videoId,起,止} 发服务端从真实流裁 → 出卡。无录屏、无回放。
// 只移除**成功**的项（失败留在队列下次重试）；跨视频累积的 youtube 项都在此生成。
window.hibikiGenerateAll = async function () {
  const items = hibikiQueue.filter((q) => q.site === 'youtube' && q.youtubeId);
  if (!items.length) {
    window.hibikiToast('YouTube 队列为空：先开字幕 → shift 查词 → 点弹窗「制卡」入队，再来生成');
    return;
  }
  if (!hibikiExtAlive()) { window.hibikiToast('扩展已更新，刷新页面(F5)后重试'); return; }
  let done = 0, fail = 0, unconfigured = 0;
  const okIds = [];
  window.hibikiToast('生成中… 0/' + items.length, true);
  for (const q of items) {
    const cls = await new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({
          type: 'mineYoutube', fields: q.fields, sentence: q.sentence,
          youtubeVideoId: q.youtubeId, startMs: q.startV, endMs: q.endV,
        }, (resp) => {
          try { if (chrome.runtime.lastError) return resolve('retry'); } catch (_) { return resolve('retry'); }
          resolve(hibikiClassifyMineResp(resp));
        });
      } catch (_) { resolve('retry'); }
    });
    // done(成功/已存在)才出队；unconfigured/retry 留队（前者提示配 Anki，后者下次重试）。
    if (cls === 'done') { done++; okIds.push(q.id); }
    else { fail++; if (cls === 'unconfigured') unconfigured++; }
    window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true);
  }
  await hibikiRemoveQueued(okIds);
  if (unconfigured > 0) {
    window.hibikiToast('部分未生成：Anki 未配置，请在 Hibiki 中配置 Anki 后重试（已处理 ' + done + '，保留 ' + fail + '）');
  } else {
    window.hibikiToast('✓ 生成完成：已处理 ' + done + (fail ? ' · 失败 ' + fail : ''));
  }
};

// ── Netflix 回放录制（DRM）：由 content 驱动，capture 经 background/offscreen（beginClip/endClip）──
let hibikiNfBatchRunning = false;

// 生成本剧集的项：逐句 seek 到句首 → 播放到字幕变化(=本句结束) → 停录 → 送服务端整段裁 [0,时长]
// 转 GIF+音频。整场用注入 CSS 藏字幕轨(GIF 不烧字幕，且能扛 Netflix 换节点)+藏鼠标。不停录屏
// （跨集续用，由 nfFinish 收尾）。只移除成功的本集项。
async function hibikiRunNetflixBatch() {
  const nfId = hibikiNetflixId();
  // TODO-1217：按视频时间升序，逐句 seek 单调前进（乱序会往回跳，放大抖动）。filter 已产生新数组，
  // sort 不影响作为跨标签真相源的 hibikiQueue。
  const items = hibikiQueue
    .filter((q) => q.site === 'netflix' && q.netflixId === nfId)
    .sort((a, b) => (a.startV || 0) - (b.startV || 0));
  if (!items.length) return;
  const v = document.querySelector('video');
  if (!v) return;
  // TODO-1175：记录批量前的播放位置/态，批量结束（成功或异常）后都回到这里、恢复原播放/暂停态。
  const resumeAt = v.currentTime;
  const wasPlaying = !v.paused;
  const hideStyle = document.createElement('style');
  hideStyle.id = 'hibiki-nf-hide-sub';
  // TODO-1216：藏字幕轨（GIF 不烧字幕）+ 藏 Netflix 控制/进度条——逐句 seek 与结尾 pause 会强制
  // Netflix 显控制条，落在录制窗会被录进 clip。多选择器兜底 Netflix 改类名（同下方字幕兜底策略）。
  hideStyle.textContent =
    // TODO-1219 P2：字幕列表面板 + 重开小片同批隐藏（GIF 不该录进面板）；P3 再补录制前撤推挤 margin。
    // TODO-1270 Bug B：Hibiki 自己的「生成中」浮层(#hibiki-toast)也在被 tabCapture 录进 GIF
    // （用户报「底部生成中条送给了网飞」）→ 整场批量期间一并隐藏，进度改由扩展图标红点徽标传达。
    '.player-timedtext,#hibiki-subtitle-panel,#hibiki-subtitle-reopen,#hibiki-toast{visibility:hidden!important}' +
    // TODO-1270 Bug B：Netflix 自己的返回按钮(左上)+举报旗帜(右上)是顶部控制层，逐句 seek/pause
    // 会强制其显示 → 落进录制窗。底部控制条之外再隐藏顶部返回/举报容器（多选择器兜底改类名）。
    '.watch-video--bottom-controls-container,.PlayerControlsNeo__layout,' +
    '.watch-video--back-container,[data-uia="control-back"],[data-uia="back-to-browse"],' +
    // 举报旗帜的真实容器 = .watch-video--flag-container（见本文件取词兜底覆盖层清单）。
    '.watch-video--flag-container,[data-uia="player-report-a-problem"],[data-uia="report-a-problem-link"],' +
    '[data-uia="controls-standard"]{opacity:0!important;visibility:hidden!important}';
  try { document.head.appendChild(hideStyle); } catch (_) {}
  // TODO-1219 P3：撤销字幕面板对播放器的推挤（video 恢复全宽），否则录制画面右侧带面板留出的
  // 黑边。面板此刻已被 hideStyle 隐藏；这里只还原播放器宽度。finally 里 hideStyle.remove() 后重挂。
  try { if (typeof window.hibikiSubtitlePanelSuspendPush === 'function') window.hibikiSubtitlePanelSuspendPush(); } catch (_) {}
  const prevCursor = document.body.style.cursor;
  document.body.style.cursor = 'none';
  let done = 0, fail = 0, unconfigured = 0;
  const okIds = [];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const seekTo = (sec) => new Promise((resolve) => {
    const ms = Math.max(0, Math.round(sec * 1000));
    let settled = false;
    const finish = () => {
      if (settled) return; settled = true;
      try { v.removeEventListener('seeked', onSeeked); } catch (_) {}
      try { window.removeEventListener('message', onMsg); } catch (_) {}
      resolve();
    };
    // TODO-1217：落点接近目标才算完成，避免上一次滞后的 seeked 事件提前满足本次 seek。
    const onSeeked = () => { if (Math.abs(v.currentTime * 1000 - ms) < 400) finish(); };
    const onMsg = (e) => { if (e.source === window && e.data && e.data.__hibikiNf === 'seekDone') finish(); };
    v.addEventListener('seeked', onSeeked);
    window.addEventListener('message', onMsg);
    // 走 Netflix 官方播放器 API seek（主世界 netflix-bridge.js 执行），不改 currentTime → 不触发 M7375。
    try { window.postMessage({ __hibikiNf: 'seek', ms: ms }, window.location.origin); } catch (_) {}
    setTimeout(finish, 5000); // 兜底：seeked / seekDone 都不来也继续
  });
  try {
    for (const q of items) {
      let began = false; // beginClip 是否成功（决定 finally 是否需要收口 recorder）
      let cls = 'retry';
      try {
        await seekTo(Math.max(0, q.startV / 1000));
        await sleep(150); // 让首帧稳定
        // TODO-1270 Bug C：先确保真的在播（自动播放策略可能拦），但**一旦在播立刻开录**——不要用
        // 固定 warmup sleep 吃掉入队时预留的 200ms 头部提前量（seek 目标本就是 cueStart-200），
        // 否则录制起点漂到 cueStart 之后 → 用户报「少了一点开头」。仍暂停 → 跳过本句，不录冻结帧。
        try { await v.play(); } catch (_) {}
        for (let i = 0; i < 8 && v.paused; i++) { try { await v.play(); } catch (_) {} await sleep(60); }
        if (v.paused) { fail++; window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
        const beginResp = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'beginClip' });
        began = !!(beginResp && beginResp.ok);
        if (!began) { fail++; window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
        // 本句结束判据：字幕文本变成别的/清空（≠ 这一句），且已过句首 0.4s。refText 用入队时存的整句
        // 文本，比「播放时现采样」稳（避免字幕还没渲染时采到空 → 判据失效整段录到超时）。
        // seek 后字幕要零点几秒才重新渲染：**先等本句字幕真正出现**（过句首 0.3s 后第一段非空字幕
        // 作参照 ref），**再**录到字幕变成别句(=本句结束)才停。不能一开始就比 refText——seek 后先采到
        // 的是残留/空字幕，会被误判成「已结束」→ 录一瞬就停（用户报「一下就停了」根因）。
        // hardEnd 只是字幕检测失效（字幕关/相邻同文本）时的安全上限。
        const startSec = Math.max(0, q.startV) / 1000;
        const hardEnd = startSec + 12; // 12s 硬上限
        const deadline = Date.now() + 16000;
        let ref = '';
        while (v.currentTime < hardEnd && Date.now() < deadline) {
          await sleep(120);
          const nowText = hibikiSubtitleTextNow();
          if (!ref) {
            if (nowText && v.currentTime > startSec + 0.3) ref = nowText; // 抓到本句字幕作参照
            continue;
          }
          if (nowText !== ref) break; // 字幕变成别句 = 本句结束
        }
        try { v.pause(); } catch (_) {}
        const clip = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'endClip' });
        began = false; // 已正常收口，finally 不再重复 endClip
        if (clip && clip.ok && clip.clipBase64) {
          cls = await new Promise((resolve) => {
            chrome.runtime.sendMessage(
              { type: 'mineClip', fields: q.fields, sentence: q.sentence, clipBase64: clip.clipBase64, clipDurationMs: clip.clipDurationMs },
              (resp) => {
                try { if (chrome.runtime.lastError) return resolve('retry'); } catch (_) { return resolve('retry'); }
                resolve(hibikiClassifyMineResp(resp));
              });
          });
        }
      } catch (_) {
        // 录制期异常：不吞进「下一句」，交给 finally 收口 recorder，本句按失败计（下方 else fail++）。
      } finally {
        // V16#2/#3：beginClip 成功但正常路径未走到 endClip（异常/中途 return）→ 这里必收口，
        // 否则 offscreen 录制器泄漏，下一句 beginClip 覆盖 recorder → 旧 MediaRecorder 成孤儿仍占流（状态叠加根因）。
        if (began) {
          try { v.pause(); } catch (_) {}
          try { await chrome.runtime.sendMessage({ target: 'offscreen', type: 'endClip' }); } catch (_) {}
        }
      }
      if (cls === 'done') { done++; okIds.push(q.id); }
      else { fail++; if (cls === 'unconfigured') unconfigured++; }
      window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true);
    }
  } finally {
    // V16#3：无论批量循环正常结束还是中途抛错，都必还原隐藏字幕的样式 + 光标，绝不把
    // cursor:none / 藏字幕样式泄漏到用户可见界面（循环外抛异常留可见副作用的根因）。
    try { hideStyle.remove(); } catch (_) {}
    // TODO-1219 P3：录制结束（成功或异常）后重挂面板推挤，播放器回到收窄态、面板重新贴右显示。
    try { if (typeof window.hibikiSubtitlePanelResumePush === 'function') window.hibikiSubtitlePanelResumePush(); } catch (_) {}
    document.body.style.cursor = prevCursor;
    // TODO-1175/1217：仅当批量前正在播放时才回原位并续播（暂停态制卡不回跳，消除「跳过去又秒挑
    // 回来」的刺眼跳动）；批量前是暂停态则停在当前句、不回跳。
    if (wasPlaying) {
      try { await seekTo(resumeAt); } catch (_) {}
      try { await v.play(); } catch (_) {}
    }
  }
  await hibikiRemoveQueued(okIds);
  if (unconfigured > 0 && typeof window.hibikiToast === 'function') {
    window.hibikiToast('部分未生成：Anki 未配置，请在 Hibiki 中配置 Anki 后重试（保留 ' + fail + '）');
  }
}

// 等 Netflix 播放器就绪（切集后 video 需时间加载）。
async function hibikiWaitForPlayer(timeoutMs) {
  const deadline = Date.now() + (timeoutMs || 20000);
  while (Date.now() < deadline) {
    const v = document.querySelector('video');
    if (v && v.readyState >= 2) return v;
    await new Promise((r) => setTimeout(r, 300));
  }
  return document.querySelector('video');
}

// 跨剧集批量状态机：每次页面(重)注入或状态变 active 后检查——当前是目标集就「等就绪→开录→回放本集
// →停录→跳下一集」；不是目标集(切集重载后)就导航过去。**开录只在到位后**、**跳集前先停录** →
// 录屏绝不在「播放器全新加载」那一刻活着 → 避开 M7375。状态在 storage，跨导航/SW 休眠都存活。防重入。
async function hibikiMaybeResumeNetflixBatch(fromLoad) {
  if (hibikiNfBatchRunning) return;
  hibikiNfBatchRunning = true; // 同步置位（任何 await 前）：堵 setTimeout 与 storage 事件的重入 TOCTOU
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  try {
    if (!hibikiExtAlive() || hibikiSite() !== 'netflix') return;
    let st;
    try { st = (await chrome.storage.local.get(['hibikiNfBatch'])).hibikiNfBatch; } catch (_) { return; }
    if (!st || !st.active) return;
    if (!st.episodes || !st.episodes.length) { // 旧格式残留 → 清
      try { chrome.runtime.sendMessage({ type: 'nfFinish' }); } catch (_) {}
      return;
    }
    const target = st.episodes[st.idx];
    if (hibikiNetflixId() !== target) {
      // 还没到目标集：只有真实页面加载(fromLoad)才驱动导航+计数（storage 变化触发的不导航，免风暴）。
      // 连 4 次真实加载都到不了目标集 → 放弃收尾，绝不无限重载。
      if (!fromLoad) return;
      const attempts = (st.navAttempts || 0) + 1;
      if (attempts > 4) {
        window.hibikiToast('✗ 打不开剧集 ' + target + '，结束生成');
        try { chrome.runtime.sendMessage({ type: 'nfFinish', originalUrl: st.originalUrl }); } catch (_) {}
        return;
      }
      try { await chrome.storage.local.set({ hibikiNfBatch: { active: true, episodes: st.episodes, idx: st.idx, originalUrl: st.originalUrl, navAttempts: attempts } }); } catch (_) {}
      try { chrome.runtime.sendMessage({ type: 'nfNavigate', url: 'https://www.netflix.com/watch/' + target }); } catch (_) {}
      return;
    }
    // 到了目标集：等播放器就绪 → 稳一下 → 开录（此时才开，避开加载中录屏）→ 回放本集队列项 → 停录。
    window.hibikiToast('自动生成：第 ' + (st.idx + 1) + '/' + st.episodes.length + ' 部…', true);
    await hibikiWaitForPlayer(20000);
    if (!document.querySelector('video')) {
      try { chrome.runtime.sendMessage({ type: 'nfFinish', originalUrl: st.originalUrl }); } catch (_) {}
      window.hibikiToast('✗ 播放器未就绪，结束（Netflix 报错就刷新重试）');
      return;
    }
    await sleep(800); // 给播放器/DRM 授权稳一下再开录
    try { await chrome.runtime.sendMessage({ type: 'nfEnsureCapture' }); } catch (_) {}
    await hibikiRunNetflixBatch(); // v34 就地 API-seek 回放本集队列项（内部按当前 netflixId 过滤 + 移除成功）
    try { await chrome.runtime.sendMessage({ type: 'nfStopCapture' }); } catch (_) {} // 跳集前必停录
    const next = st.idx + 1;
    if (next < st.episodes.length) {
      // 前进下一集：新对象不带 navAttempts → 下一集从 0 计数。
      try { await chrome.storage.local.set({ hibikiNfBatch: { active: true, episodes: st.episodes, idx: next, originalUrl: st.originalUrl } }); } catch (_) {}
      try { chrome.runtime.sendMessage({ type: 'nfNavigate', url: 'https://www.netflix.com/watch/' + st.episodes[next] }); } catch (_) {}
    } else {
      try { chrome.runtime.sendMessage({ type: 'nfFinish', originalUrl: st.originalUrl }); } catch (_) {}
      window.hibikiToast('✓ 全部剧集生成完成');
    }
  } finally {
    // V16 遗留缺口：跳集前停录（第 449 行）在正常路径；若 hibikiRunNetflixBatch 抛错
    // 向上传播，该行被跳过 → offscreen 的 MediaStream 不释放、继续录，随后切集导航就
    // 变成「加载中录屏」(M7375) + 流泄漏。故在 finally 里兜底停录（stopTabCapture 幂等，
    // 正常路径已停时重复调用无害）。
    try { await chrome.runtime.sendMessage({ type: 'nfStopCapture' }); } catch (_) {}
    hibikiNfBatchRunning = false;
  }
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg) return;
  if (msg.type === 'hibikiToastMsg' && typeof window.hibikiToast === 'function') window.hibikiToast(msg.text);
  else if (msg.type === 'hibikiRunYoutube' && typeof window.hibikiGenerateAll === 'function') window.hibikiGenerateAll();
});
// 图标点击设 hibikiNfBatch(active) → storage 变化触发就地续跑(本页无重载,fromLoad=false 不导航);
// 切集重载后由 setTimeout(fromLoad=true) 驱动导航到目标集。
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.hibikiNfBatch) {
      const nv = changes.hibikiNfBatch.newValue;
      if (nv && nv.active) hibikiMaybeResumeNetflixBatch(false);
    }
  });
} catch (_) {}
try { setTimeout(function () { hibikiMaybeResumeNetflixBatch(true); }, 1500); } catch (_) {}

function hibikiEnsureContainer() {
  // BUG-530：全屏时（Netflix 看片常全屏）挂在 document.body 上的弹窗会被全屏元素盖住看不见
  // （浏览器全屏只渲染 fullscreenElement 及其后代）→ shift 划词其实触发了但弹窗不可见=「没反应」。
  // 故挂到当前 fullscreenElement（无则 body），并用 position:fixed + 视口坐标，全屏/普通页都对。
  const parent = document.fullscreenElement || document.body;
  if (hibikiContainer && hibikiContainer.parentNode === parent) return hibikiContainer;
  let c = hibikiContainer || document.getElementById('entries-container');
  if (!c) {
    c = document.createElement('div');
    c.id = 'entries-container';
    // 不写死 max-width：宽/高/字号由 popup.css 的 --hibiki-popup-* 变量决定（查词响应下发配置），
    // 取不到时 popup.css 兜底 400px。inline 样式会盖过 CSS，故这里只留定位/层级。
    // 全屏可见性走下方 parent = fullscreenElement||body + position:fixed（BUG-530）。
    c.style.cssText = 'position:fixed;z-index:2147483647;';
    // content.css 把主题变量作用域到 #entries-container[data-theme]，
    // 主题属性必须落在弹窗根上（不再改宿主 <html>），否则文字/背景色回退到空值（TODO-1090）。
    c.setAttribute('data-theme', hibikiResolveTheme());
  }
  if (c.parentNode !== parent) parent.appendChild(c); // 进/出全屏时迁到正确父节点
  hibikiContainer = c;
  return c;
}

// TODO-1272：被查词高亮的覆盖层（扩展自绘、不改宿主页 DOM）。null=未画。
let hibikiHighlightLayer = null;

// 撤掉覆盖层高亮。弹窗关闭 / 切到新词重画前调用。宿主页事件碰不到它，只有这里主动撤。
function hibikiClearHighlightOverlay() {
  if (hibikiHighlightLayer) {
    try { hibikiHighlightLayer.remove(); } catch (_) { /* 已脱离文档 */ }
    hibikiHighlightLayer = null;
  }
}

// TODO-1279：清掉浏览器原生文本选区（window.getSelection 的蓝色高亮）。只动原生 DOM Selection，
// 不碰我们自绘的 #hibiki-highlight-overlay 覆盖层（独立 <div>，与原生选区无关），也不碰
// hoshiSelection.selection（纯 JS 取词状态，覆盖层就从它的 ranges 只读取几何）。塌缩/空选区时
// no-op：避免无谓清掉输入框 caret 或没有可见蓝色时反复调用。
function hibikiClearNativeSelection() {
  try {
    const sel = window.getSelection && window.getSelection();
    if (sel && sel.rangeCount > 0 && !sel.isCollapsed) sel.removeAllRanges();
  } catch (_) { /* 某些跨域/detached 上下文 getSelection 可能抛：静默 */ }
}

// 从 hoshiSelection.selection.ranges 取前 charCount 个「码点」的视口系 client rects（只读
// Range.getClientRects，**不改宿主页 DOM**），并算出整体 bbox 作弹窗锚点。返回 {rects, bounds}。
// 与 selection.js highlightSelection 的裁词逻辑同构，但不做 DOM 包裹。
function hibikiSelectionRects(charCount) {
  const rects = [];
  let bx = null;
  const sel = window.hoshiSelection && window.hoshiSelection.selection;
  if (!sel || !Array.isArray(sel.ranges) || !sel.ranges.length) return { rects, bounds: null };
  let remaining = charCount;
  for (const r of sel.ranges) {
    if (remaining <= 0) break;
    const content = (r.node && r.node.textContent) || '';
    let end = r.start;
    while (end < r.end && remaining > 0) {
      end += String.fromCodePoint(content.codePointAt(end)).length;
      remaining--;
    }
    try {
      const range = document.createRange();
      range.setStart(r.node, r.start);
      range.setEnd(r.node, end);
      for (const cr of range.getClientRects()) {
        if (!cr.width || !cr.height) continue;
        rects.push({ left: cr.left, top: cr.top, width: cr.width, height: cr.height });
        if (!bx) bx = { left: cr.left, top: cr.top, right: cr.right, bottom: cr.bottom };
        else {
          if (cr.left < bx.left) bx.left = cr.left;
          if (cr.top < bx.top) bx.top = cr.top;
          if (cr.right > bx.right) bx.right = cr.right;
          if (cr.bottom > bx.bottom) bx.bottom = cr.bottom;
        }
      }
    } catch (_) { /* 跨节点 range 失败：跳过该段 */ }
  }
  const bounds = bx
    ? { x: bx.left, y: bx.top, width: bx.right - bx.left, height: bx.bottom - bx.top }
    : null;
  return { rects, bounds };
}

// 画覆盖层高亮：给每个 client rect 一个 position:fixed 的透明色块，装进扩展自有的顶层容器
// （挂在 fullscreenElement||body，与弹窗同父，全屏也可见）。不写进宿主页文本节点 → 宿主页
// 框架重渲染 / MutationObserver / 鼠标移动都动不了它，保持到 hibikiClearHighlightOverlay。
function hibikiDrawHighlightOverlay(rects) {
  hibikiClearHighlightOverlay();
  if (!rects || !rects.length) return;
  const parent = document.fullscreenElement || document.body;
  if (!parent) return;
  const layer = document.createElement('div');
  layer.id = 'hibiki-highlight-overlay';
  // 穿透点击、不进宿主页布局；z-index 比弹窗(2147483647)低 1 → 永远在宿主页之上、弹窗之下。
  layer.style.cssText =
    'position:fixed;left:0;top:0;width:0;height:0;margin:0;padding:0;border:0;' +
    'z-index:2147483646;pointer-events:none;';
  // 高亮色跟随弹窗主题（--hoshi-primary-highlight 落在 #entries-container 上）；取不到用 content.css 同款兜底。
  let color = 'rgba(160, 160, 160, 0.4)';
  try {
    if (hibikiContainer) {
      const v = getComputedStyle(hibikiContainer).getPropertyValue('--hoshi-primary-highlight').trim();
      if (v) color = v;
    }
  } catch (_) { /* getComputedStyle 不可用：用兜底色 */ }
  for (const r of rects) {
    const box = document.createElement('div');
    box.style.cssText =
      'position:fixed;pointer-events:none;border-radius:2px;background-color:' + color + ';' +
      'left:' + r.left + 'px;top:' + r.top + 'px;width:' + r.width + 'px;height:' + r.height + 'px;';
    layer.appendChild(box);
  }
  parent.appendChild(layer);
  hibikiHighlightLayer = layer;
}

function hibikiRemoveContainer() {
  if (hibikiContainer) { hibikiContainer.remove(); hibikiContainer = null; }
  // TODO-1272：关窗即撤覆盖层高亮（被查词高亮跟随弹窗生命周期，弹窗在则在、弹窗关则撤）。
  hibikiClearHighlightOverlay();
  // TODO-1150（yomitan 式）：关窗即撤 selection 状态与任何 DOM 包裹高亮（嵌套查词用）。hoshiSelection 未加载/无选区时是 no-op。
  try {
    if (window.hoshiSelection && typeof window.hoshiSelection.clearSelection === 'function') {
      window.hoshiSelection.clearSelection();
    }
  } catch (_) { /* no-op */ }
}

// 流媒体字幕的取词兜底：Netflix 等在字幕**上面**盖了视频覆盖层（如 .watch-video--flag-container），
// 会把 caretRangeFromPoint 截走 → hoshiSelection.getCharacterAtPoint 命中空覆盖层而非字幕文字。这里
// 绕开命中测试：找到包含光标的字幕容器，遍历其文本节点、逐字符用 Range.getBoundingClientRect 找出
// 光标 (x,y) 落在哪个字上，返回该字所在的 Range（供 hoshiSelection.selectFromPosition 展开成词）。
// 只在 getCharacterAtPoint 失败时兜底。
const HIBIKI_SUBTITLE_SELECTORS = [
  '.player-timedtext-text-container', // Netflix
  '.player-timedtext',
  '[class*="timedtext"]',
  '.libassjs-canvas-parent', // 某些播放器
  '[class*="subtitle"] [lang]',
];

function hibikiSubtitleCaretAtPoint(x, y) {
  let container = null;
  for (const sel of HIBIKI_SUBTITLE_SELECTORS) {
    for (const el of document.querySelectorAll(sel)) {
      const r = el.getBoundingClientRect();
      if (r.width && r.height && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        container = el;
        break;
      }
    }
    if (container) break;
  }
  if (!container) return null;
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
  let node;
  while ((node = walker.nextNode())) {
    const text = node.textContent || '';
    if (!text.trim()) continue;
    for (let i = 0; i < text.length; i++) {
      const r = document.createRange();
      r.setStart(node, i);
      r.setEnd(node, i + 1);
      const rects = r.getClientRects();
      for (const rect of rects) {
        if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
          const out = document.createRange();
          out.setStart(node, i);
          out.setEnd(node, i);
          return out;
        }
      }
    }
  }
  return null;
}

document.addEventListener('mousemove', (e) => {
  if (hibikiNfBatchRunning) return; // 批量回放录制中：不查词、不自动暂停，免误触把当前句录制截断
  if (!e[HIBIKI_MOD]) { hibikiLastTerm = ''; return; } // 松开 Shift 复位，下次可重查同词
  // TODO-1279：Shift 悬停取词是「纯悬停扫描」——浏览器会在 Shift 按住+指针移动时把原生文本选区从
  // 既有 caret 扩到指针，与我们自绘的覆盖层高亮叠出一条多余的蓝色原生选区（用户报「一个我们的选区、
  // 一个浏览器自带的蓝色选区」）。纯悬停（无鼠标键按下，e.buttons===0）时清掉原生选区，只留覆盖层
  // 高亮；用户手动按住键拖拽划选复制（e.buttons!==0）不清，保住其复制能力。
  if (e.buttons === 0) hibikiClearNativeSelection();
  // 位移阈值：几乎没动就跳过（同一像素反复 mousemove 不重复取词）。
  if (Math.abs(e.clientX - hibikiLastX) < 4 && Math.abs(e.clientY - hibikiLastY) < 4) return;
  hibikiLastX = e.clientX;
  hibikiLastY = e.clientY;
  if (hibikiPending) return; // 在途闸：上一次查词还没回来就不发新请求（防洪）
  // 取词：复用 Flutter app 同款 window.hoshiSelection（vendor/selection.js，manifest 里先于本脚本加载）——
  // 统一处理 furigana/ruby、词边界、跨文本节点扩词，取词一致性与阅读器/视频查词同源（TODO-1150）。
  if (!window.hoshiSelection || typeof window.hoshiSelection.getCharacterAtPoint !== 'function') return;
  let hit = window.hoshiSelection.getCharacterAtPoint(e.clientX, e.clientY);
  // getCharacterAtPoint 命中失败（多为流媒体字幕上盖了视频覆盖层截走了 caret）→ 字幕逐字兜底绕开覆盖层。
  if (!hit) {
    const subRange = hibikiSubtitleCaretAtPoint(e.clientX, e.clientY);
    if (subRange && subRange.startContainer.nodeType === Node.TEXT_NODE) {
      hit = { node: subRange.startContainer, offset: subRange.startOffset };
    }
  }
  // 诊断：记录本次 shift 划词命中了什么（页面 Console 读 document.documentElement.dataset）。
  try {
    const d = document.documentElement.dataset;
    d.hibikiMove = e.clientX + ',' + e.clientY;
    d.hibikiCaret = hit
      ? String(hit.node.textContent || '').slice(hit.offset, hit.offset + 12)
      : 'null';
  } catch (_) {}
  if (!hit) return;
  // selectFromPosition 向左扩到词首、向右扫最多 MAX_LEN 字（跨节点收 ranges）并存进 hoshiSelection.selection，
  // 供随后 highlightSelection 高亮 + 取 bbox；内部 fire 的 textSelected 在扩展里经 bridge-shim 是 no-op（无副作用）。
  const term = window.hoshiSelection.selectFromPosition(hit.node, hit.offset, HIBIKI_MAX_LEN, e.clientX, e.clientY);
  // TODO-1218②：立刻快照被查词的锚点几何（selection.js getSelectionRect）。不能等响应回来才量——
  // 那时并发的 selectText 可能已清掉 hoshiSelection.selection → highlightSelection 返回 null → 锚点
  // 退回鼠标坐标（弹窗比词底高半行）。随响应传给 hibikiRender 作回退锚点。
  let hibikiAnchorRect = null;
  try {
    if (window.hoshiSelection && typeof window.hoshiSelection.getSelectionRect === 'function') {
      hibikiAnchorRect = window.hoshiSelection.getSelectionRect(e.clientX, e.clientY);
    }
  } catch (_) { hibikiAnchorRect = null; }
  try { document.documentElement.dataset.hibikiTerm = term || ''; } catch (_) {}
  if (!term || !term.trim()) return;
  if (term === hibikiLastTerm) return; // 同词去重：还在同一个词上就不重复查/重渲染
  hibikiLastTerm = term;
  hibikiSendLookup(term, hibikiAnchorRect);
});

// 查词即自动暂停 + 发查词请求 + 渲染弹窗的共享收尾（mousemove 划词与面板行显式点击查词同源）。
// 暂停：**仅对 Netflix 播放器**（按域名判定，不碰别的站点/后台视频）。定格画面+字幕（方便看词/看
// 弹窗），冻结 video.currentTime → 句子窗口停在句末，offscreen 随之暂停录制保住这句 → 制卡得整句、
// 干净。YouTube 走服务端裁剪路径不需暂停；普通网页背景视频更不该被查词误暂停。仅在播放时暂停、不
// 自动恢复（用户查完自己按空格续播）。幂等（重复调用只在 !paused 时暂停）。
function hibikiSendLookup(term, anchorRect, cueWindow) {
  // TODO-1219 P3：每次查词刷新精确窗——面板行查词传 cueWindow（该行精确 [startMs,endMs]），
  // mousemove 划词不传则清空，使后续制卡回落 DOM 采样窗（live 视频 hover 取当前句）。
  hibikiPendingCueWindow = cueWindow || null;
  if (!term || !term.trim()) return;
  if (hibikiSite() === 'netflix') {
    try { const _v = document.querySelector('video'); if (_v && !_v.paused) _v.pause(); } catch (_) {}
  }
  if (!hibikiExtAlive()) return; // 扩展已重载/失效：静默停手（重载页面恢复）
  hibikiPending = true;
  try {
    chrome.runtime.sendMessage({ type: 'lookup', term }, (resp) => {
      hibikiPending = false;
      // 回调期间上下文可能已失效：安全读 lastError（读它本身可能抛），有错就静默丢弃。
      try {
        if (chrome.runtime.lastError) return;
      } catch (_) {
        return;
      }
      if (!resp || !resp.ok || !resp.data || !resp.data.popupJson) return;
      // TODO-1150（yomitan 式）：弹窗钉在被查词旁 + 高亮词。匹配长度取服务端 result.bestLength（日语=
      // 去屈折后命中的词长，与 app 阅读器 lookupHighlightCharCount → result.bestLength 同源），只高亮真正
      // 匹配的词而非整个 12 字扫描窗；缺失/为 0 时回落扫描窗长度 term.length。
      const best = resp.data.result && typeof resp.data.result.bestLength === 'number'
        ? resp.data.result.bestLength
        : 0;
      const termLen = best > 0 ? best : term.length;
      // 单词音频：查词响应带回 app 已启用的音频源（enabledAudioSources），非空时 popup.js
      // 的 createEntryHeader 才渲染 ♪ 按钮（与 app 内 window.audioSources 注入一致）。
      window.audioSources = Array.isArray(resp.data.audioSources) ? resp.data.audioSources : [];
      hibikiRender(resp.data.popupJson, termLen, resp.data.theme, anchorRect);
    });
  } catch (_) {
    hibikiPending = false; // 「Extension context invalidated」：静默，等用户重载页面
  }
}

// TODO-1219 P2：面板行内文本「显式点击查词」的入口（供 subtitle-panel.js 调用）。点击命中的
// (clientX,clientY) 复用与 mousemove 划词同一套 hoshiSelection 取词（含流媒体字幕覆盖层兜底），
// 选中后走 hibikiSendLookup 发查词 + 渲染弹窗，取词/高亮/锚点与全局划词完全一致。
window.hibikiLookupAtPoint = function (clientX, clientY, cueWindow) {
  if (!window.hoshiSelection || typeof window.hoshiSelection.getCharacterAtPoint !== 'function') return;
  let hit = window.hoshiSelection.getCharacterAtPoint(clientX, clientY);
  if (!hit) {
    const subRange = hibikiSubtitleCaretAtPoint(clientX, clientY);
    if (subRange && subRange.startContainer.nodeType === Node.TEXT_NODE) {
      hit = { node: subRange.startContainer, offset: subRange.startOffset };
    }
  }
  if (!hit) return;
  const term = window.hoshiSelection.selectFromPosition(hit.node, hit.offset, HIBIKI_MAX_LEN, clientX, clientY);
  hibikiClearNativeSelection(); // TODO-1279：显式点击查词同样清掉浏览器原生蓝色选区，只留覆盖层高亮
  let anchorRect = null;
  try {
    if (window.hoshiSelection && typeof window.hoshiSelection.getSelectionRect === 'function') {
      anchorRect = window.hoshiSelection.getSelectionRect(clientX, clientY);
    }
  } catch (_) { anchorRect = null; }
  hibikiLastTerm = term || ''; // 与 mousemove 去重状态对齐，避免点后立刻 hover 同词重查
  hibikiSendLookup(term, anchorRect, cueWindow); // TODO-1219 P3：面板行传入精确窗
};

// TODO-1185：嵌套查词——点释义里的词（词典交叉引用 a[href]）。popup.js 的 a.onclick →
// callHandler('onLinkClick', query) → bridge-shim → 这里。用该词**重发一次 lookup**，在同一
// #entries-container 重渲染（yomitan 式单弹窗内导航），对齐 app 的「点释义里的词继续查」。
window.__hibikiOnLinkClick = function (query) {
  const term = (query || '').trim();
  if (!term) return;
  if (!hibikiExtAlive()) return;
  try {
    chrome.runtime.sendMessage({ type: 'lookup', term }, (resp) => {
      try { if (chrome.runtime.lastError) return; } catch (_) { return; }
      if (!resp || !resp.ok || !resp.data || !resp.data.popupJson) return;
      const best = resp.data.result && typeof resp.data.result.bestLength === 'number'
        ? resp.data.result.bestLength : 0;
      const termLen = best > 0 ? best : term.length;
      window.audioSources = Array.isArray(resp.data.audioSources) ? resp.data.audioSources : [];
      hibikiRender(resp.data.popupJson, termLen, resp.data.theme);
    });
  } catch (_) { /* 扩展上下文失效：静默 */ }
};

function hibikiRender(popupJson, termLen, theme, anchorRect) {
  const c = hibikiEnsureContainer();
  // BUG-530：查词响应带回当前 app 主题色（--md-*），套到弹窗容器上，弹窗实时跟随用户主题
  // （改主题下次查词即变）。无 theme 时用 popup.css 里的深色兜底。
  if (theme && typeof theme === 'object') {
    for (const k in theme) {
      if (typeof theme[k] === 'string') c.style.setProperty(k, theme[k]);
    }
  }
  // TODO-1272：被查词高亮改为「扩展自绘覆盖层」，取词的视口 rects 也一并作弹窗锚点（不再贴鼠标坐标）。
  // 旧实现走 selection.js highlightSelection 的 DOM 包裹路径（<span class="hoshi-dict-highlight">
  // 直接改宿主页文本节点）：动态站点（React/Vue/视频字幕逐帧重渲染）框架 diff / MutationObserver
  // 会在下一帧把这个凭空多出的 span revert 掉 → 高亮闪一下就没（用户报「非常容易消失」）。改画
  // 扩展自有的顶层 fixed 覆盖层：宿主页重绘/事件都碰不到它，保持到弹窗关闭。高亮前 termLen 个字。
  let wordRect = null;
  try {
    const hl = hibikiSelectionRects(termLen);
    if (hl.rects.length) {
      hibikiDrawHighlightOverlay(hl.rects); // 覆盖层高亮：宿主页 DOM 重绘/事件冲不掉它
      wordRect = hl.bounds;
    } else if (window.hoshiSelection && typeof window.hoshiSelection.highlightSelection === 'function') {
      // 兜底：selection 结构异常（无 ranges）时退回旧的 bbox 计算，只为拿锚点，不画 DOM 包裹高亮。
      wordRect = window.hoshiSelection.highlightSelection(termLen);
    }
  } catch (_) { wordRect = null; }
  // TODO-1218②：取词 rects 拿不到（并发 selectText 清了 selection）时用查词时快照的锚点，避免退回鼠标坐标。
  if (!wordRect && anchorRect) wordRect = anchorRect;
  // 先隐藏放到左上角渲染，量出真实尺寸后再夹取到视口内显示——否则词在屏幕底/右时，
  // 弹窗直接放词处会溢出到浏览器窗口外/被裁（用户报「弹窗进到浏览器外面」）。
  c.style.visibility = 'hidden';
  c.style.left = '0px';
  c.style.top = '0px';
  try { window.lookupEntries = JSON.parse(popupJson); }
  catch (_) { window.lookupEntries = []; }
  window._noResultsMessage = 'No results';
  window.__hibikiOnTapOutside = hibikiRemoveContainer;
  if (typeof window.renderPopup === 'function') window.renderPopup();
  const place = () => {
    const rect = c.getBoundingClientRect();
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    // 锚点=被查词的视口坐标。容器 position:fixed（BUG-530 全屏可见），坐标即视口系，故**不加**
    // scrollX/Y（加了反而在滚动页面上错位）。拿不到 bbox → 回落最后鼠标视口坐标。
    const ax = wordRect ? wordRect.x : hibikiLastX;
    const ay = wordRect ? wordRect.y : hibikiLastY;
    const ah = wordRect ? wordRect.height : 0;
    let left = ax;
    let top = ay + ah + 4; // 默认落在词下方
    if (left + rect.width > vw - 8) left = Math.max(8, vw - rect.width - 8); // 右溢出→贴右
    if (left < 8) left = 8;
    if (top + rect.height > vh - 8) top = Math.max(8, ay - rect.height - 4); // 下溢出→翻到词上方
    if (top < 8) top = 8;
    // TODO-1185：#entries-container 消费 --hibiki-popup-zoom（content.css: zoom: var(...)）。
    // CSS zoom 会把 fixed 元素的 left/top 也乘以 zoom，直接写视口坐标会被放大偏移。写入前除以
    // zoom，使渲染用值(styleLeft*zoom) 落回目标视口坐标；zoom 缺省=1（旧 server 无此变量）时零影响。
    const zoom = parseFloat(getComputedStyle(c).getPropertyValue('--hibiki-popup-zoom')) || 1;
    c.style.left = (left / zoom) + 'px';
    c.style.top = (top / zoom) + 'px';
    c.style.visibility = 'visible';
  };
  requestAnimationFrame(place);
}

document.addEventListener('mousedown', (e) => {
  if (hibikiContainer && !hibikiContainer.contains(e.target)) hibikiRemoveContainer();
});
