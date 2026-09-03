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
  // bilibili.com（大陆站）。注意与 bilibili.tv（国际站，走 stream-bridge 抓字幕）不同域，
  // 两者的接口与字幕来源都不一样，别合成一个判定。
  if (h === 'bilibili.com' || h.endsWith('.bilibili.com')) return 'bilibili';
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
// 制卡裁切窗的边距（毫秒）：句首/句尾各外扩这么多。
//
// 两条制卡路裁的是**同一句话**，边距必须同源：
//   · 入队批量剪辑（`content.js` 的 `fushiEnqueue`）——过去写死 `startV - 200 / endV + 200`；
//   · 立即出卡（`bridge-shim.js` 的 mine 消息）——过去发的是**裸 cue 窗**，一点边距都没有。
// 于是同一个用户在 B 站点一下出的卡，句子音频开头容易被切掉一点，而 YouTube 批量那条不会。
//
// 200ms 的来源是**字幕采样粒度**：当前字幕行是轮询 DOM 发现的，`startV` 最坏比真句首晚一个
// 采样周期；再叠上音频编码器的起始帧对齐，不外扩就会吃掉句子开头的辅音。
//
// 注意 `cueStartMs`（静态帧「字幕开头」档要的时刻）必须仍是**真句首**，不带这个边距——
// 边距是给「裁音频/动图」用的，不是给「定位那一帧」用的。
const FUSHI_CLIP_WINDOW_MARGIN_MS = 200;

// 纯函数：把 cue 的 [startV, endV] 外扩成制卡裁切窗。start 夹到 >= 0（句首在 0 附近时不越界）。
// 入参非有限数 → null，调用方据此判「这一句没有可用的时间窗」。
function fushiClipWindowWithMargin(startV, endV, marginMs) {
  const s = Number(startV);
  const e = Number(endV);
  if (!isFinite(s) || !isFinite(e)) return null;
  // `m` 是唯一会被重新赋值的（非法/负边距回落默认值），所以只有它是 let。
  let m = Number(marginMs);
  if (!isFinite(m) || m < 0) m = FUSHI_CLIP_WINDOW_MARGIN_MS;
  return { startMs: Math.max(0, s - m), endMs: e + m };
}

// 「本页的原始媒体能不能被服务端按时间窗裁出句子音频/动图」——制卡该走批量剪辑队列、还是
// 立即出卡，判据是**它**，不是站点名枚举。
//
// 起因：`bridge-shim.js` 过去写的是 `site !== 'youtube' && site !== 'netflix'`，把三件互相
// 正交的能力绑死在一个枚举上：① 有没有可裁的原始流 ② 有没有当前字幕行 ③ 能不能取当前解码帧。
// 于是 bilibili.com（②③ 俱全、只缺①）整个落进「普通网页」分支，制卡既没有例句也没有封面。
// 每加一个站点就得改一处 if，正是那种应该被数据结构消掉的特殊情况。
//
// `mode` 区分两种可裁法，**不是**画质差别而是交互差别：
//   'queue'     — 必须先回放/逐条解析才能拿到媒体，只适合「看完一集统一生成」。Netflix 是
//                 DRM 只能录制回放；YouTube 是既有批量行为，保持原样不动。
//   'immediate' — 服务端拿 {id, 时间窗} 就能直接从原始流裁，点一下即出卡，不必攒队列。
// 返回 null = 本页没有可裁的原始流；此时仍然出卡，只是媒体只有「当前解码帧」那一张图。
//
// 加新站点 = 这里加一行 + 服务端加一个对应的 clip miner，别处不用改。
function fushiClipSource() {
  const site = fushiSite();
  if (site === 'youtube') {
    const id = fushiYoutubeId();
    return id ? { kind: 'youtube', id: id, mode: 'queue' } : null;
  }
  if (site === 'netflix') {
    const id = fushiNetflixId();
    return id ? { kind: 'netflix', id: id, mode: 'queue' } : null;
  }
  if (site === 'bilibili') {
    const b = fushiBilibiliRef();
    // 非 DRM，服务端拿 {bvid, 分P, 时间窗} 就能从原始 DASH 音轨直接裁 → 点一下即出卡。
    return b ? { kind: 'bilibili', id: b.bvid, part: b.page, mode: 'immediate' } : null;
  }
  return null;
}
// bilibili.com 稿件页的 `BVxxxxxxxxxx` 与分 P 号。纯 URL 解析，不读页面内部变量
// （`__INITIAL_STATE__` 那类全局在隔离世界里本来也读不到，且随站点改版就会碎）。
// cid 由服务端用 bvid 现查（`x/web-interface/view`），扩展不必知道它。
//
// 只认 `/video/BV...` 稿件页：番剧 `/bangumi/play/ep|ss` 走的是另一套 pgc 接口（epid→cid），
// 服务端还没有对应解析器，这里就不谎报能裁——返回 null，制卡照常出「解码帧 + 例句」的卡。
function fushiBilibiliRef() {
  const m = location.pathname.match(/\/video\/(BV[0-9A-Za-z]{10})/);
  if (!m) return null;
  let page = 1;
  try {
    const p = parseInt(new URL(location.href).searchParams.get('p') || '1', 10);
    if (Number.isFinite(p) && p >= 1) page = p;
  } catch (_) { /* 畸形 URL：按第 1 P */ }
  return { bvid: m[1], page: page };
}
function fushiVideoTimeMs(video) {
  const v = video || document.querySelector('video');
  return v && typeof v.currentTime === 'number' && Number.isFinite(v.currentTime)
    ? Math.round(v.currentTime * 1000)
    : null;
}
// 把字幕 DOM 切成「正文段 + 可选读音」。`textContent` 会把 <rt> 的读音直接拼进正文
// （`<ruby>熱<rt>ねつ</rt></ruby>さまし` → `熱ねつさまし`），于是列表里读音与正文并排成同级
// 文字，查词、制卡 sentence 一起被污染——这正是 app 侧 strip_html_tags.dart 修过的 BUG-1161
// 在 DOM 采样这一侧的孪生。`<rp>` 是给不支持 ruby 的渲染器看的回退括号，同样不是正文。
function fushiCollectCueSegments(node, out) {
  for (const child of node.childNodes || []) {
    if (child.nodeType === 3) {
      const value = child.nodeValue || '';
      if (value) out.push({ text: value, reading: '' });
      continue;
    }
    if (child.nodeType !== 1) continue;
    const tag = (child.tagName || '').toLowerCase();
    if (tag === 'rt' || tag === 'rp' || tag === 'rtc') continue; // 读音/回退括号不是正文
    if (tag === 'ruby') {
      let base = '';
      let reading = '';
      for (const part of child.childNodes || []) {
        if (part.nodeType === 3) { base += part.nodeValue || ''; continue; }
        if (part.nodeType !== 1) continue;
        const partTag = (part.tagName || '').toLowerCase();
        if (partTag === 'rt') { reading += part.textContent || ''; continue; }
        if (partTag === 'rp') continue;
        if (partTag === 'rtc') {
          // <rtc> 是读音容器，其中的 <rt> 才是读音本身。
          for (const inner of part.querySelectorAll ? part.querySelectorAll('rt') : []) {
            reading += inner.textContent || '';
          }
          continue;
        }
        base += part.textContent || ''; // <rb> 等 base 侧容器
      }
      if (base) out.push({ text: base, reading: reading });
      continue;
    }
    fushiCollectCueSegments(child, out);
  }
  return out;
}

// 当前屏幕上的字幕：{ text: 正文（不含读音）, ruby: 段序列 }。
function fushiSubtitleSegmentsNow() {
  // Netflix: .player-timedtext；YouTube: .ytp-caption-segment / .captions-text。
  const sels = ['.player-timedtext', '.ytp-caption-segment', '.captions-text'];
  for (const sel of sels) {
    const nodes = document.querySelectorAll(sel);
    if (!nodes.length) continue;
    const segments = [];
    for (const n of nodes) fushiCollectCueSegments(n, segments);
    const text = segments.map((seg) => seg.text).join('');
    if (text.trim()) return { text: text.trim(), ruby: segments };
  }
  return { text: '', ruby: [] };
}

function fushiSubtitleTextNow() {
  return fushiSubtitleSegmentsNow().text;
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
    justEndedCue: null,
    lastSegments: null,
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
  state.justEndedCue = null; // 只在本次采样内有效（见 fushiLiveCueEnd）
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
  const snapshot = fushiSubtitleSegmentsNow();
  const text = snapshot.text;
  state.lastSegments = snapshot.ruby;

  if (state.replayPending) {
    // seek/remount 后字幕 DOM 可能短暂为空；等第一份真实快照再消费 replay 门。
    if (!text) return;
    state.replayPending = false;
    state.lastDomText = text;
    state.curText = text;
    state.curStartV = nowV;
    fushiLiveCueStart(state, text, nowV);
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
    if (state.curText) fushiLiveCueStart(state, state.curText, nowV);
    return;
  }
  if (state.curText) {
    fushiPushCueV(state, state.curText, state.curStartV, nowV); // 上一句定格
    fushiLiveCueEnd(state, nowV); // TODO-1363：live 轨同句定格真实 end
  }
  state.lastDomText = text;
  state.curText = text;
  state.curStartV = text ? nowV : 0;
  if (text) fushiLiveCueStart(state, text, nowV); // TODO-1363：新句出现即入 live 轨（暂定 end）
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

// ── 整轨优先仲裁（TODO-1219 收口）──
// 整集拦截轨是主路径，DOM 实时采样只是兜底。判据与选轨逻辑收在 subtitle-adapters.js
// 的共享纯函数里（findCueIndexAt / pickPrimaryCueTrack），面板与此处共用同一份。

// 面板在场时以它暴露的活动轨为准——那份已应用用户设的时轴偏移，语言也与用户正在读的
// 一致；面板未加载或未开启时自取第一条非 live 轨（偏移默认 0，不影响正确性）。
// 认领结果缓存：`videoKey -> lang`。认领一次就钉住，避免每次查词重扫几十条轨。
let fushiClaimedTrackKey = null;
let fushiClaimedTrackLang = null;

// 用**屏幕上正在显示的那句**去认领「哪条整轨是用户在读的那条」。
//
// 为什么必须有这一步：netflix-bridge 对 manifest 里的 timedtexttracks **全量**
// fetchCues，textTracks 收割还会把 disabled 轨临时升 hidden——一集下来 store 里
// 躺着几十种语言，每条都覆盖整条时间轴。没有这道门时选轨兜底是 `lang` **字典序**，
// 与「用户在读哪条」毫无关系：开日文字幕看片，查词制卡的句子会取自 `ar`/`cs`。
// 那是把「拿到了某条轨」当成了「拿到了用户那条轨」，比阶段推断更隐蔽。
//
// 认不上就返回 null —— 调用方回落 DOM 采样，也就是本次改造前的行为。这道门只会
// **收窄**整轨的适用面，不会让任何原本能工作的路径变差。
// 在 nowV 时刻，哪条整轨的当前 cue 与屏幕上这句对得上。对不上返回 null。
function fushiMatchFullTrackLangAt(videoKey, nowV, onScreenText) {
  const prefix = String(videoKey) + '|';
  for (const key in fushiEpisodeCues) {
    if (key.indexOf(prefix) !== 0) continue;
    const lang = key.slice(prefix.length);
    if (lang === FUSHI_LIVE_LANG) continue;
    const cues = fushiEpisodeCues[key];
    if (!cues || !cues.length) continue;
    const idx = findCueIndexAt(cues, nowV);
    if (idx < 0) continue;
    const cue = cues[idx];
    if (!cue || !cue.text) continue;
    if (fushiCueTextRelated(String(cue.text), String(onScreenText))) return lang;
  }
  return null;
}

function fushiClaimFullTrackLang() {
  const videoKey = fushiVideoKey();
  if (!videoKey) return null;
  if (fushiClaimedTrackKey !== videoKey) {
    fushiClaimedTrackKey = null;
    fushiClaimedTrackLang = null;
  }
  const onScreen = fushiCurrentCueWindowV();
  const nowV = fushiVideoTimeMs();
  // 屏幕上没有字可比（静音段 / 字幕未渲染）：不改判，沿用已认领的那条。
  if (!onScreen || !onScreen.text || nowV === null) return fushiClaimedTrackLang;
  const matched = fushiMatchFullTrackLangAt(videoKey, nowV, String(onScreen.text));
  if (matched) {
    fushiClaimedTrackKey = videoKey;
    fushiClaimedTrackLang = matched;
    return matched;
  }
  // 屏幕上明明有字、却没有一条整轨对得上 —— 之前那次认领已经失效（用户中途换了
  // 字幕语言）。**这里必须作废**：只在成功路径写、失败路径不复位，就是本仓
  // 「bool 镜像只有成功路径复位」那个反复出现的坑。作废后回落 DOM 采样。
  fushiClaimedTrackKey = null;
  fushiClaimedTrackLang = null;
  return null;
}

function fushiActiveFullTrackCues() {
  try {
    if (typeof window.fushiActiveFullTrack === 'function') {
      const t = window.fushiActiveFullTrack();
      if (t && t.cues && t.cues.length) return t.cues;
    }
  } catch (_) {}
  // 面板不在场时，只有**被认领**的那条轨才够格当主路径。
  const claimed = fushiClaimFullTrackLang();
  if (!claimed) return null;
  const picked = pickPrimaryCueTrack(
    fushiEpisodeCues, fushiVideoKey(), FUSHI_LIVE_LANG, claimed);
  return picked && picked.lang === claimed ? picked.cues : null;
}

// 该视频是否已有**可用**的整轨（live 伪轨不算，认领不上的也不算）。
//
// live 采样据此降级（见 fushiLiveCueStart）。判据必须是「有一条对得上屏幕的轨」而
// 不是「有任意一条非 live 轨」：后者会被一条只有 1 句的分片轨（HLS/Shaka 渐进加载，
// 轨只增不减）或几十条看不懂的语言轨满足，把唯一跟屏幕一致的 live 轨永久掐掉。
function fushiHasFullEpisodeTrack(videoKey) {
  const claimed = fushiClaimFullTrackLang();
  if (!claimed) return false;
  return !!pickPrimaryCueTrack(fushiEpisodeCues, videoKey, FUSHI_LIVE_LANG, claimed);
}

/**
 * 当前播放时刻在整轨中的精确 [startMs,endMs] 窗。整轨缺席、或当前时刻落在字幕间隙
 * （静音段）时返回 null，交由调用方回落 DOM 采样窗。
 * @returns {{text:string,startV:number,endV:number}|null}
 */
function fushiFullTrackWindowAt() {
  const cues = fushiActiveFullTrackCues();
  if (!cues) return null;
  const nowV = fushiVideoTimeMs();
  if (nowV === null) return null;
  const idx = findCueIndexAt(cues, nowV);
  if (idx < 0) return null;
  const cue = cues[idx];
  return { text: cue.text || '', startV: cue.startMs, endV: cue.endMs };
}
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
function fushiLiveCueStart(state, text, startV) {
  if (!text) {
    state.liveCue = null;
    state.liveCueReplay = false;
    return;
  }
  // 整轨优先：已有整集拦截/textTracks 收割的真语言轨时，DOM 实时采样退居兜底，不再往
  // `|live` 伪轨写——两条来源并存会让面板多出一条重复的抖动轨（用户诉求：实时采集只能
  // 是降级）。注意 cueHist 仍照常采样，fushiCurrentCueWindowV 是整轨查不中（字幕间隙、
  // 整轨尚未到达）时的最后退路，所以这是降级不是砍掉退路。
  if (fushiHasFullEpisodeTrack(state.key)) {
    state.liveCue = null;
    state.liveCueReplay = false;
    return;
  }
  const key = state.key + '|' + FUSHI_LIVE_LANG;
  const track = fushiEpisodeCues[key] || (fushiEpisodeCues[key] = []);
  // 「这句我采过吗」：文本相关（逐字扩长的前缀关系）且落进已有那条的整段时间窗
  // [startMs-750, endMs+750]。判据用整段区间而不是 fushiSortedCueInsert 的「句首相差 <750ms」
  // 窄窗，是因为 startMs 记的是**这句在 DOM 里被我们看到的时刻**：上一次经过若是 seek 落在句
  // 中，它就比真实句首晚了一两秒；下一次正常播放从句首采到它，两个起点差出窄窗，同一句于是
  // 在轨里留下两条（用户截图：来回跳转后 12:49 同一句两行）。
  // 例外只有一个：同一次采样里刚定格的上一条要跳过——DOM 在同一时刻把 abcdef 更正/缩短成
  // abc 是**新句**而不是历史重复（justEndedCue 每次采样开头清空，只在本次采样内有效）。
  for (const existing of track) {
    if (existing === state.justEndedCue) continue;
    // 向后容差 750ms、**向前 3s**：两个方向的偏差成因不同。向后只是采样抖动；向前是因为上一次
    // 经过时 seek 落在句中，那条的 startMs 比真实句首晚了一截，这一次从句首采到它，新起点反而
    // 更早——只留 750ms 的话正好从窗口前沿漏出去，于是同一句入轨两次。
    if (startV < existing.startMs - 3000 || startV > existing.endMs + 750) continue;
    if (!fushiCueTextRelated(existing.text, text)) continue;
    // 命中历史：只读跟随页面快照，既不重复入轨也不动旧句的窗。
    state.liveCue = null;
    state.liveCueReplay = true;
    return;
  }
  const cue = { startMs: startV, endMs: startV + 1500, text: text };
  fushiAttachCueRuby(cue, state.lastSegments);
  if (fushiSortedCueInsert(track, cue)) {
    state.liveCue = cue;
    state.liveCueReplay = false;
    fushiNotifyPanel(key);
  } else {
    state.liveCue = null; // 已见过的句：不重复入轨，也不动旧句窗
    state.liveCueReplay = true;
  }
}
// 段序列只有在拼接结果与 cue 正文完全一致时才挂上去：DOM 快照是**整句**，而逐字扩长被切成
// 下一行时 cue.text 只是后缀，两者错位就会把振假名标到别的字上。宁可这行不画振假名。
function fushiAttachCueRuby(cue, segments) {
  if (!cue || !Array.isArray(segments) || !segments.length) return;
  const joined = segments.map((seg) => seg.text).join('').trim();
  if (joined !== cue.text) return;
  if (!segments.some((seg) => seg.reading)) return; // 整句没有注音：不必带这份数据
  cue.ruby = segments;
}

function fushiLiveCueAppend(state, addedText, nowV) {
  if (!state.liveCue || state.liveCueReplay || !addedText) return false;
  state.liveCue.text += addedText;
  fushiAttachCueRuby(state.liveCue, state.lastSegments);
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
  // 本次采样内刚定格的这条：紧随其后的 fushiLiveCueStart 不得把它当成「历史里的同一句」。
  state.justEndedCue = state.liveCue;
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
      const raw = String(c.text || '');
      const text = stripCueTags(raw);
      if (!text) continue;
      const cue = { startMs: Math.round(c.startTime * 1000), endMs: Math.round(c.endTime * 1000), text: text };
      if (typeof splitCueRuby === 'function') fushiAttachCueRuby(cue, splitCueRuby(raw));
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
