import 'package:material_ui/material_ui.dart';

/// 一块表面上「至多一个」右键菜单的在途句柄。
///
/// 盖在平台视图（WebView）上的菜单，在 macOS 上点到 WebView 的鼠标事件直接交给
/// 原生视图、到不了菜单路由的 ModalBarrier：点页面别处关不掉菜单，再右键又叠一层
/// （反馈 U_8sCB0h_f，一次截图里叠了 6 个）。本句柄让新菜单开之前先关掉旧的，并给
/// 页面一个 [dismiss] 入口（WebView 的 pointerdown 回报到 Dart 时调它）。
///
/// 菜单路由靠 [routeName] 认：[show] 把 `RouteSettings(name: routeName)` 交给
/// [show] 的 `open` 回调，调用方原样传给 `showFushiMenu(routeSettings: ...)`。
class FushiSingleMenuGate {
  FushiSingleMenuGate({required this.routeName, this.onOpenChanged});

  final String routeName;

  /// 菜单在场状态变化（true = 开，false = 关）；例如同步给 WebView 里的 JS。
  final ValueChanged<bool>? onOpenChanged;

  NavigatorState? _navigator;
  int _generation = 0;

  bool get isOpen => _navigator != null;

  /// 先关掉在场的菜单，再开 [open] 给出的新菜单；返回新菜单的结果。
  ///
  /// 在首个 await 之前就登记在场，连发两次也只会留下后开的那一个。
  Future<T?> show<T>(
    BuildContext context,
    Future<T?> Function(RouteSettings settings) open,
  ) async {
    dismiss();
    final int generation = ++_generation;
    _navigator = Navigator.of(context);
    onOpenChanged?.call(true);
    try {
      return await open(RouteSettings(name: routeName));
    } finally {
      // 被后开的菜单顶替时不清：在场的已是新的那一个。
      if (generation == _generation) {
        _navigator = null;
        onOpenChanged?.call(false);
      }
    }
  }

  /// 关掉在场的菜单（没有就什么都不做）。只弹本句柄的菜单路由：栈顶不是它时
  /// 不动别的路由。
  void dismiss() {
    final NavigatorState? navigator = _navigator;
    if (navigator == null || !navigator.mounted) return;
    navigator.popUntil(
      (Route<dynamic> route) => route.settings.name != routeName,
    );
  }
}
