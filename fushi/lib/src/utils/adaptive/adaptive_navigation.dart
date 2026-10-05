import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        AnimatedGlassIndicator,
        GlassContainer,
        GlassQuality,
        GlassSpring,
        LiquidGlassSettings,
        LiquidOval,
        LiquidRoundedSuperellipse,
        SpringBuilder,
        VelocitySpringBuilder;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show fushiClearGlassSettings;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

class AdaptiveNavItem {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;

  /// 在图标右上角叠加一个 MD3 小圆点徽标（无文字），标记该目的地为「实验性」。
  /// 底栏与侧栏共用同一渲染，徽标随之一致。
  final bool experimentalBadge;

  const AdaptiveNavItem({
    required this.icon,
    required this.label,
    this.selectedIcon,
    this.experimentalBadge = false,
  });
}

/// 当 [item] 标记为实验性时，给其图标 [child] 叠加一个 MD3 小圆点 [Badge]（无 label
/// 即默认小圆点，用 error 色吸引注意），否则原样返回。底栏（Material/Cupertino）与
/// 侧栏共用，保证徽标位置/样式一致。
Widget _maybeBadge({
  required AdaptiveNavItem item,
  required Widget child,
  Key? key,
}) {
  // key 挂在外层 KeyedSubtree：导航药丸的 AnimatedSwitcher 靠它区分线框 /
  // 实心两态图标。
  if (!item.experimentalBadge) return KeyedSubtree(key: key, child: child);
  return KeyedSubtree(key: key, child: Badge(child: child));
}

/// Marks the root of the self-drawn Material navigation (bottom bar / side rail)
/// so integration tests can locate the top-level destinations without depending
/// on the private widget type or the stock NavigationBar/NavigationRail (which
/// this no longer uses on Material).
const Key fushiMaterialNavKey = ValueKey<String>('hibiki-material-nav');

/// Marks the macOS-native (macos_ui) shell's content subtree so integration
/// tests can locate the top-level destinations without depending on the
/// MacosWindow/Sidebar internals. Mirrors [fushiMaterialNavKey] for the macOS
/// design system.
const Key fushiMacosNavKey = ValueKey<String>('hibiki-macos-nav');

/// Height of the mobile bottom bar's **content box**, in logical pixels —
/// the system gesture inset is let through by [SafeArea] on top of this.
///
/// Single source of truth for the bar's height, mirroring
/// [kAdaptiveNavRailWidth] on the rail side. MD3's nominal 80dp container
/// leaves 28dp of pure padding around a 52dp destination (32 indicator + 4 gap
/// + one labelSmall line); adding the gesture inset on top of that pushed the
/// whole bar to 104dp on a gesture-navigation phone, so it read as floating
/// above the bottom edge rather than sitting on it (BUG-2395). 64dp keeps the
/// destination untouched and drops the slack, leaving only
/// [kAdaptiveNavBarContentPadding] between the labels and the gesture area.
const double kAdaptiveNavBarContentHeight = 64;

/// Breathing room above and below the bottom bar's destinations.
/// A 52dp destination plus twice this is [kAdaptiveNavBarContentHeight].
const double kAdaptiveNavBarContentPadding = 6;

/// 「玻璃」设计系统（iOS 26）悬浮标签栏胶囊的高度（apple_music 演示 64、
/// 系统 UITabBar 实测 62）。
const double kGlassNavBarCapsuleHeight = 62;

/// 胶囊离屏幕左右边的距离。
const double kGlassNavBarSideMargin = 16;

/// 胶囊上沿与内容之间的缝。
const double _kGlassNavBarTopGap = 4;

/// 胶囊内沿到选中气泡的内边距。
const double _kGlassNavBarInnerPadding = 4;

/// 最小化后的标签栏（iOS 26 Music / Podcasts 下滑后）：只剩当前项图标的
/// 圆形胶囊，宽 = 胶囊高。
const double _kGlassNavBarMinimizedWidth = kGlassNavBarCapsuleHeight;

/// 胶囊与右侧独立搜索圆钮之间的缝（iOS 26 `Tab(role: .search)`）。
const double _kGlassNavBarTrailingGap = 10;

/// 底部 scroll edge 带往胶囊上方多伸出的高度：内容在胶囊上沿之前就开始
/// 化开，而不是到胶囊边才被盖住。
const double _kGlassNavBarEdgeOverhang = 24;

/// MD3（Material 3 Expressive）展开态导航 rail 的总宽（宽窗口，图标 + 文字
/// 横排的行）。窄窗口仍是 [kAdaptiveNavRailWidth] 的收起 rail。
const double kMaterialNavRailExpandedWidth = 200;

/// MD3 展开 rail 一行的高度与收起 rail / 底栏指示器药丸的尺寸（M3 Expressive：
/// 行 56、药丸 56×32，全圆角）。
const double _kMaterialRailRowHeight = 56;
const double _kMaterialPillWidth = 56;
const double _kMaterialPillHeight = 32;

/// 当前设计系统下导航 rail / 侧栏实际占的宽（标题栏按它缩进标题）。
double adaptiveNavRailWidthFor(BuildContext context, {required bool extended}) {
  if (!extended) return kAdaptiveNavRailWidth;
  return isGlassDesign(context)
      ? kGlassNavSidebarWidth
      : kMaterialNavRailExpandedWidth;
}

/// 胶囊离屏幕底边的距离。iOS 26 的标签栏浮在 home indicator 之上、并不让出
/// 整条手势区（演示同样忽略 safe area），所以只吃掉手势区的一部分，最少 16。
double _glassNavBarBottomMargin(BuildContext context) =>
    math.max(16, MediaQuery.paddingOf(context).bottom - 12);

/// 「玻璃」设计系统（macOS 26）展开态悬浮侧栏占的总宽（含四周 8 的悬浮边距）。
/// 窄窗口（medium 尺寸档）收成只有图标的窄条，总宽回到 [kAdaptiveNavRailWidth]。
const double kGlassNavSidebarWidth = 208;

/// 悬浮侧栏离窗口左 / 上 / 下边的距离。
const double _kGlassSidebarMargin = 8;

/// 悬浮侧栏面板的圆角（macOS 26 Finder / 设置侧栏实测 ≈ 20）。
const double _kGlassSidebarRadius = 20;

/// 侧栏行 / 选中填充的圆角与行高（macOS 26 源列表：行高 32–36、圆角 8–10）。
const double _kGlassSidebarRowRadius = 9;
const double _kGlassSidebarRowHeight = 34;

/// 玻璃窄条（侧栏收起）单格宽：图标 + 下方标签。窄条总宽仍是
/// [kAdaptiveNavRailWidth]，扣掉两侧悬浮边距后居中。
const double _kGlassSidebarCollapsedCellWidth = 60;

/// [glassMinimized] / [onGlassExpand] / [glassContentUnder] /
/// [glassSearchIndex] 只有 Apple 设计系统的悬浮胶囊读：
/// - [glassMinimized]：下滑后收成只剩当前项的小圆胶囊（点它 / 对它按
///   Enter 调 [onGlassExpand] 展开，不切 tab）；
/// - [glassContentUnder]：内容还压在胶囊下面，画底部 scroll edge 带；
/// - [glassSearchIndex]：这一项（查词 / 搜索）不进胶囊，单独画成胶囊右侧的
///   圆形玻璃钮（iOS 26 搜索 tab）。
Widget adaptiveBottomBar({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
  bool glassMinimized = false,
  VoidCallback? onGlassExpand,
  bool glassContentUnder = false,
  int? glassSearchIndex,
}) {
  if (isCupertinoPlatform(context)) {
    // Cupertino keeps the stock tab bar as a single whole-bar gamepad stop. iOS
    // is touch-first and we don't self-draw its chrome; per-item focus is a
    // Material-only refinement (the rail/bottom bar the gamepad users hit).
    return GamepadNavCluster(
      axis: Axis.horizontal,
      count: items.length,
      currentIndex: currentIndex,
      onSelect: onTap,
      child: CupertinoTabBar(
        currentIndex: currentIndex,
        onTap: onTap,
        items: items
            .map((AdaptiveNavItem e) => BottomNavigationBarItem(
                  icon: _maybeBadge(item: e, child: FushiIcon(e.icon)),
                  label: e.label,
                ))
            .toList(),
      ),
    );
  }
  // Material: each destination is its OWN gamepad/keyboard focus target, so the
  // app focus ring hugs the single selected item instead of wrapping the whole
  // bar. Directional D-pad steps between adjacent tiles through the normal
  // FushiFocus geometry; A/Enter (or a tap) selects.
  return _MaterialNavCluster(
    axis: Axis.horizontal,
    currentIndex: currentIndex,
    onTap: onTap,
    items: items,
    idPrefix: 'nav-bar',
    glassMinimized: glassMinimized,
    onGlassExpand: onGlassExpand,
    glassContentUnder: glassContentUnder,
    glassSearchIndex: glassSearchIndex,
  );
}

/// Self-drawn Material navigation as a row (bottom bar) or column (side rail) of
/// per-item gamepad/keyboard focus targets. Reproduces the MD3 destination look
/// (indicator pill + icon swap + label) so the app focus ring can hug a single
/// destination — the stock [NavigationBar]/[NavigationRail] only expose the
/// whole bar as one focusable region.
class _MaterialNavCluster extends StatelessWidget {
  const _MaterialNavCluster({
    required this.axis,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    required this.idPrefix,
    this.leading,
    this.extended = true,
    this.glassMinimized = false,
    this.onGlassExpand,
    this.glassContentUnder = false,
    this.glassSearchIndex,
  });

  /// [Axis.horizontal] = bottom bar; [Axis.vertical] = side rail.
  final Axis axis;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<AdaptiveNavItem> items;

  /// Stable per-position focus id prefix; the bar and rail use distinct prefixes
  /// so their ids never collide (only one is mounted at a time anyway).
  final String idPrefix;

  /// Rail-only leading widget (the app logo). Ignored for the bottom bar.
  final Widget? leading;

  /// 侧栏形态：true = 图标 + 文字横排的展开侧栏 / rail（宽窗口），false =
  /// 收起（窄窗口）。玻璃是 224 悬浮侧栏 / 窄条，MD3 是 240 展开 rail /
  /// 80 收起 rail。底栏不读它。
  final bool extended;

  /// 见 [adaptiveBottomBar]；只有 Apple 设计系统的底栏读。
  final bool glassMinimized;
  final VoidCallback? onGlassExpand;
  final bool glassContentUnder;
  final int? glassSearchIndex;

  Widget _cell(
    BuildContext context,
    int i, {
    bool iconOnly = false,
    double? cellWidth,
  }) {
    return _NavFocusCell(
      id: FushiFocusId('$idPrefix-$i'),
      item: items[i],
      selected: i == currentIndex,
      horizontal: axis == Axis.horizontal,
      extended: axis == Axis.vertical && extended,
      iconOnly: iconOnly,
      cellWidth: cellWidth,
      onSelect: () {
        if (i != currentIndex) fushiSelectionHaptic(context);
        onTap(i);
      },
    );
  }

  /// Apple 设计系统（iOS 26）的悬浮标签栏本体：一枚放目的地的玻璃胶囊，
  /// [glassSearchIndex] 那一项拆成右侧的圆形玻璃钮。下滑最小化时胶囊收成
  /// 只剩当前项图标的圆（宽度动画；减弱动态效果下瞬间到位），其余目的地
  /// 淡出并移出焦点遍历 / 命中测试。焦点 id 与展开态一致（`nav-bar-<序号>`），
  /// 最小化圆用单独的 `nav-mini-bar`。
  Widget _buildGlassTabBar(BuildContext context) {
    final int? rawSearch = glassSearchIndex;
    final int? search = rawSearch != null &&
            rawSearch >= 0 &&
            rawSearch < items.length &&
            items.length > 1
        ? rawSearch
        : null;
    final bool selectedInCapsule = currentIndex != search;
    // 搜索项选中时不收起（iOS 进搜索会展开搜索栏，这里至少保证能切回去）。
    final bool minimized = glassMinimized && selectedInCapsule;
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    const Curve curve = FushiMotion.standard;
    final List<int> capsuleIndices = <int>[
      for (int i = 0; i < items.length; i++)
        if (i != search) i,
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double searchSpace = search == null
            ? 0
            : kGlassNavBarCapsuleHeight + _kGlassNavBarTrailingGap;
        final double fullWidth = math.max(
          _kGlassNavBarMinimizedWidth,
          constraints.maxWidth - searchSpace,
        );
        final double innerFull = fullWidth - 2 * _kGlassNavBarInnerPadding;
        const double innerMini =
            _kGlassNavBarMinimizedWidth - 2 * _kGlassNavBarInnerPadding;
        final Widget fullRow = Row(
          children: <Widget>[
            for (final int i in capsuleIndices)
              Expanded(child: _cell(context, i)),
          ],
        );
        // 隐藏的那一层不挂焦点目标：FushiFocus 按几何找方向邻居，透明但仍注册
        // 的目标会让 D-pad 落到看不见的格子上。
        final Widget miniCell = selectedInCapsule
            ? _NavFocusCell(
                id: const FushiFocusId('nav-mini-bar'),
                item: items[currentIndex],
                selected: true,
                horizontal: true,
                iconOnly: true,
                onSelect: onGlassExpand ?? () {},
              )
            : const SizedBox.shrink();
        Widget layer({
          required bool shown,
          required double width,
          required Widget child,
        }) {
          return IgnorePointer(
            ignoring: !shown,
            child: ExcludeFocus(
              excluding: !shown,
              child: AnimatedOpacity(
                opacity: shown ? 1 : 0,
                duration: duration,
                curve: curve,
                child: OverflowBox(
                  alignment: AlignmentDirectional.centerStart,
                  minWidth: width,
                  maxWidth: width,
                  child: child,
                ),
              ),
            ),
          );
        }

        final int? selectedPos =
            selectedInCapsule ? capsuleIndices.indexOf(currentIndex) : null;
        return SizedBox(
          height: kGlassNavBarCapsuleHeight,
          child: Row(
            children: <Widget>[
              _GlassTabCapsule(
                width: minimized ? _kGlassNavBarMinimizedWidth : fullWidth,
                minimized: minimized,
                itemCount: capsuleIndices.length,
                selectedPos: selectedPos,
                duration: duration,
                curve: curve,
                onSelectPos: (int pos) {
                  final int i = capsuleIndices[pos];
                  if (i != currentIndex) fushiSelectionHaptic(context);
                  onTap(i);
                },
                children: <Widget>[
                  layer(
                    shown: !minimized,
                    width: innerFull,
                    child: minimized ? const SizedBox.shrink() : fullRow,
                  ),
                  layer(
                    shown: minimized,
                    width: innerMini,
                    child: minimized ? miniCell : const SizedBox.shrink(),
                  ),
                ],
              ),
              const Spacer(),
              if (search != null)
                SizedBox.square(
                  dimension: kGlassNavBarCapsuleHeight,
                  child: GlassContainer(
                    // premium 档必须自带 LiquidGlassLayer（BUG-2957），见
                    // [fushiGlassQuality]。
                    useOwnLayer: true,
                    shape: const LiquidOval(),
                    quality: fushiGlassQuality(context, prominent: true),
                    settings: fushiClearGlassSettings(context, bar: true),
                    child: Padding(
                      padding: const EdgeInsets.all(_kGlassNavBarInnerPadding),
                      child: _cell(context, search, iconOnly: true),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool horizontal = axis == Axis.horizontal;
    final bool glassDesign = isGlassDesign(context);
    // 侧栏是否展开（图标 + 文字横排）；收起的 rail 与底栏都是「图标为主」。
    final bool railExtended = !horizontal && extended;

    // MD3 底栏格宽不足时（手机竖屏最多 8 个入口，每格约 45dp）药丸宽度按格宽
    // 收窄、标签缩小一号并按格宽省略，而不是被硬压溢出；所有入口的标签恒显示
    // （2026-10-05 用户反馈：此前一度改成「仅选中项显示标签」，要求恢复全部文字）。
    // 侧栏与玻璃胶囊恒为完整形态（cellWidth: null）。
    List<Widget> buildTiles({required double? cellWidth}) => <Widget>[
          for (int i = 0; i < items.length; i++)
            _cell(context, i, cellWidth: cellWidth),
        ];

    // eink：surfaceContainer / surface 都塌成页面底色，底栏 / 侧栏与内容面连成
    // 一整块白（黑）；靠一条前景色边线把导航区切出来。
    final bool eink = isEinkTheme(context);
    // 毛玻璃 / 玻璃设计系统：Material 底色让位给背后的玻璃层（见
    // [_NavSurfaceBackdrop]）；贴屏幕边，不画描边。
    //
    // 结构恒定：无论 MD3 / 毛玻璃 / 液态 / 玻璃设计系统，外层永远是同一个
    // [_NavSurfaceBackdrop]，带 [fushiMaterialNavKey] 的 Material 永远在它的
    // 同一个槽位里，切换时只换背景槽与几何参数。旧实现按「是否玻璃」把 Material
    // 包进 / 拆出 FushiGlassSurface，设计系统一切换整条导航（含各目的地的焦点
    // 目标）就在同一帧里被重挂，Mac 调试版触发 `_elements.contains(element)`
    // 断言。
    final bool glass =
        glassDesign || glassMaterialOf(context) != FushiGlassMaterial.off;
    if (horizontal) {
      // 玻璃设计系统（iOS 26）：底栏是离左右 16、离底 ≥16 的悬浮玻璃胶囊
      // （+ 右侧搜索圆钮），胶囊本体在前景里画（随最小化变宽窄，见
      // [_buildGlassTabBar]）；背景槽只画底部 scroll edge 带——从导航区上沿
      // 再往上伸 24，内容在胶囊上方就开始化开。手势区不再整条让出
      // （SafeArea 不吃 bottom）。
      // MD3（Expressive 导航栏）：surfaceContainer 底、64 高，选中项是 56×32
      // 的全圆角 secondaryContainer 药丸，12 号 w500 标签。
      final double glassBottom =
          glassDesign ? _glassNavBarBottomMargin(context) : 0;
      return _NavSurfaceBackdrop(
        baseColor: colors.surfaceContainer,
        glassBackground: glassDesign
            ? Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: -_kGlassNavBarEdgeOverhang,
                    bottom: 0,
                    child: FushiAppleScrollEdge(
                      side: FushiScrollEdgeSide.bottom,
                      visible: glassContentUnder,
                      // 只是一层淡淡的压暗 + 轻模糊：胶囊要透出并折射后面
                      // 的内容，底色铺满就只剩一块平板（iOS 26 同样很淡）。
                      maxSigma: 4,
                      maxAlpha: 0.4,
                    ),
                  ),
                ],
              )
            : null,
        child: Material(
          key: fushiMaterialNavKey,
          color: glass ? Colors.transparent : colors.surfaceContainer,
          shape: eink ? Border(top: BorderSide(color: colors.outline)) : null,
          // Clamp text scaling exactly like the stock NavigationBar: at the
          // system's largest font sizes an unclamped label would push the bar to
          // a third of the screen.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: SafeArea(
              top: false,
              bottom: !glassDesign,
              // minHeight, not a fixed height: even clamped, a scaled label can
              // outgrow the content box, and a fixed box would overflow instead
              // of growing (the old 80 only hid this behind spare room).
              // IntrinsicHeight is what makes that "grow" well defined — each
              // destination centers itself inside the row, so under a loose
              // constraint the row would otherwise stretch to the whole screen.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: glassDesign
                      ? kGlassNavBarCapsuleHeight +
                          _kGlassNavBarTopGap +
                          glassBottom
                      : kAdaptiveNavBarContentHeight,
                ),
                child: Padding(
                  padding: glassDesign
                      ? EdgeInsets.fromLTRB(
                          kGlassNavBarSideMargin,
                          _kGlassNavBarTopGap,
                          kGlassNavBarSideMargin,
                          glassBottom,
                        )
                      : const EdgeInsets.symmetric(
                          vertical: kAdaptiveNavBarContentPadding,
                        ),
                  child: glassDesign
                      ? _buildGlassTabBar(context)
                      : LayoutBuilder(
                          builder: (BuildContext context, BoxConstraints box) {
                            final double? cellWidth =
                                box.hasBoundedWidth && items.isNotEmpty
                                    ? box.maxWidth / items.length
                                    : null;
                            return IntrinsicHeight(
                              child: Row(
                                children: <Widget>[
                                  for (final Widget tile
                                      in buildTiles(cellWidth: cellWidth))
                                    Expanded(child: tile),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 玻璃设计系统（macOS 26）：侧栏是离窗口左 / 上 / 下 8、圆角 20 的悬浮
    // 玻璃面板。MD3（Expressive）：宽窗口是 240 宽的展开 rail（行高 56、
    // 图标 + 文字横排、选中是包住图标与文字的全圆角药丸），窄窗口是 80 宽的
    // 收起 rail（56×32 药丸 + 下方 12 号标签）；底直接是 surface，不画边。
    // 两套的行都从上往下排（品牌位在顶），不再在剩余高度里居中。
    final double railWidth = railExtended
        ? (glassDesign ? kGlassNavSidebarWidth : kMaterialNavRailExpandedWidth)
        : kAdaptiveNavRailWidth;
    const double glassInset = _kGlassSidebarMargin + 8;
    return _NavSurfaceBackdrop(
      baseColor: colors.surface,
      glassMargin: glassDesign
          ? const EdgeInsets.all(_kGlassSidebarMargin)
          : null,
      glassRadius: _kGlassSidebarRadius,
      child: Material(
        key: fushiMaterialNavKey,
        color: glass ? Colors.transparent : colors.surface,
        shape: eink
            ? BorderDirectional(end: BorderSide(color: colors.outline))
            : null,
        child: SizedBox(
          width: railWidth,
          child: SafeArea(
            right: false,
            child: Padding(
              padding: glassDesign
                  ? EdgeInsets.symmetric(
                      horizontal: railExtended
                          ? glassInset
                          : (kAdaptiveNavRailWidth -
                                  2 * _kGlassSidebarMargin -
                                  _kGlassSidebarCollapsedCellWidth) /
                              2,
                      vertical: glassInset,
                    )
                  : EdgeInsets.symmetric(
                      horizontal: railExtended ? 12 : 0,
                      vertical: 8,
                    ),
              child: Column(
                children: <Widget>[
                  // 品牌位：收起 rail 居中 64；展开态（玻璃侧栏 / MD3 展开
                  // rail）靠起始边、缩到 56 的应用图标（FittedBox 等比缩）。
                  if (leading != null)
                    Align(
                      alignment: railExtended
                          ? AlignmentDirectional.centerStart
                          : Alignment.center,
                      widthFactor: railExtended ? null : 1,
                      heightFactor: 1,
                      child: SizedBox(
                        width: glassDesign || railExtended ? 56 : null,
                        height: glassDesign || railExtended ? 56 : null,
                        child: leading,
                      ),
                    ),
                  // 矮窗口下所有 tile 的总高可能超过可用高度：直接放进 Column 会 RenderFlex
                  // 溢出（左侧导航底部 overflow）。改用 SingleChildScrollView 让 tile 在窗口
                  // 过矮时滚动。
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: <Widget>[
                          const SizedBox(height: 8),
                          for (final Widget tile
                              in buildTiles(cellWidth: null))
                            Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: glassDesign
                                    ? 1
                                    : (railExtended ? 0 : 6),
                              ),
                              child: tile,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Apple 设计系统（iOS 26）标签栏的玻璃胶囊本体：无色透明玻璃（
/// [fushiClearGlassSettings] 的 bar 档）+ 选中项下一枚更亮的透明 lens。
///
/// 交互对齐 iOS 26 / 库 `GlassTabBar.bottom`：按下时整枚胶囊轻微放大（1.04），
/// 选中 lens 由静止的半透明 pill 化成会折射的液态玻璃透镜并向外鼓出；按住
/// 横向拖动时透镜跟手在各项之间滑行（带速度相关的果冻形变），松手吸附到最近
/// 一项并切过去；点选另一项时透镜沿弹簧滑过去。lens 只是背景装饰——各目的地
/// 的焦点目标 / 点击都在 [children] 里，键盘 / 手柄路径不变。
///
/// 结构恒定：Stack 槽位数固定（静止 lens、[children]、玻璃透镜），不显示的槽位
/// 用占位，切换最小化 / 选中不重挂目的地。系统降低透明度（材质 off）下 lens
/// 是实色高一阶底、不出玻璃透镜；减弱动态效果下不鼓出、不放大。
class _GlassTabCapsule extends StatefulWidget {
  const _GlassTabCapsule({
    required this.width,
    required this.minimized,
    required this.itemCount,
    required this.selectedPos,
    required this.duration,
    required this.curve,
    required this.onSelectPos,
    required this.children,
  });

  /// 胶囊目标宽（展开 = 可用宽减搜索圆钮，最小化 = 胶囊高）。
  final double width;
  final bool minimized;

  /// 胶囊里的目的地数（不含拆出去的搜索项）。
  final int itemCount;

  /// 选中项在胶囊里的序号；选中的是搜索圆钮时为 null（胶囊里不画 lens）。
  final int? selectedPos;
  final Duration duration;
  final Curve curve;

  /// 拖动松手后选中胶囊里第 [pos] 项。
  final ValueChanged<int> onSelectPos;

  /// 展开层与最小化层（见 [_MaterialNavCluster._buildGlassTabBar]）。
  final List<Widget> children;

  @override
  State<_GlassTabCapsule> createState() => _GlassTabCapsuleState();
}

class _GlassTabCapsuleState extends State<_GlassTabCapsule> {
  /// 透镜鼓出时超出 lens 原尺寸的量（库 GlassTabBar.bottom 默认 12 / 8）。
  static const EdgeInsets _kLensExpansion =
      EdgeInsets.symmetric(horizontal: 10, vertical: 7);

  bool _down = false;
  bool _dragging = false;

  /// 拖动中透镜的对齐值（-1 = 第一项、1 = 最后一项）；null = 跟随选中项。
  double? _dragAlign;

  bool get _lensEnabled =>
      !widget.minimized && widget.selectedPos != null && widget.itemCount > 0;

  double _alignFor(int pos) =>
      widget.itemCount <= 1 ? 0 : -1 + 2 * pos / (widget.itemCount - 1);

  double _alignAt(double dx) {
    final double inner = widget.width - 2 * _kGlassNavBarInnerPadding;
    if (inner <= 0 || widget.itemCount <= 1) return 0;
    final double slot =
        (dx - _kGlassNavBarInnerPadding) / inner * widget.itemCount - 0.5;
    return (-1 + 2 * slot / (widget.itemCount - 1)).clamp(-1.0, 1.0);
  }

  void _setDown(bool down) {
    if (_down == down || !mounted) return;
    setState(() => _down = down);
  }

  void _onDragStart(DragStartDetails details) {
    if (!_lensEnabled || widget.itemCount <= 1) return;
    setState(() {
      _dragging = true;
      _dragAlign = _alignAt(details.localPosition.dx);
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    setState(() => _dragAlign = _alignAt(details.localPosition.dx));
  }

  void _onDragEnd() {
    if (!_dragging) return;
    final double align = _dragAlign ?? 0;
    final int pos = ((align + 1) / 2 * (widget.itemCount - 1))
        .round()
        .clamp(0, widget.itemCount - 1);
    setState(() {
      _dragging = false;
      _down = false;
      _dragAlign = null;
    });
    widget.onSelectPos(pos);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool dark =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final bool solid = glassMaterialOf(context) == FushiGlassMaterial.off;
    final bool reduceMotion = widget.duration == Duration.zero;
    final bool morph = !solid && !reduceMotion;
    final GlassQuality quality = fushiGlassQuality(context, prominent: true);
    const double radius = kGlassNavBarCapsuleHeight / 2;
    // 静止的选中 lens：比胶囊更亮一阶的透明 pill（iOS 26 Music 演示
    // indicatorColor = label@20%；这里玻璃本身更透，深色白@10%——再高在深色
    // 栏上就是一块灰白雾——浅色黑@7%）。实色档换高一阶的分组底色。
    final Color restColor = solid
        ? apple.tertiaryGroupedBackground
        : (dark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.07));
    // 透镜：几乎无色、一圈细亮边 + 折射。深色收低光照与 rim，避免拖动时
    // 整颗透镜泛白。
    final LiquidGlassSettings lensSettings = LiquidGlassSettings(
      glassColor: Colors.white.withValues(alpha: dark ? 0.03 : 0.12),
      thickness: 20,
      refractiveIndex: 1.12,
      lightIntensity: dark ? 0.4 : 0.8,
      ambientRim: dark ? 0.25 : 0.3,
      chromaticAberration: 0,
      blur: 0,
    );
    final int? selectedPos = widget.selectedPos;
    final double target = selectedPos == null ? 0 : _alignFor(selectedPos);
    final double align = _dragAlign ?? target;

    Widget content(double value, double velocity, double thickness) {
      final bool lens = _lensEnabled;
      return Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: <Widget>[
          if (lens)
            AnimatedGlassIndicator(
              velocity: velocity,
              itemCount: widget.itemCount,
              alignment: Alignment(value, 0),
              thickness: thickness,
              quality: quality,
              indicatorColor: restColor,
              isBackgroundIndicator: true,
              paintGlass: false,
              expansion: _kLensExpansion,
              settings: lensSettings,
            )
          else
            const Positioned.fill(child: SizedBox.shrink()),
          ...widget.children,
          if (lens && morph && thickness > 0.05)
            AnimatedGlassIndicator(
              velocity: velocity,
              itemCount: widget.itemCount,
              alignment: Alignment(value, 0),
              thickness: thickness,
              quality: quality,
              indicatorColor: restColor,
              isBackgroundIndicator: false,
              paintBackground: false,
              expansion: _kLensExpansion,
              settings: lensSettings,
              pinchStrength: 0.4,
            )
          else
            const Positioned.fill(child: SizedBox.shrink()),
        ],
      );
    }

    return Listener(
      onPointerDown: (_) => _setDown(true),
      onPointerUp: (_) {
        if (!_dragging) _setDown(false);
      },
      onPointerCancel: (_) {
        if (!_dragging) _setDown(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: (DragEndDetails _) => _onDragEnd(),
        onHorizontalDragCancel: _onDragEnd,
        child: SpringBuilder(
          value: morph && _down ? 1.04 : 1.0,
          spring: GlassSpring.snappy(
            duration: const Duration(milliseconds: 300),
          ),
          builder: (BuildContext context, double scale, Widget? _) {
            return Transform.scale(
              scale: scale,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: widget.width),
                duration: widget.duration,
                curve: widget.curve,
                builder: (BuildContext context, double w, Widget? _) {
                  // 宽度动画中 / 最小化时裁到胶囊内（隐藏层是定宽溢出盒）；
                  // 静止展开时不裁，透镜按下才能鼓出胶囊边。
                  final bool clip =
                      widget.minimized || (w - widget.width).abs() > 0.5;
                  return SizedBox(
                    width: w,
                    height: kGlassNavBarCapsuleHeight,
                    child: GlassContainer(
                      // premium 档必须自带 LiquidGlassLayer（BUG-2957）；透镜
                      // 指示器在这层里分组渲染。
                      useOwnLayer: true,
                      shape: const LiquidRoundedSuperellipse(
                        borderRadius: radius,
                      ),
                      quality: quality,
                      settings: fushiClearGlassSettings(context, bar: true),
                      child: ClipRRect(
                        clipBehavior: clip ? Clip.antiAlias : Clip.none,
                        borderRadius: BorderRadius.circular(radius),
                        child: Padding(
                          padding: const EdgeInsets.all(
                            _kGlassNavBarInnerPadding,
                          ),
                          child: VelocitySpringBuilder(
                            value: align,
                            springWhenActive: GlassSpring.interactive(),
                            springWhenReleased: GlassSpring.snappy(
                              duration: const Duration(milliseconds: 350),
                            ),
                            active: _dragging,
                            builder: (
                              BuildContext context,
                              double value,
                              double velocity,
                              Widget? _,
                            ) {
                              return SpringBuilder(
                                value: morph &&
                                        _lensEnabled &&
                                        (_down ||
                                            _dragging ||
                                            (value - target).abs() > 0.05)
                                    ? 1.0
                                    : 0.0,
                                spring: GlassSpring.snappy(
                                  duration: const Duration(milliseconds: 300),
                                ),
                                builder: (
                                  BuildContext context,
                                  double thickness,
                                  Widget? _,
                                ) =>
                                    content(
                                  reduceMotion ? align : value,
                                  reduceMotion ? 0 : velocity,
                                  thickness,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 导航面的背衬：一个恒定的 passthrough [Stack]，背景槽按设计系统 / 材质换成
/// 玻璃设计系统的悬浮 [GlassContainer]（按 [glassMargin] 内缩、[glassRadius]
/// 圆角：侧栏面板 / 底部胶囊）、MD3 毛玻璃的 [FushiGlassSurface]（同色阶半透明 +
/// 背景模糊），或 MD3 实心时的空盒；[child]（带 [fushiMaterialNavKey] 的
/// Material）恒在第二个槽位，几何与不包时一字不差。
class _NavSurfaceBackdrop extends StatelessWidget {
  const _NavSurfaceBackdrop({
    required this.baseColor,
    required this.child,
    this.glassMargin,
    this.glassRadius = 0,
    this.glassBackground,
  });

  final Color baseColor;
  final Widget child;

  /// 玻璃设计系统下整个替换背景槽（底栏：胶囊在前景里画，背景槽只放
  /// scroll edge 带）；null = 按 [glassMargin] / [glassRadius] 画玻璃面板。
  final Widget? glassBackground;

  /// 玻璃面板相对导航区的内缩；null = 铺满。
  final EdgeInsets? glassMargin;
  final double glassRadius;

  @override
  Widget build(BuildContext context) {
    final Widget background;
    final Widget? glassOverride = glassBackground;
    if (isGlassDesign(context) && glassOverride != null) {
      background = glassOverride;
    } else if (isGlassDesign(context)) {
      // 中性玻璃（iOS 26 实测填充色），不拿 MD3 表面色去染。
      background = Padding(
        padding: glassMargin ?? EdgeInsets.zero,
        child: GlassContainer(
          // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
          useOwnLayer: true,
          shape: LiquidRoundedSuperellipse(borderRadius: glassRadius),
          quality: fushiGlassQuality(context, prominent: true),
          settings: fushiGlassSettings(context),
          child: const SizedBox.expand(),
        ),
      );
    } else if (glassMaterialOf(context) != FushiGlassMaterial.off) {
      background = FushiGlassSurface(
        baseColor: baseColor,
        showBorder: false,
        grouped: true,
        child: const SizedBox.expand(),
      );
    } else {
      background = const SizedBox.shrink();
    }
    // 不裁剪：底栏的 scroll edge 带要伸出导航区上沿画到内容上（Scaffold 先画
    // body 后画 bottomNavigationBar）。其余背景都在盒内，裁不裁没有区别。
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(child: IgnorePointer(child: background)),
        child,
      ],
    );
  }
}

/// One Material navigation destination wrapped as an independent gamepad/keyboard
/// focus target. The [FushiFocusTarget] hugs the icon+label content so the app
/// focus ring frames just this item. A/Enter resolve to [ActivateIntent] (mapped
/// here to [onSelect]); a mouse/touch tap calls it directly. The [InkWell] does
/// not request focus — the focus node belongs to the [FushiFocusTarget].
class _NavFocusCell extends StatefulWidget {
  const _NavFocusCell({
    required this.id,
    required this.item,
    required this.selected,
    required this.horizontal,
    required this.onSelect,
    this.extended = true,
    this.iconOnly = false,
    this.cellWidth,
  });

  final FushiFocusId id;
  final AdaptiveNavItem item;
  final bool selected;
  final bool horizontal;
  final VoidCallback onSelect;

  /// 侧栏是否展开（见 [_MaterialNavCluster.extended]）。
  final bool extended;

  /// 只画图标的圆形目的地（Apple 底栏的搜索圆钮 / 最小化圆）。
  final bool iconOnly;

  /// MD3 底栏单格可用宽度；null = 侧栏 / 玻璃胶囊 / 宽度未知，按完整形态绘制。
  final double? cellWidth;

  @override
  State<_NavFocusCell> createState() => _NavFocusCellState();
}

class _NavFocusCellState extends State<_NavFocusCell> {
  /// MD3 底栏 / 收起 rail 的指示器药丸（[_FushiNavTile] 的 pill 槽）。状态层按它
  /// 的矩形裁剪，见 [_NavIndicatorInkWell]。
  final GlobalKey _indicatorKey = GlobalKey(debugLabel: 'nav-indicator');

  FushiFocusId get id => widget.id;
  AdaptiveNavItem get item => widget.item;
  bool get selected => widget.selected;
  bool get horizontal => widget.horizontal;
  VoidCallback get onSelect => widget.onSelect;
  bool get extended => widget.extended;
  bool get iconOnly => widget.iconOnly;
  double? get cellWidth => widget.cellWidth;

  @override
  Widget build(BuildContext context) {
    final bool glassDesign = isGlassDesign(context);
    // 窄格适配只作用于 MD3 底栏：格宽不足时药丸按格宽收窄、标签缩小一号，
    // 标签恒显示。玻璃胶囊（iOS 26）与侧栏恒为完整形态。
    final AdaptiveNavTileMetrics metrics = AdaptiveNavTileMetrics.forCellWidth(
      horizontal && !glassDesign && !iconOnly ? cellWidth : null,
    );
    Widget tile = _FushiNavTile(
      item: item,
      selected: selected,
      horizontal: horizontal,
      extended: extended,
      iconOnly: iconOnly,
      pillWidth: metrics.pillWidth,
      compactLabel: metrics.compact,
      indicatorKey: _indicatorKey,
    );
    if (metrics.compact) {
      // 窄格里的标签可能被省略，用 tooltip 补出完整名称（长按 / 悬停可见）。
      tile = Tooltip(message: item.label, child: tile);
    }
    // MD3 展开 rail 的行靠起始边（药丸包住图标 + 文字），其余居中。
    final bool materialRailRow = !glassDesign && !horizontal && extended;
    // 玻璃：按压反馈与选中态都是中性灰填充，桌面侧栏行悬停给一层最浅的
    // systemFill（macOS 源列表的 hover）；不画 MD 涟漪。
    final Color glassHover = appleColorsOf(context).tertiaryFill;
    // ActivateIntent must sit ABOVE the focus node: the gamepad/keyboard path
    // dispatches it at the primary-focus context and walks UP the Actions chain.
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            onSelect();
            return null;
          },
        ),
      },
      child: _NavIndicatorInkWell(
        // MD3 底栏 / 收起 rail：悬停 / 按压 / 焦点状态层（含涟漪）只画在指示器
        // 药丸上、与选中高亮同尺寸同圆角（M3 NavigationBar 的 indicator ink；
        // 2026-10-05 用户反馈「点击灰色那个直接跟高亮范围一致」）。展开 rail 的
        // 行本身就是药丸、玻璃不画涟漪，药丸槽不挂载时状态层退回整格。
        indicatorKey: glassDesign || materialRailRow ? null : _indicatorKey,
        onTap: onSelect,
        canRequestFocus: false,
        // MD3 Expressive：状态层与药丸同为全圆角（展开 rail 的行 28，收起
        // rail / 底栏的指示器 16）。
        borderRadius: glassDesign
            ? BorderRadius.circular(
                horizontal
                    ? kGlassNavBarCapsuleHeight / 2
                    : _kGlassSidebarRowRadius,
              )
            : BorderRadius.circular(
                materialRailRow
                    ? _kMaterialRailRowHeight / 2
                    : _kMaterialPillHeight / 2,
              ),
        // 玻璃设计系统不画 MD 涟漪（按压反馈是选中气泡本身）；InkWell 本身保留，
        // 焦点目标的父链不随设计系统变。
        splashFactory: glassDesign ? NoSplash.splashFactory : null,
        overlayColor: glassDesign
            ? WidgetStateProperty.resolveWith<Color>(
                (Set<WidgetState> states) =>
                    !horizontal && !selected &&
                            states.contains(WidgetState.hovered)
                        ? glassHover
                        : Colors.transparent,
              )
            : null,
        child: Padding(
          padding: glassDesign || materialRailRow
              ? EdgeInsets.zero
              : EdgeInsets.symmetric(
                  vertical: horizontal ? 0 : 4,
                  horizontal: horizontal ? 4 : 0,
                ),
          child: Align(
            alignment: materialRailRow
                ? AlignmentDirectional.centerStart
                : Alignment.center,
            widthFactor: materialRailRow ? null : 1,
            heightFactor: 1,
            child: FushiFocusTarget(id: id, child: tile),
          ),
        ),
      ),
    );
  }
}

/// 状态层（悬停 / 按压 / 焦点高亮与涟漪）只画在 [indicatorKey] 所指的指示器
/// 药丸矩形内的 [InkWell]（同 M3 NavigationBar 的 `_IndicatorInkWell`）：整格
/// 仍是点击区，灰色反馈却与选中高亮同尺寸。[indicatorKey] 为 null 或尚未挂载时
/// 与普通 [InkWell] 相同，状态层铺满整个控件。
class _NavIndicatorInkWell extends InkWell {
  const _NavIndicatorInkWell({
    required this.indicatorKey,
    super.onTap,
    super.canRequestFocus,
    super.borderRadius,
    super.splashFactory,
    super.overlayColor,
    super.child,
  });

  final GlobalKey? indicatorKey;

  @override
  RectCallback? getRectCallback(RenderBox referenceBox) {
    final GlobalKey? key = indicatorKey;
    if (key == null || key.currentContext == null) return null;
    return () {
      final RenderObject? indicator = key.currentContext?.findRenderObject();
      if (indicator is! RenderBox ||
          !indicator.attached ||
          !indicator.hasSize ||
          !referenceBox.attached) {
        return Offset.zero & referenceBox.size;
      }
      return indicator.localToGlobal(Offset.zero, ancestor: referenceBox) &
          indicator.size;
    };
  }
}

/// Pure MD3 destination visual: an indicator pill behind the icon (filled when
/// selected) over a label. Shared by the bottom bar and the side rail.
///
/// 2026-10 动效重做：选中药丸不再一帧跳出——它从图标宽度（32）横向展开到 56、
/// 同时由透明渐入填充色（M3 导航栏的「指示器展开」）；图标的线框 ↔ 实心切换走
/// 一次轻缩放交叉淡化，标签字重随之过渡。墨水屏 / 减弱动态效果下
/// [fushiMotionDuration] 归零，三处都瞬间到位，最终几何与配色不变。
class _FushiNavTile extends StatelessWidget {
  const _FushiNavTile({
    required this.item,
    required this.selected,
    this.horizontal = true,
    this.extended = true,
    this.iconOnly = false,
    this.pillWidth = AdaptiveNavTileMetrics.fullPillWidth,
    this.compactLabel = false,
    this.indicatorKey,
  });

  final AdaptiveNavItem item;
  final bool selected;

  /// 底栏（图标在上、小字在下）还是侧栏行。
  final bool horizontal;

  /// 侧栏：展开行（图标 + 文字横排）还是只有图标的收起格。
  final bool extended;

  /// 仅 Apple 底栏读：只画图标的圆（搜索圆钮 / 最小化圆），标签进 Tooltip。
  final bool iconOnly;

  /// 玻璃设计系统（Apple 26）的目的地：强调色实底的选中气泡 / 圆角行 +
  /// onAccent 图标与文字，未选中用 label 色；不是 MD3 的 tonal 药丸。
  /// - 底栏（iOS 26 标签栏）：图标 24 在上、10.5 号字在下，选中气泡撑满胶囊内高；
  /// - 侧栏展开（macOS 26 源列表）：行高 34、圆角 9，图标 19 + 14 号字横排；
  /// - 侧栏窄条：44×36 的图标格，标签进 Tooltip。
  Widget _buildGlass(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    // 选中态走强调色（用户 2026-10-04）：强调色实底 + 其前景色，与设置页
    // 侧栏同一套；默认单色主题即黑底白字 / 白底黑字。
    final Color fg = selected ? apple.onAccent : apple.label;
    final Color fill =
        selected ? apple.accent : apple.accent.withValues(alpha: 0);
    // 底栏的选中气泡是玻璃里一枚更亮的无色透明 lens（iOS 26 标签栏 / Music
    // 演示 indicatorColor = label@20%，参照 Niratan 的选中 pill 不着强调色）+
    // 一圈细高光边 + 柔和投影；强调色只落在选中项的图标与文字上。系统降低透明度
    // 时实色高一阶底、无高光。侧栏行仍是强调色实底源列表选中行（Niratan 同）。
    final bool solidLens = glassMaterialOf(context) == FushiGlassMaterial.off;
    final bool darkMode =
        Theme.of(context).colorScheme.brightness == Brightness.dark;
    final Color tabFg = selected ? apple.accent : apple.label;
    final Color lensFill = selected
        ? (solidLens
            ? apple.tertiaryGroupedBackground
            : apple.label.withValues(alpha: darkMode ? 0.16 : 0.1))
        : apple.label.withValues(alpha: 0);
    final Border? lensRim = selected && !solidLens
        ? Border.all(
            color: Colors.white.withValues(alpha: darkMode ? 0.22 : 0.5),
            width: 0.8,
          )
        : null;
    final List<BoxShadow>? lensShadow = selected && !solidLens
        ? <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: darkMode ? 0.35 : 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ]
        : null;
    final IconData icon =
        selected ? (item.selectedIcon ?? item.icon) : item.icon;
    Widget glyph(double size, {Color? color}) => _maybeBadge(
          item: item,
          child: FushiIcon(icon, size: size, color: color ?? fg),
        );
    if (horizontal && iconOnly) {
      const double extent =
          kGlassNavBarCapsuleHeight - 2 * _kGlassNavBarInnerPadding;
      return Tooltip(
        message: item.label,
        child: Semantics(
          label: item.label,
          selected: selected,
          child: AnimatedContainer(
            duration: duration,
            curve: FushiMotion.standard,
            width: extent,
            height: extent,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: lensFill,
              shape: BoxShape.circle,
              border: lensRim,
              boxShadow: lensShadow,
            ),
            child: glyph(24, color: tabFg),
          ),
        ),
      );
    }
    if (horizontal) {
      // 胶囊里的格不画自己的选中气泡：选中 lens 由 [_GlassTabCapsule] 统一画
      // （能在项间滑行 / 拖动、按下化成液态透镜）。
      return AnimatedContainer(
        duration: duration,
        curve: FushiMotion.standard,
        width: double.infinity,
        height: kGlassNavBarCapsuleHeight - 2 * _kGlassNavBarInnerPadding,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            glyph(24, color: tabFg),
            const SizedBox(height: 2),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (textTheme.labelSmall ?? const TextStyle()).copyWith(
                fontSize: 10.5,
                height: 1.2,
                color: tabFg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
    final BoxDecoration rowDecoration = BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(_kGlassSidebarRowRadius),
    );
    if (!extended) {
      // 窄条（medium 窗口）：图标在上、10 号标签在下，标签恒显示（2026-10-05
      // 用户反馈「所有文字不要隐藏」，与 MD3 收起 rail 一致）；放不下按格宽省略，
      // tooltip 补全名。
      return Tooltip(
        message: item.label,
        child: AnimatedContainer(
          duration: duration,
          curve: FushiMotion.standard,
          width: _kGlassSidebarCollapsedCellWidth,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          alignment: Alignment.center,
          decoration: rowDecoration,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              glyph(20),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: (textTheme.labelSmall ?? const TextStyle()).copyWith(
                  fontSize: 10,
                  height: 1.2,
                  color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return AnimatedContainer(
      duration: duration,
      curve: FushiMotion.standard,
      width: double.infinity,
      height: _kGlassSidebarRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: rowDecoration,
      child: Row(
        children: <Widget>[
          glyph(19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (textTheme.bodyMedium ?? const TextStyle()).copyWith(
                fontSize: 14,
                color: fg,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// MD3 药丸展开后的宽度：完整形态 56（M3 Expressive 导航栏 / 收起 rail
  /// 指示器 56×32），MD3 底栏窄格按格宽收窄（见 [AdaptiveNavTileMetrics]）。
  final double pillWidth;

  /// MD3 底栏窄格：标签缩小一号（11），仍按格宽单行省略；标签恒显示，不再
  /// 「只给选中项显示标签」（2026-10-05 用户反馈）。
  final bool compactLabel;

  /// 挂在 MD3 指示器药丸槽（[pillWidth] × 32）上，供 [_NavIndicatorInkWell]
  /// 把状态层裁到药丸。
  final GlobalKey? indicatorKey;

  static const double _pillHeight = AdaptiveNavTileMetrics.pillHeight;

  /// MD3 展开 rail 的一行（M3 Expressive expanded navigation rail）：行高 56，
  /// 24 图标 + 14 号 w500 标签横排，选中是包住图标与文字的全圆角
  /// secondaryContainer 药丸（onSecondaryContainer 前景），未选中
  /// onSurfaceVariant。药丸填充随选中淡入；墨水屏反色药丸。
  Widget _buildMaterialRailRow(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool eink = isEinkTheme(context);
    final Color pillColor = eink ? colors.onSurface : colors.secondaryContainer;
    final Color fg = selected
        ? (eink ? colors.surface : colors.onSecondaryContainer)
        : colors.onSurfaceVariant;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final IconData icon =
        selected ? (item.selectedIcon ?? item.icon) : item.icon;
    // 选中药丸撑满整行（2026-10-05 用户反馈「这个条的长度不对」）：旧实现药丸
    // 只包住图标 + 文字，而外层 InkWell 的悬停 / 焦点状态层是整行宽，选中项上
    // 就叠出一枚短的强调色药丸 + 一条更长的灰色底。现在两者同宽同圆角；选中时
    // 药丸实底盖住其下的状态层，只剩一个指示器。
    return AnimatedContainer(
      duration: duration,
      curve: FushiMotion.standard,
      width: double.infinity,
      height: _kMaterialRailRowHeight,
      padding: const EdgeInsetsDirectional.only(start: 16, end: 24),
      decoration: BoxDecoration(
        color: selected ? pillColor : pillColor.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(_kMaterialRailRowHeight / 2),
      ),
      child: Row(
        children: <Widget>[
          _maybeBadge(
            item: item,
            child: FushiIcon(icon, size: 24, color: fg),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (textTheme.labelLarge ?? const TextStyle()).copyWith(
                fontSize: 14,
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 设计系统切换时目的地视觉整块换新，不跨设计系统补间：两套都以
    // AnimatedContainer 为根，玻璃行是撑满宽（tight 无穷宽）、MD3 行是松宽，
    // 同类型原地更新会在两者之间插值约束，触发 box.dart「Cannot interpolate
    // between finite constraints and unbounded constraints」红屏。这里只是叶子
    // （焦点目标在 [_NavFocusCell] 里、更上层），换新不影响焦点。
    if (isGlassDesign(context)) {
      return KeyedSubtree(
        key: const ValueKey<String>('glass-nav-tile'),
        child: _buildGlass(context),
      );
    }
    if (!horizontal && extended) return _buildMaterialRailRow(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    // eink：选中药丸的 secondaryContainer == 页面底色，选中项只剩图标实心/线框
    // 之差；改反色药丸（segmentedButtonTheme / chipTheme 同一套处理）。
    final bool eink = isEinkTheme(context);
    final Color pillColor = eink ? colors.onSurface : colors.secondaryContainer;
    final Color pillIconColor =
        eink ? colors.surface : colors.onSecondaryContainer;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    // M3 Expressive：指示器是全圆角药丸（不再是控件圆角的圆角矩形）。
    const BorderRadius radius =
        BorderRadius.all(Radius.circular(_kMaterialPillHeight / 2));
    final IconData icon =
        selected ? (item.selectedIcon ?? item.icon) : item.icon;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          key: indicatorKey,
          width: pillWidth,
          height: _pillHeight,
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: selected ? 1 : 0),
              duration: duration,
              curve: FushiMotion.enter,
              builder: (BuildContext context, double t, Widget? child) {
                // t 落到端点时直接用目标色：settle 后的药丸与改造前逐值相同
                // （eink 守卫按 `decoration.color == onSurface` 断言）。
                final double width =
                    _pillHeight + (pillWidth - _pillHeight) * t;
                final Color fill = t >= 1
                    ? pillColor
                    : t <= 0
                        ? Colors.transparent
                        : pillColor.withValues(alpha: pillColor.a * t);
                return Container(
                  width: width,
                  height: _pillHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: radius,
                  ),
                  child: child,
                );
              },
              child: AnimatedSwitcher(
                duration: duration,
                switchInCurve: FushiMotion.enter,
                switchOutCurve: FushiMotion.exit,
                transitionBuilder:
                    (Widget child, Animation<double> animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.8, end: 1)
                          .animate(animation),
                      child: child,
                    ),
                  );
                },
                child: _maybeBadge(
                  key: ValueKey<(IconData, bool)>((icon, selected)),
                  item: item,
                  child: FushiIcon(
                    icon,
                    size: 24,
                    color: selected ? pillIconColor : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        AnimatedDefaultTextStyle(
          duration: duration,
          curve: FushiMotion.standard,
          // M3 Expressive 导航标签：12 号 w500（labelMedium），选中加粗一档
          // 保证墨水屏上也分得清。
          style: (textTheme.labelMedium ?? const TextStyle()).copyWith(
            fontSize: compactLabel ? 11 : 12,
            color: selected ? colors.onSurface : colors.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
          child: Text(
            item.label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// 底栏单格的绘制尺寸（2026-10 体验优化）。
///
/// 格宽 ≥ [compactMaxCellWidth] 时与 M3 Expressive 导航栏相同：药丸 56、
/// 12 号标签；更窄时切到紧凑形态：药丸宽度随格宽收窄（扣掉格内左右 4dp
/// 内边距，下限为图标药丸高度 32）、标签缩小到 11 号并按格宽省略。**所有入口
/// 的标签恒显示**（2026-10-05 用户反馈：曾在窄格只给选中项显示标签）。只
/// 作用于 MD3 底栏；玻璃胶囊与侧栏恒为完整形态。
@immutable
class AdaptiveNavTileMetrics {
  const AdaptiveNavTileMetrics({
    required this.pillWidth,
    required this.compact,
  });

  /// 格宽低于该值就切到紧凑形态（窄药丸 + 小一号标签）。
  static const double compactMaxCellWidth = 64;
  static const double fullPillWidth = _kMaterialPillWidth;
  static const double pillHeight = _kMaterialPillHeight;

  /// 格内左右合计内边距（见 [_NavFocusCell] 的 horizontal: 4）。
  static const double _cellHorizontalPadding = 8;

  final double pillWidth;

  /// 窄格紧凑形态：标签缩小一号、配 tooltip 补全名（标签仍显示）。
  final bool compact;

  static AdaptiveNavTileMetrics forCellWidth(double? cellWidth) {
    if (cellWidth == null || cellWidth >= compactMaxCellWidth) {
      return const AdaptiveNavTileMetrics(
        pillWidth: fullPillWidth,
        compact: false,
      );
    }
    final double pill = (cellWidth - _cellHorizontalPadding)
        .clamp(pillHeight, fullPillWidth)
        .toDouble();
    return AdaptiveNavTileMetrics(pillWidth: pill, compact: true);
  }
}

/// Width of the desktop navigation rail, in logical pixels.
///
/// Single source of truth: the rail itself lays out against it, and the Windows
/// app frame indents its title by the same amount so the caption text lines up
/// with the content pane instead of floating over the rail.
const double kAdaptiveNavRailWidth = 80;

/// Self-drawn Material navigation rail (per-item gamepad/keyboard focus). Mirrors
/// `NavigationRail(labelType: all)` with a leading logo and centered group, but
/// each destination is its own focus target so the ring hugs one item. [items]
/// and [currentIndex] are in visual order; [onTap] receives the visual index
/// (the caller keeps its visual→logical mapping, e.g. reversed rails).
Widget adaptiveNavRail({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
  Widget? leading,
  bool extended = true,
}) {
  // [extended] 只影响玻璃设计系统：宽窗口是图标 + 文字的悬浮侧栏，窄窗口收成
  // 只有图标的窄条。MD3 rail 恒为 80 宽的「图标在上、文字在下」。
  return _MaterialNavCluster(
    axis: Axis.vertical,
    currentIndex: currentIndex,
    onTap: onTap,
    items: items,
    idPrefix: 'nav-rail',
    leading: leading,
    extended: extended,
  );
}

/// Wraps a stock NavigationBar / NavigationRail as a SINGLE gamepad/keyboard
/// focus stop. Directional focus can land on the navigation chrome (the app
/// focus ring follows it) and the along-axis D-pad switches tabs in place,
/// instead of focus leaking onto the bar's unregistered destinations and
/// dropping the ring. Mouse/touch still tap the underlying destinations
/// (ExcludeFocus only removes them from focus traversal). Passes [child]
/// straight through when there is no FushiFocusRoot (plain widget tests).
class GamepadNavCluster extends StatefulWidget {
  const GamepadNavCluster({
    required this.axis,
    required this.count,
    required this.currentIndex,
    required this.onSelect,
    required this.child,
    super.key,
  });

  /// The cluster's main axis: [Axis.horizontal] (bottom bar) switches on D-pad
  /// Left/Right; [Axis.vertical] (side rail) switches on D-pad Up/Down.
  final Axis axis;
  final int count;
  final int currentIndex;

  /// Called with the new index when the D-pad steps to an adjacent tab. The
  /// index is in the same (possibly reversed) visual space as [currentIndex],
  /// so the caller's existing visual→logical mapping still applies.
  final ValueChanged<int> onSelect;
  final Widget child;

  @override
  State<GamepadNavCluster> createState() => _GamepadNavClusterState();
}

class _GamepadNavClusterState extends State<GamepadNavCluster> {
  late final FushiFocusId _focusId =
      FushiFocusId('nav-cluster-${identityHashCode(this)}');

  void _step(int delta) {
    if (widget.count <= 0) return;
    final int next = (widget.currentIndex + delta).clamp(0, widget.count - 1);
    if (next != widget.currentIndex) widget.onSelect(next);
  }

  @override
  Widget build(BuildContext context) {
    if (FushiFocusRoot.maybeControllerOf(context) == null) {
      return widget.child;
    }
    final bool horizontal = widget.axis == Axis.horizontal;
    return Actions(
      actions: <Type, Action<Intent>>{
        // 只消费沿轴的两个方向键，跨轴按键**显式转发**给祖先（离开导航栏）。
        // 原先靠覆写 isEnabled 让位是不成立的：Actions.maybeInvoke 上溯停在第一个
        // 注册了该 Intent 类型的层，与 enabled 无关，被让位的按键其实是被静默吞掉。
        // 见 [GamepadButtonForwardingAction] 类文档。
        GamepadButtonIntent: GamepadButtonForwardingAction(
          ancestorContext: context,
          handle: (GamepadButton button) {
            final GamepadButton prev =
                horizontal ? GamepadButton.dpadLeft : GamepadButton.dpadUp;
            final GamepadButton next =
                horizontal ? GamepadButton.dpadRight : GamepadButton.dpadDown;
            if (button == next) {
              _step(1);
              return true;
            }
            if (button == prev) {
              _step(-1);
              return true;
            }
            return false;
          },
        ),
      },
      child: Shortcuts(
        // Android delivers the D-pad as arrow keys; mirror the along-axis step.
        shortcuts: <ShortcutActivator, Intent>{
          SingleActivator(horizontal
              ? LogicalKeyboardKey.arrowLeft
              : LogicalKeyboardKey.arrowUp): const _NavStepIntent(-1),
          SingleActivator(horizontal
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowDown): const _NavStepIntent(1),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _NavStepIntent: CallbackAction<_NavStepIntent>(
              onInvoke: (_NavStepIntent intent) {
                _step(intent.delta);
                return null;
              },
            ),
          },
          child: FushiFocusTarget(
            id: _focusId,
            child: ExcludeFocus(child: widget.child),
          ),
        ),
      ),
    );
  }
}

class _NavStepIntent extends Intent {
  const _NavStepIntent(this.delta);
  final int delta;
}

PreferredSizeWidget adaptiveAppBar({
  required BuildContext context,
  Widget? leading,
  Widget? title,
  List<Widget>? actions,
  double? titleSpacing,
  PreferredSizeWidget? bottom,
}) {
  if (isCupertinoPlatform(context)) {
    final navBar = CupertinoNavigationBar(
      leading: leading,
      middle: title,
      trailing: actions != null && actions.isNotEmpty
          ? Row(mainAxisSize: MainAxisSize.min, children: actions)
          : null,
    );
    if (bottom == null) return navBar;
    return _CupertinoAppBarWithBottom(navBar: navBar, bottom: bottom);
  }
  if (isGlassDesign(context)) {
    // 「玻璃」设计系统：与 [FushiAppBar] 同一套 Apple 26 顶栏（透明底、
    // 圆形玻璃返回钮、actions 收进一枚玻璃胶囊）。
    return FushiAppBar(
      leading: leading,
      title: title,
      actions: actions,
      titleSpacing: titleSpacing,
      bottom: bottom,
    );
  }
  // MD3 同样走设计系统分派的顶栏（统一的 arrow_back 返回键与顶栏主题）。
  return FushiAppBar(
    leading: leading,
    title: title,
    actions: actions,
    titleSpacing: titleSpacing,
    bottom: bottom,
  );
}

class _CupertinoAppBarWithBottom extends StatelessWidget
    implements PreferredSizeWidget {
  final CupertinoNavigationBar navBar;
  final PreferredSizeWidget bottom;

  const _CupertinoAppBarWithBottom(
      {required this.navBar, required this.bottom});

  @override
  Size get preferredSize => Size.fromHeight(
      navBar.preferredSize.height + bottom.preferredSize.height);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [navBar, bottom],
    );
  }
}
