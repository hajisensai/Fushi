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
  // 同源导航（切下一集）会让上一个 tabCapture 流的轨道 end，但 stream 变量仍是个 truthy 对象。
  // 只有 stream.active 才算「已在录」直接复用；否则先把这个死流拆掉再重新 getUserMedia，
  // 不然 nfEnsureCapture 会以为还在录 → 之后每段都从死流录出黑/空片（跨集失败根因）。
  if (stream && stream.active) return { ok: true, already: true };
  if (stream) {
    try { stream.getTracks().forEach((t) => t.stop()); } catch (_) {}
    stream = null;
    if (audioPlaybackCtx) { try { audioPlaybackCtx.close(); } catch (_) {} audioPlaybackCtx = null; }
    recorder = null;
    chunks = [];
  }
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: {
      mandatory: {
        chromeMediaSource: 'tab', chromeMediaSourceId: streamId,
        // TODO-1145：捕获分辨率是整条 Netflix 制卡链路的支配性限制器——offscreen 录
        // 出的 webm 只有这个分辨率，下游 GIF 转码（gifWidth）/单帧再高也无法超采源。
        // 用户决策：上限对齐 app 内视频制卡（本地源典型 1080p，静帧封顶
        // downsampleCardScreenshot 长边 2000，1920 原样透传）——提到 1920×1080。
        // max* 只是上限不放大：低清源仍按源分辨率录。
        maxWidth: 1920, maxHeight: 1080, maxFrameRate: 12,
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
  // V16#3 防孤儿：上一段 recorder 若因异常未经 endClip 收口仍在录，先强停并解绑再新建，
  // 否则直接覆盖 recorder 变量会让旧 MediaRecorder 成孤儿、仍在流上跑（内存/流泄漏）。
  if (recorder && recorder.state !== 'inactive') {
    try { recorder.onstop = null; recorder.ondataavailable = null; recorder.stop(); } catch (_) {}
  }
  recorder = null;
  chunks = [];
  clipStartWall = Date.now();
  recorder = new MediaRecorder(stream, {
    mimeType: mime, videoBitsPerSecond: 5625000, audioBitsPerSecond: 128000,
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
    try {
      recorder.stop();
    } catch (_) {
      // V16 遗留缺口：stop() 抛异常时若只 resolve，第 85 行刚挂的 onstop、这个坏
      // recorder、滞留的 chunks 都成孤儿仍挂在流上（下一段靠 beginClip 的孤儿守卫才被动
      // 收；但 chunks 陈旧数据会污染）。与 beginClip/stopCapture 对称，就地解绑清理。
      recorder.onstop = null;
      recorder.ondataavailable = null;
      recorder = null;
      chunks = [];
      resolve({ ok: false, error: 'stop failed' });
    }
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
