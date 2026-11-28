import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/second_screen/companion/companion_context.dart'
    show companionSettingsHomeCategory;
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/settings/settings_recent_destinations.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_search_sheet.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiHeightReporter, FushiTopFadeScrim;
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show shellRedesignActive;
import 'package:fushi/src/utils/components/fushi_static_masthead.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AppleEdgeSidebarSurface;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show FushiSidePaneScrollScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show
        FushiAppleLargeTitle,
        FushiAppleNavBar,
        FushiAppleSoftScrollEdge,
        fushiAppleInlineTitleOpacity,
        fushiAppleLargeTitleBand,
        fushiAppleLargeTitleOpacity;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleGroupSurface;
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';

class SettingsHomePage extends BasePage {
  const SettingsHomePage({super.key, this.embedded = false});

  final bool embedded;

  @override
  BasePageState<SettingsHomePage> createState() => _SettingsHomePageState();
}

class _SettingsHomePageState extends BasePageState<SettingsHomePage>
    with SettingsContextHost<SettingsHomePage> {
  // 默认选中 schema 首个可见分类（当前为「外观与交互」），与宽屏导航列表的
  // 视觉首项一致：不再硬编码某个 id——分类顺序的唯一真相源是 buildSettingsSchema
  // （有顺序守卫），这里在 build 里首次解析时取 destinations.first.id，顺序调整
  // 时默认项自动跟随，不会再脱节。分块渲染同样不改顺序（groupSettingsDestinations
  // 只切段），故首项仍是视觉首项。
  SettingsDestinationId? _selectedDestinationId;

  // 设置搜索：跨全部分类按标题/副标题/分区/分类名过滤配置项，点结果跳转到
  // 对应分类并滚动定位（SettingsSearchReveal）。
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(debugLabel: 'settings-search');
  final ScrollController _narrowScrollController = ScrollController();
  String _searchQuery = '';

  /// M3E 窄屏浮动页头（展开态）的实测高度：页头叠放在分类列表上，列表顶部
  /// 内边距让开这一段，往下滚时内容滚到页头胶囊底下。
  ///
  /// notifier 而不是 setState：滚回顶部时页头弹簧展开，高度逐帧回报；setState
  /// 会逐帧重建整个设置主页（宽屏还连带整块详情窗格）。现在只重建滚动视图的
  /// 内边距与渐隐层，分类列表是同一个实例。
  final ValueNotifier<double> _narrowHeaderHeight = ValueNotifier<double>(0);

  /// 窄屏分类列表已滚离顶部：驱动共享顶部渐隐。
  final ValueNotifier<bool> _narrowScrolledUnder = ValueNotifier<bool>(false);

  void _onNarrowHeaderHeight(double height) {
    if (!mounted || height == _narrowHeaderHeight.value) return;
    // 只在展开态（与 SettingsFloatingHeader 同一阈值）记高度：收缩态胶囊高度
    // 不同，跟着改让位会让列表在滚动中跳一下。
    final bool atRest =
        !_narrowScrollController.hasClients ||
        _narrowScrollController.positions.first.pixels <= 12;
    if (_narrowHeaderHeight.value > 0 && !atRest) return;
    _narrowHeaderHeight.value = height;
  }

  void _onNarrowScroll() {
    _narrowScrolledUnder.value =
        _narrowScrollController.hasClients &&
        _narrowScrollController.positions.first.pixels > 0;
  }

  /// 当前搜索结果（build 时求值；回车打开第一条用）。
  List<SettingsSearchEntry> _results = const <SettingsSearchEntry>[];

  /// 上一次 build 时是不是宽屏主从（消费 [settingsDestinationRequest] 时据此决定
  /// 是切右窗格还是推详情页）。
  bool _wide = false;

  /// 上一次 build 求出的可见分类。
  List<SettingsDestination> _destinations = const <SettingsDestination>[];

  @override
  void initState() {
    super.initState();
    _narrowScrollController.addListener(_onNarrowScroll);
    settingsDestinationRequest.addListener(_onDestinationRequested);
    // 设置 tab 还没挂载时就发来的请求：挂载后第一帧消费（那时才知道宽窄）。
    if (settingsDestinationRequest.value != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onDestinationRequested(),
      );
    }
    // 错误 / 调试日志、游戏内查词准入、推荐包下载阶段（BUG-2165：宽屏内联主从
    // 同样要实时刷新）由读它们的分组自己订阅（SettingsSection.liveListenable），
    // 内联详情与 push 出去的详情页走同一套分组组件，宿主页不再整页 setState。
  }

  /// What [companionSettingsHomeCategory] should say for this page; applied
  /// after the frame (the registry notifies the companion bridge).
  String? _companionCategory;
  bool _companionCategoryScheduled = false;

  /// Two-pane layout: the companion's Settings tab shows the category in the
  /// detail pane first (same as for a pushed settings page).
  void _publishCompanionCategory(String? category) {
    _companionCategory = category;
    if (_companionCategoryScheduled ||
        companionSettingsHomeCategory.value == category) {
      return;
    }
    _companionCategoryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _companionCategoryScheduled = false;
      if (!mounted) return;
      companionSettingsHomeCategory.value = _companionCategory;
    });
  }

  @override
  void dispose() {
    if (companionSettingsHomeCategory.value != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (Duration _) => companionSettingsHomeCategory.value = null,
      );
    }
    settingsDestinationRequest.removeListener(_onDestinationRequested);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _narrowScrollController.removeListener(_onNarrowScroll);
    _narrowScrollController.dispose();
    _glassScrollController.dispose();
    _narrowScrolledUnder.dispose();
    _narrowHeaderHeight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext = createSettingsContext(
      appModel: appModel,
      ref: ref,
    );
    final List<SettingsDestination> destinations =
        buildSettingsSchema(settingsContext)
            .where(
              (SettingsDestination destination) =>
                  destination.isVisible(settingsContext),
            )
            .toList(growable: false);
    _destinations = destinations;
    // 首次进入（null）或当前选中分类被平台门控隐藏时，落到第一个可见分类。
    if (!destinations.any(
      (SettingsDestination destination) =>
          destination.id == _selectedDestinationId,
    )) {
      _selectedDestinationId = destinations.first.id;
    }
    final SettingsDestinationId selectedDestinationId = _selectedDestinationId!;
    final bool glass = isGlassDesign(context);
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kFushiSettingsHomeTwoPaneMinWidth;
        _wide = wide;
        _publishCompanionCategory(wide ? selectedDestinationId.name : null);
        // 「玻璃」设计系统：整套重排成 macOS「系统设置」（宽）/ iOS「设置」
        // （窄），见 [GlassSettingsRenderer]。
        if (glass) {
          return wide
              ? _buildGlassWideLayout(
                  settingsContext: settingsContext,
                  destinations: destinations,
                  selectedDestinationId: selectedDestinationId,
                )
              : _buildGlassNarrowLayout(
                  settingsContext: settingsContext,
                  destinations: destinations,
                );
        }
        // MD3：Android 16「设置」。宽屏左导航右详情（不另画「设置」页头），窄屏是自带
        // 折叠大标题顶栏的单列（不再套外壳页头，见 _buildMd3NarrowLayout）。
        return wide
            ? _buildMd3WideLayout(
                settingsContext: settingsContext,
                destinations: destinations,
                selectedDestinationId: selectedDestinationId,
              )
            : _buildMd3NarrowLayout(
                settingsContext: settingsContext,
                destinations: destinations,
              );
      },
    );
    // Apple（玻璃）窄屏自己画 iOS 导航栏 + 大标题，不再叠页头大字。
    if (!_mastheadHeader || glass) return content;
    // 重设计外壳：窄屏单列顶部一行页头大字（与库页同一套），下面是原版面；各
    // 版式自己的「设置」标题（MD3 窄屏浮动页头、玻璃窄屏 iOS 大标题）在
    // [_mastheadHeader] 下都不再画。
    //
    // 宽屏主从不画这一行：右窗格的分类页自己有页头大字（「外观与交互」等），
    // 上面再叠一行「设置」就是两个大标题，右半边还空出一整条。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kFushiSettingsHomeTwoPaneMinWidth;
        if (wide) return content;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiStaticMasthead(
              key: const ValueKey<String>('settings_home_masthead'),
              title: t.settings,
            ),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  /// 首页外壳里的设置 tab 在重设计外壳下用页头大字（[FushiStaticMasthead]）做
  /// 页头；独立推出来的设置页（非嵌入）与墨水屏保持原页头。
  bool get _mastheadHeader => widget.embedded && shellRedesignActive(context);

  /// 点搜索结果：登记滚动定位挂点、清空搜索，宽屏切主从选中分类，窄屏 push
  /// 详情页；目标行由 SettingsSchemaItem 消费挂点后滚入视口并闪烁高亮。
  /// 正文条目仅在已声明真实挂点时登记定位请求，避免遗留未消费的目标。
  void _openSearchResult(SettingsSearchEntry entry, {required bool wide}) {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      if (wide) _selectedDestinationId = entry.destination.id;
    });
    unawaited(
      recordSettingsDestinationVisit(appModel.prefsRepo, entry.destination.id),
    );
    // 宽屏右窗格已切到该分类，只需再推子页；窄屏连顶层分类页一起推。
    openSettingsSearchEntry(Navigator.of(context), entry, pushTopLevel: !wide);
  }

  /// 玻璃窄屏的滚动位置：驱动大标题 / 小标题交叉淡变与栏下沿 scroll edge。
  /// `late`：热重载时已存在的 State 也能建出来。
  late final ScrollController _glassScrollController = ScrollController();

  /// 设置搜索栏（M3E 胶囊 / Apple 液态玻璃胶囊，见 [SettingsSearchBar]）。回车
  /// 打开第一条结果，↓ 把焦点交给结果列表。
  Widget _buildKitSearchBar({required bool wide}) {
    return SettingsSearchBar(
      controller: _searchController,
      focusNode: _searchFocusNode,
      onChanged: (String value) => setState(() => _searchQuery = value),
      onSubmitted: (_) {
        if (_results.isEmpty) return;
        _openSearchResult(
          _results.first,
          // 与实际布局共用窄 / 宽判据；嵌入页的可用宽度可能小于整窗宽度。
          wide: wide,
        );
      },
      onArrowDown: () => FocusManager.instance.primaryFocus?.focusInDirection(
        TraversalDirection.down,
      ),
    );
  }

  /// 求当前查询的结果（同时记进 [_results] 供回车使用）。
  List<SettingsSearchEntry> _searchResults(
    SettingsContext settingsContext,
    List<SettingsDestination> destinations,
  ) {
    _results = _searchQuery.trim().isEmpty
        ? const <SettingsSearchEntry>[]
        : filterSettingsEntries(
            flattenVisibleSettings(destinations, settingsContext),
            _searchQuery,
          );
    return _results;
  }

  /// 统一的搜索结果视图（两套设计系统共用 [SettingsSearchResultsView]）：按
  /// 分类分组、命中高亮、错峰进场；空结果是空状态插画。
  Widget _buildKitSearchResults({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required bool wide,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    bool shrinkWrap = false,
  }) {
    return SettingsSearchResultsView(
      results: _searchResults(settingsContext, destinations),
      query: _searchQuery,
      padding: padding,
      shrinkWrap: shrinkWrap,
      onOpen: (SettingsSearchEntry entry) =>
          _openSearchResult(entry, wide: wide),
    );
  }

  /// 玻璃宽屏 = macOS 26「系统设置」：左栏（胶囊搜索框 + 分类侧栏，直接坐在
  /// 页面底上、无卡片外框）+ 右栏详情（分类大标题 + 封顶宽度的分组卡）。
  Widget _buildGlassWideLayout({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
  }) {
    final SettingsDestination selected = destinations.firstWhere(
      (SettingsDestination destination) =>
          destination.id == selectedDestinationId,
    );
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final SettingsRenderer renderer = resolveSettingsRenderer(
      context,
      showDetailHeader: true,
    );
    final bool searching = _searchQuery.trim().isNotEmpty;
    return MaterialSupportingPaneLayout(
      minSplitWidth: kFushiSettingsHomeTwoPaneMinWidth,
      supportingSide: SupportingPaneSide.start,
      supportingWidth:
          GlassSettingsRenderer.sidebarWidth +
          _wideNavPanelExtraWidth(FushiDesignTokens.of(context)),
      showDivider: false,
      // macOS 27 系统设置：设置的二级侧栏与主侧栏同一侧栏材质（玻璃随画质档位、
      // 实色档是实色侧栏底，右缘 0.5 px separator），详情窗格是窗口底。背景图
      // 在画时侧栏改成浮在图上的分组卡（[_wideNavPanel]），不再垫侧栏底。
      supporting: FushiSidePaneScrollScope(
        child: _glassSidebarBackdrop(
          Padding(
            // 侧栏底从窗口顶画起（[_glassSidebarBackdrop]，Apple 宽窗外壳把设置
            // tab 铺到窗口顶、顶部让位以 MediaQuery padding 交下来，见 home_page
            // `_appleSidebarTopInsetFor`），搜索框与分类排在让位（窗口按钮行）下面。
            padding: EdgeInsets.only(
              top: mediaPadding.top,
              bottom: mediaPadding.bottom,
            ),
            child: _wideNavPanel(
              FushiDesignTokens.of(context),
              glass: true,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    child: _buildKitSearchBar(wide: true),
                  ),
                  // 搜索时侧栏保持分类列表（不再把结果塞进 240 宽的侧栏），结果
                  // 占满右侧详情窗格。
                  Expanded(
                    child: _navListEdgeFade(
                      renderer.buildDestinationList(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        selectedDestinationId: selectedDestinationId,
                        onDestinationSelected: _selectDestination,
                        pushRoutes: false,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      // 详情窗格按 destination id 编码身份（同 MD3 分支的 KeyedSubtree 说明）。
      primary: searching
          ? _buildKitSearchResults(
              settingsContext: settingsContext,
              destinations: destinations,
              wide: true,
              padding: EdgeInsets.fromLTRB(
                GlassSettingsRenderer.detailHorizontalInset(context),
                16 + mediaPadding.top,
                GlassSettingsRenderer.detailHorizontalInset(context),
                24 + mediaPadding.bottom,
              ),
            )
          : KeyedSubtree(
              key: ValueKey<SettingsDestinationId>(selected.id),
              child: renderer.buildDetailContent(
                settingsContext: settingsContext,
                destination: selected,
              ),
            ),
    );
  }

  /// 玻璃窄屏 = iOS 26「设置」：大标题 + 搜索框 + 分组分类列表，三者在同一个
  /// 滚动视图里（大标题随内容滚走）；点分类 push 详情页。
  Widget _buildGlassNarrowLayout({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
  }) {
    final SettingsRenderer renderer = resolveSettingsRenderer(context);
    final double inset = GlassSettingsRenderer.detailHorizontalInset(context);
    final double band = fushiAppleLargeTitleBand(context);
    final ScrollController controller = _glassScrollController;
    double progress() => controller.hasClients
        ? (controller.positions.first.pixels / band).clamp(0.0, 1.0)
        : 0;
    final Widget body = SingleChildScrollView(
      controller: controller,
      padding: EdgeInsets.fromLTRB(
        inset,
        0,
        inset,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      // 全宽（用户 2026-10-04）：不封顶、不居中，只留常规左右留白。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // iOS 大标题：随内容滚走、交叉淡变成导航栏里的居中小标题。
          SizedBox(
            height: band,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 4),
              child: ListenableBuilder(
                listenable: controller,
                builder: (BuildContext context, Widget? title) => Opacity(
                  opacity: fushiAppleLargeTitleOpacity(progress()),
                  child: title,
                ),
                child: FushiAppleLargeTitle(title: t.settings),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 18),
            child: _buildKitSearchBar(wide: false),
          ),
          if (_searchQuery.trim().isEmpty)
            renderer.buildDestinationGroups(
              settingsContext: settingsContext,
              destinations: destinations,
              onDestinationSelected: _selectDestination,
            )
          else
            _buildKitSearchResults(
              settingsContext: settingsContext,
              destinations: destinations,
              wide: false,
              shrinkWrap: true,
            ),
        ],
      ),
    );
    // iOS 27「设置」：透明导航栏（非嵌入时带玻璃返回钮）+ 大标题在内容里；
    // 内容滚到栏下面时栏下沿是库的 soft scroll edge。
    final Widget page = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiAppleNavBar(
          automaticallyImplyLeading: !widget.embedded,
          title: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? child) {
              final double o = fushiAppleInlineTitleOpacity(progress());
              return ExcludeSemantics(
                excluding: o == 0,
                child: Opacity(opacity: o, child: child),
              );
            },
            child: Text(t.settings),
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: PrimaryScrollController(
                  controller: controller,
                  child: body,
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (BuildContext context, Widget? _) =>
                      FushiAppleSoftScrollEdge(
                        visible:
                            controller.hasClients &&
                            controller.positions.first.pixels > 0,
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return page;
    return Scaffold(body: page);
  }

  /// 宽屏左栏（搜索框 + 分类列表）的底：平时直接坐在页面底上；页底是用户的
  /// 自定义图片时垫一张与右侧分组卡同色的半透明卡——侧栏的行文字、分组小标题
  /// 直接压在图上，对比度随图片明暗忽高忽低（2026-11-20 用户截图：樱花壁纸上
  /// 侧栏字发糊）。右侧本来就是「卡片浮在图上」，左栏跟着成卡，两边同一语言：
  /// MD3 用分组卡同款 [FushiCard]（`surfaces.card`、`groupRadius`），玻璃用
  /// Apple 分组面 [FushiAppleGroupSurface]（secondaryGroupedBackground、连续曲率
  /// 圆角），与各自右侧详情的分组卡同一材质。
  Widget _wideNavPanel(
    FushiDesignTokens tokens,
    Widget child, {
    required bool glass,
  }) {
    if (!FushiPageBackdrop.imageOf(context)) return child;
    return Padding(
      key: const ValueKey<String>('settings_wide_nav_panel'),
      padding: EdgeInsets.fromLTRB(
        _wideNavPanelExtraWidth(tokens),
        tokens.spacing.gap,
        0,
        tokens.spacing.page,
      ),
      child: glass
          ? FushiAppleGroupSurface(child: child)
          : FushiCard(
              padding: EdgeInsets.zero,
              borderRadius: tokens.radii.groupRadius,
              color: tokens.surfaces.card.withValues(alpha: 0.9),
              child: child,
            ),
    );
  }

  /// 玻璃宽屏二级侧栏的侧栏底（[AppleEdgeSidebarSurface]，与主侧栏同一块）；
  /// 背景图在画时原样返回 [child]（侧栏是浮在图上的分组卡）。
  Widget _glassSidebarBackdrop(Widget child) {
    if (FushiPageBackdrop.imageOf(context)) return child;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const Positioned.fill(child: AppleEdgeSidebarSurface()),
        child,
      ],
    );
  }

  /// [_wideNavPanel] 的卡左外边距：左栏按这一段加宽，卡里的搜索框与分类行
  /// 仍是原来的宽度（不然搜索提示被截成「Search settin…」、长分类名折行）。
  double _wideNavPanelExtraWidth(FushiDesignTokens tokens) =>
      FushiPageBackdrop.imageOf(context) ? tokens.spacing.gap : 0;

  /// 分类列表两端柔和淡出：往下滚时行从搜索框下面渐隐，而不是被一刀切成半个
  /// 图标（2026-11-20 用户截图：首行「导航与首页」半截压在搜索框下）。
  /// [FushiHorizontalEdgeFade] 只淡**还有内容**的那一端：停在顶端时上沿不淡、
  /// 首行完整；下面还有分类时下沿同样淡出，提示还能往下滚，滚到底就不淡。
  Widget _navListEdgeFade(Widget list) =>
      FushiHorizontalEdgeFade(axis: Axis.vertical, extent: 28, child: list);

  /// MD3 宽屏 = Android 16 平板「设置」：左栏 300（胶囊搜索栏 + 导航抽屉式
  /// 分类列表，直接坐在页面底上）+ 右栏详情（分类大标题 + 全宽分段分组列表）。
  Widget _buildMd3WideLayout({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
  }) {
    final SettingsDestination selected = destinations.firstWhere(
      (SettingsDestination destination) =>
          destination.id == selectedDestinationId,
    );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final SettingsRenderer renderer = resolveSettingsRenderer(
      context,
      showDetailHeader: true,
    );
    return MaterialSupportingPaneLayout(
      minSplitWidth: kFushiSettingsHomeTwoPaneMinWidth,
      supportingSide: SupportingPaneSide.start,
      supportingWidth:
          MaterialSettingsRenderer.navPaneWidth +
          _wideNavPanelExtraWidth(tokens),
      showDivider: false,
      // 左栏是固定版面（搜索框 + 分类列表）：整体让开系统状态栏。
      supporting: FushiSidePaneScrollScope(
        child: SafeArea(
          bottom: false,
          child: Padding(
            // 外层 SafeArea 已让开顶部，这里只让底部。
            padding: EdgeInsets.only(bottom: mediaPadding.bottom),
            child: _wideNavPanel(
              tokens,
              glass: false,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.gap + 4,
                      tokens.spacing.gap,
                      tokens.spacing.gap + 4,
                      tokens.spacing.gap,
                    ),
                    child: _buildKitSearchBar(wide: true),
                  ),
                  // 搜索时左栏保持分类列表，结果占满右侧详情窗格（此前结果挤在 240
                  // 宽的左栏里，标题两行就截断，右侧详情却空着）。
                  Expanded(
                    child: _navListEdgeFade(
                      renderer.buildDestinationList(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        selectedDestinationId: selectedDestinationId,
                        onDestinationSelected: _selectDestination,
                        pushRoutes: false,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      // 详情窗格按 destination id 编码身份（同 _buildWideLayout 的 KeyedSubtree
      // 说明）。全宽：不封顶、不居中（用户 2026-10-04）。
      // 搜索结果的内边距按 State context 算、读不到状态栏让位：整体让开。
      primary: _searchQuery.trim().isNotEmpty
          ? SafeArea(
              bottom: false,
              child: _buildKitSearchResults(
                settingsContext: settingsContext,
                destinations: destinations,
                wide: true,
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.card,
                  tokens.spacing.page,
                  tokens.spacing.page + mediaPadding.bottom,
                ),
              ),
            )
          : KeyedSubtree(
              key: ValueKey<SettingsDestinationId>(selected.id),
              child: renderer.buildDetailContent(
                settingsContext: settingsContext,
                destination: selected,
              ),
            ),
    );
  }

  /// M3E 窄屏：浮动页头（返回 + 「设置」标题胶囊，随滚动收缩成浮在内容上的
  /// 胶囊）+ 胶囊搜索栏 + 分段分组的分类列表（彩色形状图标块），点分类 push
  /// 详情页。自绘桌面顶栏已经显示标题时不再画页头（两个「设置」）。
  Widget _buildMd3NarrowLayout({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SettingsRenderer renderer = resolveSettingsRenderer(context);
    final bool showHeader =
        (!widget.embedded || !FushiDesktopTitleBar.isEnabled) &&
        !_mastheadHeader;
    final bool searching = _searchQuery.trim().isNotEmpty;
    final Widget body = searching
        ? _buildKitSearchResults(
            settingsContext: settingsContext,
            destinations: destinations,
            wide: false,
            shrinkWrap: true,
          )
        : renderer.buildDestinationGroups(
            settingsContext: settingsContext,
            destinations: destinations,
            onDestinationSelected: _selectDestination,
          );
    final double bottomPadding =
        tokens.spacing.page + MediaQuery.of(context).padding.bottom;
    final Widget scroll = ValueListenableBuilder<double>(
      valueListenable: _narrowHeaderHeight,
      // 非懒加载：分类列表短而有界，全部常驻，Tab 能绕回视口外的分类。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card),
            child: _buildKitSearchBar(wide: false),
          ),
          body,
        ],
      ),
      builder: (BuildContext context, double headerHeight, Widget? column) =>
          SingleChildScrollView(
            controller: _narrowScrollController,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              // 页头叠放在列表上：首屏让开页头（实测高度），往下滚时内容滚到页头
              // 胶囊底下（2026-10-06 结构收口：此前页头与列表上下排，下沿硬切）。
              showHeader ? headerHeight : tokens.spacing.gap,
              tokens.spacing.page,
              bottomPadding,
            ),
            child: column,
          ),
    );
    // 整页底色（不是顶部底带）：本页是 home tab，没有 Scaffold 提供底色与 ink。
    return Material(
      color: fushiPageBackgroundColor(context),
      child: !showHeader
          ? scroll
          : Stack(
              children: <Widget>[
                Positioned.fill(child: scroll),
                // 顶部可读性只靠共享渐隐（从顶端跨过整条页头降到 0），只在
                // 列表滚到页头底下时出现，不画实色底带。
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ListenableBuilder(
                    listenable: Listenable.merge(<Listenable>[
                      _narrowScrolledUnder,
                      _narrowHeaderHeight,
                    ]),
                    builder: (BuildContext context, Widget? _) =>
                        AnimatedOpacity(
                          opacity: _narrowScrolledUnder.value ? 1 : 0,
                          duration: fushiMotionDuration(
                            context,
                            FushiMotion.short,
                          ),
                          // 与 SettingsKitScaffold 同口径：实色盖满页头让位，
                          // 再往下渐隐（2026-10-09 用户截图：页头背后透出正文）。
                          child: FushiTopFadeScrim(
                            solidHeight: _narrowHeaderHeight.value,
                            topOpacity: 1,
                          ),
                        ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: FushiHeightReporter(
                    onHeight: _onNarrowHeaderHeight,
                    child: SettingsFloatingHeader(
                      key: const ValueKey<String>('settings_home_header'),
                      title: t.settings,
                      scrollController: _narrowScrollController,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  void _selectDestination(SettingsDestinationId id) {
    setState(() => _selectedDestinationId = id);
    unawaited(recordSettingsDestinationVisit(appModel.prefsRepo, id));
  }

  /// 消费 [settingsDestinationRequest]（首页侧栏「设置」速览卡点了某个分类）：
  /// 宽屏切右窗格，窄屏推该分类的详情页。分类此刻不可见（平台 / 模块门控）
  /// 就只清掉请求。
  void _onDestinationRequested() {
    final SettingsDestinationId? id = settingsDestinationRequest.value;
    if (id == null || !mounted) return;
    settingsDestinationRequest.value = null;
    final SettingsDestination? destination = _destinations
        .where((SettingsDestination d) => d.id == id)
        .firstOrNull;
    if (destination == null) return;
    _selectDestination(id);
    if (_wide) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsDetailPage(destination: destination),
        ),
      ),
    );
  }
}
