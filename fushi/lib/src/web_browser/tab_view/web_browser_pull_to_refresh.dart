import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

import 'package:fushi/src/web_browser/web_browser_prefs.dart';

/// 建出 [PullToRefreshController] 的工厂：标签页传真控制器（带 `onRefresh`），
/// 测试传挂假平台实现的控制器。
typedef WebBrowserPullToRefreshFactory =
    PullToRefreshController Function(PullToRefreshSettings settings);

/// 一个标签页的「下拉刷新」控制器与偏好（[webBrowserPullToRefresh]）的绑定
/// （反馈 wegu0vewts：太容易误触，要能关）。
///
/// 控制器无论开关都建：偏好关着时以 `enabled: false` 挂上，设置里重新打开能
/// 即时生效（[sync]），不必重开标签页。
class WebBrowserPullToRefreshBinding {
  WebBrowserPullToRefreshBinding({
    required PrefStore prefs,
    required WebBrowserPullToRefreshFactory createController,
  }) : _prefs = prefs,
       _applied = webBrowserPullToRefresh(prefs) {
    controller = createController(PullToRefreshSettings(enabled: _applied));
  }

  final PrefStore _prefs;

  /// 交给 `InAppWebView.pullToRefreshController` 的控制器。
  late final PullToRefreshController controller;

  bool _applied;

  /// 当前已应用到 [controller] 的偏好值。
  bool get enabled => _applied;

  /// 偏好变化时调用。两处都要写：`settings.enabled` 供 WebView 还没建出 / 死亡守卫
  /// 重建时读初始设置；`setEnabled` 改已挂上的原生控件（通道未建时是 no-op，靠前者
  /// 兜住）。关掉时顺带收起正在转的刷新指示器。
  void sync() {
    final bool enabled = webBrowserPullToRefresh(_prefs);
    if (enabled == _applied) return;
    _applied = enabled;
    controller.settings.enabled = enabled;
    if (!enabled) unawaited(controller.endRefreshing());
    unawaited(controller.setEnabled(enabled));
  }
}
