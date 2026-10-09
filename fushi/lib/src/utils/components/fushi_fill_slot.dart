import 'package:material_ui/material_ui.dart';

/// 「这颗按钮就是这枚胶囊」：可见容器（返回圆胶囊、只装一颗按钮的动作胶囊…）
/// 下发自己的尺寸与形状，子树里那颗图标按钮把 state layer（悬停 / 按下 / 焦点
/// 的灰色 ink）与命中区**撑满到同一尺寸、同一形状**。
///
/// 问题根因（2026-10-09 用户截图：反馈页刷新键、词典管理返回键）：圆胶囊 56，
/// 里面的 M3E 图标按钮是 S 档 40（命中区 48），悬停只亮中间一枚 40 的小圆 /
/// 按压变形后的小方块，胶囊外圈 8px 看得见却点不到。每个页面各自修只会再分叉，
/// 所以由**容器**声明形状、按钮组件统一读取：
///
///  * [FushiIconButtonControl] / [FushiIconButton]（MD3）读 [maybeOf]：尺寸钉成
///    [extent]、ink 的 customBorder / 按钮 shape 用 [shape]，不再做按压变形
///    （容器本身不变形，ink 变形会露出两层不同的轮廓）。
///  * 框架 [IconButton] / [BackButton] / [CloseButton] / [PopupMenuButton] 经
///    [wrap] 下发的 [IconButtonTheme] 拿到同一组尺寸与形状。
///
/// 只服务 Material 设计系统；Apple 玻璃圆钮自身就是可见形状，不经这里。
class FushiFillSlot extends InheritedWidget {
  const FushiFillSlot({
    required this.extent,
    required this.shape,
    required super.child,
    super.key,
  });

  /// 容器（= 按钮）的尺寸。
  final Size extent;

  /// 容器（= 按钮 ink / 命中区）的形状。
  final OutlinedBorder shape;

  /// 最近的填充槽；没有时 null（按钮按自己的尺寸档绘制）。
  static FushiFillSlot? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiFillSlot>();

  /// 把 [child] 装进一个 [extent] × [shape] 的填充槽：既下发 [FushiFillSlot]
  /// （Fushi 按钮读），也下发同尺寸同形状的 [IconButtonTheme]（框架按钮读）。
  static Widget wrap({
    required Size extent,
    required OutlinedBorder shape,
    required Widget child,
  }) {
    return FushiFillSlot(
      extent: extent,
      shape: shape,
      child: Builder(
        builder: (BuildContext context) {
          final ButtonStyle? inherited = IconButtonTheme.of(context).style;
          final ButtonStyle fill = fushiFillSlotButtonStyle(extent, shape);
          return IconButtonTheme(
            data: IconButtonThemeData(
              style: inherited == null ? fill : fill.merge(inherited),
            ),
            child: SizedBox.fromSize(
              size: extent,
              child: Center(child: child),
            ),
          );
        },
      ),
    );
  }

  @override
  bool updateShouldNotify(FushiFillSlot oldWidget) =>
      extent != oldWidget.extent || shape != oldWidget.shape;
}

/// 填充槽给按钮的尺寸 + 形状样式（最小 = 最大 = [extent]，命中区不再被 48 的
/// 最小触控目标另外撑大或缩小）。
ButtonStyle fushiFillSlotButtonStyle(Size extent, OutlinedBorder shape) =>
    ButtonStyle(
      minimumSize: WidgetStatePropertyAll<Size>(extent),
      maximumSize: WidgetStatePropertyAll<Size>(extent),
      fixedSize: WidgetStatePropertyAll<Size>(extent),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.zero,
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(shape),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );
