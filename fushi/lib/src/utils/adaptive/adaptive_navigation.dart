import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiBadgeControl;
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_haptics.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show
        FushiSpring,
        fushiExpressiveDefaultSpatial,
        fushiExpressiveMotionEnabled;
import 'package:fushi/src/utils/misc/platform_utils.dart' show WindowSizeClass;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
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
import 'package:fushi/src/utils/fushi_icons.dart';

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
  return KeyedSubtree(
    key: key,
    child: FushiBadgeControl(child: child),
  );
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

/// MD3（Material 3 Expressive）展开态导航 rail 的总宽（图标 + 文字横排的行）。
/// M3E 把 navigation drawer 并进了 expanded navigation rail，规格宽 220–360，
/// 取下限 220：比旧抽屉窄，给内容区多留地方。
const double kMaterialNavRailExpandedWidth = 220;

/// MD3（M3 Expressive）收起态导航 rail 的总宽：规格 96（旧 M3 rail 是 80）。
/// Apple 设计系统的窄条仍是 [kAdaptiveNavRailWidth]。
const double kMaterialNavRailCollapsedWidth = 96;

/// MD3 悬浮导航（底部胶囊 / 侧边面板）离屏幕边的留白。
const double kAdaptiveNavFloatingMargin = 12;

/// MD3 悬浮底栏胶囊上沿与内容（或其上方迷你播放条）之间的缝。迷你条自带
/// 离边 12 的左右留白，与胶囊同宽对齐，底下再留 8，两者叠起来间距一致。
const double kAdaptiveNavBarFloatingTopGap = 4;

/// MD3 悬浮底栏胶囊内左右留白（目的地格从这里开始排）。
const double kAdaptiveNavBarCapsulePadding = 4;

/// MD3 悬浮胶囊里目的地上下的留白（标签可见时胶囊高按它算，约 72–80）。
const double _kCapsuleVerticalPadding = 10;

/// MD3 悬浮底栏一格的最窄宽度：再窄标签就要截断，改收进「更多」。
const double _kMinNavCellWidth = 44;

/// 纯图标（标签隐藏）时一格的最窄宽度：M3 的 48dp 最小触控目标。
const double _kMinIconNavCellWidth = 48;

/// 一格除标签外的横向余量（格内左右 4 的内边距）。
const double _kNavCellLabelSlack = 8;

/// MD3 悬浮 rail 面板离窗口左 / 上 / 下的留白，与面板右侧给阴影的缝。
const double _kMaterialRailFloatingStart = 12;
const double _kMaterialRailFloatingEnd = 6;

/// MD3 悬浮 rail 占位宽比面板宽多出的量。
const double kMaterialNavRailFloatingInset =
    _kMaterialRailFloatingStart + _kMaterialRailFloatingEnd;

/// MD3 悬浮 rail 面板圆角（M3E 大容器 28）。
const double _kMaterialRailPanelRadius = 28;

/// MD3 悬浮底栏离屏幕底边的距离：浮在手势区之上，最少 12。
double _materialNavBarBottomMargin(BuildContext context) =>
    math.max(kAdaptiveNavFloatingMargin, MediaQuery.paddingOf(context).bottom);

/// M3E rail 菜单钮的胶囊高度（与导航药丸同为全圆角）。
const double _kMaterialMenuPillHeight = 40;

/// M3 Expressive「expressive」动效方案的 default spatial 弹簧（刚度 380、
/// 阻尼比 0.8）：导航指示器选中时带一点回弹地展开，rail 展开 / 收起同用。
/// 按压类形变用的 standard 方案见 fushi_expressive.dart。
final SpringDescription _kNavExpressiveSpatial =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.8);

/// MD3 展开 rail 一行的高度与收起 rail / 底栏指示器药丸的尺寸（M3 Expressive：
/// 行 56、药丸 56×32，全圆角）。
const double _kMaterialRailRowHeight = 56;
const double _kMaterialPillWidth = 56;
const double _kMaterialPillHeight = 32;

/// 当前设计系统下导航 rail / 侧栏实际占的宽（标题栏按它缩进标题）。
double adaptiveNavRailWidthFor(BuildContext context, {required bool extended}) {
  final bool glass = isGlassDesign(context);
  if (glass) return extended ? kGlassNavSidebarWidth : kAdaptiveNavRailWidth;
  // MD3 是悬浮面板：占位宽含面板左右的留白。
  return (extended
          ? kMaterialNavRailExpandedWidth
          : kMaterialNavRailCollapsedWidth) +
      kMaterialNavRailFloatingInset;
}

/// 宽屏主导航此刻是否展开。默认按窗口尺寸档：expanded（≥840）展开、medium
/// 收起。MD3 下用户可以用 rail 顶部的菜单钮手动切换并记忆（[userExpanded]，
/// null = 没切过）；Apple 设计系统的侧栏没有这颗钮，恒按尺寸档。首页 rail 与
/// 桌面标题栏的缩进都经这里，两边不会各算一套。
bool adaptiveNavRailExtended(
  BuildContext context, {
  required WindowSizeClass sizeClass,
  bool? userExpanded,
}) {
  final bool byWindow = sizeClass == WindowSizeClass.expanded;
  if (isGlassDesign(context)) return byWindow;
  return userExpanded ?? byWindow;
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
///
/// [searchLeading]：「反转底栏方向」开启时为 true——拆出去的查词钮（Apple 圆钮
/// / MD3 FAB）挪到胶囊**起始侧**（LTR 即左侧），整条底栏成为关闭时的镜像；
/// 胶囊收起时也缩向末端，紧贴 FAB 的另一侧不留空洞。目的地顺序本身由调用方
/// 传入的 [items] 决定（已按反转排好）。
Widget adaptiveBottomBar({
  required BuildContext context,
  required int currentIndex,
  required ValueChanged<int> onTap,
  required List<AdaptiveNavItem> items,
  bool glassMinimized = false,
  VoidCallback? onGlassExpand,
  bool glassContentUnder = false,
  int? glassSearchIndex,
  bool showLabels = true,
  AdaptiveNavFab? materialFab,
  bool searchLeading = false,
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
            .map(
              (AdaptiveNavItem e) => BottomNavigationBarItem(
                icon: _maybeBadge(item: e, child: FushiIcon(e.icon)),
                label: e.label,
              ),
            )
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
    showLabels: showLabels,
    materialFab: materialFab,
    searchLeading: searchLeading,
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
    this.onToggleExtended,
    this.glassMinimized = false,
    this.onGlassExpand,
    this.glassContentUnder = false,
    this.glassSearchIndex,
    this.showLabels = true,
    this.materialFab,
    this.searchLeading = false,
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

  /// 侧栏形态：true = 图标 + 文字横排的展开侧栏 / rail，false = 收起。
  /// 玻璃是 208 悬浮侧栏 / 80 窄条，MD3 是 220 展开 rail / 96 收起 rail。
  /// 底栏不读它。
  final bool extended;

  /// MD3 rail 顶部菜单钮（M3E navigation rail 的 menu button）：切换展开 /
  /// 收起。null = 不画菜单钮；Apple 设计系统与底栏不读。
  final VoidCallback? onToggleExtended;

  /// 见 [adaptiveBottomBar]；只有 Apple 设计系统的底栏读。
  final bool glassMinimized;
  final VoidCallback? onGlassExpand;
  final bool glassContentUnder;

  /// 查词 / 搜索目的地：Apple 拆成胶囊右侧的圆形玻璃钮，MD3 拆成悬浮胶囊右侧
  /// 的大号 FAB（[materialFab] 非空时它留在胶囊里）。
  final int? glassSearchIndex;

  /// MD3 悬浮底栏是否在图标下显示标签（用户偏好 `nav_bar_labels_visible`，
  /// 出厂关 = 纯图标；本组件参数缺省仍为 true，由调用方传偏好值）。
  final bool showLabels;

  /// MD3 悬浮底栏右侧 FAB 的覆盖（当前页自己的主操作）；null = 用查词目的地。
  final AdaptiveNavFab? materialFab;

  /// 查词钮 / FAB 放在胶囊起始侧（反转底栏方向），见 [adaptiveBottomBar]。
  final bool searchLeading;

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
    final int? search =
        rawSearch != null &&
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

        final int? selectedPos = selectedInCapsule
            ? capsuleIndices.indexOf(currentIndex)
            : null;
        // 搜索圆钮：默认在胶囊右侧；反转底栏方向时挪到左侧（[searchLeading]）。
        Widget searchButton(int index) => SizedBox.square(
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
              child: _cell(context, index, iconOnly: true),
            ),
          ),
        );
        return SizedBox(
          height: kGlassNavBarCapsuleHeight,
          child: Row(
            children: <Widget>[
              if (searchLeading && search != null) searchButton(search),
              if (searchLeading) const Spacer(),
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
              if (!searchLeading) const Spacer(),
              if (!searchLeading && search != null) searchButton(search),
            ],
          ),
        );
      },
    );
  }

  /// MD3 悬浮底栏（M3E floating toolbar 形态）：vibrant 饱和容器色的大胶囊 +
  /// 右侧一颗独立的大号圆角方 FAB（[AdaptiveNavFab]；默认是「查词」目的地本身，
  /// 与 Apple 胶囊把搜索拆成右侧圆钮同一个 [glassSearchIndex] 判据），随滚动
  /// 弹簧收起成当前项小胶囊（[_MaterialFloatingBar]）。
  Widget _buildMaterialFloatingBar(BuildContext context) {
    final int? rawSearch = glassSearchIndex;
    int? search;
    if (materialFab == null &&
        rawSearch != null &&
        rawSearch >= 0 &&
        rawSearch < items.length &&
        items.length > 1) {
      search = rawSearch;
    }
    final List<int> capsuleIndices = <int>[
      for (int i = 0; i < items.length; i++)
        if (i != search) i,
    ];
    AdaptiveNavFab? fab = materialFab;
    final int? searchIndex = search;
    if (fab == null && searchIndex != null) {
      final AdaptiveNavItem searchItem = items[searchIndex];
      fab = AdaptiveNavFab(
        icon: searchItem.icon,
        selectedIcon: searchItem.selectedIcon,
        label: searchItem.label,
        experimentalBadge: searchItem.experimentalBadge,
        selected: currentIndex == searchIndex,
        onPressed: () {
          if (currentIndex != searchIndex) fushiSelectionHaptic(context);
          onTap(searchIndex);
        },
      );
    }
    final bool currentValid = currentIndex >= 0 && currentIndex < items.length;
    final double capsuleHeight = _materialCapsuleHeight(context);
    // BUG-3064：FAB 那一项（查词）选中时同样随下滑收起——胶囊里没有当前项可
    // 留，整条胶囊让位（M3E 浮动工具栏滚走、FAB 留下），回滚 / 焦点进入再展开。
    // 此前这里直接不收起，查词页往下滑底栏纹丝不动。
    final bool fabCurrent = currentIndex == searchIndex;
    final bool minimized = glassMinimized && currentValid;
    return _MaterialFloatingBar(
      minimized: minimized,
      onExpand: onGlassExpand,
      showLabels: showLabels,
      currentItem: currentValid && !fabCurrent ? items[currentIndex] : null,
      expandFocusIds: <FushiFocusId>[
        FushiFocusId('$idPrefix-$currentIndex'),
        _NavMoreCell.focusId,
      ],
      fab: fab,
      fabLeading: searchLeading,
      height: capsuleHeight,
      capsule: SizedBox(
        height: capsuleHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kAdaptiveNavBarCapsulePadding,
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) =>
                _buildMaterialFloatingRow(context, box, capsuleIndices),
          ),
        ),
      ),
    );
  }

  /// MD3 悬浮胶囊的高度：按「指示器药丸 32 + 缝 4 + 标签实际行高」加上下各
  /// [_kCapsuleVerticalPadding] 算，跟随（钳到 1.3 的）文字缩放；标签隐藏时只
  /// 剩药丸，取 [kAdaptiveNavBarContentHeight]（64）。此前用 64 的最小高 +
  /// IntrinsicHeight，Windows 上标签字体行高偏大时下半截被胶囊圆角裁掉
  /// （2026-10-06 用户截图）。
  double _materialCapsuleHeight(BuildContext context) {
    if (!showLabels) return kAdaptiveNavBarContentHeight;
    final TextStyle style =
        (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w600,
        );
    final TextPainter painter = TextPainter(
      text: TextSpan(text: 'Ag国', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
      maxLines: 1,
    )..layout();
    final double labelHeight = painter.height;
    painter.dispose();
    return math.max(
      kAdaptiveNavBarContentHeight,
      (2 * _kCapsuleVerticalPadding +
              AdaptiveNavTileMetrics.pillHeight +
              4 +
              labelHeight)
          .ceilToDouble(),
    );
  }

  /// MD3 悬浮底栏胶囊里的一排目的地（[indices] 是进胶囊的那些，按视觉序）。
  /// 标签显示时恒显示、不截断：
  /// 1. 每格要的宽 = max([_kMinNavCellWidth], 标签实宽（12 号 w600、跟随
  ///    文字缩放）+ [_kNavCellLabelSlack])；标签隐藏时每格就是最窄宽；
  /// 2. 全部放得下 → 全部出现，最宽一格乘以格数也放得下就等分，否则按所需宽
  ///    比例分（窄格自动走紧凑形态：药丸收窄、标签小一号）；纯图标时每格
  ///    至少 [_kMinIconNavCellWidth]（48 触控目标）；
  /// 3. 放不下 → 按用户的模块顺序从前往后放，剩下的收进最右的「更多」。
  ///    反转底栏方向（[searchLeading]）时整排镜像：[indices] 已是倒序，从末端
  ///    （用户顺序的开头）往回放，「更多」挪到最左、紧挨查词 FAB，菜单里仍按
  ///    用户顺序列出。
  Widget _buildMaterialFloatingRow(
    BuildContext context,
    BoxConstraints box,
    List<int> indices,
  ) {
    if (!box.hasBoundedWidth || indices.isEmpty) {
      return Row(
        children: <Widget>[
          for (final int i in indices) Expanded(child: _cell(context, i)),
        ],
      );
    }
    final double width = box.maxWidth;
    final TextStyle style =
        (Theme.of(context).textTheme.labelMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w600,
        );
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    double need(String label) {
      if (!showLabels) return _kMinIconNavCellWidth;
      final TextPainter painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double labelWidth = painter.width;
      painter.dispose();
      return math.max(_kMinNavCellWidth, labelWidth + _kNavCellLabelSlack);
    }

    final Map<int, double> needs = <int, double>{
      for (final int i in indices) i: need(items[i].label),
    };
    final double total = needs.values.fold(0, (double a, double b) => a + b);
    final List<int> visible = <int>[];
    double? moreNeed;
    if (total <= width) {
      visible.addAll(indices);
    } else {
      final double more = need(t.home_nav_more);
      moreNeed = more;
      double used = more;
      final Iterable<int> fillOrder = searchLeading
          ? indices.reversed
          : indices;
      final Set<int> fits = <int>{};
      for (final int i in fillOrder) {
        if (used + needs[i]! > width) break;
        fits.add(i);
        used += needs[i]!;
      }
      visible.addAll(indices.where(fits.contains));
    }
    final List<int> overflow = <int>[
      for (final int i in searchLeading ? indices.reversed : indices)
        if (!visible.contains(i)) i,
    ];
    final double? moreSlot = moreNeed;
    final List<double> slotNeeds = <double>[
      for (final int i in visible) needs[i]!,
      if (moreSlot != null) moreSlot,
    ];
    final double slotTotal = slotNeeds.fold(0, (double a, double b) => a + b);
    final double maxNeed = slotNeeds.fold(
      0,
      (double a, double b) => math.max(a, b),
    );
    final bool equal = maxNeed * slotNeeds.length <= width;
    double cellWidthOf(double slotNeed) =>
        equal ? width / slotNeeds.length : width * slotNeed / slotTotal;
    int flexOf(double slotNeed) => equal ? 1 : (slotNeed * 10).round();
    // 唯一一枚在项间滑动的指示器（[_SlidingIndicatorScope]）：当前页在「更多」
    // 里时滑到「更多」那格，是 FAB 那一项（查词）时不画。
    final FushiFocusId? selectedId = visible.contains(currentIndex)
        ? FushiFocusId('$idPrefix-$currentIndex')
        : (overflow.contains(currentIndex) ? _NavMoreCell.focusId : null);
    final _FloatingBarStyle? barStyle = _FloatingBarStyle.maybeOf(context);
    final Widget? moreCell = moreSlot == null
        ? null
        : Expanded(
            flex: flexOf(moreSlot),
            child: _NavMoreCell(
              items: items,
              overflow: overflow,
              currentIndex: currentIndex,
              onTap: onTap,
              cellWidth: cellWidthOf(moreSlot),
            ),
          );
    return _SlidingIndicatorScope(
      selectedId: selectedId,
      color: barStyle?.indicator ?? Theme.of(context).colorScheme.tertiary,
      child: Row(
        children: <Widget>[
          if (searchLeading && moreCell != null) moreCell,
          for (final int i in visible)
            Expanded(
              flex: flexOf(needs[i]!),
              child: _cell(context, i, cellWidth: cellWidthOf(needs[i]!)),
            ),
          if (!searchLeading && moreCell != null) moreCell,
        ],
      ),
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

    // 结构恒定：无论 MD3 / 毛玻璃 / 液态 / 玻璃设计系统，外层永远是同一个
    // [_NavSurfaceBackdrop]，带 [fushiMaterialNavKey] 的 Material 永远在它的
    // 同一个槽位里，切换时只换背景槽与几何参数。旧实现按「是否玻璃」把 Material
    // 包进 / 拆出 FushiGlassSurface，设计系统一切换整条导航（含各目的地的焦点
    // 目标）就在同一帧里被重挂，Mac 调试版触发 `_elements.contains(element)`
    // 断言。MD3 的底色 / 毛玻璃 / eink 描边都画在悬浮胶囊 / 面板
    // （[_FloatingNavSurface]）上。
    if (horizontal) {
      // 玻璃设计系统（iOS 26）：底栏是离左右 16、离底 ≥16 的悬浮玻璃胶囊
      // （+ 右侧搜索圆钮），胶囊本体在前景里画（随最小化变宽窄，见
      // [_buildGlassTabBar]）；背景槽只画底部 scroll edge 带——从导航区上沿
      // 再往上伸 24，内容在胶囊上方就开始化开。手势区不再整条让出
      // （SafeArea 不吃 bottom）。
      // MD3（M3 Expressive，2026-10-06 用户「底部栏改为 m3e 悬浮的」）：离左右
      // 12、离底 ≥12 的悬浮全胶囊（surfaceContainer + 阴影，不贴边、不占满宽），
      // 内高 64；选中项是 56×32 的全圆角 secondaryContainer 药丸（expressive
      // spatial 弹簧带回弹地展开），12 号 w500 标签恒显示；目的地太多放不下时
      // 先收窄格宽 / 小一号字，再放不下就把超出的收进最右的「更多」（见
      // [_buildMaterialFloatingRow]），标签不截断。手势区不整条让出：胶囊浮在
      // 它上面（与 Apple 胶囊同一套 extendBody 让内容从下面滚过）。
      final double glassBottom = glassDesign
          ? _glassNavBarBottomMargin(context)
          : _materialNavBarBottomMargin(context);
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
          // 悬浮胶囊之外完全透明，内容从下面滚过；底色 / 阴影 / eink 描边都画在
          // 胶囊（[_FloatingNavSurface]）上。
          type: MaterialType.transparency,
          // Clamp text scaling exactly like the stock NavigationBar: at the
          // system's largest font sizes an unclamped label would push the bar to
          // a third of the screen.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: SafeArea(
              top: false,
              bottom: false,
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
                      : kAdaptiveNavBarContentHeight +
                            kAdaptiveNavBarFloatingTopGap +
                            glassBottom,
                ),
                child: Padding(
                  padding: glassDesign
                      ? EdgeInsets.fromLTRB(
                          kGlassNavBarSideMargin,
                          _kGlassNavBarTopGap,
                          kGlassNavBarSideMargin,
                          glassBottom,
                        )
                      : EdgeInsets.fromLTRB(
                          kAdaptiveNavFloatingMargin,
                          kAdaptiveNavBarFloatingTopGap,
                          kAdaptiveNavFloatingMargin,
                          glassBottom,
                        ),
                  child: glassDesign
                      ? _buildGlassTabBar(context)
                      : _buildMaterialFloatingBar(context),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 玻璃设计系统（macOS 26）：侧栏是离窗口左 / 上 / 下 8、圆角 20 的悬浮
    // 玻璃面板，宽窗口展开、medium 档收成窄条。MD3（M3 Expressive navigation
    // rail）：展开态 220 宽（行高 56、图标 + 文字横排、选中药丸撑满整行，取代
    // 旧 navigation drawer），收起态 96 宽（56×32 药丸 + 下方 12 号标签）；
    // 顶部是切换两态的菜单钮（[onToggleExtended]）+ 品牌位，宽度变化走
    // spatial 弹簧（[_AnimatedRailWidth]）。2026-10-06 用户「横屏也改为 m3e
    // 悬浮的」：MD3 rail 不再是贴边整列，而是离窗口左 / 上 / 下 12 的悬浮
    // 圆角面板（surfaceContainer + 阴影，[_FloatingNavSurface]），面板右侧留 6
    // 给阴影；占位宽 = 面板宽 + [kMaterialNavRailFloatingInset]。
    // 两套的行都从上往下排（品牌位在顶），不再在剩余高度里居中。
    final double railWidth = railExtended
        ? (glassDesign ? kGlassNavSidebarWidth : kMaterialNavRailExpandedWidth)
        : (glassDesign
              ? kAdaptiveNavRailWidth
              : kMaterialNavRailCollapsedWidth);
    const double glassInset = _kGlassSidebarMargin + 8;
    final VoidCallback? toggle = glassDesign ? null : onToggleExtended;
    final Widget? menu = toggle == null
        ? null
        : _NavRailMenuButton(extended: railExtended, onPressed: toggle);
    final Widget? brand = leading;
    // 品牌位：收起 rail 居中 64；展开态（玻璃侧栏 / MD3 展开 rail）靠起始边、
    // 缩到 56 的应用图标（FittedBox 等比缩）；MD3 展开态与菜单钮同排时缩到 48。
    final Widget header;
    if (menu != null && railExtended) {
      header = Padding(
        padding: const EdgeInsetsDirectional.only(start: 4, bottom: 4),
        child: Row(
          children: <Widget>[
            menu,
            if (brand != null) ...<Widget>[
              const SizedBox(width: 8),
              SizedBox.square(dimension: 48, child: brand),
            ],
          ],
        ),
      );
    } else {
      header = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (menu != null)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: menu),
          if (brand != null)
            Align(
              alignment: railExtended
                  ? AlignmentDirectional.centerStart
                  : Alignment.center,
              widthFactor: railExtended ? null : 1,
              heightFactor: 1,
              child: SizedBox(
                width: glassDesign || railExtended ? 56 : null,
                height: glassDesign || railExtended ? 56 : null,
                child: brand,
              ),
            ),
        ],
      );
    }
    return _NavSurfaceBackdrop(
      baseColor: colors.surface,
      glassMargin: glassDesign
          ? const EdgeInsets.all(_kGlassSidebarMargin)
          : null,
      glassRadius: _kGlassSidebarRadius,
      child: Material(
        key: fushiMaterialNavKey,
        // 悬浮面板之外透明；底色 / 阴影 / eink 描边画在 [_FloatingNavSurface]。
        type: MaterialType.transparency,
        child: _AnimatedRailWidth(
          width: glassDesign
              ? railWidth
              : railWidth + kMaterialNavRailFloatingInset,
          child: SafeArea(
            right: false,
            child: Padding(
              padding: glassDesign
                  ? EdgeInsets.zero
                  : const EdgeInsetsDirectional.fromSTEB(
                      _kMaterialRailFloatingStart,
                      _kMaterialRailFloatingStart,
                      _kMaterialRailFloatingEnd,
                      _kMaterialRailFloatingStart,
                    ),
              child: _FloatingNavSurface(
                paint: !glassDesign,
                borderRadius: BorderRadius.circular(_kMaterialRailPanelRadius),
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
                      if (menu != null || brand != null) header,
                      // 矮窗口下所有 tile 的总高可能超过可用高度：直接放进 Column 会 RenderFlex
                      // 溢出（左侧导航底部 overflow）。改用 SingleChildScrollView 让 tile 在窗口
                      // 过矮时滚动。
                      Expanded(
                        child: SingleChildScrollView(
                          // 侧栏同样只有一枚在项间纵向滑动的指示器（2026-10-06
                          // 用户「侧边栏也要有切换动画」）：收起 rail 的 56×32
                          // 药丸、展开 rail 的整行药丸都由它滑过去，选中项超出
                          // 可视区时自动滚进来。Apple 设计系统的行不登记药丸槽，
                          // 滑块不画。
                          child: _SlidingIndicatorScope(
                            selectedId:
                                currentIndex >= 0 && currentIndex < items.length
                                ? FushiFocusId('$idPrefix-$currentIndex')
                                : null,
                            color: isEinkTheme(context)
                                ? colors.onSurface
                                : colors.secondaryContainer,
                            child: Column(
                              children: <Widget>[
                                const SizedBox(height: 8),
                                for (final Widget tile in buildTiles(
                                  cellWidth: null,
                                ))
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

/// MD3 悬浮底栏右侧那颗独立 FAB 的内容（应用级主操作）。默认由
/// [adaptiveBottomBar] 用「查词」目的地生成；调用方可以换成当前页自己的主操作
/// （例如视频源后台补刮任务），保证同一时刻屏幕上只有这一颗。
@immutable
class AdaptiveNavFab {
  const AdaptiveNavFab({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selectedIcon,
    this.selected = false,
    this.experimentalBadge = false,
  });

  final IconData icon;
  final IconData? selectedIcon;

  /// tooltip / 读屏名（FAB 本身不画字）。
  final String label;
  final VoidCallback onPressed;

  /// 它代表的目的地正是当前页（实心图标）。
  final bool selected;
  final bool experimentalBadge;
}

/// MD3 悬浮底栏胶囊内的配色与标签开关，由 [_MaterialFloatingBar] 提供给
/// 里面的目的地（[_FushiNavTile]）：vibrant 胶囊上的前景、选中指示器与其前景。
/// 侧轨不挂它，目的地照旧 surface 配色。
class _FloatingBarStyle extends InheritedWidget {
  const _FloatingBarStyle({
    required this.showLabels,
    required this.content,
    required this.indicator,
    required this.onIndicator,
    required super.child,
  });

  final bool showLabels;

  /// 胶囊上未选中的图标 / 标签色。
  final Color content;

  /// 选中项指示器药丸色（比胶囊更深一阶）与其上的图标色。
  final Color indicator;
  final Color onIndicator;

  static _FloatingBarStyle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FloatingBarStyle>();

  @override
  bool updateShouldNotify(_FloatingBarStyle oldWidget) =>
      oldWidget.showLabels != showLabels ||
      oldWidget.content != content ||
      oldWidget.indicator != indicator ||
      oldWidget.onIndicator != onIndicator;
}

/// MD3 悬浮底栏本体（2026-10-06 用户参考 M3E 官方 floating toolbar 示例）：
///
/// - 左：vibrant 饱和容器色（tertiaryContainer，随主题）的大胶囊，装目的地；
///   选中项是更深一阶的 tertiary 指示器药丸 + onTertiary 图标；
/// - 右：一颗与胶囊同高的大号圆角方 FAB（primaryContainer，[_NavBarFab]）；
/// - 随滚动收起（与 Apple 胶囊共用 [FushiAppleScrollChrome] 的最小化状态机：
///   下滑累计 20 收起、上滑 12 展开，只认用户滚动、到顶 / 到底的回弹不触发）：
///   胶囊按 expressive spatial 弹簧缩成只装当前项图标 + 标签的小胶囊（指示器
///   色），FAB 原地保留；点小胶囊、向上滚或焦点进入底栏都弹簧展开。
///
/// 收起只改胶囊的**绘制宽度**与两层内容的透明度：底栏占的高度不变，页面的
/// 滚动视口与 MediaQuery padding 都不随之变化，不会引起内容跳动 / 回弹。
/// 隐藏的那一层同时移出命中测试与焦点遍历，手柄不会落到看不见的格子上。
/// 墨水屏 / 减弱动态效果下直接切换。
class _MaterialFloatingBar extends StatefulWidget {
  const _MaterialFloatingBar({
    required this.minimized,
    required this.onExpand,
    required this.showLabels,
    required this.currentItem,
    required this.expandFocusIds,
    required this.fab,
    required this.capsule,
    required this.height,
    this.fabLeading = false,
  });

  /// 胶囊高（[_MaterialNavCluster._materialCapsuleHeight]）；FAB 与之同高。
  final double height;

  final bool minimized;
  final VoidCallback? onExpand;
  final bool showLabels;

  /// 胶囊里的当前项（收起后留下的小胶囊）。null = 当前目的地不在胶囊里
  /// （FAB 那一项），收起时整条胶囊让位、只留 FAB。
  final AdaptiveNavItem? currentItem;

  /// 从收起小胶囊展开后焦点挪去的目标，按顺序试（当前项格 / 「更多」）。
  final List<FushiFocusId> expandFocusIds;
  final AdaptiveNavFab? fab;

  /// 展开态的胶囊内容（目的地一排）。
  final Widget capsule;

  /// FAB 在胶囊起始侧（反转底栏方向）：整条底栏镜像，胶囊收起时缩向末端。
  final bool fabLeading;

  @override
  State<_MaterialFloatingBar> createState() => _MaterialFloatingBarState();
}

class _MaterialFloatingBarState extends State<_MaterialFloatingBar>
    with SingleTickerProviderStateMixin {
  /// 收起小胶囊里指示器药丸的高与左右内边距、胶囊内留白。
  static const double _kMiniPillHeight = 48;
  static const double _kMiniPillPadding = 16;
  static const double _kMiniInset = 8;

  late final FushiSpring _min = FushiSpring(
    vsync: this,
    initial: widget.minimized ? 1 : 0,
    spring: _kNavExpressiveSpatial,
  );

  @override
  void didUpdateWidget(covariant _MaterialFloatingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minimized != widget.minimized) {
      _min.animateTo(
        widget.minimized ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _min.dispose();
    super.dispose();
  }

  void _expand() => widget.onExpand?.call();

  /// 焦点进入底栏（任一目的地 / FAB）：收起态就展开。
  void _onBarFocusChange(bool hasFocus) {
    if (hasFocus && widget.minimized) _expand();
  }

  /// 焦点落在收起小胶囊上：展开，并在新一帧把焦点交给展开后的当前项格
  /// （小胶囊随即移出焦点遍历，不挪走焦点就丢了）。
  void _onMiniFocusChange(bool hasFocus) {
    if (!hasFocus || !widget.minimized) return;
    _expand();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final FushiFocusController? controller = FushiFocusRoot.maybeControllerOf(
        context,
      );
      if (controller == null) return;
      for (final FushiFocusId id in widget.expandFocusIds) {
        if (controller.requestById(id)) return;
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  double _miniWidth(BuildContext context, TextStyle labelStyle) {
    final AdaptiveNavItem? item = widget.currentItem;
    if (item == null) return 0;
    double content = 24;
    if (widget.showLabels) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: item.label, style: labelStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      content += 8 + painter.width;
      painter.dispose();
    }
    return content + 2 * _kMiniPillPadding + 2 * _kMiniInset;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool eink = isEinkTheme(context);
    final Color capsuleColor = eink
        ? colors.surfaceContainer
        : colors.tertiaryContainer;
    final Color content = eink ? colors.onSurface : colors.onTertiaryContainer;
    final Color indicator = eink ? colors.onSurface : colors.tertiary;
    final Color onIndicator = eink ? colors.surface : colors.onTertiary;
    final TextStyle miniLabelStyle = (textTheme.labelLarge ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.w600, color: onIndicator);
    final AdaptiveNavItem? current = widget.currentItem;
    final Widget mini = current == null
        ? const SizedBox.shrink()
        : Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: _onMiniFocusChange,
            child: _NavMiniCapsule(
              item: current,
              showLabel: widget.showLabels,
              color: indicator,
              foreground: onIndicator,
              labelStyle: miniLabelStyle,
              height: _kMiniPillHeight,
              horizontalPadding: _kMiniPillPadding,
              onPressed: _expand,
            ),
          );
    final AdaptiveNavFab? fab = widget.fab;
    // 反转底栏方向时整条镜像：FAB 在起始侧，胶囊与收起小胶囊都贴末端
    // （紧挨 FAB 的另一侧），收起时朝末端缩。
    final bool leading = widget.fabLeading;
    final AlignmentDirectional anchor = leading
        ? AlignmentDirectional.centerEnd
        : AlignmentDirectional.centerStart;
    final List<Widget> fabSlot = <Widget>[
      if (fab != null) ...<Widget>[
        if (!leading) const SizedBox(width: kAdaptiveNavFloatingMargin),
        _NavBarFab(fab: fab, height: widget.height),
        if (leading) const SizedBox(width: kAdaptiveNavFloatingMargin),
      ],
    ];
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onBarFocusChange,
      child: _FloatingBarStyle(
        showLabels: widget.showLabels,
        content: content,
        indicator: indicator,
        onIndicator: onIndicator,
        child: Row(
          children: <Widget>[
            if (leading) ...fabSlot,
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  final double full = box.maxWidth;
                  final double miniWidth = math.min(
                    full,
                    _miniWidth(context, miniLabelStyle),
                  );
                  return AnimatedBuilder(
                    animation: _min.animation,
                    builder: (BuildContext context, Widget? _) {
                      final double target = _min.target;
                      final double raw = _min.value;
                      final double t = (raw - target).abs() < 0.001
                          ? target
                          : raw;
                      final double shown = t.clamp(0.0, 1.0);
                      final double width = (full + (miniWidth - full) * t)
                          .clamp(miniWidth * 0.9, full);
                      final bool minimized = widget.minimized;
                      // 没有小胶囊可留（FAB 是当前项）：整条胶囊连同底色淡出让位。
                      final bool vanish = widget.currentItem == null;
                      return Align(
                        alignment: anchor,
                        heightFactor: 1,
                        child: _NavCapsuleVanish(
                          vanish: vanish,
                          minimized: minimized,
                          shown: shown,
                          child: SizedBox(
                            width: width,
                            child: _FloatingNavSurface(
                              color: capsuleColor,
                              borderRadius: BorderRadius.circular(
                                kAdaptiveNavBarContentHeight / 2,
                              ),
                              child: Stack(
                                fit: StackFit.passthrough,
                                children: <Widget>[
                                  IgnorePointer(
                                    ignoring: minimized,
                                    child: ExcludeFocus(
                                      excluding: minimized,
                                      child: Opacity(
                                        opacity: 1 - shown,
                                        child: OverflowBox(
                                          alignment: anchor,
                                          minWidth: full,
                                          maxWidth: full,
                                          fit: OverflowBoxFit.deferToChild,
                                          child: widget.capsule,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      ignoring: !minimized,
                                      child: ExcludeFocus(
                                        excluding: !minimized,
                                        child: Opacity(
                                          opacity: shown,
                                          child: Align(
                                            alignment: anchor,
                                            child: Padding(
                                              padding: leading
                                                  ? const EdgeInsetsDirectional.only(
                                                      end: _kMiniInset,
                                                    )
                                                  : const EdgeInsetsDirectional.only(
                                                      start: _kMiniInset,
                                                    ),
                                              child: mini,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (!leading) ...fabSlot,
          ],
        ),
      ),
    );
  }
}

/// BUG-3064：当前目的地不在胶囊里（FAB 那一项）时，收起没有小胶囊可留——
/// 整条胶囊（连同底色 / 投影）随收起进度淡出，收起后不吃指针、不进焦点遍历、
/// 不进语义树；[vanish] 为 false 时原样返回，树结构不变。
class _NavCapsuleVanish extends StatelessWidget {
  const _NavCapsuleVanish({
    required this.vanish,
    required this.minimized,
    required this.shown,
    required this.child,
  });

  final bool vanish;
  final bool minimized;

  /// 收起进度（0 = 展开，1 = 收起）。
  final double shown;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool gone = vanish && minimized;
    return ExcludeSemantics(
      excluding: gone,
      child: IgnorePointer(
        ignoring: gone,
        child: ExcludeFocus(
          excluding: gone,
          child: Opacity(opacity: vanish ? 1 - shown : 1, child: child),
        ),
      ),
    );
  }
}

/// 收起态的小胶囊：当前目的地的图标（+ 标签），M3E 活动指示器色的全圆角
/// 药丸。点按 / A / 回车展开整条胶囊（不切 tab）。焦点 id `nav-mini-bar`
/// （与 Apple 胶囊最小化圆同名，两套设计系统不会同时挂载）。
class _NavMiniCapsule extends StatelessWidget {
  const _NavMiniCapsule({
    required this.item,
    required this.showLabel,
    required this.color,
    required this.foreground,
    required this.labelStyle,
    required this.height,
    required this.horizontalPadding,
    required this.onPressed,
  });

  final AdaptiveNavItem item;
  final bool showLabel;
  final Color color;
  final Color foreground;
  final TextStyle labelStyle;
  final double height;
  final double horizontalPadding;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(height / 2);
    return FushiTooltip(
      message: item.label,
      child: Semantics(
        button: true,
        selected: true,
        label: item.label,
        excludeSemantics: true,
        onTap: onPressed,
        child: Material(
          color: color,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            canRequestFocus: false,
            child: FushiFocusTarget(
              id: const FushiFocusId('nav-mini-bar'),
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _maybeBadge(
                        item: item,
                        child: FushiIcon(
                          item.selectedIcon ?? item.icon,
                          size: 24,
                          color: foreground,
                        ),
                      ),
                      if (showLabel) ...<Widget>[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: labelStyle,
                          ),
                        ),
                      ],
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

/// MD3 悬浮底栏右侧的大号圆角方 FAB（M3E floating toolbar 旁的 FAB）：与胶囊
/// 同高 64、圆角 20、primaryContainer 饱和色、轻阴影；按下按 M3E 弹簧缩放
/// （[FushiPressScale]）。独立焦点目标 `nav-bar-fab`，A / 回车触发。墨水屏
/// 无阴影、描边。
class _NavBarFab extends StatelessWidget {
  const _NavBarFab({required this.fab, required this.height});

  /// 与胶囊同高（正方形）。
  final double height;

  static const FushiFocusId focusId = FushiFocusId('nav-bar-fab');
  static const double _kRadius = 20;

  final AdaptiveNavFab fab;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color color = eink
        ? colors.surfaceContainer
        : colors.primaryContainer;
    final Color foreground = eink
        ? colors.onSurface
        : colors.onPrimaryContainer;
    final IconData icon = fab.selected
        ? (fab.selectedIcon ?? fab.icon)
        : fab.icon;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final Widget glyph = FushiIcon(
      icon,
      key: ValueKey<(IconData, bool)>((icon, fab.selected)),
      size: 28,
      color: foreground,
    );
    return FushiTooltip(
      message: fab.label,
      child: Semantics(
        button: true,
        selected: fab.selected,
        label: fab.label,
        excludeSemantics: true,
        onTap: fab.onPressed,
        child: FushiPressScale(
          scale: 0.92,
          child: Material(
            color: color,
            surfaceTintColor: Colors.transparent,
            shadowColor: colors.shadow,
            elevation: eink ? 0 : 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(_kRadius),
              side: eink ? BorderSide(color: colors.outline) : BorderSide.none,
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: fab.onPressed,
              canRequestFocus: false,
              child: FushiFocusTarget(
                id: focusId,
                child: SizedBox.square(
                  dimension: height,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: duration,
                      switchInCurve: FushiMotion.enter,
                      switchOutCurve: FushiMotion.exit,
                      child: fab.experimentalBadge
                          ? FushiBadgeControl(key: glyph.key, child: glyph)
                          : glyph,
                    ),
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

/// MD3 悬浮底栏的**滑动**活动指示器（2026-10-06 用户「底部栏切换做个滚动
/// 动画」）：胶囊里只有这一枚指示器药丸，切换目的地时按 M3E expressive
/// spatial 弹簧从旧项滑到新项（位置 + 宽度一起插值），而不是旧项淡出、新项原地
/// 展开。各目的地仍保留自己的药丸槽（几何不变，状态层照旧裁到它）；滑动进行中
/// 目的地自己的填充置透明、只画这一枚滑块，落定后滑块消失、交回选中项自己的
/// 药丸（两者同色同矩形，交接处看不出来）。
///
/// 目标位置在 paint 时直接取被选中目的地药丸槽的真实矩形（目的地在 build 时向
/// 本 scope 登记自己的槽 key），不靠估算的格宽 / 字高，任何文字缩放下都严丝合缝。
/// 墨水屏 / 减弱动态效果下直接跳到新位置。
class _SlidingIndicatorScope extends StatefulWidget {
  const _SlidingIndicatorScope({
    required this.selectedId,
    required this.color,
    required this.child,
  });

  /// 选中目的地的焦点 id（`nav-bar-<序号>`，当前页在「更多」里时是
  /// `nav-bar-more`）。
  final FushiFocusId? selectedId;
  final Color color;
  final Widget child;

  static _SlidingIndicatorRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SlidingIndicatorRegistry>();

  @override
  State<_SlidingIndicatorScope> createState() => _SlidingIndicatorScopeState();
}

class _SlidingIndicatorRegistry extends InheritedWidget {
  const _SlidingIndicatorRegistry({
    required this.state,
    required this.sliding,
    required super.child,
  });

  final _SlidingIndicatorScopeState state;

  /// 滑块正在滑：目的地自己的药丸先不填色。
  final bool sliding;

  @override
  bool updateShouldNotify(_SlidingIndicatorRegistry oldWidget) =>
      !identical(oldWidget.state, state) || oldWidget.sliding != sliding;
}

class _SlidingIndicatorScopeState extends State<_SlidingIndicatorScope>
    with SingleTickerProviderStateMixin {
  final Map<FushiFocusId, GlobalKey> _slots = <FushiFocusId, GlobalKey>{};

  late final FushiSpring _progress = FushiSpring(
    vsync: this,
    initial: 1,
    spring: _kNavExpressiveSpatial,
  );

  /// 本次滑动的起点（上一帧画出来的矩形）；null = 没有在滑。
  Rect? _from;

  /// 最近一次画出来的矩形，切换时作为新一段滑动的起点。
  Rect? _painted;

  bool _sliding = false;

  @override
  void initState() {
    super.initState();
    _progress.animation.addStatusListener(_onStatus);
  }

  /// 滑动落定：交回选中项自己的药丸。状态回调可能在 build 中途（重置进度时）
  /// 触发，推到帧后再复核、再 setState。
  void _onStatus(AnimationStatus status) {
    if (status.isAnimating || !_sliding) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sliding || _progress.animation.isAnimating) return;
      setState(() {
        _sliding = false;
        _from = null;
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 目的地在 build 时登记自己的药丸槽。
  void register(FushiFocusId id, GlobalKey slot) => _slots[id] = slot;

  void unregister(FushiFocusId id, GlobalKey slot) {
    if (identical(_slots[id], slot)) _slots.remove(id);
  }

  @override
  void didUpdateWidget(covariant _SlidingIndicatorScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId) {
      final Rect? from = _painted ?? _rectOf(oldWidget.selectedId);
      final bool animate =
          fushiExpressiveMotionEnabled(context) &&
          from != null &&
          oldWidget.selectedId != null;
      _progress.animateTo(0, animate: false);
      _progress.animateTo(1, animate: animate);
      // build 内直接改字段：紧接着的 build 就用新值（不能 setState）。
      _from = animate ? from : null;
      _sliding = animate;
      _revealSelected();
    }
  }

  /// 选中项在可滚动的侧栏里超出可视区时滚进来（底栏没有 Scrollable，空操作）。
  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final BuildContext? slot = _slots[widget.selectedId]?.currentContext;
      if (slot == null || !slot.mounted) return;
      final Duration duration = fushiMotionDuration(slot, FushiMotion.medium);
      await FushiFocusScroll.ensureVisible(
        slot,
        alignment: 0,
        duration: duration,
        curve: FushiMotion.standard,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
      if (!slot.mounted) return;
      await FushiFocusScroll.ensureVisible(
        slot,
        alignment: 0,
        duration: duration,
        curve: FushiMotion.standard,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _progress.animation.removeStatusListener(_onStatus);
    _progress.dispose();
    super.dispose();
  }

  /// [id] 那一格药丸槽相对本 scope 的矩形（取上一帧的布局）。
  Rect? _rectOf(FushiFocusId? id) {
    final RenderObject? scope = context.findRenderObject();
    if (id == null || scope is! RenderBox || !scope.hasSize) return null;
    final RenderObject? slot = _slots[id]?.currentContext?.findRenderObject();
    if (slot is! RenderBox || !slot.attached || !slot.hasSize) return null;
    return slot.localToGlobal(Offset.zero, ancestor: scope) & slot.size;
  }

  /// 选中目的地药丸槽相对 [scope] 的矩形；还没布局 / 没登记时 null。
  Rect? _targetIn(RenderBox scope) {
    final FushiFocusId? id = widget.selectedId;
    if (id == null) return null;
    final RenderObject? slot = _slots[id]?.currentContext?.findRenderObject();
    if (slot is! RenderBox || !slot.attached || !slot.hasSize) return null;
    return slot.localToGlobal(Offset.zero, ancestor: scope) & slot.size;
  }

  @override
  Widget build(BuildContext context) {
    return _SlidingIndicatorRegistry(
      state: this,
      sliding: _sliding,
      child: CustomPaint(
        painter: _SlidingIndicatorPainter(this),
        child: widget.child,
      ),
    );
  }
}

class _SlidingIndicatorPainter extends CustomPainter {
  _SlidingIndicatorPainter(this.state)
    : super(repaint: state._progress.animation);

  final _SlidingIndicatorScopeState state;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderObject? scope = state.context.findRenderObject();
    if (scope is! RenderBox || !scope.hasSize) return;
    final Rect? target = state._targetIn(scope);
    if (target == null) {
      state._painted = null;
      return;
    }
    final double t = state._progress.value;
    final Rect? from = state._from;
    final Rect rect = from == null || !state._sliding
        ? target
        : Rect.lerp(from, target, t)!;
    state._painted = rect;
    // 静止时选中项自己的药丸在画（同色同矩形），滑块不重复画。
    if (!state._sliding) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()..color = state.widget.color,
    );
  }

  @override
  bool shouldRepaint(_SlidingIndicatorPainter oldDelegate) => true;
}

/// 「更多」菜单的圆角（M3E 大容器）。
const double _kNavMenuRadius = 28;

/// 「更多」菜单里的一行：图标 + 标签；当前页整行是与底栏同款的 tertiary
/// 指示器胶囊（onTertiary 前景），其余是胶囊上的 onTertiaryContainer 色。
class _NavMenuRow extends StatelessWidget {
  const _NavMenuRow({
    required this.item,
    required this.selected,
    required this.content,
    required this.indicator,
    required this.onIndicator,
    required this.labelStyle,
  });

  final AdaptiveNavItem item;
  final bool selected;
  final Color content;
  final Color indicator;
  final Color onIndicator;
  final TextStyle labelStyle;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? onIndicator : content;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: selected ? indicator : indicator.withValues(alpha: 0),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: <Widget>[
          _maybeBadge(
            item: item,
            child: FushiIcon(
              selected ? (item.selectedIcon ?? item.icon) : item.icon,
              size: 24,
              color: foreground,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle.copyWith(
                color: foreground,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// MD3 悬浮导航的表面（底部胶囊 / 侧边面板）：surfaceContainer 实底 + 轻阴影
/// （elevation 3），全圆角裁剪；系统毛玻璃材质开着时换成同色阶的
/// [FushiGlassSurface]；eink 不画阴影（灰阶下糊成脏边），改一圈前景色描边。
/// 目的地的水波画在这块 Material 上。
///
/// [paint] 为 false（Apple 设计系统，玻璃另画）时只是透明直通，结构不变——
/// 设计系统切换不重挂目的地。
class _FloatingNavSurface extends StatelessWidget {
  const _FloatingNavSurface({
    required this.borderRadius,
    required this.child,
    this.paint = true,
    this.color,
  });

  final BorderRadius borderRadius;
  final bool paint;
  final Widget child;

  /// 表面色；null = surfaceContainer（侧轨面板）。底栏胶囊传 vibrant 容器色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool frosted =
        paint && glassMaterialOf(context) != FushiGlassMaterial.off;
    final Color base = color ?? colors.surfaceContainer;
    return Material(
      color: paint && !frosted ? base : Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.shadow,
      elevation: paint && !eink ? 3 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: paint ? borderRadius : BorderRadius.zero,
        side: paint && eink
            ? BorderSide(color: colors.outline)
            : BorderSide.none,
      ),
      clipBehavior: paint ? Clip.antiAlias : Clip.none,
      child: Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: frosted
                  ? FushiGlassSurface(
                      baseColor: base,
                      borderRadius: borderRadius,
                      showBorder: false,
                      grouped: true,
                      child: const SizedBox.expand(),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// MD3 悬浮底栏「更多」格：目的地多到格宽放不下标签时，超出的（按用户的模块
/// 顺序排在后面的那些）收进这里，点开是列出它们的菜单。当前页在其中时这一格
/// 显示为选中（药丸实底），菜单里当前项加粗带勾。独立焦点目标
/// `nav-bar-more`，A / 回车打开菜单。
class _NavMoreCell extends StatefulWidget {
  const _NavMoreCell({
    required this.items,
    required this.overflow,
    required this.currentIndex,
    required this.onTap,
    required this.cellWidth,
  });

  final List<AdaptiveNavItem> items;

  /// 收进菜单的目的地序号（与 [items] 同一视觉序）。
  final List<int> overflow;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final double? cellWidth;

  static const FushiFocusId focusId = FushiFocusId('nav-bar-more');

  @override
  State<_NavMoreCell> createState() => _NavMoreCellState();
}

class _NavMoreCellState extends State<_NavMoreCell> {
  Future<void> _open() async {
    final RenderObject? cell = context.findRenderObject();
    final RenderObject? overlay = Overlay.of(
      context,
    ).context.findRenderObject();
    if (cell is! RenderBox || overlay is! RenderBox) return;
    final Rect rect =
        cell.localToGlobal(Offset.zero, ancestor: overlay) & cell.size;
    final RelativeRect position = RelativeRect.fromRect(
      rect,
      Offset.zero & overlay.size,
    );
    // 菜单与底栏胶囊同一套配色（2026-10-06 用户「颜色要和底部栏一致」）：
    // tertiaryContainer 底 + onTertiaryContainer 字 / 图标，当前项是同款 tertiary
    // 指示器胶囊（不打勾）；大圆角，从「更多」处展开。墨水屏
    // 换成 surface 底 + 反色指示器。
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final Color menuColor = eink
        ? colors.surfaceContainer
        : colors.tertiaryContainer;
    final Color content = eink ? colors.onSurface : colors.onTertiaryContainer;
    final Color indicator = eink ? colors.onSurface : colors.tertiary;
    final Color onIndicator = eink ? colors.surface : colors.onTertiary;
    final TextStyle labelStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle());
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    final int? picked = await showFushiMenu<int>(
      context: context,
      position: position,
      color: menuColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: colors.shadow,
      elevation: eink ? 0 : 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_kNavMenuRadius),
        side: eink ? BorderSide(color: colors.outline) : BorderSide.none,
      ),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      popUpAnimationStyle: AnimationStyle(
        // BUG-3005：原生菜单把这条曲线用于整条 route.animation，随后会再
        // 经 Interval 驱动尺寸与透明度；spatial 回弹超过 1 会让 Interval
        // 断言。这里必须用保持 0..1 的 effects 弹簧。
        curve: FushiMotion.enter,
        duration: duration,
        reverseCurve: FushiMotion.exit,
        reverseDuration: fushiMotionDuration(context, FushiMotion.short),
      ),
      items: <PopupMenuEntry<int>>[
        for (final int i in widget.overflow)
          PopupMenuItem<int>(
            value: i,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _NavMenuRow(
              item: widget.items[i],
              selected: i == widget.currentIndex,
              content: content,
              indicator: indicator,
              onIndicator: onIndicator,
              labelStyle: labelStyle,
            ),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked != widget.currentIndex) fushiSelectionHaptic(context);
    widget.onTap(picked);
  }

  @override
  Widget build(BuildContext context) {
    final bool selected = widget.overflow.contains(widget.currentIndex);
    return _NavFocusCell(
      id: _NavMoreCell.focusId,
      item: AdaptiveNavItem(
        icon: FushiIcons.moreHoriz,
        label: t.home_nav_more,
        experimentalBadge: widget.overflow.any(
          (int i) => widget.items[i].experimentalBadge,
        ),
      ),
      selected: selected,
      horizontal: true,
      cellWidth: widget.cellWidth,
      onSelect: () => unawaited(_open()),
    );
  }
}

/// rail 宽度在展开 / 收起两态之间按 M3E default spatial 弹簧过渡。
///
/// 结构恒定（SizedBox → ClipRect → OverflowBox）：内容始终按**目标宽**排版、
/// 由外层裁出当前宽——展开时整行逐渐露出、收起时右侧空白收拢，过渡中不会
/// 把展开态的行硬压进收起宽度里溢出；静止时 OverflowBox 与外层同宽、不裁剪，
/// 几何与不包时一致。树结构不随动画增删层级，目的地的焦点目标不会重挂。
/// 墨水屏 / 减弱动态效果下瞬间到位。
class _AnimatedRailWidth extends StatefulWidget {
  const _AnimatedRailWidth({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  State<_AnimatedRailWidth> createState() => _AnimatedRailWidthState();
}

class _AnimatedRailWidthState extends State<_AnimatedRailWidth>
    with SingleTickerProviderStateMixin {
  late final FushiSpring _width = FushiSpring(
    vsync: this,
    initial: widget.width,
    spring: fushiExpressiveDefaultSpatial,
  );

  @override
  void didUpdateWidget(covariant _AnimatedRailWidth oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.width != widget.width) {
      _width.animateTo(
        widget.width,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _width.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _width.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double target = widget.width;
        final double raw = _width.value;
        final bool settled = (raw - target).abs() < 0.5;
        return SizedBox(
          width: settled ? target : math.max(0.0, raw),
          child: ClipRect(
            clipBehavior: settled ? Clip.none : Clip.hardEdge,
            child: OverflowBox(
              alignment: AlignmentDirectional.centerStart,
              minWidth: target,
              maxWidth: target,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// MD3 rail 顶部的菜单钮（M3E navigation rail 的 menu button）：切换展开 /
/// 收起。图标 menu ↔ menu_open 旋转交叉淡化；悬停 / 按压 / 焦点状态层是与
/// 导航药丸同圆角的 56×40 胶囊。独立焦点目标（`nav-rail-menu`），
/// `autoHome: false`：被动 auto-home 仍落到第一个目的地，只有显式方向导航
/// 才停在这里；A / 回车经 [InkWell] 的 ActivateIntent 映射触发。
class _NavRailMenuButton extends StatelessWidget {
  const _NavRailMenuButton({required this.extended, required this.onPressed});

  static const FushiFocusId focusId = FushiFocusId('nav-rail-menu');

  final bool extended;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final String tooltip = extended
        ? t.home_nav_rail_collapse
        : t.home_nav_rail_expand;
    final IconData icon = extended ? FushiIcons.chevronLeft : FushiIcons.menu;
    const BorderRadius radius = BorderRadius.all(
      Radius.circular(_kMaterialMenuPillHeight / 2),
    );
    void activate() {
      fushiSelectionHaptic(context);
      onPressed();
    }

    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        expanded: extended,
        label: tooltip,
        excludeSemantics: true,
        onTap: activate,
        child: InkWell(
          onTap: activate,
          canRequestFocus: false,
          borderRadius: radius,
          child: FushiFocusTarget(
            id: focusId,
            autoHome: false,
            child: SizedBox(
              width: _kMaterialPillWidth,
              height: _kMaterialMenuPillHeight,
              child: Center(
                child: AnimatedSwitcher(
                  duration: duration,
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: RotationTransition(
                            turns: Tween<double>(
                              begin: -0.125,
                              end: 0,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                  child: FushiIcon(
                    icon,
                    key: ValueKey<IconData>(icon),
                    size: 24,
                    color: colors.onSurfaceVariant,
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
  static const EdgeInsets _kLensExpansion = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 7,
  );

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
    final int pos = ((align + 1) / 2 * (widget.itemCount - 1)).round().clamp(
      0,
      widget.itemCount - 1,
    );
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
                            builder:
                                (
                                  BuildContext context,
                                  double value,
                                  double velocity,
                                  Widget? _,
                                ) {
                                  return SpringBuilder(
                                    value:
                                        morph &&
                                            _lensEnabled &&
                                            (_down ||
                                                _dragging ||
                                                (value - target).abs() > 0.05)
                                        ? 1.0
                                        : 0.0,
                                    spring: GlassSpring.snappy(
                                      duration: const Duration(
                                        milliseconds: 300,
                                      ),
                                    ),
                                    builder:
                                        (
                                          BuildContext context,
                                          double thickness,
                                          Widget? _,
                                        ) => content(
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
    } else {
      // MD3 导航是悬浮胶囊 / 面板，毛玻璃画在 [_FloatingNavSurface] 里，
      // 胶囊之外不铺底。
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

  /// 所在 MD3 悬浮胶囊的滑动指示器（登记本格药丸槽，供它取目标矩形）。
  _SlidingIndicatorScopeState? _slider;

  @override
  void dispose() {
    _slider?.unregister(widget.id, _indicatorKey);
    super.dispose();
  }

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
    final _SlidingIndicatorScopeState? slider = _SlidingIndicatorScope.maybeOf(
      context,
    )?.state;
    if (!identical(slider, _slider)) {
      _slider?.unregister(id, _indicatorKey);
      _slider = slider;
    }
    slider?.register(id, _indicatorKey);
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
    final bool labelsHidden =
        !(_FloatingBarStyle.maybeOf(context)?.showLabels ?? true);
    if (labelsHidden) {
      // 纯图标底栏（出厂形态）：名称进 tooltip（长按 / 悬停可见），无障碍语义
      // 仍报原文案——不靠 tooltip 的语义（那是「提示」不是「名称」）。
      tile = Semantics(
        label: item.label,
        selected: selected,
        child: FushiTooltip(
          message: item.label,
          excludeFromSemantics: true,
          child: tile,
        ),
      );
    } else if (metrics.compact) {
      // 窄格里的标签可能被省略，用 tooltip 补出完整名称（长按 / 悬停可见）。
      tile = FushiTooltip(message: item.label, child: tile);
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
                    !horizontal &&
                        !selected &&
                        states.contains(WidgetState.hovered)
                    ? glassHover
                    : Colors.transparent,
              )
            : null,
        child: Padding(
          padding: glassDesign || materialRailRow
              ? EdgeInsets.zero
              : EdgeInsets.symmetric(
                  // 纯图标底栏：32 高的药丸上下各补 8，整格点击区凑足 48dp
                  // 触控目标（带标签时标签行已把格撑过 48）。
                  vertical: horizontal ? (labelsHidden ? 8 : 0) : 4,
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
/// 同时由透明渐入填充色（M3 导航栏的「指示器展开」），M3 Expressive 下由
/// expressive spatial 弹簧驱动、落点带回弹（[_NavIndicatorPill]）；图标的线框 ↔
/// 实心切换走一次轻缩放交叉淡化，标签字重随之过渡。墨水屏 / 减弱动态效果下
/// 三处都瞬间到位，最终几何与配色不变。
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
    final Color fill = selected
        ? apple.accent
        : apple.accent.withValues(alpha: 0);
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
    final IconData icon = selected
        ? (item.selectedIcon ?? item.icon)
        : item.icon;
    Widget glyph(double size, {Color? color}) => _maybeBadge(
      item: item,
      child: FushiIcon(icon, size: size, color: color ?? fg),
    );
    if (horizontal && iconOnly) {
      const double extent =
          kGlassNavBarCapsuleHeight - 2 * _kGlassNavBarInnerPadding;
      return FushiTooltip(
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
      return FushiTooltip(
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
    final _SlidingIndicatorRegistry? slider = _SlidingIndicatorScope.maybeOf(
      context,
    );
    // 滑块正在纵向滑：本行先不填色；有滑块时填色瞬间切换（动效由滑块给），
    // 否则落定交接处会多一段淡入。
    final bool sliding = slider?.sliding ?? false;
    final Color pillColor = sliding
        ? Colors.transparent
        : (eink ? colors.onSurface : colors.secondaryContainer);
    final Color fg = selected
        ? (eink ? colors.surface : colors.onSecondaryContainer)
        : colors.onSurfaceVariant;
    final Duration duration = slider != null
        ? Duration.zero
        : fushiMotionDuration(context, FushiMotion.short);
    final IconData icon = selected
        ? (item.selectedIcon ?? item.icon)
        : item.icon;
    // 选中药丸撑满整行（2026-10-05 用户反馈「这个条的长度不对」）：旧实现药丸
    // 只包住图标 + 文字，而外层 InkWell 的悬停 / 焦点状态层是整行宽，选中项上
    // 就叠出一枚短的强调色药丸 + 一条更长的灰色底。现在两者同宽同圆角；选中时
    // 药丸实底盖住其下的状态层，只剩一个指示器。
    return AnimatedContainer(
      // 滑动指示器的终点读这一行的真实矩形。
      key: indicatorKey,
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
    // MD3 悬浮底栏的 vibrant 胶囊（[_FloatingBarStyle]）：指示器 / 前景取胶囊
    // 给的配色（eink 已在那里换成反色）；侧轨照旧 surface 配色。
    final _FloatingBarStyle? bar = _FloatingBarStyle.maybeOf(context);
    final bool showLabel = bar?.showLabels ?? true;
    // eink：选中药丸的 secondaryContainer == 页面底色，选中项只剩图标实心/线框
    // 之差；改反色药丸（segmentedButtonTheme / chipTheme 同一套处理）。
    final bool eink = isEinkTheme(context);
    // 滑动指示器正在项间滑：本格药丸先不填色，只留那一枚滑块。
    final bool sliding =
        _SlidingIndicatorScope.maybeOf(context)?.sliding ?? false;
    final Color pillColor = sliding
        ? Colors.transparent
        : bar?.indicator ??
              (eink ? colors.onSurface : colors.secondaryContainer);
    final Color pillIconColor =
        bar?.onIndicator ??
        (eink ? colors.surface : colors.onSecondaryContainer);
    final Color idleColor = bar?.content ?? colors.onSurfaceVariant;
    final Color selectedLabelColor = bar?.content ?? colors.onSurface;
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final IconData icon = selected
        ? (item.selectedIcon ?? item.icon)
        : item.icon;
    // 图标线框 ↔ 实心切换：一次轻缩放交叉淡化。
    final Widget glyph = AnimatedSwitcher(
      duration: duration,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1).animate(animation),
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
          color: selected ? pillIconColor : idleColor,
        ),
      ),
    );
    // M3 Expressive 导航标签：12 号 w500（labelMedium），选中加粗一档保证墨水
    // 屏上也分得清。
    final Widget label = AnimatedDefaultTextStyle(
      duration: duration,
      curve: FushiMotion.standard,
      style: (textTheme.labelMedium ?? const TextStyle()).copyWith(
        fontSize: compactLabel ? 11 : 12,
        color: selected ? selectedLabelColor : idleColor,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
      child: Text(
        item.label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _NavIndicatorPill(
          key: indicatorKey,
          selected: selected,
          color: pillColor,
          width: pillWidth,
          height: _pillHeight,
          child: glyph,
        ),
        if (showLabel) ...<Widget>[const SizedBox(height: 4), label],
      ],
    );
  }
}

/// MD3 导航的活动指示器（M3 Expressive）：全圆角药丸，选中时从图标宽（=高）
/// 横向展开到整宽、由透明渐入填充色，按 expressive default spatial 弹簧
/// （[_kNavExpressiveSpatial]）驱动——落点前带一点回弹，取消选中反向收拢。
/// 快速连点时弹簧带着当前速度续上，不会跳帧回零。
///
/// 外层 [SizedBox] 恒为静止几何（状态层按它裁剪，见 [_NavIndicatorInkWell]），
/// 回弹超出的几个像素画在格内边距里。墨水屏 / 减弱动态效果下瞬间到位；静止时
/// 填充色与目标色逐值相同（eink 守卫按 `decoration.color == onSurface` 断言）。
class _NavIndicatorPill extends StatefulWidget {
  const _NavIndicatorPill({
    required this.selected,
    required this.color,
    required this.height,
    required this.child,
    required this.width,
    super.key,
  });

  final bool selected;
  final Color color;
  final double width;
  final double height;
  final Widget child;

  @override
  State<_NavIndicatorPill> createState() => _NavIndicatorPillState();
}

class _NavIndicatorPillState extends State<_NavIndicatorPill>
    with SingleTickerProviderStateMixin {
  /// 回弹允许超出静止宽度的量（每侧一半，落在格的 4dp 内边距里）。
  static const double _kOvershootAllowance = 8;

  late final FushiSpring _select = FushiSpring(
    vsync: this,
    initial: widget.selected ? 1 : 0,
    spring: _kNavExpressiveSpatial,
  );

  @override
  void didUpdateWidget(covariant _NavIndicatorPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _select.animateTo(
        widget.selected ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _select.dispose();
    super.dispose();
  }

  /// 弹簧当前进度；落到目标附近直接取目标，静止几何与配色与目标逐值相同。
  double get _t {
    final double target = _select.target;
    final double raw = _select.value;
    return (raw - target).abs() < 0.001 ? target : raw;
  }

  Color _fillFor(double t) => t >= 1
      ? widget.color
      : t <= 0
      ? Colors.transparent
      : widget.color.withValues(alpha: widget.color.a * t.clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final double height = widget.height;
    final BorderRadius radius = BorderRadius.circular(height / 2);
    final double width = widget.width;
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: AnimatedBuilder(
          animation: _select.animation,
          child: widget.child,
          builder: (BuildContext context, Widget? child) {
            final double t = _t;
            final double pill = math.min(
              math.max(0.0, height + (width - height) * t),
              width + _kOvershootAllowance,
            );
            return OverflowBox(
              maxWidth: width + _kOvershootAllowance,
              maxHeight: height,
              child: Container(
                width: pill,
                height: height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _fillFor(t),
                  borderRadius: radius,
                ),
                child: child,
              ),
            );
          },
        ),
      ),
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
  VoidCallback? onToggleExtended,
}) {
  // [extended]：玻璃设计系统是图标 + 文字的悬浮侧栏 / 窄条；MD3 是 M3E 的
  // 展开 rail（220）/ 收起 rail（96）。[onToggleExtended] 非空时 MD3 rail 顶部
  // 画菜单钮切换两态（调用方负责记住，见 [adaptiveNavRailExtended]）。
  return _MaterialNavCluster(
    axis: Axis.vertical,
    currentIndex: currentIndex,
    onTap: onTap,
    items: items,
    idPrefix: 'nav-rail',
    leading: leading,
    extended: extended,
    onToggleExtended: onToggleExtended,
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
  late final FushiFocusId _focusId = FushiFocusId(
    'nav-cluster-${identityHashCode(this)}',
  );

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
            final GamepadButton prev = horizontal
                ? GamepadButton.dpadLeft
                : GamepadButton.dpadUp;
            final GamepadButton next = horizontal
                ? GamepadButton.dpadRight
                : GamepadButton.dpadDown;
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
          SingleActivator(
            horizontal
                ? LogicalKeyboardKey.arrowLeft
                : LogicalKeyboardKey.arrowUp,
          ): const _NavStepIntent(
            -1,
          ),
          SingleActivator(
            horizontal
                ? LogicalKeyboardKey.arrowRight
                : LogicalKeyboardKey.arrowDown,
          ): const _NavStepIntent(
            1,
          ),
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

  const _CupertinoAppBarWithBottom({
    required this.navBar,
    required this.bottom,
  });

  @override
  Size get preferredSize => Size.fromHeight(
    navBar.preferredSize.height + bottom.preferredSize.height,
  );

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [navBar, bottom]);
  }
}
