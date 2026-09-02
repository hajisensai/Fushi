// 从网页 `<video>` 取**当前解码帧**（制卡封面）。隔离世界，站点无关。
//
// 这不是截屏，也不是录屏。`drawImage(video, …)` 读的是解码后的那一帧本身：
//   · 尺寸是 `videoWidth × videoHeight`（**流的原生分辨率**），与窗口大小、CSS 缩放、
//     是否全屏、是否被别的窗口挡住全都无关——4K 源就是 3840×2160；
//   · 弹幕层、播放器控件、网页字幕层、我们自己的字幕覆盖层都是 video 的 **DOM 兄弟节点**，
//     不在这份像素里，所以帧是干净的画面；
//   · 不需要 tabCapture / desktopCapture 权限，不惊动录制指示器，不受 12fps、
//     1920×1080 那套 tabCapture 上限支配（`offscreen.js` 那条 Netflix 录屏路的枷锁）。
//
// 与既有三条封面来源的关系：本模块是「浏览器里的 `controller.screenshot()`」——app 内视频页
// 用 media_kit 拿 libmpv 解码帧（`video_player_controller.dart` 的 `screenshot()`），这里用
// canvas 拿浏览器解码帧，两者都是解码帧、都不是屏幕像素。
//
// **取不到就返回 null，绝不退化成截屏**：EME/DRM 保护的视频（Netflix 等）画不进 canvas，
// 浏览器要么抛 SecurityError（canvas 被跨源污染），要么画出全黑帧。两种都判失败 → 上层照旧
// 出纯文本卡或走它自己的录制路，不会把一张黑图或一张屏幕截图塞给用户当封面。
//
// 服务端对 `providedCoverBytes` **只换编码、不改尺寸**（`immersion_mining_engine.dart:289`
// 那段注释：「那些字节大多已经降过采样，再压一遍是越权」），所以降采样责任在**产字节这一侧**，
// 也就是本模块。上限取 1920 长边，与 Netflix tabCapture 路径的既有上限同值。

// 封面长边上限（像素）。超过就等比缩到它。
// 与 `offscreen.js` 的 tabCapture maxWidth 同值：同一个 Anki 卡片封面，两条来源不该给出
// 数量级不同的图。真要更高清得先让服务端 `transcodeCardScreenshotAsync` 认「这是原始帧、
// 按用户 miningImageQuality 档降」这件事，那是另一件事，不在这里偷偷放大。
var FUSHI_FRAME_MAX_LONG_EDGE = 1920;

// JPEG 质量。0.92 是「肉眼无损」与体积的常用折中；封面还要经服务端按用户静图格式偏好
// 转一次编码（`transcodeCardScreenshotAsync`），这里不必压得太狠。
var FUSHI_FRAME_JPEG_QUALITY = 0.92;

// 纯函数：把源尺寸等比夹进长边上限。
// 源尺寸非正数（video 尚未拿到元数据）返回 null —— 调用方据此判「此刻取不到帧」。
// 长边已经在上限内则原样返回（`scaled:false`），绝不放大。
function fushiFrameTargetSize(srcWidth, srcHeight, maxLongEdge) {
  var w = Number(srcWidth);
  var h = Number(srcHeight);
  if (!isFinite(w) || !isFinite(h) || w <= 0 || h <= 0) return null;
  var limit = Number(maxLongEdge);
  if (!isFinite(limit) || limit <= 0) limit = FUSHI_FRAME_MAX_LONG_EDGE;
  var long = Math.max(w, h);
  if (long <= limit) {
    return { width: Math.round(w), height: Math.round(h), scaled: false };
  }
  var k = limit / long;
  // 至少 1px：极端长条比例（k 很小的一侧）四舍五入到 0 会让 canvas 尺寸非法。
  return {
    width: Math.max(1, Math.round(w * k)),
    height: Math.max(1, Math.round(h * k)),
    scaled: true,
  };
}

// 纯函数：`data:image/jpeg;base64,XXXX` → `XXXX`。
// 不是 data URL、或 base64 段为空则返回 null（canvas 在画不出内容时会给出退化串）。
function fushiDataUrlToBase64(dataUrl) {
  if (typeof dataUrl !== 'string') return null;
  var i = dataUrl.indexOf(',');
  if (i < 0 || !/^data:image\//i.test(dataUrl)) return null;
  var b64 = dataUrl.slice(i + 1);
  return b64.length > 0 ? b64 : null;
}

// 能力探测：这个 video 此刻能不能取到帧。
// `readyState >= 2`（HAVE_CURRENT_DATA）保证当前帧已解码；`videoWidth/Height` 在元数据到达
// 前是 0。两者都不满足就是「还没到能取帧的时候」，不是错误。
function fushiVideoFrameCapturable(video) {
  if (!video) return false;
  var w = video.videoWidth;
  var h = video.videoHeight;
  if (!w || !h) return false;
  return typeof video.readyState === 'number' && video.readyState >= 2;
}

// 取当前解码帧 → JPEG base64。失败一律返回 null（见文件头：绝不退化成截屏）。
// 返回 `{ base64, width, height, sourceWidth, sourceHeight }`——尺寸随字节一起回传，
// 便于诊断「卡上这张图到底是几分之几的原始分辨率」，不用去猜。
function fushiCaptureVideoFrame(video, options) {
  if (!fushiVideoFrameCapturable(video)) return null;
  var opts = options || {};
  var size = fushiFrameTargetSize(
    video.videoWidth, video.videoHeight,
    opts.maxLongEdge || FUSHI_FRAME_MAX_LONG_EDGE);
  if (!size) return null;
  try {
    var canvas = document.createElement('canvas');
    canvas.width = size.width;
    canvas.height = size.height;
    var ctx = canvas.getContext('2d');
    if (!ctx) return null;
    // 缩放质量：默认的 low 在 4K→1920 这种大比例缩小上会出明显锯齿。
    try {
      ctx.imageSmoothingEnabled = true;
      ctx.imageSmoothingQuality = 'high';
    } catch (_) { /* 老浏览器没有这两个属性，画质差一点不影响正确性 */ }
    ctx.drawImage(video, 0, 0, size.width, size.height);
    // DRM 视频在这里抛 SecurityError（canvas 已被污染）——由外层 catch 收，返回 null。
    var url = canvas.toDataURL('image/jpeg',
      opts.quality || FUSHI_FRAME_JPEG_QUALITY);
    var b64 = fushiDataUrlToBase64(url);
    if (!b64) return null;
    return {
      base64: b64,
      width: size.width,
      height: size.height,
      sourceWidth: video.videoWidth,
      sourceHeight: video.videoHeight,
    };
  } catch (_) {
    // SecurityError（DRM/跨源污染）、canvas 尺寸超实现上限、内存不足都落这里。
    // 一律当「这一帧取不到」，让上层降级，绝不改用截屏。
    return null;
  }
}

// 取「当前页面主视频」的帧。video 选择沿用全仓既有约定 `document.querySelector('video')`
// （`subtitle-providers.js` / `subtitle-panel.js` / `video-shortcuts.js` 都是这一句）——
// 字幕轨、时间窗、快捷键认的是哪个 video，封面就必须是同一个，否则会出现「例句来自 A 视频、
// 封面来自 B 视频」的错配。
function fushiCaptureCurrentFrame(options) {
  var v = typeof document !== 'undefined'
    ? document.querySelector('video') : null;
  return fushiCaptureVideoFrame(v, options);
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FUSHI_FRAME_MAX_LONG_EDGE,
    FUSHI_FRAME_JPEG_QUALITY,
    fushiFrameTargetSize,
    fushiDataUrlToBase64,
    fushiVideoFrameCapturable,
    fushiCaptureVideoFrame,
    fushiCaptureCurrentFrame,
  };
}
