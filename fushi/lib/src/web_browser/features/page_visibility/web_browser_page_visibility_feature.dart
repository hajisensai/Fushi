import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/web_browser/features/play_in_fushi/web_browser_media_hold_scripts.dart';
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

/// 落到页面上的状态。
enum _PageState {
  /// 看得见（WebView 建好时的默认）。
  visible,

  /// 已按住媒体并隐藏。
  hidden,

  /// 上次落地有一步失败，页面实际处于哪种状态说不准：下次同步无论目标是什么都重做。
  unknown,
}

/// 浏览页被**播放页**盖住时，下面的网页别跟着播（BUG-4084）。
///
/// 起因（用户 2026-11-04）：开着 Netflix 首页时从别处打开本地视频，浏览页被视频页盖住，
/// 但 WebView 还以为自己在前台，首页预告片照样自动播、和上层播放器同时出声。正常浏览器
/// 是同一个网页直接跳转，不会有「底下那页还在播」的情况。
///
/// 范围（用户拍板）：
/// - 只在被视频页 / 播放页盖住时（[onPlaybackCoverChanged]，`PlaybackRouteMarks`）触发；
///   盖上设置页、标签网格等别的整页路由不算。
/// - 浏览器里只是切走的后台标签页**不**暂停、不挂起，照常播放（与 Chrome 一致）。
/// - 正被手机遥控的那一页（[remoteControlledTabId]：有已认证的手机控制端、且控制的正是
///   这一页）不暂停、不挂起：遥控要靠页面回话。只是页面里有视频、登记了遥控绑定不算。
///   盖住期间手机断开 / 换控别的播放器 / 会话结束，那一页随即按规则隐藏。
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
///
/// 只管加载完过一次的页面（[onLoadStop] 起登记）：刚建好的 WebView 还在初始化，不在那时
/// 挂起它。WebView 被回收（[onWebViewDisposed]）时连控制器一起撒手。
class WebBrowserPageVisibilityFeature extends WebBrowserFeature {
  WebBrowserPageVisibilityFeature({
    this.remoteControlledTabId,
    WebBrowserPageHiddenSetter? setHidden,
    WebBrowserPageScriptRunner? runScript,
  }) : _setHidden = setHidden ?? webBrowserSetPageHidden,
       _runScript = runScript ?? _evaluate {
    _remoteTabId = remoteControlledTabId?.value;
    remoteControlledTabId?.addListener(_onRemoteSessionChanged);
  }

  /// 正被手机遥控的标签页 id（`WebBrowserVideoRemote.remoteControlledTabId`）；null = 没装遥控。
  final ValueListenable<String?>? remoteControlledTabId;

  final WebBrowserPageHiddenSetter _setHidden;
  final WebBrowserPageScriptRunner _runScript;

  /// 加载完过、WebView 还活着的标签页的控制器。
  final Map<String, InAppWebViewController> _controllers =
      <String, InAppWebViewController>{};

  /// 已经落到页面上的状态；没有记录 = [_PageState.visible]。
  final Map<String, _PageState> _applied = <String, _PageState>{};

  /// 每个标签页一条串行链：盖住 / 露出来得再快，也按顺序落地。
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  bool _playbackCovered = false;
  String? _remoteTabId;

  @override
  String get id => 'page_visibility';

  /// [tabId] 现在该不该看不见。
  @visibleForTesting
  bool shouldHide(String tabId) => _playbackCovered && tabId != _remoteTabId;

  @override
  void onWebViewCreated(WebBrowserTab tab, InAppWebViewController controller) {
    // 新 WebView（含回收后重建）：旧控制器、旧状态全作废，等它加载完再登记。
    _forget(tab.id);
  }

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) {
    _controllers[tab.id] = controller;
    // 看不见期间整页换了文档：新文档没有按住脚本，重新走一遍。看得见时照常同步
    // （上次落地失败留下的「说不准」在这里补正）。
    if (shouldHide(tab.id)) _applied[tab.id] = _PageState.unknown;
    return _sync(tab.id);
  }

  @override
  void onPlaybackCoverChanged({required bool covered}) {
    if (covered == _playbackCovered) return;
    _playbackCovered = covered;
    for (final String id in List<String>.of(_controllers.keys)) {
      _sync(id);
    }
  }

  void _onRemoteSessionChanged() {
    final String? previous = _remoteTabId;
    final String? next = remoteControlledTabId?.value;
    if (previous == next) return;
    _remoteTabId = next;
    if (previous != null) _sync(previous);
    if (next != null) _sync(next);
  }

  @override
  void onWebViewDisposed(WebBrowserTab tab) => _forget(tab.id);

  @override
  void onTabClosed(WebBrowserTab tab) => _forget(tab.id);

  @override
  void dispose() {
    remoteControlledTabId?.removeListener(_onRemoteSessionChanged);
    _controllers.clear();
    _applied.clear();
    _chains.clear();
  }

  void _forget(String tabId) {
    _controllers.remove(tabId);
    _applied.remove(tabId);
    _chains.remove(tabId);
  }

  /// 测试用：[tabId] 是否还登记着控制器。
  @visibleForTesting
  bool tracks(String tabId) => _controllers.containsKey(tabId);

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
    final _PageState target = hide ? _PageState.hidden : _PageState.visible;
    if ((_applied[tabId] ?? _PageState.visible) == target) return;
    final bool ok;
    if (hide) {
      final bool held = await _step(
        () => _runScript(controller, kWebBrowserHoldMediaScript),
      );
      final bool hidden = await _step(
        () => _setHidden(controller, hidden: true),
      );
      ok = held && hidden;
    } else {
      final bool shown = await _step(
        () => _setHidden(controller, hidden: false),
      );
      final bool released = await _step(
        () => _runScript(controller, kWebBrowserReleaseMediaScript),
      );
      ok = shown && released;
    }
    // 落地期间 WebView 被回收 / 标签页关了：记录已清，别再写回去。
    if (!identical(_controllers[tabId], controller)) return;
    // 只有每一步都成功才记成目标状态；有一步失败就记「说不准」，下次同步重做。
    _applied[tabId] = ok ? target : _PageState.unknown;
  }

  /// 单步失败（页面正在导航、平台没实现）不挡后面的步骤；返回这一步成没成功。
  Future<bool> _step(Future<void> Function() body) async {
    try {
      await body();
      return true;
    } on Object catch (e) {
      debugPrint('[web-browser] page visibility step failed: $e');
      return false;
    }
  }
}
