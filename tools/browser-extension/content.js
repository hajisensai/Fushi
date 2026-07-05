// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
// 样式经 content.css 注入，全部作用域到 #entries-container，不污染宿主页（TODO-1090）。
// 版本标记：加载后在 Console 打一行，用户可据此确认加载的是**新版**扩展（排查缓存旧版）。
console.log('[Hibiki] content script v38 loaded (yomitan-style word anchor + highlight via hoshiSelection)');
// 诊断标记：写进 <html> 的 data-*，页面 Console（主世界）可读，用来隔空排查划词为何不触发
// （隔离世界的全局变量在页面 console 里看不到，故用 DOM 属性桥接）。
try { document.documentElement.setAttribute('data-hibiki-cs', 'v38'); } catch (_) {}
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
// Netflix 用：只在制卡队列**增长**时弹一次中间下方短暂提示，避免加载/删除/跨标签同步也刷屏。
let hibikiLastQueueTotal = 0;
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
  // Netflix：不再在右下角常驻小控件（长期遮挡视频/字幕）。改为「中间下方短暂提示」——
  // 复用 hibikiToast（left:50% + bottom，5s 自动淡出），只在队列新增时弹一次、内容不变。
  // 生成仍走浏览器工具栏的 Hibiki 图标（Netflix 录屏需手势），不依赖常驻控件。
  if (hibikiSite() === 'netflix') {
    if (hibikiChip) hibikiChip.style.display = 'none';
    if (total > hibikiLastQueueTotal && typeof window.hibikiToast === 'function') {
      window.hibikiToast('制卡队列 ' + total + ' · 点扩展图标生成本片 ' + here);
    }
    hibikiLastQueueTotal = total;
    return;
  }
  hibikiLastQueueTotal = total;
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
  if (!items.length) {
    window.hibikiToast('YouTube 队列为空：先开字幕 → shift 查词 → 点弹窗「制卡」入队，再来生成');
    return;
  }
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
  // TODO-1175：记录批量前的播放位置/态，批量结束（成功或异常）后都回到这里、恢复原播放/暂停态。
  const resumeAt = v.currentTime;
  const wasPlaying = !v.paused;
  const hideStyle = document.createElement('style');
  hideStyle.id = 'hibiki-nf-hide-sub';
  hideStyle.textContent = '.player-timedtext{visibility:hidden!important}';
  try { document.head.appendChild(hideStyle); } catch (_) {}
  const prevCursor = document.body.style.cursor;
  document.body.style.cursor = 'none';
  let done = 0, fail = 0;
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
    const onSeeked = () => finish();
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
      let ok = false;
      try {
        await seekTo(Math.max(0, q.startV / 1000));
        await sleep(150); // 让首帧稳定
        // 先确保真的在播（自动播放策略可能拦；重试一次）。仍暂停 → 跳过本句，不录一段冻结帧。
        try { await v.play(); } catch (_) {}
        await sleep(200);
        if (v.paused) { try { await v.play(); } catch (_) {} await sleep(200); }
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
          ok = await new Promise((resolve) => {
            chrome.runtime.sendMessage(
              { type: 'mineClip', fields: q.fields, sentence: q.sentence, clipBase64: clip.clipBase64, clipDurationMs: clip.clipDurationMs },
              (resp) => {
                try { if (chrome.runtime.lastError) return resolve(false); } catch (_) { return resolve(false); }
                resolve(!!(resp && resp.ok && resp.data && resp.data.result === 'success'));
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
      if (ok) { done++; okIds.push(q.id); } else fail++;
      window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true);
    }
  } finally {
    // V16#3：无论批量循环正常结束还是中途抛错，都必还原隐藏字幕的样式 + 光标，绝不把
    // cursor:none / 藏字幕样式泄漏到用户可见界面（循环外抛异常留可见副作用的根因）。
    try { hideStyle.remove(); } catch (_) {}
    document.body.style.cursor = prevCursor;
    // TODO-1175：批量停在最后一句 + 暂停态 → 回到批量前的位置并恢复原播放/暂停态。
    try { await seekTo(resumeAt); } catch (_) {}
    if (wasPlaying) { try { await v.play(); } catch (_) {} }
  }
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

function hibikiRemoveContainer() {
  if (hibikiContainer) { hibikiContainer.remove(); hibikiContainer = null; }
  // TODO-1150（yomitan 式）：关窗即撤被查词高亮。hoshiSelection 未加载/无选区时是 no-op。
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
  try { document.documentElement.dataset.hibikiTerm = term || ''; } catch (_) {}
  if (!term || !term.trim()) return;
  if (term === hibikiLastTerm) return; // 同词去重：还在同一个词上就不重复查/重渲染
  hibikiLastTerm = term;
  // 查词即自动暂停：**仅对 Netflix 播放器**（按域名判定，不碰别的站点/后台视频）。定格画面+字幕
  // （方便看词/看弹窗），冻结 video.currentTime → 句子窗口停在句末，offscreen 随之暂停录制保住这
  // 句 → 制卡得整句、干净（无鼠标/弹窗）。YouTube 走服务端裁剪路径不需暂停；普通网页的背景视频更
  // 不该被查词误暂停（V16#1：原来对页面任意 <video> 都暂停 → UX 副作用）。
  // 仅在播放时暂停（避免重复触发），不自动恢复（用户查完自己按空格续播）。
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
      hibikiRender(resp.data.popupJson, termLen, resp.data.theme);
    });
  } catch (_) {
    hibikiPending = false; // 「Extension context invalidated」：静默，等用户重载页面
  }
});

function hibikiRender(popupJson, termLen, theme) {
  const c = hibikiEnsureContainer();
  // BUG-530：查词响应带回当前 app 主题色（--md-*），套到弹窗容器上，弹窗实时跟随用户主题
  // （改主题下次查词即变）。无 theme 时用 popup.css 里的深色兜底。
  if (theme && typeof theme === 'object') {
    for (const k in theme) {
      if (typeof theme[k] === 'string') c.style.setProperty(k, theme[k]);
    }
  }
  // TODO-1150（yomitan 式）：高亮刚取的词并拿它的视口 bbox 作弹窗锚点（不再贴鼠标坐标）。
  // highlightSelection 复用上一步 selectFromPosition 存进 hoshiSelection.selection 的 ranges，用
  // CSS Custom Highlight API 高亮前 termLen 个字并返回其 getClientRects 视口系 bbox；同名高亮覆盖
  // 上一次（切词自动换高亮）。拿不到 bbox（极少数取词失败）→ 回落到最后鼠标位置。
  let wordRect = null;
  try {
    if (window.hoshiSelection && typeof window.hoshiSelection.highlightSelection === 'function') {
      wordRect = window.hoshiSelection.highlightSelection(termLen);
    }
  } catch (_) { wordRect = null; }
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
    c.style.left = left + 'px';
    c.style.top = top + 'px';
    c.style.visibility = 'visible';
  };
  requestAnimationFrame(place);
}

document.addEventListener('mousedown', (e) => {
  if (hibikiContainer && !hibikiContainer.contains(e.target)) hibikiRemoveContainer();
});
