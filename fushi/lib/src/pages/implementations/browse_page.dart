import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show AudiobookRepository, AudiobookStorage, SrtBookRepository;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_transcribe_tasks_section.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/torrent/torrent_network_diagnosis.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/torrent/torrent_network_issue_banner.dart';
import 'package:fushi/src/media/downloads/manga_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/pages/implementations/remote_download_tasks_section.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
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
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeController,
        FushiFloatingChromeInsetPadding,
        FushiFloatingChromeOverlay,
        FushiFloatingChromeScope;
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
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
enum BrowseTab { discover, sources, extensions, downloads }

/// 顶层页签接力（二级标签越界横滑）时，目标页签的二级标签要不要按衔接方向
/// 重新落端（往后落首段、往前落末段）。
///
/// 来源 ↔ 扩展之间**不**落端：两者共用同一份内容域选择（来回切不丢选择），
/// 改它就等于在拖动途中改被拖那一页的二级下标，标签条与页面错位（PR #1735）。
/// 其余页签各持自己的二级状态，照常落端。
bool browseHandOffRealignsSections(BrowseTab from, BrowseTab to) {
  bool isOnline(BrowseTab tab) =>
      tab == BrowseTab.sources || tab == BrowseTab.extensions;
  return !(isOnline(from) && isOnline(to));
}

/// 测试入口：直接挂一份浏览页的「二级标签 + 横滑页面」（真页面要起 Mihon /
/// LNReader manager，widget 测试挂不起来）。
@visibleForTesting
Widget debugBrowseSwipeSections<T extends Object>({
  required List<LibrarySectionTab<T>> tabs,
  required T selected,
  required Widget Function(T value) pageBuilder,
  Widget? trailing,
}) =>
    _BrowseSwipeSections<T>(
      pickerKey: const ValueKey<String>('debug-browse-swipe-sections'),
      tabs: tabs,
      selected: selected,
      onChanged: (T _) {},
      focusIdPrefix: 'debug-browse-swipe-sections',
      pageBuilder: pageBuilder,
      onEdgeOverscroll: (int _) {},
      trailing: trailing,
    );

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

  late BrowseDownloadsSection _downloadsSection =
      widget.navigationRequest?.downloadsSection ??
      widget.initialDownloadsSection;

  _DownloadsResourceDomain _resourceDomain = _DownloadsResourceDomain.books;

  /// 页头动作（下载页签的「添加任务」+ 下载设置）登记的槽：由页签行右侧的
  /// 悬浮按钮组胶囊画出（与库页壳 [MediaLibraryShell] 同构）。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  /// 头部（一级页签行 + 各页签的二级页签行）随滚动收放的状态：与四个库页
  /// 同一套规则（下滚收起、上滚弹回、只认主滚动区、平滑滚轮拉回不算）。头部
  /// 叠在正文上，收放不改正文视口（BUG-2975）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  bool _onScroll(ScrollNotification notification) {
    // 保活的离屏页签 / 内容域（TickerMode 关着）发来的通知不算；横向翻页在
    // controller 内按轴过滤。
    if (!fushiNotificationFromVisibleSubtree(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

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
    final List<OnlineSourcesDomain> onlineDomains = visibleOnlineSourcesDomains(
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
    _actionsSlot.release(this);
    _actionsSlot.dispose();
    _tabController?.dispose();
    _chrome.dispose();
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
        final BrowseTab tab = _controllerTabs[next.index];
        // 换了页签：新页面从顶部开始，头部回来、遮罩撤掉。
        if (tab != _selectedTab) _chrome.resetToTop();
        _selectedTab = tab;
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
    final bool online = visibleOnlineSourcesDomains(
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
    // 发现排第一（2026-09-28 用户拍板）：打开浏览默认落在发现页签。
    return <BrowseTab>[
      if (discover) BrowseTab.discover,
      if (online) BrowseTab.sources,
      if (online) BrowseTab.extensions,
      BrowseTab.downloads,
    ];
  }

  String _tabLabel(BrowseTab tab) => switch (tab) {
    BrowseTab.sources => t.media_import_segment_sources,
    BrowseTab.extensions => t.media_import_segment_extensions,
    BrowseTab.discover => t.library_view_discover,
    BrowseTab.downloads => t.nav_downloads,
  };

  void _selectOnlineDomain(OnlineSourcesDomain domain) {
    if (domain == _onlineDomain) return;
    _chrome.resetToTop();
    setState(() => _onlineDomain = domain);
  }

  /// 来源 / 扩展页签：内容域选择条 + 各域可横滑、保活的在线来源面。
  Widget _buildOnlineTab(BrowseTab tab) {
    final AppModel appModel = ref.watch(appProvider);
    final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
      appModel.moduleVisibility,
    );
    if (domains.isEmpty) return const SizedBox.shrink();
    final OnlineSourcesDomain selected = domains.contains(_onlineDomain)
        ? _onlineDomain
        : domains.first;
    final OnlineSourcesSection section = tab == BrowseTab.sources
        ? OnlineSourcesSection.sources
        : OnlineSourcesSection.extensions;
    return _BrowseSwipeSections<OnlineSourcesDomain>(
      pickerKey: ValueKey<String>('browse-${tab.name}-domain-picker'),
      tabs: <LibrarySectionTab<OnlineSourcesDomain>>[
        for (final OnlineSourcesDomain domain in domains)
          LibrarySectionTab<OnlineSourcesDomain>(
            value: domain,
            label: onlineSourcesDomainLabel(domain),
          ),
      ],
      selected: selected,
      onChanged: _selectOnlineDomain,
      focusIdPrefix: 'browse-${tab.name}-domain',
      onEdgeOverscroll: (int delta) => _handOffFrom(tab, delta),
      trailing: tab == BrowseTab.extensions
          ? FushiIconButton(
              key: const ValueKey<String>('browse-extensions-stores'),
              icon: Icons.hub_outlined,
              tooltip: t.media_import_segment_stores,
              label: t.media_import_segment_stores,
              onTap: () => openOnlineSourceStores(context, selected),
            )
          : null,
      // 在线来源面的主滚动视图自己把头部高度加成顶部 sliver（内容滚到头部底下）。
      pageHandlesInset: true,
      pageBuilder: (OnlineSourcesDomain domain) => BrowseOnlineSourcesView(
        key: ValueKey<String>('browse-${tab.name}-${domain.name}'),
        domain: domain,
        section: section,
      ),
    );
  }

  /// 二级标签横滑越过首 / 尾段时，把手势交给相邻的顶层页签：从 [from] 往 [delta]
  /// 方向（+1 下一个 / -1 上一个）切过去，并让目标页签的二级标签落在衔接的那一端
  /// （往后落首段、往前落末段）——四个页签的二级标签连成一条可一路滑过去的带子。
  void _handOffFrom(BrowseTab from, int delta) {
    final TabController? controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    final int index = _controllerTabs.indexOf(from);
    final int target = index + delta;
    if (index < 0 || index != controller.index) return;
    if (target < 0 || target >= _controllerTabs.length) return;
    // 来源 / 扩展共用同一份内容域：两者之间接力只切顶层页签、落在同一个域上。
    // 若按「往后首段 / 往前末段」去改共享域，被拖的那一页的二级控制器会在拖动
    // 途中被改下标（TabBarView 拖动中不跟随跳页），标签条与页面就此错位。
    if (!browseHandOffRealignsSections(from, _controllerTabs[target])) {
      controller.animateTo(target);
      return;
    }
    final bool toFirst = delta > 0;
    final AppModel appModel = ref.read(appProvider);
    setState(() {
      switch (_controllerTabs[target]) {
        case BrowseTab.sources || BrowseTab.extensions:
          final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
            appModel.moduleVisibility,
          );
          if (domains.isNotEmpty) {
            _onlineDomain = toFirst ? domains.first : domains.last;
          }
        case BrowseTab.discover:
          final List<_DownloadsResourceDomain> domains =
              _visibleResourceDomains(
            appModel.moduleVisibility,
            gamesForm: appModel.gamesModuleForm,
          );
          if (domains.isNotEmpty) {
            _resourceDomain = toFirst ? domains.first : domains.last;
          }
        case BrowseTab.downloads:
          _downloadsSection = toFirst
              ? BrowseDownloadsSection.values.first
              : BrowseDownloadsSection.values.last;
      }
    });
    controller.animateTo(target);
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
    _chrome.resetToTop();
    setState(() => _resourceDomain = domain);
  }

  /// 漫画发现（「发现」页签里）的「管理来源」去处：回到本页并切到「来源 › 漫画」。
  /// 漫画域此刻不可见时为 null（空态只给文案、不给点了没反应的按钮）。
  ///
  /// 以本页自己的路由为界弹掉上面压着的路由（全源搜索页、详情页），与压了几层
  /// 无关——与库页壳 `MediaLibraryShell` 的「回到壳」同一口径。
  VoidCallback? _mangaSourcesAction() {
    final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
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
        _DownloadsResourceDomain.books => MediaDiscoveryPage(
            kinds: const <DiscoveryMediaKind>[
              DiscoveryMediaKind.novel,
              DiscoveryMediaKind.audiobook,
            ],
            onAiAcquire: _aiAcquireAction(domain),
          ),
        _DownloadsResourceDomain.manga => MangaDiscoveryPage(
            embedded: true,
            onOpenSources: _mangaSourcesAction(),
            onAiAcquire: _aiAcquireAction(domain),
          ),
        _DownloadsResourceDomain.games => MediaDiscoveryPage(
            kinds: const <DiscoveryMediaKind>[DiscoveryMediaKind.game],
            onAiAcquire: _aiAcquireAction(domain),
          ),
        _DownloadsResourceDomain.video => _buildVideoResourceTab(),
      };

  /// 「AI 下载」入口（小说 / 漫画 / 游戏发现页；视频域是首页注入的「AI 下视频」）。
  ///
  /// 门与点击行为在 [discoveryAiAcquireAction]（库页「发现」子标签共用）。
  ValueChanged<String>? _aiAcquireAction(_DownloadsResourceDomain domain) {
    final (AiMediaAcquisitionDomain, OnlineSourcesDomain?)? target =
        switch (domain) {
      _DownloadsResourceDomain.books => (
          AiMediaAcquisitionDomain.novel,
          OnlineSourcesDomain.novel,
        ),
      _DownloadsResourceDomain.manga => (
          AiMediaAcquisitionDomain.manga,
          OnlineSourcesDomain.manga,
        ),
      _DownloadsResourceDomain.games => (AiMediaAcquisitionDomain.game, null),
      _DownloadsResourceDomain.video => null,
    };
    if (target == null) return null;
    final (AiMediaAcquisitionDomain aiDomain, OnlineSourcesDomain? online) =
        target;
    return discoveryAiAcquireAction(
      context: context,
      readAppModel: () => ref.read(appProvider),
      domain: aiDomain,
      domainLabel: _resourceDomainLabel(domain),
      onlineDomain: online,
    );
  }

  /// 二级标签页只负责选择内容域；域内筛选、搜索与结果展示全部沿用各模块
  /// 自己的生产发现页。四个固定目的地直接可见，避免无标签的表单型下拉框
  /// 单独悬在搜索区上方。域页可横滑切换，首次访问后保持挂载，来回切换不丢
  /// 搜索词、结果和滚动位置。
  Widget _buildResourceHub() {
    // 模块门控：四个域分属 books / manga / games / video，关掉的模块不出段，
    // 它的发现页也一并不建（隐藏域不该继续挂在树上跑网络）。
    final AppModel appModel = ref.watch(appProvider);
    final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
      appModel.moduleVisibility,
      gamesForm: appModel.gamesModuleForm,
    );
    // 四个域全关：整块资源分区不渲染——空的标签条 + 空页面是「渲染出来但点不
    // 出任何东西」，正是要消灭的形态。
    if (domains.isEmpty) return const SizedBox.shrink();
    // 当前域在渲染期回落到第一个可见域：用户在设置里关掉当前域后本页可能仍挂着
    // （保活 tab），选中值不在标签里时标签条会落到错误的下标上。
    final _DownloadsResourceDomain selected = domains.contains(_resourceDomain)
        ? _resourceDomain
        : domains.first;
    return _BrowseSwipeSections<_DownloadsResourceDomain>(
      pickerKey: const ValueKey<String>('downloads-resource-type-picker'),
      tabs: <LibrarySectionTab<_DownloadsResourceDomain>>[
        for (final _DownloadsResourceDomain domain in domains)
          LibrarySectionTab<_DownloadsResourceDomain>(
            value: domain,
            label: _resourceDomainLabel(domain),
          ),
      ],
      selected: selected,
      onChanged: _selectResourceDomain,
      focusIdPrefix: 'browse-discover-domain',
      onEdgeOverscroll: (int delta) => _handOffFrom(BrowseTab.discover, delta),
      pageBuilder: (_DownloadsResourceDomain domain) => KeyedSubtree(
        key: ValueKey<String>('downloads-resource-${domain.name}'),
        child: _buildResourceDomain(domain),
      ),
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
        FushiSnackBar(content: Text(t.drag_drop_unsupported_on_downloads)),
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

  /// 统一门头：与四个库页（[MediaLibraryShell]）同一套 M3E 浮动工具栏行
  /// （[FushiFloatingChromeBar]）——外壳大标题下面一行，左边是贴合内容宽的
  /// 一级页签单层浮动胶囊（摆不下在胶囊里横滑渐隐），右边是同高的悬浮按钮组
  /// 胶囊；整行左右缘与大标题、页面内容同一条页边。独立 push 进来（无 home
  /// 壳）时页签胶囊左边多一枚返回键圆胶囊。
  ///
  /// 页签走 [LibrarySectionTabs.controlled]：本页的 [TabController] 同时驱动
  /// [TabBarView]，横滑时指示器跟手连续滑动。
  ///
  /// 页头动作只在「下载」页签出现（「添加任务」+ 下载设置）：它们不是来源 / 扩展 /
  /// 发现的动作。动作登记进本页自己的 [_actionsSlot]，由按钮组胶囊画出。
  Widget _buildHeader(TabController controller, List<BrowseTab> tabs) {
    // 下拉框会临时 push PopupRoute；只看本页自己的 PageRoute，避免展开菜单时
    // 左上角凭空出现返回键。
    final bool showBackButton = ModalRoute.of(context)?.isFirst == false;
    // 不在首页外壳里（没有外壳大标题）时，工具栏行顶上留一点呼吸位。
    final bool shellTitle = FushiShellTitleScope.maybeTitleOf(context) != null;
    final double page = FushiDesignTokens.of(context).spacing.page;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final bool onDownloads =
            tabs[controller.index.clamp(0, tabs.length - 1)] ==
            BrowseTab.downloads;
        final List<Widget> actions = <Widget>[
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
        ];
        if (actions.isEmpty) {
          _actionsSlot.release(this);
        } else {
          _actionsSlot.claim(
            this,
            visible: true,
            actions: FushiShellHeaderActions(actions: actions),
          );
        }
        return FushiFloatingChromeBar(
          slot: _actionsSlot,
          padding: shellTitle
              ? null
              : EdgeInsets.fromLTRB(page, page / 2, page, 4),
          leading: showBackButton
              ? fushiFloatingLeading(
                  FushiIconButton(
                    icon: Icons.arrow_back,
                    tooltip: t.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                )
              : null,
          tabs: child!,
        );
      },
      child: LibrarySectionTabs<BrowseTab>.controlled(
        tabs: <LibrarySectionTab<BrowseTab>>[
          for (final BrowseTab tab in tabs)
            LibrarySectionTab<BrowseTab>(value: tab, label: _tabLabel(tab)),
        ],
        controller: controller,
        focusIdPrefix: 'browse-tab',
        floating: true,
      ),
    );
  }

  /// 「下载」页签：任务 / 订阅两段（可横滑切换）。
  Widget _buildDownloadsTab() {
    return _BrowseSwipeSections<BrowseDownloadsSection>(
      pickerKey: const ValueKey<String>('browse-downloads-section-picker'),
      tabs: <LibrarySectionTab<BrowseDownloadsSection>>[
        LibrarySectionTab<BrowseDownloadsSection>(
          value: BrowseDownloadsSection.tasks,
          label: t.download_tasks_tab,
        ),
        LibrarySectionTab<BrowseDownloadsSection>(
          value: BrowseDownloadsSection.subscriptions,
          label: t.download_subscriptions_tab,
        ),
      ],
      selected: _downloadsSection,
      onChanged: (BrowseDownloadsSection value) {
        _chrome.resetToTop();
        setState(() => _downloadsSection = value);
      },
      focusIdPrefix: 'browse-downloads-section',
      onEdgeOverscroll: (int delta) =>
          _handOffFrom(BrowseTab.downloads, delta),
      pageBuilder: (BrowseDownloadsSection section) => switch (section) {
        BrowseDownloadsSection.tasks => _buildTasks(),
        BrowseDownloadsSection.subscriptions =>
          const VideoDownloadSubscriptionsPanel(),
      },
    );
  }

  Widget _buildTasks() {
    // 有声书「转录后入库」任务包在最外层：它的条目经闭包并进下面统一列表的
    // additionalTasks，与各下载来源并列排序/筛选。
    final Widget tasks = AudiobookTranscribeTasksSection(
      tasksBuilder: (BuildContext context, List<DownloadTaskEntry> transcribe) =>
          _buildTaskSources(transcribe),
    );
    // BUG-2950：内置引擎网络被掐（fake-ip 不转发 UDP / DHT 不可达）时在任务区
    // 顶部说明原因；无问题时横幅零高度，任务列表布局不变。
    return Column(
      children: <Widget>[
        ValueListenableBuilder<TorrentNetworkIssue>(
          valueListenable: ref.read(appProvider).torrentNetworkIssue,
          builder: (BuildContext context, TorrentNetworkIssue issue, _) =>
              TorrentNetworkIssueBanner(
            issue: issue,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          ),
        ),
        Expanded(child: tasks),
      ],
    );
  }

  Widget _buildTaskSources(List<DownloadTaskEntry> transcribe) {
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
                                ...transcribe,
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
                                    networkIssue:
                                        appModel.torrentNetworkIssue,
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
      // 2026-10 体验优化：BUG-1003 的 inset 关闭原先对整页生效，来源 / 扩展 /
      // 发现页签里的搜索框在手机上会被软键盘直接盖住、列表也滚不到底。只在
      // 「下载」页签（贴底任务区）关 inset，其它页签恢复默认让键盘顶起 body。
      child: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? body) {
          final bool onDownloads =
              tabs[controller.index.clamp(0, tabs.length - 1)] ==
              BrowseTab.downloads;
          return Scaffold(
            // BUG-1003：下载页签把输入框放在上半部、任务折叠区贴底、中段列表是
            // 唯一的 Expanded。默认 resizeToAvoidBottomInset:true 时，手机软键盘
            // 弹出会压掉 body 高度、顶掉贴底任务区。在该页签关掉 inset 让键盘
            // 只覆盖下半部（打字时本就不看），顶部输入框保持可见、布局不反流。
            resizeToAvoidBottomInset: !onDownloads,
            body: body,
          );
        },
        // 作为 home tab 时外层已有 SafeArea，这里的 SafeArea 兜的是独立 push
        // 进来（设置入口）时的状态栏避让，双层无副作用。
        child: SafeArea(
          bottom: false,
          // 头部（一级页签行）叠在正文上、随滚动收放（与库页同一套，见
          // [FushiFloatingChromeOverlay]）；各页签的二级页签行在 [_BrowseSwipeSections]
          // 里同样叠放，排在这一行下面、一起收。
          child: FushiFloatingChromeScope(
            controller: _chrome,
            child: FushiFloatingChromeOverlay(
              chrome: isCupertinoPlatform(context)
                  ? const SizedBox.shrink()
                  : _buildHeader(controller, tabs),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
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
            ),
          ),
        ),
      ),
    );
  }
}

/// 页面内一排二级标签 + 可横滑的对应页面（MD3 secondary tabs + [TabBarView]），
/// 「浏览」四个页签共用：来源 / 扩展的内容域、发现的内容域、下载的任务 / 订阅。
///
/// * 标签条是贴合内容宽的紧凑分段胶囊（`floating` + `secondary`），摆不下时
///   在胶囊里横滑。
/// * 页面可左右横滑（移动端触屏；桌面鼠标不拖页，走标签 / 方向键），首次滑到 /
///   点到的页面保活，来回切不丢搜索词、结果与滚动位置。
/// * 横滑越过首 / 尾段时经 [onEdgeOverscroll] 把手势交给宿主切顶层页签：内层
///   [TabBarView] 在手势竞技场里恒先于外层胜出，不接力的话滑到末段就再也滑不到
///   下一个顶层页签。
///
/// 选中值的真相在宿主（[selected] / [onChanged]），本组件的 [TabController] 是它的
/// 投影：宿主改值（跳转请求、接力落端）时就地跟过去。
class _BrowseSwipeSections<T extends Object> extends StatefulWidget {
  const _BrowseSwipeSections({
    required this.pickerKey,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.focusIdPrefix,
    required this.pageBuilder,
    required this.onEdgeOverscroll,
    this.trailing,
    this.pageHandlesInset = false,
    super.key,
  });

  /// true：[pageBuilder] 的页面自己消费 [FushiFloatingChromeInset]（主滚动视图
  /// 加顶部 sliver）；false：页面整体下移头部高度（[FushiFloatingChromeInsetPadding]）。
  final bool pageHandlesInset;

  /// 标签条的稳定 key（焦点导航与行为验证用）。
  final Key pickerKey;
  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;
  final String focusIdPrefix;
  final Widget Function(T value) pageBuilder;

  /// 越过首段（-1）/ 末段（+1）继续横滑时回调（每次拖动手势至多一次）。
  final ValueChanged<int> onEdgeOverscroll;

  /// 标签条右侧的动作（如扩展页签的「仓库」）。
  final Widget? trailing;

  @override
  State<_BrowseSwipeSections<T>> createState() =>
      _BrowseSwipeSectionsState<T>();
}

/// 越界横滑累计到这个距离（逻辑像素）才接力给顶层页签：边缘的轻微误拖不该把
/// 整页切走。
const double _kSectionEdgeHandOffDistance = 48.0;

class _BrowseSwipeSectionsState<T extends Object>
    extends State<_BrowseSwipeSections<T>> with TickerProviderStateMixin {
  TabController? _controller;

  /// [_controller] 对应的段值序列。
  List<T> _controllerValues = <T>[];

  double _edgeOverscroll = 0;
  bool _handedOff = false;

  int get _selectedIndex {
    final int index = widget.tabs.indexWhere(
      (LibrarySectionTab<T> tab) => tab.value == widget.selected,
    );
    return index < 0 ? 0 : index;
  }

  /// 段序列变了（模块开关增减内容域）才换控制器；否则沿用，并把下标对齐到宿主
  /// 的 [_BrowseSwipeSections.selected]。
  TabController _syncController() {
    final List<T> values = <T>[
      for (final LibrarySectionTab<T> tab in widget.tabs) tab.value,
    ];
    final TabController? current = _controller;
    if (current != null && listEquals(values, _controllerValues)) {
      final int index = _selectedIndex;
      if (!current.indexIsChanging && current.index != index) {
        // 宿主改了选中值（跳转请求 / 顶层接力落端）：此刻多半不在屏上，直接跳。
        current.index = index;
      }
      return current;
    }
    final TabController next = TabController(
      length: values.length,
      initialIndex: _selectedIndex,
      // eink：横滑动画 = 一串局部刷新的残影，归零。
      animationDuration: einkSafeDuration(context, kTabScrollDuration),
      vsync: this,
    );
    next.addListener(() {
      if (!identical(next, _controller)) return;
      final T value = _controllerValues[next.index];
      if (value != widget.selected) widget.onChanged(value);
    });
    _controller = next;
    _controllerValues = List<T>.unmodifiable(values);
    // 旧控制器还挂在本帧之前的标签条 / TabBarView 上：等这一帧换绑完再释放。
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  bool _handleScroll(ScrollNotification notification) {
    // 只看本层 TabBarView 的横向翻页；页面里的列表 / 横排封面自己的滚动不算。
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _edgeOverscroll = 0;
      _handedOff = false;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_handedOff) {
      // 只接力手指拖动的越界；惯性滑到头的越界不算（那不是「还要往下一个滑」）。
      _edgeOverscroll += notification.overscroll;
      if (_edgeOverscroll.abs() >= _kSectionEdgeHandOffDistance) {
        _handedOff = true;
        widget.onEdgeOverscroll(_edgeOverscroll > 0 ? 1 : -1);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TabController controller = _syncController();
    // 只剩一个段（其余内容域被模块开关 / 平台门关掉）：一排只有一个标签的二级
    // 页签既不能切换、又占一整行纵向空间，还会被误读成标题。此时不画标签条，
    // 只在有尾随动作时留下那一行放动作。
    final bool showTabs = widget.tabs.length > 1;
    // 二级页签行叠在页面上、与一级页签行同一份显隐（[FushiFloatingChromeOverlay]
    // 读同一个作用域），收放不改页面视口。
    return FushiFloatingChromeOverlay(
      chrome: !(showTabs || widget.trailing != null)
          ? const SizedBox.shrink()
          : Padding(
            // 与上面的一级页签浮动胶囊、页面内容同一条页边（左缘对齐）；
            // 顶上 8 + 浮动工具栏底边 4 = 两级页签之间 12。
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            child: Row(
              children: <Widget>[
                if (showTabs)
                  Expanded(
                    // 二级内容域：贴合内容宽的紧凑扁平分段胶囊（比一级悬浮
                    // 页签胶囊矮一档、不浮），摆不下在胶囊里横滑。
                    child: LibrarySectionTabs<T>.controlled(
                      key: widget.pickerKey,
                      tabs: widget.tabs,
                      controller: controller,
                      focusIdPrefix: widget.focusIdPrefix,
                      secondary: true,
                      floating: true,
                    ),
                  )
                else
                  const Spacer(),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
      child: NotificationListener<ScrollNotification>(
            onNotification: _handleScroll,
            // 只在选中段变化时重建，用来给离屏段关焦点与 ticker。
            child: AnimatedBuilder(
              animation: controller,
              builder: (BuildContext context, Widget? _) => TabBarView(
                // 段序列一变就整个换新（同顶层页签的理由）。
                key: ValueKey<String>(_controllerValues.join(',')),
                controller: controller,
                children: <Widget>[
                  for (final T value in _controllerValues)
                    _BrowseTabKeepAlive(
                      key: ValueKey<T>(value),
                      active: _controllerValues[controller.index] == value,
                      child: widget.pageHandlesInset
                          ? widget.pageBuilder(value)
                          : FushiFloatingChromeInsetPadding(
                              child: widget.pageBuilder(value),
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
/// 焦点遍历——保活的离屏页签仍在树上，不排除的话 Tab / 方向键会走进看不见的页签；
/// 也关掉它的 ticker（离屏页的转圈 / 动画不该继续跑）。
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
    // 保活页签同时挂在树上：各给一份主滚动控制器，否则多个页签的主滚动视图
    // 附着同一个外壳控制器、Scrollbar 断言。
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(
        excluding: !widget.active,
        child: SectionPrimaryScrollScope(child: widget.child),
      ),
    );
  }
}

/// 下载设置页：内置引擎 / qBittorrent、在线服务入口、下载路由。原「下载」页的
/// 「设置」页签，2026-09-27 起改为「浏览 › 下载」页头齿轮 push 的独立页。
class BrowseDownloadSettingsPage extends ConsumerWidget {
  const BrowseDownloadSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return BrowseSubPage(
      title: t.download_settings,
      // 与设置详情页同一种页面：页边距由这里给，正文全是真正的设置分组
      // （MD3 分段卡 / Apple inset grouped），组件自己不再缩进。
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.gap,
          tokens.spacing.page,
          tokens.spacing.page + MediaQuery.paddingOf(context).bottom,
        ),
        children: <Widget>[
          const TorrentSettingsSection(),
          // 索引器 / 字幕来源 / 发现来源已迁到设置 → 在线服务（第三方凭据一个家）；
          // 下载设置页留一条跳转，番剧下载对话框「去设置」落到这里仍能一步到达。
          // 「在线服务」分类被 [ModuleId.services] 关掉时这一组不渲染：它指向的
          // 设置分类此刻已从设置页消失，留着就是一条通往不存在页面的死路。
          if (ref
              .watch(appProvider)
              .moduleVisibility
              .isEnabled(ModuleId.services))
            AdaptiveSettingsSection(
              children: <Widget>[
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
                              destination: buildServicesDestination(),
                            ),
                          ),
                        ),
                      ),
                ),
              ],
            ),
          const VideoExternalProviderSettingsSection(
            scope: VideoExternalProviderScope.downloadRouting,
          ),
        ],
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

/// 此刻可见的资源域，顺序即标签顺序（枚举声明序）。
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
