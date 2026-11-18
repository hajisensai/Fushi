import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 标签 chip 左侧的「⋮⋮」拖动柄（BUG-4899）：按下即拖，不等长按。
///
/// 根因：库页标签条的 chip 只有 `LongPressDraggable` 一条重排路径，而它住在
/// `HorizontalDragScrollable` 包的横向 `ListView` 里（鼠标拖动 = 横滚）。鼠标
/// 精确指针的 hit slop 只有 1 px（`kPrecisePointerHitSlop`）：长按计时的 500 ms
/// 里手一抖超过 1 px，`DelayedMultiDragGestureRecognizer` 就自行认输，同一下
/// 位移又让横滚 recognizer 胜出——桌面用户按住标签拖，得到的是标签条在滚、
/// 标签纹丝不动，像是「拖动功能没了」。
///
/// 拖动柄用即时 [Draggable]（`ImmediateMultiDragGestureRecognizer`）：柄比外层
/// 滚动区更深，指针路由先到它，越过 slop 的同一帧就先认领，横滚抢不到；柄以外
/// 的 chip 区域照旧点选筛选、按住拖动滚动标签条。触屏同理（柄上拖 = 拖标签）。
///
/// [feedback] 是拖动中跟手的浮层（调用方套 `FushiReorderDragProxy`）；放下由
/// 调用方各 chip 上的 `DragTarget<T>` 接，本件只负责「起拖」。
class FushiTagDragHandle<T extends Object> extends StatelessWidget {
  const FushiTagDragHandle({
    required this.data,
    required this.feedback,
    this.color,
    this.onDragStarted,
    this.onDragEnd,
    super.key,
  });

  /// 拖动携带的数据（标签行）。
  final T data;

  /// 跟手浮层。
  final Widget feedback;

  /// 柄图标颜色；null 跟随 [IconTheme]。
  final Color? color;

  final VoidCallback? onDragStarted;
  final DragEndCallback? onDragEnd;

  /// 柄的可视宽 / 高（命中区由 chip 自身高度撑满竖向）。
  static const double width = 20;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = SizedBox(
      width: width,
      height: 36,
      child: Center(
        child: FushiIcon(FushiIcons.dragIndicator, size: 18, color: color),
      ),
    );
    return Semantics(
      label: t.tag_manage_reorder_hint,
      child: Draggable<T>(
        data: data,
        feedback: feedback,
        // 浮层左上角贴指针：柄在 chip 最左，浮层不会从指针处跳开。
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: onDragStarted,
        onDragEnd: onDragEnd,
        child: MouseRegion(cursor: SystemMouseCursors.grab, child: glyph),
      ),
    );
  }
}
