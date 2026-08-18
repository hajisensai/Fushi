import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_source_browse_page.dart';
import 'package:fushi/src/media/manga/discovery/anilist_manga_discovery_provider.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_detail_page.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_models.dart';
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
import 'package:fushi/utils.dart';

/// 漫画库「发现」视图：**漫画唯一的发现入口**。
///
/// 页头下面一行是与书 / galgame 发现页同形的 [DiscoveryHeaderControls]（来源筛选
/// 下拉 + 搜索框），正文自上而下是：
///
/// 1. AniList 元数据的趋势 / 热门 / 高分 / 最新完结四条横滑行（仅「全部来源」时）；
/// 2. 每个已启用来源的「热门」横滑行（[MangaDiscoverySourceRow]）；
/// 3. 「浏览来源」一节（[MangaSourceCatalogSection]）：内置 mokuro.moe 目录 +
///    已启用 Aidoku 包 + 已启用 Mihon 在线源，点进各自的目录页。
///
/// 第 3 节此前是**另一个** tab（`manga_browse_page.dart`，`library_view_browse`）。
/// 那个 key 的文案被改成「发现」后，漫画库里出现了两个字面完全相同的「发现」
/// tab，用户点哪个都叫发现（BUG-1710）。两页能力互补——这页有横滑行没搜索框，
/// 那页有来源清单和全源搜索——所以合并取并集：来源清单进正文、全源搜索进头部
/// 搜索框，冗余 tab 删掉，一个能力都没丢。
///
/// 结构对齐 hayase 化后的视频首页决策（用户拍板）：**不做自动播轮播**，趋势行
/// 用更大的卡片充当页首视觉锚点，其余行标准卡片，全部是可拖动的横滑行。
///
/// AniList 条目是元数据不是来源条目；点开进 [MangaDiscoveryDetailPage]，由它在
/// 已启用来源里自动匹配可读条目。本页因此在**五个平台都可用**（AniList 公开查询
/// 与扩展宿主无关），与库页「视图列表无条件常量」的纪律一致。注意
/// `AppModel.mihonManager` 在不支持的平台上会抛 [UnsupportedError]，所以任何读它
/// 的路径都必须先过 [MihonRuntimeFactory.isSupported] 这道门。
///
/// 首次切到本视图才发请求（库页壳惰性构建），结果保活在 State 里（壳 Offstage
/// 保活），切走切回不重抓；显式刷新走页头按钮。
class MangaDiscoveryPage extends ConsumerStatefulWidget {
  const MangaDiscoveryPage({
    super.key,
    this.navigation,
    this.provider,
    this.sourceFeedsOverride,
    this.catalogOverride,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  /// 数据源。为空时创建 AniList provider；测试注入假实现。
  final MangaDiscoveryProvider? provider;

  /// 测试注入：给定时跳过平台来源发现，直接渲染这些来源热门行。
  final List<MangaDiscoverySourceFeed>? sourceFeedsOverride;

  /// 测试注入：给定时跳过平台来源发现，直接用这份清单渲染下拉与「浏览来源」节。
  final MangaSourceCatalog? catalogOverride;

  @override
  ConsumerState<MangaDiscoveryPage> createState() => _MangaDiscoveryPageState();
}

class _MangaDiscoveryPageState extends ConsumerState<MangaDiscoveryPage> {
  AniListMangaDiscoveryProvider? _ownedProvider;
  MangaDiscoverySnapshot? _snapshot;
  Object? _error;
  bool _loading = false;

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

  MangaDiscoveryProvider get _provider =>
      widget.provider ?? (_ownedProvider ??= AniListMangaDiscoveryProvider());

  /// 测试注入模式：**任一** override 给定就整条平台发现路径都不走。
  ///
  /// 只关掉一半会得到「feed 是假的、来源清单却去读 AppModel」这种半真状态——
  /// widget 测试立刻退化成在测环境。两个 override 因此共用同一道门。
  bool get _injected =>
      widget.sourceFeedsOverride != null || widget.catalogOverride != null;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
    _ownedProvider?.close();
    super.dispose();
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
      aidokuError: _aidokuError,
    );
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MangaDiscoverySnapshot snapshot = await _provider.fetchSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _openEntry(MangaDiscoveryEntry entry) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            MangaDiscoveryDetailPage(entry: entry),
      ),
    );
  }

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
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaGlobalSearchPage(
          mihonManager: _mihonManager,
          mihonSources: scope.mihonSources,
          aidokuPackages: scope.aidokuPackages,
          initialQuery: query,
        ),
      ),
    );
  }

  /// 页头。与 `MangaSourcesPage` 同一范式：导航条存在时即页头主位，不再另渲染一个
  /// 页面大标题。全源搜索不再是这里的 travel_explore 按钮——它被下面的搜索框取代。
  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      IconButton(
        key: const ValueKey<String>('manga_discovery_refresh'),
        tooltip: t.retry,
        onPressed: _loading ? null : () => unawaited(_load()),
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
          if (!isCupertinoPlatform(context)) _buildHeader(),
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

  /// 正文。选中具体来源时收窄：AniList 行整体隐藏（它是跨来源的元数据，按来源筛
  /// 选没有意义），只留该来源的热门行和它那张浏览卡片。
  ///
  /// AniList 的加载/失败态是**列表里的一项**，不再顶替整页：它挂了不该把「浏览
  /// 来源」一起带走——那是本页合并进来的、与 AniList 完全无关的能力。
  Widget _buildBody(MangaSourceCatalog catalog, String selected) {
    final bool allSources = selected == kDiscoveryAllSourcesId;
    final MangaDiscoverySnapshot? snapshot = _snapshot;
    final List<MangaDiscoverySourceFeed> feeds = _sourceFeeds()
        .where((MangaDiscoverySourceFeed feed) =>
            allSources || feed.id == selected)
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: <Widget>[
        if (allSources) ...<Widget>[
          if (snapshot == null && _loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (snapshot == null && !_loading) _buildError(),
          if (snapshot != null) ...<Widget>[
            _buildSection(
              title: t.manga_discovery_section_trending,
              entries: snapshot[MangaDiscoveryFeed.trending],
              cardWidth: 165,
              stripHeight: 265,
            ),
            _buildSection(
              title: t.manga_discovery_section_popular,
              entries: snapshot[MangaDiscoveryFeed.popular],
            ),
            _buildSection(
              title: t.manga_discovery_section_top_rated,
              entries: snapshot[MangaDiscoveryFeed.topRated],
            ),
            _buildSection(
              title: t.manga_discovery_section_latest_finished,
              entries: snapshot[MangaDiscoveryFeed.latestFinished],
            ),
          ],
        ],
        // P2：AniList 行之后接「来源热门」行——条目直接来自已启用来源，点开即
        // 可读，不经过标题匹配。空/失败的行整行隐藏（补充内容，不立错误牌坊）。
        for (final MangaDiscoverySourceFeed feed in feeds)
          MangaDiscoverySourceRow(
            key: ValueKey<String>('manga_discovery_source_${feed.id}'),
            feed: feed,
          ),
        // 末节：从原「浏览」tab 搬来的在线来源清单。
        MangaSourceCatalogSection(
          catalog: catalog.filterById(selected),
          onOpenMokuro: _openMokuro,
          onOpenAidoku: _openAidokuSource,
          onOpenMihon: _openMihonSource,
        ),
      ],
    );
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            t.manga_discovery_load_failed,
            textAlign: TextAlign.center,
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '$_error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.tonal(
            key: const ValueKey<String>('manga_discovery_retry'),
            onPressed: () => unawaited(_load()),
            child: Text(t.retry),
          ),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<MangaDiscoveryEntry> entries,
    double cardWidth = 130,
    double stripHeight = 214,
  }) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          // 桌面端默认 dragDevices 不含 mouse，横滑行必须包
          // HorizontalDragScrollable（横向滚动守卫，与全局搜索页同一处理）。
          SizedBox(
            height: stripHeight,
            child: HorizontalDragScrollable(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: entries.length,
                itemBuilder: (BuildContext context, int index) =>
                    _buildCard(entries[index], width: cardWidth),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(MangaDiscoveryEntry entry, {required double width}) {
    final double? score = entry.averageScore;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: FushiCard(
          padding: EdgeInsets.zero,
          onTap: () => _openEntry(entry),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: MangaDiscoveryCover(url: entry.coverUrl)),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      entry.preferredTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (score != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.star_rate_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            score.toStringAsFixed(1),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条「来源热门」横滑行：首次挂载才加载（发现视图本身已惰性构建，行不会
/// 因页面存在就打请求风暴）；加载中显示细进度条，空/失败整行收起。
class MangaDiscoverySourceRow extends StatefulWidget {
  const MangaDiscoverySourceRow({required this.feed, super.key});

  final MangaDiscoverySourceFeed feed;

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
      final List<MangaDiscoverySourceItem> items =
          await widget.feed.loadPopular();
      if (!mounted) return;
      setState(() => _items = items);
    } on Object {
      // 来源热门是补充内容：单源失败静默收起，不立错误牌坊（与匹配编排同纪律）。
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final List<MangaDiscoverySourceItem>? items = _items;
    if (items == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              t.manga_discovery_source_popular(source: widget.feed.name),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 214,
            child: HorizontalDragScrollable(
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                itemBuilder: (BuildContext context, int index) =>
                    _buildCard(items[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(MangaDiscoverySourceItem item) {
    return SizedBox(
      width: 130,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: FushiCard(
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
        ),
      ),
    );
  }
}

/// AniList 封面（公开 CDN，普通 `Image.network` 即可）；空/失败给占位图标。
class MangaDiscoveryCover extends StatelessWidget {
  const MangaDiscoveryCover({required this.url, super.key});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final String value = url?.trim() ?? '';
    if (value.isEmpty) {
      return const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.image_not_supported_outlined)),
      );
    }
    return Image.network(
      value,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const ColoredBox(
        color: Color(0x11000000),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}
