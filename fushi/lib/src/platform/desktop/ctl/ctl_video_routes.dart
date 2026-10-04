import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        MediaSourceRow,
        VideoMetadataWorkRow,
        VideoSourceScrapeRunRow;
import 'package:fushi_engine/media/external_provider.dart'
    show ExternalProviderFailure, ProviderBatchResult;
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/torrent/nyaa_resource_provider.dart'
    show preferredNyaaSearchQueries;
import 'package:fushi_engine/media/torrent/video_resource_provider.dart'
    show VideoResourceCandidate, VideoResourceSearchRequest;
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_service.dart';
import 'package:fushi_engine/media/video/download/video_discovery_selection.dart'
    show VideoDiscoveryDownloadSelection;
import 'package:fushi_engine/media/video/download/video_discovery_submit.dart'
    show enqueueLocalVideoDownload;
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart'
    show VideoDownloadBackendTarget, VideoDownloadBackendUnavailable;
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart'
    show VideoMetadataDatabaseStore;
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataProviderKind, VideoMetadataWork;
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart'
    show VideoMetadataLookup;
import 'package:fushi_engine/media/video/metadata/video_metadata_work_loader.dart'
    show lookupOfWork;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart'
    show kSelectableVideoMetadataProviders;
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';

import 'package:fushi/src/media/video/acquisition/app_video_acquisition_assembly.dart'
    show videoDiscoveryScrapeConfig;
import 'package:fushi/src/media/video/metadata/video_scrape_runtime.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_video_support.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';

/// video 域控制通道路由（视频发现 / 刮削；CLI 侧命令见 `packages/fushi_cli/lib/src/commands/video_commands.dart`）。
///
/// 两组：
/// * 刮削（`/video/works`、`/video/scrape`）——全部经 HomePage 登记的
///   [VideoScrapeRuntime]（同一个任务控制器、同一把全应用刮削互斥门、同一份
///   待确认清单），与库页按钮 / 待确认队列 / 互联 host 代刮走同一条
///   `rescrapeWorkWithLookup` / `scrapeSource` 管线；资料源只收 AniDB / MAL / TMDB，
///   AniDB 的客户端登记、限流与缓存都在协调器里，这里不绕开任何一道。
/// * 发现（`/video/discovery`）——视频发现页「搜作品 → 搜资源 → 入队下载」那条
///   确定性路径（[VideoDiscoveryService] → [VideoResourceRegistry] →
///   [enqueueLocalVideoDownload]），不经 AI。
List<CtlRoute> buildVideoCtlRoutes(DesktopCtlContext context) {
  final _VideoCtl ctl = _VideoCtl(context);
  return <CtlRoute>[
    // ── 刮削 ──────────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/video/works', ctl.listWorks),
    CtlRoute.get('/api/admin/video/works/:id/candidates', ctl.searchCandidates),
    CtlRoute.post('/api/admin/video/works/:id/identify', ctl.identifyWork),
    CtlRoute.get('/api/admin/video/scrape', ctl.scrapeStatus),
    CtlRoute.post('/api/admin/video/scrape', ctl.scrape),
    CtlRoute.post('/api/admin/video/scrape/cancel', ctl.cancelScrape),
    // ── 发现 ──────────────────────────────────────────────────────────────
    CtlRoute.get('/api/admin/video/discovery/search', ctl.discover),
    CtlRoute.get(
      '/api/admin/video/discovery/works/:id/resources',
      ctl.searchResources,
    ),
    CtlRoute.post('/api/admin/video/discovery/acquire', ctl.acquire),
  ];
}

/// `video discover` 的作品结果（`vw1`…）。
final CtlVideoCandidateCache<VideoDiscoveryItem> _discoveredWorks =
    CtlVideoCandidateCache<VideoDiscoveryItem>('vw');

/// `video resources` 的资源候选（`vr1`…），连同作品身份快照与封面一起暂存——
/// 入队时要的正是搜索那一刻的身份（资源搜索页提交时同样带当时的 media）。
final CtlVideoCandidateCache<_ResourceEntry> _discoveredResources =
    CtlVideoCandidateCache<_ResourceEntry>('vr');

typedef _ResourceEntry = ({
  VideoMediaReference media,
  VideoResourceCandidate resource,
  String? coverUrl,
});

class _VideoCtl {
  _VideoCtl(this.context);

  final DesktopCtlContext context;

  AppModel get appModel => context.appModel;

  FushiDatabase get _db => appModel.database;

  // ── 门控 ────────────────────────────────────────────────────────────────

  void _requireVideoModule() {
    if (!appModel.moduleVisibility.isEnabled(ModuleId.video)) {
      throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
    }
  }

  /// HomePage 登记的刮削运行时；没有 HomePage（主窗口还没进首页）时 409。
  VideoScrapeRuntime _runtime() {
    _requireVideoModule();
    return appModel.videoScrapeRuntime ??
        (throw const CtlFailure.conflict('主窗口首页尚未就绪，稍后再试'));
  }

  void _requireDiscovery() {
    _requireVideoModule();
    if (!StoreRestrictedCapability.externalDiscovery.isAvailable) {
      throw const CtlFailure.rejected('本平台构建不提供发现源（商店合规）');
    }
  }

  /// 资源搜索与入队属于下载中心：与 `dl` 命令同一组门（合规 + 「浏览」模块）。
  void _requireDownloads() {
    _requireDiscovery();
    if (!StoreRestrictedCapability.downloads.isAvailable) {
      throw const CtlFailure.rejected('本平台构建不提供下载中心（商店合规）');
    }
    if (!appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
      throw const CtlFailure.rejected('「浏览」模块已关闭（设置 › 功能模块）');
    }
  }

  void _requireConfirm(CtlCall call, String what) {
    if (call.optBool('confirm') != true) {
      throw CtlFailure.badRequest('$what 需要 confirm=true');
    }
  }

  // ── 作品定位 ────────────────────────────────────────────────────────────

  /// 作品 id → 计划器作品单元（与库页「重新刮削」同两条定位函数）。
  ///
  /// 合集在计划里可能是 N 个独立作品（BUG-2433）：[allowAmbiguous] 为 false 时
  /// 不默选第一个（写身份猜错就写到别的作品上），回 409 并列出成员作品 id。
  Future<VideoPendingScrapeWork> _plannedWork(
    CtlVideoWorkId id, {
    bool allowAmbiguous = false,
  }) async {
    switch (id) {
      case CtlVideoBookWorkId(:final String bookUid):
        final VideoPendingScrapeWork? planned =
            await planScrapeWorkForVideoBook(_db, bookUid);
        if (planned == null) {
          throw CtlFailure.notFound(
            '${id.stableKey} 不在任何本机视频来源的刮削计划里'
            '（手动导入 / 远端下载的视频、目录分组来源或特典不参与刮削）',
          );
        }
        return planned;
      case CtlVideoCollectionWorkId(:final int collectionId):
        final List<VideoPendingScrapeWork> planned =
            await planScrapeWorksForCollection(_db, collectionId);
        if (planned.isEmpty) {
          throw CtlFailure.notFound('${id.stableKey} 不在任何本机视频来源的刮削计划里');
        }
        if (planned.length > 1 && !allowAmbiguous) {
          throw CtlFailure.conflict(
            '${id.stableKey} 在刮削计划里是 ${planned.length} 个独立作品，请指定其一：'
            '${planned.map((VideoPendingScrapeWork u) => u.work.stableKey).join(' ')}',
          );
        }
        return planned.first;
    }
  }

  // ── 作品列表 ────────────────────────────────────────────────────────────

  Future<List<SourceLibraryRow>> _localVideoSources() async =>
      (await _db.getMediaSourcesByKind('video'))
          .where((SourceLibraryRow s) => s.transport == 'local')
          .toList(growable: false);

  Future<VideoMetadataWorkRow?> _workRow(VideoSourceScrapeWork work) =>
      work.collection == null
      ? _db.getVideoMetadataWorkByBook(work.members.single.bookUid)
      : _db.getVideoMetadataWorkByCollection(work.collection!.id);

  Map<String, Object?> _workJson(
    VideoSourceScrapeWork work,
    SourceLibraryRow source,
  ) => <String, Object?>{
    'id': work.stableKey,
    'title': work.title,
    'sourceId': source.id,
    'source': source.label,
    'members': work.members.length,
  };

  /// `video works [--pending]`：全部作品（计划器单元 + 已刮出的身份），或待确认
  /// 作品及挂起原因（待确认面板同一个 `pendingWorksWithReasons`）。
  Future<Object?> listWorks(CtlCall call) async {
    if (call.optBool('pending') == true) {
      final VideoScrapeRuntime runtime = _runtime();
      final List<VideoPendingScrapeWork> pending = await runtime.sweep
          .pendingWorksWithReasons();
      return <String, Object?>{
        'pending': true,
        'works': <Map<String, Object?>>[
          for (final VideoPendingScrapeWork entry in pending)
            <String, Object?>{
              ..._workJson(entry.work, entry.source),
              'reason': entry.pendingNote?.cause.wire,
              if (entry.pendingNote != null)
                'note': ctlVideoPendingNoteJson(entry.pendingNote!),
            },
        ],
      };
    }
    _requireVideoModule();
    final List<Map<String, Object?>> works = <Map<String, Object?>>[];
    for (final SourceLibraryRow source in await _localVideoSources()) {
      for (final VideoSourceScrapeWork work in await VideoSourceWorkPlanner(
        _db,
      ).plan(source)) {
        final VideoMetadataWorkRow? row = await _workRow(work);
        final VideoMetadataLookup? lookup = row == null
            ? null
            : await lookupOfWork(_db, row.id);
        works.add(<String, Object?>{
          ..._workJson(work, source),
          'identity': lookup == null
              ? null
              : '${lookup.provider.name}:${lookup.externalId}',
          'scrapedTitle': row?.title,
          'year': row?.year,
        });
      }
    }
    return <String, Object?>{'pending': false, 'works': works};
  }

  // ── 手动候选 / 指定身份 ─────────────────────────────────────────────────

  /// `video candidates`：库页「重新刮削」搜索框背后的 `searchManualCandidates`
  /// （只读，不抢刮削互斥门）。查询词缺省用作品标题；`provider` 只过滤结果。
  Future<Object?> searchCandidates(CtlCall call) async {
    final VideoScrapeRuntime runtime = _runtime();
    final CtlVideoWorkId id = CtlVideoWorkId.parse(call.params['id']!);
    final VideoMetadataProviderKind? provider =
        call.optString('provider') == null
        ? null
        : parseCtlVideoProvider(call.optString('provider')!);
    // 多单元合集的候选搜索只需要作品形态，取第一个单元即可（互联 host 代搜同口径）。
    final VideoPendingScrapeWork unit = await _plannedWork(
      id,
      allowAmbiguous: true,
    );
    final String query = call.optString('q') ?? unit.work.title;
    final List<VideoSourceScrapeConfirmationCandidate> candidates =
        await _searchManual(runtime.controller, unit, query);
    return <String, Object?>{
      'workId': unit.work.stableKey,
      'query': query,
      'candidates': <Map<String, Object?>>[
        for (final VideoSourceScrapeConfirmationCandidate c in candidates)
          if (provider == null || c.lookup.provider == provider)
            ctlVideoCandidateJson(c.lookup, c.work),
      ],
    };
  }

  Future<List<VideoSourceScrapeConfirmationCandidate>> _searchManual(
    VideoSourceScrapeTaskController controller,
    VideoPendingScrapeWork unit,
    String query,
  ) async {
    if (!controller.supportsManualBinding) {
      throw const CtlFailure.unsupported('当前刮削实现不支持手动指定作品');
    }
    try {
      return await controller.searchManualCandidates(
        source: unit.source,
        workTitle: unit.work.title,
        workStableKey: unit.work.stableKey,
        query: query,
      );
    } on FormatException catch (e) {
      throw CtlFailure.badRequest('作品 id / 链接无效：${e.message}');
    }
  }

  /// `video identify`：手动指定身份。与候选搜索框里手打 `anidb:123` 同一条路——
  /// 协调器按 id 直取作品（白名单 + 正整数校验、provider 不可用时返回空），再交
  /// `rescrapeWorkWithLookup` 重刮落库（FIFO 队列 + 全应用互斥门）。
  Future<Object?> identifyWork(CtlCall call) async {
    final VideoScrapeRuntime runtime = _runtime();
    final CtlVideoWorkId id = CtlVideoWorkId.parse(call.params['id']!);
    final VideoMetadataProviderKind provider = parseCtlVideoProvider(
      call.requireString('provider'),
    );
    final String query = ctlVideoIdentityQuery(
      provider,
      call.requireString('externalId'),
      mediaKind: parseCtlVideoMediaKind(call.optString('type')),
    );
    final VideoPendingScrapeWork unit = await _plannedWork(id);
    final VideoSourceScrapeTaskController controller = runtime.controller;
    final List<VideoSourceScrapeConfirmationCandidate> candidates =
        await _searchManual(controller, unit, query);
    if (candidates.isEmpty) {
      throw CtlFailure.rejected(
        '${provider.name} 取不到 $query（资料源不可用 / 未配置凭据 / 查无此作品）',
      );
    }
    final VideoMetadataLookup lookup = candidates.first.lookup;
    final Future<SourceScrapeReport> task = runtime.observe(
      controller.rescrapeWorkWithLookup(
        source: unit.source,
        workTitle: unit.work.title,
        workStableKey: unit.work.stableKey,
        lookup: lookup,
      ),
    );
    final Map<String, Object?> head = <String, Object?>{
      'workId': unit.work.stableKey,
      'identity': ctlVideoLookupJson(lookup),
      'title': candidates.first.work.title,
    };
    if (call.optBool('wait') == false) {
      unawaited(task.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      return <String, Object?>{...head, 'queued': true};
    }
    return <String, Object?>{...head, ...await _awaitReport(task)};
  }

  /// 等一个单作品刮削结束并给出结论。失败不抛、进 report（provider 挂 / 封禁 /
  /// 候选被类型门拒），所以「成功」要看计数而不是没有异常（互联 7a 同一判据）。
  Future<Map<String, Object?>> _awaitReport(
    Future<SourceScrapeReport> task,
  ) async {
    final SourceScrapeReport report;
    try {
      report = await task;
    } on VideoSourceScrapeCancelled {
      throw const CtlFailure.conflict('刮削请求在执行前被撤回');
    } on VideoSourceScrapeWorkNotFound catch (e) {
      throw CtlFailure.notFound('作品已不在刮削计划里：${e.workTitle}');
    } on StateError catch (e) {
      throw CtlFailure.conflict(e.message);
    }
    final bool ok =
        report.failedWorks == 0 &&
        report.errors.isEmpty &&
        report.succeededWorks > 0;
    return <String, Object?>{'ok': ok, 'report': ctlVideoReportJson(report)};
  }

  // ── 重刮 ────────────────────────────────────────────────────────────────

  /// `video scrape <sourceId|workId>`：
  /// * 来源 id → 库页「刮削此来源」同一个 `scrapeSource`（非交互：歧义作品进
  ///   待确认清单，之后用 `video candidates / identify` 处理）。来源设置要求覆盖
  ///   外部 NFO / 图片时，库页会弹框确认；这里要显式 `allowOverwrite` + confirm。
  /// * 作品 id → 已有生产主源身份时按该身份重刮（`rescrapeWorkWithLookup`，同 TMDB
  ///   集编排的重刮）；还没有身份时走自动补刮同一个 `scrapeWorkSubsets` 试认一次。
  Future<Object?> scrape(CtlCall call) async {
    final VideoScrapeRuntime runtime = _runtime();
    final CtlVideoScrapeTarget target = CtlVideoScrapeTarget.parse(
      call.requireString('target'),
    );
    final bool wait = call.optBool('wait') == true;
    final VideoSourceScrapeTaskController controller = runtime.controller;
    switch (target) {
      case CtlVideoSourceTarget(:final int sourceId):
        final SourceLibraryRow? source = await _db.getMediaSourceById(sourceId);
        if (source == null) throw CtlFailure.notFound('没有这个来源：$sourceId');
        if (source.mediaKind != 'video' || source.transport != 'local') {
          throw CtlFailure.rejected('来源 $sourceId 不是本机视频来源');
        }
        final bool allowOverwrite = call.optBool('allowOverwrite') == true;
        if (allowOverwrite) _requireConfirm(call, '覆盖受保护的外部 NFO / 图片');
        if (controller.isBusy) {
          throw const CtlFailure.conflict('已有刮削批次或来源扫描在进行（video status 查看）');
        }
        final Future<SourceScrapeReport> task = runtime.observe(
          controller.scrapeSource(
            source,
            allowProtectedOverwrite: allowOverwrite,
          ),
        );
        final Map<String, Object?> head = <String, Object?>{
          'sourceId': source.id,
          'source': source.label,
          'mode': 'source',
        };
        if (!wait) {
          unawaited(
            task.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
          );
          return <String, Object?>{...head, 'started': true};
        }
        return <String, Object?>{...head, ...await _awaitReport(task)};
      case CtlVideoWorkTarget(:final CtlVideoWorkId workId):
        final VideoPendingScrapeWork unit = await _plannedWork(workId);
        final VideoMetadataLookup? confirmed = await VideoMetadataDatabaseStore(
          _db,
        ).confirmedLookup(unit.work);
        // 只有生产主源身份才按身份直取；历史 provider（Bangumi / AniList…）的
        // 旧身份不得触发退役 provider 的网络请求，按未识别处理。
        final bool byIdentity =
            confirmed != null &&
            kSelectableVideoMetadataProviders.contains(confirmed.provider);
        final Future<SourceScrapeReport> task;
        if (byIdentity) {
          task = runtime.observe(
            controller.rescrapeWorkWithLookup(
              source: unit.source,
              workTitle: unit.work.title,
              workStableKey: unit.work.stableKey,
              lookup: confirmed,
            ),
          );
        } else {
          if (controller.isBusy) {
            throw const CtlFailure.conflict(
              '已有刮削批次在进行，未识别作品的自动识别要等它结束（video status 查看）',
            );
          }
          task = runtime.observe(
            controller.scrapeWorkSubsets(
              <SourceLibraryRow, List<VideoSourceScrapeWork>>{
                unit.source: <VideoSourceScrapeWork>[unit.work],
              },
            ),
          );
        }
        final Map<String, Object?> head = <String, Object?>{
          'workId': unit.work.stableKey,
          'title': unit.work.title,
          'mode': byIdentity ? 'identity' : 'auto',
          if (byIdentity) 'identity': ctlVideoLookupJson(confirmed),
        };
        if (!wait) {
          unawaited(
            task.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
          );
          return <String, Object?>{...head, 'started': true};
        }
        return <String, Object?>{...head, ...await _awaitReport(task)};
    }
  }

  /// `video status`：当前批次进度、待确认、手动队列与最近的刮削运行记录
  /// （任务面板同一份 `getVideoSourceScrapeRuns`）。
  Future<Object?> scrapeStatus(CtlCall call) async {
    final VideoScrapeRuntime runtime = _runtime();
    final VideoSourceScrapeTaskController? controller =
        runtime.currentController;
    final int limit = (call.optInt('limit') ?? 10).clamp(1, 50);
    final List<VideoSourceScrapeRunRow> runs = await _db
        .getVideoSourceScrapeRuns(limit: limit);
    final VideoSourceScrapeConfirmation? confirmation =
        controller?.pendingConfirmation;
    return <String, Object?>{
      'busy': controller?.isBusy ?? false,
      'progress': controller == null
          ? null
          : ctlVideoProgressJson(controller.progress),
      'queuedManual': controller?.queuedManualRequestCount ?? 0,
      'pendingConfirmation': confirmation == null
          ? null
          : <String, Object?>{
              'work': confirmation.localWorkTitle,
              'source': confirmation.sourceLabel,
              'candidates': confirmation.candidates.length,
            },
      'runs': <Map<String, Object?>>[
        for (final VideoSourceScrapeRunRow run in runs)
          <String, Object?>{
            'id': run.id,
            'sourceId': run.sourceId,
            'scope': run.scope,
            'status': run.status,
            'provider': run.provider,
            'total': run.totalWorks,
            'succeeded': run.succeededWorks,
            'failed': run.failedWorks,
            'pending': run.pendingConfirmations,
            'startedAt': run.startedAt,
            'finishedAt': run.finishedAt,
            'error': run.lastError,
          },
      ],
    };
  }

  /// `video cancel`：任务面板「取消」同一个 `cancel()`（批次停在下一个取消边界）。
  Future<Object?> cancelScrape(CtlCall call) async {
    final VideoSourceScrapeTaskController? controller =
        _runtime().currentController;
    if (controller == null || !controller.isRunning) {
      throw const CtlFailure.conflict('没有正在进行的刮削批次');
    }
    controller.cancel();
    return <String, Object?>{'cancelled': true};
  }

  // ── 发现 ────────────────────────────────────────────────────────────────

  /// 与视频发现页同一装配（[videoDiscoveryScrapeConfig] + 合规门）；每次请求自建、
  /// 用完即关（互联 host 的助手会话同一做法）。
  VideoDiscoveryService _openDiscovery() => VideoDiscoveryService.production(
    videoDiscoveryScrapeConfig(
      appModel.prefsRepo,
      uiLocaleTag: appModel.appLocale.toLanguageTag(),
    ),
    discoveryAvailable: StoreRestrictedCapability.externalDiscovery.isAvailable,
  );

  static List<Map<String, Object?>> _failuresJson(
    List<ExternalProviderFailure> failures,
  ) => <Map<String, Object?>>[
    for (final ExternalProviderFailure f in failures)
      <String, Object?>{'source': f.providerId, 'message': f.message},
  ];

  /// `video discover <q>`：发现页搜索框同一个 [VideoDiscoveryService.load]。
  Future<Object?> discover(CtlCall call) async {
    _requireDiscovery();
    final String query = call.requireString('q');
    final VideoDiscoveryCategory? category = parseCtlVideoDiscoveryCategory(
      call.optString('category'),
    );
    final int page = call.optInt('page') ?? 1;
    if (page < 1) throw const CtlFailure.badRequest('page 必须 >= 1');
    final VideoDiscoveryService service = _openDiscovery();
    final ProviderBatchResult<VideoDiscoveryPage> result;
    try {
      result = await service.load(
        VideoDiscoveryRequest(category: category, query: query, page: page),
      );
    } finally {
      service.close();
    }
    final List<Map<String, Object?>> works = <Map<String, Object?>>[];
    final Set<String> seen = <String>{};
    for (final VideoDiscoveryPage p in result.items) {
      for (final VideoDiscoveryItem item in p.items) {
        final VideoMediaReference ref = item.reference;
        if (!seen.add(
          '${ref.providerId}:${ref.mediaKind.name}:${ref.mediaId}',
        )) {
          continue;
        }
        works.add(<String, Object?>{
          'id': _discoveredWorks.put(item),
          'title': ref.title,
          'originalTitle': ref.originalTitle,
          'year': ref.year,
          'kind': ref.mediaKind.name,
          'category': ref.discoveryCategory.name,
          'provider': ref.providerId,
          'mediaId': ref.mediaId,
          'score': item.score,
          'cover': item.posterUrl,
        });
      }
    }
    return <String, Object?>{
      'query': query,
      'works': works,
      'failures': _failuresJson(result.failures),
    };
  }

  /// `video resources <workId>`：资源搜索页同一个 [VideoResourceRegistry.search]。
  /// 作品缺拉丁标题时先按详情补齐别名（BUG-2794，与资源搜索页同一条
  /// `loadDetails` → `withWorkLatinTitles`），默认检索词与搜索框首选词同一函数。
  Future<Object?> searchResources(CtlCall call) async {
    _requireDownloads();
    final String id = call.params['id']!;
    final VideoDiscoveryItem? found = _discoveredWorks[id];
    if (found == null) {
      throw CtlFailure.notFound('没有作品 $id（结果只在本次 app 运行内有效，先 video discover）');
    }
    final VideoResourceRegistry registry =
        appModel.videoResourceRegistry ??
        (throw const CtlFailure.rejected('资源索引还没就绪（浏览 › 下载 里配置下载后端）'));
    VideoDiscoveryItem item = found;
    if (!item.reference.hasLatinTitle) {
      final VideoDiscoveryService service = _openDiscovery();
      try {
        final VideoMetadataWork? work = await service.loadDetails(item);
        item = item.withReference(item.reference.withWorkLatinTitles(work));
      } on Object {
        // 补齐失败照原条目搜（资源搜索页同一姿态）。
      } finally {
        service.close();
      }
    }
    final VideoMediaReference media = item.reference;
    final String query =
        call.optString('q') ??
        preferredNyaaSearchQueries(
          VideoResourceSearchRequest(media: media),
        ).firstOrNull ??
        media.title;
    final ProviderBatchResult<VideoResourceCandidate> result = await registry
        .search(VideoResourceSearchRequest(media: media, query: query));
    return <String, Object?>{
      'workId': id,
      'title': media.title,
      'query': query,
      'resources': <Map<String, Object?>>[
        for (final VideoResourceCandidate r in result.items)
          <String, Object?>{
            'id': _discoveredResources.put((
              media: media,
              resource: r,
              coverUrl: item.posterUrl,
            )),
            'title': r.title,
            'provider': r.providerId,
            'size': r.sizeBytes,
            'seeders': r.seeders,
            'resolution': r.resolution,
            'group': r.releaseGroup,
            'trusted': r.trusted,
            'published': r.publishedAt?.toIso8601String(),
          },
      ],
      'failures': _failuresJson(result.failures),
    };
  }

  /// `video get <resourceId>`：资源搜索页「下载」提交同一个
  /// [enqueueLocalVideoDownload]（后端目标在提交那一刻取，PR #1021），返回任务 id，
  /// 之后用 `dl get <jobId>` 查进度。
  Future<Object?> acquire(CtlCall call) async {
    _requireDownloads();
    final String id = call.requireString('id');
    final _ResourceEntry? entry = _discoveredResources[id];
    if (entry == null) {
      throw CtlFailure.notFound('没有资源 $id（结果只在本次 app 运行内有效，先 video resources）');
    }
    final VideoDownloadPipelineService pipeline =
        appModel.videoDownloadPipelineService ??
        (throw const CtlFailure.rejected('本机下载后端没有配好（浏览 › 下载 里配置）'));
    final List<MediaSourceRow> sources = await appModel
        .getManagedVideoDownloadSources();
    if (sources.isEmpty) {
      throw const CtlFailure.rejected('没有可用的受管视频来源（先在视频库添加一个本机来源）');
    }
    // 落地来源缺省与资源搜索页初值同一规则：偏好里的默认来源，否则第一个。
    final int? requested =
        call.optInt('sourceId') ??
        appModel.prefsRepo.videoDownloadTargetSourceId;
    final MediaSourceRow source =
        sources.firstWhereOrNull((MediaSourceRow s) => s.id == requested) ??
        (call.optInt('sourceId') != null
            ? (throw CtlFailure.notFound(
                '来源 ${call.optInt('sourceId')} 不是可用的受管视频来源',
              ))
            : sources.first);
    final VideoDownloadSubtitlePolicy subtitlePolicy =
        parseCtlVideoSubtitlePolicy(call.optString('subtitles'));
    final String jobId;
    try {
      final VideoDownloadBackendTarget backend = await appModel
          .currentVideoDownloadBackendTarget();
      jobId = await enqueueLocalVideoDownload(
        pipeline: pipeline,
        coverUrl: entry.coverUrl,
        selection: VideoDiscoveryDownloadSelection(
          media: entry.media,
          resource: entry.resource,
          source: source,
          subtitlePolicy: subtitlePolicy,
        ),
        target: backend,
      );
    } on VideoDownloadBackendUnavailable catch (e) {
      throw CtlFailure.rejected(e.message);
    } on VideoDownloadAlreadyQueued catch (e) {
      throw CtlFailure.conflict(e.message);
    } on VideoDownloadPipelineActionRequired catch (e) {
      throw CtlFailure.rejected(e.message);
    } on ArgumentError {
      throw const CtlFailure.rejected('下载后端没有配好（浏览 › 下载 里配置）');
    }
    return <String, Object?>{
      'jobId': jobId,
      'title': entry.resource.title,
      'work': entry.media.title,
      'sourceId': source.id,
      'source': source.label,
    };
  }
}
