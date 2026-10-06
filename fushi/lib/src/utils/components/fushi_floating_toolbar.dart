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
/// （iOS 26 浮动材质胶囊：分组底色的近不透明面 + 发丝描边 + 柔和投影，不做实时
/// 模糊——阅读器背后是平台视图，逐帧 BackdropFilter 在 Android 上掉帧，BUG-969）。
/// 颜色默认全取 context 主题；页面可经 [FushiFloatingToolbarColors] 覆盖（阅读器
/// 用纸色调和的面，让胶囊落在米色纸上不突兀）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
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
    container = apple.secondaryGroupedBackground;
    foreground = apple.label;
  } else if (variant == FushiFloatingToolbarVariant.vibrant) {
    container = scheme.primaryContainer;
    foreground = scheme.onPrimaryContainer;
  } else {
    container = scheme.surfaceContainer;
    foreground = scheme.onSurfaceVariant;
  }
  return (
    container: colors?.container ?? container,
    foreground: colors?.foreground ?? foreground,
    selectedContainer:
        colors?.selectedContainer ??
        (glass ? appleColorsOf(context).accent : scheme.secondaryContainer),
    selectedForeground:
        colors?.selectedForeground ??
        (glass ? appleColorsOf(context).onAccent : scheme.onSecondaryContainer),
  );
}

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

/// 一颗悬浮胶囊：给任意内容套上 [fushiFloatingPillDecoration]。
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
    this.iconSize = 24,
  });

  final FushiToolbarItem item;
  final Color foreground;
  final Color selectedContainer;
  final Color selectedForeground;
  final bool showLabel;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final Color fg = item.selected ? selectedForeground : foreground;
    final Widget button;
    if (!showLabel) {
      button = FushiIconButtonControl(
        key: item.key,
        icon: FushiIcon(item.icon, color: fg),
        iconSize: iconSize,
        tooltip: item.tooltip ?? item.label,
        isSelected: item.selected,
        style: item.selected
            ? IconButton.styleFrom(backgroundColor: selectedContainer)
            : null,
        onPressed: item.onPressed,
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
      iconSize: 24,
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
    final List<Widget> children = <Widget>[];
    for (int gi = 0; gi < nonEmpty.length; gi++) {
      if (gi > 0) {
        children.add(
          _GroupDivider(
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
class FushiFloatingTopBar extends StatefulWidget {
  const FushiFloatingTopBar({
    super.key,
    this.leading = const <FushiToolbarItem>[],
    this.title = '',
    this.subtitle = '',
    this.onTitleTap,
    this.titleTooltip,
    this.actions = const <List<FushiToolbarItem>>[],
    this.overflow = const <FushiToolbarItem>[],
    this.colors,
    this.excludeFocus = false,
    this.adaptiveOverflow = true,
  });

  final List<FushiToolbarItem> leading;
  final String title;
  final String subtitle;
  final VoidCallback? onTitleTap;
  final String? titleTooltip;

  /// 右侧动作按钮组（分组，组间分隔），按优先级从高到低排。
  final List<List<FushiToolbarItem>> actions;

  /// 最低优先级的动作：[adaptiveOverflow] 时宽度够也平铺，否则恒在「⋯」里。
  final List<FushiToolbarItem> overflow;
  final FushiFloatingToolbarColors? colors;
  final bool excludeFocus;

  /// false = 旧行为：[actions] 恒平铺、[overflow] 恒进「⋯」（布局编辑器的槽位预览用）。
  final bool adaptiveOverflow;

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
double fushiTopBarActionsWidth(
  List<List<FushiToolbarItem>> groups,
  List<FushiToolbarItem> overflow,
  int visible,
) {
  final ({List<List<FushiToolbarItem>> groups, List<FushiToolbarItem> overflow})
  split = fushiTopBarSplitActions(groups, overflow, visible);
  int items = 0;
  for (final List<FushiToolbarItem> g in split.groups) {
    items += g.length;
  }
  final int buttons = items + (split.overflow.isEmpty ? 0 : 1);
  if (buttons == 0) return 0;
  final int dividers = split.groups.length > 1 ? split.groups.length - 1 : 0;
  return _kTopBarActionsPadding +
      buttons * _kTopBarActionSlot +
      dividers * _kTopBarGroupDivider;
}

/// 在 [budget] 宽度里最多能平铺几颗（总数 [total]）。
int fushiTopBarFitCount(
  List<List<FushiToolbarItem>> groups,
  List<FushiToolbarItem> overflow,
  int total,
  double budget,
) {
  for (int k = total; k > 0; k--) {
    if (fushiTopBarActionsWidth(groups, overflow, k) <= budget) return k;
  }
  return 0;
}

class _FushiFloatingTopBarState extends State<FushiFloatingTopBar> {
  List<FushiToolbarItem> get leading => widget.leading;
  String get title => widget.title;
  String get subtitle => widget.subtitle;
  VoidCallback? get onTitleTap => widget.onTitleTap;
  String? get titleTooltip => widget.titleTooltip;
  List<List<FushiToolbarItem>> get actions => widget.actions;
  List<FushiToolbarItem> get overflow => widget.overflow;
  FushiFloatingToolbarColors? get colors => widget.colors;
  bool get excludeFocus => widget.excludeFocus;

  /// 上一次布局平铺了几颗（回差的参照）；动作总数变了就作废。
  int? _lastVisible;
  int? _lastTotal;

  /// 按可用宽度定平铺颗数（带展开回差）。
  int _visibleFor(double maxWidth, {required bool hasTitle}) {
    int total = 0;
    for (final List<FushiToolbarItem> g in actions) {
      total += g.length;
    }
    total += overflow.length;
    if (!widget.adaptiveOverflow) {
      return total - overflow.length;
    }
    if (!maxWidth.isFinite) return total;
    final double budget =
        maxWidth -
        leading.length * _kTopBarLeadingSlot -
        (hasTitle ? kFushiFloatingTopBarTitleMinWidth : 0) -
        8;
    final int fit = fushiTopBarFitCount(actions, overflow, total, budget);
    final int? last = _lastTotal == total ? _lastVisible : null;
    int visible = fit;
    if (last != null && fit > last) {
      // 展开：多出来的那几颗要连回差一起放得下才放出来，否则维持原样。
      final int strict = fushiTopBarFitCount(
        actions,
        overflow,
        total,
        budget - kFushiFloatingTopBarOverflowHysteresis,
      );
      visible = strict > last ? strict : last;
    }
    _lastVisible = visible;
    _lastTotal = total;
    return visible;
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
        overflow.isNotEmpty;
    final String t = title.trim();
    final String s = subtitle.trim();
    final Widget? titlePill = t.isEmpty && s.isEmpty
        ? null
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
                    padding: const EdgeInsets.symmetric(horizontal: 16),
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
                              color: palette.foreground.withValues(alpha: 0.7),
                              height: 1.15,
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
        final int visible = _visibleFor(
          constraints.maxWidth,
          hasTitle: titlePill != null,
        );
        final ({
          List<List<FushiToolbarItem>> groups,
          List<FushiToolbarItem> overflow,
        })
        split = widget.adaptiveOverflow
            ? fushiTopBarSplitActions(actions, overflow, visible)
            : (groups: actions, overflow: overflow);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (final FushiToolbarItem item in leading) ...<Widget>[
              FushiFloatingPill(
                color: palette.container,
                child: FushiToolbarButton(
                  item: item,
                  foreground: palette.foreground,
                  selectedContainer: palette.selectedContainer,
                  selectedForeground: palette.selectedForeground,
                ),
              ),
              const SizedBox(width: 8),
            ],
            // 标题胶囊按内容收缩、最多吃满中间剩余宽度（超长书名省略号）。
            Expanded(
              child: titlePill == null
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: titlePill,
                    ),
            ),
            if (hasActions) ...<Widget>[
              const SizedBox(width: 8),
              // 不做尺寸动画（HBK034）：AnimatedSize 收缩时会保留旧宽度一帧，窗口
              // 骤缩时右侧溢出。按目标宽度立即布局，防抖靠展开回差。
              FushiFloatingToolbar(
                groups: split.groups,
                overflow: split.overflow,
                colors: colors,
                compact: true,
              ),
            ],
          ],
        );
      },
    );
    return excludeFocus ? ExcludeFocus(child: row) : row;
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
