// TODO-1000 主世界桥（manifest 里 world:MAIN 注入）：content script 跑在隔离世界，够不到页面的
// window.netflix。这里接 content 发来的 postMessage，用 Netflix **官方播放器 API** seek——走它正规
// 的缓冲/授权通道，和你手动拖进度条一样，不会 desync → 不触发 M7375（直接改 video.currentTime 才炸）。
(function () {
  var ORIGIN = window.location.origin;

  // TODO-1217：player.seek(ms) **返回 ≠ 视频真正重定位完成**。若调完就立刻回 seekDone，content 侧
  // seekTo 会在 Netflix 实际跳转**前**就 resolve → 先 play/录、Netflix 随后才跳 → 用户看到「跳过去又
  // 秒挑回来」的二次跳动。故这里 seek 后轮询 getCurrentTime 逼近目标 ms 再回 seekDone（带超时兜底，
  // 4s 不到位也放行，绝不卡死批量）。
  function nfSeek(ms, done) {
    var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
    var ids = vp.getAllPlayerSessionIds();
    if (!ids || !ids.length) throw new Error('no player session');
    // 取最近的会话（看片会话通常是最后一个）。
    var player = vp.getVideoPlayerBySessionId(ids[ids.length - 1]);
    player.seek(ms);
    var deadline = Date.now() + 4000;
    (function poll() {
      var cur = null;
      try { cur = player.getCurrentTime(); } catch (_) { cur = null; }
      if (cur != null && Math.abs(cur - ms) < 300) { done(); return; } // 已逼近目标：真重定位完成
      if (Date.now() > deadline) { done(); return; } // 超时兜底：不卡死批量
      setTimeout(poll, 80);
    })();
  }

  window.addEventListener('message', function (e) {
    if (e.origin !== ORIGIN || e.source !== window) return;
    var d = e.data;
    if (!d || d.__hibikiNf !== 'seek') return;
    var replied = false;
    var reply = function (ok, err) {
      if (replied) return; replied = true;
      try { window.postMessage({ __hibikiNf: 'seekDone', ok: ok, err: err || '' }, ORIGIN); } catch (_) {}
    };
    try { nfSeek(d.ms, function () { reply(true, ''); }); }
    catch (x) { reply(false, String(x)); }
  });
})();
