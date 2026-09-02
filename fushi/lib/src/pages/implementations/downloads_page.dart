import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show AudiobookRepository, AudiobookStorage, SrtBookRepository;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/discovery/discovery_download_tasks_section.dart';
import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_tasks_section.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
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

/// 独立「下载」页：资源、任务、订阅、设置共用一个下载中心。
///
/// 资源页先选择内容类型，再直接复用书架、漫画、游戏、视频各自的发现页。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({
    super.key,
    this.initialShowSettings = false,
    this.initialTabIndex = 0,
    this.videoDiscoveryController,
    this.videoDiscoveryActions = const VideoDiscoveryActions(),
  });

  /// 初始即显示设置面板（「后端未配置」横幅的「去设置」从对话框入口 push
  /// 本页直落配置用）。默认 false = 正常下载流程。
  final bool initialShowSettings;

  /// 发现详情“管理订阅”等入口可直接落到对应子页。
  final int initialTabIndex;

  /// 与视频模块共用同一套生产发现服务，避免下载页另起网络生命周期。
  final VideoDiscoveryController? videoDiscoveryController;

  /// 视频发现详情、资源搜索与订阅动作由首页组合根统一注入。
  final VideoDiscoveryActions videoDiscoveryActions;

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  _DownloadsResourceDomain _resourceDomain = _DownloadsResourceDomain.books;
  final Set<_DownloadsResourceDomain> _visitedResourceDomains =
      <_DownloadsResourceDomain>{_DownloadsResourceDomain.books};
  bool _hasLegacyAnimeTasks = false;

  void _setLegacyAnimeTaskPresence(bool present) {
    if (!mounted || _hasLegacyAnimeTasks == present) return;
    setState(() => _hasLegacyAnimeTasks = present);
  }

  /// 「补对齐文件」：把已下完的孤立音频直接喂进统一导入对话框。
  ///
  /// 本仓有声书是字幕对齐驱动的，`download-only-audiobook` 任务落地的只有音频
  /// （CoreAudio/TMW 单卷 m4b），自动导入链路进不去。这里把该任务真实落盘的音频
  /// 预填进 [BookImportDialog]，用户只需再给一个字幕就能成书。
  ///
  /// 取不到音频路径（文件被手动删掉/移走）时照常开框、只是不预填——把死路留成
  /// 用户仍可自选文件的活路，好过弹一句错误后什么也做不了。
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
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
      ),
    );
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

  Widget _buildResourceDomain(_DownloadsResourceDomain domain) =>
      switch (domain) {
        _DownloadsResourceDomain.books => const MediaDiscoveryPage(
            kinds: <DiscoveryMediaKind>[
              DiscoveryMediaKind.novel,
              DiscoveryMediaKind.audiobook,
            ],
          ),
        _DownloadsResourceDomain.manga => const MangaDiscoveryPage(
            embedded: true,
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
              for (final _DownloadsResourceDomain domain
                  in _DownloadsResourceDomain.values)
                ButtonSegment<_DownloadsResourceDomain>(
                  value: domain,
                  label: Text(_resourceDomainLabel(domain)),
                ),
            ],
            selected: _resourceDomain,
            onChanged: _selectResourceDomain,
            minSegmentWidth: 72,
            alignment: Alignment.centerLeft,
          ),
        ),
        Expanded(
          child: Stack(
            children: <Widget>[
              for (final _DownloadsResourceDomain domain
                  in _DownloadsResourceDomain.values)
                if (_visitedResourceDomains.contains(domain))
                  Positioned.fill(
                    child: Offstage(
                      offstage: domain != _resourceDomain,
                      child: TickerMode(
                        enabled: domain == _resourceDomain,
                        child: KeyedSubtree(
                          key: ValueKey<String>(
                            'downloads-resource-${domain.name}',
                          ),
                          child: _buildResourceDomain(domain),
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

  /// 统一门头：分区导航（资源 / 任务 / 订阅 / 设置）作页头主位 + 页头动作，与其余
  /// 顶层库页同构；独立 push 进来（无 home 壳）时在 leading 位保留返回按钮——旧
  /// AppBar 的自动返回键由这里承接。
  ///
  /// 走 [LibrarySectionTabs.controlled]：本页的 [TabController] 同时驱动 [TabBarView]，
  /// 交给导航组件共用那一个即可。此前这里是「分段条镜像 controller」——外面套
  /// [AnimatedBuilder] 读 index、点段回调 animateTo，两处都只是把 controller 的状态
  /// 抄一遍；抄出来的指示器在横滑 TabBarView 时只能在越过一半时跳一下，共用同一个
  /// controller 才跟手连续滑动。
  Widget _buildHeader(BuildContext tabContext) {
    // 下拉框会临时 push PopupRoute；只看本页自己的 PageRoute，避免展开菜单时
    // 左上角凭空出现返回键。
    final bool showBackButton = ModalRoute.of(context)?.isFirst == false;
    return FushiPageHeader.customTitle(
      leading: showBackButton
          ? FushiIconButton(
              icon: Icons.arrow_back,
              tooltip: t.back,
              onTap: () => Navigator.of(context).maybePop(),
            )
          : null,
      title: LibrarySectionTabs<int>.controlled(
        tabs: <LibrarySectionTab<int>>[
          LibrarySectionTab<int>(value: 0, label: t.download_resources_tab),
          LibrarySectionTab<int>(value: 1, label: t.download_tasks_tab),
          LibrarySectionTab<int>(value: 2, label: t.download_subscriptions_tab),
          LibrarySectionTab<int>(value: 3, label: t.settings),
        ],
        controller: DefaultTabController.of(tabContext),
        focusIdPrefix: 'downloads-tab',
      ),
      // 页头动作只留「添加任务」（2026-08-21 用户点名）：旧「放送日历」
      // 「在线目录」入口都不是下载动作，前者迁往发现页（独立改造），后者
      // 在漫画库页「浏览」视图仍然可达。
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.add,
          tooltip: t.download_task_add,
          label: t.download_task_add,
          onTap: _openManualTaskDialog,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
        initialIndex:
            widget.initialShowSettings ? 3 : widget.initialTabIndex.clamp(0, 2),
        length: 4,
        child: Builder(
          builder: (BuildContext tabContext) => Scaffold(
            // BUG-1003：内联下载流程把 apikey/搜番等输入框全放在页面上半部，下载任务折叠区
            // 贴底、中段结果列表是唯一的 Expanded。默认 resizeToAvoidBottomInset:true 时，
            // 手机软键盘弹出会压掉 body 高度、顶掉贴底任务区，使其爬到顶部输入框边上（看似
            // 「下载任务被输入框挤上去」）。关掉 inset 让键盘只覆盖下半部结果/任务区（打字时
            // 本就不看），顶部输入框保持可见、布局不反流。
            resizeToAvoidBottomInset: false,
            // 统一门头（2026-08-13）：与书 / 漫画 / 视频 / 游戏库页同一范式——
            // FushiPageHeader.customTitle（左对齐分段条）+ FushiIconButton 动作，
            // 替代旧 AppBar + 居中 TabBar 的独有形态（本页此前是全 app 唯一还在
            // 用 AppBar 门头的顶层 tab）。分段条与 TabBarView 由同一个
            // TabController 驱动，横滑切页不受影响；旧 TabBar 的「窄屏可滚不裁
            // 字」（BUG-1184）由 FushiSegmentedStrip 的同一契约承接。作为 home
            // tab 时外层已有 SafeArea，这里的 SafeArea 兜的是独立 push 进来
            // （设置/对话框入口）失去 AppBar 后的状态栏避让，双层无副作用。
            body: SafeArea(
              bottom: false,
              child: Column(
                children: <Widget>[
                  if (!isCupertinoPlatform(context)) _buildHeader(tabContext),
                  Expanded(
                    child: TabBarView(
                      children: <Widget>[
                        _buildResourceHub(),
                        // 任务 tab：漫画目录卷下载队列（有任务才占位）+ torrent 任务，
                        // 统一下载中心的同屏任务视图。
                        //
                        // 「同屏只留一份空态」由**旧计划列表**按需折叠实现（BUG-1512）：
                        // 新版任务面板常驻并自带空态与实时指标，旧 AnimeDownloadDialog
                        // 只在真有旧任务时按比例分高度，没有就整块收成 0 高。
                        LayoutBuilder(
                          builder: (BuildContext context,
                              BoxConstraints constraints) {
                            final double legacyHeight =
                                (constraints.maxHeight * 0.38).clamp(180, 360);
                            return Column(
                              children: <Widget>[
                                const MokuroMoeTasksSection(),
                                const DiscoveryDownloadTasksSection(),
                                Expanded(
                                  child: VideoDownloadJobsPanel.database(
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
                                    onPairAudiobook:
                                        (VideoDownloadJobRow job) async {
                                      await _pairDownloadedAudiobook(job);
                                    },
                                    onOpenDetails:
                                        (VideoDownloadJobRow job) async {
                                      final appModel = ref.read(appProvider);
                                      final pipeline =
                                          appModel.videoDownloadPipelineService;
                                      final details = pipeline != null
                                          ? await pipeline
                                              .loadJobDetails(job.jobId)
                                          : buildPersistedVideoDownloadJobDetails(
                                              job,
                                              await appModel.database
                                                  .getVideoDownloadJobFiles(
                                                      job.jobId),
                                            );
                                      if (!context.mounted) return;
                                      final String torrentId =
                                          (job.backendTaskId ??
                                                  job.torrentHash ??
                                                  '')
                                              .trim();
                                      await showAppDialog<void>(
                                        context: context,
                                        builder: (BuildContext dialogContext) =>
                                            TorrentTaskDetailDialog.task(
                                          torrentId: torrentId,
                                          title: job.title,
                                          torrentTitle: job.resourceTitle
                                                      ?.trim()
                                                      .isNotEmpty ==
                                                  true
                                              ? job.resourceTitle!.trim()
                                              : job.title,
                                          backendOverride: details.backend,
                                          liveDataAbsence:
                                              details.liveDataAbsence,
                                          initialSnapshot: details.snapshot,
                                          initialFiles: details.files,
                                        ),
                                      );
                                    },
                                    onSetPriority: (VideoDownloadJobRow job,
                                        int priority) async {
                                      final pipeline = ref
                                          .read(appProvider)
                                          .videoDownloadPipelineService;
                                      await pipeline?.setJobPriority(
                                        job.jobId,
                                        priority,
                                      );
                                    },
                                    locationLoader:
                                        (VideoDownloadJobRow job) async {
                                      final pipeline = ref
                                          .read(appProvider)
                                          .videoDownloadPipelineService;
                                      return pipeline == null
                                          ? null
                                          : await pipeline
                                              .resolveJobLocation(job.jobId);
                                    },
                                    onDelete: (job,
                                        {required bool deleteFiles}) async {
                                      final appModel = ref.read(appProvider);
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
                                  ),
                                ),
                                SizedBox(
                                  height:
                                      _hasLegacyAnimeTasks ? legacyHeight : 0,
                                  child: Offstage(
                                    offstage: !_hasLegacyAnimeTasks,
                                    child: AnimeDownloadDialog(
                                      embedded: true,
                                      tasksOnly: true,
                                      showTasks: false,
                                      onTaskPresenceChanged:
                                          _setLegacyAnimeTaskPresence,
                                      onOpenSettings: () =>
                                          DefaultTabController.of(
                                        tabContext,
                                      ).animateTo(3),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                        const VideoDownloadSubscriptionsPanel(),
                        ListView(
                          children: <Widget>[
                            const TorrentSettingsSection(),
                            // 索引器 / 字幕来源 / 发现来源已迁到设置 → 在线服务
                            // （第三方凭据一个家）；下载页设置 tab 留一条跳转，
                            // 番剧下载对话框「去设置」落到这里仍能一步到达。
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
                            const VideoExternalProviderSettingsSection(
                              scope: VideoExternalProviderScope.downloadRouting,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
  }
}

enum _DownloadsResourceDomain { books, manga, games, video }
