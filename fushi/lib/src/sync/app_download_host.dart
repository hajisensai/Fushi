/// app 当互联 host 时的「代下载」实现（设计 §3.3）：把对端交来的磁链投进**本机**
/// 已经在跑的 `VideoDownloadPipelineService`，与用户在本机下载页手动添加任务走
/// 同一条管线、同一张 `video_download_jobs` 表——所以对端的任务会出现在本机下载
/// 中心的任务列表里，完成后按本机规则入库 / 刮削。
///
/// 与无头服务端 `ServerDownloadHost` 的差别只有「管线 / 后端落点 / 落地源从哪来」：
/// 服务端自己起管线、固定 `<documents>/downloads`；app 这边全是 `AppModel` 已有的
/// 东西，按闭包注入（管线是 fire-and-forget 起来的，host 可能先绑上端口，所以每次
/// 调用都现取而不是构造时快照）。
///
/// 非视频域（小说 / 漫画 / 有声书 / 游戏）也收：app 有发现导入执行器，下载完按域
/// 入库；服务端没有，所以能力位 `kinds` 两边不同，客户端据此决定投不投。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart'
    show VideoResourceProvider;
import 'package:fushi_engine/media/video/download/video_download_subscription_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart'
    show VideoMetadataMediaKind;
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/pipeline_subscription_host.dart';

class AppDownloadHost implements HostDownloadHost {
  AppDownloadHost({
    required FushiDatabase Function() database,
    required VideoDownloadPipelineService? Function() pipeline,
    required Future<VideoDownloadBackendTarget> Function() backendTarget,
    required String? Function() readyBackend,
    required Future<int?> Function() targetSourceId,
    required VideoResourceRegistry? Function() resourceRegistry,
    required VideoDownloadSubscriptionService? Function() subscriptionService,
    this.discoveryImportSupported = true,
  })  : _database = database,
        _pipeline = pipeline,
        _backendTarget = backendTarget,
        _readyBackend = readyBackend,
        _targetSourceId = targetSourceId,
        _resourceRegistry = resourceRegistry,
        _subscriptionService = subscriptionService;

  final FushiDatabase Function() _database;
  final VideoDownloadPipelineService? Function() _pipeline;

  /// 本机当前的后端落点（`AppModel.currentVideoDownloadBackendTarget`）。
  final Future<VideoDownloadBackendTarget> Function() _backendTarget;

  /// 就绪的后端名 `embedded` / `qbittorrent`，null = 本机没配好下载后端
  /// （`AppModel.readyVideoDownloadBackend`，与下载页「添加任务」同一判据）。
  final String? Function() _readyBackend;

  /// 视频任务的落地来源：用户在本机选的默认受管视频来源；null = 一个都没有。
  final Future<int?> Function() _targetSourceId;
  final VideoResourceRegistry? Function() _resourceRegistry;
  final VideoDownloadSubscriptionService? Function() _subscriptionService;

  /// 本机能否把非视频域下载按域入库（有发现导入执行器）。
  final bool discoveryImportSupported;

  /// `/api/subscriptions` 面：与代下载共享同一组闭包，registry / service 每次现取。
  HostSubscriptionHost get subscriptions => _AppSubscriptionHost(this);

  bool get _supported => _pipeline() != null && _readyBackend() != null;

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
        'supported': _supported,
        'backend': _readyBackend() ?? 'none',
        'kinds': <String>[
          'video',
          if (discoveryImportSupported) ...kHostDownloadDiscoveryKinds,
        ],
      };

  @override
  Future<List<VideoDownloadJobRow>> listJobs() =>
      _database().getVideoDownloadJobs();

  VideoDownloadPipelineService get _requirePipeline =>
      _pipeline() ??
      (throw const VideoDownloadPipelineActionRequired(
        'downloads are not configured on this host',
      ));

  @override
  Future<String> addMagnet({
    required String magnetUri,
    required String title,
    String mediaKind = 'movie',
    String? discoveryKind,
  }) async {
    final VideoDownloadPipelineService pipeline = _requirePipeline;
    if (_readyBackend() == null) {
      throw const VideoDownloadPipelineActionRequired(
        'no torrent backend configured on this host',
      );
    }
    DiscoveryMediaKind? kind;
    if (discoveryKind != null) {
      if (!discoveryImportSupported ||
          !kHostDownloadDiscoveryKinds.contains(discoveryKind)) {
        throw ArgumentError('this host does not import "$discoveryKind"');
      }
      kind = DiscoveryMediaKind.values.byName(discoveryKind);
    }
    int? sourceId;
    if (kind == null) {
      sourceId = await _targetSourceId();
      if (sourceId == null) {
        throw const VideoDownloadPipelineActionRequired(
          'no managed video source on this host',
        );
      }
    }
    final VideoDownloadBackendTarget target;
    try {
      target = await _backendTarget();
    } on VideoDownloadBackendUnavailable catch (error) {
      throw VideoDownloadPipelineActionRequired(error.message);
    }
    return pipeline.enqueueManual(
      VideoDownloadManualEnqueueRequest(
        title: title,
        backendTarget: target,
        magnetUri: magnetUri,
        discoveryKind: kind,
        mediaKind: mediaKind == 'tv'
            ? VideoMetadataMediaKind.tv
            : VideoMetadataMediaKind.movie,
        targetSourceId: sourceId,
      ),
    );
  }

  @override
  Future<void> cancelJob(String jobId) => _requirePipeline.cancelJob(jobId);

  @override
  Future<void> retryJob(String jobId) => _requirePipeline.retryJob(jobId);

  @override
  Future<void> deleteJob(String jobId) =>
      // **不删磁盘文件**：host 是用户自己的机器，`listJobs` 返回的是本机全表
      //（含 host 主人自己加的任务），对端在「远端任务」卡片上点一下删除就把
      // 主人已经下载好的文件删了是不可接受的。无头 `fushi_server` 那边整台机器
      // 本就是为对端服务的，语义不同。对端要的是「别再占我的列表」，落盘文件的
      // 去留归 host 主人在本机下载中心决定。
      _requirePipeline.deleteJob(jobId, deleteFiles: false);
}

/// 每次调用都按当下的 registry / service 重建一份 [PipelineSubscriptionHost]：
/// 它自身无状态（订阅行全在 DB），而 app 的下载 runtime 会随设置变更整体重建，
/// 缓存实例只会拿着一个已 dispose 的 service。registry 没起来时用空 registry
/// 顶上——能力位如实报 supported=false、provider 清单为空，列表 / 启停 / 删除
/// 只碰 DB 照常可用。
class _AppSubscriptionHost implements HostSubscriptionHost {
  const _AppSubscriptionHost(this._owner);

  final AppDownloadHost _owner;

  PipelineSubscriptionHost get _delegate => PipelineSubscriptionHost(
        db: _owner._database(),
        registry: _owner._resourceRegistry() ??
            VideoResourceRegistry(const <VideoResourceProvider>[]),
        backendTarget: _owner._backendTarget,
        targetSourceId: () async {
          final int? id = await _owner._targetSourceId();
          if (id == null) {
            throw const VideoDownloadPipelineActionRequired(
              'no managed video source on this host',
            );
          }
          return id;
        },
        backendName: _owner._readyBackend() ?? 'none',
        service: _owner._supported ? _owner._subscriptionService() : null,
      );

  @override
  Future<Map<String, Object?>> capability() => _delegate.capability();

  @override
  Future<List<VideoDownloadSubscriptionRow>> list() => _delegate.list();

  @override
  Future<Map<String, Map<String, int>>> itemCounts() => _delegate.itemCounts();

  @override
  Future<VideoDownloadSubscriptionRow> create(
    HostSubscriptionCreateRequest request,
  ) =>
      _delegate.create(request);

  @override
  Future<void> setEnabled(String subscriptionId, bool enabled) =>
      _delegate.setEnabled(subscriptionId, enabled);

  @override
  Future<void> checkNow(String? subscriptionId) =>
      _delegate.checkNow(subscriptionId);

  @override
  Future<void> delete(String subscriptionId) =>
      _delegate.delete(subscriptionId);
}
