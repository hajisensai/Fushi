part of '../adaptive_navigation.dart';

/// [AppleSidebarTabsShell] 侧栏里的一个分组：标题 + 目的地序号（序号指
/// [AppleSidebarTabsShell.items]）。标题为 null 的分组不画标题、不能折叠。
@immutable
class AppleSidebarSection {
  const AppleSidebarSection({required this.indices, this.title});

  final String? title;
  final List<int> indices;
}

/// 宽窗口时 Apple 设计系统侧栏是否收成顶部标签栏：只在 expanded 尺寸档、
/// 用户用侧栏右上的按钮切过（[userExpanded] == false，与 MD3 rail 的展开 /
/// 收起记忆同一个偏好）时成立。首页外壳与桌面标题栏的缩进都经这里。
bool adaptiveAppleTabBarMode(
  BuildContext context, {
  required WindowSizeClass sizeClass,
  bool? userExpanded,
}) =>
    isGlassDesign(context) &&
    sizeClass == WindowSizeClass.expanded &&
    userExpanded == false;

/// 侧栏面板离窗口的边距（与旧玻璃侧栏一致）。
const double _kAppleSidebarMargin = _kGlassSidebarMargin;

/// 面板内边距。
const double _kAppleSidebarPadding = 8;
const double _kAppleSidebarHeaderHeight = 44;
const double _kAppleSidebarSearchHeight = 32;
const double _kAppleSidebarSectionHeight = 28;
const double _kAppleSidebarRowGap = 2;

/// 顶部标签栏：胶囊高、离窗口顶、内边距、格高。
const double _kAppleTabBarHeight = 44;
const double _kAppleTabBarTop = 10;
const double _kAppleTabBarPadding = 5;
const double _kAppleTabCellHeight = 34;

/// 标签栏模式下内容区往下让出的高度。
const double _kAppleTabBarInset = _kAppleTabBarTop + _kAppleTabBarHeight + 8;

/// 侧栏 → 标签栏时各目的地依次起飞的错开量（占整段进度的比例）。
const double _kAppleMorphStagger = 0.03;

/// iOS 弹簧（阻尼比 0.86，轻微回弹）：面板变形与目的地飞行同用。
final SpringDescription _kAppleMorphSpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 260,
  ratio: 0.86,
);

/// Apple 设计系统宽窗口的首页导航外壳（2026-10-23，照 iPadOS 18 的侧栏 ↔
/// 标签栏）：
///
/// - 侧栏模式：左侧 192 宽的实色悬浮面板（Apple 悬浮面一律实色，
///   [fushiAppleSolidFloatingDecoration]），顶部品牌位 + 收起按钮、搜索框
///   （按名称过滤目的地）、可折叠的分组、底部固定项（设置）。
/// - 标签栏模式：面板变形成顶部居中的 44 高胶囊，每个目的地从侧栏的行
///   飞到胶囊里对应的格（依次错开起飞），内容区同步变宽、往下让出胶囊。
///   胶囊放不下全部带字的格时退成纯图标格（名称进 tooltip 与语义）。
///
/// 两种模式下每个目的地都是同一个焦点目标（`nav-rail-<序号>`），键盘 / 手柄
/// 遍历与读屏语义不随模式变化。墨水屏 / 减弱动态效果下直接切到终态。
class AppleSidebarTabsShell extends StatefulWidget {
  const AppleSidebarTabsShell({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.sections,
    required this.footer,
    required this.tabBar,
    required this.onToggle,
    required this.child,
    this.leading,
  });

  final List<AdaptiveNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// 侧栏的分组（自上而下）；没出现在任何分组 / [footer] 里的目的地不画。
  final List<AppleSidebarSection> sections;

  /// 钉在侧栏底部的目的地（设置）。
  final List<int> footer;

  /// true = 顶部标签栏模式。
  final bool tabBar;
  final VoidCallback onToggle;

  /// 品牌位（侧栏顶部左侧）。
  final Widget? leading;

  /// 内容区。
  final Widget child;

  @override
  State<AppleSidebarTabsShell> createState() => _AppleSidebarTabsShellState();
}

class _AppleSidebarTabsShellState extends State<AppleSidebarTabsShell>
    with TickerProviderStateMixin {
  late final FushiSpring _t = FushiSpring(
    vsync: this,
    initial: widget.tabBar ? 1 : 0,
    spring: _kAppleMorphSpring,
  );
  final TextEditingController _query = TextEditingController();
  final Set<int> _shutSections = <int>{};

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant AppleSidebarTabsShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabBar != widget.tabBar) {
      _t.animateTo(
        widget.tabBar ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _query.dispose();
    super.dispose();
  }

  bool _matches(int index) {
    final String q = _query.text.trim().toLowerCase();
    return q.isEmpty || widget.items[index].label.toLowerCase().contains(q);
  }

  /// 侧栏模式下每个目的地行的矩形（shell 坐标）；被折叠 / 过滤掉的行给 null。
  /// 同时返回每个分组标题的纵向位置。
  ({Map<int, Rect> rows, List<double> sectionTops}) _sidebarLayout(Size size) {
    const double left = _kAppleSidebarMargin + _kAppleSidebarPadding;
    const double width = kGlassNavSidebarWidth - 2 * left;
    double y =
        _kAppleSidebarMargin +
        _kAppleSidebarPadding +
        _kAppleSidebarHeaderHeight +
        _kAppleSidebarSearchHeight +
        8;
    final Map<int, Rect> rows = <int, Rect>{};
    final List<double> sectionTops = <double>[];
    for (int s = 0; s < widget.sections.length; s++) {
      final AppleSidebarSection section = widget.sections[s];
      if (section.title != null) {
        sectionTops.add(y);
        y += _kAppleSidebarSectionHeight;
      } else {
        sectionTops.add(double.nan);
      }
      if (_shutSections.contains(s)) continue;
      for (final int i in section.indices) {
        if (!_matches(i)) continue;
        rows[i] = Rect.fromLTWH(left, y, width, _kGlassSidebarRowHeight);
        y += _kGlassSidebarRowHeight + _kAppleSidebarRowGap;
      }
      y += 6;
    }
    double bottom = size.height - _kAppleSidebarMargin - _kAppleSidebarPadding;
    for (final int i in widget.footer.reversed) {
      bottom -= _kGlassSidebarRowHeight;
      rows[i] = Rect.fromLTWH(left, bottom, width, _kGlassSidebarRowHeight);
      bottom -= _kAppleSidebarRowGap;
    }
    return (rows: rows, sectionTops: sectionTops);
  }

  /// 标签栏模式：胶囊矩形 + 每个目的地格的矩形（shell 坐标）。放不下带字格
  /// 时整排退成纯图标格（[iconOnly]）。
  ({Rect capsule, Map<int, Rect> cells, bool iconOnly}) _tabLayout(
    Size size,
    TextStyle labelStyle,
  ) {
    final List<int> order = <int>[
      for (final AppleSidebarSection s in widget.sections) ...s.indices,
      ...widget.footer,
    ];
    final Set<int> iconOnlyAlways = widget.footer.toSet();
    double cellWidth(int i, {required bool iconOnly}) {
      if (iconOnly || iconOnlyAlways.contains(i)) return _kAppleTabCellHeight;
      final TextPainter painter = TextPainter(
        text: TextSpan(text: widget.items[i].label, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return 12 + 18 + 6 + painter.width + 12;
    }

    double total({required bool iconOnly}) =>
        _kAppleTabBarPadding * 2 +
        _kAppleTabCellHeight +
        order.fold<double>(
          0,
          (double sum, int i) =>
              sum + cellWidth(i, iconOnly: iconOnly) + _kAppleSidebarRowGap,
        );
    bool iconOnly = false;
    double width = total(iconOnly: false);
    if (width > size.width - 32) {
      iconOnly = true;
      width = total(iconOnly: true);
    }
    final Rect capsule = Rect.fromLTWH(
      ((size.width - width) / 2).clamp(8.0, double.infinity),
      _kAppleTabBarTop,
      width,
      _kAppleTabBarHeight,
    );
    double x =
        capsule.left +
        _kAppleTabBarPadding +
        _kAppleTabCellHeight +
        _kAppleSidebarRowGap;
    const double top =
        _kAppleTabBarTop + (_kAppleTabBarHeight - _kAppleTabCellHeight) / 2;
    final Map<int, Rect> cells = <int, Rect>{};
    for (final int i in order) {
      final double w = cellWidth(i, iconOnly: iconOnly);
      cells[i] = Rect.fromLTWH(x, top, w, _kAppleTabCellHeight);
      x += w + _kAppleSidebarRowGap;
    }
    return (capsule: capsule, cells: cells, iconOnly: iconOnly);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle tabLabel = (text.labelLarge ?? const TextStyle()).copyWith(
      fontSize: 13.5,
      fontWeight: FontWeight.w500,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        final ({Map<int, Rect> rows, List<double> sectionTops}) side =
            _sidebarLayout(size);
        final ({Rect capsule, Map<int, Rect> cells, bool iconOnly}) tabs =
            _tabLayout(size, tabLabel);
        final Rect sidePanel = Rect.fromLTWH(
          _kAppleSidebarMargin,
          _kAppleSidebarMargin,
          kGlassNavSidebarWidth - 2 * _kAppleSidebarMargin,
          size.height - 2 * _kAppleSidebarMargin,
        );
        return AnimatedBuilder(
          animation: _t.animation,
          builder: (BuildContext context, Widget? content) {
            final double t = _t.value;
            final double settled = t.clamp(0.0, 1.0);
            // 侧栏独有的部分（品牌、搜索、分组标题）先淡出、后淡入；
            // 标签栏独有的切换钮反之。
            final double sideOnly = (1 - settled * 2.5).clamp(0.0, 1.0);
            final double tabOnly = (settled * 2 - 1).clamp(0.0, 1.0);
            final Rect panel = Rect.lerp(sidePanel, tabs.capsule, t)!;
            final int count = widget.items.length;
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned(
                  left: kGlassNavSidebarWidth * (1 - settled),
                  top: _kAppleTabBarInset * settled,
                  right: 0,
                  bottom: 0,
                  child: content!,
                ),
                Positioned.fromRect(
                  rect: panel,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: fushiAppleSolidFloatingDecoration(
                        context,
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(
                            20 + (_kAppleTabBarHeight / 2 - 20) * settled,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (sideOnly > 0)
                  ..._buildSidebarChrome(
                    context,
                    apple: apple,
                    opacity: sideOnly,
                    sectionTops: side.sectionTops,
                  ),
                if (tabOnly > 0)
                  Positioned(
                    left: tabs.capsule.left + _kAppleTabBarPadding,
                    top:
                        _kAppleTabBarTop +
                        (_kAppleTabBarHeight - _kAppleTabCellHeight) / 2,
                    child: Opacity(
                      opacity: tabOnly,
                      child: _toggleButton(apple, toTabBar: false),
                    ),
                  ),
                for (int i = 0; i < count; i++)
                  if (tabs.cells[i] case final Rect cell)
                    _buildItem(
                      context,
                      index: i,
                      apple: apple,
                      from: side.rows[i],
                      to: cell,
                      // 依次起飞：越靠后的目的地越晚出发（两个方向同一顺序）。
                      t: _stagger(t, i, count),
                      tabLabel: tabLabel,
                      iconOnly: tabs.iconOnly || widget.footer.contains(i),
                    ),
              ],
            );
          },
          child: widget.child,
        );
      },
    );
  }

  static double _stagger(double t, int i, int count) {
    final double span = 1 - _kAppleMorphStagger * (count - 1).clamp(0, 12);
    final double start = _kAppleMorphStagger * i.clamp(0, 12);
    if (t >= 1) return t; // 弹簧过冲：全体同步回弹
    return ((t - start) / span).clamp(0.0, 1.0);
  }

  Widget _toggleButton(FushiAppleColors apple, {required bool toTabBar}) {
    return FushiTooltip(
      message: toTabBar ? t.nav_sidebar_to_tab_bar : t.nav_tab_bar_to_sidebar,
      child: FushiPressScale(
        child: Semantics(
          button: true,
          label: toTabBar ? t.nav_sidebar_to_tab_bar : t.nav_tab_bar_to_sidebar,
          child: GestureDetector(
            onTap: widget.onToggle,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: SizedBox.square(
                dimension: _kAppleTabCellHeight,
                child: Center(
                  child: FushiIcon(
                    toTabBar ? FushiIcons.menuOpen : FushiIcons.menu,
                    size: 20,
                    color: apple.accent,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSidebarChrome(
    BuildContext context, {
    required FushiAppleColors apple,
    required double opacity,
    required List<double> sectionTops,
  }) {
    const double left = _kAppleSidebarMargin + _kAppleSidebarPadding;
    const double width = kGlassNavSidebarWidth - 2 * left;
    final TextTheme text = Theme.of(context).textTheme;
    Widget fade(Widget child) => Opacity(
      opacity: opacity,
      child: IgnorePointer(ignoring: opacity < 1, child: child),
    );
    return <Widget>[
      Positioned(
        left: left,
        top: _kAppleSidebarMargin + _kAppleSidebarPadding,
        width: width,
        height: _kAppleSidebarHeaderHeight,
        child: fade(
          Row(
            children: <Widget>[
              if (widget.leading case final Widget leading)
                SizedBox.square(dimension: 36, child: leading),
              const Spacer(),
              _toggleButton(apple, toTabBar: true),
            ],
          ),
        ),
      ),
      Positioned(
        left: left,
        top:
            _kAppleSidebarMargin +
            _kAppleSidebarPadding +
            _kAppleSidebarHeaderHeight,
        width: width,
        height: _kAppleSidebarSearchHeight,
        child: fade(
          DecoratedBox(
            decoration: BoxDecoration(
              color: apple.tertiaryFill,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                const SizedBox(width: 8),
                FushiIcon(
                  FushiIcons.search,
                  size: 16,
                  color: apple.secondaryLabel,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _query,
                    style: text.bodyMedium?.copyWith(color: apple.label),
                    decoration: InputDecoration.collapsed(
                      hintText: t.search,
                      hintStyle: text.bodyMedium?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      for (int s = 0; s < widget.sections.length; s++)
        if (widget.sections[s].title case final String title)
          if (!sectionTops[s].isNaN)
            Positioned(
              left: left,
              top: sectionTops[s],
              width: width,
              height: _kAppleSidebarSectionHeight,
              child: fade(
                _AppleSidebarSectionHeader(
                  title: title,
                  shut: _shutSections.contains(s),
                  color: apple.secondaryLabel,
                  onTap: () => setState(() {
                    if (!_shutSections.remove(s)) _shutSections.add(s);
                  }),
                ),
              ),
            ),
    ];
  }

  Widget _buildItem(
    BuildContext context, {
    required int index,
    required FushiAppleColors apple,
    required Rect? from,
    required Rect to,
    required double t,
    required TextStyle tabLabel,
    required bool iconOnly,
  }) {
    // 侧栏里被折叠 / 过滤掉的行：侧栏模式下不画，标签栏模式下从胶囊格位置
    // 原地淡入。
    final Rect start = from ?? to;
    final double visible = from == null ? t.clamp(0.0, 1.0) : 1;
    final Rect rect = Rect.lerp(start, to, t)!;
    final double s = t.clamp(0.0, 1.0);
    final bool selected = index == widget.currentIndex;
    final AdaptiveNavItem item = widget.items[index];
    final TextStyle sideLabel =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w400,
        );
    final TextStyle label = TextStyle.lerp(sideLabel, tabLabel, s)!;
    // 选中态：侧栏是强调色实底 + onAccent；标签栏是灰色托盘 + 强调色字。
    final Color fill = selected
        ? Color.lerp(apple.accent, apple.secondaryFill, s)!
        : Colors.transparent;
    final Color fg = selected
        ? Color.lerp(apple.onAccent, apple.accent, s)!
        : apple.label;
    final Color iconColor = selected ? fg : apple.accent;
    final double radius =
        _kGlassSidebarRowRadius +
        (_kAppleTabCellHeight / 2 - _kGlassSidebarRowRadius) * s;
    final double labelOpacity = iconOnly ? (1 - s * 2).clamp(0.0, 1.0) : 1;
    return Positioned.fromRect(
      rect: rect,
      child: Opacity(
        opacity: visible,
        child: IgnorePointer(
          ignoring: visible < 1,
          child: _AppleMorphDestination(
            id: FushiFocusId('nav-rail-$index'),
            item: item,
            selected: selected,
            onSelect: () {
              if (index != widget.currentIndex) fushiSelectionHaptic(context);
              widget.onTap(index);
            },
            fill: fill,
            hover: apple.tertiaryFill,
            radius: radius,
            padding: 10 + 2 * s,
            iconSize: 19 - s,
            iconColor: iconColor,
            label: labelOpacity > 0
                ? Opacity(
                    opacity: labelOpacity,
                    child: Text(
                      item.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: label.copyWith(color: fg),
                    ),
                  )
                : null,
            centerIcon: iconOnly && s >= 0.5,
          ),
        ),
      ),
    );
  }
}

class _AppleSidebarSectionHeader extends StatelessWidget {
  const _AppleSidebarSectionHeader({
    required this.title,
    required this.shut,
    required this.color,
    required this.onTap,
  });

  final String title;
  final bool shut;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      expanded: !shut,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: text.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: shut ? -0.25 : 0,
                  duration: fushiMotionDuration(context, FushiMotion.short),
                  curve: FushiMotion.standard,
                  child: FushiIcon(
                    FushiIcons.expandMore,
                    size: 16,
                    color: color,
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

/// 侧栏 ↔ 标签栏里的一个目的地：独立的键盘 / 手柄焦点目标（A / Enter 走
/// [ActivateIntent]），悬停给一层最浅的 systemFill，按压走 [FushiPressScale]。
class _AppleMorphDestination extends StatefulWidget {
  const _AppleMorphDestination({
    required this.id,
    required this.item,
    required this.selected,
    required this.onSelect,
    required this.fill,
    required this.hover,
    required this.radius,
    required this.padding,
    required this.iconSize,
    required this.iconColor,
    required this.label,
    required this.centerIcon,
  });

  final FushiFocusId id;
  final AdaptiveNavItem item;
  final bool selected;
  final VoidCallback onSelect;
  final Color fill;
  final Color hover;
  final double radius;
  final double padding;
  final double iconSize;
  final Color iconColor;
  final Widget? label;
  final bool centerIcon;

  @override
  State<_AppleMorphDestination> createState() => _AppleMorphDestinationState();
}

class _AppleMorphDestinationState extends State<_AppleMorphDestination> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final AdaptiveNavItem item = widget.item;
    final IconData icon = widget.selected
        ? (item.selectedIcon ?? item.icon)
        : item.icon;
    final Widget glyph = _maybeBadge(
      item: item,
      child: FushiIcon(icon, size: widget.iconSize, color: widget.iconColor),
    );
    final Color background = widget.selected
        ? widget.fill
        : (_hovering ? widget.hover : Colors.transparent);
    final Widget? label = widget.label;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            widget.onSelect();
            return null;
          },
        ),
      },
      child: FushiTooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: widget.selected,
          label: item.label,
          excludeSemantics: true,
          child: FushiFocusTarget(
            id: widget.id,
            child: FushiPressScale(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovering = true),
                onExit: (_) => setState(() => _hovering = false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onSelect,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(widget.radius),
                    ),
                    child: widget.centerIcon || label == null
                        ? Center(child: glyph)
                        : Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: widget.padding,
                            ),
                            child: Row(
                              children: <Widget>[
                                glyph,
                                const SizedBox(width: 6),
                                Expanded(child: label),
                              ],
                            ),
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
