import 'package:flutter/material.dart';

/// 给 SDK [ReorderableListView]（`buildDefaultDragHandles: false`、整行可拖）用的
/// 「整行拖拽起始监听器」，按平台选择即时 / 延迟起拖——镜像 Flutter
/// `ReorderableListView` 默认手柄（`SliverReorderableListState` 的
/// `_dragStartListener`）的平台逻辑：
/// - 桌面（Windows / Linux / macOS，鼠标为主）→ [ReorderableDragStartListener]
///   （[ImmediateMultiDragGestureRecognizer]，按下即拖）；
/// - 移动 / 触摸（Android / iOS / Fuchsia）→ [ReorderableDelayedDragStartListener]
///   （[DelayedMultiDragGestureRecognizer]，长按 `kLongPressTimeout` 再拖）。
///
/// 旧代码对所有平台一律用 `ReorderableDelayedDragStartListener`，导致桌面端鼠标
/// 也必须长按等待 ~500ms 才能拖动重排——本组件消除这个「所有平台都长按」的特例。
///
/// 与本仓自实现的 `HibikiReorderableColumn` 不同：那个组件按**输入设备**区分
/// （鼠标即时 / 触摸长按），因为它要在祖先 `Transform.scale` 下手搓拖拽坐标；
/// 本组件服务于普通（未缩放）的 SDK `ReorderableListView`，沿用 SDK 的按平台范式即可。
///
/// ⚠️ **当前无调用方，新代码不要用它。** 上面那句「普通（未缩放）的
/// `ReorderableListView`」在本 app 里**不成立**——`main.dart` 在应用根部套了
/// `HibikiAppUiScale` 的 `Transform.scale`，全 app 没有未缩放的树，任何 SDK
/// 重排组件的 Overlay 拖拽代理都会在「界面大小」非 100% 时漂移（BUG-778）。
/// 最后两个调用方（`custom_fonts_page` 与互联设备排序）已改用
/// `HibikiReorderableColumn`。保留本文件只为不破坏可能存在的外部引用；
/// 守卫见 `test/widgets/reorderable_scale_safety_guard_test.dart`。
class HibikiReorderDragListener extends StatelessWidget {
  const HibikiReorderDragListener({
    required this.index,
    required this.child,
    super.key,
  });

  /// 该行在 [ReorderableListView] 中的下标（透传给 SDK 监听器）。
  final int index;

  /// 行内容。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    switch (Theme.of(context).platform) {
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
        return ReorderableDragStartListener(index: index, child: child);
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return ReorderableDelayedDragStartListener(index: index, child: child);
    }
  }
}
