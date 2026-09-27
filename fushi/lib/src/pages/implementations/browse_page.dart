import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show AudiobookRepository, AudiobookStorage, SrtBookRepository;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/remote_download_tasks_section.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/torrent_detail_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_page.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show VideoDownloadJobFileRow, VideoDownloadJobRow;

/// 「浏览」页签（Mihon 的 Browse 形态）：来源 / 扩展 / 发现 / 下载。
///
/// 2026-09-27 由「下载」模块改名而来（持久化键 `module_downloads_enabled` 冻结），
/// 同时把散在各库页与导入页的在线入口收拢到这里：
/// - **来源**：小说（LNReader）/ 漫画（Mihon + mokuro.moe）/ 视频（Aniyomi）三域
///   已装扩展提供的在线源，点进源的浏览页；
/// - **扩展**：三域的可装扩展目录与已装扩展管理，扩展仓库挂在本页签的「仓库」
///   动作上（Mihon 把 repo 放在 Extensions 的工具栏）；
/// - **发现**：书 / 漫画 / 游戏 / 视频四域的生产发现页（原「资源」页签）；
/// - **下载**：统一下载中心的任务与订阅，下载设置在页头齿轮里。
///
/// 每个页签内先选内容域，再直接复用各域自己的生产组件，不另写第二套 UI。
class BrowsePage extends ConsumerStatefulWidget {
  const BrowsePage({
    super.key,
    this.initialTab,
    this.initialDownloadsSection = BrowseDownloadsSection.tasks,
    this.navigationRequest,
    this.videoDiscoveryController,
    this.videoDiscoveryActions = const VideoDiscoveryActions(),
  });

  /// 打开时停在哪个页签；null 或此刻不可见 = 第一个可见页签。
  final BrowseTab? initialTab;

  /// 「下载」页签里先显示任务还是订阅（发现详情「管理订阅」等入口直落订阅）。
  final BrowseDownloadsSection initialDownloadsSection;

  /// 宿主（首页）把**已挂载**的浏览页切到某页签 / 下载段的请求：首页保活本页，
  /// 跳转不再靠换 key 整页重建（那会丢掉各页签的搜索词、结果与滚动）。按 identity
  /// 判新请求；首次挂载时它优先于 [initialTab]。
  final BrowseNavigationRequest? navigationRequest;

  /// 与视频模块共用同一套生产发现服务，避免下载页另起网络生命周期。
  final VideoDiscoveryController? videoDiscoveryController;

  /// 视频发现详情、资源搜索与订阅动作由首页组合根统一注入。
  final VideoDiscoveryActions videoDiscoveryActions;

  @override
  ConsumerState<BrowsePage> createState() => _BrowsePageState();
}

/// 「浏览」的页签。**用枚举而不是下标**：页签随平台 / 模块开关增减，跨页跳转
/// （视频发现详情「管理订阅」等）若按下标就会在页签少一个时静默落错页。
enum BrowseTab { sources, extensions, discover, downloads }

/// 「下载」页签里的两段。
enum BrowseDownloadsSection { tasks, subscriptions }

/// 一次「切到浏览某页签」的请求（见 [BrowsePage.navigationRequest]）。构造器刻意
/// 不是 const：每次跳转都是新对象，同一页签连续请求两次也能被识别成两次。
class BrowseNavigationRequest {
  BrowseNavigationRequest(
    this.tab, {
    this.downloadsSection = BrowseDownloadsSection.tasks,
  });

  final BrowseTab tab;
  final BrowseDownloadsSection downloadsSection;
}

class _BrowsePageState extends ConsumerState<BrowsePage>
    with TickerProviderStateMixin {
  /// 页签控制器由本页持有（不用 DefaultTabController）：页签随平台 / 模块开关增减
  /// 时要**按页签 id** 落回原来选中的页签——DefaultTabController 只保留下标，前面
  /// 少一个页签就静默落到相邻页签上。
  TabController? _tabController;

  /// [_tabController] 对应的页签序列。
  List<BrowseTab> _controllerTabs = const <BrowseTab>[];

  /// 当前选中的页签（按 id 记）；首次挂载时是跳转请求 / [BrowsePage.initialTab]。
  late BrowseTab? _selectedTab =
      widget.navigationRequest?.tab ?? widget.initialTab;

  /// 来源 / 扩展两个页签共用的内容域选择（在两页签之间来回切不丢选择）。
  OnlineSourcesDomain _onlineDomain = OnlineSourcesDomain.novel;

  /// 已访问过的在线域，按页签分开记（首次访问后保持挂载，来回切不丢搜索与滚动）。
  final Map<BrowseTab, Set<OnlineSourcesDomain>> _visitedOnlineDomains =
      <BrowseTab, Set<OnlineSourcesDomain>>{
        BrowseTab.sources: <OnlineSourcesDomain>{},
        BrowseTab.extensions: <OnlineSourcesDomain>{},
      };

  late BrowseDownloadsSection _downloadsSection =
      widget.navigationRequest?.downloadsSection ??
      widget.initialDownloadsSection;

  _DownloadsResourceDomain _resourceDomain = _DownloadsResourceDomain.books;

  /// 已访问过的资源域（首次访问后保持挂载，来回切不丢搜索词/结果/滚动位置）。
  /// 初始项在 [initState] 按可见域播种——硬编码 books 会在 books 模块关掉时把一个
  /// 不可见域的发现页挂起来。
  final Set<_DownloadsResourceDomain> _visitedResourceDomains =
      <_DownloadsResourceDomain>{};

  @override
  void initState() {
    super.initState();
    // 初始域 = 第一个可见域，不再硬编码 books：books 模块关掉时旧实现会停在一个
    // 已被过滤掉的域上（分段条选中值不在选项里 → 分段控件直接 assert，发现页也
    // 会挂在一个用户已关掉的模块上）。四个域全关时保持字段原值，此时
    // [_buildResourceHub] 整块不渲染，字段不参与任何渲染判据。
    final AppModel initialAppModel = ref.read(appProvider);
    final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
      initialAppModel.moduleVisibility,
      gamesForm: initialAppModel.gamesModuleForm,
    );
    if (domains.isNotEmpty) _resourceDomain = domains.first;
    _visitedResourceDomains.add(_resourceDomain);
    final List<OnlineSourcesDomain> onlineDomains = _visibleOnlineDomains(
      initialAppModel.moduleVisibility,
    );
    if (onlineDomains.isNotEmpty) _onlineDomain = onlineDomains.first;
  }

  @override
  void didUpdateWidget(BrowsePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final BrowseNavigationRequest? request = widget.navigationRequest;
    if (request == null || identical(request, oldWidget.navigationRequest)) {
      return;
    }
    // 已挂载时的跳转：原地切页签 / 下载段，不重建整页。
    _downloadsSection = request.downloadsSection;
    _selectedTab = request.tab;
    final int index = _controllerTabs.indexOf(request.tab);
    if (index >= 0) _tabController?.index = index;
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  /// 按此刻可见的页签对齐 [_tabController]：页签序列没变就沿用；变了（模块 /
  /// 平台门增减页签）就按 [_selectedTab] 的 id 重新定位，已不可见时落第一个页签。
  TabController _syncTabController(List<BrowseTab> tabs) {
    final TabController? current = _tabController;
    if (current != null && listEquals(tabs, _controllerTabs)) return current;
    final BrowseTab? wanted = _selectedTab;
    final int found = wanted == null ? -1 : tabs.indexOf(wanted);
    final int index = found < 0 ? 0 : found;
    final TabController next = TabController(
      length: tabs.length,
      initialIndex: index,
      // eink：TabBarView 的 300ms 横滑 = 整页一串局部刷新的残影，归零。
      animationDuration: einkSafeDuration(context, kTabScrollDuration),
      vsync: this,
    );
    next.addListener(() {
      if (identical(next, _tabController)) {
        _selectedTab = _controllerTabs[next.index];
      }
    });
    _tabController = next;
    _controllerTabs = List<BrowseTab>.unmodifiable(tabs);
    _selectedTab = tabs[index];
    // 旧控制器还挂在本帧之前的 TabBar / TabBarView 上：等这一帧换绑完再释放。
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  /// 此刻可见的页签，顺序即页头顺序。
  ///
  /// 来源 / 扩展两页签只在至少一个域有在线来源时出现（漫画域有内置 mokuro.moe，
  /// 不依赖扩展宿主；三个库模块全关时就只剩发现与下载）；发现页签跟四个库模块
  /// 走；下载恒在。
  List<BrowseTab> _visibleTabs(AppModel appModel) {
    final bool online = _visibleOnlineDomains(
      appModel.moduleVisibility,
    ).isNotEmpty;
    // 发现页签自己再问一次合规门，不只靠整个模块委托的 downloads 能力：两种能力
    // 今天都只在 iOS 缺席，但它们是两条独立的审核理由，日后范围分开时发现页签
    // 不能静默漏门。
    final bool discover =
        StoreRestrictedCapability.externalDiscovery.isAvailable &&
        _visibleResourceDomains(
          appModel.moduleVisibility,
          gamesForm: appModel.gamesModuleForm,
        ).isNotEmpty;
    return <BrowseTab>[
      if (online) BrowseTab.sources,
      if (online) BrowseTab.extensions,
      if (discover) BrowseTab.discover,
      BrowseTab.downloads,
    ];
  }

  String _tabLabel(BrowseTab tab) => switch (tab) {
    BrowseTab.sources => t.media_import_segment_sources,
    BrowseTab.extensions => t.media_import_segment_extensions,
    BrowseTab.discover => t.library_view_discover,
    BrowseTab.downloads => t.nav_downloads,
  };

  String _onlineDomainLabel(OnlineSourcesDomain domain) => switch (domain) {
    OnlineSourcesDomain.novel => t.discovery_kind_novel,
    OnlineSourcesDomain.manga => t.manga_library,
    OnlineSourcesDomain.video => t.nav_video,
  };

  void _selectOnlineDomain(OnlineSourcesDomain domain) {
    if (domain == _onlineDomain) return;
    setState(() => _onlineDomain = domain);
  }

  /// 「扩展」页签的「仓库」动作：push 同一域的扩展仓库管理（与扩展目录同一组
  /// 组件的仓库形态）。
  void _openStores(OnlineSourcesDomain domain) {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => _BrowseSubPage(
          title: '${t.media_import_segment_stores} · '
              '${_onlineDomainLabel(domain)}',
          child: BrowseOnlineSourcesView(
            domain: domain,
            section: OnlineSourcesSection.stores,
          ),
        ),
      ),
    );
  }

  /// 来源 / 扩展页签：内容域选择条 + 各域保活的在线来源面。
  Widget _buildOnlineTab(BrowseTab tab) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AppModel appModel = ref.watch(appProvider);
    final List<OnlineSourcesDomain> domains = _visibleOnlineDomains(
      appModel.moduleVisibility,
    );
    if (domains.isEmpty) return const SizedBox.shrink();
    final OnlineSourcesDomain selected = domains.contains(_onlineDomain)
        ? _onlineDomain
        : domains.first;
    final Set<OnlineSourcesDomain> visited = _visitedOnlineDomains[tab]!
      ..add(selected);
    final OnlineSourcesSection section = tab == BrowseTab.sources
        ? OnlineSourcesSection.sources
        : OnlineSourcesSection.extensions;
    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.gap,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: FushiSegmentedStrip<OnlineSourcesDomain>(
                  key: ValueKey<String>('browse-${tab.name}-domain-picker'),
                  segments: <ButtonSegment<OnlineSourcesDomain>>[
                    for (final OnlineSourcesDomain domain in domains)
                      ButtonSegment<OnlineSourcesDomain>(
                        value: domain,
                        label: Text(_onlineDomainLabel(domain)),
                      ),
                  ],
                  selected: selected,
                  onChanged: _selectOnlineDomain,
                  minSegmentWidth: 72,
                  alignment: Alignment.centerLeft,
                ),
              ),
              if (tab == BrowseTab.extensions)
                FushiIconButton(
                  key: const ValueKey<String>('browse-extensions-stores'),
                  icon: Icons.hub_outlined,
                  tooltip: t.media_import_segment_stores,
                  label: t.media_import_segment_stores,
                  onTap: () => _openStores(selected),
                ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              for (final OnlineSourcesDomain domain in domains)
                if (visited.contains(domain))
                  Positioned.fill(
                    child: Offstage(
                      offstage: domain != selected,
                      child: TickerMode(
                        enabled: domain == selected,
                        // Offstage 只关绘制与命中，不关焦点：隐藏域不排除出焦点
                        // 遍历，Tab / 方向键会走进看不见的域。
                        child: ExcludeFocus(
                          excluding: domain != selected,
                          child: BrowseOnlineSourcesView(
                            key: ValueKey<String>(
                              'browse-${tab.name}-${domain.name}',
                            ),
                            domain: domain,
                            section: section,
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// 「补对齐文件」：把已下完的孤立音频直接喂进统一导入对话框。
  ///
  /// 本仓有声书是字幕对齐驱动的，`download-only-audiobook` 任务落地的只有音频
  /// （CoreAudio/TMW 单卷 m4b），自动导入链路进不去。这里把该任务真实落盘的音频
  /// 预填进 [BookImportDialog]，用户只需再给一个字幕就能成书。
  ///
  /// 取不到音频路径（文件被手动删掉/移走）时照常开框、只是不预填——把死路留成
  /// 用户仍可自选文件的活路，好过弹一句错误后什么也做不了。
  ///
  /// 素材库里配得到字幕/正文时一并预填：身份键取任务记的 [externalId]（发现页
  /// 下载时写的作品主键），没有就退到音频文件名里的键。
  Future<void> _pairDownloadedAudiobook(VideoDownloadJobRow job) async {
    final AppModel appModel = ref.read(appProvider);
    final List<VideoDownloadJobFileRow> rows =
        await appModel.database.getVideoDownloadJobFiles(job.jobId);
    final List<String> audioPaths = <String>[
      for (final VideoDownloadJobFileRow row in rows)
        if (row.selected &&
            (row.finalAbsolutePath?.trim().isNotEmpty ?? false) &&
            AudiobookStorage.audioExtensions.contains(
              p.extension(row.finalAbsolutePath!).toLowerCase(),
            ))
          row.finalAbsolutePath!,
    ]..sort();
    final AudiobookMaterialMatch match = await _matchAudiobookMaterials(
      appModel,
      job: job,
      audioPaths: audioPaths,
    );
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
        initialSubtitlePath: match.subtitlePath,
        initialEpubPath: match.contentPath,
      ),
    );
  }

  /// 从素材库给这条任务配字幕/正文；没配素材库或配不到时返回空匹配。
  Future<AudiobookMaterialMatch> _matchAudiobookMaterials(
    AppModel appModel, {
    required VideoDownloadJobRow job,
    required List<String> audioPaths,
  }) async {
    final AudiobookMaterialScan scan =
        await appModel.audiobookMaterialService.scan();
    if (scan.index.isEmpty) return const AudiobookMaterialMatch();
    final String? externalId = job.externalId?.trim();
    final String? key = (externalId != null && externalId.isNotEmpty)
        ? externalId
        : audioPaths
            .map(audiobookKeyFromAudioPath)
            .firstWhere((String? k) => k != null, orElse: () => null);
    return matchAudiobookMaterial(scan.index, key: key, title: job.title);
  }

  Widget _buildVideoResourceTab() => VideoDiscoveryPage(
        key: const ValueKey<String>('downloads-resource-video-discovery'),
        navigation: const SizedBox.shrink(),
        embedded: true,
        controller: widget.videoDiscoveryController,
        actions: widget.videoDiscoveryActions,
      );

  String _resourceDomainLabel(_DownloadsResourceDomain domain) =>
      switch (domain) {
        _DownloadsResourceDomain.books => t.books,
        _DownloadsResourceDomain.manga => t.manga_library,
        _DownloadsResourceDomain.games => t.nav_game,
        _DownloadsResourceDomain.video => t.nav_video,
      };

  void _selectResourceDomain(_DownloadsResourceDomain domain) {
    if (domain == _resourceDomain) return;
    setState(() {
      _resourceDomain = domain;
      _visitedResourceDomains.add(domain);
    });
  }

  /// 漫画发现（「发现」页签里）的「管理来源」去处：回到本页并切到「来源 › 漫画」。
  /// 漫画域此刻不可见时为 null（空态只给文案、不给点了没反应的按钮）。
  ///
  /// 以本页自己的路由为界弹掉上面压着的路由（全源搜索页、详情页），与压了几层
  /// 无关——与库页壳 `MediaLibraryShell` 的「回到壳」同一口径。
  VoidCallback? _mangaSourcesAction() {
    final List<OnlineSourcesDomain> domains = _visibleOnlineDomains(
      ref.read(appProvider).moduleVisibility,
    );
    if (!domains.contains(OnlineSourcesDomain.manga)) return null;
    return () {
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        Navigator.of(context).popUntil((Route<dynamic> above) => above == route);
      }
      final int index = _controllerTabs.indexOf(BrowseTab.sources);
      if (index < 0) return;
      setState(() => _onlineDomain = OnlineSourcesDomain.manga);
      _tabController?.animateTo(index);
    };
  }

  Widget _buildResourceDomain(_DownloadsResourceDomain domain) =>
      switch (domain) {
        _DownloadsResourceDomain.books => const MediaDiscoveryPage(
            kinds: <DiscoveryMediaKind>[
              DiscoveryMediaKind.novel,
              DiscoveryMediaKind.audiobook,
            ],
          ),
        _DownloadsResourceDomain.manga => MangaDiscoveryPage(
            embedded: true,
            onOpenSources: _mangaSourcesAction(),
          ),
        _DownloadsResourceDomain.games => const MediaDiscoveryPage(
            kinds: <DiscoveryMediaKind>[DiscoveryMediaKind.game],
          ),
        _DownloadsResourceDomain.video => _buildVideoResourceTab(),
      };

  /// 分段条只负责选择内容域；域内筛选、搜索与结果展示全部沿用各模块
  /// 自己的生产发现页。四个固定目的地直接可见，避免无标签的表单型下拉框
  /// 单独悬在搜索区上方。首次访问后保持挂载，来回切换不丢搜索词、结果和滚动位置。
  Widget _buildResourceHub() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 模块门控：四个域分属 books / manga / games / video，关掉的模块不出段，
    // 它的发现页也一并从保活 Stack 里剪掉（隐藏域不该继续挂在树上跑网络）。
    final AppModel appModel = ref.watch(appProvider);
    final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
      appModel.moduleVisibility,
      gamesForm: appModel.gamesModuleForm,
    );
    // 四个域全关：整块资源分区不渲染——空的分段条 + 空 Stack 是「渲染出来但点不
    // 出任何东西」，正是要消灭的形态。
    if (domains.isEmpty) return const SizedBox.shrink();
    // 当前域在渲染期回落到第一个可见域：用户在设置里关掉当前域后本页可能仍挂着
    // （保活 tab），选中值不在 segments 里会让分段控件直接 assert。
    final _DownloadsResourceDomain selected = domains.contains(_resourceDomain)
        ? _resourceDomain
        : domains.first;
    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.gap,
          ),
          child: FushiSegmentedStrip<_DownloadsResourceDomain>(
            key: const ValueKey<String>('downloads-resource-type-picker'),
            segments: <ButtonSegment<_DownloadsResourceDomain>>[
              for (final _DownloadsResourceDomain domain in domains)
                ButtonSegment<_DownloadsResourceDomain>(
                  value: domain,
                  label: Text(_resourceDomainLabel(domain)),
                ),
            ],
            selected: selected,
            onChanged: _selectResourceDomain,
            minSegmentWidth: 72,
            alignment: Alignment.centerLeft,
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              for (final _DownloadsResourceDomain domain in domains)
                if (_visitedResourceDomains.contains(domain))
                  Positioned.fill(
                    child: Offstage(
                      offstage: domain != selected,
                      child: TickerMode(
                        enabled: domain == selected,
                        // 隐藏域排除出焦点遍历（Offstage 不管焦点）。
                        child: ExcludeFocus(
                          excluding: domain != selected,
                          child: KeyedSubtree(
                            key: ValueKey<String>(
                              'downloads-resource-${domain.name}',
                            ),
                            child: _buildResourceDomain(domain),
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  /// 手动添加任务（磁力链接 / .torrent 文件）：与搜索出的资源同走 v78 持久
  /// 管线，任务出现在任务 tab、同一套排序/搜索/优先级/删除操作。
  Future<void> _openManualTaskDialog() async {
    await showManualDownloadTaskDialog(
      context: context,
      appModel: ref.read(appProvider),
    );
  }

  /// 拖 `.torrent` 进下载页 → 与页头「添加任务」同一对话框、预填种子（多个种子
  /// 逐个开框）。其它文件在本页没有语义，给明确提示而不是静默——拖放没有
  /// 「不渲染入口」这个选项，落点就是整页。
  Future<void> _handleDownloadsDrop(List<String> paths, Offset _) async {
    final DroppedFiles files = classifyDroppedFiles(paths);
    if (files.torrents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.drag_drop_unsupported_on_downloads)),
      );
      return;
    }
    await showManualDownloadTaskDialog(
      context: context,
      appModel: ref.read(appProvider),
      torrentPaths: files.torrents,
    );
  }

  /// 下载设置（原「设置」页签）：push 一页，入口在「下载」页签的页头齿轮与番剧
  /// 下载对话框「去设置」。
  void _openDownloadSettings() {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => const BrowseDownloadSettingsPage(),
      ),
    );
  }

  /// 统一门头：页签导航作页头主位 + 页头动作，与其余顶层库页同构；独立 push 进来
  /// （无 home 壳）时在 leading 位保留返回按钮。
  ///
  /// 走 [LibrarySectionTabs.controlled]：本页的 [TabController] 同时驱动
  /// [TabBarView]，横滑时指示条跟手连续滑动。
  ///
  /// 页头动作只在「下载」页签出现（「添加任务」+ 下载设置）：它们不是来源 / 扩展 /
  /// 发现的动作。
  Widget _buildHeader(TabController controller, List<BrowseTab> tabs) {
    // 下拉框会临时 push PopupRoute；只看本页自己的 PageRoute，避免展开菜单时
    // 左上角凭空出现返回键。
    final bool showBackButton = ModalRoute.of(context)?.isFirst == false;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final bool onDownloads =
            tabs[controller.index.clamp(0, tabs.length - 1)] ==
            BrowseTab.downloads;
        return FushiPageHeader.customTitle(
          leading: showBackButton
              ? FushiIconButton(
                  icon: Icons.arrow_back,
                  tooltip: t.back,
                  onTap: () => Navigator.of(context).maybePop(),
                )
              : null,
          title: child!,
          actions: <Widget>[
            if (onDownloads) ...<Widget>[
              FushiIconButton(
                icon: Icons.add,
                tooltip: t.download_task_add,
                label: t.download_task_add,
                onTap: _openManualTaskDialog,
              ),
              FushiIconButton(
                key: const ValueKey<String>('browse-download-settings'),
                icon: Icons.settings_outlined,
                tooltip: t.download_settings,
                onTap: _openDownloadSettings,
              ),
            ],
          ],
        );
      },
      child: LibrarySectionTabs<BrowseTab>.controlled(
        tabs: <LibrarySectionTab<BrowseTab>>[
          for (final BrowseTab tab in tabs)
            LibrarySectionTab<BrowseTab>(value: tab, label: _tabLabel(tab)),
        ],
        controller: controller,
        focusIdPrefix: 'browse-tab',
      ),
    );
  }

  /// 「下载」页签：任务 / 订阅两段。
  Widget _buildDownloadsTab() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.gap,
          ),
          child: FushiSegmentedStrip<BrowseDownloadsSection>(
            key: const ValueKey<String>('browse-downloads-section-picker'),
            segments: <ButtonSegment<BrowseDownloadsSection>>[
              ButtonSegment<BrowseDownloadsSection>(
                value: BrowseDownloadsSection.tasks,
                label: Text(t.download_tasks_tab),
              ),
              ButtonSegment<BrowseDownloadsSection>(
                value: BrowseDownloadsSection.subscriptions,
                label: Text(t.download_subscriptions_tab),
              ),
            ],
            selected: _downloadsSection,
            onChanged: (BrowseDownloadsSection value) =>
                setState(() => _downloadsSection = value),
            minSegmentWidth: 72,
            alignment: Alignment.centerLeft,
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _downloadsSection.index,
            children: <Widget>[
              _buildTasks(),
              const VideoDownloadSubscriptionsPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTasks() {
    return AnimeDownloadDialog(
                        embedded: true,
                        tasksOnly: true,
                        showTasks: false,
                        onOpenSettings: _openDownloadSettings,
                        tasksBuilder: (
                          BuildContext context,
                          List<DownloadTaskEntry> legacy,
                        ) =>
                            DiscoveryDownloadTasksSection(
                          tasksBuilder: (
                            BuildContext context,
                            List<DownloadTaskEntry> direct,
                          ) =>
                              MangaDownloadTasksSection(
                            tasksBuilder: (
                              BuildContext context,
                              List<DownloadTaskEntry> manga,
                            ) =>
                                RemoteDownloadTasksSection(
                              tasksBuilder: (
                                BuildContext context,
                                List<DownloadTaskEntry> remote,
                              ) =>
                                  InterconnectDownloadTasksSection(
                              tasksBuilder: (
                                BuildContext context,
                                List<DownloadTaskEntry> interconnect,
                              ) =>
                                  VideoDownloadJobsPanel.database(
                              unified: true,
                              additionalTasks: <DownloadTaskEntry>[
                                ...legacy,
                                ...direct,
                                ...manga,
                                ...remote,
                                ...interconnect,
                              ],
                              database: ref.read(appProvider).database,
                              metricsLoader: ref
                                  .read(appProvider)
                                  .videoDownloadPipelineService
                                  ?.loadTaskSnapshots,
                              onRetry: (VideoDownloadJobRow job) async {
                                await ref
                                    .read(appProvider)
                                    .videoDownloadPipelineService
                                    ?.retryJob(job.jobId);
                              },
                              onResume: (VideoDownloadJobRow job) async {
                                await ref
                                    .read(appProvider)
                                    .videoDownloadPipelineService
                                    ?.resumeJob(job.jobId);
                              },
                              onCancel: (VideoDownloadJobRow job) async {
                                await ref
                                    .read(appProvider)
                                    .videoDownloadPipelineService
                                    ?.cancelJob(job.jobId);
                              },
                              onPairAudiobook: (VideoDownloadJobRow job) async {
                                await _pairDownloadedAudiobook(
                                  job,
                                );
                              },
                              onOpenDetails: (VideoDownloadJobRow job) async {
                                final appModel = ref.read(
                                  appProvider,
                                );
                                final pipeline =
                                    appModel.videoDownloadPipelineService;
                                final details = pipeline != null
                                    ? await pipeline.loadJobDetails(
                                        job.jobId,
                                      )
                                    : buildPersistedVideoDownloadJobDetails(
                                        job,
                                        await appModel.database
                                            .getVideoDownloadJobFiles(
                                          job.jobId,
                                        ),
                                      );
                                if (!context.mounted) return;
                                final String torrentId =
                                    (job.backendTaskId ?? job.torrentHash ?? '')
                                        .trim();
                                await showAppDialog<void>(
                                  context: context,
                                  builder: (
                                    BuildContext dialogContext,
                                  ) =>
                                      TorrentTaskDetailDialog.task(
                                    torrentId: torrentId,
                                    title: job.title,
                                    torrentTitle:
                                        job.resourceTitle?.trim().isNotEmpty ==
                                                true
                                            ? job.resourceTitle!.trim()
                                            : job.title,
                                    backendOverride: details.backend,
                                    liveDataAbsence: details.liveDataAbsence,
                                    initialSnapshot: details.snapshot,
                                    initialFiles: details.files,
                                  ),
                                );
                              },
                              onSetPriority: (
                                VideoDownloadJobRow job,
                                int priority,
                              ) async {
                                final pipeline = ref
                                    .read(appProvider)
                                    .videoDownloadPipelineService;
                                await pipeline?.setJobPriority(
                                  job.jobId,
                                  priority,
                                );
                              },
                              locationLoader: (VideoDownloadJobRow job) async {
                                final pipeline = ref
                                    .read(appProvider)
                                    .videoDownloadPipelineService;
                                return pipeline == null
                                    ? null
                                    : await pipeline.resolveJobLocation(
                                        job.jobId,
                                      );
                              },
                              onDelete: (
                                job, {
                                required bool deleteFiles,
                              }) async {
                                final appModel = ref.read(
                                  appProvider,
                                );
                                final pipeline =
                                    appModel.videoDownloadPipelineService;
                                if (pipeline != null) {
                                  await pipeline.deleteJob(
                                    job.jobId,
                                    deleteFiles: deleteFiles,
                                  );
                                } else {
                                  await deletePersistedVideoDownloadJob(
                                    database: appModel.database,
                                    job: job,
                                    deleteFiles: deleteFiles,
                                  );
                                }
                              },
                            ))),
                          ),
                        ),
                      );
  }

  @override
  Widget build(BuildContext context) {
    final List<BrowseTab> tabs = _visibleTabs(ref.watch(appProvider));
    // 初始页签：跳转请求 / initialTab 播种进 [_selectedTab]，此刻不可见就落第一个
    // 页签（见 [_syncTabController]）。
    final TabController controller = _syncTabController(tabs);
    // 整页是 .torrent 的落点（桌面拖放）；移动端 FushiFileDropTarget 直接透传。
    return FushiFileDropTarget(
      debugLabel: 'downloads',
      onDrop: _handleDownloadsDrop,
      child: Scaffold(
        // BUG-1003：内联下载流程把 apikey/搜番等输入框全放在页面上半部，下载
        // 任务折叠区贴底、中段结果列表是唯一的 Expanded。默认
        // resizeToAvoidBottomInset:true 时，手机软键盘弹出会压掉 body 高度、
        // 顶掉贴底任务区。关掉 inset 让键盘只覆盖下半部结果/任务区（打字时
        // 本就不看），顶部输入框保持可见、布局不反流。
        resizeToAvoidBottomInset: false,
        // 作为 home tab 时外层已有 SafeArea，这里的 SafeArea 兜的是独立 push
        // 进来（设置入口）时的状态栏避让，双层无副作用。
        body: SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              if (!isCupertinoPlatform(context))
                _buildHeader(controller, tabs),
              Expanded(
                // 只在选中页签变化时重建（controller 的 notifyListeners 只在下标
                // 变化时触发），用来给隐藏页签关焦点。
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (BuildContext context, Widget? _) => TabBarView(
                    // 页签序列一变就整个换新：旧 TabBarView 的 PageController 停在
                    // 旧下标上，换绑新控制器的那一帧会先把旧下标处（多半是新插进来
                    // 的「来源」）建出来再跳走——白建一个页签还被保活。
                    key: ValueKey<String>(
                      tabs.map((BrowseTab tab) => tab.name).join(','),
                    ),
                    controller: controller,
                    children: <Widget>[
                      for (final BrowseTab tab in tabs)
                        _BrowseTabKeepAlive(
                          key: ValueKey<BrowseTab>(tab),
                          active: tabs[controller.index] == tab,
                          child: switch (tab) {
                            BrowseTab.sources ||
                            BrowseTab.extensions => _buildOnlineTab(tab),
                            BrowseTab.discover => _buildResourceHub(),
                            BrowseTab.downloads => _buildDownloadsTab(),
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [TabBarView] 的页签外壳：横滑离开的页签**保活**（TabBarView 默认把离屏页签
/// dispose 掉，回来时发现页重拉网络、在线来源丢搜索与滚动）；未选中的页签排除出
/// 焦点遍历——保活的离屏页签仍在树上，不排除的话 Tab / 方向键会走进看不见的页签。
class _BrowseTabKeepAlive extends StatefulWidget {
  const _BrowseTabKeepAlive({
    required this.active,
    required this.child,
    super.key,
  });

  final bool active;
  final Widget child;

  @override
  State<_BrowseTabKeepAlive> createState() => _BrowseTabKeepAliveState();
}

class _BrowseTabKeepAliveState extends State<_BrowseTabKeepAlive>
    with AutomaticKeepAliveClientMixin<_BrowseTabKeepAlive> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ExcludeFocus(excluding: !widget.active, child: widget.child);
  }
}

/// 下载设置页：内置引擎 / qBittorrent、在线服务入口、下载路由。原「下载」页的
/// 「设置」页签，2026-09-27 起改为「浏览 › 下载」页头齿轮 push 的独立页。
class BrowseDownloadSettingsPage extends ConsumerWidget {
  const BrowseDownloadSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _BrowseSubPage(
      title: t.download_settings,
      child: ListView(
                        children: <Widget>[
                          const TorrentSettingsSection(),
                          // 索引器 / 字幕来源 / 发现来源已迁到设置 → 在线服务
                          // （第三方凭据一个家）；下载页设置 tab 留一条跳转，
                          // 番剧下载对话框「去设置」落到这里仍能一步到达。
                          // 「在线服务」分类被 [ModuleId.services] 关掉时这一行
                          // 不渲染：它指向的设置分类此刻已从设置页消失，留着就是
                          // 一条通往不存在页面的死路。
                          if (ref
                              .watch(appProvider)
                              .moduleVisibility
                              .isEnabled(ModuleId.services))
                            Builder(
                              builder: (BuildContext rowContext) =>
                                  AdaptiveSettingsNavigationRow(
                                    title: t.settings_destination_services,
                                    subtitle: t.settings_services_link_subtitle,
                                    icon: Icons.cloud_outlined,
                                    showIcon: true,
                                    onTap: () => Navigator.of(rowContext).push(
                                      adaptivePageRoute(
                                        context: rowContext,
                                        builder: (_) => SettingsDetailPage(
                                          destination:
                                              buildServicesDestination(),
                                        ),
                                      ),
                                    ),
                                  ),
                            ),
                          const VideoExternalProviderSettingsSection(
                            scope: VideoExternalProviderScope.downloadRouting,
                          ),
                        ],
                      ),
    );
  }
}

/// 浏览页 push 出来的二级页外壳：带返回键的统一门头 + 正文。
class _BrowseSubPage extends StatelessWidget {
  const _BrowseSubPage({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            FushiPageHeader(
              title: title,
              leading: FushiIconButton(
                icon: Icons.arrow_back,
                tooltip: t.back,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

enum _DownloadsResourceDomain { books, manga, games, video }

/// 资源域 → 所属功能模块（穷尽 switch：加域时编译器强制补齐这张表）。
///
/// 四个域各自复用对应库的生产发现页，所以门控判据就是那个库的模块开关——关掉
/// 视频模块还留着「视频」资源域，等于给一个已经关掉的库继续找片源。
ModuleId _moduleOfResourceDomain(_DownloadsResourceDomain domain) =>
    switch (domain) {
      _DownloadsResourceDomain.books => ModuleId.books,
      _DownloadsResourceDomain.manga => ModuleId.manga,
      _DownloadsResourceDomain.games => ModuleId.games,
      _DownloadsResourceDomain.video => ModuleId.video,
    };

/// 此刻可见的资源域，顺序即分段条顺序（枚举声明序）。
///
/// games 域是「找 galgame 资源下到本机」，只对本机游戏库形态成立；Android 的
/// games 模块是串流接收端（游戏装在 Windows 主机上），不出这个域。
List<_DownloadsResourceDomain> _visibleResourceDomains(
  ModuleVisibility visibility, {
  required GamesModuleForm? gamesForm,
}) => <_DownloadsResourceDomain>[
  for (final _DownloadsResourceDomain domain in _DownloadsResourceDomain.values)
    if (visibility.isEnabled(_moduleOfResourceDomain(domain)) &&
        (domain != _DownloadsResourceDomain.games ||
            gamesForm == GamesModuleForm.localLibrary))
      domain,
];

/// 在线域 → 所属功能模块（穷尽 switch）：关掉某个库模块，它的在线来源一并不出。
ModuleId _moduleOfOnlineDomain(OnlineSourcesDomain domain) => switch (domain) {
  OnlineSourcesDomain.novel => ModuleId.books,
  OnlineSourcesDomain.manga => ModuleId.manga,
  OnlineSourcesDomain.video => ModuleId.video,
};

/// 此刻可见的在线域：模块开着、且本平台有该域的在线来源宿主。
List<OnlineSourcesDomain> _visibleOnlineDomains(ModuleVisibility visibility) =>
    <OnlineSourcesDomain>[
      for (final OnlineSourcesDomain domain in OnlineSourcesDomain.values)
        if (visibility.isEnabled(_moduleOfOnlineDomain(domain)) &&
            isOnlineSourcesDomainAvailable(domain))
          domain,
    ];
