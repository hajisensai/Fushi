// 内嵌 UI frame 的按需查词闸门（manifest 里 all_frames + match_about_blank 的唯一脚本）。
//
// asbplayer 的「Anki Export」等对话框是铺满视口、吃掉全部指针事件的 about:blank iframe（它特意
// 用 document.write 保持 about:blank，好让查词扩展能注入）。主 content script 只进顶层页，对话框
// 一开顶层就收不到任何鼠标事件，字段里查不了词。但整套脚本也不能进所有 frame：广告 / 嵌入页
// 都会多一份完整实例，侧边栏消息还会被没有视频的 frame 抢答。
//
// 所以这里只做一件事：仅在 about: 子 frame（about:blank / about:srcdoc）里，等用户真按 Shift
// 查词时，请 background 把主 content script 整套注入**这一个** frame（fushiInjectEmbeddedFrame）。
// 注入完成后由 content.js 自己接管 Shift 悬停；第一下悬停只负责唤起，挪一下鼠标即可查词。
(function () {
  try {
    if (window === window.top) return;
    if (String(location.protocol) !== 'about:') return;
    if (window.__fushiExtension || window.__fushiFrameGate) return;
    window.__fushiFrameGate = true;
  } catch (_) { return; }
  var requested = false;
  function request() {
    if (requested || window.__fushiExtension) return;
    requested = true;
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('mousemove', onMove, true);
    try {
      chrome.runtime.sendMessage({ type: 'fushiInjectEmbeddedFrame' }, function () {
        try { void chrome.runtime.lastError; } catch (_) {}
      });
    } catch (_) {}
  }
  function onKey(e) { if (e && e.key === 'Shift') request(); }
  function onMove(e) { if (e && e.shiftKey) request(); }
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('mousemove', onMove, true);
})();
