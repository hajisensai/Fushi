// 触屏查词（content script 隔离世界，manifest bundle 里排在 video-shortcuts.js 之后加载）。
// 桌面查词靠 Shift+悬停划词，手机/平板没键盘，那条路完全够不着——本脚本把「页面正文」
// 变成触屏查词入口：单点一下 = 查词（touchLookupTap，默认开）；长按约 0.5 秒不动 = 查词
// （touchLookupHold，默认关，想要再开）。取词、高亮、弹窗完全复用 window.fushiLookupAtPoint
// （content.js 的「显式点击查词」入口，与字幕面板行内点击同源），不新增任何查词链路。
// 闸门（每一条都是「绝不抢站点」）：
//   · 只认 pointerType === 'touch' 且主指针——鼠标/触控笔的行为永远是原样，零变化；
//   · 扩展自绘 UI（查词弹窗 #hibiki-popup-host 及 #fushi-* 前缀的宿主、字幕覆盖层、
//     toast、排队卡、拖放提示）上的手势全部跳过——弹窗内自有交互，字幕覆盖层自带
//     click→查词（subtitle-panel.js），不掺和；
//   · 链接、按钮、输入框、视频画面等交互元素交给站点自己：点播放器暂停/播放
//     这类操作绝不被查词抢走；
//   · 手指位移超过 MOVE_SLOP 判为滚动/拖拽选词，取消本次手势，不查词；
//   · 长按与点按同时开着：到 500ms 长按先查，抬手不再重复查（手势已被长按消费）。
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  var HOLD_MS = 500;
  var MOVE_SLOP = 10;
  var settings = { tap: true, hold: false };

  function apply(saved) {
    saved = saved || {};
    if (typeof saved.touchLookupTap === 'boolean') settings.tap = saved.touchLookupTap;
    if (typeof saved.touchLookupHold === 'boolean') settings.hold = saved.touchLookupHold;
  }
  try {
    var p = chrome.storage.local.get(['touchLookupTap', 'touchLookupHold'], apply);
    if (p && typeof p.then === 'function') p.then(apply, function () {});
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      var patch = {};
      if (changes.touchLookupTap) patch.touchLookupTap = changes.touchLookupTap.newValue;
      if (changes.touchLookupHold) patch.touchLookupHold = changes.touchLookupHold.newValue;
      if (patch.touchLookupTap !== undefined || patch.touchLookupHold !== undefined) apply(patch);
    });
  } catch (_) {}

  // 扩展自绘的在页 UI：查词弹窗宿主是 #hibiki-popup-host（历史名），其余统一 #fushi-* 前缀。
  function isOwnUi(t) {
    try {
      return !!(t && t.closest && t.closest('#hibiki-popup-host, [id^="fushi-"]'));
    } catch (_) { return false; }
  }
  // 站点交互元素——closest 向上找祖先，正文 <p> 里包着的 <a> 也算命中。
  var INTERACTIVE =
    'a, button, input, select, textarea, summary, video, audio, iframe, canvas, label, ' +
    '[role="button"], [role="link"], [onclick], [contenteditable="true"]';
  function isSiteControl(t) {
    try {
      return !!(t && t.closest && t.closest(INTERACTIVE));
    } catch (_) { return false; }
  }

  function lookupAt(x, y) {
    try {
      if (typeof window.fushiLookupAtPoint === 'function') window.fushiLookupAtPoint(x, y, null);
    } catch (_) {}
  }

  var gesture = null;
  function cancelGesture() {
    if (gesture && gesture.timer) clearTimeout(gesture.timer);
    gesture = null;
  }

  // 全部 capture + passive：只观察、不拦截——站点自己的 touch/pointer 行为（滚动、
  // 双击缩放、播放器手势）一概不动；查词发生在判定成立的抬手/到点时刻。
  var OPTS = { capture: true, passive: true };

  document.addEventListener('pointerdown', function (e) {
    if (e.pointerType !== 'touch' || !e.isPrimary) return;
    if (!settings.tap && !settings.hold) { cancelGesture(); return; }
    // Shadow DOM：e.target 会被 retarget 成宿主元素，composedPath()[0] 才是真实落点
    // （与 video-shortcuts.js 的键盘判定同一策略）。
    var realTarget = e.target;
    try {
      if (typeof e.composedPath === 'function') {
        var path = e.composedPath();
        if (path && path.length && path[0] && path[0].nodeType === 1) realTarget = path[0];
      }
    } catch (_) {}
    if (isOwnUi(realTarget) || isSiteControl(realTarget)) { cancelGesture(); return; }
    cancelGesture();
    gesture = { id: e.pointerId, x: e.clientX, y: e.clientY, moved: false, fired: false, timer: 0 };
    if (settings.hold) {
      var g = gesture;
      g.timer = setTimeout(function () {
        if (gesture !== g || g.moved || g.fired) return;
        g.fired = true;
        lookupAt(g.x, g.y);
      }, HOLD_MS);
    }
  }, OPTS);

  document.addEventListener('pointermove', function (e) {
    if (!gesture || e.pointerId !== gesture.id) return;
    if (Math.abs(e.clientX - gesture.x) > MOVE_SLOP || Math.abs(e.clientY - gesture.y) > MOVE_SLOP) {
      gesture.moved = true;
      if (gesture.timer) { clearTimeout(gesture.timer); gesture.timer = 0; }
    }
  }, OPTS);

  document.addEventListener('pointerup', function (e) {
    if (!gesture || e.pointerId !== gesture.id) return;
    var g = gesture;
    cancelGesture();
    if (settings.tap && !g.moved && !g.fired) lookupAt(g.x, g.y);
  }, OPTS);

  document.addEventListener('pointercancel', function (e) {
    if (gesture && e.pointerId === gesture.id) cancelGesture();
  }, OPTS);
})();
