import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// `showFushiMenu` 打开的菜单在场登记（全局一份）。
///
/// 盖在平台视图（WebView）上的菜单，在 macOS 上点到 WebView 的鼠标事件直接交给
/// 原生视图、到不了菜单路由的 ModalBarrier：点页面别处关不掉菜单，再右键又叠一层
/// （反馈 U_8sCB0h_f，一次截图里叠了 6 个）。这件事过去只在漫画阅读器里用一个
/// 页面私有的「单菜单句柄」补，正文阅读器、歌词、内置浏览器的菜单都没有。现在由
/// `showFushiMenu` 自己登记：
/// - 新菜单开之前先关掉在场的菜单（任何来路都不会叠加）；
/// - WebView 宿主经 `WebViewMenuDismissBridge` 订阅 [isOpen]，菜单在场时把 WebView
///   里的鼠标按下回报过来调 [dismissAll]。
class FushiMenuPresence {
  FushiMenuPresence._();

  static final FushiMenuPresence instance = FushiMenuPresence._();

  final List<Route<Object?>> _routes = <Route<Object?>>[];
  final ValueNotifier<bool> _isOpen = ValueNotifier<bool>(false);

  /// 是否有 `showFushiMenu` 菜单在场。
  ValueListenable<bool> get isOpen => _isOpen;

  /// 登记一个刚推入的菜单路由；返回的回调在它结束（选中 / 取消 / 被关）时调。
  VoidCallback register(Route<Object?> route) {
    _routes.add(route);
    _isOpen.value = true;
    return () {
      _routes.remove(route);
      _isOpen.value = _routes.isNotEmpty;
    };
  }

  /// 关掉所有在场菜单（结果为 null，与点遮罩取消同义）。在栈顶的走 pop（有退场
  /// 动效），不在栈顶的直接移除；不动别的路由。
  void dismissAll() {
    for (final Route<Object?> route in List<Route<Object?>>.of(
      _routes.reversed,
    )) {
      final NavigatorState? navigator = route.navigator;
      if (navigator == null || !navigator.mounted || !route.isActive) continue;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    }
  }

  @visibleForTesting
  int get debugOpenCount => _routes.length;
}
