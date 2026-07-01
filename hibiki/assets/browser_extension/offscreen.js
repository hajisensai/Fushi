// TODO-1000 Netflix GIF：offscreen 文档里用 tabCapture 录制当前标签页（含 DRM 视频——需用户
// 关硬件加速才非黑），分段滚动保留「最近一段完整 webm」。一键制卡时取该段回给 background，
// 由 Hibiki server ffmpeg 转 GIF+音频。用分段（周期重启）而非丢头块：MediaRecorder 的分片不
// 独立可解，只有「从 start 起的完整序列」才是合法 webm，故每段自包含。

let recorder = null;
let stream = null;
let segMs = 12000; // 每段 12s
let lastSegment = null; // 最近一段完整 webm Blob
let currentChunks = [];
let restartTimer = null;
let mime = 'video/webm;codecs=vp8,opus';

function pickMime() {
  const prefs = [
    'video/webm;codecs=vp9,opus',
    'video/webm;codecs=vp8,opus',
    'video/webm',
  ];
  for (const m of prefs) {
    if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(m)) return m;
  }
  return 'video/webm';
}

function beginSegment() {
  currentChunks = [];
  recorder = new MediaRecorder(stream, { mimeType: mime });
  recorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) currentChunks.push(e.data);
  };
  recorder.onstop = () => {
    if (currentChunks.length) lastSegment = new Blob(currentChunks, { type: mime });
    // 只要流还在，立即开新段（滚动保留最近一段）。
    if (stream && stream.active) beginSegment();
  };
  recorder.start();
  restartTimer = setTimeout(() => {
    if (recorder && recorder.state === 'recording') recorder.stop();
  }, segMs);
}

async function startCapture(streamId) {
  if (recorder) return { ok: true, already: true };
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
  });
  mime = pickMime();
  beginSegment();
  return { ok: true };
}

function stopCapture() {
  if (restartTimer) clearTimeout(restartTimer);
  restartTimer = null;
  try { if (recorder && recorder.state !== 'inactive') recorder.stop(); } catch (_) {}
  recorder = null;
  if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
}

function blobToBase64(blob) {
  return new Promise((resolve) => {
    const r = new FileReader();
    r.onloadend = () => resolve(String(r.result).split(',')[1] || '');
    r.readAsDataURL(blob);
  });
}

async function getRecentClip() {
  if (!lastSegment) return null;
  const base64 = await blobToBase64(lastSegment);
  return { clipBase64: base64, clipDurationMs: segMs };
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.target !== 'offscreen') return false;
  (async () => {
    try {
      if (msg.type === 'startCapture') sendResponse(await startCapture(msg.streamId));
      else if (msg.type === 'stopCapture') { stopCapture(); sendResponse({ ok: true }); }
      else if (msg.type === 'getRecentClip') sendResponse(await getRecentClip());
      else sendResponse({ ok: false, error: 'unknown' });
    } catch (e) {
      sendResponse({ ok: false, error: String(e) });
    }
  })();
  return true;
});
