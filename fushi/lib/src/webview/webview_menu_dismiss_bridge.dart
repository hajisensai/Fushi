import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/utils/components/fushi_menu_presence.dart';

/// 让盖在 WebView（平台视图）上的 `showFushiMenu` 菜单在「点到 WebView」时也能关。
///
/// macOS 上点到 WKWebView 的鼠标事件直接交给原生视图，菜单路由的 ModalBarrier
/// 收不到：点页面别处关不掉菜单（反馈 U_8sCB0h_f）。Flutter 没有在 macOS 上拦平台
/// 视图指针的机制（iOS 有手势拦截、Android 混合合成先过 Flutter，都不受影响），
/// 所以由 WebView 里的 JS 在菜单在场时把鼠标按下回报给 Dart，Dart 关菜单。
///
/// 每个会在自己上方弹 `showFushiMenu` 的 WebView 宿主都这样接：
/// 1. 构造 WebView 时把 [userScript] 放进 `initialUserScripts`；
/// 2. `onWebViewCreated` 里 [attach] 该 controller；宿主 dispose 时 [detach]。
///
/// 菜单在场状态来自 [FushiMenuPresence]（`showFushiMenu` 自己登记），宿主不再各写
/// 一套菜单句柄 / JS 标志。
class WebViewMenuDismissBridge {
  WebViewMenuDismissBridge({FushiMenuPresence? presence})
    : _presence = presence ?? FushiMenuPresence.instance;

  final FushiMenuPresence _presence;
  InAppWebViewController? _controller;

  /// JS → Dart 回报口。
  static const String handlerName = 'onFushiDismissMenu';

  /// 页内「菜单在场」标志（Dart 经 [attach] 后的同步写入）。
  static const String openFlag = '__fushiMenuOpen';

  /// 页内监听：菜单在场时的第一下鼠标 / 笔按下回报一次 [handlerName]。触摸不回报
  /// ——触摸在所有平台都先过 Flutter，遮罩自己收得到。
  static const String script =
      '''
(function(){
  if(window.__fushiMenuDismissInstalled)return;
  window.__fushiMenuDismissInstalled=true;
  if(window.$openFlag===undefined)window.$openFlag=false;
  document.addEventListener('pointerdown',function(e){
    if(e.pointerType==='touch'||!window.$openFlag)return;
    window.$openFlag=false;
    var b=window.flutter_inappwebview;
    if(b&&b.callHandler)b.callHandler('$handlerName');
  },{capture:true,passive:true});
})();
''';

  /// 放进 WebView 的 `initialUserScripts`（每个新文档开头注入）。
  static UserScript get userScript => UserScript(
    source: script,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  );

  /// 接上一个 WebView controller（重建出的新 controller 再调一次即可替换旧的）。
  void attach(InAppWebViewController controller) {
    if (identical(controller, _controller)) return;
    final bool wasAttached = _controller != null;
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: handlerName,
      callback: (List<dynamic> _) => _presence.dismissAll(),
    );
    if (!wasAttached) _presence.isOpen.addListener(_syncFlag);
    // 接上时菜单可能已经在场（WebView 换代）。
    if (_presence.isOpen.value) _syncFlag();
  }

  /// 宿主销毁 / 换掉 WebView 时调。
  void detach() {
    if (_controller == null) return;
    _presence.isOpen.removeListener(_syncFlag);
    _controller = null;
  }

  void _syncFlag() {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    unawaited(
      controller.evaluateJavascript(
        source: 'window.$openFlag=${_presence.isOpen.value};',
      ),
    );
  }

  @visibleForTesting
  bool get debugAttached => _controller != null;
}
