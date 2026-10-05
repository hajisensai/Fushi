import 'package:flutter/material.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/lookup/gal_ingame_lookup_controller.dart';
import 'package:flutter/cupertino.dart' show CupertinoSearchTextField;
import 'package:fushi/src/settings/cupertino_settings_renderer.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';

class SettingsHomePage extends BasePage {
  const SettingsHomePage({super.key, this.embedded = false, this.onBack});

  final bool embedded;

  /// 非空时在内嵌页头左侧显示返回箭头（宽屏全屏设置切回来源 tab）。
  final VoidCallback? onBack;

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
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    ErrorLogService.instance.addListener(_onLogChanged);
    DebugLogService.instance.addListener(_onLogChanged);
    // 游戏内查词准入是 hook **异步**报上来的：settingsContext.refresh 只由交互驱动，
    // 事件走不到它。不听这一条，用户开着设置页启动游戏时那一行永远停在旧状态。
    GalIngameLookupController.instance.admission.addListener(_onLogChanged);
    // 推荐包下载阶段同理，而且宽屏（>=720，Windows 桌面的主用形态）是**内联**
    // 主从：详情内容直接在本页渲染，走不到 [SettingsDetailPage] 那份订阅
    // （BUG-2165）。不听这一条，开着设置页时下载开始/下完/暂停，「推荐包」那一行
    // 的出现与消失就只能靠 AppModel 顺带 notify 撞上，变成偶发刷新。
    appModelNoUpdate.recommendedPackDownloadController.stage.addListener(
      _onLogChanged,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    ErrorLogService.instance.removeListener(_onLogChanged);
    DebugLogService.instance.removeListener(_onLogChanged);
    GalIngameLookupController.instance.admission.removeListener(_onLogChanged);
    appModelNoUpdate.recommendedPackDownloadController.stage.removeListener(
      _onLogChanged,
    );
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
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
    // 首次进入（null）或当前选中分类被平台门控隐藏时，落到第一个可见分类。
    if (!destinations.any(
      (SettingsDestination destination) =>
          destination.id == _selectedDestinationId,
    )) {
      _selectedDestinationId = destinations.first.id;
    }
    final SettingsDestinationId selectedDestinationId = _selectedDestinationId!;
    final SettingsRenderer renderer = isCupertinoPlatform(context)
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();

    final bool glass = isGlassDesign(context) && !isCupertinoPlatform(context);
    final bool md3 = !glass && !isCupertinoPlatform(context);
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 720;
        // MD3：Android 16「设置」。宽屏左导航右详情（页头外壳同旧），窄屏是自带
        // 折叠大标题顶栏的单列（不再套外壳页头，见 _buildMd3NarrowLayout）。
        if (md3) {
          return wide
              ? _buildEmbeddedShell(
                  _buildMd3WideLayout(
                    settingsContext: settingsContext,
                    destinations: destinations,
                    selectedDestinationId: selectedDestinationId,
                  ),
                )
              : _buildMd3NarrowLayout(
                  settingsContext: settingsContext,
                  destinations: destinations,
                );
        }
        // 「玻璃」设计系统：整套重排成 macOS「系统设置」（宽）/ iOS「设置」
        // （窄），见 [GlassSettingsRenderer]。MD3 / Cupertino 走下面原分支。
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
        if (wide) {
          // 宽屏主从：导航栏贴最左、详情填满整宽（平板友好，不再居中留白）。
          return _buildWideLayout(
            settingsContext: settingsContext,
            renderer: renderer,
            destinations: destinations,
            selectedDestinationId: selectedDestinationId,
          );
        }
        // 窄屏单列：居中限宽（单列阅读更舒适）。搜索时结果列表整体替换分类列表。
        return DesktopContentLayout(
          kind: DesktopContentKind.settings,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildSearchField(),
              Expanded(
                child: _searchQuery.trim().isEmpty
                    ? renderer.buildHomePage(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        selectedDestinationId: selectedDestinationId,
                        onDestinationSelected: _selectDestination,
                        embedded: widget.embedded,
                      )
                    : _buildSearchResults(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        wide: false,
                      ),
              ),
            ],
          ),
        );
      },
    );
    return md3 ? content : _buildEmbeddedShell(content);
  }

  /// [onNavCard] 为 true 时搜索框画在宽屏导航卡（`surfaces.card`，见
  /// [_buildWideLayout]）里：那里 `surfaces.search` 与卡底只差一档、几乎糊掉，故再
  /// 提一档到 `surfaces.overlay`，且横向内边距收成卡内的 `gap`；窄屏单列画在页面底
  /// （`surfaces.page`）上，保持 `surfaces.search` 与 `page` 内边距。
  Widget _buildSearchField({bool onNavCard = false}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double horizontal = onNavCard
        ? tokens.spacing.gap
        : tokens.spacing.page;
    // 搜索框与设置分组卡走同一套边界语言：填充分层，不描边。原来它吃全局
    // inputDecorationTheme 的 colorScheme.outline 描边——比分组卡的
    // outlineVariant 深一档，在同一屏里是第三种强度的线。
    //
    // eink 例外：填充在 eink scheme 下塌缩成背景色，描边是唯一的边界信号，
    // 那里把 enabled/focused 交回主题默认（enabledBorder/focusedBorder 传 null
    // 即回落主题；只覆盖 border 会被主题的 enabledBorder 顶掉）。
    final bool eink = isEinkTheme(context);
    final InputBorder flatBorder = OutlineInputBorder(
      // MD3 守卫：圆角一律走 design tokens，不自持字面量。
      borderRadius: tokens.radii.controlRadius,
      borderSide: BorderSide.none,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        tokens.spacing.gap,
        horizontal,
        0,
      ),
      // Material(transparency)：设置主页也会在 Cupertino 皮肤下渲染（隐藏内部
      // 能力），彼时树里没有 Material 祖先，裸 TextField 会 assert；透明 Material
      // 只提供 ink/装饰上下文，不改观感。
      child: Material(
        type: MaterialType.transparency,
        child: FushiTextFieldControl(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: t.settings_search_hint,
            prefixIcon: const FushiIcon(Icons.search),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : FushiIconButtonControl(
                    icon: const FushiIcon(Icons.clear),
                    tooltip: t.clear,
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
            isDense: true,
            filled: !eink,
            fillColor: eink
                ? null
                : (onNavCard
                      ? tokens.surfaces.overlay
                      : tokens.surfaces.search),
            border: eink
                ? OutlineInputBorder(
                    // MD3 守卫：圆角一律走 design tokens，不自持字面量。
                    borderRadius: tokens.radii.controlRadius,
                  )
                : flatBorder,
            enabledBorder: eink ? null : flatBorder,
            focusedBorder: eink
                ? null
                : OutlineInputBorder(
                    borderRadius: tokens.radii.controlRadius,
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
          ),
          onChanged: (String value) => setState(() => _searchQuery = value),
        ),
      ),
    );
  }

  Widget _buildSearchResults({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required bool wide,
  }) {
    final List<SettingsSearchEntry> results = filterSettingsEntries(
      flattenVisibleSettings(destinations, settingsContext),
      _searchQuery,
    );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    if (results.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Center(child: Text(t.settings_search_no_results)),
      );
    }
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    // 宽屏结果列表画在导航卡里：横向收成卡内 `gap`、底部不再叠系统栏内边距
    // （卡的外边距已经让出），结果分组也不再铺卡（卡中卡）。窄屏落在页面底上，
    // 保持原样。
    final double horizontal = wide ? tokens.spacing.gap : tokens.spacing.page;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        tokens.spacing.gap,
        horizontal,
        wide ? tokens.spacing.gap : tokens.spacing.page + mediaPadding.bottom,
      ),
      children: <Widget>[
        AdaptiveSettingsSection(
          surfaceColor: wide ? Colors.transparent : null,
          children: <Widget>[
            for (final SettingsSearchEntry entry in results)
              FushiListItem(
                leading: FushiIcon(entry.item.icon ?? entry.destination.icon),
                // custom 项经 searchTitle 入索引时 item.title 为空，展示用
                // entry.title（同打分口径）。
                title: Text(entry.title),
                titleMaxLines: 2,
                // 面包屑「分类 › 分区」——框架级去重：分区名为空或与分类同名时
                // 只显示分类（消灭「系统 › 系统」，见 settingsSearchBreadcrumb）。
                subtitle: Text(settingsSearchBreadcrumb(entry)),
                trailing: const FushiIcon(Icons.chevron_right),
                onTap: () => _openSearchResult(entry, wide: wide),
              ),
          ],
        ),
      ],
    );
  }

  /// 点搜索结果：登记滚动定位挂点、清空搜索，宽屏切主从选中分类，窄屏 push
  /// 详情页；目标行由 SettingsSchemaItem 消费挂点后滚入视口并闪烁高亮。
  /// 正文条目仅在已声明真实挂点时登记定位请求，避免遗留未消费的目标。
  void _openSearchResult(SettingsSearchEntry entry, {required bool wide}) {
    SettingsSearchReveal.pendingItemId = entry.hasRevealTarget
        ? entry.item.id
        : null;
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      if (wide) _selectedDestinationId = entry.destination.id;
    });
    final NavigatorState navigator = Navigator.of(context);
    if (!wide) {
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsDetailPage(destination: entry.destination),
        ),
      );
    }
    // 子 schema 页里的命中：父页之上再逐级推子页，挂点由最里层页面的目标行消费。
    for (final SettingsNavigationItem hop in entry.subPagePath) {
      final SettingsDestination Function() child = hop.child!;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsDetailPage.subPage(child),
        ),
      );
    }
  }

  Widget _buildEmbeddedShell(Widget content) {
    if (!widget.embedded) {
      return content;
    }
    // 自绘顶栏的桌面主窗口（Windows / macOS）已经由应用壳层提供当前 tab 标题；
    // 设置仍是普通 home tab，左侧主导航始终可见，因此无需再画第二条
    // 「返回 + 设置」页头。
    if (FushiDesktopTitleBar.isEnabled) {
      return content;
    }
    // Cupertino 手机（compact 走底栏导航、onBack 为空、无需返回出口）保持原生
    // 无页头观感，不强加 Material 风页头。只有桌面/平板全屏设置（隐藏图标侧栏、
    // 由 onBack 提供返回）才需补页头出口——这正是 BUG-009 R2 让 Cupertino 桌面
    // 从「无出口的三栏混排」恢复成「页头(返回) + 二栏」的地方。Material 维持其
    // 一贯页头（手机标题 / 桌面带返回箭头）。
    if (isCupertinoPlatform(context) && widget.onBack == null) {
      return content;
    }
    // 玻璃同理：没有返回出口时不画页头，大标题「设置」由窄屏布局自己画在
    // 滚动内容顶上（iOS 大标题随内容滚走），宽屏由详情窗格的分类大标题承担。
    if (isGlassDesign(context) && widget.onBack == null) {
      return content;
    }
    // 全屏嵌入设置统一加自绘页头 + 返回箭头；叶子设置控件仍由各自渲染器保持
    // Cupertino / Material 皮肤。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FushiPageHeader(
          title: t.settings,
          leading: widget.onBack != null
              ? FushiIconButtonControl(
                  icon: const FushiIcon(Icons.arrow_back),
                  tooltip: t.back,
                  onPressed: widget.onBack,
                )
              : null,
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildWideLayout({
    required SettingsContext settingsContext,
    required SettingsRenderer renderer,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
  }) {
    final SettingsDestination selected = destinations.firstWhere(
      (SettingsDestination destination) =>
          destination.id == selectedDestinationId,
    );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    // 窗格之间不画分隔线：BUG-2443 曾把导航窗格整块铺成 `surfaces.card` 底并保留
    // 1px 分隔线，让线两侧读出「两个窗格」；用户实机反馈（2026-09-20 截图）那条线
    // 本身多余——左边一整块贴边色块、右边一张分组卡、中间再夹一条竖线，接缝最扎眼。
    // 改成导航整块（搜索框 + 分类列表）装进一张与右侧分组卡**同款**的 FushiCard
    // （同色 `surfaces.card`、同圆角 `groupRadius`），外边距与右侧分组卡对齐：顶部
    // 同取 `gap`、离图标侧栏 `page`、与右侧分组卡之间留一个 `page`（右侧正文自带
    // 的左内边距，见 MaterialSettingsRenderer.detailHorizontalInsets）。这样左右
    // 都是「卡片浮在页面底上」，窗格边界由卡片自己表达，不需要线。
    return MaterialSupportingPaneLayout(
      minSplitWidth: 720,
      supportingSide: SupportingPaneSide.start,
      showDivider: false,
      supporting: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          0,
          tokens.spacing.page + mediaPadding.bottom,
        ),
        child: FushiCard(
          padding: EdgeInsets.zero,
          borderRadius: tokens.radii.groupRadius,
          color: tokens.surfaces.card,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildSearchField(onNavCard: true),
              Expanded(
                child: _searchQuery.trim().isEmpty
                    ? renderer.buildDestinationList(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        selectedDestinationId: selectedDestinationId,
                        onDestinationSelected: _selectDestination,
                        pushRoutes: false,
                      )
                    : _buildSearchResults(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        wide: true,
                      ),
              ),
            ],
          ),
        ),
      ),
      // 详情面板的身份就是当前 destination：用 KeyedSubtree 按 id 编码，
      // 切换目标时整棵子树作废重建，避免 Flutter 复用上一目标同位置的 Switch
      // Element 触发 didUpdateWidget(value 变化)→ 圆点滑动（以及分段滑动、滚动
      // 位置串页等同类复用副作用）。
      // 详情正文填满 pane 整宽：UI 巡检 PR-5 曾按 MD3 list-detail 惯例加过
      // 960 限宽 + 左对齐，用户实机反馈「右边空了一大堆」（2026-07-22 截图，
      // 4K 窗口下右侧 2400px 空白）——用户拍板回滚到填满整宽的原始形态。
      primary: KeyedSubtree(
        key: ValueKey<SettingsDestinationId>(selected.id),
        child: renderer.buildDetailContent(
          settingsContext: settingsContext,
          destination: selected,
        ),
      ),
    );
  }

  /// 玻璃窄屏是否自己画 iOS 大标题「设置」：只在没有任何别的页头时画
  /// （自绘桌面顶栏已经显示标题、带返回的全屏设置有 FushiPageHeader、
  /// 非嵌入用法由 FushiPageScaffold 出标题）。
  bool get _glassShowsLargeTitle =>
      widget.embedded &&
      widget.onBack == null &&
      !FushiDesktopTitleBar.isEnabled;

  /// iOS / macOS 26 胶囊搜索框：控件层，无色透明液态玻璃胶囊（不铺
  /// systemFill 灰底，Niratan 工具栏搜索同款）；桌面 13 号紧凑、触屏 17 号。
  /// 降低透明度时玻璃回落实色。
  Widget _buildGlassSearchField() {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = FushiAppleMetrics.of(context).desktop;
    final double radius = desktop ? 15 : 19;
    return fushiClearGlassBezel(
      context,
      radius: radius,
      child: _buildGlassSearchTextField(apple, desktop, radius),
    );
  }

  Widget _buildGlassSearchTextField(
    FushiAppleColors apple,
    bool desktop,
    double radius,
  ) {
    return CupertinoSearchTextField(
      controller: _searchController,
      placeholder: t.settings_search_hint,
      backgroundColor: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      itemColor: apple.secondaryLabel,
      itemSize: desktop ? 15 : 18,
      style: TextStyle(fontSize: desktop ? 13 : 17, color: apple.label),
      placeholderStyle: TextStyle(
        fontSize: desktop ? 13 : 17,
        color: apple.secondaryLabel,
      ),
      padding: desktop
          ? const EdgeInsetsDirectional.fromSTEB(4, 6, 6, 6)
          : const EdgeInsetsDirectional.fromSTEB(5, 9, 6, 9),
      onChanged: (String value) => setState(() => _searchQuery = value),
      onSuffixTap: () {
        _searchController.clear();
        setState(() => _searchQuery = '');
      },
    );
  }

  /// 玻璃搜索结果。宽屏画在侧栏里（侧栏行 + 面包屑），窄屏是一张 inset
  /// grouped 分组卡（图标 + 标题 + 面包屑 + chevron）。点击语义与 MD3 同一个
  /// [_openSearchResult]。
  Widget _buildGlassSearchResults({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required bool wide,
  }) {
    final List<SettingsSearchEntry> results = filterSettingsEntries(
      flattenVisibleSettings(destinations, settingsContext),
      _searchQuery,
    );
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            t.settings_search_no_results,
            textAlign: TextAlign.center,
            style: FushiAppleMetrics.of(context).footnoteStyle(context),
          ),
        ),
      );
    }
    if (wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final SettingsSearchEntry entry in results)
            GlassSettingsSidebarRow(
              icon: entry.item.icon ?? entry.destination.icon,
              title: entry.title,
              subtitle: settingsSearchBreadcrumb(entry),
              onTap: () => _openSearchResult(entry, wide: true),
            ),
        ],
      );
    }
    return AdaptiveSettingsSection(
      children: <Widget>[
        for (final SettingsSearchEntry entry in results)
          AdaptiveSettingsNavigationRow(
            title: entry.title,
            subtitle: settingsSearchBreadcrumb(entry),
            icon: entry.item.icon ?? entry.destination.icon,
            showIcon: true,
            onTap: () => _openSearchResult(entry, wide: false),
          ),
      ],
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
    const GlassSettingsRenderer renderer = GlassSettingsRenderer(
      showDetailHeader: true,
    );
    final bool searching = _searchQuery.trim().isNotEmpty;
    return MaterialSupportingPaneLayout(
      minSplitWidth: 720,
      supportingSide: SupportingPaneSide.start,
      supportingWidth: GlassSettingsRenderer.sidebarWidth,
      showDivider: false,
      supporting: Padding(
        padding: EdgeInsets.only(bottom: mediaPadding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: _buildGlassSearchField(),
            ),
            Expanded(
              child: searching
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                      child: _buildGlassSearchResults(
                        settingsContext: settingsContext,
                        destinations: destinations,
                        wide: true,
                      ),
                    )
                  : renderer.buildDestinationList(
                      settingsContext: settingsContext,
                      destinations: destinations,
                      selectedDestinationId: selectedDestinationId,
                      onDestinationSelected: _selectDestination,
                      pushRoutes: false,
                    ),
            ),
          ],
        ),
      ),
      // 详情窗格按 destination id 编码身份（同 MD3 分支的 KeyedSubtree 说明）。
      primary: KeyedSubtree(
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
    const GlassSettingsRenderer renderer = GlassSettingsRenderer();
    final FushiAppleColors apple = appleColorsOf(context);
    final double inset = GlassSettingsRenderer.detailHorizontalInset(context);
    final Widget body = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        inset,
        _glassShowsLargeTitle ? 4 : 12,
        inset,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      // 全宽（用户 2026-10-04）：不封顶、不居中，只留常规左右留白。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_glassShowsLargeTitle)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
              child: Text(
                t.settings,
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  letterSpacing: 0.4,
                  color: apple.label,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: _buildGlassSearchField(),
          ),
          if (_searchQuery.trim().isEmpty)
            renderer.buildDestinationGroups(
              settingsContext: settingsContext,
              destinations: destinations,
              onDestinationSelected: _selectDestination,
            )
          else
            _buildGlassSearchResults(
              settingsContext: settingsContext,
              destinations: destinations,
              wide: false,
            ),
        ],
      ),
    );
    if (widget.embedded) return body;
    return FushiPageScaffold(title: t.settings, body: body);
  }

  /// MD3 胶囊搜索栏（Android 16 设置顶部的 search bar）：全圆角、高 ≈ 52、
  /// surfaceContainerHigh 填充、无描边。墨水屏下填充塌缩成背景色，交回主题的
  /// 实描边作边界。
  Widget _buildMd3SearchBar() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    const BorderRadius capsule = BorderRadius.all(Radius.circular(28));
    const InputBorder flat = OutlineInputBorder(
      borderRadius: capsule,
      borderSide: BorderSide.none,
    );
    return Material(
      type: MaterialType.transparency,
      child: FushiTextFieldControl(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: t.settings_search_hint,
          prefixIcon: Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.spacing.rowHorizontal,
              end: tokens.spacing.gap,
            ),
            child: const FushiIcon(Icons.search),
          ),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : FushiIconButtonControl(
                  icon: const FushiIcon(Icons.clear),
                  tooltip: t.clear,
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
          contentPadding: EdgeInsets.symmetric(
            vertical: tokens.spacing.rowVertical + 4,
          ),
          filled: !eink,
          fillColor: eink ? null : tokens.surfaces.search,
          border: eink
              ? const OutlineInputBorder(borderRadius: capsule)
              : flat,
          enabledBorder: eink ? null : flat,
          focusedBorder: eink
              ? null
              : OutlineInputBorder(
                  borderRadius: capsule,
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  ),
                ),
        ),
        onChanged: (String value) => setState(() => _searchQuery = value),
      ),
    );
  }

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
    const MaterialSettingsRenderer renderer = MaterialSettingsRenderer(
      showDetailHeader: true,
    );
    return MaterialSupportingPaneLayout(
      minSplitWidth: 720,
      supportingSide: SupportingPaneSide.start,
      supportingWidth: MaterialSettingsRenderer.navPaneWidth,
      showDivider: false,
      supporting: Padding(
        padding: EdgeInsets.only(bottom: mediaPadding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.gap + 4,
                tokens.spacing.gap,
                tokens.spacing.gap + 4,
                tokens.spacing.gap,
              ),
              child: _buildMd3SearchBar(),
            ),
            Expanded(
              child: _searchQuery.trim().isEmpty
                  ? renderer.buildDestinationList(
                      settingsContext: settingsContext,
                      destinations: destinations,
                      selectedDestinationId: selectedDestinationId,
                      onDestinationSelected: _selectDestination,
                      pushRoutes: false,
                    )
                  : _buildSearchResults(
                      settingsContext: settingsContext,
                      destinations: destinations,
                      wide: true,
                    ),
            ),
          ],
        ),
      ),
      // 详情窗格按 destination id 编码身份（同 _buildWideLayout 的 KeyedSubtree
      // 说明）。全宽：不封顶、不居中（用户 2026-10-04）。
      primary: KeyedSubtree(
        key: ValueKey<SettingsDestinationId>(selected.id),
        child: renderer.buildDetailContent(
          settingsContext: settingsContext,
          destination: selected,
        ),
      ),
    );
  }

  /// MD3 窄屏 = Android 16「设置」：随滚动折叠的大标题顶栏「设置」+ 胶囊搜索栏
  /// + 分段分组的分类列表，点分类 push 详情页。自绘桌面顶栏已经显示标题时不再
  /// 画大标题顶栏（两个「设置」）；带返回出口的全屏设置在顶栏左侧放返回箭头。
  Widget _buildMd3NarrowLayout({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    const MaterialSettingsRenderer renderer = MaterialSettingsRenderer();
    final bool showAppBar =
        !widget.embedded || !FushiDesktopTitleBar.isEnabled;
    final List<SettingsSearchEntry> results = _searchQuery.trim().isEmpty
        ? const <SettingsSearchEntry>[]
        : filterSettingsEntries(
            flattenVisibleSettings(destinations, settingsContext),
            _searchQuery,
          );
    final Widget body;
    if (_searchQuery.trim().isEmpty) {
      body = renderer.buildDestinationGroups(
        settingsContext: settingsContext,
        destinations: destinations,
        onDestinationSelected: _selectDestination,
      );
    } else if (results.isEmpty) {
      body = Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Center(child: Text(t.settings_search_no_results)),
      );
    } else {
      body = AdaptiveSettingsSection(
        children: <Widget>[
          for (final SettingsSearchEntry entry in results)
            FushiListItem(
              leading: FushiIcon(entry.item.icon ?? entry.destination.icon),
              title: Text(entry.title),
              titleMaxLines: 2,
              subtitle: Text(settingsSearchBreadcrumb(entry)),
              onTap: () => _openSearchResult(entry, wide: false),
            ),
        ],
      );
    }
    // 底部导航直达的根设置页（没有返回出口）：M3 大标题栏的 64 高工具栏行
    // 只装返回箭头 / 操作，这里两样都没有，展开态等于标题上方一整行空白再加
    // 大标题区的余量（BUG-2959）。根页与书架等其它根 Tab 一样把标题放进
    // 工具栏行；带返回出口的全屏设置仍用大标题栏（工具栏行有箭头）。
    final bool rootPage = widget.onBack == null &&
        !(ModalRoute.of(context)?.impliesAppBarDismissal ?? false);
    return Material(
      color: tokens.surfaces.page,
      child: CustomScrollView(
        slivers: <Widget>[
          if (showAppBar && rootPage)
            SliverAppBar(
              key: const ValueKey<String>('settings_home_root_app_bar'),
              pinned: true,
              automaticallyImplyLeading: false,
              title: Text(t.settings),
              titleTextStyle: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
              backgroundColor: tokens.surfaces.page,
            )
          else if (showAppBar)
            SliverAppBar.large(
              title: Text(t.settings),
              backgroundColor: tokens.surfaces.page,
              automaticallyImplyLeading: widget.onBack == null,
              leading: widget.onBack == null
                  ? null
                  : FushiIconButtonControl(
                      icon: const FushiIcon(Icons.arrow_back),
                      tooltip: t.back,
                      onPressed: widget.onBack,
                    ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              showAppBar ? 0 : tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.page + MediaQuery.of(context).padding.bottom,
            ),
            // 非懒加载：分类列表短而有界，全部常驻，Tab 能绕回视口外的分类。
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.only(bottom: tokens.spacing.card),
                    child: _buildMd3SearchBar(),
                  ),
                  body,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _selectDestination(SettingsDestinationId id) {
    setState(() => _selectedDestinationId = id);
  }
}
