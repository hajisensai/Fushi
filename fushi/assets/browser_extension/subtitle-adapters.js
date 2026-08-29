// TODO-1000 per-site 字幕 + 时间戳读取。Netflix 字幕是明文 DOM（非 DRM），可直接读；
// 只有视频帧/音频受 DRM。与 bridge-shim.js 同 content-script isolated world，顶层 function
// 互相可见（挖词时由 bridge-shim.js 的 mineEntry 分支调用）。

function extractNetflixCueText(container) {
  if (!container) return '';
  const spans = container.querySelectorAll('.player-timedtext-text-container span, span');
  // TODO-1270 Bug A：Netflix 把每行字幕包成「外层定位 span > 内层样式 span」的嵌套结构，
  // 父 span 的 textContent 已含子 span 全文。若把每一层 span 的 textContent 都拼进来，同一句
  // 字幕会按嵌套层数重复（用户报「卡里字幕重复两次」）。只取**叶子** span（无后代 span），
  // 每段文本恰好一次；扁平（无嵌套）时行为不变。
  const leaves = Array.from(spans).filter(
    (s) => !(s.querySelector && s.querySelector('span')));
  return leaves
    .map((s) => s.textContent || '')
    .join('')
    .trim();
}

function currentVideoTimeMs(video) {
  if (!video || typeof video.currentTime !== 'number') return null;
  return Math.round(video.currentTime * 1000);
}

function netflixVideoIdFromPath(pathname) {
  const m = (pathname || '').match(/\/watch\/(\d+)/);
  return m ? m[1] : null;
}

// 浏览器运行时入口（非测试）：定位 Netflix 字幕容器 + 播放器 video 元素。
function netflixSubtitleContainer() {
  return typeof document !== 'undefined' ? document.querySelector('.player-timedtext') : null;
}
function netflixVideoEl() {
  return typeof document !== 'undefined' ? document.querySelector('video') : null;
}

// BUG-676（TODO-1361 ③）：网飞制卡的「视频名」= Anki `{document-title}` 字段。扩展 mineClip 此前
// 不发 documentTitle → 服务端 buildImmersionRequest 回落成字面「Netflix」(immersion_capture_channel.dart:90)，
// 卡片视频名全是「Netflix」而非剧名（YouTube 由服务端解析真实标题，故有剧名 → 二者不一致）。
// 这里从播放器标题栏 [data-uia="video-title"] 抽「系列名 - 集信息」(语言无关)，回落 document.title
// 去掉尾部「- Netflix」。传 [doc] 便于 node 单测（缺省用全局 document）。
function netflixDocumentTitle(doc) {
  const d = doc || (typeof document !== 'undefined' ? document : null);
  if (!d || typeof d.querySelector !== 'function') return '';
  let el = null;
  try { el = d.querySelector('[data-uia="video-title"]'); } catch (_) { el = null; }
  if (el) {
    const h4 = typeof el.querySelector === 'function' ? el.querySelector('h4') : null;
    const series = h4 ? String(h4.textContent || '').trim() : '';
    const spans = typeof el.querySelectorAll === 'function' ? el.querySelectorAll('span') : [];
    const parts = [];
    for (const s of spans) {
      const t = String((s && s.textContent) || '').trim();
      if (t && parts.indexOf(t) < 0) parts.push(t);
    }
    const episode = parts.join(' ').trim();
    const combined = [series, episode].filter(Boolean).join(' - ');
    if (combined) return combined;
    const whole = String(el.textContent || '').trim();
    if (whole) return whole;
  }
  return String((d.title) || '').replace(/\s*[-–—|]\s*Netflix\s*$/i, '').trim();
}


// ── TODO-1219 P1：整集字幕纯函数解析器 ──
// 主世界 netflix-bridge.js 抓来 timedtext 原文（WebVTT / TTML），交给隔离世界这里解析。
// 纯函数、正则实现，绝不依赖 DOMParser（node 测试环境无 DOMParser，隔离世界也保持一致）。
// 统一输出 [{ startMs:number, endMs:number, text:string }]。

// 解析单个时间戳为毫秒。支持：
//   WebVTT/SRT 时钟：HH:MM:SS.mmm / HH:MM:SS,mmm / MM:SS.mmm
//   TTML 偏移：<num>s（秒） / <num>ms / <num>t（tick，需 tickRate，TTML 默认 1e7）
function parseSubtitleTimestamp(raw, tickRate) {
  if (raw == null) return null;
  const s = String(raw).trim();
  if (!s) return null;
  const off = s.match(/^([0-9]+(?:\.[0-9]+)?)(ms|s|t)$/);
  if (off) {
    const n = parseFloat(off[1]);
    const unit = off[2];
    if (unit === 'ms') return Math.round(n);
    if (unit === 's') return Math.round(n * 1000);
    // 't'（tick）：ms = n / tickRate * 1000；TTML 默认 tickRate 常见为 1e7。
    const rate = tickRate && tickRate > 0 ? tickRate : 10000000;
    return Math.round((n / rate) * 1000);
  }
  const clock = s.match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?$/);
  if (clock) {
    const h = clock[1] ? parseInt(clock[1], 10) : 0;
    const m = parseInt(clock[2], 10);
    const sec = parseInt(clock[3], 10);
    const frac = clock[4] ? parseInt((clock[4] + '000').slice(0, 3), 10) : 0;
    return (h * 3600 + m * 60 + sec) * 1000 + frac;
  }
  return null;
}

// 注音（振假名）标注元素：`<rt>` 是读音本身，`<rp>` 是给不支持 ruby 的渲染器看的回退括号，
// `<rtc>` 是读音容器。三者的内容**都不是正文**——只有 ruby base 是。光删标签保留内容会把读音
// 拼进正文（`<ruby>震<rt>ふる</rt></ruby>` → `震ふる`），于是列表里读音与正文并排成同级文字，
// 查词、制卡 sentence、字幕匹配一起被污染。app 侧 strip_html_tags.dart 早为此收过口
// （BUG-1161），这里是它在扩展侧的孪生实现，判据逐条对齐：
//  - 一条规则同时吃「显式闭合 <rt>ふる</rt>」与「隐式闭合 <ruby>震<rt>ふる</ruby>」；
//  - 开标签属性段写成 (?:[^<>/]|/(?!>))* 而不是 [^>]*：不许跨越 `<`（缺 `>` 的畸形开标签不能
//    借后面的 `>` 凑合法，否则会把正文一路吃光），也不许把自闭合 `<rt/>` 当成有内容的开标签。
//    认不出的形态整体不匹配 → 退回「只删标签」的旧行为，宁可多留一个假名也不吃掉正文。
const RUBY_ANNOTATION = '<(?:rt|rp|rtc)\\b(?:[^<>/]|/(?!>))*>' +
  '(?:(?!</?(?:ruby|rt|rp|rtc)\\b)[\\s\\S])*(?:</(?:rt|rp|rtc)\\s*>)?';

// 方向/零宽控制字符与最小实体解码（不碰标签）。
function decodeCueEntities(text) {
  return String(text || '')
    .replace(/[‎‏]/g, '')
    .replace(/&lrm;|&rlm;/g, '')
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&');
}

// 去掉行内标签（<c>、<i>、<b.bg_transparent> …）并解码实体；注音内容已在上游剔除。
function stripInlineTags(text) {
  return decodeCueEntities(String(text || '').replace(/<[^>]*>/g, ''));
}

// 把一行字幕切成「正文段 + 可选读音」的序列：`<ruby>震<rt>ふる</rt></ruby>える` →
// [{text:'震', reading:'ふる'}, {text:'える', reading:''}]。读音单独留着是为了让字幕列表/覆盖层
// 能画出真正的 <ruby>（振假名在正文上方），而 cue.text 仍然只有正文——两个用途各取所需，
// 不再让读音以同级文字的身份混进正文。没有注音时返回单段（reading 为空）。
function splitCueRuby(text) {
  const source = String(text || '');
  const segments = [];
  const rubyBlock = /<ruby\b(?:[^<>/]|\/(?!>))*>([\s\S]*?)<\/ruby\s*>/gi;
  let cursor = 0;
  let match;
  const pushPlain = (raw) => {
    const plain = stripInlineTags(raw);
    if (plain) segments.push({ text: plain, reading: '' });
  };
  while ((match = rubyBlock.exec(source)) !== null) {
    pushPlain(source.slice(cursor, match.index));
    const inner = match[1];
    // base = 注音整段剔除后剩下的内容；reading = 各 <rt> 的内容按序拼接（<rp> 的回退括号
    // 不是读音，丢掉）。
    const base = stripInlineTags(inner.replace(new RegExp(RUBY_ANNOTATION, 'gi'), ''));
    let reading = '';
    const rt = /<rt\b(?:[^<>/]|\/(?!>))*>((?:(?!<\/?(?:ruby|rt|rp|rtc)\b)[\s\S])*)/gi;
    let rtMatch;
    while ((rtMatch = rt.exec(inner)) !== null) reading += stripInlineTags(rtMatch[1]);
    if (base) segments.push({ text: base, reading: reading });
    else pushPlain(inner);
    cursor = match.index + match[0].length;
  }
  pushPlain(source.slice(cursor));
  // 不变式：段拼接 === stripCueTags 的正文。渲染端画的是段、查词/制卡吃的是 cue.text，两者
  // 一旦漂开就会出现「列表上看到的字和查到的词对不上」。畸形注音（`<ruby>漢<rt かん</ruby>`
  // 这类缺 `>` 的输入）会让上面的分段留下标签字面量——那时整行退回单段，宁可不画振假名也
  // 不让两端分岔。
  const joined = segments.map((seg) => seg.text).join('');
  const plain = stripCueTags(source);
  if (joined.trim() !== plain) {
    return plain ? [{ text: plain, reading: '' }] : [];
  }
  return segments;
}

// 行内标签剥离后的**正文**（读音不在其中）。旧签名不变，调用方无需改。
function stripCueTags(text) {
  const withoutAnnotations = String(text || '')
    .replace(new RegExp(RUBY_ANNOTATION, 'gi'), '');
  return stripInlineTags(withoutAnnotations).trim();
}

// WebVTT（Netflix webvtt-lssdh-ios8）→ cues。按空行切块，含 '-->' 的块才是 cue，
// 忽略 WEBVTT / NOTE / STYLE 头块，时间戳行尾部的 align/position 设置一并忽略。
function parseWebVtt(text) {
  const out = [];
  if (!text) return out;
  const blocks = String(text)
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .split(/\n\s*\n/);
  for (const block of blocks) {
    const lines = block.split('\n');
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].indexOf('-->') >= 0) {
        idx = i;
        break;
      }
    }
    if (idx < 0) continue;
    const m = lines[idx].match(/([0-9:.,]+)\s*-->\s*([0-9:.,]+)/);
    if (!m) continue;
    const startMs = parseSubtitleTimestamp(m[1]);
    const endMs = parseSubtitleTimestamp(m[2]);
    if (startMs == null || endMs == null) continue;
    const body = lines
      .slice(idx + 1)
      .map(stripCueTags)
      .filter((s) => s.length)
      .join('\n')
      .trim();
    if (!body) continue;
    out.push({ startMs, endMs, text: body });
  }
  return out;
}

// TTML（Netflix dfxp-ls-sdh / imsc1.1）→ cues。正则抽 <p begin end>…</p>，<br/> 转换行。
function parseTtml(xml) {
  const out = [];
  if (!xml) return out;
  const s = String(xml);
  const rateM = s.match(/ttp:tickRate\s*=\s*"(\d+)"/);
  const tickRate = rateM ? parseInt(rateM[1], 10) : 0;
  const pRe = /<p\b([^>]*)>([\s\S]*?)<\/p>/g;
  let m;
  while ((m = pRe.exec(s)) !== null) {
    const attrs = m[1];
    const beginM = attrs.match(/\bbegin\s*=\s*"([^"]*)"/);
    const endM = attrs.match(/\bend\s*=\s*"([^"]*)"/);
    if (!beginM || !endM) continue;
    const startMs = parseSubtitleTimestamp(beginM[1], tickRate);
    const endMs = parseSubtitleTimestamp(endM[1], tickRate);
    if (startMs == null || endMs == null) continue;
    const body = stripCueTags(m[2].replace(/<br\s*\/?>/gi, '\n')).trim();
    if (!body) continue;
    out.push({ startMs, endMs, text: body });
  }
  return out;
}

// Bilibili.tv 字幕 JSON（asb 伪扩展名 bbjson）→ cues。形状：{body:[{from,to,content}]}，
// from/to 是秒（浮点）。与其它解析器同约：纯函数、坏输入回空数组。
function parseBilibiliJson(text) {
  const out = [];
  let data = null;
  try { data = JSON.parse(String(text || '')); } catch (_) { return out; }
  const body = data && Array.isArray(data.body) ? data.body : [];
  for (const item of body) {
    if (!item || typeof item.from !== 'number' || typeof item.to !== 'number') continue;
    const t = String(item.content || '').trim();
    if (!t) continue;
    out.push({ startMs: Math.round(item.from * 1000), endMs: Math.round(item.to * 1000), text: t });
  }
  return out;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    extractNetflixCueText,
    currentVideoTimeMs,
    netflixVideoIdFromPath,
    netflixSubtitleContainer,
    netflixVideoEl,
    parseSubtitleTimestamp,
    stripCueTags,
    splitCueRuby,
    parseWebVtt,
    parseTtml,
    parseBilibiliJson,
    netflixDocumentTitle,
  };
}
