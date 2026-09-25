import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_source_feeds.dart';
import 'package:fushi/src/media/manga/discovery/manga_source_catalog_section.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/utils.dart';

/// 漫画库「发现」视图：**漫画唯一的发现入口**。
///
/// 页头下面一行是与书 / galgame 发现页同形的 [DiscoveryHeaderControls]（来源筛选
/// 下拉 + 搜索框），正文**只由用户自己启用的来源**构成：
///
/// 1. 「浏览来源」快捷条（[MangaSourceCatalogSection]）：内置 mokuro.moe 目录 +
///    已启用 Aidoku 包 + 已启用 Mihon 在线源 + OPDS 服务器，一源一枚磁贴，点进
///    各自的目录页；
/// 2. 每个已启用在线源的「热门」横滑行（[MangaDiscoverySourceRow]），行头带
///    「查看全部」直达该源目录。
///
/// 下拉选中具体来源时正文收窄成该源的磁贴 + 它的热门**网格**
/// （[MangaDiscoverySourceGrid]）——只看一个源时，一条横滑行浪费了整屏宽度。
/// 一个来源都没有时整页换成引导空态，指向「来源」视图。
///
/// 此前页首是 MAL（经 Jikan）的趋势 / 热门 / 高分 / 最新完结四条元数据行，点开
/// 再在已启用来源里按标题猜可读条目。那条链路整体移除：Jikan 频繁 5xx / 限流
/// 让页首常年是一块失败牌坊，而且元数据条目本身不能读、标题匹配又常常猜不中，
/// 用户点进去多半是「没有找到可读来源」。现在页面上的每一张卡片都来自真实来源，
/// 点开即可读。
///
/// 注意 `AppModel.mihonManager` 在不支持的平台上会抛 [UnsupportedError]，所以任何
/// 读它的路径都必须先过 [MihonRuntimeFactory.isSupported] 这道门。
///
/// 首次切到本视图才发请求（库页壳惰性构建），结果保活在各行 State 里（壳
/// Offstage 保活），切走切回不重抓；显式刷新走页头按钮。
class MangaDiscoveryPage extends ConsumerStatefulWidget {
  const MangaDiscoveryPage({
    super.key,
    this.navigation,
    this.embedded = false,
    this.sourceFeedsOverride,
    this.catalogOverride,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  /// 嵌入下载资源聚合页时，外层已经提供「资源」页头，这里只渲染
  /// 漫画来源筛选、搜索与结果，避免再画一行「发现」。
  final bool embedded;

  /// 测试注入：给定时跳过平台来源发现，直接渲染这些来源热门行。
  final List<MangaDiscoverySourceFeed>? sourceFeedsOverride;

  /// 测试注入：给定时跳过平台来源发现，直接用这份清单渲染下拉与「浏览来源」节。
  final MangaSourceCatalog? catalogOverride;

  @override
  ConsumerState<MangaDiscoveryPage> createState() => _MangaDiscoveryPageState();
}

class _MangaDiscoveryPageState extends ConsumerState<MangaDiscoveryPage> {
  MihonManager? _mihonManager;
  final MihonSourceImageLoadQueue _imageQueue =
      MihonSourceImageLoadQueue(maxConcurrent: 4);

  StreamSubscription<void>? _aidokuChanges;
  List<AidokuInstalledPackage> _aidokuPackages =
      const <AidokuInstalledPackage>[];
  Object? _aidokuError;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// 当前下拉选中的来源；[kDiscoveryAllSourcesId] = 全部来源。
  String _selectedSourceId = kDiscoveryAllSourcesId;

  /// 刷新代数：并进各热门行/网格的 key，递增即整批重新挂载、重新拉取。
  int _generation = 0;

  /// 测试注入模式：**任一** override 给定就整条平台发现路径都不走。
  ///
  /// 只关掉一半会得到「feed 是假的、来源清单却去读 AppModel」这种半真状态——
  /// widget 测试立刻退化成在测环境。两个 override 因此共用同一道门。
  bool get _injected =>
      widget.sourceFeedsOverride != null || widget.catalogOverride != null;

  @override
  void initState() {
    super.initState();
    // Aidoku 包清单：装/卸/启停后立即重载，否则保活的本页停在旧清单上。
    if (!_injected && AidokuRuntimeFactory.isSupported) {
      _aidokuChanges = AidokuPackageStore.changes.listen((_) => _loadAidoku());
      unawaited(_loadAidoku());
    }
  }

  Future<void> _loadAidoku() async {
    try {
      final List<AidokuInstalledPackage> packages =
          await (await AidokuPackageStore.open()).listInstalled();
      if (!mounted) return;
      setState(() {
        _aidokuPackages = packages;
        _aidokuError = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _aidokuError = error);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 监听 manager：来源装载/启停后热门行与来源清单跟着变。
    if (_injected) return;
    if (!MihonRuntimeFactory.isSupported) return;
    final MihonManager manager = ref.read(appProvider).mihonManager;
    if (identical(manager, _mihonManager)) return;
    _mihonManager?.removeListener(_managerChanged);
    _mihonManager = manager..addListener(_managerChanged);
  }

  void _managerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _mihonManager?.removeListener(_managerChanged);
    unawaited(_aidokuChanges?.cancel());
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() => _generation++);
    if (!_injected && AidokuRuntimeFactory.isSupported) {
      unawaited(_loadAidoku());
    }
  }

  /// 来源热门行清单：测试注入优先，否则按平台从 Mihon 宿主取。
  List<MangaDiscoverySourceFeed> _sourceFeeds() {
    if (_injected) {
      return widget.sourceFeedsOverride ?? const <MangaDiscoverySourceFeed>[];
    }
    final MihonManager? manager = _mihonManager;
    if (manager == null) return const <MangaDiscoverySourceFeed>[];
    return mihonDiscoverySourceFeeds(manager: manager, imageQueue: _imageQueue);
  }

  /// 当前可浏览来源快照。**只能在 build 里调**（内含 `ref.watch`）。
  MangaSourceCatalog _catalog() {
    if (_injected) return widget.catalogOverride ?? const MangaSourceCatalog();
    final MihonManager? manager = _mihonManager;
    // watch（不是 read）：mokuro.moe 开关经 PreferencesRepository -> AppModel 转发
    // 过来，本页在库页壳里是 Offstage 保活的，不 watch 就永远停在旧值上
    // （BUG-1431 同因：「来源」里关掉的源必须立刻从这里消失）。
    return MangaSourceCatalog(
      mokuroEnabled: isMokuroMoeSourceEnabled(ref.watch(appProvider)),
      aidokuPackages: _aidokuPackages
          .where((AidokuInstalledPackage package) => package.enabled)
          .toList(growable: false),
      mihonSources: manager == null
          ? const <MangaOnlineSourceRow>[]
          : enabledMangaOnlineSources(manager),
      // 同上 watch 的理由：设置里增删/停用 OPDS 服务器后本节要立刻跟着变，
      // 而本页在库页壳里是 Offstage 保活的。
      opdsServers: ref
          .watch(appProvider)
          .prefsRepo
          .discoveryOpdsServers
          .where((OpdsServerConfig server) => server.enabled)
          .toList(growable: false),
      aidokuError: _aidokuError,
    );
  }

  /// 「去『来源』视图装来源」的去处；本页不在库页壳里、或壳没有「来源」视图时为
  /// null，空态只给文案不给按钮。
  ///
  /// 判据是「壳**有** sources 视图」而不是「壳在」：[MediaLibraryShellScope.select]
  /// 对不存在的视图静默忽略，拿后者当判据就会渲染一个点了什么都不发生的按钮。
  VoidCallback? _openSourcesAction() => MediaLibraryShellScope.maybeOf(context)
      ?.actionFor(MediaLibraryViewKind.sources);

  void _openMokuro() {
    final AppModel appModel = ref.read(appProvider);
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => FushiPageScaffold(
          title: t.mihon_source_browse_mokuro,
          body: MokuroMoeCatalogView(
            db: appModel.database,
            embedded: true,
          ),
        ),
      ),
    );
  }

  void _openMihonSource(MangaOnlineSourceRow source) {
    final MihonManager? manager = _mihonManager;
    if (manager == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(source),
        ),
      ),
    );
  }

  void _openAidokuSource(AidokuInstalledPackage package) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            AidokuSourceBrowsePage(package: package),
      ),
    );
  }

  /// 打开一台 OPDS 服务器的漫画目录。
  ///
  /// 复用统一发现页（`MediaDiscoveryPage`）而不是另写一个浏览页：OPDS 的目录
  /// 下钻、搜索、下载入队、下载后自动入库整条链路在那边已经是通的，漫画域
  /// 只是同一条链路的另一个 `DiscoveryMediaKind`。
  ///
  /// 单域传入 → 那页不出媒体类型分段条；`initialSourceId` 让它直接落在这台
  /// 服务器上，跳过「先挑来源」的引导态。外面套 Scaffold 是因为该页设计为
  /// 嵌在库页壳里（`navigation == null` 时它自己不出 header），pushed route
  /// 需要一个返回入口。
  void _openOpdsServer(OpdsServerConfig server) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: Text(server.displayName)),
          body: MediaDiscoveryPage(
            kinds: const <DiscoveryMediaKind>[DiscoveryMediaKind.manga],
            initialSourceId: opdsSourceIdFor(server.id),
          ),
        ),
      ),
    );
  }

  /// 搜索提交：按当前下拉选择决定搜哪些源。
  ///
  /// mokuro.moe 走**另一条**路：它不在聚合搜索的源模型里
  /// （`manga_global_search_runner` 只认 Mihon 在线源与 Aidoku 包），硬塞进去只会
  /// 得到一个恒空的段。选中它时提交搜索因此直接打开 mokuro 目录页——那里有站内
  /// 搜索，能力不丢。选「全部来源」时它同样不参与聚合，只是不拦搜索。
  void _submitSearch(
    String rawQuery,
    MangaSourceCatalog catalog,
    String selected,
  ) {
    final String query = rawQuery.trim();
    if (query.isEmpty) return;
    if (selected == MangaSourceCatalog.mokuroSourceId) {
      _openMokuro();
      return;
    }
    final MangaSourceCatalog scope = catalog.filterById(selected);
    // 一个源都没有时搜索页的空态要能把用户带去「来源」视图装来源：去处由库页壳
    // 提供（[_openSourcesAction]），弹掉搜索页也由壳自己做。
    final VoidCallback? openSources = _openSourcesAction();
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaGlobalSearchPage(
          mihonManager: _mihonManager,
          mihonSources: scope.mihonSources,
          aidokuPackages: scope.aidokuPackages,
          initialQuery: query,
          onOpenSources: openSources,
        ),
      ),
    );
  }

  /// 页头。与 `MangaSourcesPage` 同一范式：导航条存在时即页头主位，不再另渲染一个
  /// 页面大标题。全源搜索不在这里——它是下面的搜索框。
  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      IconButton(
        key: const ValueKey<String>('manga_discovery_refresh'),
        tooltip: t.refresh,
        onPressed: _refresh,
        icon: const Icon(Icons.refresh),
      ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(title: navigation, actions: actions);
    }
    return FushiPageHeader(title: t.library_view_discover, actions: actions);
  }

  @override
  Widget build(BuildContext context) {
    final MangaSourceCatalog catalog = _catalog();
    final List<DiscoverySourceOption> options = catalog.sourceOptions;
    // 选中的来源被停用/卸载后自动回落到「全部来源」：把它算成派生值而不是在
    // setState 里纠正，选中项就不可能停在一个已经不存在的 id 上。
    final String selected = options.any(
      (DiscoverySourceOption option) => option.id == _selectedSourceId,
    )
        ? _selectedSourceId
        : kDiscoveryAllSourcesId;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!widget.embedded && !isCupertinoPlatform(context)) _buildHeader(),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DiscoveryHeaderControls(
              sources: options,
              selectedSourceId: selected,
              onSourceSelected: (String id) =>
                  setState(() => _selectedSourceId = id),
              searchController: _searchController,
              searchFocusNode: _searchFocusNode,
              searchFocusId: const FushiFocusId('manga-discovery-search'),
              searchHintText: t.manga_global_search_hint,
              onSearchSubmitted: (String query) =>
                  _submitSearch(query, catalog, selected),
            ),
          ),
          Expanded(child: _buildBody(catalog, selected)),
        ],
      ),
    );
  }

  /// 正文三形态：没有任何来源 → 引导空态；全部来源 → 快捷条 + 热门横滑行；
  /// 选中单个来源 → 该源磁贴 + 热门网格。
  Widget _buildBody(MangaSourceCatalog catalog, String selected) {
    final List<MangaDiscoverySourceFeed> feeds = _sourceFeeds();
    if (catalog.isEmpty && feeds.isEmpty) return _buildEmpty();
    final Widget catalogSection = MangaSourceCatalogSection(
      catalog: catalog.filterById(selected),
      onOpenMokuro: _openMokuro,
      onOpenAidoku: _openAidokuSource,
      onOpenMihon: _openMihonSource,
      onOpenOpds: _openOpdsServer,
    );
    if (selected != kDiscoveryAllSourcesId) {
      MangaDiscoverySourceFeed? feed;
      for (final MangaDiscoverySourceFeed candidate in feeds) {
        if (candidate.id == selected) feed = candidate;
      }
      return CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(child: catalogSection),
          if (feed != null)
            MangaDiscoverySourceGrid(
              key: ValueKey<String>(
                'manga_discovery_grid_${feed.id}#$_generation',
              ),
              feed: feed,
            ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: <Widget>[
        catalogSection,
        // 条目直接来自已启用来源，点开即可读。空/失败的行整行隐藏
        // （补充内容，不立错误牌坊）。
        for (final MangaDiscoverySourceFeed feed in feeds)
          MangaDiscoverySourceRow(
            key: ValueKey<String>(
              'manga_discovery_source_${feed.id}#$_generation',
            ),
            feed: feed,
          ),
      ],
    );
  }

  /// 一个来源都没有：整页引导空态。有扩展宿主时补一句「先装扩展」，没有宿主
  /// 的平台（Linux 等）这句只会误导，那里本来就装不了扩展；「管理来源」按钮只在
  /// 库页壳真有「来源」视图时出现。
  Widget _buildEmpty() {
    final ThemeData theme = Theme.of(context);
    final VoidCallback? openSources = _openSourcesAction();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            key: const ValueKey<String>('manga_discovery_empty'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.travel_explore_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                t.manga_discovery_empty_title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (MihonRuntimeFactory.isSupported) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  t.mihon_source_empty,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (openSources != null) ...<Widget>[
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  key: const ValueKey<String>('manga_discovery_open_sources'),
                  onPressed: openSources,
                  icon: const Icon(Icons.extension_outlined),
                  label: Text(t.manga_discovery_empty_action),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 热门行与热门网格共用的加载状态：首次挂载才拉第 1 页（发现视图本身已惰性
/// 构建，不会因页面存在就打请求风暴）。
mixin _PopularFeedLoader<T extends StatefulWidget> on State<T> {
  MangaDiscoverySourceFeed get feed;

  List<MangaDiscoverySourceItem>? items;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(loadPopular());
  }

  Future<void> loadPopular() async {
    if (items != null || failed) {
      setState(() {
        items = null;
        failed = false;
      });
    }
    try {
      final List<MangaDiscoverySourceItem> loaded = await feed.loadPopular();
      if (!mounted) return;
      setState(() => items = loaded);
    } on Object {
      if (!mounted) return;
      setState(() => failed = true);
    }
  }
}

/// 行 / 网格的标题行：源名 +（加载中）小转圈 +（有目录入口时）「查看全部」。
class _FeedHeader extends StatelessWidget {
  const _FeedHeader({required this.feed, required this.loading});

  final MangaDiscoverySourceFeed feed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final void Function(BuildContext context)? openCatalog = feed.openCatalog;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 8),
      child: SizedBox(
        height: 40,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                t.manga_discovery_source_popular(source: feed.displayName),
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (openCatalog != null)
              TextButton(
                key: ValueKey<String>('manga_discovery_view_all_${feed.id}'),
                onPressed: () => openCatalog(context),
                child: Text(t.manga_discovery_view_all),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一张来源条目卡片：封面撑满剩余高度，标题两行。行与网格共用。
class _SourceItemCard extends StatelessWidget {
  const _SourceItemCard({required this.item});

  final MangaDiscoverySourceItem item;

  @override
  Widget build(BuildContext context) {
    return FushiCard(
      padding: EdgeInsets.zero,
      onTap: () => item.open(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: item.buildCover(context)),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条「来源热门」横滑行；空/失败整行收起。
///
/// 加载中渲染的是**带源名的行头 + 行内小转圈**，与全局搜索页每段的加载态同形。
/// 此前是一条 2px 的裸 `LinearProgressIndicator`：启用二十几个源时页面就是二十
/// 几条没有任何标签的横线，用户看不出那是什么、也看不出在等谁。
///
/// 加载中**同时把卡片条的高度占住**（与全局搜索页 `_buildSectionBody` 的
/// `case loading: SizedBox(height: 200)` 同一条纪律）：光有行头不占位的话，加载
/// 完成那一刻会凭空插入一整条卡片高度，标题下方所有内容整体下移。行整体高度因此
/// 在 pending → done 之间不变。
class MangaDiscoverySourceRow extends StatefulWidget {
  const MangaDiscoverySourceRow({required this.feed, super.key});

  final MangaDiscoverySourceFeed feed;

  @override
  State<MangaDiscoverySourceRow> createState() =>
      _MangaDiscoverySourceRowState();
}

class _MangaDiscoverySourceRowState extends State<MangaDiscoverySourceRow>
    with _PopularFeedLoader<MangaDiscoverySourceRow> {
  @override
  MangaDiscoverySourceFeed get feed => widget.feed;

  @override
  Widget build(BuildContext context) {
    // 来源热门是补充内容：单源失败静默收起，不立错误牌坊（与全源搜索同纪律）。
    if (failed) return const SizedBox.shrink();
    final List<MangaDiscoverySourceItem>? loaded = items;
    if (loaded != null && loaded.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _FeedHeader(feed: feed, loading: loaded == null),
          const SizedBox(height: 4),
          // 高度常量与卡片条一致：加载中占位、加载完原地换内容，行高不变。
          SizedBox(
            height: 214,
            child: loaded == null
                ? null
                // 桌面端默认 dragDevices 不含 mouse，横滑行必须包
                // HorizontalDragScrollable（横向滚动守卫）。
                : HorizontalDragScrollable(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: loaded.length,
                      separatorBuilder: (BuildContext context, int index) =>
                          const SizedBox(width: 12),
                      itemBuilder: (BuildContext context, int index) =>
                          SizedBox(
                        width: 130,
                        child: _SourceItemCard(item: loaded[index]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 选中单个来源时的热门网格（sliver）：按宽度自适应列数。
///
/// 与横滑行不同，这里失败**不收起**：用户已经明确只看这一个源，整块消失会让
/// 页面看起来像「这个源什么都没有」，所以给失败文案 + 重试。
class MangaDiscoverySourceGrid extends StatefulWidget {
  const MangaDiscoverySourceGrid({required this.feed, super.key});

  final MangaDiscoverySourceFeed feed;

  @override
  State<MangaDiscoverySourceGrid> createState() =>
      _MangaDiscoverySourceGridState();
}

class _MangaDiscoverySourceGridState extends State<MangaDiscoverySourceGrid>
    with _PopularFeedLoader<MangaDiscoverySourceGrid> {
  @override
  MangaDiscoverySourceFeed get feed => widget.feed;

  @override
  Widget build(BuildContext context) {
    final List<MangaDiscoverySourceItem>? loaded = items;
    final Widget body;
    if (failed) {
      body = SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: <Widget>[
              Text(t.manga_discovery_load_failed, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                key: const ValueKey<String>('manga_discovery_retry'),
                onPressed: () => unawaited(loadPopular()),
                child: Text(t.retry),
              ),
            ],
          ),
        ),
      );
    } else if (loaded == null || loaded.isEmpty) {
      body = const SliverToBoxAdapter(child: SizedBox.shrink());
    } else {
      body = SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.6,
          ),
          itemCount: loaded.length,
          itemBuilder: (BuildContext context, int index) =>
              _SourceItemCard(item: loaded[index]),
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _FeedHeader(feed: feed, loading: loaded == null && !failed),
          ),
        ),
        body,
      ],
    );
  }
}
