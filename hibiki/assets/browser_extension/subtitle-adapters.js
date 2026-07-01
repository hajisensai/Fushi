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

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    extractNetflixCueText,
    currentVideoTimeMs,
    netflixVideoIdFromPath,
    netflixSubtitleContainer,
    netflixVideoEl,
  };
}
