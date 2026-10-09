/// 服务端的代下载：用引擎的 `VideoDownloadPipelineService` + 内置 libtorrent 引擎
/// 或外接 qBittorrent。
///
/// 与 app 的 `AppModel.startAnimeDownloadService` 同一条管线、同一张
/// `video_download_jobs` 表；区别只在装配：后端按 `torrent.engine` 三态解析
/// （auto：找得到 libfushi_torrent_ffi 就内置，否则配了 qBittorrent 就外接）、
/// 目标视频源固定为 `<documents>/downloads`（首次启动自动建 media_sources 行）。
///
/// 非视频域（小说 / 漫画 / 有声书）下载完整包交给引擎的发现导入执行器按域入库
/// （见 `discovery_import_host.dart`）；游戏与小说包里的 PDF 服务端接不了，能力位
/// `kinds` 如实不宣告 `game`，投了按 400 拒。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/builtin_video_resource_providers.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_engine/media/torrent/qb_torrent_backend.dart';
import 'package:fushi_engine/media/torrent/qbittorrent_client.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_prefs.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/pipeline_subscription_host.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart' show DiscoveryMediaKind;
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/discovery_import_host.dart';
import 'package:fushi_server/src/native_libs.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;

class ServerDownloadHost implements HostDownloadHost {
  ServerDownloadHost({
    required this.config,
    required this.paths,
    required this.db,
    required this.prefs,
    required this.identity,
    required this.scrape,
    this.backendOverride,
    this.pollInterval = const Duration(seconds: 5),
  });

  final ServerConfig config;
  final ServerPaths paths;
  final FushiDatabase db;
  final ServerPrefs prefs;
  final ServerIdentity identity;

  /// 进程共享的刮削（协调器由 [HeadlessHost] 持有并关闭，这里只借用）。
  final ServerVideoScrape scrape;

  /// 测试缝：直接用这个 torrent 后端（跳过 libtorrent / qBittorrent 探测，按内置
  /// 引擎身份建任务）。生产传 null。
  final TorrentBackend? backendOverride;

  /// 管线轮询间隔（测试缩短；生产 5 秒，与 app 同）。
  final Duration pollInterval;

  VideoDownloadPipelineService? _pipeline;
  VideoResourceRegistry? _registry;
  VideoDownloadSubscriptionService? _subscriptionService;
  PipelineSubscriptionHost? _subscriptions;

  /// 内容订阅面（`/api/subscriptions`）。下载后端没起来时也挂着——能力位如实报
  /// supported=false，路由不 404（客户端好区分「host 不懂」与「host 没配后端」）。
  ///
  /// 返回的是**稳定的转发对象**：互联 server 启动时就把它捕获住了，而资源索引器改完
  /// （[reloadResourceIndexers]）背后的 [PipelineSubscriptionHost] 会换新——每次调用
  /// 现取当前那一份，能力位 `providers` 与 provider 在场校验才跟着新配置走。
  late final HostSubscriptionHost subscriptions = _ForwardingSubscriptionHost(() => _subscriptions ??= _buildSubscriptionHost());

  /// 当前 registry 下可用的 provider id（能力位同源；WebUI 保存索引器后回显用）。
  List<String> get availableResourceProviderIds => (_subscriptions ??= _buildSubscriptionHost()).availableProviderIds;
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

  // ── 「AI 下视频」助手会话（assistant_host.dart）的装配面：与 app 的
  // `createAppVideoAcquisitionService` 接同一组端口。后端没起来时前三项为 null。

  VideoDownloadPipelineService? get pipeline => _pipeline;
  VideoResourceRegistry? get registry => _registry;

  /// `<documents>/downloads` 的托管来源行；[start] 没起管线时 null。
  Future<MediaSourceRow?> downloadSource() async {
    final int? id = _sourceId;
    return id == null ? null : db.getMediaSourceById(id);
  }

  /// 提交那一刻的下载后端目标（与 `/api/downloads` 入队同一份身份）。
  VideoDownloadBackendTarget backendTarget() =>
      VideoDownloadBackendTarget(identity: _identity(), category: _qbConfig.category);

  /// 建订阅后立即检查一次；订阅服务没起时什么也不做。
  Future<void> checkSubscriptionsNow() async => _subscriptionService?.checkNow();

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
    if (backendOverride != null) return ServerConfig.torrentEngineEmbedded;
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
    // 资源索引器：与 app 同一张内置表 + 同一个 Torznab 偏好键（同一张 preferences 表），
    // 停用清单同源。订阅服务的在场校验看它，客户端搜到的 provider id 才对得上。
    _startPipeline(_buildRegistry());
    engineLog.logDiagnostic(
      'ServerDownloadHost',
      'pipeline started (backend=$_resolvedBackend'
          '${_resolvedBackend == ServerConfig.torrentEngineQbittorrent ? ' ${config.qbittorrentUrl}' : ''}, '
          'root ${downloadRoot.path})',
    );
  }

  void _startPipeline(VideoResourceRegistry registry) {
    _registry = registry;
    final VideoDownloadPipelineService pipeline = VideoDownloadPipelineService(
      database: db,
      resourceRegistry: registry,
      backendResolver: _resolveBackend,
      scrapeCoordinator: scrape.coordinator,
      manualTorrentDirectory: Directory(p.join(paths.support.path, 'manual_torrents')),
      workerId: 'fushi-server-${identity.deviceId}',
      pollInterval: pollInterval,
      // 非视频域：整包按域入库（书 / 漫画 / 有声书），见 discovery_import_host.dart。
      discoveryImporter: serverDiscoveryImporter(db),
      // 目标来源失效的任务重试时改绑到服务端自己的下载来源（BUG-2755）。
      defaultTargetSourceId: () async => _sourceId,
    )..start();
    _pipeline = pipeline;
    // 内容订阅：host 自己抢租约、搜、投管线（与 app 同一个服务类）。
    final VideoDownloadSubscriptionService subscriptions = VideoDownloadSubscriptionService(
      database: db,
      resourceRegistry: registry,
      enqueue: pipeline.enqueue,
      workerId: 'fushi-server-sub-${identity.deviceId}',
    );
    subscriptions.start();
    _subscriptionService = subscriptions;
    _subscriptions = null; // 让 getter 按新的 service 重建
  }

  Future<void> _reloadOps = Future<void>.value();

  /// 资源索引器配置（Torznab 清单 / 内置源停用清单）改完后调：按偏好重建 registry，
  /// 对正在跑的 host 立即生效，与 app `reloadVideoDownloadPipelineRuntime` 同一形态
  /// ——registry 是构造期快照，管线与订阅服务都持有它，只能整套换新。
  ///
  /// 只换「搜索面」：torrent 后端（内置 libtorrent session / qBittorrent 客户端）与下载
  /// 来源不动，正在下的种子不受影响。旧订阅服务等在飞的检查跑完再退；旧管线最多等
  /// 5 秒交出租约（任务按落库阶段由新管线续上），旧 registry 的 HTTP client 要等旧管线
  /// **真正停下**才关——在飞的 `resolveSelection` 仍拿着它，提前关会让那一步平白失败。
  /// 多次保存串行执行。
  Future<void> reloadResourceIndexers() {
    final Future<void> next = _reloadOps.then((_) => _reloadResourceIndexers());
    _reloadOps = next.then<void>((_) {}, onError: (Object e, StackTrace st) => engineLog.log('ServerDownloadHost.reloadResourceIndexers', e, st));
    return next;
  }

  Future<void> _reloadResourceIndexers() async {
    final VideoResourceRegistry? oldRegistry = _registry;
    final VideoDownloadPipelineService? oldPipeline = _pipeline;
    final VideoDownloadSubscriptionService? oldSubscriptions = _subscriptionService;
    if (oldPipeline == null) {
      // 后端没起来：没有管线在用 registry，只换订阅面（能力位 providers 跟着新配置）。
      _registry = null;
      _subscriptions = null;
      oldRegistry?.close();
      return;
    }
    // 换档期间 _registry 仍指向旧的：这段时间来的订阅请求拿旧 registry + 无 service
    // （能力位 supported=false，建订阅 409），不会顺手再造一个没人关的 registry。
    _subscriptionService = null;
    _subscriptions = null;
    if (oldSubscriptions != null) await oldSubscriptions.dispose();
    _pipeline = null;
    await oldPipeline.dispose(drainTimeout: const Duration(seconds: 5));
    _startPipeline(_buildRegistry());
    if (oldRegistry != null) unawaited(oldPipeline.stop().whenComplete(oldRegistry.close));
    engineLog.logDiagnostic('ServerDownloadHost', 'resource indexers reloaded: ${availableResourceProviderIds.join(', ')}');
  }

  /// 内置引擎 session 懒建（幂等）；库/端口失败 → null，调用方报 ActionRequired。
  Future<EmbeddedTorrentHost?> _ensureEmbedded() async {
    final EmbeddedTorrentHost? existing = _embedded;
    if (existing != null) return existing;
    await paths.torrentResume.create(recursive: true);
    // 计划集合 = video_download_jobs 里仍活着的 embedded 任务；resume 目录只是它的镜像。
    final Set<String> restoreIds = await loadEmbeddedTorrentResumeIds(db);
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

  VideoResourceRegistry _buildRegistry() {
    final List<TorznabIndexerConfig> torznab = readTorznabIndexerConfigs(
      prefs,
      onDecodeError: (Object e, StackTrace st) =>
          engineLog.log('ServerDownloadHost.torznabConfig', e, st),
    );
    return VideoResourceRegistry(
      <VideoResourceProvider>[
        for (final BuiltinVideoResourceProviderSpec spec in kBuiltinVideoResourceProviderSpecs)
          spec.create(createAppHttpIoClient()),
        // 没有启用的索引器就不注册（判据与 app 同一处，见 torznabHasEnabledIndexer，BUG-2818）。
        if (torznabHasEnabledIndexer(torznab))
          TorznabClient(indexers: torznab, client: createAppHttpIoClient(), closesClient: true),
      ],
      disabledProviderIds: readVideoResourceDisabledSourceIds(prefs),
    );
  }

  PipelineSubscriptionHost _buildSubscriptionHost() => PipelineSubscriptionHost(
        db: db,
        // 后端没起来时也由本对象持有（stop / 下次重载时关），不留孤儿 HTTP client。
        registry: _registry ??= _buildRegistry(),
        backendTarget: () => VideoDownloadBackendTarget(identity: _identity(), category: _qbConfig.category),
        targetSourceId: () => _sourceId ?? (throw const VideoDownloadPipelineActionRequired('download source not ready')),
        backendName: _resolvedBackend ?? 'none',
        service: _subscriptionService,
      );

  Future<void> stop() async {
    // 等在途的索引器重载落地，否则它会在 stop 之后再起一套没人关的管线。
    await _reloadOps;
    final VideoDownloadSubscriptionService? subscriptions = _subscriptionService;
    _subscriptionService = null;
    _subscriptions = null;
    if (subscriptions != null) await subscriptions.dispose();
    final VideoDownloadPipelineService? pipeline = _pipeline;
    _pipeline = null;
    if (pipeline != null) await pipeline.dispose(drainTimeout: const Duration(seconds: 5));
    _registry?.close();
    _registry = null;
    _backend?.close();
    _backend = null;
    final EmbeddedTorrentHost? embedded = _embedded;
    _embedded = null;
    if (embedded != null) {
      embedded.dispose(keepIds: await loadEmbeddedTorrentResumeIds(db));
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
    final TorrentBackend? override = backendOverride;
    if (override != null) return VideoDownloadBackendBinding(backend: override, identity: _identity());
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
        'kinds': <String>['video', ...kServerDownloadDiscoveryKinds],
      };

  @override
  Future<List<VideoDownloadJobRow>> listJobs() => db.getVideoDownloadJobs();

  @override
  Future<String> add(HostDownloadAddRequest request) async {
    // 能力位 `kinds` 之外的域（游戏，或不认识的值）：客户端照规矩不会投，投了按 400 拒。
    // 判据与能力位同一个集合，两边不会各说各话。
    final String? discoveryKind = request.discoveryKind;
    DiscoveryMediaKind? kind;
    if (discoveryKind != null) {
      if (!kServerDownloadDiscoveryKinds.contains(discoveryKind)) {
        throw ArgumentError('this host does not import "$discoveryKind"');
      }
      kind = DiscoveryMediaKind.values.byName(discoveryKind);
    }
    final VideoDownloadPipelineService? pipeline = _pipeline;
    final int? sourceId = _sourceId;
    if (pipeline == null || sourceId == null) {
      throw const VideoDownloadPipelineActionRequired('downloads are not configured on this host');
    }
    return pipeline.enqueueManual(request.toEnqueueRequest(
      backendTarget: VideoDownloadBackendTarget(identity: _identity(), category: _qbConfig.category),
      discoveryKind: kind,
      // 非视频任务不进受管视频来源（文件留在下载目录原地，整包按域入库）。
      targetSourceId: kind == null ? sourceId : null,
    ));
  }

  @override
  Future<List<VideoDownloadJobSubtitleRow>?> listJobSubtitles(String jobId) async {
    if (await db.getVideoDownloadJob(jobId) == null) return null;
    return db.getVideoDownloadJobSubtitles(jobId);
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

/// 见 [ServerDownloadHost.subscriptions]：每次调用转给当前那一份订阅面。
class _ForwardingSubscriptionHost implements HostSubscriptionHost {
  _ForwardingSubscriptionHost(this._current);

  final HostSubscriptionHost Function() _current;

  @override
  Future<Map<String, Object?>> capability() => _current().capability();

  @override
  Future<List<VideoDownloadSubscriptionRow>> list() => _current().list();

  @override
  Future<Map<String, Map<String, int>>> itemCounts() => _current().itemCounts();

  @override
  Future<VideoDownloadSubscriptionRow> create(HostSubscriptionCreateRequest request) => _current().create(request);

  @override
  Future<void> setEnabled(String subscriptionId, bool enabled) => _current().setEnabled(subscriptionId, enabled);

  @override
  Future<void> checkNow(String? subscriptionId) => _current().checkNow(subscriptionId);

  @override
  Future<void> delete(String subscriptionId) => _current().delete(subscriptionId);
}
