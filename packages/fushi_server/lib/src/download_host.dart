/// 服务端的代下载：用引擎的 `VideoDownloadPipelineService` + qBittorrent 后端。
///
/// 与 app 的 `AppModel.startAnimeDownloadService` 同一条管线、同一张
/// `video_download_jobs` 表；区别只在装配：后端固定 qBittorrent（内置引擎的
/// Linux `.so` 是第 4 期）、目标视频源固定为 `<documents>/downloads`（首次启动自动
/// 建 media_sources 行）、非视频类内容不代下（没有发现导入执行器）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/qb_torrent_backend.dart';
import 'package:fushi_engine/media/torrent/qbittorrent_client.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;

class ServerDownloadHost implements HostDownloadHost {
  ServerDownloadHost({
    required this.config,
    required this.paths,
    required this.db,
    required this.prefs,
    required this.identity,
  });

  final ServerConfig config;
  final ServerPaths paths;
  final FushiDatabase db;
  final ServerPrefs prefs;
  final ServerIdentity identity;

  VideoDownloadPipelineService? _pipeline;
  VideoSourceScrapeCoordinator? _scrape;
  TorrentBackend? _backend;
  int? _sourceId;

  bool get configured =>
      (config.qbittorrentUrl ?? '').trim().isNotEmpty;

  Directory get downloadRoot => Directory(p.join(paths.documents.path, 'downloads'));

  QbConnectionConfig get _qbConfig => QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
        baseUrl: config.qbittorrentUrl ?? '',
        username: config.qbittorrentUsername ?? '',
        password: config.qbittorrentPassword ?? '',
      );

  Future<void> start() async {
    if (!configured || _pipeline != null) return;
    await downloadRoot.create(recursive: true);
    _sourceId = await _ensureDownloadSource();
    final VideoSourceScrapeCoordinator scrape = VideoSourceScrapeCoordinator(
      database: db,
      config: VideoSourceScrapeGlobalConfig.fromPreferences(
        prefs,
        resolvedTmdbApiKey: (prefs.getPref('video_scraper_tmdb_api_key', defaultValue: '') as String).trim(),
      ),
    );
    _scrape = scrape;
    final VideoDownloadPipelineService pipeline = VideoDownloadPipelineService(
      database: db,
      resourceRegistry: VideoResourceRegistry(const <VideoResourceProvider>[]),
      backendResolver: _resolveBackend,
      scrapeCoordinator: scrape,
      manualTorrentDirectory: Directory(p.join(paths.support.path, 'manual_torrents')),
      workerId: 'fushi-server-${identity.deviceId}',
    )..start();
    _pipeline = pipeline;
    engineLog.logDiagnostic('ServerDownloadHost', 'pipeline started (qBittorrent ${config.qbittorrentUrl}, root ${downloadRoot.path})');
  }

  Future<void> stop() async {
    final VideoDownloadPipelineService? pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) await pipeline.dispose(drainTimeout: const Duration(seconds: 5));
    _scrape?.close();
    _scrape = null;
    _backend?.close();
    _backend = null;
  }

  /// `<documents>/downloads` 的托管视频源行（管线 organize/import 要靠它落库）。
  Future<int> _ensureDownloadSource() async {
    final String root = p.normalize(downloadRoot.absolute.path);
    for (final MediaSourceRow row in await db.getMediaSourcesByKind('video')) {
      if (row.transport == 'local' && p.normalize(row.rootPath) == root) return row.id;
    }
    return db.insertMediaSource(MediaSourcesCompanion(
      label: const Value('fushi_server downloads'),
      mediaKind: const Value('video'),
      transport: const Value('local'),
      rootPath: Value(root),
      recursive: const Value(true),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
  }

  VideoDownloadBackendIdentity _identity() => buildVideoDownloadBackendIdentity(
        config: _qbConfig,
        resolvedBackend: QbConnectionConfig.backendQbittorrent,
        embeddedInstallationId: identity.deviceId,
      );

  Future<VideoDownloadBackendBinding?> _resolveBackend(VideoDownloadJobRow job) async {
    if (!configured) {
      throw const VideoDownloadPipelineActionRequired('no torrent backend configured on this host');
    }
    _backend ??= QbTorrentBackend(QBittorrentClient(
      baseUrl: config.qbittorrentUrl!,
      username: config.qbittorrentUsername ?? '',
      password: config.qbittorrentPassword ?? '',
    ));
    return VideoDownloadBackendBinding(backend: _backend!, identity: _identity());
  }

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
        'supported': configured,
        'backend': configured ? QbConnectionConfig.backendQbittorrent : 'none',
        'kinds': <String>['video'],
      };

  @override
  Future<List<VideoDownloadJobRow>> listJobs() => db.getVideoDownloadJobs();

  @override
  Future<String> addMagnet({
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
  }) async {
    final VideoDownloadPipelineService? pipeline = _pipeline;
    final int? sourceId = _sourceId;
    if (pipeline == null || sourceId == null) {
      throw const VideoDownloadPipelineActionRequired('downloads are not configured on this host');
    }
    return pipeline.enqueueManual(VideoDownloadManualEnqueueRequest(
      title: title,
      backendTarget: VideoDownloadBackendTarget(identity: _identity(), category: _qbConfig.category),
      magnetUri: magnetUri,
      mediaKind: mediaKind == 'tv' ? VideoMetadataMediaKind.tv : VideoMetadataMediaKind.movie,
      targetSourceId: sourceId,
    ));
  }

  VideoDownloadPipelineService get _requirePipeline =>
      _pipeline ?? (throw const VideoDownloadPipelineActionRequired('downloads are not configured on this host'));

  @override
  Future<void> cancelJob(String jobId) => _requirePipeline.cancelJob(jobId);

  @override
  Future<void> retryJob(String jobId) => _requirePipeline.retryJob(jobId);

  @override
  Future<void> deleteJob(String jobId) =>
      _requirePipeline.deleteJob(jobId, deleteFiles: true);
}
