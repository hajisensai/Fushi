// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
// 样式经 content.css 注入，全部作用域到 #entries-container，不污染宿主页（TODO-1090）。
// 版本标记：加载后在 Console 打一行，用户可据此确认加载的是**新版**扩展（排查缓存旧版）。
console.log('[Hibiki] content script v31 loaded (batch mining; Netflix in-place, icon=generate/cancel)');
// 诊断标记：写进 <html> 的 data-*，页面 Console（主世界）可读，用来隔空排查划词为何不触发
// （隔离世界的全局变量在页面 console 里看不到，故用 DOM 属性桥接）。
try { document.documentElement.setAttribute('data-hibiki-cs', 'v31'); } catch (_) {}
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
    hibikiUpdateQueueChip();
  } catch (_) {}
}
function hibikiQueueLoad() {
  try {
    chrome.storage.local.get(['hibikiQueue'], (r) => {
      hibikiQueue = Array.isArray(r && r.hibikiQueue) ? r.hibikiQueue : [];
      hibikiUpdateQueueChip();
    });
  } catch (_) { hibikiUpdateQueueChip(); }
}
window.hibikiEnqueue = function (fields, sentence) {
  const w = hibikiCurrentCueWindowV();
  if (!w) return { ok: false, reason: 'no-cue' };
  const site = hibikiSite();
  hibikiQueue.push({
    id: Date.now() + '-' + Math.random().toString(36).slice(2),
    fields: fields, sentence: sentence || w.text || '',
    startV: Math.max(0, w.startV - 200), endV: w.endV + 200,
    site: site,
    youtubeId: site === 'youtube' ? hibikiYoutubeId() : null,
    netflixId: site === 'netflix' ? hibikiNetflixId() : null,
  });
  hibikiQueueSave();
  hibikiUpdateQueueChip();
  return { ok: true, count: hibikiQueue.length };
};
// 跨标签/重载同步：storage 变了就刷新内存镜像 + 计数。
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.hibikiQueue) {
      hibikiQueue = Array.isArray(changes.hibikiQueue.newValue) ? changes.hibikiQueue.newValue : [];
      hibikiUpdateQueueChip();
    }
  });
} catch (_) {}

// 浮动小控件：显示总队列数 + 本页可生成数；YouTube 点即生成，Netflix 提示点扩展图标。
let hibikiChip = null;
function hibikiGenerableCount() {
  const site = hibikiSite();
  if (site === 'youtube') return hibikiQueue.filter((q) => q.site === 'youtube').length;
  if (site === 'netflix') {
    const id = hibikiNetflixId();
    return hibikiQueue.filter((q) => q.site === 'netflix' && q.netflixId === id).length;
  }
  return 0;
}
function hibikiUpdateQueueChip() {
  const total = hibikiQueue.length;
  const here = hibikiGenerableCount();
  if (!hibikiChip) {
    hibikiChip = document.createElement('div');
    hibikiChip.id = 'hibiki-queue-chip';
    hibikiChip.style.cssText =
      'position:fixed;right:16px;bottom:16px;z-index:2147483647;padding:8px 12px;border-radius:20px;' +
      'background:rgba(20,20,22,.92);color:#fff;font:13px/1.4 sans-serif;cursor:pointer;' +
      'box-shadow:0 4px 16px rgba(0,0,0,.4);user-select:none;';
    hibikiChip.addEventListener('click', () => {
      if (hibikiSite() === 'youtube') {
        if (typeof window.hibikiGenerateAll === 'function') window.hibikiGenerateAll();
      } else if (typeof window.hibikiToast === 'function') {
        window.hibikiToast('点浏览器工具栏的 Hibiki 图标生成本片的 ' + hibikiGenerableCount() + ' 条（Netflix 录屏需此手势）');
      }
    });
    (document.fullscreenElement || document.body).appendChild(hibikiChip);
  } else if (hibikiChip.parentNode !== (document.fullscreenElement || document.body)) {
    (document.fullscreenElement || document.body).appendChild(hibikiChip);
  }
  if (total === 0) { hibikiChip.style.display = 'none'; return; }
  hibikiChip.style.display = 'block';
  hibikiChip.textContent = hibikiSite() === 'youtube'
    ? '制卡队列 ' + total + ' · 点此生成 ' + here
    : '制卡队列 ' + total + ' · 点扩展图标生成本片 ' + here;
}
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
  if (!items.length) return;
  if (!hibikiExtAlive()) { window.hibikiToast('扩展已更新，刷新页面(F5)后重试'); return; }
  let done = 0, fail = 0;
  const okIds = [];
  window.hibikiToast('生成中… 0/' + items.length, true);
  for (const q of items) {
    const ok = await new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({
          type: 'mineYoutube', fields: q.fields, sentence: q.sentence,
          youtubeVideoId: q.youtubeId, startMs: q.startV, endMs: q.endV,
        }, (resp) => {
          try { if (chrome.runtime.lastError) return resolve(false); } catch (_) { return resolve(false); }
          resolve(!!(resp && resp.ok && resp.data && resp.data.result === 'success'));
        });
      } catch (_) { resolve(false); }
    });
    if (ok) { done++; okIds.push(q.id); } else fail++;
    window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true);
  }
  await hibikiRemoveQueued(okIds);
  window.hibikiToast('✓ 生成完成：成功 ' + done + (fail ? ' · 失败 ' + fail : ''));
};

// ── Netflix 回放录制（DRM）：由 content 驱动，capture 经 background/offscreen（beginClip/endClip）──
let hibikiNfBatchRunning = false;

// 生成本剧集的项：逐句 seek 到句首 → 播放到字幕变化(=本句结束) → 停录 → 送服务端整段裁 [0,时长]
// 转 GIF+音频。整场用注入 CSS 藏字幕轨(GIF 不烧字幕，且能扛 Netflix 换节点)+藏鼠标。不停录屏
// （跨集续用，由 nfFinish 收尾）。只移除成功的本集项。
async function hibikiRunNetflixBatch() {
  const nfId = hibikiNetflixId();
  const items = hibikiQueue.filter((q) => q.site === 'netflix' && q.netflixId === nfId);
  if (!items.length) return;
  const v = document.querySelector('video');
  if (!v) return;
  const hideStyle = document.createElement('style');
  hideStyle.id = 'hibiki-nf-hide-sub';
  hideStyle.textContent = '.player-timedtext{visibility:hidden!important}';
  try { document.head.appendChild(hideStyle); } catch (_) {}
  document.body.style.cursor = 'none';
  let done = 0, fail = 0;
  const okIds = [];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const seekTo = (sec) => new Promise((resolve) => {
    let settled = false;
    const on = () => { if (settled) return; settled = true; try { v.removeEventListener('seeked', on); } catch (_) {} resolve(); };
    v.addEventListener('seeked', on);
    try { v.currentTime = sec; } catch (_) {}
    setTimeout(on, 4000); // 兜底：seeked 不来也继续
  });
  for (const q of items) {
    try {
      await seekTo(Math.max(0, q.startV / 1000));
      await sleep(150); // 让首帧稳定
      // 先确保真的在播（自动播放策略可能拦；重试一次）。仍暂停 → 跳过本句，不录一段冻结帧。
      try { await v.play(); } catch (_) {}
      await sleep(200);
      if (v.paused) { try { await v.play(); } catch (_) {} await sleep(200); }
      if (v.paused) { fail++; window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
      await chrome.runtime.sendMessage({ target: 'offscreen', type: 'beginClip' });
      // 本句结束判据：字幕文本变成别的/清空（≠ 这一句），且已过句首 0.4s。refText 用入队时存的整句
      // 文本，比「播放时现采样」稳（避免字幕还没渲染时采到空 → 判据失效整段录到超时）。
      const refText = (q.sentence || '').trim();
      // 主判据是「字幕变成别句」；hardEnd 只是判据失效（相邻同文本/字幕关）时的安全上限。
      // 有观测到的 endV 就用 endV+1500（长句不被截）；否则封顶 startV+8000（8s，控制转码体积）。
      const hardEnd = Math.max((q.endV || 0) + 1500, q.startV + 8000) / 1000;
      const deadline = Date.now() + 12000;
      while (v.currentTime < hardEnd && Date.now() < deadline) {
        await sleep(120);
        if (v.paused) break; // 外部暂停 → 别空转录冻结帧到超时
        const nowText = hibikiSubtitleTextNow();
        if (refText && v.currentTime > (q.startV / 1000 + 0.4) && nowText !== refText) break;
      }
      try { v.pause(); } catch (_) {}
      const clip = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'endClip' });
      let ok = false;
      if (clip && clip.ok && clip.clipBase64) {
        ok = await new Promise((resolve) => {
          chrome.runtime.sendMessage(
            { type: 'mineClip', fields: q.fields, sentence: q.sentence, clipBase64: clip.clipBase64, clipDurationMs: clip.clipDurationMs },
            (resp) => {
              try { if (chrome.runtime.lastError) return resolve(false); } catch (_) { return resolve(false); }
              resolve(!!(resp && resp.ok && resp.data && resp.data.result === 'success'));
            });
        });
      }
      if (ok) { done++; okIds.push(q.id); } else fail++;
    } catch (_) { fail++; }
    window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true);
  }
  try { hideStyle.remove(); } catch (_) {}
  document.body.style.cursor = '';
  await hibikiRemoveQueued(okIds);
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

// 跨剧集批量：页面(重)注入或状态变 active 后检查是否在批量中；是且当前是目标剧集 → 等就绪 →
// 生成本集项 → 前进/跳下一集/收尾。状态在 storage，跨导航与 SW 休眠都存活。防重入。
async function hibikiMaybeResumeNetflixBatch() {
  if (hibikiNfBatchRunning) return;
  // 同步置位（任何 await 之前）：堵 setTimeout 与 storage 事件「查-await-置位」间的重入 TOCTOU。
  hibikiNfBatchRunning = true;
  try {
    if (!hibikiExtAlive() || hibikiSite() !== 'netflix') return;
    let st;
    try { st = (await chrome.storage.local.get(['hibikiNfBatch'])).hibikiNfBatch; } catch (_) { return; }
    if (!st || !st.active) return;
    // 就地模式：只在目标剧集页跑，**绝不导航**（导航=reload 会触发 Netflix DRM M7375）。
    // 目标集对不上 / 旧格式残留状态 → 直接清掉，不卡住。
    if (!st.netflixId || hibikiNetflixId() !== st.netflixId) {
      try { chrome.runtime.sendMessage({ type: 'nfFinish' }); } catch (_) {}
      return;
    }
    window.hibikiToast('生成本片中…', true);
    await hibikiWaitForPlayer(20000);
    if (!document.querySelector('video')) {
      // 播放器没起来（如 Netflix 报 M7375）→ 干净收尾，不卡住。
      try { chrome.runtime.sendMessage({ type: 'nfFinish' }); } catch (_) {}
      window.hibikiToast('✗ 播放器未就绪，已取消（Netflix 报错就刷新本页重试）');
      return;
    }
    try { await chrome.runtime.sendMessage({ type: 'nfEnsureCapture' }); } catch (_) {}
    await hibikiRunNetflixBatch();
    try { chrome.runtime.sendMessage({ type: 'nfFinish' }); } catch (_) {}
    window.hibikiToast('✓ 本片生成完成');
  } finally {
    hibikiNfBatchRunning = false;
  }
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg) return;
  if (msg.type === 'hibikiToastMsg' && typeof window.hibikiToast === 'function') window.hibikiToast(msg.text);
  else if (msg.type === 'hibikiRunYoutube' && typeof window.hibikiGenerateAll === 'function') window.hibikiGenerateAll();
});
// 图标点击设 hibikiNfBatch → storage 变化触发就地续跑（本页无重载）；重载路径由 setTimeout 兜底。
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.hibikiNfBatch) {
      const nv = changes.hibikiNfBatch.newValue;
      if (nv && nv.active) hibikiMaybeResumeNetflixBatch();
    }
  });
} catch (_) {}
try { setTimeout(hibikiMaybeResumeNetflixBatch, 1500); } catch (_) {}

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

function hibikiRemoveContainer() {
  if (hibikiContainer) { hibikiContainer.remove(); hibikiContainer = null; }
}

function hibikiCaretFromPoint(x, y) {
  if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    if (!p) return null;
    const r = document.createRange();
    r.setStart(p.offsetNode, p.offset);
    return r;
  }
  return null;
}

// 流媒体字幕的取词兜底：Netflix 等在字幕**上面**盖了视频覆盖层（如 .watch-video--flag-container），
// 会把 caretRangeFromPoint 截走 → 命中空覆盖层而非字幕文字。这里绕开命中测试：找到包含光标的
// 字幕容器，遍历其文本节点、逐字符用 Range.getBoundingClientRect 找出光标 (x,y) 落在哪个字上，
// 返回该字所在的 Range（供 expandWordWindow 展开成词）。只在 caretRangeFromPoint 失败时兜底。
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
  // 位移阈值：几乎没动就跳过（同一像素反复 mousemove 不重复取词）。
  if (Math.abs(e.clientX - hibikiLastX) < 4 && Math.abs(e.clientY - hibikiLastY) < 4) return;
  hibikiLastX = e.clientX;
  hibikiLastY = e.clientY;
  if (hibikiPending) return; // 在途闸：上一次查词还没回来就不发新请求（防洪）
  let range = hibikiCaretFromPoint(e.clientX, e.clientY);
  // 命中的不是文本节点（多为流媒体字幕上盖了视频覆盖层截走了 caret）→ 用字幕逐字兜底绕开覆盖层。
  if (!range || range.startContainer.nodeType !== Node.TEXT_NODE) {
    range = hibikiSubtitleCaretAtPoint(e.clientX, e.clientY);
  }
  // 诊断：记录本次 shift 划词命中了什么（页面 Console 读 document.documentElement.dataset）。
  try {
    const d = document.documentElement.dataset;
    d.hibikiMove = e.clientX + ',' + e.clientY;
    d.hibikiCaret = range
      ? (range.startContainer.nodeType + ':' + String(range.startContainer.textContent || '').slice(0, 12))
      : 'null';
  } catch (_) {}
  if (!range || range.startContainer.nodeType !== Node.TEXT_NODE) return;
  const term = expandWordWindow(range.startContainer, range.startOffset, HIBIKI_MAX_LEN);
  try { document.documentElement.dataset.hibikiTerm = term; } catch (_) {}
  if (!term.trim()) return;
  if (term === hibikiLastTerm) return; // 同词去重：还在同一个词上就不重复查/重渲染
  hibikiLastTerm = term;
  // 查词即自动暂停网飞：定格画面 + 字幕（字幕不消失，方便看词/看弹窗）；也冻结 video.currentTime →
  // 句子窗口自动停在句末，且 offscreen 随之暂停录制保住这句 → 制卡得到整句、干净（无鼠标/弹窗）。
  // 仅在播放时暂停（避免重复触发），不自动恢复（用户查完自己按空格续播）。
  try { const _v = document.querySelector('video'); if (_v && !_v.paused) _v.pause(); } catch (_) {}
  // 视口坐标（配合 position:fixed）：全屏与普通页都定位在光标处，且不受页面滚动影响。
  const px = e.clientX;
  const py = e.clientY;
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
      hibikiRender(resp.data.popupJson, px, py, resp.data.theme);
    });
  } catch (_) {
    hibikiPending = false; // 「Extension context invalidated」：静默，等用户重载页面
  }
});

function hibikiRender(popupJson, x, y, theme) {
  const c = hibikiEnsureContainer();
  // BUG-530：查词响应带回当前 app 主题色（--md-*），套到弹窗容器上，弹窗实时跟随用户主题
  // （改主题下次查词即变）。无 theme 时用 popup.css 里的深色兜底。
  if (theme && typeof theme === 'object') {
    for (const k in theme) {
      if (typeof theme[k] === 'string') c.style.setProperty(k, theme[k]);
    }
  }
  // 先隐藏放到左上角渲染，量出真实尺寸后再夹取到视口内显示——否则字幕在屏幕底/右时，
  // 弹窗直接放光标处会溢出到浏览器窗口外/被裁（用户报「弹窗进到浏览器外面」）。
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
    let left = x + 4;
    let top = y + 16; // 默认落在光标下方一点
    if (left + rect.width > vw - 8) left = Math.max(8, vw - rect.width - 8); // 右溢出→贴右
    if (left < 8) left = 8;
    if (top + rect.height > vh - 8) top = Math.max(8, y - rect.height - 12); // 下溢出→翻到光标上方
    if (top < 8) top = 8;
    c.style.left = left + 'px';
    c.style.top = top + 'px';
    c.style.visibility = 'visible';
  };
  requestAnimationFrame(place);
}

document.addEventListener('mousedown', (e) => {
  if (hibikiContainer && !hibikiContainer.contains(e.target)) hibikiRemoveContainer();
});
