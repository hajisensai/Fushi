// TODO-1000 per-site 字幕 + 时间戳读取。Netflix 字幕是明文 DOM（非 DRM），可直接读；
// 只有视频帧/音频受 DRM。与 bridge-shim.js 同 content-script isolated world，顶层 function
// 互相可见（挖词时由 bridge-shim.js 的 mineEntry 分支调用）。

function extractNetflixCueText(container) {
  if (!container) return '';
  const spans = container.querySelectorAll('.player-timedtext-text-container span, span');
  return Array.from(spans)
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

// 去行内标签（<c>、<i>、<b.bg_transparent> …）与方向/零宽控制字符，最小实体解码。
function stripCueTags(text) {
  return String(text || '')
    .replace(/<[^>]*>/g, '')
    .replace(/[‎‏]/g, '')
    .replace(/&lrm;|&rlm;/g, '')
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .trim();
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

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    extractNetflixCueText,
    currentVideoTimeMs,
    netflixVideoIdFromPath,
    netflixSubtitleContainer,
    netflixVideoEl,
    parseSubtitleTimestamp,
    stripCueTags,
    parseWebVtt,
    parseTtml,
  };
}
