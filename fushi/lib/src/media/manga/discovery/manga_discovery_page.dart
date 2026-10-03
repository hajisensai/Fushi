import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';
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
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
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
/// 交互口径与视频发现页一致（`docs/specs/2026-09-27-browse-module.md` 阶段 3）：
/// 横滑行是共享的 [DiscoveryShelf]；热门行拉取失败不再静默消失，而是汇总进页首
/// 的来源失败横幅（[DiscoveryProviderWarningBanner]，印来源展示名），全部失败时换
/// 成可重试的整块提示；单源网格滚到离底 600 以内自动翻下一页。
///
/// 「浏览来源」节保留：它是 mokuro.moe / Aidoku / OPDS 这些**没有热门行**的来源在
/// 本页唯一的入口——下拉选中它们时正文只剩这一块磁贴，删掉就成了空白页。
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
    this.onOpenSources,
    this.onAiAcquire,
    this.sourceFeedsOverride,
    this.catalogOverride,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  /// 嵌入「浏览 › 发现」时，外层已经提供页头，这里只渲染漫画来源筛选、搜索与
  /// 结果，避免再画一行「发现」；页头上的刷新随之挪进搜索行。
  final bool embedded;

  /// 「管理来源」的去处（空态与全源搜索页的引导按钮）。嵌在浏览页时由宿主给出
  /// （切到「来源 › 漫画」）；为 null 时退回库页壳的「来源」视图，都没有就只给
  /// 文案不给按钮。
  final VoidCallback? onOpenSources;

  /// 「AI 下载」入口（参数 = 搜索框当前文字）；null = 宿主没接线，按钮不渲染。
  final ValueChanged<String>? onAiAcquire;

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

  /// 「全部来源」下各热门行最近一次的拉取失败（feed id → 错误），喂页首横幅。
  ///
  /// 刷新与切换来源时清空：行随之重新挂载、重新拉取，旧失败不该挂在新一轮上。
  final Map<String, Object> _rowFailures = <String, Object>{};

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
    setState(() {
      _generation++;
      _rowFailures.clear();
    });
    if (!_injected && AidokuRuntimeFactory.isSupported) {
      unawaited(_loadAidoku());
    }
  }

  /// 热门行拉取结束的回报：[error] 为 null = 成功。晚到的旧一代回报直接丢弃。
  void _onRowResult(int generation, String feedId, Object? error) {
    if (!mounted || generation != _generation) return;
    if (error == null) {
      if (!_rowFailures.containsKey(feedId)) return;
      setState(() => _rowFailures.remove(feedId));
      return;
    }
    setState(() => _rowFailures[feedId] = error);
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

  /// 「去『来源』装来源」的去处：宿主给的 [MangaDiscoveryPage.onOpenSources]
  /// 优先（浏览页不是库页壳，壳作用域在那里不存在）；否则问库页壳。都没有时为
  /// null，空态只给文案不给按钮。
  ///
  /// 壳的判据是「壳**有**在线来源视图」而不是「壳在」：[MediaLibraryShellScope.select]
  /// 对不存在的视图静默忽略，拿后者当判据就会渲染一个点了什么都不发生的按钮。
  /// 去处是漫画库的「来源」（[MediaLibraryViewKind.onlineSources]，Mihon 源 +
  /// mokuro.moe），不是「导入」——导入页只有本地来源，装不了在线源。
  VoidCallback? _openSourcesAction() =>
      widget.onOpenSources ??
      MediaLibraryShellScope.maybeOf(context)
          ?.actionFor(MediaLibraryViewKind.onlineSources);

  /// 页头只在独立 / 库页壳里渲染；不渲染时（embedded、Cupertino）刷新挪进搜索行。
  bool get _headerVisible => !widget.embedded && !isCupertinoPlatform(context);

  Widget _refreshButton() => IconButton(
        key: const ValueKey<String>('manga_discovery_refresh'),
        tooltip: t.refresh,
        onPressed: _refresh,
        icon: const Icon(Icons.refresh),
      );

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
  /// 漫画发现页**只在提交时搜**，不跟视频发现页做 350ms 输入防抖：这里的搜索是
  /// push 一张全源聚合搜索页（每个源各打一次网络），防抖触发就等于用户每停顿一下
  /// 就被推进一张新页面、再给所有来源各发一轮请求。视频发现页防抖成立，是因为它在
  /// 本页原地刷新结果。
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
    final List<Widget> actions = <Widget>[_refreshButton()];
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
          if (_headerVisible) _buildHeader(),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DiscoveryHeaderControls(
              trailing: <Widget>[
                if (widget.onAiAcquire case final ValueChanged<String> onAi)
                  DiscoveryAiAcquireButton(
                    key: const ValueKey<String>('manga-discovery-ai-acquire'),
                    onPressed: () => onAi(_searchController.text),
                  ),
                if (!_headerVisible) _refreshButton(),
              ],
              sources: options,
              selectedSourceId: selected,
              onSourceSelected: (String id) => setState(() {
                _selectedSourceId = id;
                _rowFailures.clear();
              }),
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
        key: PageStorageKey<String>('manga-discovery-scroll-$selected'),
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
    final Map<String, MangaDiscoverySourceFeed> feedsById =
        <String, MangaDiscoverySourceFeed>{
      for (final MangaDiscoverySourceFeed feed in feeds) feed.id: feed,
    };
    // 已停用 / 卸载的来源不再有行，它的旧失败也不该留在横幅上。
    final List<ExternalProviderFailure> failures = <ExternalProviderFailure>[
      for (final MapEntry<String, Object> failure in _rowFailures.entries)
        if (feedsById.containsKey(failure.key))
          ExternalProviderFailure.fromException(
            providerId: failure.key,
            operation: 'popular',
            error: failure.value,
          ),
    ];
    String displayNameFor(String feedId) =>
        feedsById[feedId]?.displayName ?? feedId;
    final bool allFailed = feeds.isNotEmpty && failures.length == feeds.length;
    final int generation = _generation;
    return CustomScrollView(
      key: const PageStorageKey<String>('manga-discovery-scroll'),
      slivers: <Widget>[
        // 部分来源失败：横幅点名是哪几个源，其余行照常显示。
        if (failures.isNotEmpty && !allFailed)
          SliverToBoxAdapter(
            child: DiscoveryProviderWarningBanner(
              key: const ValueKey<String>('manga_discovery_provider_warning'),
              failures: failures,
              displayNameFor: displayNameFor,
            ),
          ),
        SliverToBoxAdapter(child: catalogSection),
        // 条目直接来自已启用来源，点开即可读。空行整行收起；失败行也收起，
        // 失败汇总到上面的横幅（或下面全部失败的整块提示）。
        //
        // 一个 SliverList 懒建（只建可见范围 + 缓存区）：每行挂载即拉该源第 1 页，
        // 一行一个 SliverToBoxAdapter 会在进入本页时把全部来源的行一次性建出来，
        // 对二十几个源同时并发 loadPopular（PR #1707 审查）。
        SliverList.list(
          children: <Widget>[
            for (final MangaDiscoverySourceFeed feed in feeds)
              MangaDiscoverySourceRow(
                key: ValueKey<String>(
                  'manga_discovery_source_${feed.id}#$generation',
                ),
                feed: feed,
                onResult: (Object? error) =>
                    _onRowResult(generation, feed.id, error),
              ),
          ],
        ),
        if (allFailed)
          SliverToBoxAdapter(
            child: FushiPlaceholderMessage(
              key: const ValueKey<String>('manga_discovery_feeds_failed'),
              icon: Icons.cloud_off_outlined,
              message: t.manga_discovery_load_failed,
              detail: feeds
                  .map((MangaDiscoverySourceFeed feed) => feed.displayName)
                  .join(' · '),
              action: FilledButton.icon(
                key: const ValueKey<String>('manga_discovery_retry_all'),
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(t.retry),
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: DiscoveryLoadMoreFooter(loading: false),
        ),
      ],
    );
  }

  /// 一个来源都没有：整页引导空态。有扩展宿主时补一句「先装扩展」，没有宿主
  /// 的平台（iOS 等）这句只会误导，那里本来就装不了扩展；「管理来源」按钮只在
  /// 真有去处时出现（宿主给了 [MangaDiscoveryPage.onOpenSources]，或库页壳真有
  /// 「来源」视图）。
  Widget _buildEmpty() {
    final VoidCallback? openSources = _openSourcesAction();
    return CustomScrollView(
      slivers: <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('manga_discovery_empty'),
            icon: Icons.travel_explore_outlined,
            message: t.manga_discovery_empty_title,
            detail:
                MihonRuntimeFactory.isSupported ? t.mihon_source_empty : null,
            action: openSources == null
                ? null
                : FilledButton.tonalIcon(
                    key: const ValueKey<String>('manga_discovery_open_sources'),
                    onPressed: openSources,
                    icon: const Icon(Icons.extension_outlined),
                    label: Text(t.manga_discovery_empty_action),
                  ),
          ),
        ),
      ],
    );
  }
}

/// 行头「查看全部」：来源有完整目录入口时才出。
Widget? _viewAllButton(MangaDiscoverySourceFeed feed) {
  final void Function(BuildContext context)? openCatalog = feed.openCatalog;
  if (openCatalog == null) return null;
  return Builder(
    builder: (BuildContext context) => TextButton(
      key: ValueKey<String>('manga_discovery_view_all_${feed.id}'),
      onPressed: () => openCatalog(context),
      child: Text(t.manga_discovery_view_all),
    ),
  );
}

/// 网格的标题行：源名 +（加载中）小转圈 +（有目录入口时）「查看全部」。
class _FeedHeader extends StatelessWidget {
  const _FeedHeader({required this.feed, required this.loading});

  final MangaDiscoverySourceFeed feed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final Widget? viewAll = _viewAllButton(feed);
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
            if (viewAll != null) viewAll,
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

/// 一条「来源热门」横滑行（共享 [DiscoveryShelf]）；空 / 失败整行收起。
///
/// 首次挂载才拉第 1 页（发现视图本身已惰性构建，不会因页面存在就打请求风暴）。
/// 失败不在行内立牌坊，而是经 [onResult] 报给页面，汇总进页首横幅——二十几个源
/// 各自一块错误卡片会把真正拉到内容的行挤出屏幕，但完全静默又让用户以为那个源
/// 什么都没有。
///
/// 加载中渲染的是**带源名的行头 + 行内小转圈**，与全局搜索页每段的加载态同形；
/// 卡片条的高度同时占住（[DiscoveryShelf] 的 loading 形态），加载完成那一刻不会
/// 凭空插入一整条卡片高度，行整体高度在 pending → done 之间不变。
class MangaDiscoverySourceRow extends StatefulWidget {
  const MangaDiscoverySourceRow({
    required this.feed,
    this.onResult,
    super.key,
  });

  final MangaDiscoverySourceFeed feed;

  /// 拉取结束回报：null = 成功，否则是失败原因。
  final ValueChanged<Object?>? onResult;

  @override
  State<MangaDiscoverySourceRow> createState() =>
      _MangaDiscoverySourceRowState();
}

class _MangaDiscoverySourceRowState extends State<MangaDiscoverySourceRow> {
  List<MangaDiscoverySourceItem>? _items;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MangaDiscoverySourceItem> loaded =
          await widget.feed.loadPopular();
      if (!mounted) return;
      setState(() => _items = loaded);
      widget.onResult?.call(null);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onResult?.call(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final List<MangaDiscoverySourceItem>? loaded = _items;
    if (loaded != null && loaded.isEmpty) return const SizedBox.shrink();
    final MangaDiscoverySourceFeed feed = widget.feed;
    return DiscoveryShelf(
      title: t.manga_discovery_source_popular(source: feed.displayName),
      storageKey: 'manga-discovery-shelf-${feed.id}',
      loading: loaded == null,
      // 高度常量与卡片条一致：加载中占位、加载完原地换内容，行高不变。
      height: 214,
      itemWidth: 130,
      trailing: _viewAllButton(feed),
      itemCount: loaded?.length ?? 0,
      itemBuilder: (BuildContext context, int index) =>
          _SourceItemCard(item: loaded![index]),
    );
  }
}

/// 选中单个来源时的热门网格（sliver）：按宽度自适应列数，滚到离底
/// [kDiscoveryAutoLoadExtent] 以内自动翻下一页（来源给了
/// [MangaDiscoverySourceFeed.loadPopularPage] 时）。
///
/// 与横滑行不同，这里失败**不收起**：用户已经明确只看这一个源，整块消失会让
/// 页面看起来像「这个源什么都没有」，所以给失败提示 + 重试。翻页失败保留已有
/// 条目，页尾换成重试按钮，且不再自动重试（否则每滚一下就重打一次坏掉的页）。
class MangaDiscoverySourceGrid extends StatefulWidget {
  const MangaDiscoverySourceGrid({required this.feed, super.key});

  final MangaDiscoverySourceFeed feed;

  @override
  State<MangaDiscoverySourceGrid> createState() =>
      _MangaDiscoverySourceGridState();
}

class _MangaDiscoverySourceGridState extends State<MangaDiscoverySourceGrid> {
  List<MangaDiscoverySourceItem>? _items;
  bool _failed = false;
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;

  /// 竞态哨兵：重试 / 首页重拉后，晚到的旧翻页结果不许接到新列表尾部。
  int _seq = 0;

  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFirst());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollPosition? position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _position)) return;
    _position?.removeListener(_onScroll);
    _position = position?..addListener(_onScroll);
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final ScrollPosition? position = _position;
    if (position == null || !position.hasContentDimensions) return;
    if (discoveryShouldLoadMore(position)) unawaited(_loadMore());
  }

  /// 首页内容不够撑满视口时没有滚动事件可等：画完这一帧再判一次。
  void _checkFillAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  Future<void> _loadFirst() async {
    final int seq = ++_seq;
    if (_items != null || _failed) {
      setState(() {
        _items = null;
        _failed = false;
        _page = 1;
        _hasMore = false;
        _loadingMore = false;
        _loadMoreFailed = false;
      });
    }
    try {
      final Future<MangaDiscoverySourcePage> Function(int page)? loadPage =
          widget.feed.loadPopularPage;
      final MangaDiscoverySourcePage page = loadPage != null
          ? await loadPage(1)
          : MangaDiscoverySourcePage(
              items: await widget.feed.loadPopular(),
              hasMore: false,
            );
      if (!mounted || seq != _seq) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
      });
      _checkFillAfterFrame();
    } on Object {
      if (!mounted || seq != _seq) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _loadMore() async {
    final Future<MangaDiscoverySourcePage> Function(int page)? loadPage =
        widget.feed.loadPopularPage;
    final List<MangaDiscoverySourceItem>? current = _items;
    if (loadPage == null ||
        current == null ||
        !_hasMore ||
        _loadingMore ||
        _loadMoreFailed) {
      return;
    }
    final int seq = _seq;
    final int nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final MangaDiscoverySourcePage page = await loadPage(nextPage);
      if (!mounted || seq != _seq) return;
      setState(() {
        _items = <MangaDiscoverySourceItem>[...current, ...page.items];
        _page = nextPage;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
      _checkFillAfterFrame();
    } on Object {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    }
  }

  void _retryLoadMore() {
    setState(() => _loadMoreFailed = false);
    unawaited(_loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final List<MangaDiscoverySourceItem>? loaded = _items;
    final Widget body;
    if (_failed) {
      body = SliverToBoxAdapter(
        child: FushiPlaceholderMessage(
          icon: Icons.cloud_off_outlined,
          message: t.manga_discovery_load_failed,
          action: FilledButton.tonal(
            key: const ValueKey<String>('manga_discovery_retry'),
            onPressed: () => unawaited(_loadFirst()),
            child: Text(t.retry),
          ),
        ),
      );
    } else if (loaded == null) {
      body = const SliverToBoxAdapter(child: SizedBox.shrink());
    } else if (loaded.isEmpty) {
      body = SliverToBoxAdapter(
        child: FushiPlaceholderMessage(
          key: const ValueKey<String>('manga_discovery_grid_empty'),
          icon: Icons.search_off_rounded,
          message: t.discovery_empty,
        ),
      );
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
    final Widget footer;
    if (_loadMoreFailed) {
      footer = Center(
        child: TextButton.icon(
          key: const ValueKey<String>('manga_discovery_load_more_retry'),
          onPressed: _retryLoadMore,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.retry),
        ),
      );
    } else if (_hasMore && !_loadingMore && loaded != null) {
      // 自动翻页的键盘 / 手柄兜底：焦点走到页尾也能手动拉下一页。
      footer = Center(
        child: TextButton(
          key: const ValueKey<String>('manga_discovery_load_more'),
          onPressed: () => unawaited(_loadMore()),
          child: Text(t.discovery_load_more),
        ),
      );
    } else {
      footer = DiscoveryLoadMoreFooter(loading: _loadingMore);
    }
    return SliverMainAxisGroup(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _FeedHeader(
              feed: widget.feed,
              loading: loaded == null && !_failed,
            ),
          ),
        ),
        body,
        SliverToBoxAdapter(child: footer),
      ],
    );
  }
}
