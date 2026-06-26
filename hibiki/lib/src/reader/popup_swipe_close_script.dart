// TODO-854 M1a-2：查词弹窗「下滑关闭」的注入 JS——单一真相，由桌面/移动两套查词
// 表面共用：
//   * 主 Dart 查词弹窗（DictionaryPopupWebView，桌面经 flutter_inappwebview_windows
//     的 WebView2 渲染）；
//   * Windows 全局查词覆盖窗（bare WebView2，global_lookup_render 注入）。
//
// 根因：旧实现只挂 touch 事件，桌面 WebView2 不触发 touch，故顶部下滑关闭在桌面失效。
// 这里并行挂 touch + pointer/mouse 两套识别：pointerType==='touch' 由 touch 路径处理，
// pointer 路径只接 mouse/pen，避免同一次拖动在两套事件家族同时派发的平台上双触发。
// 两条路径同阈值（顶部下滑 48px）、同 atTop 判定，最终都回调
// `flutter_inappwebview.callHandler('topPullReleased')`（全局覆盖窗由原生 shim 把该
// callHandler 桥接到 chrome.webview.postMessage）。是否真正关闭由 Dart 侧据用户
// 「滑动关闭弹窗」(enableSwipeToClose) 偏好决定，本脚本只负责手势识别与上报。
const String kPopupTopPullReleaseJs = '''
(function(){
  if(window.__hoshiTopPullInstalled) return;
  window.__hoshiTopPullInstalled = true;
  var startY = null;
  var pulled = false;
  function atTop(){
    var st = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
    return st <= 0;
  }
  function fire(){
    if(pulled && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('topPullReleased');
    }
    startY = null;
    pulled = false;
  }
  // Touch (mobile).
  window.addEventListener('touchstart', function(e){
    if(!e.touches || e.touches.length !== 1) return;
    startY = e.touches[0].clientY;
    pulled = false;
  }, {passive: true});
  window.addEventListener('touchmove', function(e){
    if(startY === null || !e.touches || e.touches.length !== 1) return;
    if(atTop() && e.touches[0].clientY - startY > 48) {
      pulled = true;
    }
  }, {passive: true});
  window.addEventListener('touchend', fire, {passive: true});
  // Pointer / mouse (desktop WebView2 — in-app popup + global overlay). The
  // 'touch' pointerType is already covered by the touch path above; only act on
  // mouse/pen so a single drag never fires twice on platforms that dispatch
  // both event families.
  var pointerActive = false;
  window.addEventListener('pointerdown', function(e){
    if(e.pointerType === 'touch') return;
    if(e.button !== undefined && e.button !== 0) return;
    pointerActive = true;
    startY = e.clientY;
    pulled = false;
  }, {passive: true});
  window.addEventListener('pointermove', function(e){
    if(!pointerActive || e.pointerType === 'touch' || startY === null) return;
    if(atTop() && e.clientY - startY > 48) {
      pulled = true;
    }
  }, {passive: true});
  window.addEventListener('pointerup', function(e){
    if(!pointerActive || e.pointerType === 'touch') return;
    pointerActive = false;
    fire();
  }, {passive: true});
  window.addEventListener('pointercancel', function(e){
    if(e.pointerType === 'touch') return;
    pointerActive = false;
    startY = null;
    pulled = false;
  }, {passive: true});
})();
''';
