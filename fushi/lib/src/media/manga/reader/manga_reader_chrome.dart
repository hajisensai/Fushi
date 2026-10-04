/// 漫画阅读器的界面件（chrome）：顶栏 [MangaReaderTopBar]、底栏跳页 slider
/// [MangaReaderBottomBar]、隐藏界面时的页码角标 [MangaHiddenPageBadge]。
///
/// 与 EPUB 阅读器的 [ReaderDesktopHeader] 同一套视觉语言（48px、左返回 / 中标题 /
/// 右动作、窄窗折叠进 ⋮ 溢出菜单），但布局自己画：栏是**深色实底/半透明**（底色
/// 偏好只管页图周围，栏本身不跟着变白，否则白底档下白字栏不可读），动作要按
/// 「导航 / 视图 / 界面」分组并夹分隔线，还要塞 OCR 进度胶囊，[ReaderDesktopHeader]
/// 的 `title + leading + trailing` 三槽装不下。折叠阈值复用 [readerHeaderCompact]，
/// 折叠规则（只留 pinned、其余进 ⋮）与 EPUB 同一句。
///
/// 两种形态由页面决定、本组件只管画：
///  * 固定（`floating == false`）：实底、占布局，页面把正文 WebView 往下让
///    [mangaChromeTopInset]；
///  * 悬浮（`floating == true`）：半透明、盖在正文上，默认收起，正文中央点击唤出、
///    再点一下收起（**只认点击**：鼠标移动不唤出，唤出后也不自动收起）。
library;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart' show FushiBorderRadius;
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show
        kReaderDesktopHeaderButtonWidth,
        kReaderDesktopHeaderHeight,
        readerHeaderCompact;
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// 顶栏内容行高（不含系统状态栏）。与 EPUB 顶栏同值，两个阅读器视觉对齐。
const double kMangaChromeBarHeight = kReaderDesktopHeaderHeight;

/// 固定态下正文 WebView 顶部让出的高度（纯函数，单测钉住）。
///
///  * 悬浮 / 界面被隐藏（M 键）→ 0：正文全出血；
///  * 固定且界面可见 → 状态栏 + 顶栏行高。正文让位的高度**必须**等于顶栏画出的
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

/// 漫画 chrome（顶栏 / 底栏 / 角标 / 胶囊）的配色。
///
/// 栏恒为深色（见文件头：底色偏好只管页图周围），所以 Apple 设计系统下取的是
/// **深色档**系统色（`FushiAppleColors.of(Brightness.dark)`），不跟随 app 亮暗——
/// 浅色主题下的单色强调色是黑，画在深色栏上等于隐形。MD3 保持原值。
@immutable
class MangaChromeColors {
  const MangaChromeColors({
    required this.foreground,
    required this.secondaryForeground,
    required this.accent,
    required this.warning,
    required this.fixedBar,
    required this.floatingBar,
    required this.hairline,
    required this.groupDivider,
    required this.chipFill,
    required this.badgeFill,
    required this.hiddenBadgeFill,
    required this.sliderInactive,
    required this.apple,
  });

  static const MangaChromeColors _material = MangaChromeColors(
    foreground: Colors.white,
    secondaryForeground: Colors.white70,
    accent: Colors.amberAccent,
    warning: Colors.amberAccent,
    fixedBar: Color(0xF2141414),
    floatingBar: Color(0xB3000000),
    hairline: Colors.white12,
    groupDivider: Colors.white24,
    chipFill: Colors.white12,
    badgeFill: Color(0xB3000000),
    hiddenBadgeFill: Color(0x66000000),
    sliderInactive: null,
    apple: false,
  );

  /// 当前设计系统下的配色。
  static MangaChromeColors of(BuildContext context) {
    if (!isGlassDesign(context)) return _material;
    // 漫画 chrome 恒压在黑底页图上：取恒深色档色板（单色强调色在深色档取白、
    // 有彩强调色按深色档重建明度，见 [appleDarkColorsOf]）。
    final FushiAppleColors dark = appleDarkColorsOf(context);
    return MangaChromeColors(
      foreground: dark.label,
      secondaryForeground: dark.secondaryLabel,
      accent: dark.accent,
      warning: dark.warning,
      // 深色 secondarySystemGroupedBackground：比纯黑页图周围高一层，栏与页图
      // 分得开；悬浮态压低不透明度，透出下面的页图。
      fixedBar: const Color(0xF51C1C1E),
      floatingBar: const Color(0xC71C1C1E),
      hairline: dark.separator,
      groupDivider: dark.separator,
      // 工具栏里的项不带 bezel（HIG Toolbars：toolbar items don't include a
      // bezel）：页码 / 状态小胶囊不铺 systemFill 灰底，悬停由 FushiPlainButton 给。
      chipFill: Colors.transparent,
      badgeFill: const Color(0xD91C1C1E),
      hiddenBadgeFill: const Color(0x991C1C1E),
      sliderInactive: dark.fill,
      apple: true,
    );
  }

  final Color foreground;
  final Color secondaryForeground;

  /// 开关型动作开启态的强调色（MD3 琥珀；Apple 深色档强调色）。
  final Color accent;

  /// 降级 / 告警读数色（BUG-1163：推理后端降级必须看得见）。
  final Color warning;
  final Color fixedBar;
  final Color floatingBar;

  /// 固定态栏与页图之间的细线。
  final Color hairline;

  /// 顶栏动作组之间的竖分隔。
  final Color groupDivider;

  /// 页码胶囊 / 状态胶囊的填充。
  final Color chipFill;

  /// OCR 进度浮标底。
  final Color badgeFill;

  /// 隐藏界面时页码角标底。
  final Color hiddenBadgeFill;

  /// 底栏 slider 未填段；null = 跟主题（MD3 原样）。
  final Color? sliderInactive;

  /// 是否 Apple 设计系统（决定开启态画法与胶囊是否带描边）。
  final bool apple;
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

/// 顶栏一行两端内边距合计：[MangaReaderTopBar] 的 `EdgeInsets.symmetric(horizontal: 4)`。
const double kMangaTopBarHorizontalPadding = 8;

/// 组间分隔线占宽：左右各 2 + 线宽 1（与 `_divider` 同源）。
const double kMangaTopBarDividerWidth = 5;

/// 页码胶囊左右内边距（单侧，与胶囊 `Padding` 同源）。
const double kMangaPageChipHorizontalPadding = 10;

/// [planMangaTopBarActions] 的结果：哪些动作画成图标、哪些进 ⋮。
@immutable
class MangaTopBarActionPlan {
  const MangaTopBarActionPlan({
    required this.compact,
    required this.inline,
    required this.overflow,
    required this.titleAreaWidth,
  });

  /// 紧凑形态：不画书名、组间不画分隔线。
  final bool compact;

  /// 画成图标按钮的动作（按引用比较）。
  final Set<MangaChromeAction> inline;

  /// 收进 ⋮ 的动作，保持组序。
  final List<MangaChromeAction> overflow;

  /// 按钮全部排完后留给标题槽（书名 + 页码胶囊 + 状态件）的宽度，下限 0。
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

/// 顶栏。`[← 返回] [标题 · 页码胶囊] ……… [组1] │ [组2] │ [组3] [⋮]`。
class MangaReaderTopBar extends StatelessWidget {
  const MangaReaderTopBar({
    super.key,
    required this.title,
    required this.onBack,
    required this.backTooltip,
    required this.groups,
    required this.floating,
    this.pageLabel,
    this.pageListenable,
    this.onPageTap,
    this.status,
    this.leading = const <MangaChromeAction>[],
  });

  /// 书名 / 章节名；空串时只画页码。
  final String title;
  final VoidCallback onBack;
  final String backTooltip;

  /// 紧跟返回键的动作（章节目录）：窄窗也常驻，不折进 ⋮。
  final List<MangaChromeAction> leading;

  /// 动作分组（按顺序从左到右），组与组之间画分隔线。空组自动跳过。
  final List<List<MangaChromeAction>> groups;

  /// 悬浮态：半透明底；固定态：实底。
  final bool floating;

  /// 页码胶囊文案（如 `3-4 / 40`），每次 [pageListenable] 触发时重新取；返回
  /// null 不画。只重建胶囊、不重建整页——翻页是高频事件，页面本体带着原生
  /// WebView，不该跟着 setState。
  final String? Function()? pageLabel;
  final Listenable? pageListenable;
  final VoidCallback? onPageTap;

  /// 页码胶囊右侧的状态件（OCR 进度胶囊 / debug 命中信息）。
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final MangaChromeColors colors = MangaChromeColors.of(context);
    final double statusBar = MediaQuery.paddingOf(context).top;
    final List<List<MangaChromeAction>> visibleGroups =
        <List<MangaChromeAction>>[
          for (final List<MangaChromeAction> g in groups)
            if (g.isNotEmpty) g,
        ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: floating ? colors.floatingBar : colors.fixedBar,
        border: floating
            ? null
            : Border(bottom: BorderSide(color: colors.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: statusBar),
        child: SizedBox(
          height: kMangaChromeBarHeight,
          // 胶囊文案随翻页变，排布（降不降次要按钮）要跟着胶囊实测宽走，所以
          // 整栏随 [pageListenable] 重建——只是这一条栏，页面本体（原生
          // WebView）照旧不跟着 setState。
          child: ListenableBuilder(
            listenable:
                pageListenable ?? Listenable.merge(const <Listenable>[]),
            builder: (BuildContext context, Widget? _) {
              final String? label = pageLabel?.call();
              return LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final MangaTopBarActionPlan plan = planMangaTopBarActions(
                    width: constraints.maxWidth,
                    leadingCount: leading.length,
                    groups: visibleGroups,
                    titleAreaMinWidth: label == null
                        ? 0
                        : _pageChipWidth(context, colors, label),
                  );
                  final bool compact = plan.compact;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: kMangaTopBarHorizontalPadding / 2,
                    ),
                    child: Row(
                      children: <Widget>[
                        FushiIconButtonControl(
                          key: const ValueKey<String>(
                            'manga_reader_back_button',
                          ),
                          tooltip: backTooltip,
                          color: colors.foreground,
                          iconSize: 22,
                          icon: const FushiIcon(Icons.arrow_back),
                          onPressed: onBack,
                        ),
                        for (final MangaChromeAction a in leading)
                          _button(a, colors),
                        Expanded(
                          child: _buildTitleArea(
                            context,
                            colors,
                            compact: compact,
                            label: label,
                            maxChipWidth: plan.titleAreaWidth,
                          ),
                        ),
                        for (
                          int i = 0;
                          i < visibleGroups.length;
                          i++
                        ) ...<Widget>[
                          if (i > 0 && !compact) _divider(colors),
                          for (final MangaChromeAction a in visibleGroups[i])
                            if (plan.inline.contains(a)) _button(a, colors),
                        ],
                        if (plan.overflow.isNotEmpty)
                          _overflowMenu(context, colors, plan.overflow),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  TextStyle? _pageChipStyle(BuildContext context, MangaChromeColors colors) =>
      Theme.of(context).textTheme.labelLarge?.copyWith(
        color: colors.foreground,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      );

  /// 页码胶囊按当前字号缩放（[MediaQuery.textScalerOf]）的实测宽。
  double _pageChipWidth(
    BuildContext context,
    MangaChromeColors colors,
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
    MangaChromeColors colors, {
    required bool compact,
    required String? label,
    required double maxChipWidth,
  }) {
    final TextTheme text = Theme.of(context).textTheme;
    return Row(
      children: <Widget>[
        if (title.isNotEmpty && !compact)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Text(
                title,
                key: const ValueKey<String>('manga_reader_title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall?.copyWith(
                  color: colors.foreground.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        if (label != null)
          // 胶囊取自然宽，但绝不超出标题槽：极端字号下连次要按钮都降完仍放不下
          // 时，文字省略而不是画出槽外被按钮盖住。
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxChipWidth),
            child: colors.apple
                // Apple：iOS `.bordered` 小胶囊——系统填充色底、全圆角、按下
                // 变淡，无水波。
                ? FushiPlainButton(
                    key: const ValueKey<String>('manga_page_jump_button'),
                    onPressed: onPageTap,
                    borderRadius: const BorderRadius.all(Radius.circular(999)),
                    child: _pageChipLabel(context, colors, label),
                  )
                : Material(
                    color: colors.chipFill,
                    borderRadius: FushiBorderRadius.chip,
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
    MangaChromeColors colors,
    String label,
  ) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: kMangaPageChipHorizontalPadding,
      vertical: 5,
    ),
    child: Text(
      label,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: _pageChipStyle(context, colors),
    ),
  );

  Widget _divider(MangaChromeColors colors) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: SizedBox(
      width: 1,
      height: 20,
      child: ColoredBox(color: colors.groupDivider),
    ),
  );

  Widget _button(MangaChromeAction a, MangaChromeColors colors) {
    // Apple：开启态是 iOS 26 工具栏里「开着的」开关钮——强调色实心圆 + 反色
    // 字形（[FushiIconButtonControl] 的选中态），而不是只给图标换色。
    final bool appleActive = colors.apple && a.active && !a.busy;
    final Widget icon = a.busy
        ? SizedBox.square(
            dimension: 20,
            child: FushiCircularProgressIndicator(
              strokeWidth: 2,
              color: colors.foreground,
            ),
          )
        : FushiIcon(
            a.icon,
            color: appleActive
                ? appleOnAccent(colors.accent)
                : (a.active ? colors.accent : colors.foreground),
          );
    return FushiIconButtonControl(
      key: a.key,
      tooltip: a.label,
      iconSize: 22,
      icon: icon,
      isSelected: appleActive ? true : null,
      style: appleActive
          ? ButtonStyle(
              backgroundColor: WidgetStatePropertyAll<Color>(colors.accent),
              foregroundColor: WidgetStatePropertyAll<Color>(
                appleOnAccent(colors.accent),
              ),
            )
          : null,
      onPressed: a.onPressed,
    );
  }

  Widget _overflowMenu(
    BuildContext context,
    MangaChromeColors colors,
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

/// 顶栏右侧的小胶囊（OCR 进度 `12/40 · DirectML`）。[warning] 时琥珀色（BUG-1163：
/// 推理后端降级必须看得见）。
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
    final MangaChromeColors colors = MangaChromeColors.of(context);
    final Color fg = warning ? colors.warning : colors.secondaryForeground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // Apple 不画描边框：告警用告警色的淡填充表达，胶囊全圆角。
        color: colors.apple
            ? (warning ? fg.withValues(alpha: 0.18) : colors.chipFill)
            : Colors.white10,
        borderRadius: colors.apple
            ? const BorderRadius.all(Radius.circular(999))
            : FushiBorderRadius.chip,
        border: warning && !colors.apple
            ? Border.all(color: fg.withValues(alpha: 0.6))
            : null,
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

/// 整卷 OCR 进度浮标（`OCR 19/182 · DirectML`），挂在页面右上角、顶栏下沿。
///
/// 不放进顶栏：悬浮顶栏默认收起、用户也会隐藏界面，进度却要一直看得见（对齐
/// Mangatan / Chimahon）。[busy] 画转圈；[warning] 用琥珀色（加速降级 / 没有可用
/// 引擎，BUG-1163：降级必须看得见）。浮标只是读数，不吃指针事件。
class MangaOcrProgressBadge extends StatelessWidget {
  const MangaOcrProgressBadge({
    super.key,
    required this.text,
    this.busy = true,
    this.warning = false,
  });

  final String text;
  final bool busy;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final MangaChromeColors colors = MangaChromeColors.of(context);
    final Color fg = warning ? colors.warning : colors.foreground;
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colors.badgeFill,
          borderRadius: colors.apple
              ? const BorderRadius.all(Radius.circular(999))
              : FushiBorderRadius.chip,
          border: warning && !colors.apple
              ? Border.all(color: fg.withValues(alpha: 0.6))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy) ...<Widget>[
              SizedBox.square(
                dimension: 14,
                child: FushiCircularProgressIndicator(strokeWidth: 2, color: fg),
              ),
              const SizedBox(width: 8),
            ],
            // 警告（没有可用引擎）要把原因和解决办法说全，窄屏上折成两行；进度读数
            // 恒一行。Flexible 让 maxLines / 省略号在有界宽度里真正生效。
            Flexible(
              child: Text(
                text,
                maxLines: warning ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底栏行高（不含系统手势区）。比顶栏矮：只有一条 slider 和两个页码读数。
const double kMangaChromeBottomBarHeight = 44;

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

/// 底栏：`[3] ──────●──── [40]`，拖动跳页。
///
/// 此前跳页的唯一入口是顶栏页码胶囊弹出的输入框——要跳到「大概三分之二处」必须先
/// 知道总页数再心算页号。slider 是漫画阅读器的标配（Mihon / Tachiyomi / Kindle 都
/// 有），缺它是用户「本体比 Mihon 薄」的具体一条。
///
/// 拖动中只更新本地预览（[onPagePreview] 留给调用方画页码读数），**松手才真跳页**
/// （[onPageCommitted]）：漫画翻页要 loadData 重建窗口文档，按住滑块扫过 40 页会
/// 连发 40 次重建。
class MangaReaderBottomBar extends StatefulWidget {
  const MangaReaderBottomBar({
    super.key,
    required this.pageCount,
    required this.pageListenable,
    required this.currentPage,
    required this.rtl,
    required this.onPageCommitted,
    this.floating = true,
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

  /// 与顶栏同义：悬浮态半透明、固定态实底。
  final bool floating;

  @override
  State<MangaReaderBottomBar> createState() => _MangaReaderBottomBarState();
}

class _MangaReaderBottomBarState extends State<MangaReaderBottomBar> {
  /// 拖动中的 slider 位置；null = 没在拖，读 [MangaReaderBottomBar.currentPage]。
  double? _dragPosition;

  @override
  Widget build(BuildContext context) {
    if (widget.pageCount <= 1) return const SizedBox.shrink();
    final TextTheme text = Theme.of(context).textTheme;
    final MangaChromeColors colors = MangaChromeColors.of(context);
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.floating ? colors.floatingBar : colors.fixedBar,
        border: widget.floating
            ? null
            : Border(top: BorderSide(color: colors.hairline)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: SizedBox(
          height: kMangaChromeBottomBarHeight,
          child: ListenableBuilder(
            listenable: widget.pageListenable,
            builder: (BuildContext context, Widget? _) {
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
              final TextStyle? readout = text.labelMedium?.copyWith(
                color: colors.foreground,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              );
              return Row(
                children: <Widget>[
                  const SizedBox(width: 12),
                  Text(
                    '$shownPage',
                    key: const ValueKey<String>('manga_slider_current_page'),
                    style: readout,
                  ),
                  Expanded(
                    child: FushiSlider(
                      key: const ValueKey<String>('manga_page_slider'),
                      value: position.clamp(0, maxPosition),
                      max: maxPosition,
                      // Apple 滑块默认取主题强调色（浅色单色主题下是黑），画在
                      // 恒深色的栏上要换成深色档的强调色 / 填充色；MD3 原样。
                      activeColor: colors.apple ? colors.accent : null,
                      inactiveColor: colors.sliderInactive,
                      // 每一格恰好一页：divisions 缺省时滑块落在页与页之间，
                      // 松手才 round，拖动读数会跳。
                      divisions: pageCount > 1 ? pageCount - 1 : null,
                      onChanged: (double v) =>
                          setState(() => _dragPosition = v),
                      onChangeEnd: (double v) {
                        setState(() => _dragPosition = null);
                        widget.onPageCommitted(
                          mangaSliderPageIndex(
                            position: v,
                            pageCount: pageCount,
                            rtl: widget.rtl,
                          ),
                        );
                      },
                    ),
                  ),
                  Text(
                    '$pageCount',
                    key: const ValueKey<String>('manga_slider_page_count'),
                    style: readout?.copyWith(
                      color: colors.secondaryForeground,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              );
            },
          ),
        ),
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
          final MangaChromeColors colors = MangaChromeColors.of(context);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colors.hiddenBadgeFill,
              borderRadius: colors.apple
                  ? const BorderRadius.all(Radius.circular(999))
                  : FushiBorderRadius.chip,
            ),
            child: Text(
              shown,
              key: const ValueKey<String>('manga_hidden_page_badge'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.secondaryForeground,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          );
        },
      ),
    );
  }
}
