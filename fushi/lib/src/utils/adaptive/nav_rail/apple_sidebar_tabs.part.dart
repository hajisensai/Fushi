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

/// 贴边侧栏的内容内边距（行离侧栏左右缘 / 上下缘的距离）。
const double _kAppleSidebarPadding = 10;
const double _kAppleSidebarHeaderHeight = 44;
const double _kAppleSidebarSectionHeight = 26;
const double _kAppleSidebarRowGap = 2;

/// 库页分区子项每一级的缩进（macOS 源列表的子项缩进量）。
const double _kAppleSidebarSubIndent = 14;

/// macOS 26（Tahoe）源列表的行：行高 28、选中底圆角 8、13 号常规字重标签、
/// 16 号强调色描线图标（SF Symbols 侧栏默认中号）。
const double _kAppleSidebarRowHeight = 28;
const double _kAppleSidebarRowRadius = 8;
const double _kAppleSidebarIconSize = 16;
const double _kAppleSidebarFontSize = 13;

/// 分组标题：11 号半粗次要色（macOS 源列表 section header）。
const double _kAppleSidebarSectionFontSize = 11;

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
/// - 侧栏模式：macOS 27（Golden Gate）贴边侧栏（[AppleEdgeSidebarSurface]：
///   紧贴窗口左 / 上 / 下缘、无外边距 / 圆角 / 投影，右缘发丝线，随「玻璃
///   画质」档位：实色档实色面，其余档平面库玻璃；顶部伸到标题行底下），顶部品牌位 + 收起按钮、胶囊搜索框（按名称过滤目的地）、
///   可折叠的分组（11 号次要色标题 + 折叠箭头）、底部固定项（设置）。行是
///   源列表规格：行高 28、13 号字、16 号强调色图标，选中 = 中性色圆角底
///   （secondarySystemFill，窗口失焦时减半、图标退次要灰）。
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
    this.libraryHost,
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

  /// 库页登记分区子项的宿主（2026-11-24 方案 A）：macOS 档侧栏形态下，当前
  /// 模块的行下面展开它登记的分区行；本壳也把自己的形态报给它（收成标签栏时
  /// 库页把分区画回内容区）。null = 不展开。
  final AppleSidebarLibraryHost? libraryHost;

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
  final Set<int> _shutSections = <int>{};

  @override
  void initState() {
    super.initState();
    widget.libraryHost?.addListener(_onLibraryRows);
  }

  void _onLibraryRows() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant AppleSidebarTabsShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryHost != widget.libraryHost) {
      oldWidget.libraryHost?.removeListener(_onLibraryRows);
      widget.libraryHost?.addListener(_onLibraryRows);
    }
    if (oldWidget.tabBar != widget.tabBar) {
      _t.animateTo(
        widget.tabBar ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    widget.libraryHost?.removeListener(_onLibraryRows);
    _t.dispose();
    super.dispose();
  }

  /// macOS 档放大系数（[fushiAppleMacScale]）：侧栏行高 / 字号 / 图标在
  /// Windows / Linux 宽窗放大，Mac 与 iPad 1.0。标签栏形态不随它变。
  double get _k => fushiAppleMacScale(context);

  /// 侧栏模式下每个目的地行的矩形（shell 坐标）；被折叠的行给 null。
  /// 同时返回每个分组标题的纵向位置。
  ({
    Map<int, Rect> rows,
    List<double> sectionTops,
    List<(AppleSidebarLibraryRow, Rect)> subRows,
  })
  _sidebarLayout(Size size, double topInset) {
    const double left = _kAppleSidebarPadding;
    const double width = kGlassNavSidebarWidth - 2 * left;
    final double k = _k;
    final double rowHeight = _kAppleSidebarRowHeight * k;
    final double rowGap = _kAppleSidebarRowGap * k;
    double y =
        topInset +
        _kAppleSidebarPadding +
        // 无搜索框：首节标题紧接窗口控件 / 品牌行下方（macOS 27 Finder / Music
        // 侧栏）。
        _kAppleSidebarHeaderHeight;
    final Map<int, Rect> rows = <int, Rect>{};
    final List<double> sectionTops = <double>[];
    final List<AppleSidebarLibraryRow> library = _libraryRows;
    final List<(AppleSidebarLibraryRow, Rect)> subRows =
        <(AppleSidebarLibraryRow, Rect)>[];
    for (int s = 0; s < widget.sections.length; s++) {
      final AppleSidebarSection section = widget.sections[s];
      if (section.title != null) {
        sectionTops.add(y);
        y += _kAppleSidebarSectionHeight * k;
      } else {
        sectionTops.add(double.nan);
      }
      if (_shutSections.contains(s)) continue;
      for (final int i in section.indices) {
        rows[i] = Rect.fromLTWH(left, y, width, rowHeight);
        y += rowHeight + rowGap;
        // 当前模块下展开库页登记的分区行（缩进一级 / 两级）。
        if (i == widget.currentIndex) {
          for (final AppleSidebarLibraryRow sub in library) {
            final double indent = _kAppleSidebarSubIndent * k * sub.depth;
            subRows.add((
              sub,
              Rect.fromLTWH(left + indent, y, width - indent, rowHeight),
            ));
            y += rowHeight + rowGap;
          }
        }
      }
      y += 6 * k;
    }
    double bottom = size.height - _kAppleSidebarPadding;
    for (final int i in widget.footer.reversed) {
      bottom -= rowHeight;
      rows[i] = Rect.fromLTWH(left, bottom, width, rowHeight);
      bottom -= rowGap;
    }
    return (rows: rows, sectionTops: sectionTops, subRows: subRows);
  }

  /// 此刻要在当前模块下展开的库页分区行：侧栏形态 + macOS 档度量才展开。
  List<AppleSidebarLibraryRow> get _libraryRows {
    final AppleSidebarLibraryHost? host = widget.libraryHost;
    if (host == null || widget.tabBar || !fushiAppleUsesMacMetrics(context)) {
      return const <AppleSidebarLibraryRow>[];
    }
    return host.rows;
  }

  /// 标签栏模式：胶囊矩形 + 每个目的地格的矩形（shell 坐标）。放不下带字格
  /// 时整排退成纯图标格（[iconOnly]）。
  ({Rect capsule, Map<int, Rect> cells, bool iconOnly}) _tabLayout(
    Size size,
    TextStyle labelStyle,
    double topInset,
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
      topInset + _kAppleTabBarTop,
      width,
      _kAppleTabBarHeight,
    );
    double x =
        capsule.left +
        _kAppleTabBarPadding +
        _kAppleTabCellHeight +
        _kAppleSidebarRowGap;
    final double top =
        topInset +
        _kAppleTabBarTop +
        (_kAppleTabBarHeight - _kAppleTabCellHeight) / 2;
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
    final TextStyle tabLabel = context.fushiType.labelMedium.copyWith(
      fontWeight: FontWeight.w500,
    );
    return _AppleWindowActiveBuilder(
      builder: (BuildContext context, bool windowActive) =>
          _buildShell(context, apple, tabLabel, windowActive: windowActive),
    );
  }

  Widget _buildShell(
    BuildContext context,
    FushiAppleColors apple,
    TextStyle tabLabel, {
    required bool windowActive,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        // 首页外壳不在外层吃顶部安全区（[navRailBleedsToTop]）：侧栏底从窗口
        // 上沿铺起（伸到桌面自绘标题行 / 状态栏底下），侧栏内容、标签栏胶囊与
        // 内容区各自让开这一段。
        final double topInset = MediaQuery.paddingOf(context).top;
        // 侧栏形态报给库页（收成标签栏时库页把分区画回内容区）；通知推迟到
        // 帧末，构建期间调用安全。
        widget.libraryHost?.reportSidebarMode(!widget.tabBar);
        final ({
          Map<int, Rect> rows,
          List<double> sectionTops,
          List<(AppleSidebarLibraryRow, Rect)> subRows,
        })
        side = _sidebarLayout(size, topInset);
        final ({Rect capsule, Map<int, Rect> cells, bool iconOnly}) tabs =
            _tabLayout(size, tabLabel, topInset);
        // macOS 27（Golden Gate）侧栏贴边：紧贴窗口左 / 上 / 下缘。
        final Rect sidePanel = Rect.fromLTWH(
          0,
          0,
          kGlassNavSidebarWidth,
          size.height,
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
                // 侧栏态：内容区与侧栏一样从窗口上沿铺起（macOS 27 统一的标题栏 +
                // 工具栏，详情页的底色 / 二级侧栏一直画到窗口按钮那一行，不再在
                // y = topInset 处切出一条接缝），顶部安全区（窗口按钮行 / 状态栏）
                // 以 MediaQuery 顶部 padding 交给页面自己让；[AppleSidebarTopBleed]
                // 标出这一段是让位。标签栏态：内容排在胶囊下面，不再有顶部 padding。
                // 两态之间按形变进度插值，过渡连续。
                Positioned(
                  left: kGlassNavSidebarWidth * (1 - settled),
                  top: (topInset + _kAppleTabBarInset) * settled,
                  right: 0,
                  bottom: 0,
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      padding: MediaQuery.paddingOf(
                        context,
                      ).copyWith(top: topInset * (1 - settled)),
                      viewPadding: MediaQuery.viewPaddingOf(
                        context,
                      ).copyWith(top: topInset * (1 - settled)),
                    ),
                    child: content!,
                  ),
                ),
                // 侧栏静止时是贴边的平面侧栏底；一离开侧栏态就换成悬浮胶囊面，
                // 从直角贴边形变到标签栏胶囊。
                Positioned.fromRect(
                  rect: panel,
                  child: IgnorePointer(
                    child: t <= 0
                        ? const AppleEdgeSidebarSurface()
                        : FushiAppleFloatingSurface(
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(
                                _kAppleTabBarHeight / 2 * settled,
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
                    topInset: topInset,
                  ),
                if (sideOnly > 0)
                  for (int i = 0; i < side.subRows.length; i++)
                    _buildLibraryRow(
                      context,
                      row: side.subRows[i].$1,
                      rect: side.subRows[i].$2,
                      index: i,
                      apple: apple,
                      opacity: sideOnly,
                      windowActive: windowActive,
                    ),
                if (tabOnly > 0)
                  Positioned(
                    left: tabs.capsule.left + _kAppleTabBarPadding,
                    top:
                        topInset +
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
                      windowActive: windowActive,
                    ),
              ],
            );
          },
          child: AppleSidebarTopBleed(child: widget.child),
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
    required double topInset,
  }) {
    const double left = _kAppleSidebarPadding;
    const double width = kGlassNavSidebarWidth - 2 * left;
    final double k = _k;
    Widget fade(Widget child) => Opacity(
      opacity: opacity,
      child: IgnorePointer(ignoring: opacity < 1, child: child),
    );
    return <Widget>[
      Positioned(
        left: left,
        top: topInset + _kAppleSidebarPadding,
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
      for (int s = 0; s < widget.sections.length; s++)
        if (widget.sections[s].title case final String title)
          if (!sectionTops[s].isNaN)
            Positioned(
              left: left,
              top: sectionTops[s],
              width: width,
              height: _kAppleSidebarSectionHeight * k,
              child: fade(
                _AppleSidebarSectionHeader(
                  title: title,
                  shut: _shutSections.contains(s),
                  color: apple.secondaryLabel,
                  chevronColor: apple.tertiaryLabel,
                  onTap: () => setState(() {
                    if (!_shutSections.remove(s)) _shutSections.add(s);
                  }),
                ),
              ),
            ),
    ];
  }

  /// 当前模块下展开的一行库页分区（与目的地行同一源列表规格：行高 28、选中
  /// 中性色圆角底、图标强调色；缩进一级）。随侧栏独有部分一起淡出；首次出现
  /// 时错峰淡入。
  Widget _buildLibraryRow(
    BuildContext context, {
    required AppleSidebarLibraryRow row,
    required Rect rect,
    required int index,
    required FushiAppleColors apple,
    required double opacity,
    required bool windowActive,
  }) {
    final double k = _k;
    final Color sideFill = windowActive
        ? apple.secondaryFill
        : apple.secondaryFill.withValues(alpha: apple.secondaryFill.a * 0.5);
    final IconData? icon = row.icon;
    if (row.header) {
      // 节标题（「标签」）：与侧栏分组标题同一字级，不可点、不进焦点序。
      return Positioned.fromRect(
        key: ValueKey<String>('apple-sidebar-library-${row.id}'),
        rect: rect,
        child: Opacity(
          opacity: opacity,
          child: ExcludeFocus(
            child: Align(
              alignment: AlignmentDirectional.bottomStart,
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  start: 8 * k,
                  bottom: 4 * k,
                ),
                child: Text(
                  row.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: context.fushiType.labelSmall.copyWith(
                    fontSize: (_kAppleSidebarFontSize - 2) * k,
                    fontWeight: FontWeight.w600,
                    color: apple.tertiaryLabel,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Positioned.fromRect(
      key: ValueKey<String>('apple-sidebar-library-${row.id}'),
      rect: rect,
      child: Opacity(
        opacity: opacity,
        child: IgnorePointer(
          ignoring: opacity < 1,
          child: FushiStaggeredEntrance(
            index: index,
            child: _AppleMorphDestination(
              id: FushiFocusId('nav-rail-library-${row.id}'),
              item: AdaptiveNavItem(
                icon: icon ?? FushiIcons.chevronRight,
                label: row.label,
              ),
              selected: row.selected,
              onSelect: () {
                if (!row.selected) fushiSelectionHaptic(context);
                row.onTap();
              },
              fill: row.selected ? sideFill : Colors.transparent,
              hover: apple.tertiaryFill.withValues(
                alpha: apple.tertiaryFill.a * 0.6,
              ),
              radius: _kAppleSidebarRowRadius * k,
              padding: 8 * k,
              gap: 7 * k,
              iconSize: (_kAppleSidebarIconSize - 1) * k,
              iconColor:
                  row.tint ??
                  (windowActive ? apple.accent : apple.secondaryLabel),
              fillDuration: fushiMotionDuration(context, FushiMotion.short),
              label: Text(
                row.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: context.fushiType.bodyMedium.copyWith(
                  fontSize: _kAppleSidebarFontSize * k,
                  fontWeight: FontWeight.w400,
                  height: 1.2,
                  color: apple.label,
                ),
              ),
              centerIcon: false,
            ),
          ),
        ),
      ),
    );
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
    required bool windowActive,
  }) {
    // 侧栏里被折叠的行：侧栏模式下不画，标签栏模式下从胶囊格位置
    // 原地淡入。
    final Rect start = from ?? to;
    final double visible = from == null ? t.clamp(0.0, 1.0) : 1;
    final Rect rect = Rect.lerp(start, to, t)!;
    final double s = t.clamp(0.0, 1.0);
    final bool selected = index == widget.currentIndex;
    final AdaptiveNavItem item = widget.items[index];
    final double k = _k;
    final TextStyle sideLabel = context.fushiType.bodyMedium.copyWith(
      fontSize: _kAppleSidebarFontSize * k,
      fontWeight: FontWeight.w400,
      height: 1.2,
    );
    final TextStyle label = TextStyle.lerp(sideLabel, tabLabel, s)!;
    // 选中态（2026-11-24 用户「侧栏还不是 macOS 27」）：侧栏是 macOS 26 源列表
    // 的中性色圆角底（secondarySystemFill，窗口失焦时减半），标签仍 label 色、
    // 图标仍强调色——不再是强调色实心块。标签栏模式是灰色托盘 + 强调色字。
    final Color sideFill = windowActive
        ? apple.secondaryFill
        : apple.secondaryFill.withValues(alpha: apple.secondaryFill.a * 0.5);
    final Color fill = selected
        ? Color.lerp(sideFill, apple.secondaryFill, s)!
        : Colors.transparent;
    final Color fg = selected
        ? Color.lerp(apple.label, apple.accent, s)!
        : apple.label;
    // 失焦窗口的源列表图标退成次要灰（macOS 同）。
    final Color sideIcon = windowActive ? apple.accent : apple.secondaryLabel;
    final Color iconColor = Color.lerp(sideIcon, apple.accent, s)!;
    final double radius =
        _kAppleSidebarRowRadius * k +
        (_kAppleTabCellHeight / 2 - _kAppleSidebarRowRadius * k) * s;
    final double labelOpacity = iconOnly ? (1 - s * 2).clamp(0.0, 1.0) : 1;
    // 选中 / 悬停底色的补间只在两端静止时播；变形途中逐帧插值，不叠补间。
    final bool settled = t <= 0 || t >= 1;
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
            // 悬停：比选中浅一阶的中性底（quaternarySystemFill 量级）。
            hover: apple.tertiaryFill.withValues(
              alpha: apple.tertiaryFill.a * 0.6,
            ),
            radius: radius,
            // 侧栏端（s = 0）乘 macOS 档系数，标签栏端（s = 1）不变。
            padding: 8 * k + (12 - 8 * k) * s,
            gap: 7 * k + (6 - 7 * k) * s,
            iconSize:
                _kAppleSidebarIconSize * k +
                (18 - _kAppleSidebarIconSize * k) * s,
            iconColor: iconColor,
            fillDuration: settled
                ? fushiMotionDuration(context, FushiMotion.short)
                : Duration.zero,
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

/// macOS 27（Golden Gate）的贴边侧栏底：紧贴窗口边、无外边距 / 圆角 / 投影 /
/// 抬起，末端（LTR 右缘）一条 0.5 px `separator` 发丝线与内容区分开。
///
/// 材质跟随「玻璃画质」（[glassMaterialOf]）：
/// - 实色档：系统材质实色（[fushiGlassFill] 的 off 档，深 #1C1C1E / 浅
///   #F9F9F9，即 secondarySystemBackground 量级），无模糊无着色器；
/// - 其余档：自带一层的平面库玻璃（[GlassContainer] 直角、`shadowElevation: 0`，
///   参数取 [fushiGlassSettings]，静态主表面按 prominent 口径取档）。库没有
///   侧栏组件，这是最贴近的「平铺背景玻璃」。
///
/// 宽窗口侧栏（[AppleSidebarTabsShell]）与 medium 窄条（`_NavSurfaceBackdrop`）
/// 共用这一块。
class AppleEdgeSidebarSurface extends StatelessWidget {
  const AppleEdgeSidebarSurface({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final Widget hairline = DecoratedBox(
      decoration: BoxDecoration(
        border: BorderDirectional(
          end: BorderSide(color: apple.separator, width: 0.5),
        ),
      ),
    );
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return DecoratedBox(
        decoration: BoxDecoration(color: fushiGlassFill(context)),
        child: hairline,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        GlassContainer(
          // premium 档必须自带 LiquidGlassLayer（BUG-2957）。
          useOwnLayer: true,
          shape: const LiquidRoundedSuperellipse(borderRadius: 0),
          quality: fushiGlassQuality(context, prominent: true),
          // macOS 27 侧栏是贴边的磨砂材质（vibrancy），不是一块悬浮玻璃：
          // 没有镜面高光、菲涅尔亮边与边缘折射，只留模糊与底色。
          settings: fushiGlassSettings(context).copyWith(
            shadowElevation: 0,
            thickness: 0,
            lightIntensity: 0,
            ambientRim: 0,
            fresnelStrength: 0,
            chromaticAberration: 0,
          ),
          child: const SizedBox.expand(),
        ),
        hairline,
      ],
    );
  }
}

/// 窗口是否处于前台激活（桌面端失焦时引擎报 [AppLifecycleState.inactive]）：
/// macOS 源列表在窗口失焦时把选中底与图标都退淡，侧栏照做。
class _AppleWindowActiveBuilder extends StatefulWidget {
  const _AppleWindowActiveBuilder({required this.builder});

  final Widget Function(BuildContext context, bool active) builder;

  @override
  State<_AppleWindowActiveBuilder> createState() =>
      _AppleWindowActiveBuilderState();
}

class _AppleWindowActiveBuilderState extends State<_AppleWindowActiveBuilder>
    with WidgetsBindingObserver {
  late bool _active = _isActive(WidgetsBinding.instance.lifecycleState);

  static bool _isActive(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool active = _isActive(state);
    if (active != _active) setState(() => _active = active);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _active);
}

class _AppleSidebarSectionHeader extends StatelessWidget {
  const _AppleSidebarSectionHeader({
    required this.title,
    required this.shut,
    required this.color,
    required this.chevronColor,
    required this.onTap,
  });

  final String title;
  final bool shut;
  final Color color;

  /// 折叠箭头色（比标题再淡一阶）。
  final Color chevronColor;
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
            // 标题贴行的图标起点对齐，上方多留一点与上一组分开。
            padding: const EdgeInsetsDirectional.only(start: 8, end: 6, top: 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(
                      fontSize:
                          _kAppleSidebarSectionFontSize *
                          fushiAppleMacScale(context),
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
                    size: 14,
                    color: chevronColor,
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
    required this.gap,
    required this.iconSize,
    required this.iconColor,
    required this.fillDuration,
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

  /// 图标与标签之间的距离。
  final double gap;
  final double iconSize;
  final Color iconColor;

  /// 选中 / 悬停底色切换的补间时长（变形途中为零）。
  final Duration fillDuration;
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
                  child: AnimatedContainer(
                    duration: widget.fillDuration,
                    curve: FushiMotion.standard,
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
                                SizedBox(width: widget.gap),
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

/// 标记子树在 Apple 宽窗侧栏外壳（[AppleSidebarTabsShell]）的内容区里：内容区
/// 从窗口上沿铺起，MediaQuery 顶部 padding 是窗口按钮行（桌面自绘标题行）的
/// 让位，页面自己决定让不让（整页底色 / 侧栏底铺到顶、内容排在 padding 下）。
/// 外壳里只为它画顶栏的页面（首页外壳的大标题条、各 tab）据此把让位还给自己。
/// 纯布局标记，与设计系统分派无关。
class AppleSidebarTopBleed extends InheritedWidget {
  const AppleSidebarTopBleed({required super.child, super.key});

  /// [context] 是否在侧栏外壳的内容区里。
  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppleSidebarTopBleed>() !=
      null;

  @override
  bool updateShouldNotify(AppleSidebarTopBleed oldWidget) => false;
}
