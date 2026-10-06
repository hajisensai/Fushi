/// 保活分区（顶层 tab / 库页视图）的可见性：焦点与系统返回的参与资格。
///
/// 保活分区用 [Offstage] + [TickerMode] 藏起来，但这两者都不管焦点与返回：
/// - 藏起来的分区里的焦点节点仍在焦点树上，Tab / 方向键遍历会落进看不见的按钮；
/// - 藏起来的分区里的 [PopScope] 仍登记在同一个路由上——书架在「发现」视图背后
///   停在多选模式时，`canPop: false` 照样拦住返回键，回调还会在看不见的地方退出
///   多选（HBK-AUDIT-017）。
///
/// 统一裁剪点：宿主用 [SectionVisibilityScope] 包每个保活分区（与 `offstage:`
/// 同一个判据），分区内会拦返回的地方用 [SectionPopScope] 代替裸 [PopScope]。
/// 可见性沿祖先链取与：外层 tab 隐藏时，里面「当前」视图同样不可见。
library;

import 'package:flutter/widgets.dart';

/// 当前子树是否处在可见分区里（自身与所有祖先分区都可见）。
class SectionVisibility extends InheritedWidget {
  const SectionVisibility._({required this.visible, required super.child});

  /// 自身与所有祖先分区是否都可见。
  final bool visible;

  /// 子树是否可见；不在任何分区里时恒为 true。
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SectionVisibility>()
          ?.visible ??
      true;

  @override
  bool updateShouldNotify(SectionVisibility oldWidget) =>
      visible != oldWidget.visible;
}

/// 包一个保活分区：向子树发布（与祖先取与后的）可见性，并按**有效可见性**
/// 排除焦点——外层 tab 隐藏时，里面本地「当前」的视图同样拿不到焦点、收不到
/// 按键（HBK-AUDIT-017 残留：只按本层 [visible] 排除时，外层隐藏、内层当前的
/// 子树仍 hasFocus 且吃键）。
///
/// 由隐转显的那次同步调用里（尚未重建）向分区内 requestFocus 会被这里吞掉；
/// 需要「切过去就聚焦」的宿主要在分区重建之后再请求焦点（后帧，或像查词 tab
/// 那样由非保活页自己在挂载后消费请求）。
class SectionVisibilityScope extends StatelessWidget {
  const SectionVisibilityScope({
    required this.visible,
    required this.child,
    super.key,
  });

  /// 本分区是否为当前分区（与宿主 `Offstage.offstage` 取反同一个判据）。
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool effective = visible && SectionVisibility.of(context);
    return SectionVisibility._(
      visible: effective,
      child: ExcludeFocus(excluding: !effective, child: child),
    );
  }
}

/// 只在所在分区可见时参与系统返回的 [PopScope]。
///
/// [intercepting] 为 true 且分区可见时拦下返回（`canPop: false`）并调
/// [onIntercept]；分区隐藏时既不拦返回、也不调回调——看不见的页面不能吃掉
/// 用户的返回键，也不能在背后改自己的状态。
class SectionPopScope extends StatelessWidget {
  const SectionPopScope({
    required this.intercepting,
    required this.onIntercept,
    required this.child,
    super.key,
  });

  final bool intercepting;
  final VoidCallback onIntercept;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool active = intercepting && SectionVisibility.of(context);
    return PopScope<Object?>(
      canPop: !active,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || !active) return;
        onIntercept();
      },
      child: child,
    );
  }
}
