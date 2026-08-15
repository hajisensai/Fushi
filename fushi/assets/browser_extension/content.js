// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
// 样式经 content.css 注入，全部作用域到 #entries-container，不污染宿主页（TODO-1090）。
// 版本标记：加载后在 Console 打一行，用户可据此确认加载的是**新版**扩展（排查缓存旧版）。
console.log('[Fushi] content script v46 loaded (BUG-688: popup Shadow DOM isolation + theme single-sourced from app; TODO-1219/1363: subtitle cue replay + universal subtitle-list providers; TODO-1391: hide Netflix start-of-episode maturity/age-rating overlay)');
// 诊断标记：写进 <html> 的 data-*，页面 Console（主世界）可读，用来隔空排查划词为何不触发
// （隔离世界的全局变量在页面 console 里看不到，故用 DOM 属性桥接）。
try { document.documentElement.setAttribute('data-fushi-cs', 'v46'); } catch (_) {}
// TODO-1190：网页源文里高亮被查的词。selection.js 默认走 CSS Custom Highlight API
// （CSS.highlights.set('fushi-selection', …) + content.css 的 ::highlight(fushi-selection)）。
// 但 content script 跑在**隔离世界**：在隔离世界注册的 highlight 不会被页面渲染引擎绘制
// （用户报「浏览器还是没高亮」的根因——1150 只补了调用，没绕开这条平台限制）。故在扩展里
// 强制 selection.js 回落到 **DOM 包裹**路径（<span class="fushi-dict-highlight"> 直接改共享 DOM，
// 页面渲染引擎必然绘制，与世界隔离无关；关窗时 clearSelection→clearHighlightWrappers 还原）。
// selection.js 先于本脚本加载，这里覆盖它探测出的 true。app 内查词 selection.js 跑在主世界，
// 不加载 content.js，CSS 高亮照常，互不影响。
window.__fushiCssHighlightsSupported = false;
// TODO-1218①：标记「本页由扩展注入」。popup.js 的页面级 selectText 监听器本为 app 内嵌套弹窗
// 设计，注入宿主页后宿主页自身 hover/click 会误触 selectText→clearSelection，拆掉刚画的划词高亮；
// popup.js 读此 flag 后只处理落在 #entries-container 内的事件（content.js 与 popup.js 同隔离世界共享 window）。
window.__fushiExtension = true;
const FUSHI_MOD = 'shiftKey';
const FUSHI_MAX_LEN = 12;
let fushiContainer = null;
// BUG-688：弹窗渲染进 Shadow DOM，宿主网页 CSS 无法穿透 shadow 边界（ruby/行距/定位等
// 与 in-app WebView 弹窗一致）。fushiHost 是挂在宿主页的 shadow 宿主元素（负责 fixed 定位），
// #entries-container 及全部弹窗内容在其 shadow root 内；window.__fushiRoot 暴露给 popup.js。
let fushiHost = null;
// BUG-530 性能：划词监听器原来对每次 mousemove 都发查词请求 → 一直按 Shift 移动会把服务器
// 刷爆、UI 卡顿。用「位移阈值 + 同词去重 + 在途请求闸」三重节流：只在移到**不同词**上才查。
let fushiLastTerm = '';
let fushiLastAutoLookupKey = '';
let fushiLastX = -1;
let fushiLastY = -1;
let fushiPending = false;
let fushiLookupPerfSequence = 0;
let fushiLookupPerfContext = null;
// BUG-1024：在途闸不能只用裸 bool——MV3 background service worker 若在查词消息在途时
// 被系统终止，chrome.runtime.sendMessage 的回调会永不触发，fushiPending 永久卡在 true，
// 此后所有 Shift 悬停被在途闸整条吞掉（弹窗越来越不敏感）。记发起时刻，超过此截止时间
// 就当上一次已废弃、放行新查词（回调仍会正常复位，此值只是「回调永不来」的安全兜底）。
let fushiPendingSince = 0;
const FUSHI_PENDING_TIMEOUT_MS = 1500;

function fushiReportLookupPerf(entry) {
  try {
    chrome.runtime.sendMessage({ type: 'lookupPerf', entry }, () => {
      try { void chrome.runtime.lastError; } catch (_) {}
    });
  } catch (_) { /* 扩展重载/页面卸载时静默 */ }
}

function fushiBindPopupPerfContext(ctx) {
  // popup.js 捕获本函数后才异步发 IPC；闭包固定本轮 ctx，换词/关窗后的
  // cancelled/error 终态不会串到新查询。
  window.__fushiOnPopupPerf = function (metrics) {
    if (!ctx) return;
    fushiReportLookupPerf({
      id: ctx.id,
      surface: 'page-popup',
      stage: 'popup-' + String(metrics && metrics.phase || 'unknown'),
      term: ctx.term,
      maximumTerms: ctx.maximumTerms,
      sinceRequestMs: Number((performance.now() - ctx.clientStartedAt).toFixed(1)),
      ...(metrics || {}),
    });
  };
}
fushiBindPopupPerfContext(null);

function fushiReportVisibleAfterPaint(ctx, container) {
  if (!ctx || ctx.visibleReported || ctx.visibleReportScheduled) return;
  ctx.visibleReportScheduled = true;
  // 调用点本身在 place() 的 rAF；再等一帧，浏览器至少有一次 paint 机会。
  requestAnimationFrame(() => {
    if (!fushiHost || !fushiHost.isConnected || !container ||
        container.style.visibility !== 'visible') return;
    ctx.visibleReported = true;
    fushiReportLookupPerf({
      id: ctx.id,
      surface: 'page-popup',
      stage: 'visible-after-paint',
      term: ctx.term,
      maximumTerms: ctx.maximumTerms,
      sinceRequestMs: Number((performance.now() - ctx.clientStartedAt).toFixed(1)),
    });
  });
}

// 「查词时暂停」取代旧的「悬停字幕时暂停」。新键显式值优先；旧
// subtitleHoverPause 只作升级兼容读取，避免用户更新扩展后原选择突然丢失。
// 默认**开启**，对齐 app 侧 pauseOnLookup 默认 true（TODO-1108）；从未做过选择的用户
// 查词即暂停、关窗即恢复（恢复侧见 fushiRemoveContainer）。
let fushiPauseOnLookup = true;
let fushiHasPauseOnLookupPref = false;
function fushiApplyPauseOnLookupPrefs(saved) {
  saved = saved || {};
  fushiHasPauseOnLookupPref = typeof saved.subtitlePauseOnLookup === 'boolean';
  fushiPauseOnLookup = fushiHasPauseOnLookupPref
    ? saved.subtitlePauseOnLookup
    : (typeof saved.subtitleHoverPause === 'boolean'
        ? saved.subtitleHoverPause
        : true);
}
// 因查词被**我们**暂停的那个 <video>；null=没有。它是恢复侧唯一真相源（对齐 app 的
// _pausedForLookup 不变式）：用户自己暂停的视频绝不因关弹窗被播起来。
let fushiPausedForLookup = null;
// 记「被我们暂停」并挂一次性 play 监听：用户手动点播放（不是我们 resume——我们 resume 前
// 已先置 null）即视为收回控制权，清掉标记。这样「查词暂停 → 用户播放 → 用户再暂停 → 关窗」
// 不会把用户自己按下的暂停顶掉；SPA 同元素换 src 继续播的场景同样被覆盖。
function fushiMarkPausedForLookup(v) {
  if (fushiPausedForLookup === v) return; // 重复查词同一视频：已挂过监听，别叠加
  fushiPausedForLookup = v;
  try {
    v.addEventListener('play', function () {
      if (fushiPausedForLookup === v) fushiPausedForLookup = null;
    }, { once: true });
  } catch (_) {}
}
// 恢复侧唯一实现（对齐 app 的 shouldResumeAfterLookupDismiss）：只恢复确实由查词暂停的
// 那个视频；用户已手动继续播放的不重复 play（v.paused 守卫）。除关窗汇聚点外，查词失败/
// 扩展失效等「弹窗根本没建出来」的路径也必须走它——否则视频被停住却没有任何关窗动作可触发恢复。
function fushiResumePausedForLookup() {
  if (!fushiPausedForLookup) return;
  const pausedVideo = fushiPausedForLookup;
  fushiPausedForLookup = null;
  try {
    if (pausedVideo.isConnected !== false && pausedVideo.paused) {
      const played = pausedVideo.play();
      if (played && typeof played.catch === 'function') played.catch(() => {});
    }
  } catch (_) { /* autoplay 拦截等：保持暂停即可 */ }
}
// 找「正在播放」的视频：没有在播的就没有可暂停的（也就无需恢复）。顶层文档快路径优先
// （高频 Shift 悬停查词不能每次全树扫描）；顶层没有才穿透 open shadow root 与**同源**
// iframe 深搜（跨域 iframe 拿不到 contentDocument，静默跳过——嵌入式第三方播放器暂不覆盖）。
// 深搜结果为空时记 2s TTL 负缓存：纯文本页/无在播视频的页面上，高频扫词不反复全树扫描。
let fushiNoPlayingVideoUntil = 0;
function fushiFindPlayingVideo() {
  const playing = (root) => {
    let vids;
    try { vids = root.querySelectorAll('video'); } catch (_) { return null; }
    for (const v of vids) {
      if (!v.paused && !v.ended) return v;
    }
    return null;
  };
  const top = playing(document);
  if (top) return top;
  if (Date.now() < fushiNoPlayingVideoUntil) return null; // 负缓存命中：跳过深搜
  const deep = (root, depth) => {
    if (!root || depth > 3) return null;
    let all;
    try { all = root.querySelectorAll('*'); } catch (_) { return null; }
    for (const el of all) {
      let sub = null;
      if (el.shadowRoot) {
        sub = playing(el.shadowRoot) || deep(el.shadowRoot, depth + 1);
      } else if (el.tagName === 'IFRAME') {
        try {
          if (el.contentDocument) {
            sub = playing(el.contentDocument) || deep(el.contentDocument, depth + 1);
          }
        } catch (_) { /* 跨域 iframe */ }
      }
      if (sub) return sub;
    }
    return null;
  };
  const found = deep(document, 0);
  if (!found) fushiNoPlayingVideoUntil = Date.now() + 2000;
  return found;
}
try {
  const fushiPausePrefsPromise = chrome.storage.local.get(
    ['subtitlePauseOnLookup', 'subtitleHoverPause'],
    fushiApplyPauseOnLookupPrefs,
  );
  if (fushiPausePrefsPromise &&
      typeof fushiPausePrefsPromise.then === 'function') {
    fushiPausePrefsPromise.then(fushiApplyPauseOnLookupPrefs, () => {});
  }
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes) return;
    if (changes.subtitlePauseOnLookup) {
      fushiHasPauseOnLookupPref = true;
      fushiPauseOnLookup = changes.subtitlePauseOnLookup.newValue === true;
    } else if (changes.subtitleHoverPause && !fushiHasPauseOnLookupPref) {
      fushiPauseOnLookup = changes.subtitleHoverPause.newValue === true;
    }
  });
} catch (_) {}

// 弹窗尺寸精细化 Phase D：拖拽调整扩展弹窗尺寸。
// fushiResizeGrip：右下角拖拽把手（顶层 position:fixed overlay，与高亮层同父挂在
//   fullscreenElement||body；不放进 host 的 shadow，避开 host 的 zoom 建立包含块干扰 fixed）。
// fushiResizeBox：place() 每次落点后存的夹取上下文——弹窗视口左上角 + 视口可用空间右/下边界
//   （已内含 BUG-767「拖大也不许遮住被查词」约束）+ 当前 zoom，供拖拽把「视口位移」折回基准尺度。
// fushiResizeDrag：一次拖拽的起始快照 {startX,startY,baseW,baseH,zoom,bounds}；null=未在拖。
let fushiResizeGrip = null;
let fushiResizeBox = null;
let fushiResizeDrag = null;

// 扩展重载/更新/禁用后，已注入到**已打开标签**里的旧 content script 会「上下文失效」：
// chrome.runtime 变 undefined / 访问抛异常 → 再调 chrome.runtime.sendMessage 就报
// 「Cannot read properties of undefined (reading 'sendMessage')」。守卫掉：失效即静默停手，
// 不再抛错刷 Console；用户重载该页面会注入带有效上下文的新脚本，划词恢复。
function fushiExtAlive() {
  try {
    return !!(typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.id);
  } catch (_) {
    return false;
  }
}

// 轻量页面 toast：制卡全程反馈（开始/成功/失败）+ 解释「为什么这张卡只有截图/没音频」。
// 挂 window 上供 bridge-shim.js（制卡回调）调用。sticky=true 时常驻不自动消失（「制卡中…」要
// 一直显示到出结果），后续用非 sticky 的成功/失败提示替换它并 5s 后淡出。
let fushiToastTimer = null;
// [openSettings] 为真时整条 toast 可点击 → 打开扩展设置页。存在的理由：连接类报错的文案一直在
// 让用户「去扩展设置核对 API key / 恢复自动配置」，但产品里通往设置页的路本身极难找（工具栏图标
// 被 default_popup 占用、options_page 只在 chrome://extensions 深处）——只指路不给路，等于没说。
window.fushiToast = function (text, sticky, openSettings) {
  try {
    let t = document.getElementById('fushi-toast');
    if (!t) {
      t = document.createElement('div');
      t.id = 'fushi-toast';
      t.style.cssText =
        'position:fixed;left:50%;bottom:64px;transform:translateX(-50%);z-index:2147483647;' +
        'max-width:70vw;padding:12px 18px;border-radius:10px;background:rgba(20,20,22,.94);' +
        'color:#fff;font:14px/1.5 "Hiragino Sans",sans-serif;box-shadow:0 6px 24px rgba(0,0,0,.5);' +
        'pointer-events:none;white-space:pre-line;text-align:center;transition:opacity .2s;';
      (document.fullscreenElement || document.body).appendChild(t);
    } else if (t.parentNode !== (document.fullscreenElement || document.body)) {
      (document.fullscreenElement || document.body).appendChild(t); // 全屏切换时迁到正确父节点
    }
    t.textContent = openSettings ? text + '\n（点这里打开扩展设置）' : text;
    // toast 是复用的同一个节点：每次都要把可点态显式设成本次该有的值，否则上一条可点的报错
    // 会把 pointer-events 留给下一条普通提示，让它凭空吞掉页面点击。
    t.style.pointerEvents = openSettings ? 'auto' : 'none';
    t.style.cursor = openSettings ? 'pointer' : '';
    t.onclick = openSettings
      ? function () { try { chrome.runtime.sendMessage({ type: 'openOptions' }); } catch (_) {} }
      : null;
    t.style.opacity = '1';
    if (fushiToastTimer) clearTimeout(fushiToastTimer);
    if (!sticky) fushiToastTimer = setTimeout(() => { if (t) t.style.opacity = '0'; }, 5000);
  } catch (_) { /* DOM 不可用：忽略 */ }
};

// ── 站点 + 视频时间字幕追踪（批量制卡：入队时记这一句的视频时间窗，末尾统一裁）──
function fushiSite() {
  const h = location.hostname;
  if (h.endsWith('netflix.com')) return 'netflix';
  if (h.endsWith('youtube.com') || h === 'youtu.be') return 'youtube';
  return 'other';
}
function fushiYoutubeId() {
  try {
    const u = new URL(location.href);
    if (u.hostname === 'youtu.be') return u.pathname.slice(1) || null;
    return u.searchParams.get('v');
  } catch (_) { return null; }
}
function fushiNetflixId() {
  const m = location.pathname.match(/\/watch\/(\d+)/);
  return m ? m[1] : null;
}
function fushiVideoTimeMs(video) {
  const v = video || document.querySelector('video');
  return v && typeof v.currentTime === 'number' && Number.isFinite(v.currentTime)
    ? Math.round(v.currentTime * 1000)
    : null;
}
function fushiSubtitleTextNow() {
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
const FUSHI_LIVE_CUE_MAX_MS = 12000;
const FUSHI_LIVE_LANG = 'live';
let fushiSamplerGeneration = 0;
let fushiSamplerState = null;

function fushiNewSamplerState(video, key, replayPending) {
  return {
    video: video,
    key: key,
    generation: ++fushiSamplerGeneration,
    lastDomText: '',
    curText: '',
    curStartV: 0,
    lastSampleV: 0,
    cueHist: [],
    liveCue: null,
    liveCueReplay: false,
    replayPending: !!replayPending,
    seeking: false,
    onSeeking: null,
    onSeeked: null,
  };
}

// 最近若干句 {text, startV, endV}（视频时间）只属于当前视频元素代际，避免
// SPA 换视频或播放器 remount 后按旧视频文本回取时间窗。
function fushiPushCueV(state, text, startV, endV) {
  if (!text || endV <= startV) return;
  state.cueHist.push({ text: text, startV: startV, endV: endV });
  if (state.cueHist.length > 80) state.cueHist.shift();
}
function fushiIsProgressiveCueUpdate(previousText, nextText) {
  if (!previousText || !nextText || nextText.length <= previousText.length) return false;
  // YouTube 自绘自动字幕会在同一个 DOM 节点里逐字扩长。完整前缀不变说明这是同一句的
  // 新快照，不是新 cue；否则列表会留下「NVIDIA / NVIDIAの / NVIDIAのCEO…」一整串。
  return nextText.indexOf(previousText) === 0;
}

function fushiFinishSamplerCue(state, endV) {
  if (!state) return;
  if (state.curText && typeof endV === 'number' && endV > state.curStartV) {
    fushiPushCueV(state, state.curText, state.curStartV, endV);
  }
  fushiLiveCueEnd(state, endV);
  state.lastDomText = '';
  state.curText = '';
  state.curStartV = 0;
}

function fushiDetachSamplerVideo(state) {
  if (!state || !state.video || typeof state.video.removeEventListener !== 'function') return;
  try { state.video.removeEventListener('seeking', state.onSeeking); } catch (_) {}
  try { state.video.removeEventListener('seeked', state.onSeeked); } catch (_) {}
}

function fushiBindSamplerVideo(state) {
  if (!state || !state.video || typeof state.video.addEventListener !== 'function') return;
  state.onSeeking = function () {
    if (fushiSamplerState !== state) return;
    if (!state.seeking) fushiFinishSamplerCue(state, state.lastSampleV);
    state.seeking = true;
    state.replayPending = true;
  };
  state.onSeeked = function () {
    if (fushiSamplerState !== state) return;
    // 某些播放器会在 content script 绑定较晚时只被我们观察到 seeked；仍须用
    // 最后一个真实采样时间定格旧 cue，不能把目标时间当旧句 end。
    if (!state.seeking) fushiFinishSamplerCue(state, state.lastSampleV);
    state.seeking = false;
    state.replayPending = true;
  };
  try { state.video.addEventListener('seeking', state.onSeeking); } catch (_) {}
  try { state.video.addEventListener('seeked', state.onSeeked); } catch (_) {}
}

function fushiHasRecordedLiveTrack(key) {
  const track = fushiEpisodeCues[key + '|' + FUSHI_LIVE_LANG];
  return !!(track && track.length);
}

function fushiSyncSamplerLifecycle() {
  const video = document.querySelector('video');
  if (!video) {
    // player 销毁后只用最后一个真实视频时间定格；绝不把缺失播放器映射成 t=0。
    if (fushiSamplerState) {
      fushiFinishSamplerCue(fushiSamplerState, fushiSamplerState.lastSampleV);
      fushiDetachSamplerVideo(fushiSamplerState);
      fushiSamplerState = null;
    }
    return null;
  }
  const key = fushiVideoKey();
  if (!fushiSamplerState ||
      fushiSamplerState.video !== video ||
      fushiSamplerState.key !== key) {
    const previous = fushiSamplerState;
    const replayKnownTrack =
      !!(previous && previous.key === key) ||
      fushiHasRecordedLiveTrack(key);
    if (previous) {
      fushiFinishSamplerCue(previous, previous.lastSampleV);
      fushiDetachSamplerVideo(previous);
    }
    // 同 key remount，或 A→B→A 回到已有 live 轨时，首个真实快照按只读 replay
    // 对照旧轨；真正未见过的 key 则建立新轨，不能复用旧代引用。
    fushiSamplerState = fushiNewSamplerState(video, key, replayKnownTrack);
    fushiBindSamplerVideo(fushiSamplerState);
  }
  return fushiSamplerState;
}

function fushiSampleCue() {
  const state = fushiSyncSamplerLifecycle();
  if (!state) return;
  const nowV = fushiVideoTimeMs(state.video);
  if (nowV === null) return;

  // seek 只认播放器生命周期信号。采样停顿/后台节流造成的正向时间间隔不是 seek，
  // 不能把正常逐字后缀扔进只读 replay。
  if (state.video.seeking === true) {
    if (!state.seeking) fushiFinishSamplerCue(state, state.lastSampleV);
    state.seeking = true;
    state.replayPending = true;
    return;
  }
  if (state.seeking) {
    state.seeking = false;
    state.replayPending = true;
  }
  state.lastSampleV = nowV;
  const text = fushiSubtitleTextNow();

  if (state.replayPending) {
    // seek/remount 后字幕 DOM 可能短暂为空；等第一份真实快照再消费 replay 门。
    if (!text) return;
    state.replayPending = false;
    state.lastDomText = text;
    state.curText = text;
    state.curStartV = nowV;
    fushiLiveCueStart(state, text, nowV, true);
    return;
  }
  if (text === state.lastDomText) return;
  if (fushiIsProgressiveCueUpdate(state.lastDomText, text)) {
    const addedText = text.slice(state.lastDomText.length);
    state.lastDomText = text;
    // 回放已经采过的区间：只跟进页面快照，不改旧 cue，也不把逐字扩长误插成新行。
    if (state.liveCueReplay) {
      state.curText += addedText;
      return;
    }
    // YouTube 自动字幕在同一 DOM 节点中逐字扩长；12 秒内追加到当前行。
    if (state.liveCue && nowV - state.liveCue.startMs < FUSHI_LIVE_CUE_MAX_MS) {
      state.curText += addedText;
      fushiLiveCueAppend(state, addedText, nowV);
      return;
    }
    // DOM 长时间不换节点时，按新增后缀切成下一行，避免整段视频被吞进一个超长 cue。
    if (state.curText) {
      fushiPushCueV(state, state.curText, state.curStartV, nowV);
      fushiLiveCueEnd(state, nowV);
    }
    state.curText = addedText.replace(/^\s+/, '');
    state.curStartV = state.curText ? nowV : 0;
    if (state.curText) fushiLiveCueStart(state, state.curText, nowV, false);
    return;
  }
  if (state.curText) {
    fushiPushCueV(state, state.curText, state.curStartV, nowV); // 上一句定格
    fushiLiveCueEnd(state, nowV); // TODO-1363：live 轨同句定格真实 end
  }
  state.lastDomText = text;
  state.curText = text;
  state.curStartV = text ? nowV : 0;
  if (text) fushiLiveCueStart(state, text, nowV, false); // TODO-1363：新句出现即入 live 轨（暂定 end）
}
// 当前句的视频时间窗：命中历史（倒退回看过的句）用其完整 [startV,endV]；否则用当前 start +
// 现在的视频时间作暂定 end（Netflix 回放时会按字幕变化重新定 end；YouTube 用此窗即可）。
function fushiCurrentCueWindowV() {
  const state = fushiSamplerState;
  if (!state) return null;
  if (!state.curText) {
    const last = state.cueHist[state.cueHist.length - 1];
    return last ? { text: last.text, startV: last.startV, endV: last.endV } : null;
  }
  for (let i = state.cueHist.length - 1; i >= 0; i--) {
    if (state.cueHist[i].text === state.curText) return { text: state.cueHist[i].text, startV: state.cueHist[i].startV, endV: state.cueHist[i].endV };
  }
  const nowV = fushiVideoTimeMs(state.video);
  const endV = Math.max(state.curStartV + 1200, nowV === null ? state.curStartV : nowV);
  return { text: state.curText, startV: state.curStartV, endV: endV };
}
try { setInterval(fushiSampleCue, 200); } catch (_) {}

// TODO-1219 P3：面板行「精确窗」制卡——从字幕面板行查词时带上该行整集拦截的精确 [startMs,endMs]
// 窗（胜过 fushiCurrentCueWindowV 的 DOM 采样窗，DOM 采样在暂停/回放/字幕未渲染时不稳）。契约：
// 每次查词都刷新此变量——面板行查词（fushiLookupAtPoint 带 cueWindow）设精确窗；mousemove 划词
// （无 cueWindow）清成 null 回落 DOM 采样。制卡入口 fushiEnqueue 优先消费它。null 表示无精确窗。
let fushiPendingCueWindow = null;

// ── TODO-1219 P1：整集字幕（主世界 netflix-bridge.js 抓清单 timedtext → 这里解析存档）──
// P1 仅存档 + console 验证；P2 面板消费 fushiEpisodeCues。DOM 采样 fushiCueHist 仍作回退不删。
// 解析器 parseWebVtt / parseTtml 定义在 subtitle-adapters.js（同隔离世界、先于 content.js 加载）。
const fushiEpisodeCues = Object.create(null); // key: `${videoId}|${lang}` -> [{startMs,endMs,text}]
// TODO-1219 P2：把整集字幕存档暴露到 window，供隔离世界内后加载的 subtitle-panel.js 消费
// （面板只依赖 window.fushiEpisodeCues 这一个契约，不跨文件依赖 const 词法作用域）。同一对象
// 引用，后续 fushiOnFullEpisodeCues 就地写入即对面板可见。
window.fushiEpisodeCues = fushiEpisodeCues;
function fushiOnFullEpisodeCues(msg) {
  try {
    const cues = msg.format === 'ttml' ? parseTtml(msg.text) : parseWebVtt(msg.text);
    if (!cues || !cues.length) return;
    const vid = String(msg.videoId || netflixVideoIdFromPath(location.pathname) || '');
    const key = vid + '|' + (msg.lang || 'und');
    fushiEpisodeCues[key] = cues;
    try {
      console.log('[Fushi][TODO-1219] full-episode cues intercepted:', key, cues.length, 'cues; first:', cues.slice(0, 3));
    } catch (_) {}
    // TODO-1219 P2：通知面板有新轨可用（切集/切轨会重放清单）。面板在同一隔离世界、于 content.js
    // 之后加载，注册此钩子；未加载时静默跳过。
    try {
      if (typeof window.fushiSubtitlePanelOnCues === 'function') window.fushiSubtitlePanelOnCues(key);
    } catch (_) {}
  } catch (_) {}
}
window.addEventListener('message', (e) => {
  if (e.source !== window || !e.data || e.data.__fushiNf !== 'cues') return;
  fushiOnFullEpisodeCues(e.data);
});
// TODO-1219/1363（勾选面板要刷新 + 面板空列表的根因）：本脚本 document_idle 注入，主世界
// netflix-bridge.js document_start 就装好 hook——Netflix 播放清单/字幕轨常在**本 listener 注册前**
// 就被抓取并 postMessage 出去，fire-and-forget 的消息永久丢失 → store 空、勾选开关无物可挂、
// 面板只剩预取的下一集轨（列表空）。接收端就位后立刻请求 bridge 重放已存档的 cue 消息，消除时序运气。
try { window.postMessage({ __fushiNf: 'replayCues' }, '/'); } catch (_) {}

// ── asb 移植：通用流媒体字幕桥（stream-bridge.js，MAIN 世界）→ store ──
// TVer / Bilibili.tv / Hulu JP / Prime Video 的主世界桥抓到整集字幕原文后经
// {__fushiStream:'cues'} 送到这里，按 format 分派解析器写进 fushiEpisodeCues。
// 轨 key 用桥捕获时的 host+path（与 fushiVideoKey 的通用回落同构）——SPA 换集后
// 消息晚到也落在正确的视频 key 下。存档/重放握手与 netflix-bridge 相同。
function fushiOnStreamCues(msg) {
  try {
    let cues;
    if (msg.format === 'cues' && Array.isArray(msg.cues)) {
      cues = msg.cues.flatMap((cue) => {
        if (!cue || typeof cue.startMs !== 'number' || typeof cue.endMs !== 'number') return [];
        const text = String(cue.text || '').trim();
        return text ? [{ startMs: cue.startMs, endMs: cue.endMs, text }] : [];
      });
    } else if (msg.format === 'ttml') cues = parseTtml(msg.text);
    else if (msg.format === 'bbjson') cues = parseBilibiliJson(msg.text);
    else cues = parseWebVtt(msg.text); // webvtt / srt（parseWebVtt 兼容 SRT 块）
    if (!cues || !cues.length) return;
    const vidKey = String(msg.videoKey ||
      (location.hostname + (msg.path || location.pathname))).replace(/\|/g, '_');
    const lang = String(msg.lang || 'und').replace(/\|/g, '_');
    const key = vidKey + '|' + lang;
    fushiEpisodeCues[key] = cues;
    fushiNotifyPanel(key);
  } catch (_) {}
}
window.addEventListener('message', (e) => {
  if (e.source !== window || !e.data || e.data.__fushiStream !== 'cues') return;
  fushiOnStreamCues(e.data);
});
try { window.postMessage({ __fushiStream: 'replayCues' }, '/'); } catch (_) {}

// ── TODO-1363：通用字幕轨 provider（所有站点） ──
// 数据契约不变：window.fushiEpisodeCues[`${videoKey}|${lang}`] = [{startMs,endMs,text}]，新数据到达
// 即调 window.fushiSubtitlePanelOnCues(key)。Netflix 整集拦截之外新增两条通用通道，站点差异全部
// 收敛在「谁往 store 里写」，面板零站点特例：
//   a) HTML5 video.textTracks 全量收割——任何用原生 <track>/TextTrack 的站点，cue 是结构化数据
//      （精确起止 + 文本），整轨直接读出，随流媒体渐进加载增量刷新；
//   b) DOM 字幕采样升格 live 轨——fushiSampleCue 已在采字幕（YouTube .ytp-caption-segment /
//      Netflix .player-timedtext 等既有通道），把采到的句子按视频时间有序去重进 `${videoKey}|live`
//      轨，边看边长（YouTube 自绘字幕不走 textTracks，靠这条）。
function fushiVideoKey() {
  const site = fushiSite();
  if (site === 'netflix') {
    const id = fushiNetflixId();
    if (id) return id; // 与整集拦截的 store key（manifest movieId）对齐
  }
  if (site === 'youtube') {
    const id = fushiYoutubeId();
    if (id) return 'yt-' + id;
  }
  // 其它站点：host+path 即视频身份（'|' 是 store key 分隔符，替换掉防串 key）。
  return (location.hostname + location.pathname).replace(/\|/g, '_');
}
// 面板（subtitle-panel.js，同隔离世界后加载）用同一把 key 过滤当前视频的轨。
window.fushiVideoKey = fushiVideoKey;

function fushiNotifyPanel(key) {
  try {
    if (typeof window.fushiSubtitlePanelOnCues === 'function') window.fushiSubtitlePanelOnCues(key);
  } catch (_) {}
}

// 有序插入 + 去重：同文本且句首相差 <windowMs 视为同一句（倒退/回放重看不重复入轨）。
// windowMs 缺省 750（DOM 采样 live 轨的时间轴本就有采样抖动）；textTracks 收割传 1（精确
// 时间轴，只有 startMs 完全相同才算同一条——连续两声相同短句是真实台词，不能被宽窗误杀）。
// 返回是否真插入。
function fushiSortedCueInsert(cues, cue, windowMs) {
  const win = windowMs > 0 ? windowMs : 750;
  let lo = 0;
  let hi = cues.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (cues[mid].startMs <= cue.startMs) lo = mid + 1; else hi = mid;
  }
  for (let i = lo - 1; i >= 0 && cue.startMs - cues[i].startMs < win; i--) {
    if (cues[i].text === cue.text) return false;
  }
  for (let j = lo; j < cues.length && cues[j].startMs - cue.startMs < win; j++) {
    if (cues[j].text === cue.text) return false;
  }
  cues.splice(lo, 0, cue);
  return true;
}

// live cue/replay 引用只保存在 fushiSamplerState 当前代际；SPA/video remount 后旧引用不可达。
function fushiCueTextRelated(a, b) {
  return a === b || a.indexOf(b) === 0 || b.indexOf(a) === 0;
}
function fushiLiveCueStart(state, text, startV, allowReplay) {
  if (!text) {
    state.liveCue = null;
    state.liveCueReplay = false;
    return;
  }
  const key = state.key + '|' + FUSHI_LIVE_LANG;
  const track = fushiEpisodeCues[key] || (fushiEpisodeCues[key] = []);
  if (allowReplay) {
    // 真实 seek 或同 key 的新 video 代际回到已采区间时，页面先给较短快照、再逐字扩长；
    // 只读 replay 只由这两个明确生命周期事件开启，普通采样停顿不会误入。
    for (const existing of track) {
      if (startV < existing.startMs - 750 || startV > existing.endMs + 750) continue;
      if (!fushiCueTextRelated(existing.text, text)) continue;
      state.liveCue = null;
      state.liveCueReplay = true;
      return;
    }
  }
  const cue = { startMs: startV, endMs: startV + 1500, text: text };
  if (fushiSortedCueInsert(track, cue)) {
    state.liveCue = cue;
    state.liveCueReplay = false;
    fushiNotifyPanel(key);
  } else {
    state.liveCue = null; // 已见过的句：不重复入轨，也不动旧句窗
    state.liveCueReplay = true;
  }
}
function fushiLiveCueAppend(state, addedText, nowV) {
  if (!state.liveCue || state.liveCueReplay || !addedText) return false;
  state.liveCue.text += addedText;
  // 句子仍在屏幕上时保持一个向后的暂定窗；真正换句/清空时由 fushiLiveCueEnd 定格。
  state.liveCue.endMs = Math.max(state.liveCue.endMs, nowV + 1500);
  const key = state.key + '|' + FUSHI_LIVE_LANG;
  fushiNotifyPanel(key);
  return true;
}

function fushiLiveCueEnd(state, endV) {
  if (state.liveCue && typeof endV === 'number' && endV > state.liveCue.startMs) {
    state.liveCue.endMs = endV;
  }
  state.liveCue = null;
  state.liveCueReplay = false;
}

// a) textTracks 全量收割：轮询归并。kind 只收 subtitles/captions。两条完整性规则：
//   ① disabled 轨浏览器根本不加载 cues → 以前直接跳过 = 只有播放器当前开着的那条轨能进
//      store，侧边栏语言轨永远只有一条。asbplayer 同款做法：临时升到 hidden（加载 cues 但
//      不渲染、不影响站点显示），下一轮轮询即可收割全部语言轨。
//   ② 归并而非整轨覆盖：hls.js/Shaka 的分片字幕会随 back-buffer 回收 / seek 重建而增删
//      cue——旧的「条数没长就跳过、长了整轨覆盖」两个方向都丢字幕（新区间进不来 / 旧区间
//      被抹掉），正是「侧边栏字幕不全」的主根因。逐条有序插入（fushiSortedCueInsert 同文本
//      ±750ms 去重），轨只增不减，快进/回看过的各区间都留得住。
// 每条 track 只尝试升 hidden 一次：站点播放器（hls.js 等）若把 mode 拨回 disabled，那是它在
// 管理轨道，1.2s 轮询若反复翻回去会形成无限拉锯（每次翻转都触发站点侧 change 处理）。一次
// 尝试足以让静态播放器把 cues 加载出来；被站点收回的轨就尊重站点。
const fushiPromotedTracks = typeof WeakSet === 'function' ? new WeakSet() : null;
function fushiHarvestTextTracks() {
  const v = document.querySelector('video');
  if (!v || !v.textTracks || !v.textTracks.length) return;
  const vidKey = fushiVideoKey();
  // 同语言多轨（如 "English" 与 "English [CC]"，language 同为 en）必须分 key，否则两条轨的
  // cue 被归并进同一条侧边栏轨、台词穿插重复且轨只增不减无法恢复。仅在语言撞车时才把 label
  // 编进轨身份——单轨语言保持裸语言码，与其它 provider（stream-bridge/YouTube）的 key 习惯一致。
  const langCount = Object.create(null);
  for (let i = 0; i < v.textTracks.length; i++) {
    const t = v.textTracks[i];
    if (!t || (t.kind !== 'subtitles' && t.kind !== 'captions')) continue;
    const l = String(t.language || t.label || 'und');
    langCount[l] = (langCount[l] || 0) + 1;
  }
  for (let i = 0; i < v.textTracks.length; i++) {
    const tt = v.textTracks[i];
    if (!tt || (tt.kind !== 'subtitles' && tt.kind !== 'captions')) continue;
    if (tt.mode === 'disabled') {
      if (fushiPromotedTracks && !fushiPromotedTracks.has(tt)) {
        fushiPromotedTracks.add(tt);
        try { tt.mode = 'hidden'; } catch (_) {}
      }
      continue; // cues 要到下一轮轮询才加载好
    }
    if (!tt.cues || !tt.cues.length) continue;
    const langRaw = String(tt.language || tt.label || 'und');
    const langId = langCount[langRaw] > 1
      ? langRaw + '·' + String(tt.label || '#' + i)
      : langRaw;
    const key = vidKey + '|' + langId.replace(/\|/g, '_');
    const track = fushiEpisodeCues[key] || (fushiEpisodeCues[key] = []);
    let inserted = false;
    for (let j = 0; j < tt.cues.length; j++) {
      const c = tt.cues[j];
      if (!c || typeof c.startTime !== 'number' || typeof c.endTime !== 'number') continue;
      const text = stripCueTags(String(c.text || ''));
      if (!text) continue;
      const cue = { startMs: Math.round(c.startTime * 1000), endMs: Math.round(c.endTime * 1000), text: text };
      if (fushiSortedCueInsert(track, cue, 1)) inserted = true;
    }
    if (inserted) fushiNotifyPanel(key);
  }
}
try { setInterval(fushiHarvestTextTracks, 1200); } catch (_) {}

// c) YouTube 真整集字幕（BUG-783 后续 / A）：YouTube 自绘字幕不走 textTracks，DOM 采样（live 轨）
//    暂停/seek/字幕未渲染时不稳、拿不到整集。改向本地 Fushi server 要真字幕——server 复用 app 内
//    已修的解析器（androidVr getPlayerResponse + format-3 timedtext），一次拿全部轨（自动/人工）+
//    整集 cue，写进 store（真语言标签轨，面板排序自然盖过 |live）。best-effort：失败静默、live 回退。
function fushiYtCaptionLabel(t, used) {
  let base = String(t.languageName || t.languageCode || 'und').replace(/\|/g, '_');
  if (t.isAutoGenerated && !/auto|自动/i.test(base)) base += ' (自动)';
  if (t.isTranslated) base += ' →译';
  let label = base;
  let n = 2;
  while (used.has(label)) label = base + ' #' + (n++); // 同名轨去重（防覆盖）
  used.add(label);
  return label;
}
function fushiApplyYoutubeServerCaptions(resp) {
  if (!resp || !resp.ok || !resp.data || !Array.isArray(resp.data.tracks)) return 0;
  const vidKey = fushiVideoKey();
  const used = new Set();
  let applied = 0;
  for (const t of resp.data.tracks) {
    if (!t || !Array.isArray(t.cues) || !t.cues.length) continue;
    const cues = [];
    for (const c of t.cues) {
      if (!c || typeof c.startMs !== 'number' || typeof c.endMs !== 'number') continue;
      const text = String(c.text || '');
      if (!text) continue;
      cues.push({ startMs: c.startMs, endMs: c.endMs, text: text });
    }
    if (!cues.length) continue;
    const key = vidKey + '|' + fushiYtCaptionLabel(t, used);
    fushiEpisodeCues[key] = cues;
    fushiNotifyPanel(key);
    applied++;
  }
  return applied;
}
let fushiYtCaptionsFetchedFor = null; // 已请求过的 videoId（防重复请求；SPA 切视频后 id 变即重取）
let fushiYtDirectBridgeStartedAt = 0;
let fushiYtDirectBridgeVideoId = null;
function fushiMaybeFetchYoutubeCaptions() {
  if (fushiSite() !== 'youtube') return;
  const id = fushiYoutubeId();
  if (!id || fushiYtCaptionsFetchedFor === id) return;
  if (fushiYtDirectBridgeVideoId !== id) {
    fushiYtDirectBridgeVideoId = id;
    fushiYtDirectBridgeStartedAt = Date.now();
  }
  const directKeyPrefix = 'yt-' + id + '|';
  if (Object.keys(fushiEpisodeCues).some((key) =>
    key.indexOf(directKeyPrefix) === 0 && key !== directKeyPrefix + FUSHI_LIVE_LANG)) {
    fushiYtCaptionsFetchedFor = id;
    return;
  }
  // asbplayer 式 MAIN-world bridge 优先：播放器运行态 URL 含 POT，最完整也最快。本地 server
  // 仅在 bridge 8 秒仍拿不到整轨时兜底，避免同时请求产生重复语言轨。
  if (Date.now() - fushiYtDirectBridgeStartedAt < 8000) return;
  fushiYtCaptionsFetchedFor = id;
  try {
    chrome.runtime.sendMessage({ type: 'youtubeCaptions', videoId: id }, (resp) => {
      try {
        if (chrome.runtime.lastError) { fushiYtCaptionsFetchedFor = null; return; } // 允许下轮重试
        if (fushiYoutubeId() !== id) return; // SPA 已切视频，绝不把旧响应写进新视频 store
        if (!fushiApplyYoutubeServerCaptions(resp)) fushiYtCaptionsFetchedFor = null; // 空→可重试
      } catch (_) {}
    });
  } catch (_) { fushiYtCaptionsFetchedFor = null; }
}
try { setInterval(fushiMaybeFetchYoutubeCaptions, 1500); } catch (_) {}

// ── 制卡队列（持久化：chrome.storage.local，跨刷新/跨剧集/跨会话累积，随时点击生成）──
// 内存镜像 fushiQueue 以 storage 为真相源；storage.onChanged 让多标签/重载后计数一致。
let fushiQueue = [];
function fushiQueueSave() {
  try { chrome.storage.local.set({ fushiQueue: fushiQueue }); } catch (_) {}
}
// 移除已成功生成的项：storage 读-改-写（不改可能被 storage.onChanged 覆盖的内存镜像），跨标签安全。
// 生成过程中别的标签/别集入队都不会被这一步误删（只按 id 剔除本次成功的）。
async function fushiRemoveQueued(okIds) {
  if (!okIds || !okIds.length) return;
  try {
    const got = await chrome.storage.local.get(['fushiQueue']);
    const fresh = Array.isArray(got.fushiQueue) ? got.fushiQueue : [];
    const remaining = fresh.filter((q) => okIds.indexOf(q.id) < 0);
    fushiQueue = remaining;
    await chrome.storage.local.set({ fushiQueue: remaining });
  } catch (_) {}
}
// 制卡结果分类（TODO-1184）：卡已建(success)或已存在(duplicate) → 出队(done，队列才会清)；
// Anki 未配置(notConfigured) → 留队 + 提示用户去配（配好再点生成即可，出队会静默丢词）；
// 其余(error / 网络失败 / 上下文失效) → 留队下次重试。只有 done 才 push 进 okIds 被剔除。
// TODO-1331：把制卡请求的 HTTP/网络层失败翻成用户能懂的原因。resp 形状见 background.js：
// HTTP 成功 {ok:true,status,data}；非 2xx {ok:false,status,data:null}；fetch 抛异常
// （连接被拒/超时/DNS）{ok:false,error}。据此分 401 鉴权 / 404 端点 / 4xx-5xx 服务端 /
// 连不上（无 status）四类，让扩展弹明确 ✗ 原因，而不是静默 retry 到「你看日志却查不到」。
function fushiMineHttpFailureReason(resp) {
  if (!resp) return '制卡无响应（扩展已更新？刷新页面 F5 重试）';
  const status = typeof resp.status === 'number' ? resp.status : 0;
  if (status === 401) return '鉴权失败(401)：扩展 token 与 Fushi 不一致，去扩展设置核对 API key';
  if (status === 404) return '端点不存在(404)：Fushi 未开 Yomitan API server 或端口不对';
  if (status >= 500) return '服务端错误(' + status + ')：制卡出错，去 Fushi 错误日志页查详情';
  if (status >= 400) return '请求被拒(' + status + ')：' + (resp.error || '检查扩展设置');
  // ok:false 且无 status = fetch 抛异常（连接被拒/超时/DNS）：server 没开或主机/端口错。
  return '连不上 Fushi(' + (resp.error || '连接被拒/超时') + ')：确认已开 Yomitan API server 且主机/端口正确';
}
function fushiClassifyMineResp(resp) {
  // TODO-1331：HTTP/网络层失败不再静默 retry——弹 ✗ 原因让用户看得见（YouTube/Netflix
  // 批量制卡共用本分类器，两条链路的 HTTP 失败都据此显因）。
  if (!resp || !resp.ok || !resp.data) {
    if (typeof window.fushiToast === 'function') {
      // 401 / 其它 4xx 的文案就是让用户去扩展设置核对 token，故这两类做成可点直达设置页。
      const st = resp && typeof resp.status === 'number' ? resp.status : 0;
      const settingsFixable = st === 401 || (st >= 400 && st < 500 && st !== 404);
      try {
        window.fushiToast('✗ ' + fushiMineHttpFailureReason(resp), false, settingsFixable);
      } catch (_) {}
    }
    return 'retry';
  }
  const d = resp.data;
  const r = d.result;
  // TODO-1303：服务端现在回带诊断（message=失败原因/音频落空警告，
  // detail=技术细节）。末尾弹 toast 显因，终结「制卡失败报成功 + 没提示」；
  // app 侧已把失败写进错误日志。
  const reason = (d.message || d.detail || '').toString();
  if (r === 'success' || r === 'duplicate') {
    // 部分成功：卡建好了但单词音频落空（message 非空）→ 与真成功区分，
    // 弹警告但仍算 done（卡确实建了）。
    if (r === 'success' && reason && typeof window.fushiToast === 'function') {
      try { window.fushiToast('⚠ ' + reason); } catch (_) {}
    }
    return 'done';
  }
  if (r === 'notConfigured') return 'unconfigured';
  // error / 其它：失败，弹原因（无原因回落通用文案）后重试。
  if (typeof window.fushiToast === 'function') {
    try { window.fushiToast('✗ ' + (reason || '制卡失败，稍候再试')); } catch (_) {}
  }
  return 'retry';
}
function fushiQueueLoad() {
  try {
    chrome.storage.local.get(['fushiQueue'], (r) => {
      fushiQueue = Array.isArray(r && r.fushiQueue) ? r.fushiQueue : [];
    });
  } catch (_) {}
}
// TODO-1222：队列去重唯一键 = 词 + 句 + 站点 + 视频ID（同一字幕行重复点「制卡」视为同一条）。
function fushiQueueKey(q) {
  const word = (q && q.fields && (q.fields.expression || q.fields.word || q.fields.term)) || '';
  const sent = (q && q.sentence) || '';
  const site = (q && q.site) || '';
  const vid = (q && (q.youtubeId || q.netflixId)) || '';
  return String(word) + '\0' + String(sent) + '\0' + String(site) + '\0' + String(vid);
}
window.fushiEnqueue = function (fields, sentence) {
  // TODO-1219 P3：若本次查词来自字幕面板行（fushiPendingCueWindow 非空），用该行整集拦截的精确
  // [startMs,endMs] 窗（稳过 DOM 采样）；否则回落 fushiCurrentCueWindowV 的 DOM 采样窗。下方
  // startV-200/endV+200 录制边距 + fushiQueueKey 去重两路不变。
  const cw = fushiPendingCueWindow;
  const w = cw ? { text: cw.text || '', startV: cw.startMs, endV: cw.endMs } : fushiCurrentCueWindowV();
  if (!w) return { ok: false, reason: 'no-cue' };
  // BUG-1416：**制卡那一刻**的视频时间就地采样并随队列项持久化。用户拍板「按制卡时候的时间来」，
  // 而这是唯一还知道那一刻的地方——之后的回放录制只知道句首，再也拿不回这个时刻。
  // 只在它确实落在本句 cue 窗内才记：面板行查词（fushiPendingCueWindow）可能停在别的句上，
  // 那种时刻不在将要录的片段里，记下来只会让下游取到夹取后的边界帧。null → 下游退句首。
  const nowV = fushiVideoTimeMs();
  const mineAtV = (nowV !== null && nowV >= w.startV && nowV <= w.endV) ? nowV : null;
  const site = fushiSite();
  const youtubeId = site === 'youtube' ? fushiYoutubeId() : null;
  const netflixId = site === 'netflix' ? fushiNetflixId() : null;
  // BUG-676（TODO-1361 ③）：入队即抓当前网飞剧名（此刻在正确剧集页），随卡持久化 → 生成时发给
  // 服务端当 documentTitle（Anki 视频名字段）。YouTube 走服务端解析标题，无需在此抓。
  const documentTitle =
      site === 'netflix' && typeof netflixDocumentTitle === 'function'
          ? netflixDocumentTitle()
          : '';
  const item = {
    id: Date.now() + '-' + Math.random().toString(36).slice(2),
    fields: fields, sentence: sentence || w.text || '',
    startV: Math.max(0, w.startV - 200), endV: w.endV + 200,
    // BUG-1416：startV 带了 200ms 录制头部提前量，不是真句首；静态帧「字幕开头」要的是真句首。
    cueStartV: w.startV,
    mineAtV: mineAtV,
    site: site,
    youtubeId: youtubeId,
    netflixId: netflixId,
    documentTitle: documentTitle,
  };
  // TODO-1222：已在队列（同词同句同片）→ 不重复入队，返回 duplicate 让弹窗提示「已在队列中」。
  const key = fushiQueueKey(item);
  if (fushiQueue.some((q) => fushiQueueKey(q) === key)) {
    return { ok: true, count: fushiQueue.length, duplicate: true };
  }
  fushiQueue.push(item);
  fushiQueueSave();
  return { ok: true, count: fushiQueue.length };
};
// 跨标签/重载同步：storage 变了就刷新内存镜像 + 计数。
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.fushiQueue) {
      fushiQueue = Array.isArray(changes.fushiQueue.newValue) ? changes.fushiQueue.newValue : [];
    }
  });
} catch (_) {}

// TODO-1221：页面右下角制卡队列 chip 已删——队列 UI 统一到浏览器工具栏图标 popup（vendor/action-popup.html）。
// 队列数据仍以 chrome.storage.local 的 fushiQueue 为单一真相源，供图标 popup 读取/删除/生成。
try { fushiQueueLoad(); } catch (_) {}

/**
 * 跟随宿主页配色返回弹窗主题名。
 * @returns {'dark'|'light'}
 */
function fushiResolveTheme() {
  return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
    ? 'dark'
    : 'light';
}

// 生成全部（YouTube）：逐条把 {videoId,起,止} 发服务端从真实流裁 → 出卡。无录屏、无回放。
// 只移除**成功**的项（失败留在队列下次重试）；跨视频累积的 youtube 项都在此生成。
window.fushiGenerateAll = async function () {
  const items = fushiQueue.filter((q) => q.site === 'youtube' && q.youtubeId);
  if (!items.length) {
    window.fushiToast('YouTube 队列为空：先开字幕 → shift 查词 → 点弹窗「制卡」入队，再来生成');
    return;
  }
  if (!fushiExtAlive()) { window.fushiToast('扩展已更新，刷新页面(F5)后重试'); return; }
  let done = 0, fail = 0, unconfigured = 0;
  const okIds = [];
  window.fushiToast('生成中… 0/' + items.length, true);
  for (const q of items) {
    const cls = await new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({
          type: 'mineYoutube', fields: q.fields, sentence: q.sentence,
          youtubeVideoId: q.youtubeId, startMs: q.startV, endMs: q.endV,
        }, (resp) => {
          try { if (chrome.runtime.lastError) return resolve('retry'); } catch (_) { return resolve('retry'); }
          resolve(fushiClassifyMineResp(resp));
        });
      } catch (_) { resolve('retry'); }
    });
    // done(成功/已存在)才出队；unconfigured/retry 留队（前者提示配 Anki，后者下次重试）。
    if (cls === 'done') { done++; okIds.push(q.id); }
    else { fail++; if (cls === 'unconfigured') unconfigured++; }
    window.fushiToast('生成中… ' + (done + fail) + '/' + items.length, true);
  }
  await fushiRemoveQueued(okIds);
  if (unconfigured > 0) {
    window.fushiToast('部分未生成：Anki 未配置，请在 Fushi 中配置 Anki 后重试（已处理 ' + done + '，保留 ' + fail + '）');
  } else {
    window.fushiToast('✓ 生成完成：已处理 ' + done + (fail ? ' · 失败 ' + fail : ''));
  }
};

// ── Netflix 回放录制（DRM）：由 content 驱动，capture 经 background/offscreen（beginClip/endClip）──
let fushiNfBatchRunning = false;

// 生成本剧集的项：逐句 seek 到句首 → 播放到字幕变化(=本句结束) → 停录 → 送服务端整段裁 [0,时长]
// 转 GIF+音频。整场用注入 CSS 藏字幕轨(GIF 不烧字幕，且能扛 Netflix 换节点)+藏鼠标。不停录屏
// （跨集续用，由 nfFinish 收尾）。只移除成功的本集项。
async function fushiRunNetflixBatch() {
  const nfId = fushiNetflixId();
  // TODO-1217：按视频时间升序，逐句 seek 单调前进（乱序会往回跳，放大抖动）。filter 已产生新数组，
  // sort 不影响作为跨标签真相源的 fushiQueue。
  const items = fushiQueue
    .filter((q) => q.site === 'netflix' && q.netflixId === nfId)
    .sort((a, b) => (a.startV || 0) - (b.startV || 0));
  if (!items.length) return;
  const v = document.querySelector('video');
  if (!v) return;
  // TODO-1175：记录批量前的播放位置/态，批量结束（成功或异常）后都回到这里、恢复原播放/暂停态。
  const resumeAt = v.currentTime;
  const wasPlaying = !v.paused;
  const hideStyle = document.createElement('style');
  hideStyle.id = 'fushi-nf-hide-sub';
  // TODO-1216：藏字幕轨（GIF 不烧字幕）+ 藏 Netflix 控制/进度条——逐句 seek 与结尾 pause 会强制
  // Netflix 显控制条，落在录制窗会被录进 clip。多选择器兜底 Netflix 改类名（同下方字幕兜底策略）。
  hideStyle.textContent =
    // 原生 Side Panel 不属于标签页录制画面；这里只隐藏仍位于网页内的字幕覆盖层与拖放提示。
    // TODO-1270 Bug B：Fushi 自己的「生成中」浮层(#fushi-toast)也在被 tabCapture 录进 GIF
    // （用户报「底部生成中条送给了网飞」）→ 整场批量期间一并隐藏，进度改由扩展图标红点徽标传达。
    '.player-timedtext,#fushi-subtitle-overlay,#fushi-subtitle-drop-hint,#fushi-toast{visibility:hidden!important}' +
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
  try { if (typeof window.fushiSubtitlePanelSuspendPush === 'function') window.fushiSubtitlePanelSuspendPush(); } catch (_) {}
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
    const onMsg = (e) => { if (e.source === window && e.data && e.data.__fushiNf === 'seekDone') finish(); };
    v.addEventListener('seeked', onSeeked);
    window.addEventListener('message', onMsg);
    // 走 Netflix 官方播放器 API seek（主世界 netflix-bridge.js 执行），不改 currentTime → 不触发 M7375。
    try { window.postMessage({ __fushiNf: 'seek', ms: ms }, '/'); } catch (_) {}
    setTimeout(finish, 5000); // 兜底：seeked / seekDone 都不来也继续
  });
  try {
    for (const q of items) {
      let began = false; // beginClip 是否成功（决定 finally 是否需要收口 recorder）
      let cls = 'retry';
      try {
        const targetSec = Math.max(0, q.startV / 1000);
        await seekTo(targetSec);
        // TODO-1361 ⑤（BUG-685 seek-in-then-out 跳卡根因）：seek 落点后先确认 seek 真落到 <video>
        // 元素层再开录。bridge 的 seekDone 只据 Netflix 播放器 API getCurrentTime 判定，MSE 下
        // <video> 元素可能仍在 seeking / 停在旧位；不确认就 pause/play 会停在旧位、录错内容或空录。
        // 暂停态等落定不推进 currentTime、不吃入队预留的 200ms 头部提前量（seek 目标本就是 cueStart-200）。
        try { v.pause(); } catch (_) {}
        await fushiWaitForSeekSettled(v, targetSec, 4000);
        // TODO-1335 ④：落点后**先等缓冲就绪再开录**（readyState>=HAVE_FUTURE_DATA=3），暂停态等不推进
        // currentTime → 不吃头部提前量，也不把 stall 冻结帧录进 clip（offscreen 墙钟时长照走 → 虚长）。
        await fushiWaitForBuffered(v, 3000);
        // TODO-1361 ⑤（BUG-685）：以「currentTime 真正前进」为唯一判据有界等视频开录，期间反复补 play()。
        // 旧实现只在固定 480ms（8×60ms）后单看一次 v.paused 就判跳——但 v.paused===false 不等于在播
        // （可能仍 seeking 冻结），且 Netflix seek→恢复播放耗时多变，480ms 常不够 → 本可录的句被误判
        // 「暂停」立即 seek 走（用户报「跳转过去以后马上跳转走了、根本没制卡」根因）。改为轮询到视频真
        // 前进才开录；到 4s 上界仍推不动才按失败计（真 DRM/网络/自动播放失败，留队可重试，BUG-675 清点
        // 不变），不再因 seek→播放时序把本可录的句误跳。
        const advancing = await fushiWaitForPlaying(v, 4000);
        if (!advancing) { fail++; window.fushiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
        // BUG-1416：实测片段的**时间基锚点**（clip t=0 对应的视频时间）。绝不能假设它等于
        // 本句 seek 目标——上面的 waitForSeekSettled/waitForBuffered/waitForPlaying（40ms 轮询、
        // 要求 currentTime 真前进 20ms 以上）加这一次 IPC 往返，都在推进视频时间。
        // recorder.start() 必落在「发消息」与「收到 ack」之间，故真锚点必在 [before, after] 内：
        // 取中点，误差上界 = 半个区间，随请求下发供服务端写进诊断日志（可观测，不靠猜）。
        const anchorBeforeV = fushiVideoTimeMs(v);
        const beginResp = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'beginClip' });
        const anchorAfterV = fushiVideoTimeMs(v);
        began = !!(beginResp && beginResp.ok);
        if (!began) { fail++; window.fushiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
        const anchorV = (anchorBeforeV === null || anchorAfterV === null)
          ? null
          : Math.round((anchorBeforeV + anchorAfterV) / 2);
        const anchorUncertaintyMs = (anchorBeforeV === null || anchorAfterV === null)
          ? null
          : Math.round(Math.abs(anchorAfterV - anchorBeforeV) / 2);
        // 本句结束判据：字幕文本变成别的/清空（≠ 这一句），且已过句首 0.4s。refText 用入队时存的整句
        // 文本，比「播放时现采样」稳（避免字幕还没渲染时采到空 → 判据失效整段录到超时）。
        // seek 后字幕要零点几秒才重新渲染：**先等本句字幕真正出现**（过句首 0.3s 后第一段非空字幕
        // 作参照 ref），**再**录到字幕变成别句(=本句结束)才停。不能一开始就比 refText——seek 后先采到
        // 的是残留/空字幕，会被误判成「已结束」→ 录一瞬就停（用户报「一下就停了」根因）。
        // hardEnd 只是字幕检测失效（字幕关/相邻同文本）时的安全上限。
        // TODO-1364：字幕清空/变句 = Netflix 字幕 **display end**，常早于本句 **语音 end**；且入队窗
        // 的 200ms 尾部预留（q.endV = cueEnd+200）在回放录制侧从未被消费（见 fushiCurrentCueWindowV
        // 注释「Netflix 回放时会按字幕变化重新定 end」），录制侧只保头部 200ms、从不补尾 → 检测到句末
        // 就立即 pause+endClip 会截掉尾段音频（用户报「音频少了后面一段」根因）。修复：检测到句末后不
        // 立即停，再多录一段尾部余量（与 200ms 头部提前量对称、略放宽以覆盖字幕清空后的残余语音）再停。
        const startSec = Math.max(0, q.startV) / 1000;
        const hardEnd = startSec + 12; // 12s 硬上限
        const deadline = Date.now() + 16000;
        const kNfClipTailPadSec = 0.35; // 句末尾部余量（秒）：覆盖字幕 display end 之后的残余语音，防截尾
        let ref = '';
        let endAtSec = 0; // 检测到句末后的目标停录视频时间（= 句末视频时间 + 尾部余量）；0 = 尚未到句末
        while (v.currentTime < hardEnd && Date.now() < deadline) {
          await sleep(120);
          const nowText = fushiSubtitleTextNow();
          if (!ref) {
            if (nowText && v.currentTime > startSec + 0.3) ref = nowText; // 抓到本句字幕作参照
            continue;
          }
          if (!endAtSec) {
            if (nowText !== ref) endAtSec = v.currentTime + kNfClipTailPadSec; // 句末：再录一段尾部余量
            continue;
          }
          if (v.currentTime >= endAtSec) break; // 尾部余量录满 → 停录（尾段音频完整）
        }
        try { v.pause(); } catch (_) {}
        const clip = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'endClip' });
        began = false; // 已正常收口，finally 不再重复 endClip
        if (clip && clip.ok && clip.clipBase64) {
          cls = await new Promise((resolve) => {
            chrome.runtime.sendMessage(
              // BUG-676（TODO-1361 ③）：带上入队时抓的剧名；旧队列项无则录制时现抓（此刻正在目标集页）。
              { type: 'mineClip', fields: q.fields, sentence: q.sentence, clipBase64: clip.clipBase64, clipDurationMs: clip.clipDurationMs,
                // BUG-1416：静态帧模式要「制卡那一刻」的帧，服务端据这三个视频时间换算片段内偏移。
                clipAnchorMs: anchorV, clipAnchorUncertaintyMs: anchorUncertaintyMs,
                cueStartMs: (typeof q.cueStartV === 'number' ? q.cueStartV : null),
                mineAtMs: (typeof q.mineAtV === 'number' ? q.mineAtV : null),
                documentTitle: q.documentTitle || (typeof netflixDocumentTitle === 'function' ? netflixDocumentTitle() : '') },
              (resp) => {
                try { if (chrome.runtime.lastError) return resolve('retry'); } catch (_) { return resolve('retry'); }
                resolve(fushiClassifyMineResp(resp));
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
      window.fushiToast('生成中… ' + (done + fail) + '/' + items.length, true);
    }
  } finally {
    // V16#3：无论批量循环正常结束还是中途抛错，都必还原隐藏字幕的样式 + 光标，绝不把
    // cursor:none / 藏字幕样式泄漏到用户可见界面（循环外抛异常留可见副作用的根因）。
    try { hideStyle.remove(); } catch (_) {}
    // TODO-1219 P3：录制结束（成功或异常）后重挂面板推挤，播放器回到收窄态、面板重新贴右显示。
    try { if (typeof window.fushiSubtitlePanelResumePush === 'function') window.fushiSubtitlePanelResumePush(); } catch (_) {}
    document.body.style.cursor = prevCursor;
    // TODO-1175/1217：仅当批量前正在播放时才回原位并续播（暂停态制卡不回跳，消除「跳过去又秒挑
    // 回来」的刺眼跳动）；批量前是暂停态则停在当前句、不回跳。
    if (wasPlaying) {
      try { await seekTo(resumeAt); } catch (_) {}
      try { await v.play(); } catch (_) {}
    }
  }
  await fushiRemoveQueued(okIds);
  if (unconfigured > 0 && typeof window.fushiToast === 'function') {
    window.fushiToast('部分未生成：Anki 未配置，请在 Fushi 中配置 Anki 后重试（保留 ' + fail + '）');
  }
}

// TODO-1335 ④：等 video 在当前播放点缓冲就绪（readyState>=HAVE_FUTURE_DATA=3，可从该点顺畅
// 前进）。用于 seek 后、开录前的缓冲门（暂停态调用 → currentTime 不推进 → 不吃头部提前量）。
// maxMs 上界兜底：弱网/受阻迟迟不就绪时也继续（退化到旧行为，绝不无限等卡死批量）。
function fushiWaitForBuffered(v, maxMs) {
  return new Promise((resolve) => {
    if (!v || v.readyState >= 3) { resolve(); return; }
    const deadline = Date.now() + (maxMs || 3000);
    const tick = () => {
      if (!v || v.readyState >= 3 || Date.now() >= deadline) { resolve(); return; }
      setTimeout(tick, 80);
    };
    setTimeout(tick, 80);
  });
}

// TODO-1361 ⑤（BUG-685）：有界等 <video> 元素层 seek 真正落定——currentTime 逼近目标且不再
// seeking。bridge 的 seekDone 只据 Netflix 播放器 API getCurrentTime 判定，MSE 下 <video> 元素可能滞后
// （仍 seeking / 停在旧位）；不等它落定就 pause/play 会停在旧位、录错内容或空录。maxMs 上界兜底：
// 迟迟不落定也继续（退化到旧行为，绝不无限等卡死批量）。
function fushiWaitForSeekSettled(v, targetSec, maxMs) {
  return new Promise((resolve) => {
    if (!v) { resolve(); return; }
    const deadline = Date.now() + (maxMs || 4000);
    const tick = () => {
      if (!v || Date.now() >= deadline) { resolve(); return; }
      // seeking 结束且 currentTime 落在目标 0.5s 内 = <video> 层已真正重定位到本句起点。
      if (!v.seeking && Math.abs(v.currentTime - targetSec) < 0.5) { resolve(); return; }
      setTimeout(tick, 80);
    };
    tick(); // 已落定则同步返回，正常句零额外延迟
  });
}

// TODO-1361 ⑤（BUG-685）：有界等 video 真正在播放并前进（currentTime 相对开录基线单调增长），
// 期间反复补发 play() 抵抗自动播放拦截 / Netflix 播放器状态机暂态回暂停。返回 true=已前进、可录；
// false=到 maxMs 上界仍推不动（真失败，交调用方按失败计、留队重试）。判据用「currentTime 是否前进」
// 而非「v.paused」——v.paused===false 不等于在播（seek 后可能仍 seeking 冻结），这是旧 480ms 单快照
// gate 把本可录的句误跳的根因。
function fushiWaitForPlaying(v, maxMs) {
  return new Promise((resolve) => {
    if (!v) { resolve(false); return; }
    const deadline = Date.now() + (maxMs || 4000);
    const base = v.currentTime; // 开录基线（此刻暂停在 seek 落点）
    const tick = async () => {
      if (!v) { resolve(false); return; }
      if (v.paused) { try { await v.play(); } catch (_) {} }
      if (!v.paused && v.currentTime > base + 0.02) { resolve(true); return; } // 真前进了 → 可录
      if (Date.now() >= deadline) { resolve(false); return; }
      setTimeout(tick, 40);
    };
    tick();
  });
}

// 等 Netflix 播放器就绪（切集后 video 需时间加载）。
async function fushiWaitForPlayer(timeoutMs) {
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
async function fushiMaybeResumeNetflixBatch(fromLoad) {
  if (fushiNfBatchRunning) return;
  fushiNfBatchRunning = true; // 同步置位（任何 await 前）：堵 setTimeout 与 storage 事件的重入 TOCTOU
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  try {
    if (!fushiExtAlive() || fushiSite() !== 'netflix') return;
    let st;
    try { st = (await chrome.storage.local.get(['fushiNfBatch'])).fushiNfBatch; } catch (_) { return; }
    if (!st || !st.active) return;
    if (!st.episodes || !st.episodes.length) { // 旧格式残留 → 清
      try { chrome.runtime.sendMessage({ type: 'nfFinish' }); } catch (_) {}
      return;
    }
    const target = st.episodes[st.idx];
    if (fushiNetflixId() !== target) {
      // 还没到目标集：只有真实页面加载(fromLoad)才驱动导航+计数（storage 变化触发的不导航，免风暴）。
      // 连 4 次真实加载都到不了目标集 → 放弃收尾，绝不无限重载。
      if (!fromLoad) return;
      const attempts = (st.navAttempts || 0) + 1;
      if (attempts > 4) {
        window.fushiToast('✗ 打不开剧集 ' + target + '，结束生成');
        try { chrome.runtime.sendMessage({ type: 'nfFinish', originalUrl: st.originalUrl }); } catch (_) {}
        return;
      }
      try { await chrome.storage.local.set({ fushiNfBatch: { active: true, episodes: st.episodes, idx: st.idx, originalUrl: st.originalUrl, navAttempts: attempts } }); } catch (_) {}
      try { chrome.runtime.sendMessage({ type: 'nfNavigate', url: 'https://www.netflix.com/watch/' + target }); } catch (_) {}
      return;
    }
    // 到了目标集：等播放器就绪 → 稳一下 → 开录（此时才开，避开加载中录屏）→ 回放本集队列项 → 停录。
    window.fushiToast('自动生成：第 ' + (st.idx + 1) + '/' + st.episodes.length + ' 部…', true);
    await fushiWaitForPlayer(20000);
    if (!document.querySelector('video')) {
      try { chrome.runtime.sendMessage({ type: 'nfFinish', originalUrl: st.originalUrl }); } catch (_) {}
      window.fushiToast('✗ 播放器未就绪，结束（Netflix 报错就刷新重试）');
      return;
    }
    await sleep(800); // 给播放器/DRM 授权稳一下再开录
    try { await chrome.runtime.sendMessage({ type: 'nfEnsureCapture' }); } catch (_) {}
    await fushiRunNetflixBatch(); // v34 就地 API-seek 回放本集队列项（内部按当前 netflixId 过滤 + 移除成功）
    try { await chrome.runtime.sendMessage({ type: 'nfStopCapture' }); } catch (_) {} // 跳集前必停录
    const next = st.idx + 1;
    if (next < st.episodes.length) {
      // 前进下一集：新对象不带 navAttempts → 下一集从 0 计数。
      try { await chrome.storage.local.set({ fushiNfBatch: { active: true, episodes: st.episodes, idx: next, originalUrl: st.originalUrl } }); } catch (_) {}
      try { chrome.runtime.sendMessage({ type: 'nfNavigate', url: 'https://www.netflix.com/watch/' + st.episodes[next] }); } catch (_) {}
    } else {
      try { chrome.runtime.sendMessage({ type: 'nfFinish', originalUrl: st.originalUrl }); } catch (_) {}
      // BUG-675（TODO-1361 ②）：录制失败的卡片留在队列（未丢失），但旧实现一律报「✓ 全部完成」
      // 掩盖了被跳过的卡，用户以为都生成了。批量结束时清点本次剧集仍残留的网飞待生成项，>0 就明确
      // 告知「N 张录制失败未生成，可再点生成重试」，把静默跳过变成可见可重试。
      let fushiRemainingNf = 0;
      try {
        const fushiGot = await chrome.storage.local.get(['fushiQueue']);
        const fushiQ = Array.isArray(fushiGot.fushiQueue) ? fushiGot.fushiQueue : [];
        fushiRemainingNf = fushiQ.filter(
            (it) => it && it.site === 'netflix' && st.episodes.indexOf(it.netflixId) >= 0).length;
      } catch (_) {}
      if (fushiRemainingNf > 0) {
        window.fushiToast('✓ 生成完成：' + fushiRemainingNf + ' 张录制失败未生成，可再点生成重试');
      } else {
        window.fushiToast('✓ 全部剧集生成完成');
      }
    }
  } finally {
    // V16 遗留缺口：跳集前停录（第 449 行）在正常路径；若 fushiRunNetflixBatch 抛错
    // 向上传播，该行被跳过 → offscreen 的 MediaStream 不释放、继续录，随后切集导航就
    // 变成「加载中录屏」(M7375) + 流泄漏。故在 finally 里兜底停录（stopTabCapture 幂等，
    // 正常路径已停时重复调用无害）。
    try { await chrome.runtime.sendMessage({ type: 'nfStopCapture' }); } catch (_) {}
    fushiNfBatchRunning = false;
  }
}

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg) return;
  if (msg.type === 'fushiToastMsg' && typeof window.fushiToast === 'function') window.fushiToast(msg.text);
  else if (msg.type === 'fushiRunYoutube' && typeof window.fushiGenerateAll === 'function') window.fushiGenerateAll();
});
// 图标点击设 fushiNfBatch(active) → storage 变化触发就地续跑(本页无重载,fromLoad=false 不导航);
// 切集重载后由 setTimeout(fromLoad=true) 驱动导航到目标集。
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.fushiNfBatch) {
      const nv = changes.fushiNfBatch.newValue;
      if (nv && nv.active) fushiMaybeResumeNetflixBatch(false);
    }
  });
} catch (_) {}
try { setTimeout(function () { fushiMaybeResumeNetflixBatch(true); }, 1500); } catch (_) {}

// ── BUG-674（TODO-1361 ①）+ BUG-702（TODO-1391）：隐藏网飞自己的干扰性播放器 UI ──
// 纯视觉：只注入 CSS 隐藏 Netflix 自己的 seamless「下一集」按钮 + 剧末续播卡 + 剧集开头左上角的
// 年龄分级/成熟度评级 overlay（TODO-1391：制卡录制会把它录进卡片截图/gif），绝不碰 DRM/seek/自动
// 切集计时器（不改变播放行为）。由 options 开关 netflixHideNextEpisode 门控——缺省=隐藏（用户诉求），
// 仅在显式存 false 时才显示；storage.onChanged 实时生效。CSS 规则常驻，Netflix 重建元素也照样命中。
const FUSHI_NF_HIDE_NEXT_ID = 'fushi-nf-hide-next';
function fushiNetflixNextEpisodeSelectors() {
  return [
    '[data-uia="next-episode-seamless-button"]',
    '[data-uia="next-episode-seamless-button-draining"]',
    '[data-uia="watch-video-post-play-back-to-browse"]',
    '.watch-video--evidence-overlay-container',
    '.nfp.PostPlay',
    // TODO-1391 / BUG-702：剧集开头左上角短暂显示的年龄分级/成熟度评级 overlay。
    // 播放器作用域（watch-video--maturity-rating 前缀 + .watch-video 后代），不误伤浏览页评级角标；
    // class*= / data-uia*= 子串匹配兜住 Netflix 的哈希类名变体。
    '[class*="watch-video--maturity-rating"]',
    '.watch-video [data-uia*="maturity"]',
    '.watch-video [class*="maturity-rating"]',
  ];
}
function fushiApplyNetflixNextEpisodeHiding(hide) {
  if (fushiSite() !== 'netflix') return;
  const existing = document.getElementById(FUSHI_NF_HIDE_NEXT_ID);
  if (!hide) { if (existing) { try { existing.remove(); } catch (_) {} } return; }
  if (existing) return;
  const style = document.createElement('style');
  style.id = FUSHI_NF_HIDE_NEXT_ID;
  style.textContent =
      fushiNetflixNextEpisodeSelectors().join(',') + '{display:none!important}';
  try { (document.head || document.documentElement).appendChild(style); } catch (_) {}
}
function fushiReadNextEpisodeHide() {
  try {
    chrome.storage.local.get(['netflixHideNextEpisode'], (r) => {
      fushiApplyNetflixNextEpisodeHiding(!(r && r.netflixHideNextEpisode === false));
    });
  } catch (_) { fushiApplyNetflixNextEpisodeHiding(true); }
}
try {
  fushiReadNextEpisodeHide();
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.netflixHideNextEpisode) {
      fushiApplyNetflixNextEpisodeHiding(changes.netflixHideNextEpisode.newValue !== false);
    }
  });
} catch (_) {}

// ── 隐藏字幕（用户诉求：浏览器侧对齐 app 的 videoToggleSubtitleHide）──
// app 内视频页早有「字幕遮蔽三态（不遮蔽/模糊/隐藏）」，扩展侧此前**只有**作用于自绘覆盖层
// 的防剧透模糊（subtitleOverlayBlur，且悬停即恢复清晰），站点原生字幕从不被遮 → 想「先听后看」
// 的用户在浏览器里无解。这里补上真正的隐藏：站点原生字幕 + 扩展自绘覆盖层一起藏。
//
// 关键约束：**只能用 visibility/opacity，绝不能用 display:none 或删节点**——扩展的取词
// (fushiSubtitleTextNow)、逐句制卡、caret 兜底命中(fushiSubtitleCaretAtPoint) 全靠读这些
// 字幕节点的 textContent / getBoundingClientRect。display:none 会把它们从布局里摘掉，
// 隐藏字幕就等于同时废掉制卡，那是把功能做成 bug。Netflix 批量录制路径 (fushiRunNetflixBatch)
// 用的也是 visibility:hidden，此处与之同策。
//
// 所有权：本模块是 subtitleHidden 的**唯一**持有者（读 storage、注入 style、翻转、toast）。
// subtitle-panel.js 只是把快捷键转发过来——因为面板整体受 netflixSubtitlePanel 门控且默认关，
// 状态若放在面板里，用户没开面板时隐藏字幕就会失效。
const FUSHI_HIDE_SUBS_ID = 'fushi-hide-subs';
let fushiSubtitleHidden = false;

function fushiSubtitleHideSelectors() {
  return [
    '.player-timedtext',             // Netflix
    '.ytp-caption-window-container', // YouTube
    '.captions-text',                // 通用（部分播放器）
    '.libassjs-canvas-parent',       // ASS/SSA 渲染层
    '#fushi-subtitle-overlay',      // 扩展自绘覆盖层
  ];
}

function fushiApplySubtitleHiding(hide) {
  const existing = document.getElementById(FUSHI_HIDE_SUBS_ID);
  if (!hide) { if (existing) { try { existing.remove(); } catch (_) {} } return; }
  if (existing) return;
  const style = document.createElement('style');
  style.id = FUSHI_HIDE_SUBS_ID;
  // ::cue（原生 <track> 字幕）必须单独成一条规则：它只接受受限属性集，且与普通选择器
  // 并列时若被浏览器判为无效会**整条规则**失效，连带把上面的站点字幕也藏不掉。
  style.textContent =
      fushiSubtitleHideSelectors().join(',') + '{visibility:hidden!important}' +
      'video::cue{visibility:hidden!important}';
  try { (document.head || document.documentElement).appendChild(style); } catch (_) {}
}

// 快捷键执行端（subtitle-panel.js 的 fushiSubtitleShortcut 转发过来）。翻转 → 立即生效 →
// 落 storage（options 页的开关与之双向同步）→ toast 反馈。返回 true 表示已接管这次按键。
window.fushiToggleSubtitleHiding = function () {
  fushiSubtitleHidden = !fushiSubtitleHidden;
  fushiApplySubtitleHiding(fushiSubtitleHidden);
  try { chrome.storage.local.set({ subtitleHidden: fushiSubtitleHidden }); } catch (_) {}
  try {
    if (typeof window.fushiToast === 'function') {
      window.fushiToast('隐藏字幕：' + (fushiSubtitleHidden ? '开' : '关'));
    }
  } catch (_) {}
  return true;
};

function fushiReadSubtitleHidden() {
  try {
    chrome.storage.local.get(['subtitleHidden'], (r) => {
      fushiSubtitleHidden = !!(r && r.subtitleHidden === true);
      fushiApplySubtitleHiding(fushiSubtitleHidden);
    });
  } catch (_) {}
}
try {
  fushiReadSubtitleHidden();
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.subtitleHidden) {
      fushiSubtitleHidden = changes.subtitleHidden.newValue === true;
      fushiApplySubtitleHiding(fushiSubtitleHidden);
    }
  });
} catch (_) {}

// 「滑动关闭查词弹窗」——app 的 enableSwipeToClose 偏好经查词响应 theme 的
// --fushi-swipe-close（'1'/'0'）下发；in-app 走 Flutter 手势层 / WebView topPullReleased，
// 扩展的浮动弹窗是纯 DOM，这里在弹窗宿主上装同语义的**水平拖关**手势（设置项文案即「水平
// 滑动关闭查词弹窗」）。默认 Windows/Linux 关（鼠标框选正文与拖手势同形易误触），跟随 app 偏好。
let fushiSwipeCloseEnabled = false;
let fushiSwipeStart = null;
// 水平拖过此像素即关（固定阈值；in-app 的灵敏度滑块暂不移植，待真机再定是否需要）。
const FUSHI_SWIPE_CLOSE_THRESHOLD = 64;

// 在弹窗宿主 [host] 上装水平拖关手势（每个 host 只装一次）。监听始终挂上，是否真正关窗由
// fushiSwipeCloseEnabled 门控（theme 到达后置位）→ 关时纯 no-op，开时水平主导且过阈才关。
// pointer 路径只接 mouse/pen（touch 由 touch 家族处理，避免同一次拖动双触发）；全部 passive。
function fushiInstallSwipeClose(host) {
  if (!host || host.__fushiSwipeHooked) return;
  host.__fushiSwipeHooked = true;
  const start = (x, y) => { fushiSwipeStart = { x: x, y: y }; };
  const move = (x, y) => {
    if (!fushiSwipeCloseEnabled || !fushiSwipeStart) return;
    const dx = x - fushiSwipeStart.x;
    const dy = y - fushiSwipeStart.y;
    // 水平主导（|dx| > 1.5·|dy|，避开竖向滚动/选竖排）且过阈 → 关。
    if (Math.abs(dx) > FUSHI_SWIPE_CLOSE_THRESHOLD &&
        Math.abs(dx) > Math.abs(dy) * 1.5) {
      fushiSwipeStart = null;
      fushiRemoveContainer();
    }
  };
  const end = () => { fushiSwipeStart = null; };
  host.addEventListener('pointerdown', (e) => {
    if (e.pointerType === 'touch') return;
    if (e.button !== undefined && e.button !== 0) return;
    start(e.clientX, e.clientY);
  }, { passive: true });
  host.addEventListener('pointermove', (e) => {
    if (e.pointerType === 'touch') return;
    move(e.clientX, e.clientY);
  }, { passive: true });
  host.addEventListener('pointerup', (e) => {
    if (e.pointerType === 'touch') return;
    end();
  }, { passive: true });
  host.addEventListener('pointercancel', (e) => {
    if (e.pointerType === 'touch') return;
    end();
  }, { passive: true });
  host.addEventListener('touchstart', (e) => {
    if (!e.touches || e.touches.length !== 1) return;
    start(e.touches[0].clientX, e.touches[0].clientY);
  }, { passive: true });
  host.addEventListener('touchmove', (e) => {
    if (!e.touches || e.touches.length !== 1) return;
    move(e.touches[0].clientX, e.touches[0].clientY);
  }, { passive: true });
  host.addEventListener('touchend', end, { passive: true });
}

function fushiEnsureContainer() {
  // BUG-530：全屏时（Netflix 看片常全屏）挂在 document.body 上的弹窗会被全屏元素盖住看不见
  // （浏览器全屏只渲染 fullscreenElement 及其后代）→ shift 划词其实触发了但弹窗不可见=「没反应」。
  // 故挂到当前 fullscreenElement（无则 body），并用 position:fixed + 视口坐标，全屏/普通页都对。
  // BUG-530：全屏时挂到 fullscreenElement（无则 body），position:fixed 全屏/普通页都可见。
  const parent = document.fullscreenElement || document.body;
  if (fushiHost && fushiHost.parentNode === parent && fushiContainer) {
    return fushiContainer;
  }
  if (!fushiHost) {
    // BUG-688：shadow 宿主元素只负责 fixed 定位 + 层级；弹窗内容全在其 shadow root 内，
    // 宿主页 CSS 无法穿透 → 与 in-app 弹窗渲染一致（不再被宿主站点 line-height/ruby 等污染）。
    fushiHost = document.createElement('div');
    fushiHost.id = 'hibiki-popup-host';
    // BUG-688：尺寸盒 + zoom 落在 host（视口坐标系，确定宽度），弹窗内容尺寸不再受
    // 「CSS zoom × 100vw × shadow shrink-to-fit」相互作用干扰。host 宽/高/zoom 由 fushiRender
    // 按查词响应下发的 --fushi-popup-* 设置；#entries-container 在 shadow 内中和为 width:100%。
    fushiHost.style.cssText =
        'position:fixed;top:0;left:0;z-index:2147483647;overflow-x:hidden;overflow-y:auto;';
    fushiInstallSwipeClose(fushiHost); // 水平拖关手势（是否生效由 fushiSwipeCloseEnabled 门控）
    const shadow = fushiHost.attachShadow({ mode: 'open' });
    // 中和 content.css 里 #entries-container 自带的尺寸盒/zoom（那套是给「容器自身即 fixed 元素」
    // 的旧模型用的）；现在 host 才是尺寸/缩放/定位主体，容器只做 100% 透传。
    const norm = document.createElement('style');
    norm.textContent =
        '#entries-container{width:100%!important;max-width:none!important;' +
        'max-height:none!important;overflow:visible!important;zoom:1!important;}';
    shadow.appendChild(norm);
    // 把弹窗样式注入 shadow：content.css 作为扩展资源经 <link> 加载（web_accessible_resources）。
    // 其中宿主页级选择器（高亮层等）在 shadow 内无对应元素、天然失效；
    // 弹窗选择器（#entries-container/.glossary-group/ruby…）在 shadow 内生效。
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = chrome.runtime.getURL('vendor/content.css');
    shadow.appendChild(link);
    const c = document.createElement('div');
    c.id = 'entries-container';
    // 主题落在弹窗根 #entries-container 上（content.css 作用域 #entries-container[data-theme]）；
    // --md-* / --fushi-popup-* 由 fushiRender 直接 setProperty 到该元素，shadow 内可读。
    c.setAttribute('data-theme', fushiResolveTheme());
    shadow.appendChild(c);
    fushiContainer = c;
    window.__fushiRoot = shadow; // popup.js 的 DOM 查询/浮层/选区都相对它解析
    // BUG-1078：弹窗滚轮监听懒装——popup.js 在扩展上下文里不再常驻 document（常驻的
    // 非 passive wheel 监听会让浏览器在所有网页放弃合成器快速滚动路径），而是把监听
    // 暴露为 window.__fushiPopupWheelListener，由这里在弹窗 host 创建时挂到 shadow
    // host 上（非 passive 只影响弹窗内滚轮），fushiRemoveContainer 销毁时卸载。
    if (typeof window.__fushiPopupWheelListener === 'function') {
      fushiHost.addEventListener('wheel', window.__fushiPopupWheelListener,
          { passive: false });
    }
  }
  if (fushiHost.parentNode !== parent) parent.appendChild(fushiHost); // 进/出全屏迁父节点
  return fushiContainer;
}

// TODO-1272：被查词高亮的覆盖层（扩展自绘、不改宿主页 DOM）。null=未画。
let fushiHighlightLayer = null;

// 撤掉覆盖层高亮。弹窗关闭 / 切到新词重画前调用。宿主页事件碰不到它，只有这里主动撤。
function fushiClearHighlightOverlay() {
  if (fushiHighlightLayer) {
    try { fushiHighlightLayer.remove(); } catch (_) { /* 已脱离文档 */ }
    fushiHighlightLayer = null;
  }
}

// TODO-1279：清掉浏览器原生文本选区（window.getSelection 的蓝色高亮）。只动原生 DOM Selection，
// 不碰我们自绘的 #fushi-highlight-overlay 覆盖层（独立 <div>，与原生选区无关），也不碰
// fushiSelection.selection（纯 JS 取词状态，覆盖层就从它的 ranges 只读取几何）。塌缩/空选区时
// no-op：避免无谓清掉输入框 caret 或没有可见蓝色时反复调用。
function fushiClearNativeSelection() {
  try {
    const sel = window.getSelection && window.getSelection();
    if (sel && sel.rangeCount > 0 && !sel.isCollapsed) sel.removeAllRanges();
  } catch (_) { /* 某些跨域/detached 上下文 getSelection 可能抛：静默 */ }
}

// 从 fushiSelection.selection.ranges 取前 charCount 个「码点」的视口系 client rects（只读
// Range.getClientRects，**不改宿主页 DOM**），并算出整体 bbox 作弹窗锚点。返回 {rects, bounds}。
// 与 selection.js highlightSelection 的裁词逻辑同构，但不做 DOM 包裹。
function fushiSelectionRects(charCount) {
  const rects = [];
  let bx = null;
  const sel = window.fushiSelection && window.fushiSelection.selection;
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
// 框架重渲染 / MutationObserver / 鼠标移动都动不了它，保持到 fushiClearHighlightOverlay。
function fushiDrawHighlightOverlay(rects) {
  fushiClearHighlightOverlay();
  if (!rects || !rects.length) return;
  const parent = document.fullscreenElement || document.body;
  if (!parent) return;
  const layer = document.createElement('div');
  layer.id = 'fushi-highlight-overlay';
  // 穿透点击、不进宿主页布局；z-index 比弹窗(2147483647)低 1 → 永远在宿主页之上、弹窗之下。
  layer.style.cssText =
    'position:fixed;left:0;top:0;width:0;height:0;margin:0;padding:0;border:0;' +
    'z-index:2147483646;pointer-events:none;';
  // 高亮色跟随弹窗主题（--fushi-primary-highlight 落在 #entries-container 上）；取不到用 content.css 同款兜底。
  let color = 'rgba(160, 160, 160, 0.4)';
  try {
    if (fushiContainer) {
      const v = getComputedStyle(fushiContainer).getPropertyValue('--fushi-primary-highlight').trim();
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
  fushiHighlightLayer = layer;
}

function fushiRemoveContainer() {
  // BUG-688：移除 shadow 宿主即连带整个 shadow root（弹窗内容）；清 __fushiRoot 让 popup.js
  // 的 helper 回落到 document（下次开窗 fushiEnsureContainer 会重建）。host 引用即刻置空，
  // 让并发 re-lookup 重建新 host；旧节点与高亮/选区都立即撤掉。
  const dying = fushiHost;
  // popup.js 的尾部词条按宏任务逐条补建；关窗推进 generation，旧批次下一跳立即取消，
  // 避免在已脱离 DOM 的 ShadowRoot 上继续消耗主线程。
  if (Number.isInteger(window._renderGeneration)) window._renderGeneration += 1;
  window._renderInProgress = false;
  fushiLookupPerfContext = null;
  fushiBindPopupPerfContext(null);
  fushiHost = null;
  fushiContainer = null;
  window.__fushiRoot = null;
  // TODO-1272：关窗即撤覆盖层高亮（被查词高亮跟随弹窗生命周期，弹窗在则在、弹窗关则撤）。
  fushiClearHighlightOverlay();
  // 「查词时暂停」的恢复侧：关窗即恢复（实现与不变式见 fushiResumePausedForLookup）。
  // 嵌套查词只换弹窗内容、不经此处，天然不会提前恢复——与 app「整栈关空才恢复」同语义。
  fushiResumePausedForLookup();
  // TODO-1150（yomitan 式）：关窗即撤 selection 状态与任何 DOM 包裹高亮（嵌套查词用）。fushiSelection 未加载/无选区时是 no-op。
  try {
    if (window.fushiSelection && typeof window.fushiSelection.clearSelection === 'function') {
      window.fushiSelection.clearSelection();
    }
  } catch (_) { /* no-op */ }
  // Yomitan 式直接撤掉旧 host：不保留 200ms 淡出节点，也不让下一次查词与旧过渡
  // 重叠。高亮/选区已在上面同步清理。
  if (dying) {
    // BUG-1078：随弹窗卸载滚轮监听（挂载见 fushiEnsureContainer）。这里显式卸载
    // 把契约钉死：弹窗不在场 ⇒
    // 页面上不存在任何非 passive wheel 监听。
    if (typeof window.__fushiPopupWheelListener === 'function') {
      dying.removeEventListener('wheel', window.__fushiPopupWheelListener);
    }
    try { dying.remove(); } catch (_) { /* 已脱离文档 */ }
  }
  // Phase D：关窗即撤拖拽把手 + 清尺寸拖拽状态（把手随弹窗生命周期，下次开窗 place() 重建）。
  if (fushiResizeGrip) {
    try { fushiResizeGrip.remove(); } catch (_) { /* 已脱离文档 */ }
    fushiResizeGrip = null;
  }
  fushiResizeDrag = null;
  fushiResizeBox = null;
}

// 流媒体字幕的取词兜底：Netflix 等在字幕**上面**盖了视频覆盖层（如 .watch-video--flag-container），
// 会把 caretRangeFromPoint 截走 → fushiSelection.getCharacterAtPoint 命中空覆盖层而非字幕文字。这里
// 绕开命中测试：找到包含光标的字幕容器，遍历其文本节点、逐字符用 Range.getBoundingClientRect 找出
// 光标 (x,y) 落在哪个字上，返回该字所在的 Range（供 fushiSelection.selectFromPosition 展开成词）。
// 只在 getCharacterAtPoint 失败时兜底。
const FUSHI_SUBTITLE_SELECTORS = [
  '.player-timedtext-text-container', // Netflix
  '.player-timedtext',
  '[class*="timedtext"]',
  '.libassjs-canvas-parent', // 某些播放器
  '[class*="subtitle"] [lang]',
];

function fushiSubtitleCaretAtPoint(x, y) {
  let container = null;
  for (const sel of FUSHI_SUBTITLE_SELECTORS) {
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
  if (fushiNfBatchRunning) return; // 批量回放录制中：不查词、不自动暂停，免误触把当前句录制截断
  if (!e[FUSHI_MOD]) { fushiLastTerm = ''; return; } // 松开 Shift 复位，下次可重查同词
  // TODO-1279：Shift 悬停取词是「纯悬停扫描」——浏览器会在 Shift 按住+指针移动时把原生文本选区从
  // 既有 caret 扩到指针，与我们自绘的覆盖层高亮叠出一条多余的蓝色原生选区（用户报「一个我们的选区、
  // 一个浏览器自带的蓝色选区」）。纯悬停（无鼠标键按下，e.buttons===0）时清掉原生选区，只留覆盖层
  // 高亮；用户手动按住键拖拽划选复制（e.buttons!==0）不清，保住其复制能力。
  if (e.buttons === 0) fushiClearNativeSelection();
  // 位移阈值：几乎没动就跳过（同一像素反复 mousemove 不重复取词）。
  if (Math.abs(e.clientX - fushiLastX) < 4 && Math.abs(e.clientY - fushiLastY) < 4) return;
  fushiLastX = e.clientX;
  fushiLastY = e.clientY;
  // 在途闸：上一次查词还没回来就不发新请求（防洪）。BUG-1024：带截止时间——超时视为
  // 上一次已废弃（回调被杀死的 worker 吞掉），放行本次，避免永久卡死。
  if (fushiPending && Date.now() - fushiPendingSince < FUSHI_PENDING_TIMEOUT_MS) return;
  // 取词：复用 Flutter app 同款 window.fushiSelection（vendor/selection.js，manifest 里先于本脚本加载）——
  // 统一处理 furigana/ruby、词边界、跨文本节点扩词，取词一致性与阅读器/视频查词同源（TODO-1150）。
  if (!window.fushiSelection || typeof window.fushiSelection.getCharacterAtPoint !== 'function') return;
  let hit = window.fushiSelection.getCharacterAtPoint(e.clientX, e.clientY);
  // getCharacterAtPoint 命中失败（多为流媒体字幕上盖了视频覆盖层截走了 caret）→ 字幕逐字兜底绕开覆盖层。
  if (!hit) {
    const subRange = fushiSubtitleCaretAtPoint(e.clientX, e.clientY);
    if (subRange && subRange.startContainer.nodeType === Node.TEXT_NODE) {
      hit = { node: subRange.startContainer, offset: subRange.startOffset };
    }
  }
  // 诊断：记录本次 shift 划词命中了什么（页面 Console 读 document.documentElement.dataset）。
  try {
    const d = document.documentElement.dataset;
    d.fushiMove = e.clientX + ',' + e.clientY;
    d.fushiCaret = hit
      ? String(hit.node.textContent || '').slice(hit.offset, hit.offset + 12)
      : 'null';
  } catch (_) {}
  if (!hit) return;
  // selectFromPosition 向左扩到词首、向右扫最多 MAX_LEN 字（跨节点收 ranges）并存进 fushiSelection.selection，
  // 供随后 highlightSelection 高亮 + 取 bbox；内部 fire 的 textSelected 在扩展里经 bridge-shim 是 no-op（无副作用）。
  const term = window.fushiSelection.selectFromPosition(hit.node, hit.offset, FUSHI_MAX_LEN, e.clientX, e.clientY);
  // TODO-1218②：立刻快照被查词的锚点几何（selection.js getSelectionRect）。不能等响应回来才量——
  // 那时并发的 selectText 可能已清掉 fushiSelection.selection → highlightSelection 返回 null → 锚点
  // 退回鼠标坐标（弹窗比词底高半行）。随响应传给 fushiRender 作回退锚点。
  let fushiAnchorRect = null;
  try {
    if (window.fushiSelection && typeof window.fushiSelection.getSelectionRect === 'function') {
      fushiAnchorRect = window.fushiSelection.getSelectionRect(e.clientX, e.clientY);
    }
  } catch (_) { fushiAnchorRect = null; }
  try { document.documentElement.dataset.fushiTerm = term || ''; } catch (_) {}
  if (!term || !term.trim()) return;
  if (term === fushiLastTerm) return; // 同词去重：还在同一个词上就不重复查/重渲染
  fushiLastTerm = term;
  fushiSendLookup(term, fushiAnchorRect);
});

let fushiLastConnectionHintAt = 0;
function fushiShowConnectionFailure(resp) {
  const now = Date.now();
  if (now - fushiLastConnectionHintAt < 8000) return; // hover 连发时只提醒一次，避免刷屏
  fushiLastConnectionHintAt = now;
  const c = resp && resp.connection;
  let message = 'Fushi API 未开启：请在 Fushi 设置 → 查词中开启 Yomitan API 服务器';
  if (c && c.state === 'yomitan-conflict') {
    message = '端口 ' + (c.port || 19633) + ' 被 Yomitan API 占用：请在 Yomitan 高级设置关闭 Enable Yomitan API，再开启 Fushi 的 Yomitan API 服务器';
  } else if (c && c.state === 'unauthorized') {
    message = 'Fushi API 密钥不匹配：请打开扩展设置并恢复自动配置';
  } else if (c && c.state === 'wrong-service') {
    message = '扩展端口连接到了其他服务：请打开扩展设置检查连接';
  }
  // unauthorized / wrong-service 两态的解法就在扩展设置页（核对 token / 恢复自动配置），
  // 故把 toast 做成可点直达；其余两态（app 侧没开 API、Yomitan 抢端口）要去 Fushi app 或
  // Yomitan 里改，开扩展设置页帮不上忙，保持不可点。
  const settingsFixable =
      !!c && (c.state === 'unauthorized' || c.state === 'wrong-service');
  try { window.fushiToast('⚠ ' + message, false, settingsFixable); } catch (_) {}
}

// 发查词请求 + 渲染弹窗的共享收尾（Shift 悬停、面板行点击、悬浮字幕自动查词同源）。
// 用户开启「查词时暂停」后，仅在确实发起了非空查词请求时暂停正在播放的视频，并记下
// fushiPausedForLookup；关闭查词弹窗时自动恢复（fushiRemoveContainer）。关闭该设置时
// 任何站点都不因查词被暂停。
function fushiSendLookup(term, anchorRect, cueWindow) {
  // TODO-1219 P3：每次查词刷新精确窗——面板行查词传 cueWindow（该行精确 [startMs,endMs]），
  // mousemove 划词不传则清空，使后续制卡回落 DOM 采样窗（live 视频 hover 取当前句）。
  fushiPendingCueWindow = cueWindow || null;
  if (!term || !term.trim()) return;
  if (!fushiExtAlive()) return; // 扩展已重载/失效：静默停手（重载页面恢复）
  // 已因查词暂停且视频仍停着：重复查词不必再扫（fushiFindPlayingVideo 也不会命中）。
  if (fushiPauseOnLookup && !(fushiPausedForLookup && fushiPausedForLookup.paused)) {
    try { const _v = fushiFindPlayingVideo(); if (_v) { _v.pause(); fushiMarkPausedForLookup(_v); } } catch (_) {}
  }
  fushiPending = true;
  fushiPendingSince = Date.now(); // BUG-1024：记发起时刻，供在途闸超时兜底
  // SW 在消息在途时被回收（BUG-1024）：回调永不触发，下面的失败恢复路径也到不了。兜底：
  // 12s 后仍是同一笔在途且没有弹窗在场，就恢复被查词暂停的视频（正常有响应时无操作）。
  const fushiLookupIssuedAt = fushiPendingSince;
  try {
    setTimeout(() => {
      if (fushiPending && fushiPendingSince === fushiLookupIssuedAt && !fushiHost) {
        fushiResumePausedForLookup();
      }
    }, 12000);
  } catch (_) {}
  const clientStartedAt = performance.now();
  const clientSentEpochMs = performance.timeOrigin + clientStartedAt;
  try {
    chrome.runtime.sendMessage({ type: 'lookup', term, clientSentEpochMs }, (resp) => {
      fushiPending = false;
      const responseAt = performance.now();
      const responseEpochMs = performance.timeOrigin + responseAt;
      // 回调期间上下文可能已失效：安全读 lastError（读它本身可能抛），有错就静默丢弃。
      try {
        if (chrome.runtime.lastError) return;
      } catch (_) {
        return;
      }
      if (!resp || !resp.ok) {
        const failedPerf = resp && resp.lookupPerf || {};
        fushiReportLookupPerf({
          id: failedPerf.id || 'page-error-' + Date.now().toString(36) + '-' + (++fushiLookupPerfSequence).toString(36),
          surface: 'page-popup',
          stage: 'client-error',
          term,
          maximumTerms: failedPerf.maximumTerms || 10,
          messageRoundTripMs: Number((responseAt - clientStartedAt).toFixed(1)),
          ...(typeof failedPerf.responseReadyEpochMs === 'number' ? {
            deliveryAfterReadyMs: Number(
              Math.max(0, responseEpochMs - failedPerf.responseReadyEpochMs).toFixed(1)),
          } : {}),
          error: String(resp && resp.error || 'empty lookup response'),
        });
        fushiShowConnectionFailure(resp);
        // 失败且没有在场弹窗：不会有任何「关窗」动作可触发恢复——直接恢复被查词暂停的
        // 视频，否则服务未启动时 Shift 划词=视频被停住+只剩一条 toast、暂停无出口。
        if (!fushiHost) fushiResumePausedForLookup();
        return;
      }
      if (!resp.data || typeof resp.data.popupJson !== 'string') {
        fushiReportLookupPerf({
          id: resp.lookupPerf && resp.lookupPerf.id || 'page-empty-' + Date.now().toString(36),
          surface: 'page-popup',
          stage: 'client-error',
          term,
          error: 'missing popupJson',
        });
        if (!fushiHost) fushiResumePausedForLookup();
        return;
      }
      const servicePerf = resp.lookupPerf || {};
      fushiLookupPerfContext = {
        id: servicePerf.id || 'page-' + Date.now().toString(36) + '-' + (++fushiLookupPerfSequence).toString(36),
        term,
        maximumTerms: servicePerf.maximumTerms || 10,
        clientStartedAt,
        visibleReported: false,
        visibleReportScheduled: false,
      };
      fushiReportLookupPerf({
        id: fushiLookupPerfContext.id,
        surface: 'page-popup',
        stage: 'client-response',
        term,
        maximumTerms: fushiLookupPerfContext.maximumTerms,
        messageRoundTripMs: Number((responseAt - clientStartedAt).toFixed(1)),
        ...(typeof servicePerf.responseReadyEpochMs === 'number' ? {
          deliveryAfterReadyMs: Number(
            Math.max(0, responseEpochMs - servicePerf.responseReadyEpochMs).toFixed(1)),
        } : {}),
        responseChars: servicePerf.responseChars || resp.data.popupJson.length,
      });
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
      window.needsAudio = true;
      fushiRender(resp.data.popupJson, termLen, resp.data.theme, anchorRect);
    });
  } catch (_) {
    fushiPending = false; // 「Extension context invalidated」：静默，等用户重载页面
    if (!fushiHost) fushiResumePausedForLookup(); // 暂停不能没有出口
  }
}

// TODO-1219 P2：面板行内文本「显式点击查词」的入口（供 subtitle-panel.js 调用）。点击命中的
// (clientX,clientY) 复用与 mousemove 划词同一套 fushiSelection 取词（含流媒体字幕覆盖层兜底），
// 选中后走 fushiSendLookup 发查词 + 渲染弹窗，取词/高亮/锚点与全局划词完全一致。
window.fushiLookupAtPoint = function (clientX, clientY, cueWindow, options) {
  if (!window.fushiSelection || typeof window.fushiSelection.getCharacterAtPoint !== 'function') return;
  let hit = window.fushiSelection.getCharacterAtPoint(clientX, clientY);
  if (!hit) {
    const subRange = fushiSubtitleCaretAtPoint(clientX, clientY);
    if (subRange && subRange.startContainer.nodeType === Node.TEXT_NODE) {
      hit = { node: subRange.startContainer, offset: subRange.startOffset };
    }
  }
  if (!hit) return;
  const term = window.fushiSelection.selectFromPosition(hit.node, hit.offset, FUSHI_MAX_LEN, clientX, clientY);
  fushiClearNativeSelection(); // TODO-1279：显式点击查词同样清掉浏览器原生蓝色选区，只留覆盖层高亮
  let anchorRect = null;
  try {
    if (window.fushiSelection && typeof window.fushiSelection.getSelectionRect === 'function') {
      anchorRect = window.fushiSelection.getSelectionRect(clientX, clientY);
    }
  } catch (_) { anchorRect = null; }
  const autoLookup = !!(options && options.auto === true);
  if (autoLookup && fushiPending &&
      Date.now() - fushiPendingSince < FUSHI_PENDING_TIMEOUT_MS) return;
  if (autoLookup) {
    const cueKey = cueWindow
      ? String(cueWindow.startMs) + ':' + String(cueWindow.endMs) + ':' + String(cueWindow.text || '')
      : '';
    const lookupKey = String(term || '') + '\0' + cueKey;
    if (lookupKey === fushiLastAutoLookupKey) return;
    fushiLastAutoLookupKey = lookupKey;
  }
  fushiLastTerm = term || ''; // 与 mousemove 去重状态对齐，避免点后立刻 hover 同词重查
  fushiSendLookup(term, anchorRect, cueWindow); // TODO-1219 P3：面板行传入精确窗
};
// 原生 Side Panel 自己请求并渲染词典，视频页只保留精确 cue 窗（制卡媒体）以及可选的
// “查词时暂停”。这里不创建弹窗、不读/写宿主 Selection，也不修改任何宿主文本节点。
window.fushiPrepareLookupFromSidePanel = function (cueWindow) {
  fushiPendingCueWindow = cueWindow && typeof cueWindow === 'object' ? cueWindow : null;
  if (fushiPauseOnLookup) {
    // Side Panel 自渲染词典、没有「面板关闭」回调到 content script，故此路径只暂停、
    // 不记 fushiPausedForLookup（否则会被后续无关的页面弹窗关闭误恢复）；恢复由用户手动。
    try { const video = fushiFindPlayingVideo(); if (video) video.pause(); } catch (_) {}
  }
  return true;
};
window.fushiMineFromSidePanel = function (fields, cueWindow) {
  fushiPendingCueWindow = cueWindow && typeof cueWindow === 'object' ? cueWindow : null;
  const sentence = fushiPendingCueWindow ? String(fushiPendingCueWindow.text || '') : '';
  return typeof window.fushiEnqueue === 'function'
    ? window.fushiEnqueue(fields || {}, sentence)
    : { ok: false, reason: 'no-queue' };
};
window.fushiResetAutoLookupDedupe = function () {
  fushiLastAutoLookupKey = '';
};

// TODO-1185：嵌套查词——点释义里的词（词典交叉引用 a[href]）。popup.js 的 a.onclick →
// callHandler('onLinkClick', query) → bridge-shim → 这里。用该词**重发一次 lookup**，在同一
// #entries-container 重渲染（yomitan 式单弹窗内导航），对齐 app 的「点释义里的词继续查」。
// BUG-1279：走 fushiRenderNested（只换内容），不再走 fushiRender 的完整首查词路径——弹窗
// 的位置、尺寸、原文高亮与可见状态全部原样保持。子词的匹配长度（result.bestLength）在这里
// 没有任何用处：它是「原文里命中了几个字」的量，而嵌套查的词根本不在原文里，拿它去截原文
// 选区正是修复前把原文高亮和弹窗落点一起算错的原因。
window.__fushiOnLinkClick = function (query) {
  const term = (query || '').trim();
  if (!term) return;
  if (!fushiExtAlive()) return;
  const clientStartedAt = performance.now();
  const clientSentEpochMs = performance.timeOrigin + clientStartedAt;
  try {
    chrome.runtime.sendMessage({ type: 'lookup', term, clientSentEpochMs }, (resp) => {
      const responseAt = performance.now();
      const responseEpochMs = performance.timeOrigin + responseAt;
      try { if (chrome.runtime.lastError) return; } catch (_) { return; }
      if (!resp || !resp.ok) {
        const failedPerf = resp && resp.lookupPerf || {};
        fushiReportLookupPerf({
          id: failedPerf.id || 'nested-error-' + Date.now().toString(36) + '-' + (++fushiLookupPerfSequence).toString(36),
          surface: 'page-popup',
          stage: 'client-error',
          term,
          maximumTerms: failedPerf.maximumTerms || 10,
          nested: true,
          messageRoundTripMs: Number((responseAt - clientStartedAt).toFixed(1)),
          ...(typeof failedPerf.responseReadyEpochMs === 'number' ? {
            deliveryAfterReadyMs: Number(
              Math.max(0, responseEpochMs - failedPerf.responseReadyEpochMs).toFixed(1)),
          } : {}),
          error: String(resp && resp.error || 'empty lookup response'),
        });
        fushiShowConnectionFailure(resp);
        return;
      }
      if (!resp.data || typeof resp.data.popupJson !== 'string') {
        fushiReportLookupPerf({
          id: resp.lookupPerf && resp.lookupPerf.id || 'nested-empty-' + Date.now().toString(36),
          surface: 'page-popup',
          stage: 'client-error',
          term,
          nested: true,
          error: 'missing popupJson',
        });
        return;
      }
      const servicePerf = resp.lookupPerf || {};
      fushiLookupPerfContext = {
        id: servicePerf.id || 'nested-' + Date.now().toString(36) + '-' + (++fushiLookupPerfSequence).toString(36),
        term,
        maximumTerms: servicePerf.maximumTerms || 10,
        clientStartedAt,
        visibleReported: false,
        visibleReportScheduled: false,
      };
      fushiReportLookupPerf({
        id: fushiLookupPerfContext.id,
        surface: 'page-popup',
        stage: 'client-response',
        term,
        maximumTerms: fushiLookupPerfContext.maximumTerms,
        nested: true,
        messageRoundTripMs: Number((responseAt - clientStartedAt).toFixed(1)),
        ...(typeof servicePerf.responseReadyEpochMs === 'number' ? {
          deliveryAfterReadyMs: Number(
            Math.max(0, responseEpochMs - servicePerf.responseReadyEpochMs).toFixed(1)),
        } : {}),
        responseChars: servicePerf.responseChars || resp.data.popupJson.length,
      });
      window.audioSources = Array.isArray(resp.data.audioSources) ? resp.data.audioSources : [];
      window.needsAudio = true;
      // 同词去重状态跟着**弹窗当前显示的词**走：弹窗里已经是子词了，鼠标再回到原文那个父词
      // 上就是一次真正的换词，必须能重查。不更新的话 fushiLastTerm 还停在父词，mousemove
      // 的同词去重会把它当「还在同一个词上」直接 return，用户从嵌套查词回不到原词。
      fushiLastTerm = term;
      fushiRenderNested(resp.data.popupJson, resp.data.theme);
    });
  } catch (_) { /* 扩展上下文失效：静默 */ }
};

// BUG-767：计算查词弹窗落点，保证**永不覆盖被查词**。纯函数（不碰 DOM），便于单测。
// anchor：被查词的视口矩形 {x, y, height}（x/y=左上角，height=词高，均视口坐标系）。
// size：弹窗自然尺寸 {width, height}（已按主题 max-height 夹住的可见尺寸）。
// viewport：{width, height}。返回 {left, top, maxHeight}；maxHeight!=null 表示上下两侧
// 都放不下整只弹窗，需把弹窗高度夹到所选一侧的可用空间（内部滚动），故渲染后不会压到词上。
// 旧实现只把 top 夹到边距 8，弹窗高时（词典结果多）会从 8 往下铺开盖住上半屏的词——本函数修掉。
function fushiComputePlacement(anchor, size, viewport) {
  const M = 8; // 视口边距
  const G = 4; // 词与弹窗之间的间隙
  const vw = viewport.width;
  const vh = viewport.height;
  const ax = anchor.x;
  const ay = anchor.y;
  const ah = anchor.height || 0;
  const pw = size.width;
  const ph = size.height;
  // 横向：左对齐词左缘，右/左溢出各自贴边（原行为，未变）。
  let left = ax;
  if (left + pw > vw - M) left = Math.max(M, vw - pw - M);
  if (left < M) left = M;
  // 纵向：词下方 / 上方各自的可用高度（含留出的视口边距）。
  const belowSpace = vh - (ay + ah) - M; // 词底 → 视口底
  const aboveSpace = ay - M;             // 视口顶 → 词顶
  let top;
  let maxHeight = null;
  if (ph + G <= belowSpace) {
    top = ay + ah + G;                   // 下方放得下整只弹窗：落词下方
  } else if (ph + G <= aboveSpace) {
    top = ay - G - ph;                   // 上方放得下整只弹窗：落词上方
  } else if (belowSpace >= aboveSpace) {
    top = ay + ah + G;                   // 两侧都放不下、下方空间更大：贴词下方并夹高度
    maxHeight = Math.max(64, belowSpace - G);
  } else {
    maxHeight = Math.max(64, aboveSpace - G); // 上方空间更大：夹高度使弹窗底恰落词顶之上
    top = Math.max(M, ay - G - maxHeight);
  }
  return { left, top, maxHeight };
}

// 弹窗尺寸精细化 Phase D：拖拽右下角把手把「起始基准最大宽高 + 本次累计位移」折算成新的基准
// （未缩放）最大宽高并 clamp。纯函数（不碰 DOM），便于单测。
// start：拖拽开始时的基准 {width, height}（= host.style.width / 渲染高÷zoom，未乘 zoom）。
// delta：指针在视口(**已缩放**)坐标系里的累计位移 {dx, dy}；除以 zoom 折回基准尺度
//   （与 place() 里 `pos.left / zoom` 折算同源——host 带 zoom，视口位移 = 基准位移 × zoom）。
// bounds：{minW, minH, maxW, maxH}（基准尺度上下限；maxW/maxH 由视口可用空间÷zoom 得来，已内含
//   BUG-767「不遮词」约束）。zoom<=0 按 1 兜底（不除零）。clamp 上界恒 >= 下界（视口过小也不倒挂）。
function fushiComputeResizedSize(start, delta, zoom, bounds) {
  const z = zoom > 0 ? zoom : 1;
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), Math.max(lo, hi));
  const width = clamp(start.width + delta.dx / z, bounds.minW, bounds.maxW);
  const height = clamp(start.height + delta.dy / z, bounds.minH, bounds.maxH);
  return { width: width, height: height };
}

// 基准最大宽/高的允许范围（逻辑像素）。与 app 设置页两滑杆 + Dart 侧
// effective_lookup_size.dart 的 kLookupPopupMin/MaxWidth/Height 单一同源——拖拽与滑杆写同一
// 真值，故边界必须一致，否则拖拽能写出滑杆写不出的越界值（app 侧仍会再 clamp 一次兜底）。
const FUSHI_POPUP_MIN_WIDTH = 250;
const FUSHI_POPUP_MIN_HEIGHT = 200;
const FUSHI_RESIZE_GRIP_SIZE = 18;

// 把拖拽把手移到弹窗当前渲染矩形的右下角（视口坐标；host 是 fixed，坐标即视口系）。
function fushiPositionResizeGrip() {
  if (!fushiResizeGrip || !fushiHost) return;
  const r = fushiHost.getBoundingClientRect();
  const s = FUSHI_RESIZE_GRIP_SIZE;
  fushiResizeGrip.style.left = (r.right - s) + 'px';
  fushiResizeGrip.style.top = (r.bottom - s) + 'px';
}

// Phase D：把拖出来的最终基准最大宽高经 background → app（POST /api/extension/popup-size）。
// app 侧 clamp(250-2000/200-1600) + 「拖即解锁」extensionPopupIndependentSize=true + 写扩展键，
// 下一次查词 browserExtensionThemeColors 读新 extensionPopupEffectiveSize 即以新尺寸下发（闭环）。
function fushiSendPopupSize(maxWidth, maxHeight) {
  try {
    chrome.runtime.sendMessage(
      { type: 'popupSize', maxWidth: Math.round(maxWidth), maxHeight: Math.round(maxHeight) },
      () => { void chrome.runtime.lastError; });
  } catch (_) { /* 扩展上下文失效：静默（尺寸只是没落库，不崩查词） */ }
}

// 在把手上装拖拽逻辑（每个 grip 只装一次）。pointerdown 快照起始基准 + 视口可用空间夹取上界，
// pointermove 经纯函数 fushiComputeResizedSize 实时改 host 的 width/maxHeight（place() 只在查词当
// 帧跑一次、无 rAF 循环，故手动尺寸不会被每帧覆盖回去），pointerup 落库并经 bridge 回写 app。
function fushiInstallResizeDrag(grip) {
  if (!grip || grip.__fushiResizeHooked) return;
  grip.__fushiResizeHooked = true;
  const down = (x, y) => {
    if (!fushiHost || !fushiResizeBox) return;
    const box = fushiResizeBox;
    const z = box.zoom > 0 ? box.zoom : 1;
    const baseW = parseFloat(fushiHost.style.width) || 0;
    // 当前基准高度：host 渲染高÷zoom（style.maxHeight 可能是 min()/px/未设 → 用真实 rect 最稳）。
    const baseH = fushiHost.getBoundingClientRect().height / z;
    fushiResizeDrag = {
      startX: x, startY: y, baseW: baseW, baseH: baseH, zoom: z,
      moved: false,
      bounds: {
        minW: FUSHI_POPUP_MIN_WIDTH, minH: FUSHI_POPUP_MIN_HEIGHT,
        // 视口可用空间（右/下边界 − 弹窗左上角）÷zoom = 基准尺度上界；不撑出视口、不遮被查词。
        maxW: (box.maxRight - box.left) / z,
        maxH: (box.maxBottom - box.top) / z,
      },
    };
  };
  const move = (x, y) => {
    if (!fushiResizeDrag || !fushiHost) return;
    const d = fushiResizeDrag;
    // 位移超阈值才算真拖拽（区分纯点击与拖动，见 up() 的「拖即解锁」门控）。
    if (!d.moved && Math.abs(x - d.startX) + Math.abs(y - d.startY) > 3) {
      d.moved = true;
    }
    const size = fushiComputeResizedSize(
      { width: d.baseW, height: d.baseH },
      { dx: x - d.startX, dy: y - d.startY },
      d.zoom, d.bounds);
    fushiHost.style.width = size.width + 'px';
    fushiHost.style.maxHeight = size.height + 'px';
    fushiPositionResizeGrip();
  };
  const up = () => {
    const d = fushiResizeDrag;
    fushiResizeDrag = null;
    // 拖即解锁：仅当本次确实拖动过（位移超阈值）才回写尺寸 + 翻 independent；
    // 纯点击（把手盖住的内容点击）不脱钩「跟随 app 内尺寸」（BUG review LOW）。
    if (!d || !fushiHost || !d.moved) return;
    const w = parseFloat(fushiHost.style.width);
    const h = parseFloat(fushiHost.style.maxHeight);
    if (w > 0 && h > 0) fushiSendPopupSize(w, h);
  };
  grip.addEventListener('pointerdown', (e) => {
    if (e.button !== undefined && e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    try { grip.setPointerCapture(e.pointerId); } catch (_) { /* 某些上下文无指针捕获 */ }
    down(e.clientX, e.clientY);
  });
  grip.addEventListener('pointermove', (e) => {
    if (!fushiResizeDrag) return;
    e.preventDefault();
    move(e.clientX, e.clientY);
  });
  grip.addEventListener('pointerup', (e) => {
    e.preventDefault();
    e.stopPropagation();
    try { grip.releasePointerCapture(e.pointerId); } catch (_) { /* 同上 */ }
    up();
  });
  grip.addEventListener('pointercancel', () => { up(); });
}

// 确保拖拽把手已创建并挂到弹窗同父节点（fullscreenElement||body，与高亮层同源，全屏也可见）。
function fushiEnsureResizeGrip() {
  const parent = document.fullscreenElement || document.body;
  if (!parent) return;
  if (!fushiResizeGrip) {
    const g = document.createElement('div');
    g.id = 'fushi-popup-resize-grip';
    // 顶层 fixed；z-index 与 host 齐平（同值时 DOM 靠后者胜出 → 把手可点）；斜纹视觉暗示可拖。
    g.style.cssText =
      'position:fixed;left:0;top:0;width:' + FUSHI_RESIZE_GRIP_SIZE + 'px;height:' +
      FUSHI_RESIZE_GRIP_SIZE + 'px;z-index:2147483647;cursor:nwse-resize;' +
      'pointer-events:auto;touch-action:none;' +
      'background:linear-gradient(135deg,transparent 0 46%,rgba(128,128,128,0.75) 46% 54%,' +
      'transparent 54% 66%,rgba(128,128,128,0.75) 66% 74%,transparent 74%);';
    fushiInstallResizeDrag(g);
    fushiResizeGrip = g;
  }
  if (fushiResizeGrip.parentNode !== parent) parent.appendChild(fushiResizeGrip);
}

// BUG-1279：把「换弹窗内容」从「建立弹窗几何」里拆出来。首次查词两件事都要做；嵌套查词
// （弹窗内点释义里的词）只该换内容——原文里被查的词一个字都没变，重算它的高亮与落点纯属
// 无中生有。三个入口共用这一份内容渲染，行为不再各写一遍。
function fushiRenderEntries(popupJson) {
  const parseStartedAt = performance.now();
  let parseError = null;
  try { window.lookupEntries = JSON.parse(popupJson); }
  catch (error) {
    window.lookupEntries = [];
    parseError = String(error && error.message || error);
  }
  const parseMs = performance.now() - parseStartedAt;
  if (fushiLookupPerfContext) {
    fushiReportLookupPerf({
      id: fushiLookupPerfContext.id,
      surface: 'page-popup',
      stage: 'inner-json-parse',
      term: fushiLookupPerfContext.term,
      maximumTerms: fushiLookupPerfContext.maximumTerms,
      innerJsonParseMs: Number(parseMs.toFixed(1)),
      parsedEntryCount: Array.isArray(window.lookupEntries) ? window.lookupEntries.length : 0,
      ...(parseError ? { error: 'inner JSON parse: ' + parseError } : {}),
    });
  }
  if (parseError) {
    if (fushiContainer) {
      fushiContainer.innerHTML = '<div class="no-results">词典结果解析失败，请重试。</div>';
    }
    return false;
  }
  window._noResultsMessage = 'No results';
  window.__fushiOnTapOutside = fushiRemoveContainer;
  fushiBindPopupPerfContext(fushiLookupPerfContext);
  if (typeof window.renderPopup === 'function') window.renderPopup();
  return true;
}

// 把查词响应下发的主题变量套到弹窗上。applyBox=false 时只套颜色/行为类变量，**不碰 host 的
// 尺寸盒**（width/maxWidth/maxHeight/zoom）——嵌套查词是原地换内容，弹窗尺寸以及 place() 按
// 「不遮被查词」夹出来的 maxHeight 必须原样保持；重写尺寸盒会把那次夹取悄悄丢掉。
function fushiApplyTheme(c, theme, applyBox) {
  if (!theme || typeof theme !== 'object') return;
  for (const k in theme) {
    if (typeof theme[k] === 'string') c.style.setProperty(k, theme[k]);
  }
  // BUG-688：data-theme 也跟 app 主题（--fushi-color-scheme），覆盖 fushiEnsureContainer
  // 里基于宿主页 prefers-color-scheme 的初值。否则 app 浅色 + 宿主页深色时，content.css 的
  // [data-theme="dark"] 块给黑底/白字，却套上 app 浅色的 --md-* 米白 surface = 主题分裂
  // （用户报「和 app 内完全不一样」：黑底 + 米卡 + 灰字）。主题单一来源于 app，与 in-app 一致。
  const cs = theme['--fushi-color-scheme'];
  if (cs === 'dark' || cs === 'light') c.setAttribute('data-theme', cs);
  // 多列词典（masonry）根因修：popup.js 的 dictColumns() 与 updateEffectiveDictColumns()
  // 都从 document.documentElement 读 --dict-columns（in-app 时 documentElement 就是弹窗自身
  // 文档，注入在那里）。扩展里弹窗挂在宿主页的 shadow root，上面把 --dict-columns 连同其它
  // theme 变量 setProperty 到 #entries-container（c）——masonry 读 documentElement 读不到 →
  // 恒 1 列，且 updateEffectiveDictColumns 把 --dict-columns-effective 算成 1 写回
  // documentElement 又继承进 grid，连 CSS grid 兜底也塌成单列（用户报「浏览器多列不生效」）。
  // 这里把列数额外落到宿主页 documentElement（与 in-app dictionary_popup_webview 同源、整数
  // 字符串），让 masonry 读数、effective 收敛、grid 继承三条路径全部命中。命名空间自定义属性，
  // 宿主页 CSS 不消费，无副作用。
  const dictCols = theme['--dict-columns'];
  if (typeof dictCols === 'string' && dictCols) {
    try {
      document.documentElement.style.setProperty('--dict-columns', dictCols);
    } catch (_) { /* 宿主页禁写 style 时静默：多列退化为单列，不崩查词 */ }
  }
  // 「滑动关闭」偏好（app enableSwipeToClose）随 theme 下发（'1'/'0'）；置位后弹窗宿主上已挂的
  // 水平拖关手势才真正关窗（缺该 key = 旧 app，保持关闭，向后兼容）。
  fushiSwipeCloseEnabled = theme['--fushi-swipe-close'] === '1';
  // BUG-1026：查词弹窗滚轮速度倍率随 theme 下发（app popupWheelSpeed）→ 设同名全局供
  // popup.js 的 wheel 监听器读（content/popup 同隔离世界共享 window）。非法/缺失 → 1.0。
  {
    const ws = parseFloat(theme['--fushi-wheel-speed']);
    window.__fushiPopupWheelSpeed = (isFinite(ws) && ws > 0) ? ws : 1;
  }
  // BUG-688：尺寸盒 + zoom 落到 host（视口坐标，确定宽度 → header 满宽、按钮右推、不再全屏铺开）。
  if (applyBox && fushiHost) {
    fushiHost.style.width = theme['--fushi-popup-max-width'] || '400px';
    fushiHost.style.maxWidth = 'calc(100vw - 16px)';
    fushiHost.style.maxHeight =
        'min(' + (theme['--fushi-popup-max-height'] || '360px') + ', 80vh)';
    fushiHost.style.zoom = theme['--fushi-popup-zoom'] || '1';
  }
}

// BUG-1279：嵌套查词的渲染入口——**只换内容**。不重算原文高亮、不重新 place、不重写
// 尺寸盒。语义与 yomitan 的单弹窗内导航一致（本实现的既定设计也是「没有前进
// 后退，就是嵌套查词」）：用户视线停在弹窗上，弹窗就不该动；原文里被查的词没变，它的高亮
// 就不该变。修复前这里走的是下面 fushiRender 的完整路径，代价是弹窗归零到屏
// 幕左上角、再按**子词长度**截原文选区算出的锚点搬回原文旁边——用户看到的就是
// 「点了释义里的词，旧弹窗被关掉了」。
function fushiRenderNested(popupJson, theme) {
  // 请求在途期间弹窗已被关掉（点完链接又点了页面别处 / 滑动关窗 / 进出全屏重建失败）：直接
  // 丢弃这次嵌套结果。**不能**走 fushiEnsureContainer 凭空重建——嵌套渲染不 place，重建出来
  // 的弹窗会没有落点地钉在屏幕左上角；而且用户已经明确关掉了弹窗，它就不该再弹回来。
  if (!fushiHost || !fushiContainer) return;
  fushiApplyTheme(fushiContainer, theme, false);
  fushiRenderEntries(popupJson);
  fushiReportVisibleAfterPaint(fushiLookupPerfContext, fushiContainer);
}

function fushiRender(popupJson, termLen, theme, anchorRect) {
  const c = fushiEnsureContainer();
  // BUG-530：查词响应带回当前 app 主题色（--md-*），套到弹窗容器上，弹窗实时跟随用户主题
  // （改主题下次查词即变）。无 theme 时用 popup.css 里的深色兜底。首次查词要建立弹窗几何，
  // 故连尺寸盒一并套上（applyBox=true）；嵌套查词走 fushiRenderNested，不碰尺寸盒。
  fushiApplyTheme(c, theme, true);
  // TODO-1272：被查词高亮改为「扩展自绘覆盖层」，取词的视口 rects 也一并作弹窗锚点（不再贴鼠标坐标）。
  // 旧实现走 selection.js highlightSelection 的 DOM 包裹路径（<span class="fushi-dict-highlight">
  // 直接改宿主页文本节点）：动态站点（React/Vue/视频字幕逐帧重渲染）框架 diff / MutationObserver
  // 会在下一帧把这个凭空多出的 span revert 掉 → 高亮闪一下就没（用户报「非常容易消失」）。改画
  // 扩展自有的顶层 fixed 覆盖层：宿主页重绘/事件都碰不到它，保持到弹窗关闭。高亮前 termLen 个字。
  let wordRect = null;
  try {
    const hl = fushiSelectionRects(termLen);
    if (hl.rects.length) {
      fushiDrawHighlightOverlay(hl.rects); // 覆盖层高亮：宿主页 DOM 重绘/事件冲不掉它
      wordRect = hl.bounds;
    } else if (window.fushiSelection && typeof window.fushiSelection.highlightSelection === 'function') {
      // 兜底：selection 结构异常（无 ranges）时退回旧的 bbox 计算，只为拿锚点，不画 DOM 包裹高亮。
      wordRect = window.fushiSelection.highlightSelection(termLen);
    }
  } catch (_) { wordRect = null; }
  // TODO-1218②：取词 rects 拿不到（并发 selectText 清了 selection）时用查词时快照的锚点，避免退回鼠标坐标。
  if (!wordRect && anchorRect) wordRect = anchorRect;
  // 先隐藏放到左上角渲染，量出真实尺寸后再夹取到视口内显示——否则词在屏幕底/右时，
  // 弹窗直接放词处会溢出到浏览器窗口外/被裁（用户报「弹窗进到浏览器外面」）。
  c.style.visibility = 'hidden';
  if (fushiHost) { fushiHost.style.left = '0px'; fushiHost.style.top = '0px'; }
  fushiRenderEntries(popupJson);
  const place = () => {
    // BUG-688：量 host 的 rect（被 max-height 夹住=可见尺寸），不是容器（overflow:visible=全内容
    // 高度，会把弹窗错误地翻到词上方）。host 无则回落容器。
    const rect = (fushiHost || c).getBoundingClientRect();
    // 锚点=被查词的视口坐标。容器 position:fixed（BUG-530 全屏可见），坐标即视口系，故**不加**
    // scrollX/Y（加了反而在滚动页面上错位）。拿不到 bbox → 回落最后鼠标视口坐标。
    const ax = wordRect ? wordRect.x : fushiLastX;
    const ay = wordRect ? wordRect.y : fushiLastY;
    const ah = wordRect ? wordRect.height : 0;
    // BUG-767：落点交给纯函数算，保证永不覆盖被查词（旧逻辑翻到词上方时会被夹到边距 8 → 盖住词）。
    const pos = fushiComputePlacement(
      { x: ax, y: ay, height: ah },
      { width: rect.width, height: rect.height },
      { width: window.innerWidth, height: window.innerHeight });
    // BUG-688：host 现在带 zoom（尺寸盒随之缩放），故 fixed 定位坐标 / 夹高写入前除以 zoom，
    // 使渲染值(style×zoom)落回目标视口尺度；zoom 缺省 1 时零影响。
    const zoom = parseFloat(fushiHost && fushiHost.style.zoom) || 1;
    if (fushiHost) {
      // BUG-767：两侧都放不下时把弹窗高度夹到可用空间（内部滚动），弹窗底恰在词上方/下方，绝不压到词。
      if (pos.maxHeight != null) fushiHost.style.maxHeight = (pos.maxHeight / zoom) + 'px';
      fushiHost.style.left = (pos.left / zoom) + 'px';
      fushiHost.style.top = (pos.top / zoom) + 'px';
      // Phase D：记录本次落点的视口可用空间夹取上下文（视口坐标；host fixed，pos.* 即视口系），
      // 供拖拽把手把视口位移折回基准并夹取——不撑出视口、且拖大也不遮被查词（BUG-767 延续）。
      // 弹窗落在词上方(pos.top<ay)时弹窗底不得越过词顶(ay-G)；否则(落词下方/无锚点)可长到视口底。
      const resizeGap = 4;
      const maxBottom = (wordRect && pos.top < ay)
          ? (ay - resizeGap)
          : (window.innerHeight - 8);
      fushiResizeBox = {
        left: pos.left,
        top: pos.top,
        maxRight: window.innerWidth - 8,
        maxBottom: maxBottom,
        zoom: zoom,
      };
      fushiEnsureResizeGrip();
      fushiPositionResizeGrip();
    }
    c.style.visibility = 'visible';
    fushiReportVisibleAfterPaint(fushiLookupPerfContext, c);
  };
  requestAnimationFrame(place);
}

document.addEventListener('mousedown', (e) => {
  // BUG-688：shadow 内点击 e.target 被 retarget 成 fushiHost，故 contains 判定天然把
  // 「点弹窗内部」算作命中（不关窗）；只有点 host 之外才关。
  // Phase D：拖拽把手是 host 之外的顶层兄弟节点（避开 host 的 zoom 包含块），点它属正常操作
  // （开始拖拽调尺寸），不能触发关窗——否则一按把手弹窗就没了。故命中把手也算「点在弹窗上」。
  if (fushiResizeGrip &&
      (e.target === fushiResizeGrip || fushiResizeGrip.contains(e.target))) {
    return;
  }
  if (fushiHost && !fushiHost.contains(e.target)) fushiRemoveContainer();
});
