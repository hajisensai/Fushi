import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart' show FushiFocusId;
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavItem;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show fushiAppleSolidFloatingDecoration, fushiGlassPlatformViewFallback;
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_dial_bar.dart';
import 'package:fushi/src/utils/adaptive/nav_overflow/nav_mode_strip_bar.dart';

/// 悬浮胶囊**内部**交给「放不下的入口」交互原型画的那一块（2026-10-23；
/// 2026-10-30 起 MD3 与 Apple 两套胶囊都接，见 [NavOverflowPalette]）。
///
/// 胶囊底色、圆角、投影、随滚动收起、右侧 FAB / 查词圆钮都仍由宿主
/// （MD3 `_MaterialFloatingBar` / Apple `_GlassTabCapsule`）画；原型只负责
/// 胶囊里的这一排（[width] × [height]），需要冒出胶囊的部分（转盘）用
/// [OverlayPortal] 画到上层。
class NavOverflowSpec {
  const NavOverflowSpec({
    required this.items,
    required this.indices,
    required this.currentIndex,
    required this.onSelect,
    required this.cellBuilder,
    required this.width,
    required this.height,
    this.focusIdPrefix,
  });

  /// 原型自己画的可聚焦件登记进 FushiFocus 的焦点 id 前缀（宿主传 `nav-bar`）：
  /// 模式条每一项是 `<前缀>-<序号>`（与 [cellBuilder] 画的格同一套），转盘
  /// 旋钮是 `<前缀>-dial`。null = 不登记（只走 Flutter 自己的 Tab 遍历）。
  final String? focusIdPrefix;

  /// 第 [index] 个目的地的焦点 id；[focusIdPrefix] 为 null 时为 null。
  FushiFocusId? focusIdOf(int index) {
    final String? prefix = focusIdPrefix;
    return prefix == null ? null : FushiFocusId('$prefix-$index');
  }

  /// 转盘旋钮的焦点 id；[focusIdPrefix] 为 null 时为 null。
  FushiFocusId? get dialFocusId {
    final String? prefix = focusIdPrefix;
    return prefix == null ? null : FushiFocusId('$prefix-dial');
  }

  /// 底栏全部目的地（含已拆成 FAB 的查词，序号与 [currentIndex] 同一套）。
  final List<AdaptiveNavItem> items;

  /// 进胶囊的目的地序号，按视觉顺序（不含 FAB 那一项）。
  final List<int> indices;

  /// 当前选中的目的地序号；可能不在 [indices] 里（当前是 FAB 那一项）。
  final int currentIndex;

  /// 跳到某个目的地（参数是 [items] 的序号）。已带选中触觉与模块切换转场，
  /// 原型直接调，不要再自己发触觉。
  final ValueChanged<int> onSelect;

  /// 画一个标准目的地格（与平铺同一个焦点格：选中高亮、手柄焦点、
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

/// 原型的配色与形状语汇，按设计系统取（2026-10-30 用户拍板「Apple 下也要
/// 真正画出拇指转盘与相机模式条」：同一套交互，视觉换成 Apple）。
///
/// - MD3：tertiary 一族；选中高亮是目的地的 M3E 专属多边形（[polygons]）。
/// - Apple：强调色 / label 一族；模式条的选中高亮是与平铺 Apple 标签栏同款
///   的中性 lens（实色档高一阶底 / 玻璃档 label 透明 + 细高光边 + 柔和投影），
///   选中图标着强调色；转盘对准项是强调色实底圆（同 Apple 侧栏选中行）。
///   M3E 多边形是 Material 3 Expressive 的形状语汇，Apple 不画。
///   转盘盘面是 Apple 悬浮面的系统材质实色 + 发丝描边，不做玻璃
///   （[fushiAppleSolidFloatingDecoration] 同一材质）。
@immutable
class NavOverflowPalette {
  const NavOverflowPalette({
    required this.apple,
    required this.accent,
    required this.onAccent,
    required this.content,
    required this.plate,
    required this.highlight,
    required this.onHighlight,
    required this.scrim,
    required this.shadow,
    this.plateEdge,
    this.highlightRim,
    this.highlightShadows,
  });

  /// 按 [context] 的设计系统取（墨水屏下 [isGlassDesign] 恒 false，走 MD3）。
  factory NavOverflowPalette.of(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (!isGlassDesign(context)) {
      return NavOverflowPalette(
        apple: false,
        accent: scheme.tertiary,
        onAccent: scheme.onTertiary,
        content: scheme.onTertiaryContainer,
        plate: scheme.tertiaryContainer,
        highlight: scheme.tertiary,
        onHighlight: scheme.onTertiary,
        scrim: scheme.scrim,
        shadow: scheme.shadow,
      );
    }
    final FushiAppleColors apple = appleColorsOf(context);
    final bool dark = scheme.brightness == Brightness.dark;
    final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
    return NavOverflowPalette(
      apple: true,
      accent: apple.accent,
      onAccent: apple.onAccent,
      content: apple.label,
      plate: fushiGlassPlatformViewFallback(context),
      plateEdge: dark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.08),
      highlight: solid
          ? apple.tertiaryGroupedBackground
          : apple.label.withValues(alpha: dark ? 0.16 : 0.1),
      onHighlight: apple.accent,
      highlightRim: solid
          ? null
          : Border.all(
              color: Colors.white.withValues(alpha: dark ? 0.22 : 0.5),
              width: 0.8,
            ),
      highlightShadows: solid
          ? null
          : <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
      scrim: Colors.black,
      shadow: Colors.black,
    );
  }

  /// Apple 设计系统：高亮画圆 / 胶囊 lens，不画 M3E 多边形。
  final bool apple;

  /// MD3 画专属多边形（[navShapeOf]）；Apple 画圆。
  bool get polygons => !apple;

  /// 强调件（转盘对准项底、指针、旋钮指示点、名字气泡）与其上的前景。
  final Color accent;
  final Color onAccent;

  /// 未选中图标 / 刻度的前景。
  final Color content;

  /// 转盘盘面；[plateEdge] 是 Apple 的发丝描边（MD3 无）。
  final Color plate;
  final Color? plateEdge;

  /// 模式条（及 Apple 转盘胶囊固定格）的选中高亮底与其上的选中图标色。
  final Color highlight;
  final Color onHighlight;

  /// Apple 玻璃档 lens 的细高光边与投影（实色档 / MD3 为 null）。
  final Border? highlightRim;
  final List<BoxShadow>? highlightShadows;

  final Color scrim;
  final Color shadow;
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
