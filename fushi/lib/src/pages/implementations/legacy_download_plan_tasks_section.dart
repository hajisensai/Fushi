import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/torrent/anime_download_fail_reason.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/src/pages/implementations/download_backend_setup_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_detail_dialog.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart'
    show showDownloadTaskDeleteConfirm;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_task_display.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// Preserve legacy ownership while supplying comparable task metadata.
DownloadTaskEntry animeDownloadTaskEntry({
  required AnimeDownloadPlan plan,
  required WidgetBuilder builder,
  double? progress,
  DownloadTaskStats? stats,
  DownloadTaskActions actions = DownloadTaskActions.none,
}) {
  final DownloadTaskKind kind = switch (plan.contentKind) {
    AnimeDownloadPlan.kindGame => DownloadTaskKind.game,
    AnimeDownloadPlan.kindBook => DownloadTaskKind.novel,
    AnimeDownloadPlan.kindAudiobook => DownloadTaskKind.audiobook,
    _ => DownloadTaskKind.video,
  };
  final TorrentDisplayStatus? observed = stats == null
      ? null
      : torrentDisplayStatusFor(stats.state);
  final DownloadTaskStatus status = switch (plan.status) {
    AnimeDownloadPlan.statusImported => DownloadTaskStatus.completed,
    AnimeDownloadPlan.statusFailed => DownloadTaskStatus.attention,
    _ => switch (observed) {
      TorrentDisplayStatus.paused => DownloadTaskStatus.paused,
      TorrentDisplayStatus.queued => DownloadTaskStatus.queued,
      TorrentDisplayStatus.error => DownloadTaskStatus.attention,
      _ => DownloadTaskStatus.active,
    },
  };
  final String? collectionKey = plan.collectionId != null
      ? 'collection:${plan.collectionId}'
      : plan.anilistId != null
      ? 'series:anilist:${plan.anilistId}'
      : null;
  return DownloadTaskEntry(
    id: 'legacy-plan:${plan.id.trim().toLowerCase()}',
    title: plan.seriesTitle.isEmpty ? plan.torrentTitle : plan.seriesTitle,
    kind: kind,
    status: status,
    createdAt: plan.createdAtMs,
    progress: plan.status == AnimeDownloadPlan.statusImported ? 1 : progress,
    collectionKey: collectionKey,
    collectionTitle: collectionKey == null ? null : plan.seriesTitle,
    searchTerms: <String>[plan.torrentTitle, plan.qbCategory],
    // 旧番剧计划唯一记着的作品身份是 AniList id：有它就能被「定位到这部番」精确
    // 命中，不必退回标题兜底。
    workIdentity: DownloadTaskWorkIdentity.maybe(
      'anilist',
      plan.anilistId?.toString(),
    ),
    actions: actions,
    builder: builder,
  );
}

/// 下载中心里的旧版番剧下载计划（[AnimeDownloadPlan]，JSON 计划仓库）任务来源。
///
/// 旧「番剧下载」对话框的搜番 / 选种 / 确认推送已由视频资源搜索
/// （`VideoResourceSearchSurface`，经 `VideoResourceRegistry` 走用户添加的 RSS
/// 搜索站与 Torznab）取代并删除；这里只留下仍在用的那一半：列出计划仓库里的任务
/// （通用磁链推送 [pushGenericMagnet] 在本次会话里写入的计划，下次启动由
/// `VideoDownloadLegacyImporter` 迁进 v78 管线），并提供暂停 / 恢复 / 重试 /
/// 边下边播 / 改名移动 / 删除与任务详情。
///
/// 有 [tasksBuilder] 时把条目交给下载中心统一排序 / 分组；没有时自己渲染整页列表。
class LegacyDownloadPlanTasksSection extends ConsumerStatefulWidget {
  const LegacyDownloadPlanTasksSection({super.key, this.tasksBuilder});

  /// Lets the Downloads page combine all sources before sorting/grouping.
  final DownloadTasksBuilder? tasksBuilder;

  @override
  ConsumerState<LegacyDownloadPlanTasksSection> createState() =>
      _LegacyDownloadPlanTasksSectionState();
}

class _LegacyDownloadPlanTasksSectionState
    extends ConsumerState<LegacyDownloadPlanTasksSection>
    with FushiPagePlaceholders<LegacyDownloadPlanTasksSection> {
  List<AnimeDownloadPlan> _plans = const <AnimeDownloadPlan>[];
  AnimeDownloadPlanStore? _observedPlanStore;
  int _planLoadGeneration = 0;

  void _onPlanStoreChanged() => unawaited(_reloadPlans());

  @override
  void initState() {
    super.initState();
    _observedPlanStore = ref.read(appProvider).animeDownloadPlanStore;
    _observedPlanStore?.revision.addListener(_onPlanStoreChanged);
    unawaited(_reloadPlans());
  }

  @override
  void dispose() {
    _planLoadGeneration++;
    _observedPlanStore?.revision.removeListener(_onPlanStoreChanged);
    super.dispose();
  }

  /// 下载后端是否就绪。默认（auto）在桌面走内置引擎、开箱即用；只有显式外接
  /// qb 且没填地址才算未就绪。
  bool get _backendReady => torrentBackendReady(ref.read(appProvider));

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------ 下载任务区

  Future<void> _reloadPlans() async {
    final int generation = ++_planLoadGeneration;
    final AnimeDownloadPlanStore? store = ref
        .read(appProvider)
        .animeDownloadPlanStore;
    if (store == null) return;
    final List<AnimeDownloadPlan> plans = await store.loadAll();
    if (!mounted || generation != _planLoadGeneration) return;
    // loadAll 按创建时间升序；展示新的在上。
    setState(() => _plans = plans.reversed.toList(growable: false));
  }

  Future<void> _refreshPlans() async {
    await _reloadPlans();
    unawaited(ref.read(appProvider).animeDownloadService?.tick());
  }

  /// 删除旧番剧计划：与 v78 任务面板同一确认框（正文 + 「同时删除已下载文件」）。
  /// 以前这里没有确认框、也从不删文件；勾选后经后端 `removeTorrent(deleteFiles)` 删
  /// 数据，并把已入库、指向这些文件的视频行一并清掉（否则库里留下一排打不开的壳）。
  /// 单条删除：弹确认框问「要不要连文件一起删」，再走 [_deletePlanResolved]。
  Future<void> _deletePlan(AnimeDownloadPlan plan) async {
    final AppModel appModel = ref.read(appProvider);
    if (appModel.animeDownloadPlanStore == null) return;
    final AnimeDownloadService? service = appModel.animeDownloadService;
    // 「同时删除已下载文件」只在真兑现得了时才摆出来：删数据只能由下载后端执行，
    // 没有 service 或后端没配好时勾了也只会静默丢弃（与两个删除确认框里
    // 「兑现不了就不显示」同一纪律）。
    final bool canDeleteFiles =
        service != null &&
        effectiveTorrentConfig(appModel.qbConnectionConfig).isConfigured;
    final bool? deleteFiles = await showDownloadTaskDeleteConfirm(
      context,
      title: plan.seriesTitle.isNotEmpty ? plan.seriesTitle : plan.torrentTitle,
      keySuffix: plan.id,
      offerDeleteFiles: canDeleteFiles,
    );
    if (deleteFiles == null || !mounted) return;
    await _deletePlanResolved(plan, deleteFiles: deleteFiles);
  }

  /// 删除的执行体：**不弹任何确认框**，[deleteFiles] 由调用方定好。
  /// 批量删除对一整批只问一次，之后逐条走这里。
  Future<void> _deletePlanResolved(
    AnimeDownloadPlan plan, {
    required bool deleteFiles,
  }) async {
    final AppModel appModel = ref.read(appProvider);
    final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
    if (store == null) return;
    final AnimeDownloadService? service = appModel.animeDownloadService;
    if (service == null) {
      await store.delete(plan.id);
    } else {
      final AnimeDownloadPlanDeleteResult result = await service.deletePlan(
        plan.id,
        deleteFiles: deleteFiles,
        onFilesDeleted: (List<String> videoAbsolutePaths) async {
          final VideoBookRepository repo = VideoBookRepository(
            appModel.database,
          );
          bool any = false;
          for (final String path in videoAbsolutePaths) {
            final VideoBookRow? row = await repo.findByVideoPath(path);
            if (row == null) continue;
            await repo.deleteVideoBookAndReclaimAssets(
              row.bookUid,
              compactDatabase: false,
            );
            any = true;
          }
          if (any) {
            await repo.compactAfterVideoDeleteBestEffort();
            appModel.database.notifyVideoLibraryChanged();
          }
        },
      );
      // 勾了删文件却没删成（后端离线 / 摘种子失败）必须说出来：计划行已经消失，
      // 用户不会再有第二次机会发现盘上的数据还在。
      if (deleteFiles && !result.filesDeleted && mounted) {
        FushiToast.show(
          msg: t.download_task_delete_files_failed,
          severity: ToastSeverity.warning,
        );
      }
    }
    await _reloadPlans();
  }

  /// TODO-1961-e：改名 / 移动入口。
  ///
  /// 为什么必须在 app 里做：引擎按自己记的路径读盘上传，用户在资源管理器里改名
  /// 之后 app 收不到任何通知，等下一轮轮询时文件已经不见了 —— 那种情况**永远**
  /// 救不回来。走这里则由引擎自己改（做种不断），库路径同步迁移。
  Future<void> _relocatePlan(AnimeDownloadPlan plan) async {
    final AppModel appModel = ref.read(appProvider);
    final QbConnectionConfig config = effectiveTorrentConfig(
      appModel.qbConnectionConfig,
    );
    // 先拿这个种子的当前快照（save_path + 文件列表）：改名要文件下标与旧相对
    // 路径，移动要旧 save_path，都得从后端现问，不能猜。
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    TorrentSnapshot? snapshot;
    List<TorrentFileEntry> files = const <TorrentFileEntry>[];
    try {
      for (final TorrentSnapshot t in await backend.listTorrents(
        category: config.category.isEmpty ? null : config.category,
      )) {
        if (t.hash.toLowerCase() == plan.id.toLowerCase()) {
          snapshot = t;
          break;
        }
      }
      if (snapshot != null) files = await backend.listFiles(snapshot.hash);
    } catch (_) {
      snapshot = null;
    } finally {
      backend.close();
    }
    if (!mounted) return;
    if (snapshot == null || snapshot.savePath.isEmpty) {
      _snack(t.anime_download_relocate_no_files);
      return;
    }

    final _RelocateChoice? choice = await showAppDialog<_RelocateChoice>(
      context: context,
      builder: (BuildContext context) =>
          _RelocateDialog(snapshot: snapshot!, files: files),
    );
    if (choice == null || !mounted) return;

    final DownloadRelocateService service = appModel.downloadRelocateService;
    final RelocateOutcome outcome = choice.isMove
        ? await service.moveTorrent(
            infoHash: plan.id,
            backendSaveRoot: snapshot.savePath,
            newLocalSaveRoot: choice.value,
          )
        : await service.renameFile(
            infoHash: plan.id,
            fileIndex: choice.fileIndex!,
            currentRelativePath: choice.currentRelativePath!,
            newRelativePath: choice.value,
            backendSaveRoot: snapshot.savePath,
          );
    if (!mounted) return;
    switch (outcome.status) {
      case RelocateStatus.success:
        _snack(t.anime_download_relocate_ok(rows: '${outcome.rowsMigrated}'));
      case RelocateStatus.unchanged:
        break;
      case RelocateStatus.engineFailed:
        _snack(
          t.anime_download_relocate_engine_failed(reason: outcome.error ?? ''),
        );
      case RelocateStatus.libraryFailed:
        _snack(
          t.anime_download_relocate_library_failed(reason: outcome.error ?? ''),
        );
    }
    await _reloadPlans();
  }

  /// 「边下边播」：不等下载完成，立即按计划入库（qb 元数据就绪即可流式播放）。
  Future<void> _playNow(AnimeDownloadPlan plan) async {
    final bool ok =
        await ref.read(appProvider).animeDownloadService?.importNow(plan.id) ??
        false;
    if (!mounted) return;
    _snack(ok ? t.anime_download_play_now_ok : t.anime_download_play_now_fail);
    if (ok) await _reloadPlans();
  }

  /// 「开始配置」：直接弹后端配置引导（只问「谁来下载」+ 所选后端的必填项），
  /// 配完当场重算就绪状态。用户不再被丢进整页下载设置自己找字段。
  Future<void> _openBackendSetup() async {
    final bool done = await promptDownloadBackendSetup(
      context: context,
      appModel: ref.read(appProvider),
    );
    if (done && mounted) setState(() {});
  }

  /// 后端没就绪时的统一出口：**先弹引导**再决定要不要继续，而不是甩一句
  /// 「请先配置下载后端」把动作丢掉。返回 true = 现在可以继续原动作。
  Future<bool> _ensureBackendReady() async {
    if (torrentBackendReady(ref.read(appProvider))) return true;
    await _openBackendSetup();
    if (!mounted) return false;
    return torrentBackendReady(ref.read(appProvider));
  }

  /// 重试失败的计划：重推同一 magnet 走现有推送路径（prepareCategory +
  /// addTorrent 顺序/首尾块优先），成功后计划复位 downloading（重置计时，
  /// torrent-missing 超时从头算）。addTorrent 报失败但种子已在后端列表
  /// （入库失败类重试的常态——重复添加被后端拒绝）也算在下，交回轮询重走完成流程。
  /// 批量路径专用的暂停/恢复：失败**抛错**而不是弹 SnackBar。
  ///
  /// _togglePausePlan 在后端拒绝时只 _snack 一句就 return，对单条是合适的，但批量
  /// 走它会变成「先排队弹 10 条『操作失败』，最后再弹一条『已处理 10 项』」——
  /// 既刷屏又把失败计数骗成 0。抛出来交给 runDownloadTaskBatch 聚合。
  Future<void> _batchPausePlan(
    AnimeDownloadPlan plan, {
    required bool pause,
  }) async {
    if (!await _ensureBackendReady()) {
      throw StateError('torrent backend unavailable');
    }
    final AppModel appModel = ref.read(appProvider);
    final TorrentBackend backend = appModel.createTorrentBackend(
      effectiveTorrentConfig(appModel.qbConnectionConfig),
    );
    try {
      if (backend is! TorrentPauseBackend) {
        throw StateError('backend does not support pause control');
      }
      final bool ok = pause
          ? await backend.pauseTorrent(plan.id)
          : await backend.resumeTorrent(plan.id);
      if (!ok) throw StateError('backend rejected pause/resume');
    } finally {
      backend.close();
    }
    await _reloadPlans();
  }

  /// 批量路径专用的重试：后端没准备好时抛错而不是静默 return。
  Future<void> _batchRetryPlan(AnimeDownloadPlan plan) async {
    if (!await _ensureBackendReady()) {
      throw StateError('torrent backend unavailable');
    }
    await _retryPlan(plan);
  }

  /// 统一下载列表里一条 legacy 计划支持的批量动作。
  ///
  /// 四项在服务层本来就齐（pauseTorrent/resumeTorrent、_retryPlan 重新 addTorrent、
  /// deletePlan 含 deleteFiles），此前只是 [DownloadTaskEntry] 上没有槽位可填。
  /// 不填 setPriority：torrent 后端只有**文件级** priority，没有任务级调度优先级，
  /// 硬凑一个只会让批量「设为高优先级」对 legacy 行静默无效。
  DownloadTaskActions _planActions(
    AnimeDownloadPlan plan,
    DownloadTaskStats? stats,
  ) {
    final AppModel appModel = ref.read(appProvider);
    final bool imported = plan.status == AnimeDownloadPlan.statusImported;
    final bool failed = plan.status == AnimeDownloadPlan.statusFailed;
    final TorrentDisplayStatus? observed = stats == null
        ? null
        : torrentDisplayStatusFor(stats.state);
    final bool paused = observed == TorrentDisplayStatus.paused;
    // 后端不支持暂停控制时两个槽位都留 null——摆出来点了没反应比没有更糟。
    final bool pauseCapable = _pauseCapable;
    // 计划仓库没装配（Profile 切换中 / 初始化未完成）时 _deletePlanResolved 会
    // 静默 return，批量却会把它记成「已处理」。删不了就别填槽位。
    final bool canDelete = appModel.animeDownloadPlanStore != null;
    // 删磁盘数据只能由下载后端执行，判据与单条删除确认框逐字一致。
    final bool canDeleteFiles =
        canDelete &&
        appModel.animeDownloadService != null &&
        effectiveTorrentConfig(appModel.qbConnectionConfig).isConfigured;
    return DownloadTaskActions(
      // pause / resume 都排除 failed：卡片上的暂停/恢复只在 downloading 时渲染
      // （见 _buildPlanRowInner），批量比卡片宽会变成「卡片上没有、批量却能做」。
      pause: pauseCapable && !imported && !failed && !paused
          ? () => _batchPausePlan(plan, pause: true)
          : null,
      resume: pauseCapable && !imported && !failed && paused
          ? () => _batchPausePlan(plan, pause: false)
          : null,
      retry: failed ? () => _batchRetryPlan(plan) : null,
      delete: canDelete
          ? ({required bool deleteFiles}) =>
                _deletePlanResolved(plan, deleteFiles: deleteFiles)
          : null,
      deletesFiles: canDeleteFiles,
    );
  }

  Future<void> _retryPlan(AnimeDownloadPlan plan) async {
    if (!await _ensureBackendReady()) return;
    final AppModel appModel = ref.read(appProvider);
    final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
    if (store == null) {
      _snack(t.anime_download_store_unavailable);
      return;
    }
    final QbConnectionConfig config = effectiveTorrentConfig(
      appModel.qbConnectionConfig,
    );
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    bool pushed = false;
    try {
      await backend.prepareCategory(config.category);
      pushed = await backend.addTorrent(
        plan.magnet,
        category: config.category,
        sequential: true,
        firstLastPiecePrio: true,
      );
      if (!pushed) {
        final List<TorrentSnapshot> torrents = await backend.listTorrents(
          category: config.category.isEmpty ? null : config.category,
        );
        pushed = torrents.any(
          (TorrentSnapshot t) => t.hash.toLowerCase() == plan.id.toLowerCase(),
        );
      }
    } finally {
      backend.close();
    }
    if (!pushed) {
      _snack(t.anime_download_push_failed);
      return;
    }
    await store.save(
      plan.copyWith(
        status: AnimeDownloadPlan.statusDownloading,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    unawaited(appModel.animeDownloadService?.tick());
    _snack(t.anime_download_pushed);
    await _reloadPlans();
  }

  /// TODO-2481：当前后端是否支持暂停/恢复。探测 = `is TorrentPauseBackend`
  /// + 运行时能力位（内置引擎老 DLL 缺原语时类型过了也点不动）。对话框
  /// 生命周期内缓存一次 —— 只在任务行确实处于下载中时才会走到这里，此时
  /// 轮询服务本就每 tick 建同款后端，探测不会额外拉起会话。
  bool? _pauseCapableCache;

  bool get _pauseCapable {
    final bool? cached = _pauseCapableCache;
    if (cached != null) return cached;
    if (!_backendReady) return false;
    final AppModel appModel = ref.read(appProvider);
    final TorrentBackend backend = appModel.createTorrentBackend(
      effectiveTorrentConfig(appModel.qbConnectionConfig),
    );
    bool capable = false;
    try {
      capable = backend is TorrentPauseBackend && backend.pauseControlAvailable;
    } finally {
      backend.close();
    }
    _pauseCapableCache = capable;
    return capable;
  }

  /// TODO-2481：暂停/恢复单个任务；成功即踢一轮 tick 刷新快照与状态文本。
  Future<void> _togglePausePlan(
    AnimeDownloadPlan plan, {
    required bool pause,
  }) async {
    if (!await _ensureBackendReady()) return;
    final AppModel appModel = ref.read(appProvider);
    final TorrentBackend backend = appModel.createTorrentBackend(
      effectiveTorrentConfig(appModel.qbConnectionConfig),
    );
    bool ok = false;
    try {
      if (backend is TorrentPauseBackend) {
        ok = pause
            ? await backend.pauseTorrent(plan.id)
            : await backend.resumeTorrent(plan.id);
      }
    } finally {
      backend.close();
    }
    if (!ok) {
      _snack(t.download_task_toggle_failed);
      return;
    }
    unawaited(appModel.animeDownloadService?.tick());
  }

  /// TODO-2481：显示状态 → i18n 文案；unknown 返回 null（该段不渲染）。
  String? _torrentStatusLabel(TorrentDisplayStatus status) {
    return switch (status) {
      TorrentDisplayStatus.downloading => t.download_task_status_downloading,
      TorrentDisplayStatus.seeding => t.download_task_status_seeding,
      TorrentDisplayStatus.completed => t.download_task_status_completed,
      TorrentDisplayStatus.paused => t.download_task_status_paused,
      TorrentDisplayStatus.queued => t.download_task_status_queued,
      TorrentDisplayStatus.stalled => t.download_task_status_stalled,
      TorrentDisplayStatus.checking => t.download_task_status_checking,
      TorrentDisplayStatus.fetchingMetadata => t.download_task_status_metadata,
      TorrentDisplayStatus.moving => t.download_task_status_moving,
      TorrentDisplayStatus.error => t.download_task_status_error,
      TorrentDisplayStatus.unknown => null,
    };
  }

  /// 单条任务行（[FushiListItem] compact，自动接焦点系统）。
  ///
  /// - 下载中：轮询服务透传的真实进度（[AnimeDownloadService.downloadProgress]）
  ///   渲染确定进度环 + 行内百分比；进度未知（服务未接/后端未上列表）回退
  ///   不定进度环。eink 一律静态图标（转圈=墨水屏残影）。
  /// - 失败：failReason 直接显示为 subtitle 第二行（error 色，触屏/键盘/手柄
  ///   可读，不再只藏 hover Tooltip）+ trailing 重试按钮。
  Widget _buildPlanRow(ThemeData theme, AnimeDownloadPlan plan) {
    if (plan.status == AnimeDownloadPlan.statusDownloading) {
      final AnimeDownloadService? service = ref
          .read(appProvider)
          .animeDownloadService;
      if (service != null) {
        // BUG-1296：百分比与确定进度环只认 [AnimeDownloadService.downloadProgress]
        // ——它是恒发布的规范通道。BUG-1294 的速度/流量走 downloadStats，只是**增强
        // 位**：拿不到观测值时少一截后缀即可，不能把百分比一起吞掉（`_importNowUnlocked`
        // 那条路径就会短暂只发进度不发观测值）。
        return ValueListenableBuilder<Map<String, double>>(
          valueListenable: service.downloadProgress,
          builder: (BuildContext context, Map<String, double> progress, _) =>
              ValueListenableBuilder<Map<String, DownloadTaskStats>>(
                valueListenable: service.downloadStats,
                builder:
                    (
                      BuildContext context,
                      Map<String, DownloadTaskStats> stats,
                      _,
                    ) => _buildPlanRowInner(
                      theme,
                      plan,
                      progress[plan.id],
                      stats[plan.id],
                    ),
              ),
        );
      }
    }
    return _buildPlanRowInner(theme, plan, null, null);
  }

  Widget _buildPlanRowInner(
    ThemeData theme,
    AnimeDownloadPlan plan,
    double? progress,
    DownloadTaskStats? stats,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final bool downloading = plan.status == AnimeDownloadPlan.statusDownloading;
    final bool failed = plan.status == AnimeDownloadPlan.statusFailed;
    // M3E 行首：状态落在形状底色块里——完成 = primary 圆、失败 = error 色块
    // （Apple 落系统绿 / 系统红方块）；下载中是同尺寸的进度环（确定 / 不定），
    // 墨水屏一律静态图标（转圈 = 墨水屏残影）。
    final Widget statusIcon = switch (plan.status) {
      AnimeDownloadPlan.statusImported => FushiListLeadingIcon(
        FushiIcons.success,
        size: 36,
        iconSize: 20,
        tone: isGlassDesign(context)
            ? FushiCardTone.tertiary
            : FushiCardTone.primary,
      ),
      AnimeDownloadPlan.statusFailed => const FushiListLeadingIcon(
        FushiIcons.error,
        size: 36,
        iconSize: 20,
        tone: FushiCardTone.error,
        shape: FushiLeadingShape.square,
      ),
      _ =>
        eink
            ? const FushiListLeadingIcon(
                FushiIcons.downloading,
                size: 36,
                iconSize: 20,
              )
            : SizedBox(
                width: 36,
                height: 36,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: FushiCircularProgressIndicator(
                    strokeWidth: 3,
                    value: progress,
                  ),
                ),
              ),
    };
    // BUG-1294：进度百分比之外补速度与累计流量（单位串是纯数字/符号，无需
    // i18n key）。速率为 0 时仍显示（「0 B/s 卡住了」本身就是有效信息）。
    // BUG-1296：百分比只依赖 progress；观测值缺席就只渲染百分比，不整条消失。
    // TODO-2481：再补状态文本 / ETA / 分享率 —— 三者都是增强位，算不出
    // （未知词 / 零速度 / 零分母）就整段不渲染，绝不把百分比一起吞掉。
    final TorrentDisplayStatus? displayStatus = stats == null
        ? null
        : torrentDisplayStatusFor(stats.state);
    final String? statusLabel = displayStatus == null
        ? null
        : _torrentStatusLabel(displayStatus);
    final String? etaText = stats == null
        ? null
        : formatTorrentEta(
            amountLeft: stats.amountLeft,
            downRateBps: stats.downRateBps,
          );
    final String? ratioText = stats == null
        ? null
        : formatShareRatio(
            uploadedBytes: stats.uploadedBytes,
            downloadedBytes: stats.downloadedBytes,
          );
    final String? progressText = (downloading && progress != null)
        ? <String>[
            '${(progress * 100).toStringAsFixed(0)}%',
            if (statusLabel != null) statusLabel,
            if (stats != null) ...<String>[
              '↓ ${FushiByteFormat.speed(stats.downRateBps.toDouble())}',
              '↑ ${FushiByteFormat.speed(stats.upRateBps.toDouble())}',
              FushiByteFormat.bytes(stats.downloadedBytes),
            ],
            if (etaText != null) '${t.download_task_eta} $etaText',
            if (ratioText != null) '${t.download_task_ratio} $ratioText',
          ].join(' · ')
        : null;
    final String? failReason =
        (failed && (plan.failReason?.isNotEmpty ?? false))
        ? describeAnimeDownloadFailReason(plan.failReason!)
        : null;
    // 字幕的时序对用户是可见的（BUG-1206）：推送时不再预下字幕，所以必须在这里
    // 说清「还没配」「没配上」，否则用户会以为字幕功能没了。
    // resolved / none 不占行——前者字幕已经贴成 sidecar，后者用户压根没要字幕。
    final (String, Color)? subtitleNote = switch (plan.subtitleStatus) {
      AnimeDownloadPlan.subtitlePending => (
        t.anime_download_subs_pending,
        scheme.onSurfaceVariant,
      ),
      // BUG-1696 起 unavailable 不再是终态：还排得上 backoff 重试的说「稍后自动
      // 重试」，重试次数用完了才说「未匹配到（可手动补）」。两种对用户是完全不同
      // 的处境——前者什么都不用做，后者要么手动补要么改条目。
      AnimeDownloadPlan.subtitleUnavailable => (
        plan.subtitleRetryPossible
            ? t.anime_download_subs_retrying
            : t.anime_download_subs_unmatched,
        scheme.tertiary,
      ),
      _ => null,
    };
    return FushiListItem(
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      // TODO-2482：行点击 = 打开任务详情（四 tab）。详情对话框自己探测
      // 后端能力并降级，这里不做前置门槛。
      onTap: () => _openTaskDetail(plan),
      subtitleMaxLines: plan.importedEarly ? 5 : 3,
      // BUG-1184：番剧名 + 种子名都很长，而这一行右侧还挂着最多 3 个操作按钮，窄屏
      // 上标题只剩百来像素。行高自由（在可滚动列表里，只有 minHeight 下限），放宽到
      // 两行；种子名同样从死板的单行放宽到两行。
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(plan.seriesTitle),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            plan.torrentTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (progressText != null)
            Text(progressText, maxLines: 1, style: theme.textTheme.bodySmall),
          if (plan.importedEarly)
            Text(
              t.anime_download_streaming_ready,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
          if (subtitleNote != null)
            Text(
              subtitleNote.$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: subtitleNote.$2,
              ),
            ),
          if (failReason != null)
            Text(
              failReason,
              // 入库被挡下的原因带补救说明（BUG-2775），两行放不下。
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // TODO-2481：暂停/恢复（仅后端具备该能力时显示）。图标随当前
          // 状态切换；操作成功由 tick 刷出新状态，无本地乐观态。
          if (downloading && _pauseCapable)
            if (displayStatus == TorrentDisplayStatus.paused)
              FushiIconButton(
                tooltip: t.download_task_resume,
                icon: FushiIcons.play,
                size: 20,
                onTap: () => _togglePausePlan(plan, pause: false),
              )
            else
              FushiIconButton(
                tooltip: t.download_task_pause,
                icon: FushiIcons.pause,
                size: 20,
                onTap: () => _togglePausePlan(plan, pause: true),
              ),
          if (downloading && !plan.importedEarly)
            FushiIconButton(
              tooltip: t.anime_download_play_now,
              icon: FushiIcons.playCircle,
              size: 20,
              onTap: () => _playNow(plan),
            ),
          if (failed)
            FushiIconButton(
              tooltip: t.anime_download_retry,
              icon: FushiIcons.refresh,
              size: 20,
              onTap: () => _retryPlan(plan),
            ),
          FushiIconButton(
            tooltip: t.anime_download_relocate,
            icon: FushiIcons.moveFile,
            size: 20,
            onTap: () => _relocatePlan(plan),
          ),
          FushiIconButton(
            tooltip: t.anime_download_delete,
            icon: FushiIcons.delete,
            size: 20,
            onTap: () => _deletePlan(plan),
          ),
        ],
      ),
    );
  }

  /// TODO-2482：打开任务详情对话框（入口 = 任务行点击）。
  void _openTaskDetail(AnimeDownloadPlan plan) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => TorrentTaskDetailDialog(
        plan: plan,
        networkIssue: ref.read(appProvider).torrentNetworkIssue,
      ),
    );
  }

  Widget _buildTasksPage(ThemeData theme) {
    final DownloadTasksBuilder? tasksBuilder = widget.tasksBuilder;
    if (tasksBuilder != null) {
      Widget buildEntries(
        Map<String, double> progress,
        Map<String, DownloadTaskStats> stats,
      ) {
        return tasksBuilder(context, <DownloadTaskEntry>[
          for (final AnimeDownloadPlan plan in _plans)
            animeDownloadTaskEntry(
              plan: plan,
              progress: progress[plan.id],
              stats: stats[plan.id],
              // torrent 侧四项服务层本来就有，此前只是 Entry 上没有槽位可填，
              // 于是统一列表里的 legacy 行既进不了批量重试也进不了批量清理。
              // 优先级不填：后端只有文件级 priority，没有任务级调度优先级。
              actions: _planActions(plan, stats[plan.id]),
              builder: (BuildContext context) => DownloadTaskCard(
                key: ValueKey<String>('legacy-plan:${plan.id}'),
                taskId: 'legacy-plan:${plan.id.trim().toLowerCase()}',
                // 旧番剧下载计划全是 BT（种子磁力 / 通用磁力）。
                method: DownloadTransferMethod.torrent,
                externalSource: true,
                title: plan.seriesTitle.isEmpty
                    ? plan.torrentTitle
                    : plan.seriesTitle,
                subtitle: plan.torrentTitle == plan.seriesTitle
                    ? null
                    : plan.torrentTitle,
                status: plan.status == AnimeDownloadPlan.statusImported
                    ? t.download_task_status_completed
                    : plan.status == AnimeDownloadPlan.statusFailed
                    ? t.download_task_status_error
                    : _torrentStatusLabel(
                            torrentDisplayStatusFor(
                              stats[plan.id]?.state ?? '',
                            ),
                          ) ??
                          t.download_task_status_downloading,
                progress: plan.status == AnimeDownloadPlan.statusImported
                    ? 1
                    : progress[plan.id],
                details: _buildPlanRow(Theme.of(context), plan),
              ),
            ),
        ]);
      }

      final AnimeDownloadService? service = ref
          .read(appProvider)
          .animeDownloadService;
      if (service == null) return buildEntries(const {}, const {});
      return ValueListenableBuilder<Map<String, double>>(
        valueListenable: service.downloadProgress,
        builder: (BuildContext context, Map<String, double> progress, _) =>
            ValueListenableBuilder<Map<String, DownloadTaskStats>>(
              valueListenable: service.downloadStats,
              builder:
                  (
                    BuildContext context,
                    Map<String, DownloadTaskStats> stats,
                    _,
                  ) => buildEntries(progress, stats),
            ),
      );
    }
    return FushiRefreshIndicator(
      onRefresh: _refreshPlans,
      child: _plans.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                const SizedBox(height: 72),
                FushiPlaceholderMessage(
                  icon: FushiIcons.downloading,
                  message: t.anime_download_no_tasks,
                ),
              ],
            )
          : FushiEntranceScope(
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: _plans.length,
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) => FushiGroupedListItem(
                    key: ValueKey<String>('anime-plan:${_plans[index].id}'),
                    index: index,
                    count: _plans.length,
                    // 行本身内边距 4（它也嵌在统一任务卡的详情里），进分段卡再补 8。
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: _buildPlanRow(theme, _plans[index]),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => _buildTasksPage(Theme.of(context));
}

/// TODO-1961-e：用户在改名/移动对话框里做出的选择。
class _RelocateChoice {
  const _RelocateChoice.move(this.value)
    : isMove = true,
      fileIndex = null,
      currentRelativePath = null;

  const _RelocateChoice.rename({
    required this.value,
    required int this.fileIndex,
    required String this.currentRelativePath,
  }) : isMove = false;

  /// true = 移动整个种子到 [value]（新 save_path）；false = 把某个文件改成 [value]。
  final bool isMove;

  /// 移动 = 目标目录绝对路径；改名 = 种子内新相对路径。
  final String value;

  /// 改名时的文件下标（移动时为 null）。
  final int? fileIndex;

  /// 改名时该文件当前的种子内相对路径（移动时为 null）。
  final String? currentRelativePath;
}

/// 改名 / 移动对话框：上半是「移动整个任务到某目录」，下半是逐文件改名。
///
/// 刻意**不**做成两个入口：用户想的是「整理这个下载」，移动和改名是同一件事的
/// 两个面，放一个弹窗里他一眼能看到自己有哪些文件、现在在哪。
class _RelocateDialog extends StatefulWidget {
  const _RelocateDialog({required this.snapshot, required this.files});

  final TorrentSnapshot snapshot;
  final List<TorrentFileEntry> files;

  @override
  State<_RelocateDialog> createState() => _RelocateDialogState();
}

class _RelocateDialogState extends State<_RelocateDialog> {
  /// 逐文件的改名输入框（key = 文件下标），初值 = 当前种子内相对路径。
  late final Map<int, TextEditingController> _controllers =
      <int, TextEditingController>{
        for (final TorrentFileEntry f in widget.files)
          f.index: TextEditingController(text: f.name),
      };

  @override
  void dispose() {
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDestination() async {
    // 迁移目标目录长期承载下载文件，必须是真实路径（见 pickRealDirectoryPath）。
    final String? picked = await pickRealDirectoryPath(
      context: context,
      appModel: ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider),
      dialogTitle: t.anime_download_relocate_pick_folder,
    );
    if (picked == null || picked.trim().isEmpty || !mounted) return;
    Navigator.pop(context, _RelocateChoice.move(picked.trim()));
  }

  void _submitRename(TorrentFileEntry file) {
    final String next = _controllers[file.index]?.text.trim() ?? '';
    if (next.isEmpty) return;
    Navigator.pop(
      context,
      _RelocateChoice.rename(
        value: next,
        fileIndex: file.index,
        currentRelativePath: file.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiAlertDialog(
      // M3E：图标徽标（形状库饼干底），Apple 下退成单色图标。
      icon: const FushiIcon(FushiIcons.moveFile),
      title: Text(t.anime_download_relocate),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 为什么必须在 app 里改名，而不是去资源管理器 —— 说清楚，否则用户
              // 改完再来问「怎么做种断了」。
              Text(
                t.anime_download_relocate_hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t.anime_download_relocate_move_title,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(widget.snapshot.savePath, style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: FushiFilledButton.tonalIcon(
                  onPressed: _pickDestination,
                  icon: const FushiIcon(FushiIcons.folderOpen, size: 18),
                  label: Text(t.anime_download_relocate_pick_folder),
                ),
              ),
              if (widget.files.isNotEmpty) ...<Widget>[
                const FushiDividerControl(height: 28),
                Text(
                  t.anime_download_relocate_rename_title,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                for (final TorrentFileEntry file in widget.files)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: FushiTextFieldControl(
                            controller: _controllers[file.index],
                            decoration: const InputDecoration(
                              isDense: true,
                              border: FushiOutlinedFieldBorder(),
                            ),
                            onSubmitted: (_) => _submitRename(file),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FushiIconButton(
                          tooltip: t.anime_download_relocate_rename_title,
                          icon: FushiIcons.rename,
                          size: 20,
                          onTap: () => _submitRename(file),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }
}
