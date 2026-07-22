import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/settings/settings_search.dart';
import 'package:hibiki/utils.dart';

class SettingsHomePage extends BasePage {
  const SettingsHomePage({
    super.key,
    this.embedded = false,
    this.onBack,
  });

  final bool embedded;

  /// 非空时在内嵌页头左侧显示返回箭头（宽屏全屏设置切回来源 tab）。
  final VoidCallback? onBack;

  @override
  BasePageState<SettingsHomePage> createState() => _SettingsHomePageState();
}

class _SettingsHomePageState extends BasePageState<SettingsHomePage>
    with SettingsContextHost<SettingsHomePage> {
  // 默认选中 schema 首个可见分类（当前重排后是「阅读」），与宽屏导航列表的
  // 视觉首项一致：不再硬编码某个 id——分类顺序的唯一真相源是 buildSettingsSchema
  // （有顺序守卫），这里在 build 里首次解析时取 destinations.first.id，顺序调整
  // 时默认项自动跟随，不会再脱节。
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
  }

  @override
  void dispose() {
    _searchController.dispose();
    ErrorLogService.instance.removeListener(_onLogChanged);
    DebugLogService.instance.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final SettingsContext settingsContext =
        createSettingsContext(appModel: appModel, ref: ref);
    final List<SettingsDestination> destinations = buildSettingsSchema(
      settingsContext,
    )
        .where((SettingsDestination destination) =>
            destination.isVisible(settingsContext))
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

    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 720;
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
    return _buildEmbeddedShell(content);
  }

  Widget _buildSearchField() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      // Material(transparency)：设置主页也会在 Cupertino 皮肤下渲染（隐藏内部
      // 能力），彼时树里没有 Material 祖先，裸 TextField 会 assert；透明 Material
      // 只提供 ink/装饰上下文，不改观感。
      child: Material(
        type: MaterialType.transparency,
        child: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: t.settings_search_hint,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: t.clear,
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
            isDense: true,
            border: OutlineInputBorder(
              // MD3 守卫：圆角一律走 design tokens，不自持字面量。
              borderRadius: tokens.radii.controlRadius,
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    if (results.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: Center(child: Text(t.settings_search_no_results)),
      );
    }
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page + mediaPadding.bottom,
      ),
      children: <Widget>[
        AdaptiveSettingsSection(
          children: <Widget>[
            for (final SettingsSearchEntry entry in results)
              HibikiListItem(
                leading: Icon(entry.item.icon ?? entry.destination.icon),
                // custom 项经 searchTitle 入索引时 item.title 为空，展示用
                // entry.title（同打分口径）。
                title: Text(entry.title),
                titleMaxLines: 2,
                // 面包屑「分类 › 分区」——框架级去重：分区名为空或与分类同名时
                // 只显示分类（消灭「系统 › 系统」，见 settingsSearchBreadcrumb）。
                subtitle: Text(settingsSearchBreadcrumb(entry)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openSearchResult(entry, wide: wide),
              ),
          ],
        ),
      ],
    );
  }

  /// 点搜索结果：登记滚动定位挂点、清空搜索，宽屏切主从选中分类，窄屏 push
  /// 详情页；目标行由 SettingsSchemaItem 消费挂点后滚入视口并闪烁高亮。
  /// body 合成条目（bodySearchEntries）不登记挂点——body 行不是 schema item，
  /// 挂点永远不会被消费，跳转到分类正文即为完整语义。
  void _openSearchResult(SettingsSearchEntry entry, {required bool wide}) {
    SettingsSearchReveal.pendingItemId =
        entry.isBodyEntry ? null : entry.item.id;
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      if (wide) _selectedDestinationId = entry.destination.id;
    });
    if (!wide) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SettingsDetailPage(destination: entry.destination),
        ),
      );
    }
  }

  Widget _buildEmbeddedShell(Widget content) {
    if (!widget.embedded) {
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
    // 全屏嵌入设置统一加自绘页头 + 返回箭头；叶子设置控件仍由各自渲染器保持
    // Cupertino / Material 皮肤。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HibikiPageHeader(
          title: t.settings,
          leading: widget.onBack != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
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
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color dividerColor = cupertino
        ? CupertinoColors.separator.resolveFrom(context)
        : tokens.surfaces.outline;
    // MD3 list-detail: the nav pane sits on the tonal container token
    // (`surfaces.group`) while the detail pane stays on the base page surface.
    // Material only — Cupertino keeps its system background untouched.
    final Color? navPaneColor = cupertino ? null : tokens.surfaces.group;
    return MaterialSupportingPaneLayout(
      minSplitWidth: 720,
      supportingSide: SupportingPaneSide.start,
      dividerColor: dividerColor,
      supporting: Container(
        color: navPaneColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildSearchField(),
            Expanded(
              // Cupertino 的 buildDestinationList 是不可滚动的
              // CupertinoListSection（Material 自带 ListView）；分类数增长 +
              // 搜索框占高后，在有界 pane 里必须由外层补滚动，否则 RenderFlex
              // 溢出（BUG-009 同源）。
              child: _searchQuery.trim().isEmpty
                  ? (cupertino
                      ? SingleChildScrollView(
                          child: renderer.buildDestinationList(
                            settingsContext: settingsContext,
                            destinations: destinations,
                            selectedDestinationId: selectedDestinationId,
                            onDestinationSelected: _selectDestination,
                            pushRoutes: false,
                          ),
                        )
                      : renderer.buildDestinationList(
                          settingsContext: settingsContext,
                          destinations: destinations,
                          selectedDestinationId: selectedDestinationId,
                          onDestinationSelected: _selectDestination,
                          pushRoutes:
                              false, // master-detail keeps selection in-pane.
                        ))
                  : _buildSearchResults(
                      settingsContext: settingsContext,
                      destinations: destinations,
                      wide: true,
                    ),
            ),
          ],
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

  void _selectDestination(SettingsDestinationId id) {
    setState(() => _selectedDestinationId = id);
  }
}
