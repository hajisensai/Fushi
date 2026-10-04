/// 服务端的视频刮削：一个进程只有一套协调器 + 任务控制器 + 库内自动补刮。
///
/// 与 app `HomePage._videoSourceScrapeController` 同一套引擎组件、同一个装配形状：
/// - [VideoSourceScrapeCoordinator]：扫描补刮、下载管线导入后的刮削、客户端经互联
///   发起的重刮 / 手动指定（`LocalLibraryHostService.scrapeController`）共用这一份
///   （以前只有下载管线里建了一个，而且没配 torrent 后端时根本不建）；
/// - [VideoSourceScrapeTaskController]：全进程一把互斥门；
/// - [VideoLibraryScrapeSweep]：只补刮「从未认领过规范身份」的作品，按作品落盘记账
///   （`<support>/video_scrape_sweep_ledger.json`），重复触发廉价、不会每次扫描都把
///   整库重刮一遍。
///
/// 配置取构造时的快照（TMDB key / 资料语言在 WebUI 里改了要重启才生效，与
/// qBittorrent / torrent 同类）：下载管线持有协调器引用，热换会让它拿着一个已关闭的
/// 协调器。扫描后是否补刮（`scan_scrape`）每次现读，改完即生效。
///
/// 服务端没有 app 的内置 TMDB key（那是 app 本地密钥文件），TMDB 只在配置了
/// `tmdb_api_key`（或偏好表里的 `video_scraper_tmdb_api_key`）时可用；AniDB 同样按
/// 偏好表里的账号 / 客户端判 unavailable，不冒用别人的客户端标识。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/media_pref_keys.dart';
import 'package:fushi_engine/media/video/metadata/tmdb_video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_server/src/config/server_config.dart';

class ServerVideoScrape {
  ServerVideoScrape({
    required this.db,
    required PrefStore prefs,
    required ServerConfig Function() config,
    VideoSourceScrapeCoordinator Function(VideoSourceScrapeGlobalConfig config)? coordinatorFactory,
    VideoScrapeSweepLedger? ledger,
  }) : _config = config {
    final ServerConfig snapshot = config();
    final VideoSourceScrapeGlobalConfig scrapeConfig = VideoSourceScrapeGlobalConfig.fromPreferences(
      prefs,
      resolvedTmdbApiKey: resolveServerTmdbApiKey(snapshot, prefs),
      // 无头服务端没有界面语言，资料语言来自 `metadata_locale` 配置项。
      uiLocaleTag: snapshot.metadataLocale,
    );
    this.scrapeConfig = scrapeConfig;
    final VideoSourceScrapeCoordinator coordinator = coordinatorFactory != null
        ? coordinatorFactory(scrapeConfig)
        : VideoSourceScrapeCoordinator(
            database: db,
            config: scrapeConfig,
            // 与 app 生产装配一致：打开离线标题索引（AniDB 标题包 + Fribb 映射）。
            // 服务端没有 AI 配置，歧义候选留在待确认队列里（客户端可经互联手动指定）。
            enableOfflineTitleIndex: true,
          );
    this.coordinator = coordinator;
    final VideoSourceScrapeTaskController controller = VideoSourceScrapeTaskController(coordinator);
    this.controller = controller;
    _sweep = VideoLibraryScrapeSweep(
      database: db,
      controller: controller,
      isEnabled: () => _config().scanScrape,
      isHashReady: () => scrapeConfig.anidbHashReady,
      ledger: ledger ?? VideoScrapeSweepLedger.inSupportDirectory(),
      configFingerprint: scrapeConfig.runtimeFingerprint,
      // Shoko 式增量刷新：TMDB /tv/changes 与库内 TMDB id 求交集，只重刷变过的剧。
      tmdbChangedTvIds: ({required DateTime since}) {
        final VideoMetadataProvider? tmdb = coordinator.registry.provider(VideoMetadataProviderKind.tmdb);
        return tmdb is TmdbVideoMetadataProvider && tmdb.isAvailable
            ? tmdb.changedTvShowIds(since: since)
            : Future<Set<int>>.value(const <int>{});
      },
    );
  }

  final FushiDatabase db;
  final ServerConfig Function() _config;
  late final VideoSourceScrapeGlobalConfig scrapeConfig;
  late final VideoSourceScrapeCoordinator coordinator;
  late final VideoSourceScrapeTaskController controller;
  late final VideoLibraryScrapeSweep _sweep;
  bool _closed = false;

  /// 扫描 / 导入之后调用：对所有本地视频来源里「从未刮出规范身份」的作品补刮一轮。
  ///
  /// `scan_scrape: false` 时只算待确认清单、不发请求；已有批次在跑时直接放弃本轮
  /// （下次触发再试）。等批次跑完才返回（CLI `scan` 据此同步等结果）。
  Future<void> sweep() async {
    if (_closed) return;
    await _sweep.sweepOnce();
  }

  /// 仍待人工指定身份的作品数（查无 / 歧义；客户端经互联的「待确认」处理）。
  Future<int> pendingCount() async => (await _sweep.pendingWorks()).length;

  /// 对一部待确认作品跑一次 AI 识别（[VideoSourceScrapeCoordinator.identifyWorkWithAi]）。
  ///
  /// 只认待确认清单里的作品（[workKey] 是清单的 `id`，即 `stableKey`）：AI 识别就是
  /// 为「自动刮削没认出来」准备的；已识别的作品要换身份走 identify。
  /// 不在清单里抛 [StateError]。
  Future<Map<String, Object?>> identifyPendingWithAi(String workKey) async {
    final VideoPendingScrapeWork? entry = (await _sweep.pendingWorks())
        .where((VideoPendingScrapeWork e) => e.work.stableKey == workKey)
        .firstOrNull;
    if (entry == null) throw StateError('work "$workKey" is not in the pending list');
    final SourceScrapeReport report = await coordinator.identifyWorkWithAi(
      source: entry.source,
      workTitle: entry.work.title,
      workStableKey: workKey,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (VideoSourceScrapeProgress _) {},
    );
    return scrapeReportJson(report);
  }

  /// 待人工指定身份的作品清单（带最近一次没认出来的原因）。`key` 与互联
  /// `/api/library/metadata/*` 的作品键同形，可直接喂给 `ctl scrape search|identify`。
  Future<List<Map<String, Object?>>> pendingWorks() async => <Map<String, Object?>>[
        for (final VideoPendingScrapeWork entry in await _sweep.pendingWorksWithReasons())
          <String, Object?>{
            'id': entry.work.stableKey,
            'title': entry.work.title,
            'source': entry.source.id,
            'members': entry.work.members.length,
            'key': entry.work.collection == null
                ? <String, Object?>{'bookUid': entry.work.members.single.bookUid}
                : <String, Object?>{
                    'collection': <String, Object?>{
                      'name': entry.work.collection!.name,
                      'collectionType': entry.work.collection!.collectionType,
                    },
                  },
            if (entry.pendingNote != null) 'status': entry.pendingNote!.cause.name,
            if (entry.pendingNote != null) 'reason': entry.pendingNote!.reason,
          },
      ];

  /// 给 WebUI / admin status 的刮削状态。
  Map<String, Object?> status() {
    final VideoSourceScrapeProgress progress = controller.progress;
    final SourceScrapeReport? report = progress.report;
    return <String, Object?>{
      'enabled': _config().scanScrape,
      'busy': controller.isBusy,
      'phase': progress.phase.name,
      'current': progress.current,
      'total': progress.total,
      if (progress.currentWorkTitle != null) 'work': progress.currentWorkTitle,
      if (progress.message != null) 'message': progress.message,
      if (report != null)
        'lastReport': <String, Object?>{
          'totalWorks': report.totalWorks,
          'succeeded': report.succeededWorks,
          'failed': report.failedWorks,
          'pendingConfirmations': report.pendingConfirmations,
        },
      'tmdbAvailable': scrapeConfig.tmdbApiKey.isNotEmpty,
      'anidbHashReady': scrapeConfig.anidbHashReady,
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    controller.dispose();
    coordinator.close();
  }
}

/// 服务端 TMDB key：配置文件 `tmdb_api_key` 优先，其次偏好表（与 app 同一个键）。
/// 没有 app 的内置 key 兜底——那是 app 本地密钥文件，不随服务端分发。
String resolveServerTmdbApiKey(ServerConfig config, PrefStore prefs) {
  final String fromConfig = (config.tmdbApiKey ?? '').trim();
  if (fromConfig.isNotEmpty) return fromConfig;
  return (prefs.getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String).trim();
}

/// [SourceScrapeReport] 的 JSON 摘要（admin / CLI 输出用）。
Map<String, Object?> scrapeReportJson(SourceScrapeReport report) => <String, Object?>{
      'sourceIds': report.sourceIds,
      'totalWorks': report.totalWorks,
      'succeededWorks': report.succeededWorks,
      'failedWorks': report.failedWorks,
      'pendingConfirmations': report.pendingConfirmations,
      'cancelled': report.cancelled,
      'errors': <String>[for (final SourceScrapeIssue e in report.errors) '$e'],
    };
