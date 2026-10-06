/// 漫画阅读器的界面件（chrome）：顶部浮动工具栏 [MangaReaderTopBar]、底部浮动
/// 进度工具栏 [MangaReaderBottomBar]、章末「下一章」卡片 [MangaChapterEndCard]、
/// 隐藏界面时的页码角标 [MangaHiddenPageBadge]、OCR 状态胶囊。
///
/// 2026-10 重设计（MD3 Expressive 为主，Apple 26 同步）：内容全屏，chrome 不再是
/// 贴边实色条，而是**浮在页图上的胶囊**——
///  * MD3：surfaceContainer 底、圆角 28、elevation 3（M3 Expressive floating
///    toolbar）；墨水屏换实色 surface + 描边、无阴影；
///  * Apple：恒深色档（[FushiAppleDarkTier]）的液态玻璃胶囊，白色字形、按钮无底
///    （HIG Toolbars：toolbar items don't include a bezel）。
///
/// 两种形态由页面决定、本组件只管画：
///  * 固定（`floating == false`）：胶囊所在的整条区域占布局，页面把正文 WebView
///    往下 / 往上让 [mangaChromeTopInset] / [mangaChromeBottomInset]；
///  * 悬浮（`floating == true`）：盖在正文上，默认收起，正文中央点击唤出、再点
///    一下收起（**只认点击**：指针移动不唤出，唤出后也不自动收起）。
///
/// 显隐动效走 [MangaChromeReveal]（顶部向上、底部向下 fade + slide，时长取
/// [FushiMotion]，墨水屏 / 减弱动态效果下瞬间到位）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show kReaderDesktopHeaderButtonWidth, readerHeaderCompact;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart'
    show FushiExpressiveLoadingIndicator;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 胶囊离屏幕左 / 右边的距离。窄屏的标题槽要放下页码胶囊（见
/// [planMangaTopBarActions]），所以只留 8。
const double kMangaChromeEdgeInset = 8;

/// 顶部浮动工具栏胶囊本身的高度（M3 Expressive floating toolbar 的 56 档）。
const double kMangaChromeTopPillHeight = 56;

/// 顶部胶囊上 / 下方留白。
const double kMangaChromeTopGap = 8;

/// 顶栏占位高（不含系统状态栏）= 上留白 + 胶囊 + 下留白。固定态正文让位的高度
/// 与画出的高度是**同一个常量**（EPUB 顶栏 BUG-2387 同款铁律）。
const double kMangaChromeBarHeight =
    kMangaChromeTopGap + kMangaChromeTopPillHeight + kMangaChromeTopGap;

/// 底部进度胶囊本身的高度：放得下 M3 Expressive 滑块 44 高的竖条手柄。
const double kMangaChromeBottomPillHeight = 60;

/// 底部胶囊下方留白（离系统手势区）。
const double kMangaChromeBottomGap = 12;

/// 底栏占位高（不含系统手势区）= 上留白 + 胶囊 + 下留白。
const double kMangaChromeBottomBarHeight =
    kMangaChromeTopGap + kMangaChromeBottomPillHeight + kMangaChromeBottomGap;

/// 桌面宽屏下顶部工具栏的最大宽度：再宽就居中，动作不必横跨整块屏幕。
const double kMangaChromeTopMaxWidth = 1080;

/// 底部进度胶囊的最大宽度。
const double kMangaChromeBottomMaxWidth = 760;

/// 胶囊圆角（M3 Expressive 的 extra-large 28）。
const double kMangaChromePillRadius = 28;

/// 固定态下正文 WebView 顶部让出的高度（纯函数，单测钉住）。
///
///  * 悬浮 / 界面被隐藏（M 键）→ 0：正文全出血；
///  * 固定且界面可见 → 状态栏 + 顶栏占位高。正文让位的高度**必须**等于顶栏画出的
///    高度（同一个常量），否则页图第一行会压在栏下（EPUB 顶栏 BUG-2387 同款铁律）。
double mangaChromeTopInset({
  required bool floating,
  required bool chromeVisible,
  required double statusBarInset,
}) {
  if (floating || !chromeVisible) return 0;
  return statusBarInset + kMangaChromeBarHeight;
}

/// 固定态下正文 WebView 底部让出的高度（纯函数，单测钉住）。
///
/// 与 [mangaChromeTopInset] 同构、同理由：让位高度**必须**等于底栏画出的高度
/// （同一个常量 + 同一个系统手势区 inset），否则页图最后一行会压在栏下。
///
/// [contentReady] == false 时底栏不画（没有正文就没有可跳的页），故也不让位。
double mangaChromeBottomInset({
  required bool floating,
  required bool chromeVisible,
  required bool contentReady,
  required double gestureInset,
}) {
  if (floating || !chromeVisible || !contentReady) return 0;
  return gestureInset + kMangaChromeBottomBarHeight;
}

/// 当前是否该画顶栏（纯函数）。
///
///  * 界面被用户隐藏（M 键，[chromeVisible] == false）→ 不画；
///  * 固定态 → 画；
///  * 悬浮态 → 唤出中（[transientVisible]）才画——**但没有正文时无条件画**
///    （[contentReady] == false：加载失败 / 本章未下载）。悬浮态的唤出手势是正文
///    WebView 的中央点击，没有正文就没有那条通道（顶边悬停热区已按「只认点击」
///    的口径删掉），返回键一收就再也叫不回来（iOS 没有系统返回键 +
///    `PopScope(canPop: false)` 关掉了侧滑，只能杀进程）。出口不随内容存亡，也不
///    随形态收起。
bool mangaChromeBarPainted({
  required bool floating,
  required bool chromeVisible,
  required bool transientVisible,
  required bool contentReady,
}) {
  if (!chromeVisible) return false;
  return !floating || transientVisible || !contentReady;
}

/// 漫画 chrome（工具栏 / 胶囊 / 气泡 / 角标）的配色。
///
///  * MD3：跟随 app 主题的 surfaceContainer 族（浮动工具栏本就是一块独立的
///    表面，压在任何底色的页图上都读得清）；
///  * Apple：chrome 恒压在页图上，取**深色档**系统色（[appleDarkColorsOf]），
///    不跟随 app 亮暗——浅色主题下的单色强调色是黑，画在深色玻璃上等于隐形。
@immutable
class MangaChromePalette {
  const MangaChromePalette({
    required this.foreground,
    required this.secondaryForeground,
    required this.accent,
    required this.onAccent,
    required this.warning,
    required this.container,
    required this.tonal,
    required this.onTonal,
    required this.outline,
    required this.groupDivider,
    required this.chipFill,
    required this.badgeFill,
    required this.hiddenBadgeFill,
    required this.sliderInactive,
    required this.apple,
    required this.eink,
  });

  /// 当前设计系统下的配色。
  static MangaChromePalette of(BuildContext context) {
    final bool eink = isEinkTheme(context);
    if (!isGlassDesign(context)) {
      final ColorScheme cs = Theme.of(context).colorScheme;
      return MangaChromePalette(
        foreground: cs.onSurface,
        secondaryForeground: cs.onSurfaceVariant,
        accent: cs.primary,
        onAccent: cs.onPrimary,
        // BUG-1163：推理后端降级必须看得见——MD3 用 error 角色，墨水屏同样
        // 是高对比的深色字。
        warning: cs.error,
        container: eink ? cs.surface : cs.surfaceContainer,
        tonal: eink ? cs.surface : cs.secondaryContainer,
        onTonal: eink ? cs.onSurface : cs.onSecondaryContainer,
        outline: cs.outline,
        groupDivider: cs.outlineVariant,
        chipFill: eink ? cs.surface : cs.secondaryContainer,
        badgeFill: eink ? cs.surface : cs.secondaryContainer,
        hiddenBadgeFill: eink
            ? cs.surface
            : cs.surfaceContainer.withValues(alpha: 0.88),
        sliderInactive: null,
        apple: false,
        eink: eink,
      );
    }
    // 漫画 chrome 恒压在页图上：取恒深色档色板（单色强调色在深色档取白、
    // 有彩强调色按深色档重建明度，见 [appleDarkColorsOf]）。
    final FushiAppleColors dark = appleDarkColorsOf(context);
    return MangaChromePalette(
      foreground: dark.label,
      secondaryForeground: dark.secondaryLabel,
      accent: dark.accent,
      onAccent: appleOnAccent(dark.accent),
      warning: dark.warning,
      container: const Color(0xFF1C1C1E),
      tonal: dark.fill,
      onTonal: dark.label,
      outline: dark.separator,
      groupDivider: dark.separator,
      // 工具栏里的项不带 bezel：页码 / 状态胶囊不铺 systemFill 灰底，悬停由
      // FushiPlainButton 给。
      chipFill: Colors.transparent,
      badgeFill: dark.fill,
      hiddenBadgeFill: const Color(0x991C1C1E),
      sliderInactive: dark.fill,
      apple: true,
      eink: false,
    );
  }

  final Color foreground;
  final Color secondaryForeground;

  /// 开关型动作开启态 / 当前页高亮的强调色（MD3 primary；Apple 深色档强调色）。
  final Color accent;
  final Color onAccent;

  /// 降级 / 告警读数色（BUG-1163：推理后端降级必须看得见）。
  final Color warning;

  /// 浮动胶囊的实色底（MD3 surfaceContainer；Apple 玻璃回落色）。
  final Color container;

  /// tonal 圆钮 / 状态胶囊底（MD3 secondaryContainer；Apple systemFill）。
  final Color tonal;
  final Color onTonal;

  /// 墨水屏描边。
  final Color outline;

  /// 顶栏动作组之间的竖分隔。
  final Color groupDivider;

  /// 页码胶囊的填充。
  final Color chipFill;

  /// OCR 进度浮标底。
  final Color badgeFill;

  /// 隐藏界面时页码角标底。
  final Color hiddenBadgeFill;

  /// 底栏 slider 未填段；null = 跟主题（MD3 原样）。
  final Color? sliderInactive;

  /// 是否 Apple 设计系统（决定开启态画法与胶囊是否玻璃）。
  final bool apple;

  /// 墨水屏：实色 + 描边、无阴影、无动效。
  final bool eink;
}

/// 浮在页图上的一块胶囊表面：MD3 = surfaceContainer + elevation 3（墨水屏实色 +
/// 描边、无阴影）；Apple = 深色档液态玻璃（iOS / macOS 上页图是原生平台视图，
/// 着色器采不到像素，走 BackdropFilter 回退 + 实色兜底）。
///
/// 结构恒定：表面永远画在子树**背后**的兄弟层（[Stack] + [Positioned.fill]），
/// 子树永远挂在同一个位置——切换设计系统 / 亮暗只换背景叶子，不增删父包装层
/// （否则会触发 `_elements.contains` 断言、丢掉按钮的焦点与悬停态）。
class MangaChromeSurface extends StatelessWidget {
  const MangaChromeSurface({
    super.key,
    required this.child,
    this.radius = kMangaChromePillRadius,
    this.elevated = true,
  });

  final Widget child;
  final double radius;

  /// 是否带投影（固定态的胶囊贴在让出的区域里，不必再「浮」起来）。
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget background;
    if (colors.apple) {
      final bool overPlatformView = fushiGlassOverPlatformView(context);
      background = GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context, prominent: true),
        settings: overPlatformView
            ? fushiGlassSettingsOverPlatformView(context)
            : fushiGlassSettings(context),
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        platformViewBackdrop: overPlatformView,
        child: const SizedBox.expand(),
      );
    } else {
      background = Material(
        color: colors.container,
        elevation: colors.eink || !elevated ? 0 : 3,
        shadowColor: cs.shadow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
          side: colors.eink
              ? BorderSide(color: colors.outline)
              : BorderSide.none,
        ),
        child: const SizedBox.expand(),
      );
    }
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

/// chrome 的显隐动效：显示时 fade + slide 进场（[fromTop] 自上而下 / 否则自下而
/// 上），隐藏时反向退场，退场播完才卸载子树。
///
/// 时长取 [FushiMotion]（进场 [FushiMotion.medium]、退场 [FushiMotion.short]，
/// 快进慢出），墨水屏与系统「减弱动态效果」下经 [fushiMotionDuration] 归零，
/// 瞬间到位。退场途中子树 [IgnorePointer] + [ExcludeFocus]：正在消失的按钮
/// 不该再被点到或 Tab 到。首次挂载即可见时不播进场（打开书时栏已在位）。
class MangaChromeReveal extends StatefulWidget {
  const MangaChromeReveal({
    super.key,
    required this.visible,
    required this.child,
    this.fromTop = true,
  });

  final bool visible;
  final bool fromTop;
  final Widget child;

  @override
  State<MangaChromeReveal> createState() => _MangaChromeRevealState();
}

class _MangaChromeRevealState extends State<MangaChromeReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: FushiMotion.enter,
    reverseCurve: FushiMotion.exit.flipped,
  );

  /// 退场 / 进场时的位移（逻辑像素）。
  static const double _travel = 24;

  @override
  void didUpdateWidget(MangaChromeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    final Duration duration = fushiMotionDuration(
      context,
      widget.visible ? FushiMotion.medium : FushiMotion.short,
    );
    if (duration == Duration.zero) {
      _controller.value = widget.visible ? 1 : 0;
      return;
    }
    _controller.duration = duration;
    _controller.reverseDuration = duration;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        if (!widget.visible && _controller.isDismissed) {
          return const SizedBox.shrink();
        }
        final double t = _curve.value;
        final double direction = widget.fromTop ? -1 : 1;
        return IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeFocus(
            excluding: !widget.visible,
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, (1 - t) * _travel * direction),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 顶栏里的一颗动作。[active] 是「开关型」动作的当前态（高亮 + 溢出菜单打勾）。
class MangaChromeAction {
  const MangaChromeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.key,
    this.pinned = false,
    this.secondary = false,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? key;

  /// 窄窗紧凑形态仍保留为图标按钮；其余收进 ⋮。
  final bool pinned;

  /// pinned 里的**次要**动作（翻页方向 / 回到开头）：紧凑形态下栏宽连页码胶囊
  /// 都放不下时，先把它们（从后往前）降进 ⋮，而不是让按钮压在胶囊上
  /// （BUG：412dp 竖屏手机 7 颗 pinned 按钮把胶囊挤到只剩 ~68dp）。见
  /// [planMangaTopBarActions]。
  final bool secondary;

  /// 开关型动作当前处于开启态：图标用强调色，溢出菜单里带勾。
  final bool active;

  /// 忙碌中：图标位画转圈（例如整卷 OCR 进行中）。
  final bool busy;
}

/// 顶栏一行两端内边距合计：0——首尾 48 的图标按钮直接落在 56 高胶囊的半圆端里
/// （可见圆 40 与胶囊端几乎同心）。412dp 竖屏手机上返回 + 章节 + 取消 OCR +
/// 设置 + 隐藏 + ⋮ 之后页码胶囊恰好放得下，每一像素都要留给它。
const double kMangaTopBarHorizontalPadding = 0;

/// 组间分隔线占宽：左右各 2 + 线宽 1（与 `_divider` 同源）。
const double kMangaTopBarDividerWidth = 5;

/// 页码胶囊左右内边距（单侧，与胶囊 `Padding` 同源）。
const double kMangaPageChipHorizontalPadding = 10;

/// 标题两行至少要这么宽才画（窄屏上挤出两三个字加省略号不如不画）。
const double kMangaTopBarTitleMinWidth = 88;

/// [planMangaTopBarActions] 的结果：哪些动作画成图标、哪些进 ⋮。
@immutable
class MangaTopBarActionPlan {
  const MangaTopBarActionPlan({
    required this.compact,
    required this.inline,
    required this.overflow,
    required this.titleAreaWidth,
  });

  /// 紧凑形态：组间不画分隔线。
  final bool compact;

  /// 画成图标按钮的动作（按引用比较）。
  final Set<MangaChromeAction> inline;

  /// 收进 ⋮ 的动作，保持组序。
  final List<MangaChromeAction> overflow;

  /// 按钮全部排完后留给标题槽（标题 + 页码胶囊 + 状态件）的宽度，下限 0。
  final double titleAreaWidth;
}

/// 顶栏按**真实宽度**排布动作（纯函数，单测钉住）。
///
/// 固定阈值 [readerHeaderCompact]（760）只决定「要不要折叠」，从不检查折叠后
/// 留下的 pinned 按钮真的放得下：412dp 竖屏手机上返回 + 章节 + 方向 + 回到开头 +
/// 设置 + 隐藏 + ⋮ 一共 7 颗 48dp 按钮，标题槽只剩 ~68dp，页码胶囊（加大字号后
/// 更宽）画出槽外、被下一颗按钮盖住。现在：
///
///  1. 宽窗（未过 760 阈值）且全部按钮 + 胶囊放得下 → 全部画出；
///  2. 否则紧凑：只留 pinned，其余进 ⋮；
///  3. 紧凑态仍放不下 [titleAreaMinWidth]（页码胶囊的实测宽）时，把 pinned 里的
///     [MangaChromeAction.secondary] 从后往前逐个降进 ⋮，直到放得下或没有可降的。
///
/// [buttonWidth] 取 48（MD3 IconButton 补足 tap target 后的上界），宁可算宽。
MangaTopBarActionPlan planMangaTopBarActions({
  required double width,
  required int leadingCount,
  required List<List<MangaChromeAction>> groups,
  required double titleAreaMinWidth,
  double buttonWidth = kReaderDesktopHeaderButtonWidth,
}) {
  final List<List<MangaChromeAction>> visible = <List<MangaChromeAction>>[
    for (final List<MangaChromeAction> g in groups)
      if (g.isNotEmpty) g,
  ];
  final List<MangaChromeAction> all = <MangaChromeAction>[
    for (final List<MangaChromeAction> g in visible) ...g,
  ];
  // 返回键 + leading（章节目录）恒在。
  final double fixed =
      kMangaTopBarHorizontalPadding + (1 + leadingCount) * buttonWidth;

  final double wideUsed =
      fixed +
      all.length * buttonWidth +
      (visible.isEmpty ? 0 : (visible.length - 1) * kMangaTopBarDividerWidth);
  if (!readerHeaderCompact(width) && wideUsed + titleAreaMinWidth <= width) {
    return MangaTopBarActionPlan(
      compact: false,
      inline: Set<MangaChromeAction>.identity()..addAll(all),
      overflow: const <MangaChromeAction>[],
      titleAreaWidth: width - wideUsed,
    );
  }

  final List<MangaChromeAction> inline = <MangaChromeAction>[
    for (final MangaChromeAction a in all)
      if (a.pinned) a,
  ];
  double used() {
    final bool hasOverflow = inline.length < all.length;
    return fixed + (inline.length + (hasOverflow ? 1 : 0)) * buttonWidth;
  }

  while (used() + titleAreaMinWidth > width) {
    final int demote = inline.lastIndexWhere(
      (MangaChromeAction a) => a.secondary,
    );
    if (demote < 0) break;
    inline.removeAt(demote);
  }
  final Set<MangaChromeAction> inlineSet = Set<MangaChromeAction>.identity()
    ..addAll(inline);
  final double usedWidth = used();
  return MangaTopBarActionPlan(
    compact: true,
    inline: inlineSet,
    overflow: <MangaChromeAction>[
      for (final MangaChromeAction a in all)
        if (!inlineSet.contains(a)) a,
    ],
    titleAreaWidth: width > usedWidth ? width - usedWidth : 0,
  );
}

/// 顶部浮动工具栏：
/// `( ← 返回  章节  标题 / 副标题  [页码] ……… 组1 │ 组2  ⋮ )`。
///
/// 一枚胶囊（[MangaChromeSurface]），左右留 [kMangaChromeEdgeInset]，桌面宽屏
/// 限宽 [kMangaChromeTopMaxWidth] 居中。标题两行：主标题（章节名 / 卷名）+
/// 副标题（作品名）；窄屏放不下时只留页码胶囊。
class MangaReaderTopBar extends StatelessWidget {
  const MangaReaderTopBar({
    super.key,
    required this.title,
    required this.onBack,
    required this.backTooltip,
    required this.groups,
    required this.floating,
    this.subtitle,
    this.pageLabel,
    this.pageListenable,
    this.onPageTap,
    this.status,
    this.leading = const <MangaChromeAction>[],
  });

  /// 主标题（章节名 / 卷名）；空串时只画页码。
  final String title;

  /// 副标题（作品名）；null / 空串不画第二行。
  final String? subtitle;
  final VoidCallback onBack;
  final String backTooltip;

  /// 紧跟返回键的动作（章节目录）：窄窗也常驻，不折进 ⋮。
  final List<MangaChromeAction> leading;

  /// 动作分组（按顺序从左到右），组与组之间画分隔线。空组自动跳过。
  final List<List<MangaChromeAction>> groups;

  /// 悬浮态：胶囊带投影；固定态：胶囊贴在让出的区域里、不带投影。
  final bool floating;

  /// 页码胶囊文案（如 `3-4 / 40`），每次 [pageListenable] 触发时重新取；返回
  /// null 不画。只重建本栏、不重建整页——翻页是高频事件，页面本体带着原生
  /// WebView，不该跟着 setState。
  final String? Function()? pageLabel;
  final Listenable? pageListenable;
  final VoidCallback? onPageTap;

  /// 页码胶囊右侧的状态件（分镜状态胶囊 / debug 命中信息）。
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final double statusBar = MediaQuery.paddingOf(context).top;
    final List<List<MangaChromeAction>> visibleGroups =
        <List<MangaChromeAction>>[
          for (final List<MangaChromeAction> g in groups)
            if (g.isNotEmpty) g,
        ];
    return FushiAppleDarkTier(
      child: Builder(
        builder: (BuildContext context) {
          final MangaChromePalette colors = MangaChromePalette.of(context);
          return Padding(
            padding: EdgeInsets.only(top: statusBar),
            child: SizedBox(
              height: kMangaChromeBarHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  kMangaChromeEdgeInset,
                  kMangaChromeTopGap,
                  kMangaChromeEdgeInset,
                  kMangaChromeTopGap,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: kMangaChromeTopMaxWidth,
                    ),
                    child: MangaChromeSurface(
                      elevated: floating,
                      // 胶囊文案随翻页变，排布（降不降次要按钮）要跟着胶囊实测宽
                      // 走，所以整栏随 [pageListenable] 重建——只是这一条栏，页面
                      // 本体（原生 WebView）照旧不跟着 setState。
                      child: ListenableBuilder(
                        listenable:
                            pageListenable ??
                            Listenable.merge(const <Listenable>[]),
                        builder: (BuildContext context, Widget? _) {
                          final String? label = pageLabel?.call();
                          return LayoutBuilder(
                            builder:
                                (
                                  BuildContext context,
                                  BoxConstraints constraints,
                                ) {
                                  final double chipWidth = label == null
                                      ? 0
                                      : _pageChipWidth(context, colors, label);
                                  final MangaTopBarActionPlan plan =
                                      planMangaTopBarActions(
                                        width: constraints.maxWidth,
                                        leadingCount: leading.length,
                                        groups: visibleGroups,
                                        titleAreaMinWidth: chipWidth,
                                      );
                                  return _buildRow(
                                    context,
                                    colors,
                                    plan: plan,
                                    label: label,
                                    chipWidth: chipWidth,
                                    visibleGroups: visibleGroups,
                                  );
                                },
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    MangaChromePalette colors, {
    required MangaTopBarActionPlan plan,
    required String? label,
    required double chipWidth,
    required List<List<MangaChromeAction>> visibleGroups,
  }) {
    final bool compact = plan.compact;
    return SizedBox(
      height: kMangaChromeTopPillHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kMangaTopBarHorizontalPadding / 2,
        ),
        child: Row(
          children: <Widget>[
            FushiIconButtonControl(
              key: const ValueKey<String>('manga_reader_back_button'),
              tooltip: backTooltip,
              color: colors.foreground,
              iconSize: 22,
              icon: const FushiIcon(Icons.arrow_back),
              onPressed: onBack,
            ),
            for (final MangaChromeAction a in leading) _button(a, colors),
            Expanded(
              child: _buildTitleArea(
                context,
                colors,
                showTitle:
                    title.isNotEmpty &&
                    (!compact ||
                        plan.titleAreaWidth - chipWidth >=
                            kMangaTopBarTitleMinWidth),
                label: label,
                maxChipWidth: plan.titleAreaWidth,
              ),
            ),
            for (int i = 0; i < visibleGroups.length; i++) ...<Widget>[
              if (i > 0 && !compact) _divider(colors),
              for (final MangaChromeAction a in visibleGroups[i])
                if (plan.inline.contains(a)) _button(a, colors),
            ],
            if (plan.overflow.isNotEmpty)
              _overflowMenu(context, colors, plan.overflow),
          ],
        ),
      ),
    );
  }

  TextStyle? _pageChipStyle(BuildContext context, MangaChromePalette colors) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(
        color: colors.apple ? colors.foreground : colors.onTonal,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );

  /// 页码胶囊按当前字号缩放（[MediaQuery.textScalerOf]）的实测宽。
  double _pageChipWidth(
    BuildContext context,
    MangaChromePalette colors,
    String label,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(
          context,
        ).style.merge(_pageChipStyle(context, colors)),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final double width = painter.width.ceilToDouble();
    painter.dispose();
    return width + 2 * kMangaPageChipHorizontalPadding;
  }

  Widget _buildTitleArea(
    BuildContext context,
    MangaChromePalette colors, {
    required bool showTitle,
    required String? label,
    required double maxChipWidth,
  }) {
    final TextTheme text = Theme.of(context).textTheme;
    final String? sub = subtitle;
    return Row(
      children: <Widget>[
        if (showTitle)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 6, right: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    key: const ValueKey<String>('manga_reader_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(
                      color: colors.foreground,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  if (sub != null && sub.isNotEmpty)
                    Text(
                      sub,
                      key: const ValueKey<String>('manga_reader_subtitle'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: colors.secondaryForeground,
                        height: 1.25,
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (label != null)
          // 胶囊取自然宽，但绝不超出标题槽：极端字号下连次要按钮都降完仍放不下
          // 时，文字省略而不是画出槽外被按钮盖住。
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxChipWidth),
            child: colors.apple
                // Apple：工具栏项不带 bezel——纯文字胶囊，按下变淡，无水波。
                ? FushiPlainButton(
                    key: const ValueKey<String>('manga_page_jump_button'),
                    onPressed: onPageTap,
                    borderRadius: const BorderRadius.all(Radius.circular(999)),
                    child: _pageChipLabel(context, colors, label),
                  )
                // MD3：tonal 全圆角胶囊（secondaryContainer），点开跳页。
                : Material(
                    color: colors.chipFill,
                    shape: StadiumBorder(
                      side: colors.eink
                          ? BorderSide(color: colors.outline)
                          : BorderSide.none,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const ValueKey<String>('manga_page_jump_button'),
                      onTap: onPageTap,
                      child: _pageChipLabel(context, colors, label),
                    ),
                  ),
          ),
        if (status != null) ...<Widget>[
          const SizedBox(width: 8),
          Flexible(child: status!),
        ],
      ],
    );
  }

  Widget _pageChipLabel(
    BuildContext context,
    MangaChromePalette colors,
    String label,
  ) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: kMangaPageChipHorizontalPadding,
      vertical: 6,
    ),
    child: Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: _pageChipStyle(context, colors),
    ),
  );

  Widget _divider(MangaChromePalette colors) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: SizedBox(
      width: 1,
      height: 24,
      child: ColoredBox(color: colors.groupDivider),
    ),
  );

  Widget _button(MangaChromeAction a, MangaChromePalette colors) {
    // 开启态：MD3 = M3 Expressive 选中的图标按钮（secondaryContainer tonal 底）；
    // Apple = iOS 26 工具栏里「开着的」开关钮——强调色实心圆 + 反色字形。
    final bool selected = a.active && !a.busy;
    final Color selectedFill = colors.apple ? colors.accent : colors.tonal;
    final Color selectedGlyph = colors.apple ? colors.onAccent : colors.onTonal;
    final Widget icon = a.busy
        ? SizedBox.square(
            dimension: 22,
            child: FushiExpressiveLoadingIndicator(
              size: 22,
              color: colors.foreground,
            ),
          )
        : FushiIcon(
            a.icon,
            color: selected ? selectedGlyph : colors.foreground,
          );
    return FushiIconButtonControl(
      key: a.key,
      tooltip: a.label,
      iconSize: 22,
      icon: icon,
      isSelected: selected ? true : null,
      style: selected
          ? ButtonStyle(
              backgroundColor: WidgetStatePropertyAll<Color>(selectedFill),
              foregroundColor: WidgetStatePropertyAll<Color>(selectedGlyph),
            )
          : null,
      onPressed: a.onPressed,
    );
  }

  Widget _overflowMenu(
    BuildContext context,
    MangaChromePalette colors,
    List<MangaChromeAction> overflow,
  ) {
    return FushiPopupMenuButton<MangaChromeAction>(
      key: const ValueKey<String>('manga_chrome_overflow'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: FushiIcon(Icons.more_vert, color: colors.foreground),
      iconSize: 22,
      onSelected: (MangaChromeAction a) => a.onPressed?.call(),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<MangaChromeAction>>[
            for (final MangaChromeAction a in overflow)
              PopupMenuItem<MangaChromeAction>(
                value: a,
                enabled: a.onPressed != null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(a.icon, size: 20),
                    const SizedBox(width: 12),
                    Flexible(child: Text(a.label)),
                    if (a.active) ...<Widget>[
                      const SizedBox(width: 12),
                      const FushiIcon(Icons.check, size: 18),
                    ],
                  ],
                ),
              ),
          ],
    );
  }
}

/// 顶栏标题旁的小状态胶囊（分镜导航状态 / debug 命中信息）。MD3 = tonal 全圆角
/// 胶囊；Apple = systemFill 淡底。[warning] 时用告警色（BUG-1163：降级必须看得见）。
class MangaChromeStatusChip extends StatelessWidget {
  const MangaChromeStatusChip({
    super.key,
    required this.text,
    this.warning = false,
  });

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final MangaChromePalette colors = MangaChromePalette.of(context);
    final Color fg = warning
        ? colors.warning
        : (colors.apple ? colors.secondaryForeground : colors.onTonal);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: ShapeDecoration(
        color: warning ? fg.withValues(alpha: 0.16) : colors.tonal,
        shape: StadiumBorder(
          side: colors.eink ? BorderSide(color: fg) : BorderSide.none,
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 整卷 OCR 状态胶囊（`OCR 19/182 · DirectML`），挂在页面右上角、顶栏下沿。
///
/// 不放进顶栏：悬浮顶栏默认收起、用户也会隐藏界面，进度却要一直看得见（对齐
/// Mangatan / Chimahon）。MD3 = secondaryContainer tonal 胶囊 + Expressive 加载
/// 指示（形变多边形）+ 有总数时底部一条波浪进度；Apple = 深色档玻璃胶囊。
/// [warning] 用告警色（加速降级 / 没有可用引擎，BUG-1163：降级必须看得见）。
/// 浮标只是读数，不吃指针事件。
class MangaOcrProgressBadge extends StatelessWidget {
  const MangaOcrProgressBadge({
    super.key,
    required this.text,
    this.busy = true,
    this.warning = false,
    this.progress,
  });

  final String text;
  final bool busy;
  final bool warning;

  /// 0..1 的整卷进度；null = 不画进度条（排队中 / 不知道总数）。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FushiAppleDarkTier(
        child: Builder(
          builder: (BuildContext context) {
            final MangaChromePalette colors = MangaChromePalette.of(context);
            final Color fg = warning
                ? colors.warning
                : (colors.apple ? colors.foreground : colors.onTonal);
            final double? value = progress;
            final Widget content = Padding(
              padding: EdgeInsets.fromLTRB(
                busy ? 6 : 14,
                6,
                14,
                value == null ? 6 : 8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (busy) ...<Widget>[
                        FushiExpressiveLoadingIndicator(size: 24, color: fg),
                        const SizedBox(width: 4),
                      ],
                      // 警告（没有可用引擎）要把原因和解决办法说全，窄屏上折成
                      // 两行；进度读数恒一行。Flexible 让 maxLines / 省略号在
                      // 有界宽度里真正生效。
                      Flexible(
                        child: Text(
                          text,
                          maxLines: warning ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: fg,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                      ),
                    ],
                  ),
                  if (value != null) ...<Widget>[
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 120),
                      child: FushiLinearProgressIndicator(
                        value: value.clamp(0.0, 1.0),
                        color: fg,
                        backgroundColor: fg.withValues(alpha: 0.22),
                      ),
                    ),
                  ],
                ],
              ),
            );
            // IntrinsicWidth：胶囊宽随读数走，进度条（stretch）跟读数一样宽，
            // 而不是在 Align 的宽松约束里撑满 360。
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: IntrinsicWidth(
                child: colors.apple
                    ? MangaChromeSurface(radius: 20, child: content)
                    : DecoratedBox(
                        decoration: ShapeDecoration(
                          color: warning
                              ? Color.alphaBlend(
                                  colors.warning.withValues(alpha: 0.14),
                                  colors.container,
                                )
                              : colors.badgeFill,
                          shape: RoundedRectangleBorder(
                            borderRadius: const BorderRadius.all(
                              Radius.circular(20),
                            ),
                            side: colors.eink || warning
                                ? BorderSide(
                                    color: warning
                                        ? colors.warning
                                        : colors.outline,
                                  )
                                : BorderSide.none,
                          ),
                          shadows: colors.eink
                              ? const <BoxShadow>[]
                              : kElevationToShadow[2],
                        ),
                        child: content,
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// slider 的物理左端对应第几页（纯函数，单测钉住）。
///
/// RTL（日漫右开本）下页序在视觉上从右往左推进，slider 必须跟着镜像，否则「把滑块
/// 往前推」会倒着翻页。镜像只发生在**显示**层：[MangaReaderBottomBar] 收到的和回调
/// 出去的永远是 0-based 真实页号。
///
/// 返回值是给 [Slider] 用的 0..max 位置值。
double mangaSliderPosition({
  required int pageIndex,
  required int pageCount,
  required bool rtl,
}) {
  if (pageCount <= 1) return 0;
  final int clamped = pageIndex.clamp(0, pageCount - 1);
  return (rtl ? pageCount - 1 - clamped : clamped).toDouble();
}

/// [mangaSliderPosition] 的逆：slider 位置 → 0-based 真实页号。
int mangaSliderPageIndex({
  required double position,
  required int pageCount,
  required bool rtl,
}) {
  if (pageCount <= 1) return 0;
  final int slot = position.round().clamp(0, pageCount - 1);
  return rtl ? pageCount - 1 - slot : slot;
}

/// 底部浮动进度工具栏：`( ⏮  3  ━━━━━┃──────  40  ⏭ )`，拖动跳页。
///
/// 此前跳页的唯一入口是顶栏页码胶囊弹出的输入框——要跳到「大概三分之二处」必须先
/// 知道总页数再心算页号。slider 是漫画阅读器的标配（Mihon / Tachiyomi / Kindle 都
/// 有），缺它是用户「本体比 Mihon 薄」的具体一条。
///
/// MD3：M3 Expressive 滑块（16 粗轨道 + 4×44 竖条手柄、无刻度点）；两端是 tonal
/// 圆钮的上一章 / 下一章（[onPreviousChapter] / [onNextChapter] 为 null 时不画——
/// 本地卷没有「章」）。RTL 下两颗按钮随 slider 一起镜像：左钮恒指向物理左端。
/// 拖动中在手柄上方画一枚数值气泡（`页 / 总页`），有 [pagePreview] 时气泡里带
/// 那一页的缩略图。
///
/// 拖动中只更新本地预览，**松手才真跳页**（[onPageCommitted]）：漫画翻页要
/// loadData 重建窗口文档，按住滑块扫过 40 页会连发 40 次重建。
class MangaReaderBottomBar extends StatefulWidget {
  const MangaReaderBottomBar({
    super.key,
    required this.pageCount,
    required this.pageListenable,
    required this.currentPage,
    required this.rtl,
    required this.onPageCommitted,
    this.floating = true,
    this.onPreviousChapter,
    this.onNextChapter,
    this.previousChapterTooltip,
    this.nextChapterTooltip,
    this.pagePreview,
  });

  /// 整卷总页数；<= 1 时整条栏不画（一页的书没有跳页需求）。
  final int pageCount;

  /// 翻页通知源：只重画本栏，不重建整页（正文是原生 WebView）。
  final Listenable pageListenable;

  /// 当前 0-based 页号，每次 [pageListenable] 触发时重新取。
  final int Function() currentPage;

  /// 右开本：slider 镜像（见 [mangaSliderPosition]）。
  final bool rtl;

  /// 松手时回调，参数是 0-based 真实页号。
  final ValueChanged<int> onPageCommitted;

  /// 与顶栏同义：悬浮态胶囊带投影、固定态不带。
  final bool floating;

  /// 上一章 / 下一章（阅读顺序）；null = 不画对应按钮。
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final String? previousChapterTooltip;
  final String? nextChapterTooltip;

  /// 拖动气泡里的缩略图（0-based 页号）；返回 null 只画页码。
  final ImageProvider? Function(int pageIndex)? pagePreview;

  @override
  State<MangaReaderBottomBar> createState() => _MangaReaderBottomBarState();
}

class _MangaReaderBottomBarState extends State<MangaReaderBottomBar> {
  /// 拖动中的 slider 位置；null = 没在拖，读 [MangaReaderBottomBar.currentPage]。
  double? _dragPosition;

  /// slider 轨道两端的内缩（与 [FushiSlider.padding] 同源），气泡按它换算 x。
  static const double _sliderInset = 12;

  @override
  Widget build(BuildContext context) {
    if (widget.pageCount <= 1) return const SizedBox.shrink();
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return FushiAppleDarkTier(
      child: Builder(
        builder: (BuildContext context) {
          final MangaChromePalette colors = MangaChromePalette.of(context);
          return Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: SizedBox(
              height: kMangaChromeBottomBarHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  kMangaChromeEdgeInset,
                  kMangaChromeTopGap,
                  kMangaChromeEdgeInset,
                  kMangaChromeBottomGap,
                ),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: kMangaChromeBottomMaxWidth,
                    ),
                    child: MangaChromeSurface(
                      elevated: widget.floating,
                      child: SizedBox(
                        height: kMangaChromeBottomPillHeight,
                        child: ListenableBuilder(
                          listenable: widget.pageListenable,
                          builder: (BuildContext context, Widget? _) =>
                              _buildRow(context, colors),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRow(BuildContext context, MangaChromePalette colors) {
    final TextTheme text = Theme.of(context).textTheme;
    final int pageCount = widget.pageCount;
    final double maxPosition = (pageCount - 1).toDouble();
    final double position =
        _dragPosition ??
        mangaSliderPosition(
          pageIndex: widget.currentPage(),
          pageCount: pageCount,
          rtl: widget.rtl,
        );
    final int shownPage =
        mangaSliderPageIndex(
          position: position,
          pageCount: pageCount,
          rtl: widget.rtl,
        ) +
        1;
    final TextStyle? readout = text.labelLarge?.copyWith(
      color: colors.foreground,
      fontWeight: FontWeight.w600,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    // 物理左钮 / 右钮：LTR 左 = 上一章；RTL 页序从右往左推进，左 = 下一章。
    final VoidCallback? leftAction = widget.rtl
        ? widget.onNextChapter
        : widget.onPreviousChapter;
    final VoidCallback? rightAction = widget.rtl
        ? widget.onPreviousChapter
        : widget.onNextChapter;
    final String? leftTooltip = widget.rtl
        ? widget.nextChapterTooltip
        : widget.previousChapterTooltip;
    final String? rightTooltip = widget.rtl
        ? widget.previousChapterTooltip
        : widget.nextChapterTooltip;
    return Row(
      children: <Widget>[
        if (leftAction != null)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: _chapterButton(
              colors,
              key: const ValueKey<String>('manga_reader_chapter_left_button'),
              icon: Icons.skip_previous_rounded,
              tooltip: leftTooltip,
              onPressed: leftAction,
            ),
          )
        else
          const SizedBox(width: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 28),
          child: Text(
            '$shownPage',
            key: const ValueKey<String>('manga_slider_current_page'),
            textAlign: TextAlign.center,
            style: readout,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: <Widget>[
                  _slider(context, colors, position, maxPosition),
                  if (_dragPosition != null)
                    _bubble(
                      context,
                      colors,
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      fraction: maxPosition <= 0
                          ? 0
                          : (position / maxPosition).clamp(0.0, 1.0),
                      pageIndex: shownPage - 1,
                    ),
                ],
              );
            },
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 28),
          child: Text(
            '$pageCount',
            key: const ValueKey<String>('manga_slider_page_count'),
            textAlign: TextAlign.center,
            style: readout?.copyWith(
              color: colors.secondaryForeground,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (rightAction != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _chapterButton(
              colors,
              key: const ValueKey<String>('manga_reader_chapter_right_button'),
              icon: Icons.skip_next_rounded,
              tooltip: rightTooltip,
              onPressed: rightAction,
            ),
          )
        else
          const SizedBox(width: 10),
      ],
    );
  }

  Widget _slider(
    BuildContext context,
    MangaChromePalette colors,
    double position,
    double maxPosition,
  ) {
    final Widget slider = FushiSlider(
      key: const ValueKey<String>('manga_page_slider'),
      value: position.clamp(0, maxPosition),
      max: maxPosition,
      // Apple 滑块默认取主题强调色，压在深色玻璃上换成深色档的强调色 / 填充色；
      // MD3 跟主题（primary / secondaryContainer）。
      activeColor: colors.apple ? colors.accent : null,
      inactiveColor: colors.sliderInactive,
      // M3 Expressive（2024）滑块：粗轨道 + 竖条手柄。
      year2023: false,
      padding: const EdgeInsets.symmetric(horizontal: _sliderInset),
      // 每一格恰好一页：divisions 缺省时滑块落在页与页之间、拖动读数会跳，
      // 方向键单步也会退化成量程的 5%/10%（200 页一按跳 20 页）。Apple 滑块
      // 两端都要分格——它的刻度点在格距不足 8px 时自己不画，长卷不会糊成一串。
      // 0 / 1 页没有可跳的格（整条栏本就不画），保持 null。
      divisions: widget.pageCount <= 1 ? null : widget.pageCount - 1,
      onChanged: (double v) => setState(() => _dragPosition = v),
      onChangeEnd: (double v) {
        setState(() => _dragPosition = null);
        widget.onPageCommitted(
          mangaSliderPageIndex(
            position: v,
            pageCount: widget.pageCount,
            rtl: widget.rtl,
          ),
        );
      },
    );
    if (colors.apple) return slider;
    // 一页一格的离散滑块在 40 页上会画出 40 颗刻度点：数值气泡由本栏自己画，
    // 刻度点与系统气泡都关掉。
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
        trackHeight: 16,
      ),
      child: slider,
    );
  }

  Widget _chapterButton(
    MangaChromePalette colors, {
    required Key key,
    required IconData icon,
    required String? tooltip,
    required VoidCallback onPressed,
  }) {
    final Widget glyph = FushiIcon(icon, size: 24);
    if (colors.apple) {
      // 玻璃胶囊里的按钮不带底（玻璃叠玻璃会出两圈折射边）。
      return FushiIconButtonControl(
        key: key,
        tooltip: tooltip,
        color: colors.foreground,
        icon: glyph,
        onPressed: onPressed,
      );
    }
    // MD3：tonal 圆钮（M3 Expressive filled tonal icon button，按压形变）。
    return FushiIconButtonControl.filledTonal(
      key: key,
      tooltip: tooltip,
      icon: glyph,
      onPressed: onPressed,
    );
  }

  /// 拖动中的数值气泡：手柄正上方，`页 / 总页` + 可选缩略图。纯读数、不吃指针。
  Widget _bubble(
    BuildContext context,
    MangaChromePalette colors, {
    required double width,
    required double height,
    required double fraction,
    required int pageIndex,
  }) {
    final ImageProvider? preview = widget.pagePreview?.call(pageIndex);
    const double bubbleWidth = 104;
    final double usable = math.max(0, width - 2 * _sliderInset);
    final double centerX = _sliderInset + usable * fraction;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fill = colors.apple
        ? const Color(0xF21C1C1E)
        : (colors.eink ? cs.surface : cs.inverseSurface);
    final Color fg = colors.apple
        ? colors.foreground
        : (colors.eink ? cs.onSurface : cs.onInverseSurface);
    return Positioned(
      left: centerX - bubbleWidth / 2,
      bottom: height + 14,
      width: bubbleWidth,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey<String>('manga_slider_bubble'),
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedRectangleBorder(
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              side: colors.eink
                  ? BorderSide(color: colors.outline)
                  : BorderSide.none,
            ),
            shadows: colors.eink ? const <BoxShadow>[] : kElevationToShadow[3],
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (preview != null) ...<Widget>[
                  AspectRatio(
                    aspectRatio: 0.7,
                    child: ShelfCoverFrame(
                      child: Image(
                        image: preview,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder:
                            (
                              BuildContext context,
                              Object error,
                              StackTrace? stack,
                            ) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  '${pageIndex + 1} / ${widget.pageCount}',
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 章末「下一章」卡片：读到本章最后一页时浮在底栏上方——封面 + 「下一章」+
/// 章节名 + 继续按钮（MD3 Expressive 按压形变的实心按钮；Apple 玻璃强调色胶囊）。
///
/// 只负责画；点「继续」走页面现成的换章执行体（与翻过最后一页同一条路：先记已读
/// 再换章），本组件不碰任何阅读逻辑。
class MangaChapterEndCard extends StatelessWidget {
  const MangaChapterEndCard({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.actionLabel,
    required this.onContinue,
    this.cover,
  });

  /// 小标题（「下一章」）。
  final String eyebrow;

  /// 下一章的章节名。
  final String title;

  /// 继续按钮文案。
  final String actionLabel;
  final VoidCallback? onContinue;

  /// 作品封面（本地文件）；null 画占位图标。
  final ImageProvider? cover;

  @override
  Widget build(BuildContext context) {
    return FushiAppleDarkTier(
      child: Builder(
        builder: (BuildContext context) {
          final MangaChromePalette colors = MangaChromePalette.of(context);
          final TextTheme text = Theme.of(context).textTheme;
          final ImageProvider? image = cover;
          return MangaChromeSurface(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 52,
                    height: 74,
                    child: ShelfCoverFrame(
                      child: image == null
                          ? Center(
                              child: FushiIcon(
                                Icons.auto_stories_outlined,
                                color: colors.secondaryForeground,
                              ),
                            )
                          : Image(
                              image: image,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder:
                                  (
                                    BuildContext context,
                                    Object error,
                                    StackTrace? stack,
                                  ) => Center(
                                    child: FushiIcon(
                                      Icons.auto_stories_outlined,
                                      color: colors.secondaryForeground,
                                    ),
                                  ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          eyebrow,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelMedium?.copyWith(
                            color: colors.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(
                            color: colors.foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FushiFilledButton.icon(
                    key: const ValueKey<String>(
                      'manga_chapter_end_continue_button',
                    ),
                    onPressed: onContinue,
                    icon: const FushiIcon(Icons.arrow_forward_rounded),
                    label: Text(actionLabel),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 隐藏界面（M 键）时角落里常驻的页码角标。
///
/// 隐藏界面是为了让页图全出血，但代价是**连自己读到第几页都看不见**了——用户只能
/// 把界面调出来看一眼再关掉。角标半透明、不吃指针（[IgnorePointer]），不破坏全出血。
class MangaHiddenPageBadge extends StatelessWidget {
  const MangaHiddenPageBadge({
    super.key,
    required this.pageListenable,
    required this.label,
  });

  final Listenable pageListenable;

  /// 页码文案（如 `3 / 40`）；返回 null 不画。
  final String? Function() label;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: pageListenable,
        builder: (BuildContext context, Widget? _) {
          final String? shown = label();
          if (shown == null) return const SizedBox.shrink();
          final MangaChromePalette colors = MangaChromePalette.of(context);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: ShapeDecoration(
              color: colors.hiddenBadgeFill,
              shape: StadiumBorder(
                side: colors.eink
                    ? BorderSide(color: colors.outline)
                    : BorderSide.none,
              ),
            ),
            child: Text(
              shown,
              key: const ValueKey<String>('manga_hidden_page_badge'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.apple
                    ? colors.secondaryForeground
                    : colors.foreground,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          );
        },
      ),
    );
  }
}
