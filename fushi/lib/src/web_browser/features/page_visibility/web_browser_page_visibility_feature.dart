import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart'
    show kWebBrowserHoldMediaScript, kWebBrowserReleaseMediaScript;
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 告诉 WebView 它看不见了 / 又看得见了（[hidden]）。
typedef WebBrowserPageHiddenSetter =
    Future<void> Function(
      InAppWebViewController controller, {
      required bool hidden,
    });

/// 在页面里跑一段脚本。
typedef WebBrowserPageScriptRunner =
    Future<void> Function(InAppWebViewController controller, String source);

/// 平台默认的「页面看不见」：
/// - Windows / Android：`pause()` / `resume()`。Windows 是 WebView2 的
///   `IsVisible=false` + `TrySuspend`（fork 已实现，`in_app_webview.cpp`），Android 是
///   `WebView.onPause()`；两者都让页面的 `document.visibilityState` 变成 `hidden`，站点自己
///   的「切走就停」逻辑（Netflix 首页预告片）随之生效，定时器 / 动画 / 合成也停下。
/// - iOS / macOS / Linux：没有可见性开关，用 `setAllMediaPlaybackSuspended` 挂起页面媒体。
Future<void> webBrowserSetPageHidden(
  InAppWebViewController controller, {
  required bool hidden,
}) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.android:
      return hidden ? controller.pause() : controller.resume();
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return controller.setAllMediaPlaybackSuspended(suspended: hidden);
    case TargetPlatform.fuchsia:
      return Future<void>.value();
  }
}

Future<void> _evaluate(InAppWebViewController controller, String source) =>
    controller.evaluateJavascript(source: source);

/// 浏览器标签页「看不见就别播」：标签页**看得见** = 浏览页没被整页路由盖住
/// （[onPageCoveredChanged]）且它是前台标签页（[onTabActiveChanged]）。
///
/// 起因（用户 2026-11-04）：开着 Netflix 首页时从别处打开本地视频，浏览页被视频页盖住，
/// 但 WebView 还以为自己在前台，首页预告片照样自动播、和上层播放器同时出声。浏览器内部
/// 切到别的标签页（`IndexedStack` 藏起来的后台页）同理。
///
/// 变成看不见时两步，顺序固定：
/// 1. 先跑 [kWebBrowserHoldMediaScript]：暂停在播的 `<video>` / `<audio>`，之后谁再开播
///    立刻停——兜住页面隐藏后仍照常出声的站点（YouTube 等）；
/// 2. 再告诉 WebView 它看不见了（[webBrowserSetPageHidden]），站点按标准的
///    `visibilitychange` 自己停，渲染 / 定时器也停。必须在 1 之后：Windows 挂起后页面不再
///    跑脚本。
///
/// 重新看得见时倒过来：先恢复可见，再解除按住。与「用 Fushi 播放」交接时的按住
/// （`PlayInFushiFeature`）共用同一对脚本；那边的按住只在浏览页回到最上面时解除，
/// 此时本功能也认为页面看得见，两边解除不冲突（脚本幂等）。
class WebBrowserPageVisibilityFeature extends WebBrowserFeature {
  WebBrowserPageVisibilityFeature({
    WebBrowserPageHiddenSetter? setHidden,
    WebBrowserPageScriptRunner? runScript,
  }) : _setHidden = setHidden ?? webBrowserSetPageHidden,
       _runScript = runScript ?? _evaluate;

  final WebBrowserPageHiddenSetter _setHidden;
  final WebBrowserPageScriptRunner _runScript;

  final Map<String, InAppWebViewController> _controllers =
      <String, InAppWebViewController>{};

  /// 已经落到页面上的状态（true = 看不见）；没有记录 = 还没动过（页面默认看得见）。
  final Map<String, bool> _applied = <String, bool>{};

  /// 每个标签页一条串行链：盖住 / 露出、切标签页来得再快，也按顺序落地。
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  String? _activeId;
  bool _covered = false;

  @override
  String get id => 'page_visibility';

  /// [tabId] 现在该不该看不见。
  @visibleForTesting
  bool shouldHide(String tabId) => _covered || tabId != _activeId;

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    _controllers[tab.id] = controller;
    _applied.remove(tab.id);
    _sync(tab.id);
  }

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) {
    _controllers[tab.id] = controller;
    // 看不见期间整页换了文档：新文档没有按住脚本，重新走一遍。
    if (!shouldHide(tab.id)) return Future<void>.value();
    _applied.remove(tab.id);
    return _sync(tab.id);
  }

  @override
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) {
    final String? previous = _activeId;
    if (active) {
      _activeId = tab.id;
    } else if (_activeId == tab.id) {
      _activeId = null;
    }
    if (previous != null && previous != _activeId) _sync(previous);
    _sync(tab.id);
  }

  @override
  void onPageCoveredChanged({required bool covered}) {
    if (covered == _covered) return;
    _covered = covered;
    for (final String id in List<String>.of(_controllers.keys)) {
      _sync(id);
    }
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    _controllers.remove(tab.id);
    _applied.remove(tab.id);
    _chains.remove(tab.id);
    if (_activeId == tab.id) _activeId = null;
  }

  @override
  void dispose() {
    _controllers.clear();
    _applied.clear();
    _chains.clear();
  }

  /// 把 [tabId] 排到它那条链的末尾去落地「当时」的目标状态。
  Future<void> _sync(String tabId) {
    if (!_controllers.containsKey(tabId)) return Future<void>.value();
    final Future<void> next = (_chains[tabId] ?? Future<void>.value()).then(
      (_) => _apply(tabId),
    );
    _chains[tabId] = next;
    return next;
  }

  Future<void> _apply(String tabId) async {
    final InAppWebViewController? controller = _controllers[tabId];
    if (controller == null) return;
    final bool hide = shouldHide(tabId);
    final bool? applied = _applied[tabId];
    // 从没动过的页面本来就看得见：露出不用做事。
    if (applied == hide || (applied == null && !hide)) return;
    _applied[tabId] = hide;
    if (hide) {
      await _step(() => _runScript(controller, kWebBrowserHoldMediaScript));
      await _step(() => _setHidden(controller, hidden: true));
    } else {
      await _step(() => _setHidden(controller, hidden: false));
      await _step(() => _runScript(controller, kWebBrowserReleaseMediaScript));
    }
  }

  /// 单步失败（页面正在导航、WebView 刚被回收、平台没实现）不挡后面的步骤。
  Future<void> _step(Future<void> Function() body) async {
    try {
      await body();
    } on Object catch (e) {
      debugPrint('[web-browser] page visibility step failed: $e');
    }
  }
}
