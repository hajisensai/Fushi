// TODO-1000 批量制卡：offscreen 只做「录一小段完整 webm」。startCapture 建 tabCapture 流；
// 每次 beginClip 新起一个 MediaRecorder（自包含、可解码），endClip 停止并回 base64。
// 不再滚动分段、不暂停、不算墙钟偏移（旧模型的时钟错配就是「完全不行」根因）。
let stream = null;
let audioPlaybackCtx = null;
let recorder = null;
let chunks = [];
let clipStartWall = 0; // 本段 clip 起始墙钟，用来回给服务端真实时长（否则整段裁默认封顶 6s → 长句被截）
let mime = 'video/webm;codecs=vp8,opus';

function pickMime() {
  const prefs = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm'];
  for (const m of prefs) {
    if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(m)) return m;
  }
  return 'video/webm';
}

async function startCapture(streamId) {
  if (stream) return { ok: true, already: true };
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: {
      mandatory: {
        chromeMediaSource: 'tab', chromeMediaSourceId: streamId,
        maxWidth: 640, maxHeight: 360, maxFrameRate: 12,
      },
    },
  });
  // tabCapture 会把标签页音频改道进流 → 默认不再对用户放音。接回扬声器，回放时仍能听到。
  try {
    audioPlaybackCtx = new AudioContext();
    audioPlaybackCtx.createMediaStreamSource(stream).connect(audioPlaybackCtx.destination);
  } catch (_) {}
  mime = pickMime();
  return { ok: true };
}

function stopCapture() {
  try { if (recorder && recorder.state !== 'inactive') { recorder.onstop = null; recorder.stop(); } } catch (_) {}
  recorder = null; chunks = [];
  if (audioPlaybackCtx) { try { audioPlaybackCtx.close(); } catch (_) {} audioPlaybackCtx = null; }
  if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
}

function beginClip() {
  if (!stream) return { ok: false, error: 'no stream' };
  chunks = [];
  clipStartWall = Date.now();
  recorder = new MediaRecorder(stream, {
    mimeType: mime, videoBitsPerSecond: 800000, audioBitsPerSecond: 128000,
  });
  recorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) chunks.push(e.data); };
  recorder.start();
  return { ok: true };
}

function endClip() {
  return new Promise((resolve) => {
    if (!recorder || recorder.state === 'inactive') { resolve({ ok: false, error: 'no clip' }); return; }
    // 时长用墙钟（beginClip→endClip 经过）：这是**上界**（含 seek 稳定/消息往返），服务端整段裁
    // [0, 时长] 时 ffmpeg 到 EOF 即止 → 拿到完整整句、绝不因固定 6s 默认把长句截断。
    const durMs = Math.max(1000, Date.now() - clipStartWall);
    recorder.onstop = async () => {
      const blob = new Blob(chunks, { type: mime });
      chunks = [];
      const b64 = await blobToBase64(blob);
      resolve({ ok: true, clipBase64: b64, clipDurationMs: durMs });
    };
    try { recorder.stop(); } catch (_) { resolve({ ok: false, error: 'stop failed' }); }
  });
}

function blobToBase64(blob) {
  return new Promise((resolve) => {
    const r = new FileReader();
    r.onloadend = () => {
      // data URL: data:<mime>;base64,<数据>。webm 的 MIME 含逗号 → 必须从 ';base64,' 后取，
      // 不能 split(',')[1]（会切在 codecs 逗号上 → 服务端 base64Decode 抛 → HTTP 400）。
      const s = String(r.result || '');
      const i = s.indexOf(';base64,');
      resolve(i >= 0 ? s.slice(i + 8) : (s.split(',').pop() || ''));
    };
    r.readAsDataURL(blob);
  });
}

chrome.runtime.onMessage.addListener((msg, _s, sendResponse) => {
  if (!msg || msg.target !== 'offscreen') return false;
  (async () => {
    try {
      if (msg.type === 'startCapture') sendResponse(await startCapture(msg.streamId));
      else if (msg.type === 'stopCapture') { stopCapture(); sendResponse({ ok: true }); }
      else if (msg.type === 'beginClip') sendResponse(beginClip());
      else if (msg.type === 'endClip') sendResponse(await endClip());
      else if (msg.type === 'isRecording') sendResponse({ ok: true, recording: !!(stream && stream.active) });
      else sendResponse({ ok: false, error: 'unknown' });
    } catch (e) { sendResponse({ ok: false, error: String(e) }); }
  })();
  return true;
});
