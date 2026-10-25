import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_dial_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';

/// MD3 悬浮胶囊**内部**交给「放不下的入口」交互原型画的那一块（2026-10-23）。
///
/// 胶囊底色、圆角、投影、随滚动收起、右侧 FAB 都仍由 `_MaterialFloatingBar`
/// 画；原型只负责胶囊里的这一排（[width] × [height]），需要冒出胶囊的部分
/// （转盘）用 [OverlayPortal] 画到上层。
class NavOverflowSpec {
  const NavOverflowSpec({
    required this.items,
    required this.indices,
    required this.currentIndex,
    required this.onSelect,
    required this.cellBuilder,
    required this.width,
    required this.height,
  });

  /// 底栏全部目的地（含已拆成 FAB 的查词，序号与 [currentIndex] 同一套）。
  final List<AdaptiveNavItem> items;

  /// 进胶囊的目的地序号，按视觉顺序（不含 FAB 那一项）。
  final List<int> indices;

  /// 当前选中的目的地序号；可能不在 [indices] 里（当前是 FAB 那一项）。
  final int currentIndex;

  /// 跳到某个目的地（参数是 [items] 的序号）。已带选中触觉与模块切换转场，
  /// 原型直接调，不要再自己发触觉。
  final ValueChanged<int> onSelect;

  /// 画一个标准目的地格（与平铺 / 分页同一个焦点格：选中药丸、手柄焦点、
  /// 无障碍语义都在里面）。固定显示在胶囊里的那几个一律用它画。
  final Widget Function(int index, double cellWidth) cellBuilder;

  /// 胶囊内可用的宽与高（已扣掉胶囊左右内边距）。
  final double width;
  final double height;

  AdaptiveNavItem item(int index) => items[index];

  /// 在 [width] 里放 [triggerWidth] 宽的触发格后，还能按 [cellWidth] 平铺
  /// 几个目的地（至少 1 个）。
  int pinnedCount({required double triggerWidth, double cellWidth = 52}) {
    final int fit = ((width - triggerWidth) / cellWidth).floor();
    return fit.clamp(1, indices.length).toInt();
  }
}

/// 按 [style] 选原型；非原型值不该走到这里（调用方先判
/// [AdaptiveNavBarStyle.isOverflowVariant]）。
Widget buildNavOverflowVariant(
  AdaptiveNavBarStyle style,
  NavOverflowSpec spec,
) {
  return switch (style) {
    AdaptiveNavBarStyle.dial => NavDialBar(spec: spec),
    AdaptiveNavBarStyle.modeStrip => NavModeStripBar(spec: spec),
    AdaptiveNavBarStyle.flat => navOverflowPlainRow(spec),
  };
}

/// 全部目的地等宽平铺的一排（原型尚未实现时的占位，也是兜底）。
Widget navOverflowPlainRow(NavOverflowSpec spec) {
  final double cellWidth = spec.width / spec.indices.length;
  return Row(
    children: <Widget>[
      for (final int i in spec.indices)
        Expanded(child: spec.cellBuilder(i, cellWidth)),
    ],
  );
}
