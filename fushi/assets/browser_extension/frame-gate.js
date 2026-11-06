// 内嵌 UI frame 的按需查词闸门（manifest 里 all_frames + match_about_blank 的唯一脚本）。
//
// asbplayer 的「Anki Export」等对话框是铺满视口、吃掉全部指针事件的 about:blank iframe（它特意
// 用 document.write 保持 about:blank，好让查词扩展能注入）。主 content script 只进顶层页，对话框
// 一开顶层就收不到任何鼠标事件，字段里查不了词。但整套脚本也不能进所有 frame：广告 / 嵌入页
// 都会多一份完整实例，侧边栏消息还会被没有视频的 frame 抢答。
//
// 所以这里只做一件事：仅在 about: 子 frame（about:blank / about:srcdoc）里，等用户做出**明确的查词
// 手势**——按住 Shift、不按任何鼠标键地移动指针（即 Shift 悬停，content.js 的查词手势本身）——
// 才请 background 把主 content script 整套注入**这一个** frame（fushiInjectEmbeddedFrame）。
// 单按 Shift 键不算：富文本编辑器（TinyMCE / CKEditor 等）的编辑区同样是 about:blank iframe，
// 打大写字母就会按 Shift，不能因此往别人的编辑器里注一整套脚本。按住鼠标键的 Shift 拖动是扩选
// 文字，也不是查词。注入完成后由 content.js 自己接管 Shift 悬停；第一下悬停只负责唤起，挪一下
// 鼠标即可查词。
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
    document.removeEventListener('mousemove', onMove, true);
    try {
      chrome.runtime.sendMessage({ type: 'fushiInjectEmbeddedFrame' }, function () {
        try { void chrome.runtime.lastError; } catch (_) {}
      });
    } catch (_) {}
  }
  // 查词触发键可在设置里换（反馈 ulS75hVkAK，storage.scanModifier，判定同 content.js fushiScanModifierHeld）。本脚本独立
  // 注入、不带 scan.js，这里内联同一张表。none（不按键悬停即查）在这里仍要 Shift 唤起：
  // 「指针划过」不是明确手势，不能凭它往每个 about:blank 编辑器里注整套脚本。
  var modifierProp = 'shiftKey';
  function applyModifier(value) {
    modifierProp = { ctrl: 'ctrlKey', alt: 'altKey', meta: 'metaKey' }[value] || 'shiftKey';
  }
  try {
    chrome.storage.local.get('scanModifier', function (saved) {
      try { if (chrome.runtime.lastError) return; } catch (_) { return; }
      if (saved) applyModifier(saved.scanModifier);
    });
  } catch (_) {}
  function onMove(e) { if (e && e[modifierProp] === true && !e.buttons) request(); }
  document.addEventListener('mousemove', onMove, true);
})();
