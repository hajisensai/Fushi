import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart';

/// 菜单浮层（[MenuAnchor] / [DropdownMenu] 的 OverlayPortal 面板）的滚动通知边界。
///
/// BUG-3359：浮层在**渲染树**上画在 Overlay 里，在**元素树**上却仍是锚点的后代
/// ——面板自己那个 `SingleChildScrollView` 发出的滚动通知会一路冒泡进锚点所在的
/// 页面。页面层的监听者（浮动顶栏 / 页头的「滚动收起」、`FushiPageScaffold` 的
/// 标题淡入与顶部遮罩）把它当成正文在滚：用户在漫画「来源」下拉里拨滚轮，顶栏
/// 跟着收起；收起改了页面版式、下拉随之重建，而 [DropdownMenu] 每次 build 都会在
/// 下一帧把列表滚回当前选中项——于是列表怎么拨都停在顶上、下不去。
///
/// 本组件把浮层冒出来的滚动通知截在锚点这一层，不让它们再往页面冒；[anchor] 包住
/// 锚点自身（触发按钮），锚点子树里的滚动照常冒泡。被截下的滚动更新仍交给根部
/// 滚轮补间（[SmoothWheelScrollScope.observeIsolatedScrollUpdate]），菜单的滚轮
/// 照旧是平滑的。
class MenuOverlayScrollBoundary extends StatefulWidget {
  const MenuOverlayScrollBoundary({required this.child, super.key});

  /// 含 [MenuAnchor] / [DropdownMenu] 的子树。
  final Widget child;

  /// 包住锚点自身：从这里冒上来的滚动通知不属于浮层，照常冒泡给页面。
  static Widget anchor({required Widget child}) =>
      _MenuOverlayScrollAnchor(child: child);

  @override
  State<MenuOverlayScrollBoundary> createState() =>
      _MenuOverlayScrollBoundaryState();
}

class _MenuOverlayScrollBoundaryState extends State<MenuOverlayScrollBoundary> {
  /// 最近一条从锚点子树冒上来的通知（同一条通知对象随后才到达本层）。
  Notification? _fromAnchor;

  static bool _isScrollNotification(Notification notification) =>
      notification is ScrollNotification ||
      notification is ScrollMetricsNotification;

  bool _onNotification(Notification notification) {
    if (!_isScrollNotification(notification)) return false;
    if (identical(notification, _fromAnchor)) {
      _fromAnchor = null;
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      SmoothWheelScrollScope.observeIsolatedScrollUpdate(context, notification);
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<Notification>(
    onNotification: _onNotification,
    child: widget.child,
  );
}

class _MenuOverlayScrollAnchor extends StatelessWidget {
  const _MenuOverlayScrollAnchor({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => NotificationListener<Notification>(
    onNotification: (Notification notification) {
      if (_MenuOverlayScrollBoundaryState._isScrollNotification(notification)) {
        context
                .findAncestorStateOfType<_MenuOverlayScrollBoundaryState>()
                ?._fromAnchor =
            notification;
      }
      return false;
    },
    child: child,
  );
}
