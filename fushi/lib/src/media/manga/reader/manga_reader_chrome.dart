/// 漫画阅读器的界面件（chrome）：顶部悬浮条 [MangaReaderTopBar]、底部页码滑块胶囊
/// [MangaReaderBottomBar] + 悬浮工具栏 [MangaReaderToolbar]（两者由
/// [MangaReaderBottomChrome] 摆位）、章末「下一章」卡片 [MangaChapterEndCard]、
/// 隐藏界面时的页码角标 [MangaHiddenPageBadge]、OCR 状态胶囊。
///
/// 2026-10 二次重设计：与小说阅读器统一成 **M3 Expressive 悬浮工具栏**（共享组件
/// `fushi_floating_toolbar.dart`）。内容全屏，chrome 是一组分离的悬浮胶囊而不是
/// 整条实体栏——
///  * 顶部：`(←)  (标题 · 状态)  ………  (动作 · ⋯)`，三块各自成胶囊；
///  * 底部：页码滑块胶囊叠在「按钮组胶囊 + FAB」上方（Mihon 同形，拇指区）；手机
///    上工具栏是「图标 + 小字标签」等宽格，放不下的按优先级降进「更多」。
///  * Material 一律 M3 Expressive（surfaceContainer 胶囊 + 阴影、选中 =
///    secondaryContainer、FAB = primaryContainer 形状变形）；Apple 是恒深色档
///    （[FushiAppleDarkTier]）的浮动材质胶囊——漫画 chrome 恒压在页图上。墨水屏换
///    实色 + 描边、无阴影、无动效。
///
/// 两种形态由页面决定、本组件只管画：
///  * 固定（`floating == false`）：胶囊所在的整条区域占布局，页面把正文 WebView
///    往下 / 往上让 [mangaChromeTopInset] / [mangaChromeBottomInset]；
///  * 悬浮（`floating == true`）：盖在正文上，默认收起，正文中央点击唤出、再点
///    一下收起（**只认点击**：指针移动不唤出，唤出后也不自动收起）。
///
/// 显隐动效走 [MangaChromeReveal]（顶部向上、底部向下，M3E spatial 弹簧位移 +
/// 淡入，墨水屏 / 减弱动态效果下瞬间到位）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart'
    show FushiExpressiveLoadingIndicator;
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show ShelfCoverFrame;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 胶囊离屏幕左 / 右边的距离（M3E floating toolbar 规格离窗口边 16，手机上收到
/// 12 给标题胶囊多留一点字宽）。
const double kMangaChromeEdgeInset = 12;

/// 顶部一排胶囊（返回 / 标题 / 动作组）的高度：48 的图标按钮 + 上下 4。
const double kMangaChromeTopPillHeight = 56;

/// 顶部胶囊上 / 下方留白。
const double kMangaChromeTopGap = 8;

/// 顶栏占位高（不含系统状态栏）= 上留白 + 胶囊 + 下留白。固定态正文让位的高度
/// 与画出的高度是**同一个常量**（EPUB 顶栏 BUG-2387 同款铁律）。
const double kMangaChromeBarHeight =
    kMangaChromeTopGap + kMangaChromeTopPillHeight + kMangaChromeTopGap;

/// 底部页码滑块胶囊的高度：放得下 M3 Expressive 滑块 44 高的竖条手柄。
const double kMangaChromeBottomPillHeight = 52;

/// 滑块胶囊与下方悬浮工具栏之间的间距。
const double kMangaChromeBottomStackGap = 8;

/// 底部悬浮工具栏的高度（M3E floating toolbar 规格 64，带标签 / 不带标签同高）。
const double kMangaChromeToolbarHeight = 64;

/// 底部胶囊下方留白（离系统手势区）。
const double kMangaChromeBottomGap = 16;

/// 底栏占位高（不含系统手势区）= 上留白 + 滑块胶囊 + 间距 + 工具栏 + 下留白。
const double kMangaChromeBottomBarHeight =
    kMangaChromeTopGap +
    kMangaChromeBottomPillHeight +
    kMangaChromeBottomStackGap +
    kMangaChromeToolbarHeight +
    kMangaChromeBottomGap;

/// 桌面宽屏下顶部一排胶囊的最大宽度：再宽就居中，动作不必横跨整块屏幕。
const double kMangaChromeTopMaxWidth = 1080;

/// 底部滑块胶囊 / 工具栏的最大宽度。
const double kMangaChromeBottomMaxWidth = 720;

/// 胶囊圆角（M3 Expressive 的 extra-large 28）。
const double kMangaChromePillRadius = 28;

/// 底部工具栏改成「图标 + 小字标签」等宽格的宽度阈值（手机拇指区，与小说阅读器
/// 手机底栏同一判据 600）。
const double kMangaChromeLabeledToolbarMaxWidth = 600;

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
/// [contentReady] == false 时底栏不画（没有正文就没有可跳的页、工具栏动作也无
/// 意义），故也不让位。
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
/// 位移走 M3 Expressive 的 spatial 弹簧（与小说阅读器悬浮工具栏同一套
/// [FushiSpring] 物理：进场带一点回弹的落位，退场同一弹簧收回）；透明度钳在
/// 0..1，所以回弹只体现在位移上。墨水屏与系统「减弱动态效果」下
/// （[fushiMotionEnabled] == false）瞬间到位。退场途中子树 [IgnorePointer] +
/// [ExcludeFocus]：正在消失的按钮不该再被点到或 Tab 到。首次挂载即可见时不播
/// 进场（打开书时栏已在位）。
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

/// 漫画 chrome 显隐用的弹簧：M3E default spatial（阻尼比 0.8 档，轻微回弹）。与
/// 小说阅读器 `FushiChromeReveal` 同参，两种阅读器的栏落位手感一致。
final SpringDescription kMangaChromeRevealSpring =
    SpringDescription.withDampingRatio(mass: 1, stiffness: 520, ratio: 0.82);

class _MangaChromeRevealState extends State<MangaChromeReveal>
    with SingleTickerProviderStateMixin {
  late final FushiSpring _spring = FushiSpring(
    vsync: this,
    initial: widget.visible ? 1 : 0,
    spring: kMangaChromeRevealSpring,
  );

  /// 退场 / 进场时的位移（逻辑像素）。
  static const double _travel = 24;

  @override
  void didUpdateWidget(MangaChromeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible == widget.visible) return;
    _spring.animateTo(
      widget.visible ? 1 : 0,
      animate: fushiMotionEnabled(context),
    );
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spring.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double t = _spring.value;
        // 弹簧收回时会略微越过 0（欠阻尼）；越过即视为退场播完，卸载子树。
        if (!widget.visible && t <= 0.001) {
          return const SizedBox.shrink();
        }
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

/// 漫画 chrome 里的一颗动作放在哪儿（与小说阅读器同一套信息架构：常用的在悬浮
/// 工具栏、低频的进「更多」）。
enum MangaChromeSlot {
  /// 顶部动作胶囊（右上）：状态型 / 页面级动作（整卷 OCR 取消、窗口全屏）。恒画。
  top,

  /// 底部悬浮工具栏（拇指区）：阅读中高频动作（章节 / 页面一览 / 阅读模式 /
  /// 单双页 / 翻页方向 / 快捷设置）。窄屏放不下时按 [MangaChromeAction.priority]
  /// 从低到高降进「更多」。
  toolbar,

  /// 恒在「更多」（⋯）菜单里：低频动作（回到开头 / 识别本卷 / 全部设置 /
  /// 隐藏界面）。
  more,
}

/// chrome 里的一颗动作。[active] 是「开关型」动作的当前态（选中底 + 更多菜单
/// 打勾）。
class MangaChromeAction {
  const MangaChromeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.key,
    this.slot = MangaChromeSlot.toolbar,
    this.priority = 0,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Key? key;

  /// 放在哪儿（见 [MangaChromeSlot]）。
  final MangaChromeSlot slot;

  /// 工具栏放不下时的保留优先级：越大越晚降进「更多」。
  final int priority;

  /// 开关型动作当前处于开启态：选中底色，更多菜单里带勾。
  final bool active;

  /// 忙碌中：图标位画 Expressive 加载指示（例如整卷 OCR 进行中）。
  final bool busy;

  /// 转成共享悬浮工具栏的项描述（小说阅读器同一组件）。
  FushiToolbarItem toToolbarItem() => FushiToolbarItem(
    key: key,
    icon: icon,
    label: label,
    selected: active && !busy,
    onPressed: onPressed,
  );
}

/// 工具栏一颗按钮占的宽（不带标签 = 48 的图标按钮；带标签 = 等宽格）。
double mangaToolbarItemWidth({required bool labels}) =>
    labels ? kFushiFloatingToolbarLabeledItemWidth : 48;

/// 工具栏组间分隔占宽：左右各 6 + 线宽 1（与共享组件同源）。
const double kMangaToolbarGroupDividerWidth = 13;

/// FAB 尺寸（M3E 工具栏配对 FAB 的 56 档）。
const double kMangaToolbarFabSize = 56;

/// 悬浮工具栏按 [groups] 画出来的宽度（纯函数，单测钉住）：两端内边距 +
/// 按钮 + 组内间距 + 组间分隔 + 「更多」按钮 + FAB（含间距）。
double mangaToolbarWidth({
  required List<List<MangaChromeAction>> groups,
  required bool labels,
  bool hasOverflow = false,
  bool hasFab = false,
}) {
  final List<List<MangaChromeAction>> visible = <List<MangaChromeAction>>[
    for (final List<MangaChromeAction> g in groups)
      if (g.isNotEmpty) g,
  ];
  final double item = mangaToolbarItemWidth(labels: labels);
  double width = 2 * kFushiFloatingToolbarPadding;
  for (int i = 0; i < visible.length; i++) {
    if (i > 0) width += kMangaToolbarGroupDividerWidth;
    width +=
        visible[i].length * item +
        (visible[i].length - 1) * kFushiFloatingToolbarItemGap;
  }
  if (hasOverflow) width += kFushiFloatingToolbarItemGap + 48;
  if (hasFab) width += kFushiFloatingToolbarFabGap + kMangaToolbarFabSize;
  return width;
}

/// [planMangaChrome] 的结果：每颗动作最终画在哪儿。
@immutable
class MangaChromePlan {
  const MangaChromePlan({
    required this.top,
    required this.toolbar,
    required this.overflow,
    required this.labels,
  });

  /// 顶部动作胶囊里画成图标的动作。
  final List<MangaChromeAction> top;

  /// 底部悬浮工具栏的分组（空组已剔除）。
  final List<List<MangaChromeAction>> toolbar;

  /// 「更多」菜单：工具栏放不下被降级的（保持声明顺序）+ [MangaChromeSlot.more]。
  final List<MangaChromeAction> overflow;

  /// 工具栏是否画成「图标 + 小字标签」等宽格（手机拇指区）。
  final bool labels;
}

/// 按**真实宽度**把动作分到顶部胶囊 / 底部工具栏 / 「更多」（纯函数，单测钉住）。
///
///  1. [groups] 是页面声明的全部动作（按组、组内按序）；[MangaChromeSlot.top] 恒画
///     在顶部胶囊，[MangaChromeSlot.more] 恒进「更多」；
///  2. [MangaChromeSlot.toolbar] 动作保持分组排进底部工具栏；宽度 < [kMangaChromeLabeledToolbarMaxWidth] 时画成带标签
///     的等宽格；
///  3. 工具栏（含 FAB）超出可用宽（屏宽 − 两侧边距，封顶
///     [kMangaChromeBottomMaxWidth]）时，按 [MangaChromeAction.priority] 从低到高
///     （同优先级先降靠后的）逐个降进「更多」，直到放得下；降空也不报错。
///
/// 412dp 竖屏手机上 7~8 颗按钮挤在一条栏里、把页码胶囊压在按钮下面（旧顶栏的
/// BUG）在这里结构上不会再发生：每块胶囊各自限宽，放不下的去「更多」。
MangaChromePlan planMangaChrome({
  required double width,
  required List<List<MangaChromeAction>> groups,
  bool hasFab = false,
}) {
  final List<MangaChromeAction> actions = <MangaChromeAction>[
    for (final List<MangaChromeAction> g in groups) ...g,
  ];
  final List<List<MangaChromeAction>> toolbarGroups = <List<MangaChromeAction>>[
    for (final List<MangaChromeAction> g in groups)
      <MangaChromeAction>[
        for (final MangaChromeAction a in g)
          if (a.slot == MangaChromeSlot.toolbar) a,
      ],
  ];
  final bool labels = width < kMangaChromeLabeledToolbarMaxWidth;
  final double available = math.min(
    kMangaChromeBottomMaxWidth,
    math.max(0, width - 2 * kMangaChromeEdgeInset),
  );
  final List<List<MangaChromeAction>> kept = <List<MangaChromeAction>>[
    for (final List<MangaChromeAction> g in toolbarGroups)
      if (g.isNotEmpty) List<MangaChromeAction>.of(g),
  ];
  final List<MangaChromeAction> demoted = <MangaChromeAction>[];
  final List<MangaChromeAction> more = <MangaChromeAction>[
    for (final MangaChromeAction a in actions)
      if (a.slot == MangaChromeSlot.more) a,
  ];
  bool fits() =>
      mangaToolbarWidth(
        groups: kept,
        labels: labels,
        hasFab: hasFab,
        // 有东西降级时工具栏不另画 ⋯（「更多」在顶部），不计宽。
      ) <=
      available;
  while (!fits()) {
    MangaChromeAction? victim;
    for (final List<MangaChromeAction> g in kept) {
      for (final MangaChromeAction a in g) {
        if (victim == null || a.priority <= victim.priority) victim = a;
      }
    }
    if (victim == null) break;
    for (final List<MangaChromeAction> g in kept) {
      g.remove(victim);
    }
    kept.removeWhere((List<MangaChromeAction> g) => g.isEmpty);
    demoted.add(victim);
  }
  // 降级项按声明顺序进「更多」，排在固定的「更多」项前面（它们本是常用动作）。
  final List<MangaChromeAction> declared = <MangaChromeAction>[
    for (final List<MangaChromeAction> g in toolbarGroups) ...g,
  ];
  demoted.sort(
    (MangaChromeAction a, MangaChromeAction b) =>
        declared.indexOf(a).compareTo(declared.indexOf(b)),
  );
  return MangaChromePlan(
    top: <MangaChromeAction>[
      for (final MangaChromeAction a in actions)
        if (a.slot == MangaChromeSlot.top) a,
    ],
    toolbar: kept,
    overflow: <MangaChromeAction>[...demoted, ...more],
    labels: labels,
  );
}

/// 顶部悬浮条：`(←)  (标题 / 副标题 · 状态)  ………  ( 动作 · ⋯ )`。
///
/// 与小说阅读器的顶部悬浮条同形：三块各自独立成胶囊、不占满宽，正文在胶囊之间
/// 露出来。标题胶囊可点（[onTitleTap]：书架在线条目 = 章节目录，本地卷 = 页面
/// 一览——与小说「点标题 = 打开导航」同一口径），宽度随内容收缩、放不下省略。
/// 右侧胶囊画 [actions]（[MangaChromeSlot.top]）与「更多」（⋯，[overflow] 非空才画）。
///
/// 左右留 [kMangaChromeEdgeInset]，桌面宽屏限宽 [kMangaChromeTopMaxWidth] 居中。
class MangaReaderTopBar extends StatelessWidget {
  const MangaReaderTopBar({
    super.key,
    required this.title,
    required this.onBack,
    required this.backTooltip,
    required this.floating,
    this.subtitle,
    this.onTitleTap,
    this.titleTooltip,
    this.status,
    this.actions = const <MangaChromeAction>[],
    this.overflow = const <MangaChromeAction>[],
  });

  /// 主标题（章节名 / 卷名）；空串且无副标题时不画标题胶囊。
  final String title;

  /// 副标题（作品名）；null / 空串不画第二行。
  final String? subtitle;
  final VoidCallback onBack;
  final String backTooltip;

  /// 点标题胶囊：章节目录 / 页面一览；null = 标题不可点。
  final VoidCallback? onTitleTap;
  final String? titleTooltip;

  /// 标题胶囊尾部的状态件（分镜状态胶囊 / debug 命中信息）。
  final Widget? status;

  /// 右侧胶囊里直接画成图标的动作。
  final List<MangaChromeAction> actions;

  /// 「更多」菜单项（⋯）。空 = 不画 ⋯。
  final List<MangaChromeAction> overflow;

  /// 悬浮态：胶囊浮在页图上；固定态：胶囊画在让出的区域里（同样画投影，两种
  /// 形态外观一致，只差正文让不让位）。
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final double statusBar = MediaQuery.paddingOf(context).top;
    return FushiAppleDarkTier(
      child: Builder(
        builder: (BuildContext context) {
          final ({
            Color container,
            Color foreground,
            Color selectedContainer,
            Color selectedForeground,
          })
          palette = fushiFloatingToolbarPalette(context);
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
                    child: SizedBox(
                      height: kMangaChromeTopPillHeight,
                      child: Row(
                        children: <Widget>[
                          FushiFloatingPill(
                            key: const ValueKey<String>(
                              'manga_reader_back_pill',
                            ),
                            color: palette.container,
                            child: FushiIconButtonControl(
                              key: const ValueKey<String>(
                                'manga_reader_back_button',
                              ),
                              tooltip: backTooltip,
                              color: palette.foreground,
                              icon: const FushiIcon(Icons.arrow_back),
                              onPressed: onBack,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 标题胶囊吃掉中间全部剩余宽度的上限，但按内容收缩、
                          // 靠左；放不下时省略。
                          Expanded(
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: _titlePill(context, palette),
                            ),
                          ),
                          if (actions.isNotEmpty ||
                              overflow.isNotEmpty) ...<Widget>[
                            const SizedBox(width: 8),
                            _actionPill(context, palette),
                          ],
                        ],
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

  Widget _titlePill(
    BuildContext context,
    ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette,
  ) {
    final String main = title.trim();
    final String sub = (subtitle ?? '').trim();
    final Widget? statusWidget = status;
    if (main.isEmpty && sub.isEmpty && statusWidget == null) {
      return const SizedBox.shrink();
    }
    final TextTheme text = Theme.of(context).textTheme;
    final Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMangaChromeTopPillHeight),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          main.isEmpty && sub.isEmpty ? 8 : 18,
          4,
          statusWidget == null ? 18 : 8,
          4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (main.isNotEmpty || sub.isNotEmpty)
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (main.isNotEmpty)
                      Text(
                        main,
                        key: const ValueKey<String>('manga_reader_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall?.copyWith(
                          color: palette.foreground,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        key: const ValueKey<String>('manga_reader_subtitle'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelSmall?.copyWith(
                          color: palette.foreground.withValues(alpha: 0.72),
                          height: 1.2,
                        ),
                      ),
                  ],
                ),
              ),
            if (statusWidget != null) ...<Widget>[
              const SizedBox(width: 8),
              Flexible(child: statusWidget),
            ],
          ],
        ),
      ),
    );
    // 胶囊高度固定 56：两行标题在极大字号（2.0）下会竖向溢出，所以本胶囊的字号
    // 封顶 1.3 倍（工具栏标签同款口径），更大的字号只放大正文，不撑破 chrome。
    final Widget clamped = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: content,
    );
    return FushiFloatingPill(
      key: const ValueKey<String>('manga_reader_title_pill'),
      color: palette.container,
      padding: EdgeInsets.zero,
      child: onTitleTap == null
          ? clamped
          : Tooltip(
              message: titleTooltip ?? '',
              excludeFromSemantics: true,
              child: InkWell(
                key: const ValueKey<String>('manga_reader_title_button'),
                onTap: onTitleTap,
                child: clamped,
              ),
            ),
    );
  }

  Widget _actionPill(
    BuildContext context,
    ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette,
  ) {
    return FushiFloatingPill(
      key: const ValueKey<String>('manga_reader_action_pill'),
      color: palette.container,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < actions.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: kFushiFloatingToolbarItemGap),
            mangaChromeActionButton(actions[i], palette),
          ],
          if (overflow.isNotEmpty) ...<Widget>[
            if (actions.isNotEmpty)
              const SizedBox(width: kFushiFloatingToolbarItemGap),
            MangaChromeOverflowButton(
              actions: overflow,
              foreground: palette.foreground,
            ),
          ],
        ],
      ),
    );
  }
}

/// 一颗 chrome 动作按钮：常态走共享悬浮工具栏按钮（M3E 图标按钮、选中 =
/// secondaryContainer 底 / Apple 强调色实心）；[MangaChromeAction.busy] 时图标位
/// 画 Expressive 加载指示（形变多边形转圈）。
Widget mangaChromeActionButton(
  MangaChromeAction a,
  ({
    Color container,
    Color foreground,
    Color selectedContainer,
    Color selectedForeground,
  })
  palette, {
  bool showLabel = false,
}) {
  if (a.busy) {
    return FushiIconButtonControl(
      key: a.key,
      tooltip: a.label,
      icon: SizedBox.square(
        dimension: 24,
        child: FushiExpressiveLoadingIndicator(
          size: 24,
          color: palette.foreground,
        ),
      ),
      onPressed: a.onPressed,
    );
  }
  return FushiToolbarButton(
    item: a.toToolbarItem(),
    foreground: palette.foreground,
    selectedContainer: palette.selectedContainer,
    selectedForeground: palette.selectedForeground,
    showLabel: showLabel,
  );
}

/// 「更多」（⋯）菜单按钮：菜单项是 [MangaChromeAction]，开关型动作带勾。小说
/// 阅读器的「更多」同形（图标 + 文案一行一项）。
class MangaChromeOverflowButton extends StatelessWidget {
  const MangaChromeOverflowButton({
    super.key,
    required this.actions,
    required this.foreground,
  });

  final List<MangaChromeAction> actions;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return FushiPopupMenuButton<MangaChromeAction>(
      key: const ValueKey<String>('manga_chrome_overflow'),
      tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
      icon: FushiIcon(Icons.more_horiz, color: foreground),
      iconSize: 24,
      onSelected: (MangaChromeAction a) => a.onPressed?.call(),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<MangaChromeAction>>[
            for (final MangaChromeAction a in actions)
              PopupMenuItem<MangaChromeAction>(
                // 菜单项也带可定位的键（`<动作键>_menu_item`），焦点驱动的集成
                // 测试按它找项。
                key: switch (a.key) {
                  final ValueKey<String> k => ValueKey<String>(
                    '${k.value}_menu_item',
                  ),
                  _ => null,
                },
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

/// 底部悬浮工具栏：M3E floating toolbar（按钮组胶囊 + 配对 FAB），居中。
///
/// 手机（[labels]）上是等宽「图标 + 小字标签」格（拇指区，与小说阅读器手机底栏
/// 同形）；桌面是 48 的图标按钮。[fab] 是本页主操作（识别框开关：开 = 圆角方、
/// 关 = 圆，M3E 形状变形）。
class MangaReaderToolbar extends StatelessWidget {
  const MangaReaderToolbar({
    super.key,
    required this.groups,
    this.labels = false,
    this.fab,
  });

  final List<List<MangaChromeAction>> groups;
  final bool labels;
  final Widget? fab;

  @override
  Widget build(BuildContext context) {
    final ({
      Color container,
      Color foreground,
      Color selectedContainer,
      Color selectedForeground,
    })
    palette = fushiFloatingToolbarPalette(context);
    final List<List<MangaChromeAction>> visible = <List<MangaChromeAction>>[
      for (final List<MangaChromeAction> g in groups)
        if (g.isNotEmpty) g,
    ];
    final List<Widget> children = <Widget>[];
    for (int gi = 0; gi < visible.length; gi++) {
      if (gi > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: SizedBox(
              width: 1,
              height: 24,
              child: ColoredBox(
                color: palette.foreground.withValues(alpha: 0.18),
              ),
            ),
          ),
        );
      }
      for (int i = 0; i < visible[gi].length; i++) {
        if (i > 0) {
          children.add(const SizedBox(width: kFushiFloatingToolbarItemGap));
        }
        children.add(
          mangaChromeActionButton(visible[gi][i], palette, showLabel: labels),
        );
      }
    }
    final Widget? fabWidget = fab;
    return SizedBox(
      height: kMangaChromeToolbarHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (children.isNotEmpty)
            FushiFloatingPill(
              key: const ValueKey<String>('manga_reader_toolbar'),
              color: palette.container,
              padding: const EdgeInsets.symmetric(
                horizontal: kFushiFloatingToolbarPadding,
              ),
              child: SizedBox(
                height: kMangaChromeToolbarHeight,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              ),
            ),
          if (fabWidget != null) ...<Widget>[
            if (children.isNotEmpty)
              const SizedBox(width: kFushiFloatingToolbarFabGap),
            fabWidget,
          ],
        ],
      ),
    );
  }
}

/// 底部 chrome 的整块：`滑块胶囊` 叠在 `悬浮工具栏 + FAB` 上方，居中、限宽，
/// 自己让出系统手势区。高度恒为手势区 + [kMangaChromeBottomBarHeight]（固定态正文
/// 让位量与画出高度同源）；没有滑块（单页书）时那一行留空，工具栏不跳位。
class MangaReaderBottomChrome extends StatelessWidget {
  const MangaReaderBottomChrome({
    super.key,
    required this.slider,
    required this.toolbar,
  });

  final Widget slider;
  final Widget toolbar;

  @override
  Widget build(BuildContext context) {
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return FushiAppleDarkTier(
      child: Padding(
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
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                SizedBox(
                  height: kMangaChromeBottomPillHeight,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: kMangaChromeBottomMaxWidth,
                      ),
                      child: slider,
                    ),
                  ),
                ),
                const SizedBox(height: kMangaChromeBottomStackGap),
                SizedBox(
                  height: kMangaChromeToolbarHeight,
                  child: Center(child: toolbar),
                ),
              ],
            ),
          ),
        ),
      ),
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

/// 底部页码滑块胶囊：`( ⏮  3  ━━━━━┃──────  40  ⏭ )`，拖动跳页。浮在底部悬浮
/// 工具栏上方（[MangaReaderBottomChrome] 负责摆位与让出手势区），本组件只画胶囊。
///
/// 此前跳页的唯一入口是顶栏页码胶囊弹出的输入框——要跳到「大概三分之二处」必须先
/// 知道总页数再心算页号。slider 是漫画阅读器的标配（Mihon / Tachiyomi / Kindle 都
/// 有），缺它是用户「本体比 Mihon 薄」的具体一条。
///
/// Material：M3 Expressive 滑块（16 粗轨道 + 4×44 竖条手柄、无刻度点）；Apple：
/// 细线滑块。两端是 tonal 圆钮的上一章 / 下一章（[onPreviousChapter] / [onNextChapter] 为 null 时不画——
/// 本地卷没有「章」）。RTL 下两颗按钮随 slider 一起镜像：左钮恒指向物理左端。
/// 拖动中在手柄上方画一枚数值气泡（`页 / 总页`），有 [pagePreview] 时气泡里带
/// 那一页的缩略图。左侧读数可点（[onPageTap]）：弹出跳页输入框——顶栏不再放页码
/// 胶囊，跳页入口与滑块收在同一块胶囊里。
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
    this.onPageTap,
    this.pageTapTooltip,
    this.onPreviousChapter,
    this.onNextChapter,
    this.previousChapterTooltip,
    this.nextChapterTooltip,
    this.pagePreview,
    this.bubbleLabel,
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

  /// 点左侧当前页读数：弹出跳页框；null = 读数不可点。
  final VoidCallback? onPageTap;
  final String? pageTapTooltip;

  /// 上一章 / 下一章（阅读顺序）；null = 不画对应按钮。
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final String? previousChapterTooltip;
  final String? nextChapterTooltip;

  /// 拖动气泡里的缩略图（0-based 页号）；返回 null 只画页码。
  final ImageProvider? Function(int pageIndex)? pagePreview;

  /// 气泡文案（0-based 页号 -> 文案）；null = `页 / 总页`。双页模式下页面传
  /// 跨页对的区间（`12-13 / 40`），与页码读数同口径。
  final String Function(int pageIndex)? bubbleLabel;

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
    return FushiAppleDarkTier(
      child: Builder(
        builder: (BuildContext context) {
          final MangaChromePalette colors = MangaChromePalette.of(context);
          return FushiFloatingPill(
            key: const ValueKey<String>('manga_reader_slider_pill'),
            color: fushiFloatingToolbarPalette(context).container,
            padding: EdgeInsets.zero,
            child: SizedBox(
              height: kMangaChromeBottomPillHeight,
              child: ListenableBuilder(
                listenable: widget.pageListenable,
                builder: (BuildContext context, Widget? _) =>
                    _buildRow(context, colors),
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
        _pageReadout(
          colors,
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 28),
            child: Text(
              '$shownPage',
              key: const ValueKey<String>('manga_slider_current_page'),
              textAlign: TextAlign.center,
              style: readout,
            ),
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

  /// 当前页读数：可点时是一枚 tonal 小胶囊（Material：secondaryContainer 底 +
  /// 按压水波；Apple：无底、按下变淡），点开跳页框。
  Widget _pageReadout(MangaChromePalette colors, Widget label) {
    final VoidCallback? onTap = widget.onPageTap;
    if (onTap == null) return label;
    final Widget padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: label,
    );
    final Widget chip = colors.apple
        ? FushiPlainButton(
            key: const ValueKey<String>('manga_page_jump_button'),
            onPressed: onTap,
            borderRadius: const BorderRadius.all(Radius.circular(999)),
            child: padded,
          )
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
              onTap: onTap,
              child: padded,
            ),
          );
    final String? tooltip = widget.pageTapTooltip;
    return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
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
      // 共享 M3E 滑块尺寸档 xs（16 粗轨道 + 4×44 竖条把手，按下 / 拖动时把手
      // 收窄到 2——与视频进度条、有声书进度同一套控件规格）。
      data: fushiSliderSizeTheme(SliderTheme.of(context), FushiSliderSize.xs)
          .copyWith(
            tickMarkShape: SliderTickMarkShape.noTickMark,
            showValueIndicator: ShowValueIndicator.never,
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
        child: _MangaBubbleEntrance(
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
              shadows: colors.eink
                  ? const <BoxShadow>[]
                  : kElevationToShadow[3],
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
                    widget.bubbleLabel?.call(pageIndex) ??
                        '${pageIndex + 1} / ${widget.pageCount}',
                    key: const ValueKey<String>('manga_slider_bubble_text'),
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
      ),
    );
  }
}

/// 气泡出现的 M3E 弹簧：从手柄处 0.6 倍缩放 + 淡入弹出（拖动开始那一下）；减弱
/// 动态效果 / 墨水屏下直接出现。
class _MangaBubbleEntrance extends StatefulWidget {
  const _MangaBubbleEntrance({required this.child});

  final Widget child;

  @override
  State<_MangaBubbleEntrance> createState() => _MangaBubbleEntranceState();
}

class _MangaBubbleEntranceState extends State<_MangaBubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final FushiSpring _spring = FushiSpring(
    vsync: this,
    spring: kMangaChromeRevealSpring,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _spring.animateTo(1, animate: fushiMotionEnabled(context));
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spring.animation,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final double t = _spring.value;
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.6 + 0.4 * t,
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        );
      },
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
