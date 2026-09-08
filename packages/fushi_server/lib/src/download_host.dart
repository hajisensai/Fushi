/// 服务端的代下载：用引擎的 `VideoDownloadPipelineService` + 内置 libtorrent 引擎
/// 或外接 qBittorrent。
///
/// 与 app 的 `AppModel.startAnimeDownloadService` 同一条管线、同一张
/// `video_download_jobs` 表；区别只在装配：后端按 `torrent.engine` 三态解析
/// （auto：找得到 libfushi_torrent_ffi 就内置，否则配了 qBittorrent 就外接）、
/// 目标视频源固定为 `<documents>/downloads`（首次启动自动建 media_sources 行）、
/// 非视频类内容不代下（没有发现导入执行器）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/media_pref_keys.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
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
import 'package:fushi_server/src/native_libs.dart';
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
  EmbeddedTorrentHost? _embedded;
  int? _sourceId;

  /// 启动时解析定的后端：`embedded` / `qbittorrent` / null（都不可用）。
  String? _resolvedBackend;

  bool get configured => _resolvedBackend != null;
  bool get _qbConfigured => (config.qbittorrentUrl ?? '').trim().isNotEmpty;

  /// 内置引擎库：配置显式路径 > bundle/lib 随包 > 系统搜索路径（null = 裸名）。
  String? get _torrentLibraryPath {
    final String? configured = config.torrentLibraryPath;
    if (configured != null && configured.trim().isNotEmpty) return configured.trim();
    return locateBundledLibrary(torrentLibraryName());
  }

  Directory get downloadRoot => Directory(p.join(paths.documents.path, 'downloads'));

  QbConnectionConfig get _qbConfig => QbConnectionConfig(
        backend: _resolvedBackend == ServerConfig.torrentEngineEmbedded
            ? QbConnectionConfig.backendEmbedded
            : QbConnectionConfig.backendQbittorrent,
        baseUrl: config.qbittorrentUrl ?? '',
        username: config.qbittorrentUsername ?? '',
        password: config.qbittorrentPassword ?? '',
      );

  /// `torrent.engine` 三态 → 实际后端。探测只加载库、不建 session。
  String? _resolveEngine() {
    final String want = config.torrentEngine;
    final bool embeddedOk = EmbeddedTorrentHost.probeAvailable(libraryPath: _torrentLibraryPath);
    switch (want) {
      case ServerConfig.torrentEngineEmbedded:
        return embeddedOk ? ServerConfig.torrentEngineEmbedded : null;
      case ServerConfig.torrentEngineQbittorrent:
        return _qbConfigured ? ServerConfig.torrentEngineQbittorrent : null;
      default:
        if (embeddedOk) return ServerConfig.torrentEngineEmbedded;
        return _qbConfigured ? ServerConfig.torrentEngineQbittorrent : null;
    }
  }

  Future<void> start() async {
    if (_pipeline != null) return;
    _resolvedBackend = _resolveEngine();
    if (_resolvedBackend == null) {
      engineLog.logDiagnostic(
        'ServerDownloadHost',
        'no torrent backend: engine=${config.torrentEngine}, '
            'embedded lib=${_torrentLibraryPath ?? torrentLibraryName()} unavailable, '
            'qbittorrent ${_qbConfigured ? 'configured' : 'not configured'}',
      );
      return;
    }
    await downloadRoot.create(recursive: true);
    _sourceId = await _ensureDownloadSource();
    final VideoSourceScrapeCoordinator scrape = VideoSourceScrapeCoordinator(
      database: db,
      config: VideoSourceScrapeGlobalConfig.fromPreferences(
        prefs,
        resolvedTmdbApiKey: (prefs.getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String).trim(),
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
    engineLog.logDiagnostic(
      'ServerDownloadHost',
      'pipeline started (backend=$_resolvedBackend'
          '${_resolvedBackend == ServerConfig.torrentEngineQbittorrent ? ' ${config.qbittorrentUrl}' : ''}, '
          'root ${downloadRoot.path})',
    );
  }

  /// 内置引擎 session 懒建（幂等）；库/端口失败 → null，调用方报 ActionRequired。
  Future<EmbeddedTorrentHost?> _ensureEmbedded() async {
    final EmbeddedTorrentHost? existing = _embedded;
    if (existing != null) return existing;
    await paths.torrentResume.create(recursive: true);
    // 计划集合 = video_download_jobs 里仍活着的 embedded 任务；resume 目录只是它的镜像。
    final Set<String> restoreIds = legacyEmbeddedTorrentResumeIds(await db.getVideoDownloadJobs());
    final EmbeddedTorrentHost? host = EmbeddedTorrentHost.open(
      libraryPath: _torrentLibraryPath,
      baseSavePath: downloadRoot.path,
      resumeDir: paths.torrentResume.path,
      restoreIds: restoreIds,
      listenInterfaces: config.torrentListen,
    );
    if (host == null) {
      engineLog.logDiagnostic('ServerDownloadHost', 'embedded torrent session failed to open');
      return null;
    }
    host.applySessionSettings(_qbConfig);
    engineLog.logDiagnostic('ServerDownloadHost', 'embedded libtorrent ${host.libtorrentVersion} on ${config.torrentListen}');
    return _embedded = host;
  }

  Future<void> stop() async {
    final VideoDownloadPipelineService? pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) await pipeline.dispose(drainTimeout: const Duration(seconds: 5));
    _scrape?.close();
    _scrape = null;
    _backend?.close();
    _backend = null;
    final EmbeddedTorrentHost? embedded = _embedded;
    _embedded = null;
    if (embedded != null) {
      embedded.dispose(keepIds: legacyEmbeddedTorrentResumeIds(await db.getVideoDownloadJobs()));
    }
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
        resolvedBackend: _resolvedBackend == ServerConfig.torrentEngineEmbedded
            ? QbConnectionConfig.backendEmbedded
            : QbConnectionConfig.backendQbittorrent,
        embeddedInstallationId: identity.deviceId,
      );

  Future<VideoDownloadBackendBinding?> _resolveBackend(VideoDownloadJobRow job) async {
    switch (_resolvedBackend) {
      case ServerConfig.torrentEngineEmbedded:
        final EmbeddedTorrentHost? host = await _ensureEmbedded();
        if (host == null) {
          throw const VideoDownloadPipelineActionRequired('embedded torrent engine unavailable on this host');
        }
        // 短命视图，共享常驻 session（与 app 的 backendFactory 每 tick 一致）。
        return VideoDownloadBackendBinding(backend: host.backendView(), identity: _identity());
      case ServerConfig.torrentEngineQbittorrent:
        _backend ??= QbTorrentBackend(QBittorrentClient(
          baseUrl: config.qbittorrentUrl!,
          username: config.qbittorrentUsername ?? '',
          password: config.qbittorrentPassword ?? '',
        ));
        return VideoDownloadBackendBinding(backend: _backend!, identity: _identity());
    }
    throw const VideoDownloadPipelineActionRequired('no torrent backend configured on this host');
  }

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
        'supported': configured,
        'backend': _resolvedBackend ?? 'none',
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
