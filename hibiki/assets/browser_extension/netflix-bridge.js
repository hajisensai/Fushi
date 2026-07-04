// TODO-1000 主世界桥（manifest 里 world:MAIN 注入）：content script 跑在隔离世界，够不到页面的
// window.netflix。这里接 content 发来的 postMessage，用 Netflix **官方播放器 API** seek——走它正规
// 的缓冲/授权通道，和你手动拖进度条一样，不会 desync → 不触发 M7375（直接改 video.currentTime 才炸）。
(function () {
  var ORIGIN = window.location.origin;

  function nfSeek(ms) {
    var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
    var ids = vp.getAllPlayerSessionIds();
    if (!ids || !ids.length) throw new Error('no player session');
    // 取最近的会话（看片会话通常是最后一个）。
    var player = vp.getVideoPlayerBySessionId(ids[ids.length - 1]);
    player.seek(ms);
  }

  window.addEventListener('message', function (e) {
    if (e.origin !== ORIGIN || e.source !== window) return;
    var d = e.data;
    if (!d || d.__hibikiNf !== 'seek') return;
    var ok = true;
    var err = '';
    try { nfSeek(d.ms); } catch (x) { ok = false; err = String(x); }
    try { window.postMessage({ __hibikiNf: 'seekDone', ok: ok, err: err }, ORIGIN); } catch (_) {}
  });
})();
