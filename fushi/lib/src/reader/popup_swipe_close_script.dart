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
// `flutter_inappwebview.callHandler('topPullReleased', <指针种类>)`（全局覆盖窗由原生
// shim 把该 callHandler 桥接到 chrome.webview.postMessage）。是否真正关闭由 Dart 侧
// 据用户「滑动关闭弹窗」偏好决定，本脚本只负责手势识别与上报。
//
// BUG-2770：上报时带上指针种类（'touch' / 'pen' / 'mouse'）。Dart 侧据此分流：触摸 /
// 触控笔看 enableTouchSwipeToClose（未设置时所有平台默认开），鼠标仍看
// enableSwipeToClose（Windows/Linux 默认关，BUG-299 框选防线）。判据见
// [popupTopPullDismissAllowed]。
const String kPopupTopPullReleaseJs = '''
(function(){
  if(window.__fushiTopPullInstalled) return;
  window.__fushiTopPullInstalled = true;
  var startY = null;
  var pulled = false;
  function atTop(){
    var st = window.scrollY || document.documentElement.scrollTop || document.body.scrollTop || 0;
    return st <= 0;
  }
  function fire(kind){
    if(pulled && window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('topPullReleased', kind);
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
  window.addEventListener('touchend', function(){ fire('touch'); }, {passive: true});
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
    fire(e.pointerType === 'pen' ? 'pen' : 'mouse');
  }, {passive: true});
  window.addEventListener('pointercancel', function(e){
    if(e.pointerType === 'touch') return;
    pointerActive = false;
    startY = null;
    pulled = false;
  }, {passive: true});
})();
''';

/// BUG-2770：覆盖窗 `topPullReleased` 是否真的关窗——按 JS 上报的指针种类分流。
///
/// [pointerKind] 是 [kPopupTopPullReleaseJs] 传来的第一个参数：'touch' / 'pen' 走触摸
/// 半边 [touchSwipeEnabled]（`enableTouchSwipeToClose`，未设置时所有平台默认开）；
/// 'mouse'、缺省或任何认不出的值一律按鼠标半边 [mouseSwipeEnabled]
/// （`enableSwipeToClose`，Windows/Linux 默认关）——认不出时宁可保守不关，BUG-299
/// 的鼠标框选防线不因旧脚本 / 脏参数被绕过。
bool popupTopPullDismissAllowed({
  required Object? pointerKind,
  required bool mouseSwipeEnabled,
  required bool touchSwipeEnabled,
}) {
  if (pointerKind == 'touch' || pointerKind == 'pen') {
    return touchSwipeEnabled || mouseSwipeEnabled;
  }
  return mouseSwipeEnabled;
}

/// BUG-2770：查词覆盖窗（桌面全局查词 / galgame 游戏内卡片）的**横滑关闭**识别 JS。
///
/// 应用内弹窗的正文横滑由 Flutter 侧 `_BodySwipeDismissDetector` 识别（WebView 在
/// Flutter 指针树里）；覆盖窗是 runner 直接托管的 WebView2，没有 Flutter 指针树，
/// 手机上那种「横着一划就关」只能在页面里认。只注入覆盖窗——应用内弹窗再注入
/// 就会和 Flutter 检测器对同一划各关一层。
///
/// 口径与 `_BodySwipeDismissDetector` 一致：只认单指触摸；位移过 8px 才判轴，
/// |dx| > 1.5|dy| 才算横滑，判成纵向就交还页面滚动、后续偏回横向也不反抢；第二根
/// 手指落下本轮作废。用 Touch Events 而不是 Pointer Events：Chromium 接管平移时会
/// 给指针发 pointercancel，而 touchend 照常到达。这一划改动了选区（长按选字、拖选区
/// 柄）时不上报；划之前就留着的旧选区不挡滑关。只上报 `sideSwipeReleased(种类, dx)`，是否关闭由 Dart 按偏好与灵敏度阈值
/// 判（[popupSideSwipeDismissAllowed]），脚本不持有策略。
const String kPopupTouchSideSwipeReleaseJs = '''
(function(){
  if(window.__fushiSideSwipeInstalled) return;
  window.__fushiSideSwipeInstalled = true;
  var startX = null, startY = null, axis = null, voided = false, startSel = '';
  function reset(){ startX = null; startY = null; axis = null; }
  function selText(){
    var sel = window.getSelection && window.getSelection();
    return sel && !sel.isCollapsed ? String(sel) : '';
  }
  window.addEventListener('touchstart', function(e){
    if(!e.touches || e.touches.length !== 1) { voided = true; reset(); return; }
    voided = false;
    startX = e.touches[0].clientX;
    startY = e.touches[0].clientY;
    axis = null;
    startSel = selText();
  }, {passive: true});
  window.addEventListener('touchmove', function(e){
    if(voided || startX === null || axis !== null) return;
    if(!e.touches || e.touches.length !== 1) { voided = true; reset(); return; }
    var dx = e.touches[0].clientX - startX;
    var dy = e.touches[0].clientY - startY;
    if(dx * dx + dy * dy < 64) return;
    axis = Math.abs(dx) > Math.abs(dy) * 1.5 ? 'x' : 'y';
  }, {passive: true});
  window.addEventListener('touchend', function(e){
    if(e.touches && e.touches.length > 0) return;
    var horizontal = !voided && axis === 'x' && startX !== null;
    var t = e.changedTouches && e.changedTouches[0];
    var dx = horizontal && t ? t.clientX - startX : 0;
    voided = false;
    reset();
    if(!horizontal) return;
    var endSel = selText();
    if(endSel !== '' && endSel !== startSel) return;
    if(window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('sideSwipeReleased', 'touch', dx);
    }
  }, {passive: true});
  window.addEventListener('touchcancel', function(){ voided = false; reset(); }, {passive: true});
})();
''';

/// BUG-2770：覆盖窗 `sideSwipeReleased` 是否真的关窗。
///
/// 只有触摸 / 触控笔上报有效（脚本本就只认触摸；鼠标横拖是框选，BUG-299），开关看
/// 触摸半边 [touchSwipeEnabled]（显式开了鼠标半边也算开），位移 [dx]（CSS px）的绝对值
/// 必须超过 [threshold]——与应用内正文横滑同一个 `swipeDismissThreshold(灵敏度)`。
bool popupSideSwipeDismissAllowed({
  required Object? pointerKind,
  required Object? dx,
  required double threshold,
  required bool mouseSwipeEnabled,
  required bool touchSwipeEnabled,
}) {
  if (pointerKind != 'touch' && pointerKind != 'pen') return false;
  if (!touchSwipeEnabled && !mouseSwipeEnabled) return false;
  return dx is num && dx.isFinite && dx.abs() > threshold;
}
