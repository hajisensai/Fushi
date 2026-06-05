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
/// 与本仓自实现的 [HibikiReorderableColumn] 不同：那个组件按**输入设备**区分
/// （鼠标即时 / 触摸长按），因为它要在祖先 `Transform.scale` 下手搓拖拽坐标；
/// 本组件服务于普通（未缩放）的 SDK `ReorderableListView`，沿用 SDK 的按平台范式即可。
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
