// Fushi 内置网页播放器「软件 DRM 档」EME 垫片（document-start、主世界，必须先于站点任何脚本）。
//
// 用途：制卡 / 增强环境要能捕获帧，而硬件级 DRM（PlayReady 3000 / Widevine HW_SECURE_*）走受保护输出，
// 帧对任何捕获都是黑的。本垫片让站点只拿得到软件级 keySystem：
//   · 拒绝 com.microsoft.playready*（Netflix 在 Edge UA 下只试 PlayReady，被拒后不试 Widevine——
//     所以调用方还必须把 UA 换成 Chrome 的，见 web_video_fushi_page.dart）；
//   · Widevine 的 HW_SECURE_* robustness 降成 SW_SECURE_CRYPTO；
//   · mediaCapabilities.decodingInfo 对 playready 报 unsupported，免得站点按能力探测选到硬件档。
// 站点在页面加载时就抓走原始 requestMediaKeySystemAccess 引用，运行期再打补丁拦不到——这就是
// 「必须 document-start 注入」的原因（2026-08-29 实测）。
(function () {
  if (window.__fushiEmeShim) return;
  window.__fushiEmeShim = true;
  window.__fushiEmeLog = [];
  var log = function (s) { try { window.__fushiEmeLog.push(String(s)); } catch (_) {} };
  var soften = function (caps) {
    return (caps || []).map(function (v) {
      var r = v && v.robustness ? String(v.robustness) : '';
      return /HW_SECURE/.test(r) ? Object.assign({}, v, { robustness: 'SW_SECURE_CRYPTO' }) : v;
    });
  };
  var proto = Navigator.prototype;
  var orig = proto.requestMediaKeySystemAccess;
  var patched = function (ks, cfgs) {
    log('rmksa:' + ks);
    if (/playready/i.test(String(ks))) {
      return Promise.reject(new DOMException('Unsupported keySystem', 'NotSupportedError'));
    }
    var softened = (cfgs || []).map(function (c) {
      return Object.assign({}, c, {
        videoCapabilities: soften(c.videoCapabilities),
        audioCapabilities: soften(c.audioCapabilities),
      });
    });
    return orig.call(this, ks, softened);
  };
  proto.requestMediaKeySystemAccess = patched;
  try { navigator.requestMediaKeySystemAccess = patched; } catch (_) {}
  try {
    var ocmk = MediaKeySystemAccess.prototype.createMediaKeys;
    MediaKeySystemAccess.prototype.createMediaKeys = function () {
      try {
        var c = this.getConfiguration();
        log('createMediaKeys:' + this.keySystem + ':' +
          (c.videoCapabilities || []).map(function (v) { return v.robustness; }).join('/'));
      } catch (_) { log('createMediaKeys:' + this.keySystem); }
      return ocmk.call(this);
    };
  } catch (_) {}
  if (navigator.mediaCapabilities && navigator.mediaCapabilities.decodingInfo) {
    var od = navigator.mediaCapabilities.decodingInfo.bind(navigator.mediaCapabilities);
    navigator.mediaCapabilities.decodingInfo = function (q) {
      var k = q && q.keySystemConfiguration && q.keySystemConfiguration.keySystem;
      if (k && /playready/i.test(String(k))) {
        log('decodingInfo:' + k);
        return Promise.resolve({ supported: false, smooth: false, powerEfficient: false, keySystemAccess: null });
      }
      return od(q);
    };
  }
})();
