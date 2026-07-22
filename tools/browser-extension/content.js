// 取词扫描 + 弹窗注入。修饰键默认 Shift。普通 DOM（popup.js 依赖顶层 #entries-container）。
// 样式经 content.css 注入，全部作用域到 #entries-container，不污染宿主页（TODO-1090）。
// 版本标记：加载后在 Console 打一行，用户可据此确认加载的是**新版**扩展（排查缓存旧版）。
console.log('[Hibiki] content script v46 loaded (BUG-688: popup Shadow DOM isolation + theme single-sourced from app; TODO-1219/1363: subtitle cue replay + universal subtitle-list providers; TODO-1391: hide Netflix start-of-episode maturity/age-rating overlay)');
// 诊断标记：写进 <html> 的 data-*，页面 Console（主世界）可读，用来隔空排查划词为何不触发
// （隔离世界的全局变量在页面 console 里看不到，故用 DOM 属性桥接）。
try { document.documentElement.setAttribute('data-hibiki-cs', 'v46'); } catch (_) {}
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
// BUG-688：弹窗渲染进 Shadow DOM，宿主网页 CSS 无法穿透 shadow 边界（ruby/行距/定位等
// 与 in-app WebView 弹窗一致）。hibikiHost 是挂在宿主页的 shadow 宿主元素（负责 fixed 定位），
// #entries-container 及全部弹窗内容在其 shadow root 内；window.__hibikiRoot 暴露给 popup.js。
let hibikiHost = null;
// BUG-530 性能：划词监听器原来对每次 mousemove 都发查词请求 → 一直按 Shift 移动会把服务器
// 刷爆、UI 卡顿。用「位移阈值 + 同词去重 + 在途请求闸」三重节流：只在移到**不同词**上才查。
let hibikiLastTerm = '';
let hibikiLastX = -1;
let hibikiLastY = -1;
let hibikiPending = false;

// 弹窗尺寸精细化 Phase D：拖拽调整扩展弹窗尺寸。
// hibikiResizeGrip：右下角拖拽把手（顶层 position:fixed overlay，与高亮层同父挂在
//   fullscreenElement||body；不放进 host 的 shadow，避开 host 的 zoom 建立包含块干扰 fixed）。
// hibikiResizeBox：place() 每次落点后存的夹取上下文——弹窗视口左上角 + 视口可用空间右/下边界
//   （已内含 BUG-767「拖大也不许遮住被查词」约束）+ 当前 zoom，供拖拽把「视口位移」折回基准尺度。
// hibikiResizeDrag：一次拖拽的起始快照 {startX,startY,baseW,baseH,zoom,bounds}；null=未在拖。
let hibikiResizeGrip = null;
let hibikiResizeBox = null;
let hibikiResizeDrag = null;

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
  if (jumped) {
    hibikiCurText = text;
    hibikiCurStartV = text ? nowV : 0;
    hibikiLiveCueStart(text, nowV); // TODO-1363：seek 后的新句也入 live 轨（空文本时清掉悬挂引用）
    return;
  }
  if (text === hibikiCurText) return;
  if (hibikiCurText) {
    hibikiPushCueV(hibikiCurText, hibikiCurStartV, nowV); // 上一句定格
    hibikiLiveCueEnd(hibikiCurText, nowV); // TODO-1363：live 轨同句定格真实 end
  }
  hibikiCurText = text;
  hibikiCurStartV = text ? nowV : 0;
  if (text) hibikiLiveCueStart(text, nowV); // TODO-1363：新句出现即入 live 轨（暂定 end）
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
// TODO-1219/1363（勾选面板要刷新 + 面板空列表的根因）：本脚本 document_idle 注入，主世界
// netflix-bridge.js document_start 就装好 hook——Netflix 播放清单/字幕轨常在**本 listener 注册前**
// 就被抓取并 postMessage 出去，fire-and-forget 的消息永久丢失 → store 空、勾选开关无物可挂、
// 面板只剩预取的下一集轨（列表空）。接收端就位后立刻请求 bridge 重放已存档的 cue 消息，消除时序运气。
try { window.postMessage({ __hibikiNf: 'replayCues' }, '/'); } catch (_) {}

// ── TODO-1363：通用字幕轨 provider（所有站点） ──
// 数据契约不变：window.hibikiEpisodeCues[`${videoKey}|${lang}`] = [{startMs,endMs,text}]，新数据到达
// 即调 window.hibikiSubtitlePanelOnCues(key)。Netflix 整集拦截之外新增两条通用通道，站点差异全部
// 收敛在「谁往 store 里写」，面板零站点特例：
//   a) HTML5 video.textTracks 全量收割——任何用原生 <track>/TextTrack 的站点，cue 是结构化数据
//      （精确起止 + 文本），整轨直接读出，随流媒体渐进加载增量刷新；
//   b) DOM 字幕采样升格 live 轨——hibikiSampleCue 已在采字幕（YouTube .ytp-caption-segment /
//      Netflix .player-timedtext 等既有通道），把采到的句子按视频时间有序去重进 `${videoKey}|live`
//      轨，边看边长（YouTube 自绘字幕不走 textTracks，靠这条）。
const HIBIKI_LIVE_LANG = 'live';
function hibikiVideoKey() {
  const site = hibikiSite();
  if (site === 'netflix') {
    const id = hibikiNetflixId();
    if (id) return id; // 与整集拦截的 store key（manifest movieId）对齐
  }
  if (site === 'youtube') {
    const id = hibikiYoutubeId();
    if (id) return 'yt-' + id;
  }
  // 其它站点：host+path 即视频身份（'|' 是 store key 分隔符，替换掉防串 key）。
  return (location.hostname + location.pathname).replace(/\|/g, '_');
}
// 面板（subtitle-panel.js，同隔离世界后加载）用同一把 key 过滤当前视频的轨。
window.hibikiVideoKey = hibikiVideoKey;

function hibikiNotifyPanel(key) {
  try {
    if (typeof window.hibikiSubtitlePanelOnCues === 'function') window.hibikiSubtitlePanelOnCues(key);
  } catch (_) {}
}

// 有序插入 + 去重：同文本且句首相差 <750ms 视为同一句（倒退/回放重看不重复入轨）。返回是否真插入。
function hibikiSortedCueInsert(cues, cue) {
  let lo = 0;
  let hi = cues.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (cues[mid].startMs <= cue.startMs) lo = mid + 1; else hi = mid;
  }
  for (let i = lo - 1; i >= 0 && cue.startMs - cues[i].startMs < 750; i--) {
    if (cues[i].text === cue.text) return false;
  }
  for (let j = lo; j < cues.length && cues[j].startMs - cue.startMs < 750; j++) {
    if (cues[j].text === cue.text) return false;
  }
  cues.splice(lo, 0, cue);
  return true;
}

// live 轨：句子出现即入轨（暂定 end，勾选开关立刻有内容可显示），句子结束时定格真实 end。
let hibikiLiveCue = null; // 当前显示句在 live 轨里的对象引用
function hibikiLiveCueStart(text, startV) {
  if (!text) { hibikiLiveCue = null; return; }
  const key = hibikiVideoKey() + '|' + HIBIKI_LIVE_LANG;
  const track = hibikiEpisodeCues[key] || (hibikiEpisodeCues[key] = []);
  const cue = { startMs: startV, endMs: startV + 1500, text: text };
  if (hibikiSortedCueInsert(track, cue)) {
    hibikiLiveCue = cue;
    hibikiNotifyPanel(key);
  } else {
    hibikiLiveCue = null; // 回放已见过的句：不重复入轨，也不动旧句窗
  }
}
function hibikiLiveCueEnd(text, endV) {
  if (hibikiLiveCue && hibikiLiveCue.text === text && endV > hibikiLiveCue.startMs) {
    hibikiLiveCue.endMs = endV;
  }
  hibikiLiveCue = null;
}

// a) textTracks 全量收割：轮询增量（cue 随流加载渐增，条数长了才重建该轨）。kind 只收
// subtitles/captions；mode 为 disabled 时浏览器不加载 cues，跳过。
function hibikiHarvestTextTracks() {
  const v = document.querySelector('video');
  if (!v || !v.textTracks || !v.textTracks.length) return;
  const vidKey = hibikiVideoKey();
  for (let i = 0; i < v.textTracks.length; i++) {
    const tt = v.textTracks[i];
    if (!tt || (tt.kind !== 'subtitles' && tt.kind !== 'captions')) continue;
    if (tt.mode === 'disabled' || !tt.cues || !tt.cues.length) continue;
    const lang = String(tt.language || tt.label || 'und').replace(/\|/g, '_');
    const key = vidKey + '|' + lang;
    const existing = hibikiEpisodeCues[key];
    if (existing && existing.length >= tt.cues.length) continue;
    const out = [];
    for (let j = 0; j < tt.cues.length; j++) {
      const c = tt.cues[j];
      if (!c || typeof c.startTime !== 'number' || typeof c.endTime !== 'number') continue;
      const text = stripCueTags(String(c.text || ''));
      if (!text) continue;
      out.push({ startMs: Math.round(c.startTime * 1000), endMs: Math.round(c.endTime * 1000), text: text });
    }
    if (!out.length) continue;
    hibikiEpisodeCues[key] = out;
    hibikiNotifyPanel(key);
  }
}
try { setInterval(hibikiHarvestTextTracks, 1200); } catch (_) {}

// c) YouTube 真整集字幕（BUG-783 后续 / A）：YouTube 自绘字幕不走 textTracks，DOM 采样（live 轨）
//    暂停/seek/字幕未渲染时不稳、拿不到整集。改向本地 Hibiki server 要真字幕——server 复用 app 内
//    已修的解析器（androidVr getPlayerResponse + format-3 timedtext），一次拿全部轨（自动/人工）+
//    整集 cue，写进 store（真语言标签轨，面板排序自然盖过 |live）。best-effort：失败静默、live 回退。
function hibikiYtCaptionLabel(t, used) {
  let base = String(t.languageName || t.languageCode || 'und').replace(/\|/g, '_');
  if (t.isAutoGenerated && !/auto|自动/i.test(base)) base += ' (自动)';
  if (t.isTranslated) base += ' →译';
  let label = base;
  let n = 2;
  while (used.has(label)) label = base + ' #' + (n++); // 同名轨去重（防覆盖）
  used.add(label);
  return label;
}
function hibikiApplyYoutubeServerCaptions(resp) {
  if (!resp || !resp.ok || !resp.data || !Array.isArray(resp.data.tracks)) return 0;
  const vidKey = hibikiVideoKey();
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
    const key = vidKey + '|' + hibikiYtCaptionLabel(t, used);
    hibikiEpisodeCues[key] = cues;
    hibikiNotifyPanel(key);
    applied++;
  }
  return applied;
}
let hibikiYtCaptionsFetchedFor = null; // 已请求过的 videoId（防重复请求；SPA 切视频后 id 变即重取）
function hibikiMaybeFetchYoutubeCaptions() {
  if (hibikiSite() !== 'youtube') return;
  const id = hibikiYoutubeId();
  if (!id || hibikiYtCaptionsFetchedFor === id) return;
  hibikiYtCaptionsFetchedFor = id;
  try {
    chrome.runtime.sendMessage({ type: 'youtubeCaptions', videoId: id }, (resp) => {
      try {
        if (chrome.runtime.lastError) { hibikiYtCaptionsFetchedFor = null; return; } // 允许下轮重试
        if (!hibikiApplyYoutubeServerCaptions(resp)) hibikiYtCaptionsFetchedFor = null; // 空→可重试
      } catch (_) {}
    });
  } catch (_) { hibikiYtCaptionsFetchedFor = null; }
}
try { setInterval(hibikiMaybeFetchYoutubeCaptions, 1500); } catch (_) {}

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
// TODO-1331：把制卡请求的 HTTP/网络层失败翻成用户能懂的原因。resp 形状见 background.js：
// HTTP 成功 {ok:true,status,data}；非 2xx {ok:false,status,data:null}；fetch 抛异常
// （连接被拒/超时/DNS）{ok:false,error}。据此分 401 鉴权 / 404 端点 / 4xx-5xx 服务端 /
// 连不上（无 status）四类，让扩展弹明确 ✗ 原因，而不是静默 retry 到「你看日志却查不到」。
function hibikiMineHttpFailureReason(resp) {
  if (!resp) return '制卡无响应（扩展已更新？刷新页面 F5 重试）';
  const status = typeof resp.status === 'number' ? resp.status : 0;
  if (status === 401) return '鉴权失败(401)：扩展 token 与 Hibiki 不一致，去扩展设置核对 API key';
  if (status === 404) return '端点不存在(404)：Hibiki 未开 Yomitan API server 或端口不对';
  if (status >= 500) return '服务端错误(' + status + ')：制卡出错，去 Hibiki 错误日志页查详情';
  if (status >= 400) return '请求被拒(' + status + ')：' + (resp.error || '检查扩展设置');
  // ok:false 且无 status = fetch 抛异常（连接被拒/超时/DNS）：server 没开或主机/端口错。
  return '连不上 Hibiki(' + (resp.error || '连接被拒/超时') + ')：确认已开 Yomitan API server 且主机/端口正确';
}
function hibikiClassifyMineResp(resp) {
  // TODO-1331：HTTP/网络层失败不再静默 retry——弹 ✗ 原因让用户看得见（YouTube/Netflix
  // 批量制卡共用本分类器，两条链路的 HTTP 失败都据此显因）。
  if (!resp || !resp.ok || !resp.data) {
    if (typeof window.hibikiToast === 'function') {
      try { window.hibikiToast('✗ ' + hibikiMineHttpFailureReason(resp)); } catch (_) {}
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
    if (r === 'success' && reason && typeof window.hibikiToast === 'function') {
      try { window.hibikiToast('⚠ ' + reason); } catch (_) {}
    }
    return 'done';
  }
  if (r === 'notConfigured') return 'unconfigured';
  // error / 其它：失败，弹原因（无原因回落通用文案）后重试。
  if (typeof window.hibikiToast === 'function') {
    try { window.hibikiToast('✗ ' + (reason || '制卡失败，稍候再试')); } catch (_) {}
  }
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
    site: site,
    youtubeId: youtubeId,
    netflixId: netflixId,
    documentTitle: documentTitle,
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
    '.player-timedtext,#hibiki-subtitle-panel,#hibiki-subtitle-reopen,#hibiki-subtitle-overlay,#hibiki-subtitle-drop-hint,#hibiki-toast{visibility:hidden!important}' +
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
    try { window.postMessage({ __hibikiNf: 'seek', ms: ms }, '/'); } catch (_) {}
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
        await hibikiWaitForSeekSettled(v, targetSec, 4000);
        // TODO-1335 ④：落点后**先等缓冲就绪再开录**（readyState>=HAVE_FUTURE_DATA=3），暂停态等不推进
        // currentTime → 不吃头部提前量，也不把 stall 冻结帧录进 clip（offscreen 墙钟时长照走 → 虚长）。
        await hibikiWaitForBuffered(v, 3000);
        // TODO-1361 ⑤（BUG-685）：以「currentTime 真正前进」为唯一判据有界等视频开录，期间反复补 play()。
        // 旧实现只在固定 480ms（8×60ms）后单看一次 v.paused 就判跳——但 v.paused===false 不等于在播
        // （可能仍 seeking 冻结），且 Netflix seek→恢复播放耗时多变，480ms 常不够 → 本可录的句被误判
        // 「暂停」立即 seek 走（用户报「跳转过去以后马上跳转走了、根本没制卡」根因）。改为轮询到视频真
        // 前进才开录；到 4s 上界仍推不动才按失败计（真 DRM/网络/自动播放失败，留队可重试，BUG-675 清点
        // 不变），不再因 seek→播放时序把本可录的句误跳。
        const advancing = await hibikiWaitForPlaying(v, 4000);
        if (!advancing) { fail++; window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
        const beginResp = await chrome.runtime.sendMessage({ target: 'offscreen', type: 'beginClip' });
        began = !!(beginResp && beginResp.ok);
        if (!began) { fail++; window.hibikiToast('生成中… ' + (done + fail) + '/' + items.length, true); continue; }
        // 本句结束判据：字幕文本变成别的/清空（≠ 这一句），且已过句首 0.4s。refText 用入队时存的整句
        // 文本，比「播放时现采样」稳（避免字幕还没渲染时采到空 → 判据失效整段录到超时）。
        // seek 后字幕要零点几秒才重新渲染：**先等本句字幕真正出现**（过句首 0.3s 后第一段非空字幕
        // 作参照 ref），**再**录到字幕变成别句(=本句结束)才停。不能一开始就比 refText——seek 后先采到
        // 的是残留/空字幕，会被误判成「已结束」→ 录一瞬就停（用户报「一下就停了」根因）。
        // hardEnd 只是字幕检测失效（字幕关/相邻同文本）时的安全上限。
        // TODO-1364：字幕清空/变句 = Netflix 字幕 **display end**，常早于本句 **语音 end**；且入队窗
        // 的 200ms 尾部预留（q.endV = cueEnd+200）在回放录制侧从未被消费（见 hibikiCurrentCueWindowV
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
          const nowText = hibikiSubtitleTextNow();
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
                documentTitle: q.documentTitle || (typeof netflixDocumentTitle === 'function' ? netflixDocumentTitle() : '') },
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

// TODO-1335 ④：等 video 在当前播放点缓冲就绪（readyState>=HAVE_FUTURE_DATA=3，可从该点顺畅
// 前进）。用于 seek 后、开录前的缓冲门（暂停态调用 → currentTime 不推进 → 不吃头部提前量）。
// maxMs 上界兜底：弱网/受阻迟迟不就绪时也继续（退化到旧行为，绝不无限等卡死批量）。
function hibikiWaitForBuffered(v, maxMs) {
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
function hibikiWaitForSeekSettled(v, targetSec, maxMs) {
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
function hibikiWaitForPlaying(v, maxMs) {
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
      // BUG-675（TODO-1361 ②）：录制失败的卡片留在队列（未丢失），但旧实现一律报「✓ 全部完成」
      // 掩盖了被跳过的卡，用户以为都生成了。批量结束时清点本次剧集仍残留的网飞待生成项，>0 就明确
      // 告知「N 张录制失败未生成，可再点生成重试」，把静默跳过变成可见可重试。
      let hibikiRemainingNf = 0;
      try {
        const hibikiGot = await chrome.storage.local.get(['hibikiQueue']);
        const hibikiQ = Array.isArray(hibikiGot.hibikiQueue) ? hibikiGot.hibikiQueue : [];
        hibikiRemainingNf = hibikiQ.filter(
            (it) => it && it.site === 'netflix' && st.episodes.indexOf(it.netflixId) >= 0).length;
      } catch (_) {}
      if (hibikiRemainingNf > 0) {
        window.hibikiToast('✓ 生成完成：' + hibikiRemainingNf + ' 张录制失败未生成，可再点生成重试');
      } else {
        window.hibikiToast('✓ 全部剧集生成完成');
      }
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

// ── BUG-674（TODO-1361 ①）+ BUG-702（TODO-1391）：隐藏网飞自己的干扰性播放器 UI ──
// 纯视觉：只注入 CSS 隐藏 Netflix 自己的 seamless「下一集」按钮 + 剧末续播卡 + 剧集开头左上角的
// 年龄分级/成熟度评级 overlay（TODO-1391：制卡录制会把它录进卡片截图/gif），绝不碰 DRM/seek/自动
// 切集计时器（不改变播放行为）。由 options 开关 netflixHideNextEpisode 门控——缺省=隐藏（用户诉求），
// 仅在显式存 false 时才显示；storage.onChanged 实时生效。CSS 规则常驻，Netflix 重建元素也照样命中。
const HIBIKI_NF_HIDE_NEXT_ID = 'hibiki-nf-hide-next';
function hibikiNetflixNextEpisodeSelectors() {
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
function hibikiApplyNetflixNextEpisodeHiding(hide) {
  if (hibikiSite() !== 'netflix') return;
  const existing = document.getElementById(HIBIKI_NF_HIDE_NEXT_ID);
  if (!hide) { if (existing) { try { existing.remove(); } catch (_) {} } return; }
  if (existing) return;
  const style = document.createElement('style');
  style.id = HIBIKI_NF_HIDE_NEXT_ID;
  style.textContent =
      hibikiNetflixNextEpisodeSelectors().join(',') + '{display:none!important}';
  try { (document.head || document.documentElement).appendChild(style); } catch (_) {}
}
function hibikiReadNextEpisodeHide() {
  try {
    chrome.storage.local.get(['netflixHideNextEpisode'], (r) => {
      hibikiApplyNetflixNextEpisodeHiding(!(r && r.netflixHideNextEpisode === false));
    });
  } catch (_) { hibikiApplyNetflixNextEpisodeHiding(true); }
}
try {
  hibikiReadNextEpisodeHide();
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && changes.netflixHideNextEpisode) {
      hibikiApplyNetflixNextEpisodeHiding(changes.netflixHideNextEpisode.newValue !== false);
    }
  });
} catch (_) {}

// 「滑动关闭查词弹窗」——app 的 enableSwipeToClose 偏好经查词响应 theme 的
// --hibiki-swipe-close（'1'/'0'）下发；in-app 走 Flutter 手势层 / WebView topPullReleased，
// 扩展的浮动弹窗是纯 DOM，这里在弹窗宿主上装同语义的**水平拖关**手势（设置项文案即「水平
// 滑动关闭查词弹窗」）。默认 Windows/Linux 关（鼠标框选正文与拖手势同形易误触），跟随 app 偏好。
let hibikiSwipeCloseEnabled = false;
let hibikiSwipeStart = null;
// 水平拖过此像素即关（固定阈值；in-app 的灵敏度滑块暂不移植，待真机再定是否需要）。
const HIBIKI_SWIPE_CLOSE_THRESHOLD = 64;

// 在弹窗宿主 [host] 上装水平拖关手势（每个 host 只装一次）。监听始终挂上，是否真正关窗由
// hibikiSwipeCloseEnabled 门控（theme 到达后置位）→ 关时纯 no-op，开时水平主导且过阈才关。
// pointer 路径只接 mouse/pen（touch 由 touch 家族处理，避免同一次拖动双触发）；全部 passive。
function hibikiInstallSwipeClose(host) {
  if (!host || host.__hibikiSwipeHooked) return;
  host.__hibikiSwipeHooked = true;
  const start = (x, y) => { hibikiSwipeStart = { x: x, y: y }; };
  const move = (x, y) => {
    if (!hibikiSwipeCloseEnabled || !hibikiSwipeStart) return;
    const dx = x - hibikiSwipeStart.x;
    const dy = y - hibikiSwipeStart.y;
    // 水平主导（|dx| > 1.5·|dy|，避开竖向滚动/选竖排）且过阈 → 关。
    if (Math.abs(dx) > HIBIKI_SWIPE_CLOSE_THRESHOLD &&
        Math.abs(dx) > Math.abs(dy) * 1.5) {
      hibikiSwipeStart = null;
      hibikiRemoveContainer();
    }
  };
  const end = () => { hibikiSwipeStart = null; };
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

function hibikiEnsureContainer() {
  // BUG-530：全屏时（Netflix 看片常全屏）挂在 document.body 上的弹窗会被全屏元素盖住看不见
  // （浏览器全屏只渲染 fullscreenElement 及其后代）→ shift 划词其实触发了但弹窗不可见=「没反应」。
  // 故挂到当前 fullscreenElement（无则 body），并用 position:fixed + 视口坐标，全屏/普通页都对。
  // BUG-530：全屏时挂到 fullscreenElement（无则 body），position:fixed 全屏/普通页都可见。
  const parent = document.fullscreenElement || document.body;
  if (hibikiHost && hibikiHost.parentNode === parent && hibikiContainer) {
    return hibikiContainer;
  }
  if (!hibikiHost) {
    // BUG-688：shadow 宿主元素只负责 fixed 定位 + 层级；弹窗内容全在其 shadow root 内，
    // 宿主页 CSS 无法穿透 → 与 in-app 弹窗渲染一致（不再被宿主站点 line-height/ruby 等污染）。
    hibikiHost = document.createElement('div');
    hibikiHost.id = 'hibiki-popup-host';
    // BUG-688：尺寸盒 + zoom 落在 host（视口坐标系，确定宽度），弹窗内容尺寸不再受
    // 「CSS zoom × 100vw × shadow shrink-to-fit」相互作用干扰。host 宽/高/zoom 由 hibikiRender
    // 按查词响应下发的 --hibiki-popup-* 设置；#entries-container 在 shadow 内中和为 width:100%。
    hibikiHost.style.cssText =
        'position:fixed;top:0;left:0;z-index:2147483647;overflow-x:hidden;overflow-y:auto;' +
        // 入场淡入：与 app 内 parkedPopupLayer 及 app 外 .global-lookup-frame-shell 的
        // 200ms ease-out 对齐。首帧 opacity:0，place() 定位后 reflow 触发 0→1 淡入。
        'opacity:0;transition:opacity 200ms ease-out;';
    hibikiInstallSwipeClose(hibikiHost); // 水平拖关手势（是否生效由 hibikiSwipeCloseEnabled 门控）
    const shadow = hibikiHost.attachShadow({ mode: 'open' });
    // 中和 content.css 里 #entries-container 自带的尺寸盒/zoom（那套是给「容器自身即 fixed 元素」
    // 的旧模型用的）；现在 host 才是尺寸/缩放/定位主体，容器只做 100% 透传。
    const norm = document.createElement('style');
    norm.textContent =
        '#entries-container{width:100%!important;max-width:none!important;' +
        'max-height:none!important;overflow:visible!important;zoom:1!important;}';
    shadow.appendChild(norm);
    // 把弹窗样式注入 shadow：content.css 作为扩展资源经 <link> 加载（web_accessible_resources）。
    // 其中宿主页级选择器（#hibiki-subtitle-panel/高亮层等）在 shadow 内无对应元素、天然失效；
    // 弹窗选择器（#entries-container/.glossary-group/ruby…）在 shadow 内生效。
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = chrome.runtime.getURL('vendor/content.css');
    shadow.appendChild(link);
    const c = document.createElement('div');
    c.id = 'entries-container';
    // 主题落在弹窗根 #entries-container 上（content.css 作用域 #entries-container[data-theme]）；
    // --md-* / --hibiki-popup-* 由 hibikiRender 直接 setProperty 到该元素，shadow 内可读。
    c.setAttribute('data-theme', hibikiResolveTheme());
    shadow.appendChild(c);
    hibikiContainer = c;
    window.__hibikiRoot = shadow; // popup.js 的 DOM 查询/浮层/选区都相对它解析
  }
  if (hibikiHost.parentNode !== parent) parent.appendChild(hibikiHost); // 进/出全屏迁父节点
  return hibikiContainer;
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
  // BUG-688：移除 shadow 宿主即连带整个 shadow root（弹窗内容）；清 __hibikiRoot 让 popup.js
  // 的 helper 回落到 document（下次开窗 hibikiEnsureContainer 会重建）。host 引用即刻置空，
  // 让并发 re-lookup 重建新 host；旧节点先淡出、末尾才从 DOM 移除（高亮/选区仍即时清）。
  const dying = hibikiHost;
  hibikiHost = null;
  hibikiContainer = null;
  window.__hibikiRoot = null;
  // TODO-1272：关窗即撤覆盖层高亮（被查词高亮跟随弹窗生命周期，弹窗在则在、弹窗关则撤）。
  hibikiClearHighlightOverlay();
  // TODO-1150（yomitan 式）：关窗即撤 selection 状态与任何 DOM 包裹高亮（嵌套查词用）。hoshiSelection 未加载/无选区时是 no-op。
  try {
    if (window.hoshiSelection && typeof window.hoshiSelection.clearSelection === 'function') {
      window.hoshiSelection.clearSelection();
    }
  } catch (_) { /* no-op */ }
  // 淡出后再从 DOM 移除 host 节点（与入场淡入及 app 外 .global-lookup-dismissing 的 200ms
  // ease-out 对齐）。pointer-events:none 避免淡出期误吞点击；transitionend 用 setTimeout
  // 兜底（reduced-motion / 离屏也能移除）。高亮/选区已在上面即时清，不随淡出延迟残留。
  if (dying) {
    dying.style.pointerEvents = 'none';
    dying.style.opacity = '0';
    let dropped = false;
    const drop = () => {
      if (dropped) return;
      dropped = true;
      try { dying.remove(); } catch (_) { /* 已脱离文档 */ }
    };
    dying.addEventListener('transitionend', drop, { once: true });
    setTimeout(drop, 260);
  }
  // Phase D：关窗即撤拖拽把手 + 清尺寸拖拽状态（把手随弹窗生命周期，下次开窗 place() 重建）。
  if (hibikiResizeGrip) {
    try { hibikiResizeGrip.remove(); } catch (_) { /* 已脱离文档 */ }
    hibikiResizeGrip = null;
  }
  hibikiResizeDrag = null;
  hibikiResizeBox = null;
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

let hibikiLastConnectionHintAt = 0;
function hibikiShowConnectionFailure(resp) {
  const now = Date.now();
  if (now - hibikiLastConnectionHintAt < 8000) return; // hover 连发时只提醒一次，避免刷屏
  hibikiLastConnectionHintAt = now;
  const c = resp && resp.connection;
  let message = 'Hibiki API 未开启：请在 Hibiki 设置 → 查词中开启 Yomitan API 服务器';
  if (c && c.state === 'yomitan-conflict') {
    message = '端口 ' + (c.port || 19633) + ' 被 Yomitan API 占用：请在 Yomitan 高级设置关闭 Enable Yomitan API，再开启 Hibiki 的 Yomitan API 服务器';
  } else if (c && c.state === 'unauthorized') {
    message = 'Hibiki API 密钥不匹配：请打开扩展设置并恢复自动配置';
  } else if (c && c.state === 'wrong-service') {
    message = '扩展端口连接到了其他服务：请打开扩展设置检查连接';
  }
  try { window.hibikiToast('⚠ ' + message); } catch (_) {}
}

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
      if (!resp || !resp.ok) { hibikiShowConnectionFailure(resp); return; }
      if (!resp.data || !resp.data.popupJson) return;
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
      if (!resp || !resp.ok) { hibikiShowConnectionFailure(resp); return; }
      if (!resp.data || !resp.data.popupJson) return;
      const best = resp.data.result && typeof resp.data.result.bestLength === 'number'
        ? resp.data.result.bestLength : 0;
      const termLen = best > 0 ? best : term.length;
      window.audioSources = Array.isArray(resp.data.audioSources) ? resp.data.audioSources : [];
      window.needsAudio = true;
      hibikiRender(resp.data.popupJson, termLen, resp.data.theme);
    });
  } catch (_) { /* 扩展上下文失效：静默 */ }
};

// BUG-767：计算查词弹窗落点，保证**永不覆盖被查词**。纯函数（不碰 DOM），便于单测。
// anchor：被查词的视口矩形 {x, y, height}（x/y=左上角，height=词高，均视口坐标系）。
// size：弹窗自然尺寸 {width, height}（已按主题 max-height 夹住的可见尺寸）。
// viewport：{width, height}。返回 {left, top, maxHeight}；maxHeight!=null 表示上下两侧
// 都放不下整只弹窗，需把弹窗高度夹到所选一侧的可用空间（内部滚动），故渲染后不会压到词上。
// 旧实现只把 top 夹到边距 8，弹窗高时（词典结果多）会从 8 往下铺开盖住上半屏的词——本函数修掉。
function hibikiComputePlacement(anchor, size, viewport) {
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
function hibikiComputeResizedSize(start, delta, zoom, bounds) {
  const z = zoom > 0 ? zoom : 1;
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), Math.max(lo, hi));
  const width = clamp(start.width + delta.dx / z, bounds.minW, bounds.maxW);
  const height = clamp(start.height + delta.dy / z, bounds.minH, bounds.maxH);
  return { width: width, height: height };
}

// 基准最大宽/高的允许范围（逻辑像素）。与 app 设置页两滑杆 + Dart 侧
// effective_lookup_size.dart 的 kLookupPopupMin/MaxWidth/Height 单一同源——拖拽与滑杆写同一
// 真值，故边界必须一致，否则拖拽能写出滑杆写不出的越界值（app 侧仍会再 clamp 一次兜底）。
const HIBIKI_POPUP_MIN_WIDTH = 250;
const HIBIKI_POPUP_MIN_HEIGHT = 200;
const HIBIKI_RESIZE_GRIP_SIZE = 18;

// 把拖拽把手移到弹窗当前渲染矩形的右下角（视口坐标；host 是 fixed，坐标即视口系）。
function hibikiPositionResizeGrip() {
  if (!hibikiResizeGrip || !hibikiHost) return;
  const r = hibikiHost.getBoundingClientRect();
  const s = HIBIKI_RESIZE_GRIP_SIZE;
  hibikiResizeGrip.style.left = (r.right - s) + 'px';
  hibikiResizeGrip.style.top = (r.bottom - s) + 'px';
}

// Phase D：把拖出来的最终基准最大宽高经 background → app（POST /api/extension/popup-size）。
// app 侧 clamp(250-2000/200-1600) + 「拖即解锁」extensionPopupIndependentSize=true + 写扩展键，
// 下一次查词 browserExtensionThemeColors 读新 extensionPopupEffectiveSize 即以新尺寸下发（闭环）。
function hibikiSendPopupSize(maxWidth, maxHeight) {
  try {
    chrome.runtime.sendMessage(
      { type: 'popupSize', maxWidth: Math.round(maxWidth), maxHeight: Math.round(maxHeight) },
      () => { void chrome.runtime.lastError; });
  } catch (_) { /* 扩展上下文失效：静默（尺寸只是没落库，不崩查词） */ }
}

// 在把手上装拖拽逻辑（每个 grip 只装一次）。pointerdown 快照起始基准 + 视口可用空间夹取上界，
// pointermove 经纯函数 hibikiComputeResizedSize 实时改 host 的 width/maxHeight（place() 只在查词当
// 帧跑一次、无 rAF 循环，故手动尺寸不会被每帧覆盖回去），pointerup 落库并经 bridge 回写 app。
function hibikiInstallResizeDrag(grip) {
  if (!grip || grip.__hibikiResizeHooked) return;
  grip.__hibikiResizeHooked = true;
  const down = (x, y) => {
    if (!hibikiHost || !hibikiResizeBox) return;
    const box = hibikiResizeBox;
    const z = box.zoom > 0 ? box.zoom : 1;
    const baseW = parseFloat(hibikiHost.style.width) || 0;
    // 当前基准高度：host 渲染高÷zoom（style.maxHeight 可能是 min()/px/未设 → 用真实 rect 最稳）。
    const baseH = hibikiHost.getBoundingClientRect().height / z;
    hibikiResizeDrag = {
      startX: x, startY: y, baseW: baseW, baseH: baseH, zoom: z,
      moved: false,
      bounds: {
        minW: HIBIKI_POPUP_MIN_WIDTH, minH: HIBIKI_POPUP_MIN_HEIGHT,
        // 视口可用空间（右/下边界 − 弹窗左上角）÷zoom = 基准尺度上界；不撑出视口、不遮被查词。
        maxW: (box.maxRight - box.left) / z,
        maxH: (box.maxBottom - box.top) / z,
      },
    };
  };
  const move = (x, y) => {
    if (!hibikiResizeDrag || !hibikiHost) return;
    const d = hibikiResizeDrag;
    // 位移超阈值才算真拖拽（区分纯点击与拖动，见 up() 的「拖即解锁」门控）。
    if (!d.moved && Math.abs(x - d.startX) + Math.abs(y - d.startY) > 3) {
      d.moved = true;
    }
    const size = hibikiComputeResizedSize(
      { width: d.baseW, height: d.baseH },
      { dx: x - d.startX, dy: y - d.startY },
      d.zoom, d.bounds);
    hibikiHost.style.width = size.width + 'px';
    hibikiHost.style.maxHeight = size.height + 'px';
    hibikiPositionResizeGrip();
  };
  const up = () => {
    const d = hibikiResizeDrag;
    hibikiResizeDrag = null;
    // 拖即解锁：仅当本次确实拖动过（位移超阈值）才回写尺寸 + 翻 independent；
    // 纯点击（把手盖住的内容点击）不脱钩「跟随 app 内尺寸」（BUG review LOW）。
    if (!d || !hibikiHost || !d.moved) return;
    const w = parseFloat(hibikiHost.style.width);
    const h = parseFloat(hibikiHost.style.maxHeight);
    if (w > 0 && h > 0) hibikiSendPopupSize(w, h);
  };
  grip.addEventListener('pointerdown', (e) => {
    if (e.button !== undefined && e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    try { grip.setPointerCapture(e.pointerId); } catch (_) { /* 某些上下文无指针捕获 */ }
    down(e.clientX, e.clientY);
  });
  grip.addEventListener('pointermove', (e) => {
    if (!hibikiResizeDrag) return;
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
function hibikiEnsureResizeGrip() {
  const parent = document.fullscreenElement || document.body;
  if (!parent) return;
  if (!hibikiResizeGrip) {
    const g = document.createElement('div');
    g.id = 'hibiki-popup-resize-grip';
    // 顶层 fixed；z-index 与 host 齐平（同值时 DOM 靠后者胜出 → 把手可点）；斜纹视觉暗示可拖。
    g.style.cssText =
      'position:fixed;left:0;top:0;width:' + HIBIKI_RESIZE_GRIP_SIZE + 'px;height:' +
      HIBIKI_RESIZE_GRIP_SIZE + 'px;z-index:2147483647;cursor:nwse-resize;' +
      'pointer-events:auto;touch-action:none;' +
      'background:linear-gradient(135deg,transparent 0 46%,rgba(128,128,128,0.75) 46% 54%,' +
      'transparent 54% 66%,rgba(128,128,128,0.75) 66% 74%,transparent 74%);';
    hibikiInstallResizeDrag(g);
    hibikiResizeGrip = g;
  }
  if (hibikiResizeGrip.parentNode !== parent) parent.appendChild(hibikiResizeGrip);
}

function hibikiRender(popupJson, termLen, theme, anchorRect) {
  const c = hibikiEnsureContainer();
  // BUG-530：查词响应带回当前 app 主题色（--md-*），套到弹窗容器上，弹窗实时跟随用户主题
  // （改主题下次查词即变）。无 theme 时用 popup.css 里的深色兜底。
  if (theme && typeof theme === 'object') {
    for (const k in theme) {
      if (typeof theme[k] === 'string') c.style.setProperty(k, theme[k]);
    }
    // BUG-688：data-theme 也跟 app 主题（--hibiki-color-scheme），覆盖 hibikiEnsureContainer
    // 里基于宿主页 prefers-color-scheme 的初值。否则 app 浅色 + 宿主页深色时，content.css 的
    // [data-theme="dark"] 块给黑底/白字，却套上 app 浅色的 --md-* 米白 surface = 主题分裂
    // （用户报「和 app 内完全不一样」：黑底 + 米卡 + 灰字）。主题单一来源于 app，与 in-app 一致。
    const cs = theme['--hibiki-color-scheme'];
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
    hibikiSwipeCloseEnabled = theme['--hibiki-swipe-close'] === '1';
    // BUG-688：尺寸盒 + zoom 落到 host（视口坐标，确定宽度 → header 满宽、按钮右推、不再全屏铺开）。
    if (hibikiHost) {
      hibikiHost.style.width = theme['--hibiki-popup-max-width'] || '400px';
      hibikiHost.style.maxWidth = 'calc(100vw - 16px)';
      hibikiHost.style.maxHeight =
          'min(' + (theme['--hibiki-popup-max-height'] || '360px') + ', 80vh)';
      hibikiHost.style.zoom = theme['--hibiki-popup-zoom'] || '1';
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
  if (hibikiHost) { hibikiHost.style.left = '0px'; hibikiHost.style.top = '0px'; }
  try { window.lookupEntries = JSON.parse(popupJson); }
  catch (_) { window.lookupEntries = []; }
  window._noResultsMessage = 'No results';
  window.__hibikiOnTapOutside = hibikiRemoveContainer;
  if (typeof window.renderPopup === 'function') window.renderPopup();
  const place = () => {
    // BUG-688：量 host 的 rect（被 max-height 夹住=可见尺寸），不是容器（overflow:visible=全内容
    // 高度，会把弹窗错误地翻到词上方）。host 无则回落容器。
    const rect = (hibikiHost || c).getBoundingClientRect();
    // 锚点=被查词的视口坐标。容器 position:fixed（BUG-530 全屏可见），坐标即视口系，故**不加**
    // scrollX/Y（加了反而在滚动页面上错位）。拿不到 bbox → 回落最后鼠标视口坐标。
    const ax = wordRect ? wordRect.x : hibikiLastX;
    const ay = wordRect ? wordRect.y : hibikiLastY;
    const ah = wordRect ? wordRect.height : 0;
    // BUG-767：落点交给纯函数算，保证永不覆盖被查词（旧逻辑翻到词上方时会被夹到边距 8 → 盖住词）。
    const pos = hibikiComputePlacement(
      { x: ax, y: ay, height: ah },
      { width: rect.width, height: rect.height },
      { width: window.innerWidth, height: window.innerHeight });
    // BUG-688：host 现在带 zoom（尺寸盒随之缩放），故 fixed 定位坐标 / 夹高写入前除以 zoom，
    // 使渲染值(style×zoom)落回目标视口尺度；zoom 缺省 1 时零影响。
    const zoom = parseFloat(hibikiHost && hibikiHost.style.zoom) || 1;
    if (hibikiHost) {
      // BUG-767：两侧都放不下时把弹窗高度夹到可用空间（内部滚动），弹窗底恰在词上方/下方，绝不压到词。
      if (pos.maxHeight != null) hibikiHost.style.maxHeight = (pos.maxHeight / zoom) + 'px';
      hibikiHost.style.left = (pos.left / zoom) + 'px';
      hibikiHost.style.top = (pos.top / zoom) + 'px';
      // Phase D：记录本次落点的视口可用空间夹取上下文（视口坐标；host fixed，pos.* 即视口系），
      // 供拖拽把手把视口位移折回基准并夹取——不撑出视口、且拖大也不遮被查词（BUG-767 延续）。
      // 弹窗落在词上方(pos.top<ay)时弹窗底不得越过词顶(ay-G)；否则(落词下方/无锚点)可长到视口底。
      const resizeGap = 4;
      const maxBottom = (wordRect && pos.top < ay)
          ? (ay - resizeGap)
          : (window.innerHeight - 8);
      hibikiResizeBox = {
        left: pos.left,
        top: pos.top,
        maxRight: window.innerWidth - 8,
        maxBottom: maxBottom,
        zoom: zoom,
      };
      hibikiEnsureResizeGrip();
      hibikiPositionResizeGrip();
    }
    c.style.visibility = 'visible';
    // 入场淡入：把 host 压到 0 并强制回流提交为过渡基线，再翻 1 触发 200ms ease-out
    // 淡入（同帧 0→1 无 reflow 会被浏览器合并、跳过过渡）。重复查词复用同一 host 时
    // 亦从 0 重新淡入，与 app 内每次「隐藏→可见」淡入一致。
    if (hibikiHost) {
      hibikiHost.style.opacity = '0';
      void hibikiHost.offsetWidth;
      hibikiHost.style.opacity = '1';
    }
  };
  requestAnimationFrame(place);
}

document.addEventListener('mousedown', (e) => {
  // BUG-688：shadow 内点击 e.target 被 retarget 成 hibikiHost，故 contains 判定天然把
  // 「点弹窗内部」算作命中（不关窗）；只有点 host 之外才关。
  // Phase D：拖拽把手是 host 之外的顶层兄弟节点（避开 host 的 zoom 包含块），点它属正常操作
  // （开始拖拽调尺寸），不能触发关窗——否则一按把手弹窗就没了。故命中把手也算「点在弹窗上」。
  if (hibikiResizeGrip &&
      (e.target === hibikiResizeGrip || hibikiResizeGrip.contains(e.target))) {
    return;
  }
  if (hibikiHost && !hibikiHost.contains(e.target)) hibikiRemoveContainer();
});
