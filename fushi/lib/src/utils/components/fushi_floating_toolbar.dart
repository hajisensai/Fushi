/// 沉浸式媒体页（小说阅读器 / 漫画阅读器 / …）共用的**悬浮工具栏**组件族。
///
/// 依据 Material 3 Expressive 的 Toolbars 规范（m3.material.io/components/toolbars，
/// 2025-05）：底部应用栏（bottom app bar）已被 toolbars 取代，分两种——
///
///  * **docked toolbar**：贴边、整宽、直角、无阴影的实体条（旧形态，阅读器保留为
///    「工具栏样式 = 贴边」选项）；
///  * **floating toolbar**：浮在内容之上的胶囊，横向或纵向，可与 FAB 配对，适合
///    「与正文相关的上下文操作」，在沉浸内容里随点击 / 滚动显隐。规格：容器高 64、
///    全圆角、内边距 8、项间距 4、Elevation 1 起；距窗口边 16（纵向 24）；配色分
///    standard（surfaceContainer）与 vibrant（primaryContainer + onPrimaryContainer）。
///
/// 阅读是典型的沉浸内容，所以默认走 floating：顶部是几颗分离的小胶囊（返回 /
/// 标题胶囊 / 动作按钮组），底部是居中的悬浮工具栏 + FAB，正文真正满屏。
///
/// 本文件与任何具体页面**解耦**——只认 [FushiToolbarItem] 这一份「图标 + 文案 +
/// 回调」描述；页面负责决定放哪些按钮。组件族：
///
///  * [FushiFloatingToolbar]：悬浮工具栏（横 / 纵），可带 [fab] 与「更多」溢出菜单，
///    手机底栏可开 [FushiFloatingToolbar.showLabels]（等宽图标 + 小字标签）。
///  * [FushiFloatingTopBar]：顶部悬浮条：返回胶囊 + 标题胶囊（可点）+ 动作按钮组
///    胶囊 + 更多。三块各自是独立胶囊，不占满宽。
///  * [FushiToolbarFab]：工具栏旁的 FAB；[FushiToolbarFab.morphing] 让它在「圆 ↔
///    圆角方」之间按弹簧变形（M3E 的形状变形播放键：播放 = 圆、暂停 = 方）。
///  * [FushiChromeReveal]：显隐动效容器——位移 + 淡入，走 M3E spatial 弹簧；隐藏
///    时不吃指针、不进语义树；墨水屏 / 减弱动态效果下瞬时切换。
///
/// 两套设计系统：MD3（Expressive 胶囊 + 阴影 + tonal / vibrant 配色）与 Apple
/// （iOS 26 / macOS 26 工具栏：每组按钮一枚透明液态玻璃胶囊、组间留空、bar
/// button 36 / 44、选中 = 强调色字形、标题不装胶囊、FAB = 强调色玻璃圆钮；与
/// [FushiToolbar] 同一材质与度量）。玻璃档位跟随用户的玻璃材质设置（液态 /
/// 磨砂 / 关闭 = 实色），压在原生平台视图上时走库的 BackdropFilter 回退。
/// MD3 颜色默认全取 context 主题；页面可经 [FushiFloatingToolbarColors] 覆盖
/// （阅读器用纸色调和的面，让胶囊落在米色纸上不突兀）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_fill_slot.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show
        fushiAppleInlineSubtitleStyle,
        fushiAppleInlineTitleStyle,
        kFushiAppleInlineTitleRadius;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart'
    show FushiToolbarScope;
import 'package:fushi/src/utils/fushi_icons.dart';

/// M3E 悬浮工具栏容器高（规格 64）。阅读器手机底栏带标签时用它。
const double kFushiFloatingToolbarExtent = 64;

/// 紧凑悬浮条高（顶部胶囊 / 不带标签的桌面工具栏）：56 = 48 触控目标 + 上下 4。
const double kFushiFloatingToolbarCompactExtent = 56;

/// 工具栏内边距（规格 8）。紧凑形态收到 4。
const double kFushiFloatingToolbarPadding = 8;

/// 项间距（规格 4）。
const double kFushiFloatingToolbarItemGap = 4;

/// 距窗口边的外边距：横向 16、纵向 24（规格）。
const double kFushiFloatingToolbarEdgeMargin = 16;
const double kFushiFloatingToolbarVerticalEdgeMargin = 24;

/// 工具栏与 FAB 的间距（规格 8）。
const double kFushiFloatingToolbarFabGap = 8;

/// 带标签项的宽度（等宽格）：图标 24 + 标签 labelSmall 一行。
const double kFushiFloatingToolbarLabeledItemWidth = 64;

/// 工具栏里的一项：图标 + 文案（tooltip / 溢出菜单 / 标签）+ 回调。
///
/// [selected] 画 M3E 选中态（secondaryContainer 胶囊底 + 前景加深）；用于「此刻
/// 打开着的面板」这类状态反馈。
@immutable
class FushiToolbarItem {
  const FushiToolbarItem({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.key,
    this.semanticsId,
    this.tooltip,
  });

  final IconData icon;

  /// 可见文案：只放功能名（快捷键放 [tooltip]，否则窄窗标签被截断）。
  final String label;

  /// 悬停提示（可带快捷键）；null 时用 [label]。
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final Key? key;
  final String? semanticsId;
}

/// 悬浮工具栏配色。null 字段回落到主题：MD3 standard = surfaceContainer /
/// onSurfaceVariant，vibrant = primaryContainer / onPrimaryContainer；Apple =
/// secondaryGroupedBackground / label。
@immutable
class FushiFloatingToolbarColors {
  const FushiFloatingToolbarColors({
    this.container,
    this.foreground,
    this.selectedContainer,
    this.selectedForeground,
  });

  final Color? container;
  final Color? foreground;
  final Color? selectedContainer;
  final Color? selectedForeground;
}

/// M3E 工具栏配色变体。
enum FushiFloatingToolbarVariant { standard, vibrant }

/// 解析后的一套配色（纯函数，供测试）。
({
  Color container,
  Color foreground,
  Color selectedContainer,
  Color selectedForeground,
})
fushiFloatingToolbarPalette(
  BuildContext context, {
  FushiFloatingToolbarVariant variant = FushiFloatingToolbarVariant.standard,
  FushiFloatingToolbarColors? colors,
}) {
  final ThemeData theme = Theme.of(context);
  final ColorScheme scheme = theme.colorScheme;
  final bool glass = isGlassDesign(context);
  final Color container;
  final Color foreground;
  if (glass) {
    final FushiAppleColors apple = appleColorsOf(context);
    // Apple 胶囊是系统材质实色面（[fushiAppleSolidFloatingDecoration]）。
    container = fushiGlassPlatformViewFallback(context);
    foreground = apple.label;
  } else if (variant == FushiFloatingToolbarVariant.vibrant) {
    container = scheme.primaryContainer;
    foreground = scheme.onPrimaryContainer;
  } else {
    container = scheme.surfaceContainer;
    foreground = scheme.onSurfaceVariant;
  }
  // Apple：选中项不铺底（iOS 工具栏 / 标签栏的选中态是强调色字形，没有
  // M3E 的 secondaryContainer 选中胶囊）。
  return (
    container: colors?.container ?? container,
    foreground: colors?.foreground ?? foreground,
    selectedContainer:
        colors?.selectedContainer ??
        (glass ? Colors.transparent : scheme.secondaryContainer),
    selectedForeground:
        colors?.selectedForeground ??
        (glass ? appleColorsOf(context).accent : scheme.onSecondaryContainer),
  );
}

/// Apple 悬浮胶囊 / 工具栏按钮的边长：桌面 36（macOS 26 工具栏）、移动 44
/// （iOS 26 bar button）。与 [FushiIconButtonControl] 的 Apple 触控区同口径。
double fushiAppleFloatingExtent(BuildContext context) =>
    fushiAppleCompact(context) ? 36 : 44;

/// 悬浮胶囊的装饰：全圆角 + 阴影（MD3 Elevation 3 的两层投影 / Apple 柔和单层投影
/// + 发丝描边）。墨水屏不画阴影，改一圈 outline 切出轮廓。
ShapeDecoration fushiFloatingPillDecoration(
  BuildContext context, {
  required Color color,
  OutlinedBorder shape = const StadiumBorder(),
}) {
  final bool eink = isEinkTheme(context);
  final bool glass = isGlassDesign(context);
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final BorderSide side = eink
      ? BorderSide(color: scheme.outline)
      : glass
      ? BorderSide(color: appleColorsOf(context).separator, width: 0.5)
      : BorderSide.none;
  return ShapeDecoration(
    color: color,
    shape: shape.copyWith(side: side),
    shadows: eink
        ? const <BoxShadow>[]
        : glass
        ? <BoxShadow>[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ]
        : <BoxShadow>[
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.18),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.10),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
  );
}

/// 子树里的 [FushiFloatingPill] 不画底（见 [FushiFloatingTopBar.bare]）。
class FushiBareToolbarScope extends InheritedWidget {
  const FushiBareToolbarScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FushiBareToolbarScope>() !=
      null;

  @override
  bool updateShouldNotify(FushiBareToolbarScope oldWidget) => false;
}

/// 一颗悬浮胶囊：MD3 给任意内容套上 [fushiFloatingPillDecoration]（实色 +
/// Elevation 投影）；Apple 是原生 Cupertino 实色面：系统材质实色（或 [color]）
/// + 发丝描边 + 柔和投影，不做玻璃与实时模糊（用户 2026-10-12：玻璃白边、
/// 掉帧）。
class FushiFloatingPill extends StatelessWidget {
  const FushiFloatingPill({
    super.key,
    required this.child,
    required this.color,
    this.padding = const EdgeInsets.all(4),
    this.shape = const StadiumBorder(),
  });

  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  final OutlinedBorder shape;

  @override
  Widget build(BuildContext context) {
    if (FushiBareToolbarScope.of(context)) {
      // 裸图标模式：保留形状裁剪（state layer 不溢出），不画底色与投影。
      return Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: FushiToolbarScope(
          inGlassGroup: isGlassDesign(context),
          child: Padding(padding: padding, child: child),
        ),
      );
    }
    if (isGlassDesign(context)) {
      // Apple：原生 Cupertino 实色悬浮面（无玻璃 / 无实时模糊，见
      // [fushiAppleSolidFloatingDecoration]）；[color] 作底色，阅读器按纸色
      // 传入的面照样生效。
      return DecoratedBox(
        decoration: fushiAppleSolidFloatingDecoration(
          context,
          shape: shape,
          tint: color,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: IconTheme.merge(
            data: IconThemeData(color: appleColorsOf(context).label),
            child: FushiToolbarScope(
              inGlassGroup: true,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: fushiFloatingPillDecoration(
        context,
        color: color,
        shape: shape,
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 工具栏里的一颗按钮：无标签 = M3E 图标按钮（按压变形由
/// [FushiIconButtonControl] 自带）；有标签 = 等宽格（图标 + labelSmall），按压
/// 走 [FushiPressScale] 同款缩放。选中态画 secondaryContainer 胶囊底。
class FushiToolbarButton extends StatelessWidget {
  const FushiToolbarButton({
    super.key,
    required this.item,
    required this.foreground,
    required this.selectedContainer,
    required this.selectedForeground,
    this.showLabel = false,
    this.inlineLabel = false,
    this.iconSize = 24,
  });

  final FushiToolbarItem item;
  final Color foreground;
  final Color selectedContainer;
  final Color selectedForeground;
  final bool showLabel;

  /// 横排「图标 + 文字」胶囊（[FushiFloatingTopBar.inlineLabels]）：选中 = 选中
  /// 胶囊底（颜色过渡走 [fushiMotionDuration]），按压走 [FushiPressScale]。
  final bool inlineLabel;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final Color fg = item.selected ? selectedForeground : foreground;
    final Widget button;
    if (inlineLabel) {
      button = _buildInline(context, fg);
    } else if (!showLabel) {
      final String tooltip = item.tooltip ?? item.label;
      // Apple：玻璃胶囊里的 bar button 是无底的 `.plain` 字形（iOS 26
      // UIBarButtonItemGroup），选中只把字形染成强调色，不再叠一枚选中圆钮
      // （玻璃套玻璃）；字号随 bar button（桌面 18 / 移动 20）。
      final bool apple = isGlassDesign(context);
      final Widget iconButton = FushiIconButtonControl(
        key: item.key,
        icon: FushiIcon(item.icon, color: fg),
        iconSize: apple ? (fushiAppleCompact(context) ? 18 : 20) : iconSize,
        tooltip: tooltip,
        isSelected: apple ? null : item.selected,
        style: item.selected && !apple
            ? IconButton.styleFrom(backgroundColor: selectedContainer)
            : null,
        onPressed: item.onPressed,
      );
      // 纯图标：无障碍名称恒为功能名本身（[FushiToolbarItem.label]）——tooltip
      // 只进语义的「提示」槽，带快捷键时更不该顶替名称。
      button = MergeSemantics(
        child: Semantics(
          label: item.label,
          selected: apple && item.selected ? true : null,
          child: iconButton,
        ),
      );
    } else {
      final TextStyle? labelStyle = Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: fg, height: 1.1);
      button = SizedBox(
        width: kFushiFloatingToolbarLabeledItemWidth,
        child: FushiTooltip(
          message: item.tooltip ?? item.label,
          excludeFromSemantics: true,
          child: InkResponse(
            key: item.key,
            onTap: item.onPressed,
            radius: kFushiFloatingToolbarLabeledItemWidth / 2,
            containedInkWell: false,
            child: Semantics(
              button: true,
              selected: item.selected,
              enabled: item.onPressed != null,
              label: item.label,
              excludeSemantics: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AnimatedContainer(
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      curve: FushiMotion.standard,
                      width: 48,
                      height: 28,
                      decoration: ShapeDecoration(
                        color: item.selected
                            ? selectedContainer
                            : selectedContainer.withValues(alpha: 0),
                        shape: const StadiumBorder(),
                      ),
                      alignment: Alignment.center,
                      child: FushiIcon(item.icon, color: fg, size: iconSize),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.label,
                      style: labelStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (item.semanticsId == null) return button;
    return Semantics(identifier: item.semanticsId, child: button);
  }
}

/// [FushiToolbarButton.inlineLabel] 胶囊的高与内边距（测宽与绘制共用）。
const double _kInlineItemHeight = 40;
const double _kInlineItemPadding = 12;
const double _kInlineItemIconSize = 20;
const double _kInlineItemIconGap = 8;

/// 「图标 + 文字」胶囊的文字字阶（测宽与绘制共用）。
TextStyle? _inlineLabelStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelLarge;

/// 一颗「图标 + 文字」胶囊的宽度（纯函数，测宽用）。
double fushiTopBarInlineItemWidth(BuildContext context, FushiToolbarItem item) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: item.label, style: _inlineLabelStyle(context)),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double width =
      _kInlineItemPadding * 2 +
      _kInlineItemIconSize +
      _kInlineItemIconGap +
      painter.width.ceilToDouble();
  painter.dispose();
  return width;
}

extension on FushiToolbarButton {
  Widget _buildInline(BuildContext context, Color fg) {
    const ShapeBorder shape = StadiumBorder();
    final TextStyle? style = _inlineLabelStyle(context)?.copyWith(color: fg);
    return FushiTooltip(
      message: item.tooltip ?? item.label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: item.selected,
        enabled: item.onPressed != null,
        label: item.label,
        excludeSemantics: true,
        child: FushiPressScale(
          enabled: item.onPressed != null,
          child: AnimatedContainer(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            height: _kInlineItemHeight,
            decoration: ShapeDecoration(
              color: item.selected
                  ? selectedContainer
                  : selectedContainer.withValues(alpha: 0),
              shape: shape,
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: item.key,
                onTap: item.onPressed,
                customBorder: shape,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _kInlineItemPadding,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FushiIcon(
                        item.icon,
                        color: fg,
                        size: _kInlineItemIconSize,
                      ),
                      const SizedBox(width: _kInlineItemIconGap),
                      Text(
                        item.label,
                        style: style,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「更多」溢出菜单按钮（⋯）。[items] 为空时不画。
class FushiToolbarOverflowButton extends StatelessWidget {
  const FushiToolbarOverflowButton({
    super.key,
    required this.items,
    required this.foreground,
    this.axis = Axis.horizontal,
  });

  final List<FushiToolbarItem> items;
  final Color foreground;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return FushiPopupMenuButton<FushiToolbarItem>(
      key: const ValueKey<String>('fushi_floating_toolbar_overflow'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: FushiIcon(
        axis == Axis.horizontal ? FushiIcons.moreHoriz : FushiIcons.more,
        color: foreground,
      ),
      iconSize: isGlassDesign(context)
          ? (fushiAppleCompact(context) ? 18 : 20)
          : 24,
      onSelected: (FushiToolbarItem item) => item.onPressed?.call(),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<FushiToolbarItem>>[
        for (final FushiToolbarItem item in items)
          PopupMenuItem<FushiToolbarItem>(
            key: item.key == null
                ? null
                : ValueKey<String>('fushi_toolbar_overflow_${item.key}'),
            value: item,
            enabled: item.onPressed != null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIcon(item.icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(item.label)),
                // 被收进「⋯」的选中项（筛选类页头窄屏时）：菜单里也要看得出
                // 当前选的是它。
                if (item.selected) ...<Widget>[
                  const SizedBox(width: 12),
                  FushiIcon(FushiIcons.check, size: 18),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// M3E 悬浮工具栏：横 / 纵向胶囊里一排按钮（可分组，组间画细分隔）+ 末尾「更多」，
/// 旁边可挂 [fab]。
///
/// [groups] 是按钮分组（导航类 / 阅读类 / 有声书类 / 工具类…）：组内间距 4，组间
/// 插一条 1×24 的分隔线（M3E button group 的组间留白）。空组自动跳过。
class FushiFloatingToolbar extends StatelessWidget {
  const FushiFloatingToolbar({
    super.key,
    required this.groups,
    this.overflow = const <FushiToolbarItem>[],
    this.fab,
    this.axis = Axis.horizontal,
    this.variant = FushiFloatingToolbarVariant.standard,
    this.colors,
    this.showLabels = false,
    this.compact = false,
    this.excludeFocus = false,
    this.inlineLabel,
  });

  final List<List<FushiToolbarItem>> groups;
  final List<FushiToolbarItem> overflow;

  /// 工具栏旁的 FAB（横向在末尾、纵向在下方），间距 8。
  final Widget? fab;
  final Axis axis;
  final FushiFloatingToolbarVariant variant;
  final FushiFloatingToolbarColors? colors;

  /// 等宽图标 + 小字标签（手机底栏，拇指区）。只对横向生效。
  final bool showLabels;

  /// 紧凑高度（56）——顶部胶囊 / 纵向侧栏用；默认 64（规格）。
  final bool compact;

  /// 纯指针面：整个工具栏不进焦点遍历池（阅读器 chrome 的不变式）。
  final bool excludeFocus;

  /// 哪些按钮画成横排「图标 + 文字」胶囊（[FushiFloatingTopBar.inlineLabels]
  /// 按宽度决定）；null = 全部按原形态。
  final bool Function(FushiToolbarItem item)? inlineLabel;

  /// 工具栏实际高度（横向）/ 宽度（纵向），供页面预留空间（纯函数）。
  static double extentFor({bool compact = false, bool showLabels = false}) =>
      compact && !showLabels
      ? kFushiFloatingToolbarCompactExtent
      : kFushiFloatingToolbarExtent;

  @override
  Widget build(BuildContext context) {
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(
      context,
      variant: variant,
      colors: colors,
    );
    final bool labels = showLabels && axis == Axis.horizontal;
    final double extent = extentFor(compact: compact, showLabels: labels);
    final List<List<FushiToolbarItem>> nonEmpty = <List<FushiToolbarItem>>[
      for (final List<FushiToolbarItem> g in groups)
        if (g.isNotEmpty) g,
    ];
    if (isGlassDesign(context) && !labels) {
      return _buildApple(context, nonEmpty, palette);
    }
    final List<Widget> children = <Widget>[];
    for (int gi = 0; gi < nonEmpty.length; gi++) {
      if (gi > 0) {
        // Apple 带标签的底栏（iOS 26 标签栏式）：组与组之间只留空，不画
        // M3E 的组间细分隔。
        children.add(
          isGlassDesign(context)
              ? const SizedBox.square(dimension: 8)
              : _GroupDivider(
                  axis: axis,
                  color: palette.foreground.withValues(alpha: 0.18),
                ),
        );
      }
      final List<FushiToolbarItem> group = nonEmpty[gi];
      for (int i = 0; i < group.length; i++) {
        if (i > 0) {
          children.add(
            const SizedBox.square(dimension: kFushiFloatingToolbarItemGap),
          );
        }
        children.add(
          FushiToolbarButton(
            item: group[i],
            foreground: palette.foreground,
            selectedContainer: palette.selectedContainer,
            selectedForeground: palette.selectedForeground,
            showLabel: labels,
            inlineLabel: inlineLabel?.call(group[i]) ?? false,
          ),
        );
      }
    }
    if (overflow.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(
          const SizedBox.square(dimension: kFushiFloatingToolbarItemGap),
        );
      }
      children.add(
        FushiToolbarOverflowButton(
          items: overflow,
          foreground: palette.foreground,
          axis: axis,
        ),
      );
    }
    final double pad = compact ? 4 : kFushiFloatingToolbarPadding;
    // 整条只有一颗图标按钮：胶囊塌成一枚圆，按钮经 [FushiFillSlot] 撑满它——
    // state layer 与命中区 = 可见形状（2026-10-09 用户截图：单按钮胶囊里悬停
    // 只亮中间一枚更小的方块）。
    if (children.length == 1 && !labels && axis == Axis.horizontal) {
      final Widget single = FushiFloatingPill(
        key: const ValueKey<String>('fushi_floating_toolbar'),
        color: palette.container,
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
        child: FushiFillSlot.wrap(
          extent: Size.square(extent),
          shape: const CircleBorder(),
          child: children.single,
        ),
      );
      final Widget singleBody = fab == null
          ? single
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                single,
                const SizedBox.square(dimension: kFushiFloatingToolbarFabGap),
                fab!,
              ],
            );
      return excludeFocus ? ExcludeFocus(child: singleBody) : singleBody;
    }
    final Widget bar = ConstrainedBox(
      constraints: axis == Axis.horizontal
          ? BoxConstraints(minHeight: extent)
          : BoxConstraints(minWidth: extent),
      child: FushiFloatingPill(
        key: const ValueKey<String>('fushi_floating_toolbar'),
        color: palette.container,
        padding: axis == Axis.horizontal
            ? EdgeInsets.symmetric(horizontal: pad, vertical: labels ? 2 : 4)
            : EdgeInsets.symmetric(vertical: pad, horizontal: 4),
        child: Flex(
          direction: axis,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
    final Widget body = fab == null
        ? bar
        : Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              bar,
              const SizedBox.square(dimension: kFushiFloatingToolbarFabGap),
              fab!,
            ],
          );
    return excludeFocus ? ExcludeFocus(child: body) : body;
  }

  /// Apple（iOS 26 / macOS 26 工具栏）：每组按钮各收进一枚透明玻璃胶囊，组与
  /// 组之间留 10 的间隙（Safari / Mail 的分组胶囊，与 [FushiToolbar] 同形），
  /// 没有 M3E 的组间细分隔；「⋯」并进最后一组；单按钮的组收成正圆。胶囊高
  /// = bar button 边长（桌面 36 / 移动 44），按钮之间不另加缝。
  Widget _buildApple(
    BuildContext context,
    List<List<FushiToolbarItem>> nonEmpty,
    ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette,
  ) {
    final double extent = fushiAppleFloatingExtent(context);
    final bool compactMetrics = fushiAppleCompact(context);
    final List<List<Widget>> capsules = <List<Widget>>[
      for (final List<FushiToolbarItem> group in nonEmpty)
        <Widget>[
          for (final FushiToolbarItem item in group)
            FushiToolbarButton(
              item: item,
              foreground: palette.foreground,
              selectedContainer: palette.selectedContainer,
              selectedForeground: palette.selectedForeground,
              inlineLabel: inlineLabel?.call(item) ?? false,
            ),
        ],
    ];
    if (overflow.isNotEmpty) {
      final Widget more = FushiToolbarOverflowButton(
        items: overflow,
        foreground: palette.foreground,
        axis: axis,
      );
      if (capsules.isEmpty) {
        capsules.add(<Widget>[more]);
      } else {
        capsules.last.add(more);
      }
    }
    final List<Widget> pills = <Widget>[];
    for (int i = 0; i < capsules.length; i++) {
      if (i > 0) pills.add(const SizedBox.square(dimension: 10));
      final List<Widget> buttons = capsules[i];
      final bool single = buttons.length == 1 && inlineLabel == null;
      pills.add(
        ConstrainedBox(
          constraints: axis == Axis.horizontal
              ? BoxConstraints(minHeight: extent, minWidth: extent)
              : BoxConstraints(minWidth: extent, minHeight: extent),
          child: FushiFloatingPill(
            key: i == 0
                ? const ValueKey<String>('fushi_floating_toolbar')
                : null,
            color: palette.container,
            shape: single ? const CircleBorder() : const StadiumBorder(),
            padding: single
                ? EdgeInsets.zero
                : (axis == Axis.horizontal
                      ? EdgeInsets.symmetric(horizontal: compactMetrics ? 2 : 4)
                      : EdgeInsets.symmetric(vertical: compactMetrics ? 2 : 4)),
            child: Flex(
              direction: axis,
              mainAxisSize: MainAxisSize.min,
              children: buttons,
            ),
          ),
        ),
      );
    }
    final Widget bar = Flex(
      direction: axis,
      mainAxisSize: MainAxisSize.min,
      children: pills,
    );
    final Widget body = fab == null
        ? bar
        : Flex(
            direction: axis,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              bar,
              const SizedBox.square(dimension: kFushiFloatingToolbarFabGap),
              fab!,
            ],
          );
    return excludeFocus ? ExcludeFocus(child: body) : body;
  }
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider({required this.axis, required this.color});

  final Axis axis;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final bool h = axis == Axis.horizontal;
    return Padding(
      padding: h
          ? const EdgeInsets.symmetric(horizontal: 6)
          : const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: h ? 1 : 24,
        height: h ? 24 : 1,
        child: ColoredBox(color: color),
      ),
    );
  }
}

/// 顶部悬浮条：`[返回胶囊] [标题胶囊 ………] [动作按钮组胶囊 + ⋯]`。
///
/// 三块各自独立成胶囊、不占满宽；标题胶囊吃掉中间剩余宽度但内容居左、宽度按内容
/// 收缩（[Flexible]），点它触发 [onTitleTap]（阅读器 = 打开导航）。
///
/// **按宽度自适应溢出**（[adaptiveOverflow]，默认开；用户 2026-10-06「默认展开，
/// 不够空间才折叠更多」）：[actions] 与 [overflow] 按给出顺序（= 优先级，[overflow]
/// 最低）先全部平铺成图标按钮；放不下时从**最低优先级**起依次收进「⋯」，全放得下
/// 就不画「⋯」。标题胶囊保底 [kFushiFloatingTopBarTitleMinWidth]（可省略号压缩），
/// 保底优先于高优先级动作。展开方向带 [kFushiFloatingTopBarOverflowHysteresis] 的
/// 回差，窗口在临界宽度附近缩放时不来回跳。动作胶囊按目标宽度立即布局、不做
/// 尺寸动画——收缩时动画保留的旧宽度会让任意一帧溢出（HBK034）。
///
/// 筛选类页头（更新中心 2026-10-09：`[返回] [域筛选 …]`，没有标题胶囊）用
/// [actionsFollowLeading] 让动作组紧跟返回胶囊排，页面级的低频动作放 [menu]
/// ——它们恒在「⋯」里、不参与平铺，测宽时「⋯」那一格恒被预留。
class FushiFloatingTopBar extends StatefulWidget {
  const FushiFloatingTopBar({
    super.key,
    this.leading = const <FushiToolbarItem>[],
    this.title = '',
    this.subtitle = '',
    this.titleLeading,
    this.onTitleTap,
    this.titleTooltip,
    this.actions = const <List<FushiToolbarItem>>[],
    this.overflow = const <FushiToolbarItem>[],
    this.menu = const <FushiToolbarItem>[],
    this.actionsFollowLeading = false,
    this.inlineLabels = false,
    this.colors,
    this.excludeFocus = false,
    this.adaptiveOverflow = true,
    this.bare = false,
  });

  final List<FushiToolbarItem> leading;
  final String title;
  final String subtitle;

  /// 标题胶囊里排在标题文字前的小组件（如用户头像，约 32 见方）。
  final Widget? titleLeading;
  final VoidCallback? onTitleTap;
  final String? titleTooltip;

  /// 右侧动作按钮组（分组，组间分隔），按优先级从高到低排。
  final List<List<FushiToolbarItem>> actions;

  /// 最低优先级的动作：[adaptiveOverflow] 时宽度够也平铺，否则恒在「⋯」里。
  final List<FushiToolbarItem> overflow;

  /// 恒在「⋯」里的动作（排在被收起的 [actions] / [overflow] 之后）：宽度够也
  /// 不平铺。非空时「⋯」恒在，测宽按「⋯」常驻算。
  final List<FushiToolbarItem> menu;

  /// 无标题胶囊时，动作组紧跟 [leading] 排（筛选紧挨返回键），而不是被推到行尾。
  /// 有标题时不生效（标题胶囊仍在中间吃剩余宽度）。
  final bool actionsFollowLeading;

  /// 动作按「图标 + 文字」胶囊排，宽度不够时逐级降：全部带字 → 只有选中项
  /// 带字（其余纯图标）→ 选中项带字、放不下的按优先级收进「⋯」→ 纯图标
  /// （即默认的自适应溢出）。见 [fushiTopBarLabeledLayout]。[actions] 按一组排
  /// （组间不画分隔），只在没有标题胶囊时生效。筛选类页头用：纯图标认不出是
  /// 哪一类。
  final bool inlineLabels;
  final FushiFloatingToolbarColors? colors;
  final bool excludeFocus;

  /// false = 旧行为：[actions] 恒平铺、[overflow] 恒进「⋯」（布局编辑器的槽位预览用）。
  final bool adaptiveOverflow;

  /// true = 不画悬浮胶囊底（无底色、无投影），只剩裸图标按钮；放在自带背景的
  /// 沉浸页上用（音乐歌词页：右上动作与左上返回同样裸露，用户 2026-10-29）。
  /// 自适应收纳照旧。
  final bool bare;

  @override
  State<FushiFloatingTopBar> createState() => _FushiFloatingTopBarState();
}

/// 顶部悬浮条标题胶囊的保底宽度：动作再多也先保它（书名至少露出几个字）。
const double kFushiFloatingTopBarTitleMinWidth = 160;

/// 自适应溢出的展开回差：多放出一颗按钮需要比「刚好放得下」再多出这么多宽度。
const double kFushiFloatingTopBarOverflowHysteresis = 24;

/// 紧凑工具栏里一颗图标按钮占的横向宽度（48 触控目标 + 4 项间距）。偏大估计——
/// 宁可早一颗收进「⋯」，也不让动作胶囊把标题挤没或溢出。
const double _kTopBarActionSlot = 48 + kFushiFloatingToolbarItemGap;

/// 当前主题下顶栏一颗图标按钮的实际横向占位（含 4 项间距）。M3 `IconButton`
/// 本体 40×40，只有触屏平台（[MaterialTapTargetSize.padded]）才把命中区补到 48；
/// 桌面是 shrinkWrap、实占 40。一律按 48 估会让桌面每颗多算 8，九颗就多出一大截，
/// 明明放得下也被收进「⋯」（2026-10-20 用户截图「还是不够展开」）。Apple 的玻璃
/// bar button 尺寸另算，沿用保守的 [_kTopBarActionSlot]。
double fushiTopBarActionSlotWidth(BuildContext context) {
  if (isGlassDesign(context)) return _kTopBarActionSlot;
  final ThemeData theme = Theme.of(context);
  final double button =
      theme.materialTapTargetSize == MaterialTapTargetSize.padded ? 48 : 40;
  return button + kFushiFloatingToolbarItemGap;
}

/// 组间分隔（1 宽 + 两侧各 6）。
const double _kTopBarGroupDivider = 13;

/// 动作胶囊左右内边距（紧凑形态 4 + 4）。
const double _kTopBarActionsPadding = 8;

/// 一个返回类前置胶囊（48 按钮 + 胶囊内边距 8）+ 其后的 8 间距。
const double _kTopBarLeadingSlot = 48 + 8 + 8;

/// 把 [groups]（高 → 低优先级）+ [overflow]（最低）切成「平铺前 [visible] 颗、
/// 其余进 ⋯」。纯函数，供布局与测试共用。
({List<List<FushiToolbarItem>> groups, List<FushiToolbarItem> overflow})
fushiTopBarSplitActions(
  List<List<FushiToolbarItem>> groups,
  List<FushiToolbarItem> overflow,
  int visible,
) {
  final List<List<FushiToolbarItem>> all = <List<FushiToolbarItem>>[
    for (final List<FushiToolbarItem> g in groups)
      if (g.isNotEmpty) g,
    if (overflow.isNotEmpty) overflow,
  ];
  final List<List<FushiToolbarItem>> shown = <List<FushiToolbarItem>>[];
  final List<FushiToolbarItem> rest = <FushiToolbarItem>[];
  int left = visible;
  for (final List<FushiToolbarItem> g in all) {
    if (left >= g.length) {
      shown.add(g);
      left -= g.length;
    } else {
      if (left > 0) shown.add(g.sublist(0, left));
      rest.addAll(g.sublist(left < 0 ? 0 : left));
      left = 0;
    }
  }
  return (groups: shown, overflow: rest);
}

/// 平铺 [visible] 颗时动作胶囊的估计宽度（含「⋯」）。纯函数。
///
/// [slotWidth] / [padding]：一颗按钮占的横向宽度（含项间距）与两端内边距。默认是
/// 顶栏紧凑图标钮（48 + 4 间距 / 8）；用别的尺寸按钮的调用方（详情页 56 的 tonal
/// 钮 + 8 间距）必须传实际值，否则测宽偏小、全展开时实际溢出。
///
/// [pinnedMenu]：「⋯」恒在（[FushiFloatingTopBar.menu] 非空），即使全部平铺也
/// 占一格。
double fushiTopBarActionsWidth(
  List<List<FushiToolbarItem>> groups,
  List<FushiToolbarItem> overflow,
  int visible, {
  bool pinnedMenu = false,
  double slotWidth = _kTopBarActionSlot,
  double padding = _kTopBarActionsPadding,
}) {
  final ({List<List<FushiToolbarItem>> groups, List<FushiToolbarItem> overflow})
  split = fushiTopBarSplitActions(groups, overflow, visible);
  int items = 0;
  for (final List<FushiToolbarItem> g in split.groups) {
    items += g.length;
  }
  final int buttons = items + (split.overflow.isEmpty && !pinnedMenu ? 0 : 1);
  if (buttons == 0) return 0;
  final int dividers = split.groups.length > 1 ? split.groups.length - 1 : 0;
  return padding + buttons * slotWidth + dividers * _kTopBarGroupDivider;
}

/// 在 [budget] 宽度里最多能平铺几颗（总数 [total]）。
int fushiTopBarFitCount(
  List<List<FushiToolbarItem>> groups,
  List<FushiToolbarItem> overflow,
  int total,
  double budget, {
  bool pinnedMenu = false,
  double slotWidth = _kTopBarActionSlot,
  double padding = _kTopBarActionsPadding,
}) {
  for (int k = total; k > 0; k--) {
    if (fushiTopBarActionsWidth(
          groups,
          overflow,
          k,
          pinnedMenu: pinnedMenu,
          slotWidth: slotWidth,
          padding: padding,
        ) <=
        budget) {
      return k;
    }
  }
  return 0;
}

/// 顶部悬浮条里动作胶囊可用的宽度预算（纯函数）：整行宽减去 [leadingCount] 个
/// 前置胶囊（返回等）、标题胶囊保底 [kFushiFloatingTopBarTitleMinWidth]（有标题时）
/// 与标题和动作之间的 8 间距。
///
/// [titleWidth] 是标题胶囊的自然宽（量得出时给）：标题短于保底宽度时只预留它
/// 实际占的宽，不再按保底宽多扣——「复习」这种两个字的标题按 160 预留会白白
/// 挤掉两三颗放得下的按钮（2026-10-20 用户：「放得下的都没必要折叠吧」）。
double fushiTopBarActionsBudget({
  required double maxWidth,
  int leadingCount = 0,
  required bool hasTitle,
  double? titleWidth,
}) =>
    maxWidth -
    leadingCount * _kTopBarLeadingSlot -
    (hasTitle
        ? math.min(
            titleWidth ?? kFushiFloatingTopBarTitleMinWidth,
            kFushiFloatingTopBarTitleMinWidth,
          )
        : 0) -
    8;

/// 前置圆钮（[FushiFloatingTopBar.leading]）在 [maxWidth] 里平铺几颗（纯函数）。
///
/// 前置圆钮按布局可以不止一颗（阅读器把目录 / 图库 / 统计拖到左上角）。放不下时
/// 从末尾起收进「⋯」——第一颗（返回）恒在——并给「⋯」留出一格（动作胶囊内边距 +
/// 一颗按钮）；全部放得下时只在还有动作要排（[hasActions]）才预留这格。
int fushiTopBarLeadingFitCount({
  required int leadingCount,
  required double maxWidth,
  required bool hasActions,
  double slotWidth = _kTopBarActionSlot,
}) {
  if (leadingCount <= 1 || !maxWidth.isFinite) return leadingCount;
  final double menu = 8 + _kTopBarActionsPadding + slotWidth;
  if (leadingCount * _kTopBarLeadingSlot + (hasActions ? menu : 0) <=
      maxWidth) {
    return leadingCount;
  }
  for (int k = leadingCount - 1; k > 1; k--) {
    if (k * _kTopBarLeadingSlot + menu <= maxWidth) return k;
  }
  return 1;
}

/// 顶部悬浮条「默认展开、放不下才收进 ⋯」的平铺颗数决策（带展开回差）。
///
/// 有状态（记住上一次平铺几颗作回差参照），由持有它的 State 保活；
/// [FushiFloatingTopBar] 与自绘顶栏的页面（漫画阅读器）共用这一份，测宽逻辑只有
/// 一套。动作总数变了回差参照作废。
class FushiTopBarOverflowFit {
  int? _lastVisible;
  int? _lastTotal;

  /// 在 [budget]（见 [fushiTopBarActionsBudget]）里平铺几颗：[groups]（高 → 低
  /// 优先级）+ [overflow]（最低）。宽度无界时全部平铺。
  int visibleFor({
    required List<List<FushiToolbarItem>> groups,
    List<FushiToolbarItem> overflow = const <FushiToolbarItem>[],
    required double budget,
    bool pinnedMenu = false,
    double slotWidth = _kTopBarActionSlot,
    double padding = _kTopBarActionsPadding,
  }) {
    int total = overflow.length;
    for (final List<FushiToolbarItem> g in groups) {
      total += g.length;
    }
    if (!budget.isFinite) return total;
    final int fit = fushiTopBarFitCount(
      groups,
      overflow,
      total,
      budget,
      pinnedMenu: pinnedMenu,
      slotWidth: slotWidth,
      padding: padding,
    );
    final int? last = _lastTotal == total ? _lastVisible : null;
    int visible = fit;
    if (last != null && fit > last) {
      // 展开：多出来的那几颗要连回差一起放得下才放出来，否则维持原样。
      final int strict = fushiTopBarFitCount(
        groups,
        overflow,
        total,
        budget - kFushiFloatingTopBarOverflowHysteresis,
        pinnedMenu: pinnedMenu,
        slotWidth: slotWidth,
        padding: padding,
      );
      visible = strict > last ? strict : last;
    }
    _lastVisible = visible;
    _lastTotal = total;
    return visible;
  }
}

/// [FushiFloatingTopBar.inlineLabels] 的一种排法：[labeled] 里的按钮带字，
/// [shown] 平铺（保持原顺序），[hidden] 进「⋯」。rank 越大越宽松，用于展开
/// 回差比较。
typedef FushiTopBarLabeledLayout = ({
  int rank,
  List<FushiToolbarItem> shown,
  List<FushiToolbarItem> hidden,
  Set<FushiToolbarItem> labeled,
});

/// rank 不设上限。
const int kFushiTopBarLabeledRankAny = 1000000;

/// [FushiFloatingTopBar.inlineLabels] 的排法决策（纯函数）：在 [budget] 里按
/// 「全部带字 → 只有选中项带字 → 选中项带字 + 低优先级收进 ⋯ → 纯图标自适应
/// 溢出」取第一个放得下、且 rank 不超过 [maxRank] 的排法。[items] 按优先级
/// 从高到低；[labeledWidth] 给出一颗带字胶囊的宽度。选中项（若有）在带字的
/// 几档里恒平铺。
FushiTopBarLabeledLayout fushiTopBarLabeledLayout({
  required List<FushiToolbarItem> items,
  required double Function(FushiToolbarItem item) labeledWidth,
  required double budget,
  bool pinnedMenu = false,
  int maxRank = kFushiTopBarLabeledRankAny,
}) {
  const double gap = kFushiFloatingToolbarItemGap;
  final double menuSlot = pinnedMenu ? _kTopBarActionSlot : 0;
  final int n = items.length;
  if (999 <= maxRank) {
    double width = _kTopBarActionsPadding + menuSlot;
    for (final FushiToolbarItem item in items) {
      width += labeledWidth(item) + gap;
    }
    if (width <= budget) {
      return (
        rank: 999,
        shown: items,
        hidden: const <FushiToolbarItem>[],
        labeled: items.toSet(),
      );
    }
  }
  final int selectedIndex = items.indexWhere(
    (FushiToolbarItem item) => item.selected,
  );
  if (selectedIndex >= 0) {
    final FushiToolbarItem selected = items[selectedIndex];
    final double selectedCost = labeledWidth(selected) + gap;
    if (998 <= maxRank &&
        _kTopBarActionsPadding +
                selectedCost +
                (n - 1) * _kTopBarActionSlot +
                menuSlot <=
            budget) {
      return (
        rank: 998,
        shown: items,
        hidden: const <FushiToolbarItem>[],
        labeled: <FushiToolbarItem>{selected},
      );
    }
    // 有东西收进 ⋯：⋯ 恒占一格。
    final List<FushiToolbarItem> others = <FushiToolbarItem>[
      for (final FushiToolbarItem item in items)
        if (!identical(item, selected)) item,
    ];
    for (int k = n - 2; k >= 0; k--) {
      if (100 + k > maxRank) continue;
      final double width =
          _kTopBarActionsPadding +
          selectedCost +
          _kTopBarActionSlot +
          k * _kTopBarActionSlot;
      if (width > budget) continue;
      final Set<FushiToolbarItem> keep = <FushiToolbarItem>{
        selected,
        ...others.take(k),
      };
      return (
        rank: 100 + k,
        shown: <FushiToolbarItem>[
          for (final FushiToolbarItem item in items)
            if (keep.contains(item)) item,
        ],
        hidden: <FushiToolbarItem>[
          for (final FushiToolbarItem item in items)
            if (!keep.contains(item)) item,
        ],
        labeled: <FushiToolbarItem>{selected},
      );
    }
  }
  // 纯图标：与默认自适应溢出同一套测宽。
  final List<List<FushiToolbarItem>> groups = <List<FushiToolbarItem>>[items];
  for (int v = n < maxRank ? n : maxRank; v > 0; v--) {
    if (fushiTopBarActionsWidth(
          groups,
          const <FushiToolbarItem>[],
          v,
          pinnedMenu: pinnedMenu,
        ) <=
        budget) {
      return (
        rank: v,
        shown: items.sublist(0, v),
        hidden: items.sublist(v),
        labeled: const <FushiToolbarItem>{},
      );
    }
  }
  return (
    rank: 0,
    shown: const <FushiToolbarItem>[],
    hidden: items,
    labeled: const <FushiToolbarItem>{},
  );
}

class _FushiFloatingTopBarState extends State<FushiFloatingTopBar> {
  /// [FushiFloatingTopBar.inlineLabels] 上一次的排法 rank（展开回差参照）。
  int? _lastLabeledRank;

  /// 上一次排法时的选中项（按 label 认）。选中项一变，带字的那颗宽度就变了，
  /// rank 不再可比（进页面时从「无选中」到「有选中」也属此类），回差参照作废。
  String? _lastLabeledSelection;

  /// 带字排法 + 展开回差：更宽松的排法要连回差一起放得下才换过去。
  FushiTopBarLabeledLayout _labeledLayoutFor(
    double maxWidth, {
    required int leadingCount,
  }) {
    final List<FushiToolbarItem> items = <FushiToolbarItem>[
      for (final List<FushiToolbarItem> g in actions) ...g,
      ...overflow,
    ];
    final double budget = _actionsBudget(
      maxWidth,
      hasTitle: false,
      leadingCount: leadingCount,
    );
    double width(FushiToolbarItem item) =>
        fushiTopBarInlineItemWidth(context, item);
    FushiTopBarLabeledLayout at(
      double b, {
      int cap = kFushiTopBarLabeledRankAny,
    }) => fushiTopBarLabeledLayout(
      items: items,
      labeledWidth: width,
      budget: b,
      pinnedMenu: widget.menu.isNotEmpty,
      maxRank: cap,
    );
    if (!budget.isFinite) return at(double.maxFinite);
    FushiTopBarLabeledLayout layout = at(budget);
    final String? selection = <String?>[
      for (final FushiToolbarItem item in items)
        if (item.selected) item.label,
      null,
    ].first;
    final int? last = selection == _lastLabeledSelection
        ? _lastLabeledRank
        : null;
    _lastLabeledSelection = selection;
    if (last != null && layout.rank > last) {
      final FushiTopBarLabeledLayout strict = at(
        budget - kFushiFloatingTopBarOverflowHysteresis,
      );
      layout = strict.rank >= last ? strict : at(budget, cap: last);
    }
    _lastLabeledRank = layout.rank;
    return layout;
  }

  List<FushiToolbarItem> get leading => widget.leading;
  String get title => widget.title;
  String get subtitle => widget.subtitle;
  VoidCallback? get onTitleTap => widget.onTitleTap;
  String? get titleTooltip => widget.titleTooltip;
  List<List<FushiToolbarItem>> get actions => widget.actions;
  List<FushiToolbarItem> get overflow => widget.overflow;
  FushiFloatingToolbarColors? get colors => widget.colors;
  bool get excludeFocus => widget.excludeFocus;

  /// 平铺颗数决策（带展开回差，见 [FushiTopBarOverflowFit]）。
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();

  /// 按可用宽度定平铺颗数（带展开回差）。
  int _visibleFor(
    double maxWidth, {
    required bool hasTitle,
    required int leadingCount,
    double? titleWidth,
    bool menuPinned = false,
  }) {
    if (!widget.adaptiveOverflow) {
      int total = 0;
      for (final List<FushiToolbarItem> g in actions) {
        total += g.length;
      }
      return total;
    }
    return _fit.visibleFor(
      groups: actions,
      overflow: overflow,
      budget: _actionsBudget(
        maxWidth,
        hasTitle: hasTitle,
        leadingCount: leadingCount,
        titleWidth: titleWidth,
      ),
      pinnedMenu: menuPinned || widget.menu.isNotEmpty,
      slotWidth: fushiTopBarActionSlotWidth(context),
    );
  }

  /// 动作组的宽度预算：两条测宽路径（带字排法 / 自适应溢出）共用。
  ///
  /// [fushiTopBarActionsBudget] 末尾减的 8 是行尾动作组前那段间距；
  /// [FushiFloatingTopBar.actionsFollowLeading] 生效（无标题）时动作组紧跟前置
  /// 胶囊排、前面没有这段间距（前置胶囊那格的 8 已计入 leading slot；没有前置
  /// 胶囊时动作组就是行首），预算加回 8——与 build 里 `follow` 的 Row 排法一致。
  double _actionsBudget(
    double maxWidth, {
    required bool hasTitle,
    required int leadingCount,
    double? titleWidth,
  }) =>
      fushiTopBarActionsBudget(
        maxWidth: maxWidth,
        leadingCount: leadingCount,
        hasTitle: hasTitle,
        titleWidth: titleWidth,
      ) +
      (widget.actionsFollowLeading && !hasTitle ? 8 : 0);

  /// Material 标题胶囊的自然宽（文字 + 两侧各 16 内边距），与下面 build 里
  /// 胶囊同字体、同文字缩放。带 [FushiFloatingTopBar.titleLeading]（宽度未知）
  /// 或 Apple 设计系统时返回 null，测宽按保底宽预留。
  double? _materialTitleWidth(BuildContext context, String t, String s) {
    if (widget.titleLeading != null || isGlassDesign(context)) return null;
    final TextTheme text = Theme.of(context).textTheme;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    double measure(String value, TextStyle? style) {
      if (value.isEmpty) return 0;
      final TextPainter painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double width = painter.width;
      painter.dispose();
      return width;
    }

    final double textWidth = math.max(
      measure(
        t,
        text.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
      ),
      measure(s, text.labelSmall?.copyWith(height: 1.15)),
    );
    return textWidth.ceilToDouble() + 32 + 2;
  }

  /// Apple 的标题：iOS 26 / macOS 26 导航栏的内联标题不装进玻璃——玻璃只给
  /// 栏上的控件。纯文字（移动 17 semibold / 桌面 15 semibold，label 色；
  /// 副标题 secondaryLabel），可点时按下变淡，没有水波纹。
  Widget _appleTitle(
    BuildContext context,
    String t,
    String s,
    Widget? titleLeading,
  ) {
    final FushiAppleColors apple = appleColorsOf(context);
    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: fushiAppleFloatingExtent(context)),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (titleLeading != null) ...<Widget>[
              titleLeading,
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (t.isNotEmpty)
                    Text(
                      t,
                      key: const ValueKey<String>(
                        'fushi_floating_top_bar_title_text',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: fushiAppleInlineTitleStyle(context).copyWith(
                        color: colors?.foreground ?? apple.label,
                        height: 1.15,
                      ),
                    ),
                  if (s.isNotEmpty)
                    Text(
                      s,
                      key: const ValueKey<String>(
                        'fushi_floating_top_bar_subtitle_text',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: fushiAppleInlineSubtitleStyle(
                        context,
                      ).copyWith(height: 1.15),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final Widget body = FushiTooltip(
      message: titleTooltip ?? '',
      excludeFromSemantics: true,
      child: content,
    );
    return KeyedSubtree(
      key: const ValueKey<String>('fushi_floating_top_bar_title'),
      child: onTitleTap == null
          ? body
          : FushiPlainButton(
              onPressed: onTitleTap,
              borderRadius: kFushiAppleInlineTitleRadius,
              child: body,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(context, colors: colors);
    final ThemeData theme = Theme.of(context);
    final bool hasActions =
        actions.any((List<FushiToolbarItem> g) => g.isNotEmpty) ||
        overflow.isNotEmpty ||
        widget.menu.isNotEmpty;
    final String t = title.trim();
    final String s = subtitle.trim();
    final Widget? titleLeading = widget.titleLeading;
    final bool apple = isGlassDesign(context);
    final double leadingExtent = apple
        ? fushiAppleFloatingExtent(context)
        : kFushiFloatingToolbarCompactExtent;
    final Widget? titlePill = t.isEmpty && s.isEmpty && titleLeading == null
        ? null
        : apple
        ? _appleTitle(context, t, s, titleLeading)
        : FushiFloatingPill(
            key: const ValueKey<String>('fushi_floating_top_bar_title'),
            color: palette.container,
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: onTitleTap,
              child: FushiTooltip(
                message: titleTooltip ?? '',
                excludeFromSemantics: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: kFushiFloatingToolbarCompactExtent,
                  ),
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: titleLeading == null ? 16 : 6,
                      end: 16,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (titleLeading != null) ...<Widget>[
                          titleLeading,
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (t.isNotEmpty)
                                Text(
                                  t,
                                  key: const ValueKey<String>(
                                    'fushi_floating_top_bar_title_text',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    color: palette.foreground,
                                    fontWeight: FontWeight.w700,
                                    height: 1.15,
                                  ),
                                ),
                              if (s.isNotEmpty)
                                Text(
                                  s,
                                  key: const ValueKey<String>(
                                    'fushi_floating_top_bar_subtitle_text',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: palette.foreground.withValues(
                                      alpha: 0.7,
                                    ),
                                    height: 1.15,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
    final Widget row = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 前置圆钮放不下时从末尾起收进「⋯」（排在被收起的动作之前）。
        final int leadingShown = widget.adaptiveOverflow
            ? fushiTopBarLeadingFitCount(
                leadingCount: leading.length,
                maxWidth: constraints.maxWidth,
                hasActions: hasActions,
                slotWidth: fushiTopBarActionSlotWidth(context),
              )
            : leading.length;
        final List<FushiToolbarItem> foldedLeading = leading.sublist(
          leadingShown,
        );
        final FushiTopBarLabeledLayout? labeled =
            widget.inlineLabels && titlePill == null
            ? _labeledLayoutFor(
                constraints.maxWidth,
                leadingCount: leadingShown,
              )
            : null;
        final ({
          List<List<FushiToolbarItem>> groups,
          List<FushiToolbarItem> overflow,
        })
        split = labeled != null
            ? (
                groups: <List<FushiToolbarItem>>[labeled.shown],
                overflow: labeled.hidden,
              )
            : widget.adaptiveOverflow
            ? fushiTopBarSplitActions(
                actions,
                overflow,
                _visibleFor(
                  constraints.maxWidth,
                  hasTitle: titlePill != null,
                  leadingCount: leadingShown,
                  // 收起的前置钮在「⋯」里：⋯ 恒占一格。
                  menuPinned: foldedLeading.isNotEmpty,
                  titleWidth: titlePill == null
                      ? null
                      : _materialTitleWidth(context, t, s),
                ),
              )
            : (groups: actions, overflow: overflow);
        final Widget? toolbar = hasActions || foldedLeading.isNotEmpty
            // 不做尺寸动画（HBK034）：AnimatedSize 收缩时会保留旧宽度一帧，窗口
            // 骤缩时右侧溢出。按目标宽度立即布局，防抖靠展开回差。
            ? FushiFloatingToolbar(
                groups: split.groups,
                overflow: <FushiToolbarItem>[
                  ...foldedLeading,
                  ...split.overflow,
                  ...widget.menu,
                ],
                colors: colors,
                compact: true,
                inlineLabel: labeled == null
                    ? null
                    : (FushiToolbarItem item) => labeled.labeled.contains(item),
              )
            : null;
        // 无标题的筛选类页头：动作组紧跟返回胶囊，剩余宽度留在行尾。
        final bool follow =
            widget.actionsFollowLeading && titlePill == null && toolbar != null;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (final FushiToolbarItem item in leading.take(
              leadingShown,
            )) ...<Widget>[
              // 前置键（返回等）就是一枚圆：按钮经 [FushiFillSlot] 撑满整枚圆，
              // 悬停 / 按下的 state layer 与命中区 = 可见形状。
              FushiFloatingPill(
                color: palette.container,
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
                child: FushiFillSlot.wrap(
                  extent: Size.square(leadingExtent),
                  shape: const CircleBorder(),
                  child: FushiToolbarButton(
                    item: item,
                    foreground: palette.foreground,
                    selectedContainer: palette.selectedContainer,
                    selectedForeground: palette.selectedForeground,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (follow) toolbar,
            // 标题胶囊按内容收缩、最多吃满中间剩余宽度（超长书名省略号）。
            Expanded(
              child: titlePill == null
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: titlePill,
                    ),
            ),
            if (toolbar != null && !follow) ...<Widget>[
              const SizedBox(width: 8),
              toolbar,
            ],
          ],
        );
      },
    );
    final Widget bar = widget.bare ? FushiBareToolbarScope(child: row) : row;
    return excludeFocus ? ExcludeFocus(child: bar) : bar;
  }
}

/// 工具栏旁的 FAB（M3E：工具栏 + FAB 配对）。MD3 = 56 方形、圆角 16、
/// primaryContainer；[morphing] 时在圆（[rounded] = false）与圆角方之间按弹簧
/// 变形——播放键：播放态 = 圆角方（「正在进行」），暂停态 = 圆。Apple = 圆形
/// 强调色按钮，不变形（iOS 没有形状变形语汇）。
class FushiToolbarFab extends StatefulWidget {
  const FushiToolbarFab({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.rounded = true,
    this.morphing = false,
    this.size = 56,
    this.semanticsId,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// true = 圆角方（radius 16），false = 圆。只在 [morphing] 时随值变形；不变形
  /// 的 FAB 恒为圆角方（M3E FAB 默认形）。
  final bool rounded;
  final bool morphing;
  final double size;
  final String? semanticsId;

  @override
  State<FushiToolbarFab> createState() => _FushiToolbarFabState();
}

class _FushiToolbarFabState extends State<FushiToolbarFab>
    with TickerProviderStateMixin {
  late final FushiSpring _shape = FushiSpring(
    vsync: this,
    initial: widget.rounded || !widget.morphing ? 0 : 1,
    spring: fushiExpressiveDefaultSpatial,
  );

  @override
  void didUpdateWidget(FushiToolbarFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _shape.animateTo(
      widget.rounded || !widget.morphing ? 0 : 1,
      animate: fushiExpressiveMotionEnabled(context),
    );
  }

  @override
  void dispose() {
    _shape.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool glass = isGlassDesign(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color bg = glass
        ? appleColorsOf(context).accent
        : scheme.primaryContainer;
    final Color fg = glass
        ? appleColorsOf(context).onAccent
        : scheme.onPrimaryContainer;
    final Widget icon = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> a) => ScaleTransition(
        scale: a,
        child: FadeTransition(opacity: a, child: child),
      ),
      child: FushiIcon(
        widget.icon,
        key: ValueKey<IconData>(widget.icon),
        color: fg,
        size: 28,
      ),
    );
    if (glass) {
      // Apple：原生 Cupertino 强调色实色圆钮 + 柔和投影（无玻璃 / 实时模糊），
      // 不变形（iOS 没有形状变形语汇），按下变淡而不是水波纹。
      final double extent = widget.size < fushiAppleFloatingExtent(context)
          ? widget.size
          : fushiAppleFloatingExtent(context) + 4;
      Widget apple = DecoratedBox(
        decoration: fushiAppleSolidFloatingDecoration(
          context,
          shape: const CircleBorder(),
          tint: bg,
        ),
        child: FushiPlainButton(
          key: const ValueKey<String>('fushi_toolbar_fab'),
          onPressed: widget.onPressed,
          borderRadius: BorderRadius.all(Radius.circular(extent / 2)),
          child: SizedBox.square(
            dimension: extent,
            child: Center(
              child: FushiIcon(
                widget.icon,
                key: ValueKey<IconData>(widget.icon),
                color: fg,
                size: fushiAppleCompact(context) ? 18 : 22,
              ),
            ),
          ),
        ),
      );
      apple = FushiTooltip(
        message: widget.tooltip,
        child: Semantics(
          button: true,
          label: widget.tooltip,
          identifier: widget.semanticsId,
          child: apple,
        ),
      );
      return apple;
    }
    Widget button = AnimatedBuilder(
      animation: _shape.animation,
      builder: (BuildContext context, Widget? child) {
        // 0 = 圆角方（16），1 = 圆（pill）。Apple 恒圆。
        final double pill = glass ? 1 : _shape.value.clamp(0.0, 1.0);
        final OutlinedBorder shape = FushiMorphBorder(
          radius: 16,
          startPill: pill,
          endPill: pill,
        );
        return SizedBox.square(
          dimension: widget.size,
          child: DecoratedBox(
            decoration: fushiFloatingPillDecoration(
              context,
              color: bg,
              shape: shape,
            ),
            child: Material(
              type: MaterialType.transparency,
              shape: shape,
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        );
      },
      child: InkWell(
        key: const ValueKey<String>('fushi_toolbar_fab'),
        onTap: widget.onPressed,
        child: Center(child: icon),
      ),
    );
    button = FushiTooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        identifier: widget.semanticsId,
        child: button,
      ),
    );
    return button;
  }
}

/// chrome 显隐动效：[visible] 翻转时按 M3E spatial 弹簧把 [child] 从 [from] 方向
/// 滑入 / 滑出并淡入淡出。隐藏态 IgnorePointer + ExcludeSemantics，且在完全隐藏后
/// 不再绘制（Offstage 不画但保留状态，不重建子树）。墨水屏 / 减弱动态效果下瞬时。
class FushiChromeReveal extends StatefulWidget {
  const FushiChromeReveal({
    super.key,
    required this.visible,
    required this.child,
    this.from = AxisDirection.up,
    this.distance = 24,
  });

  final bool visible;
  final Widget child;

  /// 滑入的来向：顶部条 = up（从上方落下），底部条 = down，右侧竖条 = right。
  final AxisDirection from;

  /// 滑动距离（逻辑 px）。
  final double distance;

  @override
  State<FushiChromeReveal> createState() => _FushiChromeRevealState();
}

class _FushiChromeRevealState extends State<FushiChromeReveal>
    with TickerProviderStateMixin {
  late final FushiSpring _t = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    // 出现走 default spatial（带一点回弹的落位），消失同一弹簧收回。
    spring: SpringDescription.withDampingRatio(
      mass: 1,
      stiffness: 520,
      ratio: 0.82,
    ),
  );

  /// 透明度：M3E default effects 弹簧（临界阻尼、不过冲）。透明度是 effects
  /// 属性，不跟位移共用上面的 spatial 弹簧（HBK-AUDIT-023）；同目标、同一
  /// 降级开关。
  late final FushiSpring _fade = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: FushiSprings.effectsDefault.description,
  );

  @override
  void didUpdateWidget(FushiChromeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      final bool animate = fushiMotionEnabled(context);
      _t.animateTo(widget.visible ? 1 : 0, animate: animate);
      _fade.animateTo(widget.visible ? 1 : 0, animate: animate);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _fade.dispose();
    super.dispose();
  }

  Offset _offsetFor(double v) {
    final double d = (1 - v) * widget.distance;
    return switch (widget.from) {
      AxisDirection.up => Offset(0, -d),
      AxisDirection.down => Offset(0, d),
      AxisDirection.left => Offset(-d, 0),
      AxisDirection.right => Offset(d, 0),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_t.animation, _fade.animation]),
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double v = _t.value;
        final double opacity = _fade.value.clamp(0.0, 1.0);
        final bool hidden = !widget.visible && v <= 0.001 && opacity <= 0.001;
        return Offstage(
          offstage: hidden,
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: ExcludeSemantics(
              excluding: !widget.visible,
              child: Opacity(
                opacity: opacity,
                child: Transform.translate(offset: _offsetFor(v), child: child),
              ),
            ),
          ),
        );
      },
    );
  }
}
