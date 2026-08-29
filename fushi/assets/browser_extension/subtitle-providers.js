// 字幕 provider（站点无关的 store + 写入者）。从 content.js 抽出，原因：这一段**不依赖 chrome.* 也不依赖隔离世界**，
// 扩展（隔离世界、manifest 顺序在 content.js 之前）与 Fushi app 内置网页播放器（WebView2 主世界 document-start 注入，
// 资产镜像 assets/browser_extension/）共用同一份文件。数据契约：window.fushiEpisodeCues[`${videoKey}|${lang}`] =
// [{startMs,endMs,text}]（按 startMs 有序），新数据到达即调 window.fushiSubtitlePanelOnCues(key)；window.fushiVideoKey()
// 是当前视频身份。依赖 subtitle-adapters.js 的解析器（parseWebVtt / parseTtml / parseBilibiliJson / stripCueTags /
// netflixVideoIdFromPath）先于本文件加载。主世界 bridge（netflix-bridge / stream-bridge / youtube-bridge）的 postMessage
// 在这里接收；两个宿主唯一的差别是谁消费 store（扩展：subtitle-panel.js；app：web_video_glue.js → Dart）。

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
