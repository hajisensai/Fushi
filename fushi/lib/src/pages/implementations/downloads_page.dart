import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';

import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_tasks_section.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/airing_calendar_page.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/downloads_resource_gap.dart';
import 'package:fushi/src/pages/implementations/media_sources_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_detail_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaSourceRow, VideoDownloadJobRow;

/// 独立「下载」页（顶层底栏 tab）＝统一下载中心：番剧下载流程 **直接内联**
/// 铺在页面上（搜番 → 选种 → 配字幕 → 推送 + 通用磁力 + 下载任务），任务 tab
/// 同时列出漫画「在线目录」（mokuro.moe）的卷下载队列；页头另有在线目录入口。
/// 右上角齿轮切到「下载设置」（后端/限速/上传/做种/内存）。完成后按内容类型
/// 自动入库（视频→视频库、epub→阅读库，见 AnimeDownloadService；漫画卷→
/// 书架，见 MokuroMoeDownloadQueue）。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({
    super.key,
    this.initialShowSettings = false,
    this.initialTabIndex = 0,
  });

  /// 初始即显示设置面板（「后端未配置」横幅的「去设置」从对话框入口 push
  /// 本页直落配置用）。默认 false = 正常下载流程。
  final bool initialShowSettings;

  /// 发现详情“管理订阅”等入口可直接落到对应子页。
  final int initialTabIndex;

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  late Future<_DownloadsResourceState> _resourceDependencies;
  VideoDownloadPipelineService? _resourcePipelineSnapshot;
  bool _hasLegacyAnimeTasks = false;

  void _setLegacyAnimeTaskPresence(bool present) {
    if (!mounted || _hasLegacyAnimeTasks == present) return;
    setState(() => _hasLegacyAnimeTasks = present);
  }

  @override
  void initState() {
    super.initState();
    final AppModel appModel = ref.read(appProvider);
    _resourcePipelineSnapshot = appModel.videoDownloadPipelineService;
    _resourceDependencies = _loadResourceDependencies(appModel);
  }

  Future<_DownloadsResourceState> _loadResourceDependencies([
    AppModel? current,
  ]) async {
    final AppModel appModel = current ?? ref.read(appProvider);
    final VideoResourceRegistry? registry = appModel.videoResourceRegistry;
    final VideoDownloadPipelineService? pipeline =
        appModel.videoDownloadPipelineService;
    final bool backendReady = registry != null && pipeline != null;
    final List<MediaSourceRow> sources = backendReady
        ? await appModel.getManagedVideoDownloadSources()
        : const <MediaSourceRow>[];
    VideoDownloadBackendIdentity? identity;
    Object? identityError;
    // 没来源就别去连后端了：身份解析要打真后端，白连一趟还会把「缺来源」
    // 盖成一条连接错误。
    if (backendReady && sources.isNotEmpty) {
      try {
        identity = await appModel.currentVideoDownloadBackendIdentity();
      } on Object catch (error) {
        identityError = error;
      }
    }
    final DownloadsResourceGap? gap = findDownloadsResourceGap(
      backendReady: backendReady,
      managedSourceCount: sources.length,
      identityError: identityError,
    );
    if (gap == null &&
        registry != null &&
        pipeline != null &&
        identity != null) {
      return _DownloadsResourceReady(
        registry: registry,
        pipeline: pipeline,
        identity: identity,
        sources: sources,
        defaultSourceId: appModel.prefsRepo.videoDownloadTargetSourceId,
      );
    }
    // gap == null 时上面三个必然非空，这条只是让类型收敛。
    return _DownloadsResourceBlocked(
      gap ?? const DownloadsResourceNoBackend(),
    );
  }

  /// 「缺受管视频来源」空态的动作：就地开来源管理对话框加一个本地视频文件夹，
  /// 关掉后重算前置条件——不用把用户支去别的页面再走回来。
  Future<void> _addVideoSource() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext _) => const MediaSourcesDialog(mediaKind: 'video'),
    );
    if (!mounted) return;
    setState(() {
      _resourceDependencies = _loadResourceDependencies();
    });
  }

  Widget _buildResourceTab(BuildContext tabContext) {
    return FutureBuilder<_DownloadsResourceState>(
      future: _resourceDependencies,
      builder: (
        BuildContext context,
        AsyncSnapshot<_DownloadsResourceState> snapshot,
      ) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final _DownloadsResourceState? state = snapshot.data;
        if (state is! _DownloadsResourceReady) {
          final DownloadsResourceGap gap = state is _DownloadsResourceBlocked
              ? state.gap
              : const DownloadsResourceNoBackend();
          return switch (gap) {
            DownloadsResourceNoManagedSource() => _buildResourceGate(
                message: t.download_no_managed_video_source,
                icon: Icons.create_new_folder_outlined,
                label: t.download_add_video_source,
                onPressed: _addVideoSource,
              ),
            DownloadsResourceNoBackend(detail: final String? detail) =>
              _buildResourceGate(
                message: detail ?? t.download_backend_not_configured,
                icon: Icons.settings_outlined,
                label: t.download_open_settings,
                onPressed: () =>
                    DefaultTabController.of(tabContext).animateTo(3),
              ),
          };
        }
        final _DownloadsResourceReady dependencies = state;
        return VideoResourceSearchSurface(
          key: const ValueKey<String>('downloads-resource-search'),
          registry: dependencies.registry,
          sources: dependencies.sources,
          defaultSourceId: dependencies.defaultSourceId,
          onSubmit: (VideoDiscoveryDownloadSelection selection) =>
              dependencies.pipeline.enqueue(
            VideoDownloadEnqueueRequest(
              media: selection.media,
              resource: selection.resource,
              backendIdentity: dependencies.identity,
              targetSourceId: selection.source.id,
              subtitlePolicy: selection.subtitlePolicy,
            ),
          ),
        );
      },
    );
  }

  /// 「资源」标签的空态：一句说清缺什么 + 一个直接补上它的按钮。
  Widget _buildResourceGate({
    required String message,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            ),
          ],
        ),
      ),
    );
  }

  /// 漫画「在线目录」入口（统一下载中心：书/漫画获取入口与 torrent 并列）。
  ///
  /// 书架页与书籍导入框的旧入口已收敛到这里，故本页是
  /// [MangaModule.openOnlineCatalog] 的唯一消费方——目录弹窗的构造统一收在
  /// 漫画模块里，不在页面层直接 new 它。
  Future<void> _openMangaCatalog() async {
    await MangaModule.openOnlineCatalog(
      context: context,
      db: ref.read(appProvider).database,
    );
  }

  /// 放送日历整页入口（TODO-2487）。[tabContext] 必须来自 DefaultTabController
  /// 之下（AppBar actions 里的 Builder），日历页点「订阅中」条目 pop 回来后
  /// 用它把本页 tab 切到订阅。
  void _openAiringCalendar(BuildContext tabContext) {
    final TabController tabController = DefaultTabController.of(tabContext);
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => AiringCalendarPage(
          onOpenSubscriptions: () {
            if (!mounted) return;
            tabController.animateTo(2);
          },
        ),
      ),
    );
  }

  /// 统一门头：分段条（资源 / 任务 / 订阅 / 设置）作页头主位 + 页头动作，与其余
  /// 顶层库页同构。分段条选中态跟随 [TabController]（横滑切页后高亮同步），点段
  /// 走 animateTo；独立 push 进来（无 home 壳）时在 leading 位保留返回按钮——
  /// 旧 AppBar 的自动返回键由这里承接。
  Widget _buildHeader(BuildContext tabContext) {
    final TabController tabController = DefaultTabController.of(tabContext);
    final bool canPop = Navigator.of(context).canPop();
    return AnimatedBuilder(
      animation: tabController,
      builder: (BuildContext context, _) {
        final int index = tabController.index;
        void select(int value) {
          if (value != tabController.index) tabController.animateTo(value);
        }

        return FushiPageHeader.customTitle(
          leading: canPop
              ? FushiIconButton(
                  icon: Icons.arrow_back,
                  tooltip: t.back,
                  onTap: () => Navigator.of(context).maybePop(),
                )
              : null,
          title: FushiAdjustableSegmented<int>(
            values: const <int>[0, 1, 2, 3],
            selected: index,
            onChanged: select,
            focusIdPrefix: 'downloads-tab',
            focusId: const FushiFocusId('downloads-tab-sections'),
            child: FushiSegmentedStrip<int>(
              segments: <ButtonSegment<int>>[
                ButtonSegment<int>(
                  value: 0,
                  label: Text(t.download_resources_tab),
                ),
                ButtonSegment<int>(value: 1, label: Text(t.download_tasks_tab)),
                ButtonSegment<int>(
                  value: 2,
                  label: Text(t.download_subscriptions_tab),
                ),
                ButtonSegment<int>(value: 3, label: Text(t.settings)),
              ],
              selected: index,
              onChanged: select,
            ),
          ),
          actions: <Widget>[
            FushiIconButton(
              icon: Icons.calendar_month_outlined,
              tooltip: t.download_airing_calendar_title,
              label: t.download_airing_calendar_title,
              onTap: () => _openAiringCalendar(tabContext),
            ),
            FushiIconButton(
              icon: Icons.menu_book_outlined,
              tooltip: t.manga_online_catalog_title,
              label: t.manga_online_catalog_title,
              onTap: _openMangaCatalog,
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    if (!identical(
      _resourcePipelineSnapshot,
      appModel.videoDownloadPipelineService,
    )) {
      _resourcePipelineSnapshot = appModel.videoDownloadPipelineService;
      _resourceDependencies = _loadResourceDependencies(appModel);
    }
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
                        _buildResourceTab(tabContext),
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
                          children: const <Widget>[
                            TorrentSettingsSection(constrainWidth: false),
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

/// 「资源」标签的前置条件解析结果：要么齐备可用，要么缺了具体某一环。
/// 缺什么由 [findDownloadsResourceGap] 判定（BUG-1706）。
sealed class _DownloadsResourceState {
  const _DownloadsResourceState();
}

/// 前置条件没齐；[gap] 说清缺的是后端还是受管视频来源。
class _DownloadsResourceBlocked extends _DownloadsResourceState {
  const _DownloadsResourceBlocked(this.gap);

  final DownloadsResourceGap gap;
}

/// 前置条件齐备，可以搜资源并推送下载。
class _DownloadsResourceReady extends _DownloadsResourceState {
  const _DownloadsResourceReady({
    required this.registry,
    required this.pipeline,
    required this.identity,
    required this.sources,
    required this.defaultSourceId,
  });

  final VideoResourceRegistry registry;
  final VideoDownloadPipelineService pipeline;
  final VideoDownloadBackendIdentity identity;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
}
