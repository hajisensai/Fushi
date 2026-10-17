import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo, RemoteVideoStreamUrls;
import 'package:fushi/src/sync/cloud_video_stream_relay.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoClient, RemoteVideoSource;
import 'package:fushi/src/sync/sync_asset_range_reader.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncBackendError, SyncBackendType;
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show kSyncVideosNamespace, kSyncVideosManifestName;
import 'package:fushi/src/sync/video_manifest.dart';

/// 把云盘备份后端（Google Drive / WebDAV / OneDrive / Dropbox / FTP / SFTP）里由
/// 「上传视频文件」开关（多端库联合视图 §2.6 / 任务12）推上去的 `__videos__/` 资产，
/// 适配成书架/视频页渲染云视频占位卡 + 按 uid 下载入库所需的**只读** client。
///
/// 与 [CloudRemoteBookClient] 同范式：云盘没有 host 实时库 API，远端视频就是
/// `__videos__/videos.json` 目录清单 + 命名空间下每条一个视频资产（可选封面资产），
/// 由开启开关的设备上传产生。本 client 把「读清单」收敛成 [listRemoteVideos]，把
/// 「按 uid 取视频/封面资产并下载到落点」收敛成 [getRemoteVideo] / [getRemoteVideoCover]
/// （**只下载不导入**——下载后走既有视频导入链入库由 UI 批负责，避免双重导入）。
///
/// [backend] **必须**是 `resolveSyncBackend` 的产物（含 `ObfuscatingSyncBackend`
/// 解混淆装饰层），否则下载下来的视频/封面是混淆字节。仅需资产存取能力，故按更窄的
/// [SyncAssetStore] 契约声明依赖（`SyncBackend` 是其子类型，直接传入即可）。
class CloudRemoteVideoClient implements RemoteVideoSource {
  CloudRemoteVideoClient({
    required this.backend,
    required this.backendType,
    SyncAssetRangeReader? rangeReader,
    Future<CloudVideoStreamRelay> Function()? relay,
  })  : _rangeReader = rangeReader ?? plainAssetRangeReaderOf(backend),
        _relay = relay ?? CloudVideoStreamRelay.instance;

  /// 远端资产存取层；务必是 `resolveSyncBackend` 的产物（带解混淆装饰层）。
  final SyncAssetStore backend;

  /// [backend] 背后的云盘类型。只用于把清单缓存分槽——换后端类型（Drive→WebDAV）
  /// 之后两边的 `__videos__/` 内容毫无关系，必须落在不同槽里（BUG-1202）。
  /// [SyncAssetStore] 本身不带身份，所以由构造方（已经查过 `getBackendType()`）传入。
  final SyncBackendType backendType;

  @override
  String get remoteLibrarySourceId =>
      cloudRemoteLibrarySourceId(backendType.name);

  /// [backend] 的明文区间读视图；null = 该云盘只能整文件下载（WebDAV / FTP / SFTP）。
  final SyncAssetRangeReader? _rangeReader;
  final Future<CloudVideoStreamRelay> Function() _relay;
  CloudStreamVideoClient? _streaming;

  /// 流播视图：该云盘能按 `Range` 读（OneDrive / Dropbox / Google Drive）时给出，
  /// 否则 null（WebDAV / FTP / SFTP，调用方只提供「下载」）。同一 client 复用同一
  /// 实例，让「资产是否混淆」的探测结果在多次播放间共享。
  CloudStreamVideoClient? streamingClient() {
    final SyncAssetRangeReader? reader = _rangeReader;
    if (reader == null) return null;
    return _streaming ??= CloudStreamVideoClient._(this, reader, _relay);
  }

  /// 读 `__videos__/videos.json` 目录清单，返回全部云视频条目（uid/title/大小/
  /// importedAt/videoAsset/coverAsset）。命名空间或清单缺失（从未有设备上传）→ 空表。
  /// 清单结构非法（[FormatException]）向上抛，交调用方按「本轮云视频不可用」降级。
  ///
  /// 这是**清单层**视图（同步编排、上传去重等要看 `videoAsset`/`coverAsset` 资产名）；
  /// 库页消费的是 [listRemoteVideos] 的 [RemoteVideoInfo] 视图。
  Future<List<RemoteVideoManifestEntry>> listRemoteVideoManifest() async {
    final String ns = await backend.ensureNamespace(kSyncVideosNamespace);
    final AssetEntry? asset =
        await backend.findAsset(ns, kSyncVideosManifestName);
    if (asset == null) return const <RemoteVideoManifestEntry>[];
    final Object? json = await backend.getJsonAsset(asset.id);
    if (json == null) return const <RemoteVideoManifestEntry>[];
    return RemoteVideoManifest.fromJson(json).videos;
  }

  /// [RemoteVideoSource] 视图：把云清单条目适配成库页主网格消费的 [RemoteVideoInfo]。
  ///
  /// 适配逻辑此前长在 `home_video_page.dart` 里（`_cloudManifestToRemoteVideoInfo`），
  /// 于是给 [RemoteVideoInfo] 加字段时必须记得回去改页面，漏改则云侧该字段永远是空的
  /// （TODO-2119）。DTO 知识归 client 所有，页面不该知道 manifest 长什么样。
  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    return <RemoteVideoInfo>[
      for (final RemoteVideoManifestEntry e in await listRemoteVideoManifest())
        _manifestToInfo(e),
    ];
  }

  /// 云清单只带 uid/title/大小/importedAt/封面资产名——无外挂字幕、无远端进度、
  /// 无合集归属（云视频占位永远散卡，与 §2.3 host 合集归属互不影响），故这些字段取
  /// 缺省。封面走下载时的 [getRemoteVideoCover]，占位阶段用占位图（不预下封面），
  /// 因此这里不设 coverPath/coverUrl。
  RemoteVideoInfo _manifestToInfo(RemoteVideoManifestEntry e) {
    return RemoteVideoInfo(
      id: e.uid,
      title: e.title,
      sizeBytes: e.sizeBytes,
      // tags 稳健档：把清单条目的标签 LWW 时钟带进 RemoteVideoInfo，供下载后
      // mergeRemoteVideoTags 按名 max(add) vs max(removed) 解析（删除/改名传播）。
      tagsAddedAt: e.tagsAddedAt,
      tagTombstones: e.tagTombstones,
      // 云清单本来就带入库戳（0 = 旧数据未知），透传给首页「最近添加」/组间序。
      importedAt: e.importedAtMs > 0 ? e.importedAtMs : null,
    );
  }

  /// [RemoteVideoSource] 视图的下载入口；云盘就是整文件重下（无 Range 续传），
  /// 实现委托给既有的 [getRemoteVideo]。云盘资产接口只报比例进度、没有中止
  /// 缝，[onBytes] / [cancelSignal] 不生效（契约允许忽略）。
  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) =>
      getRemoteVideo(id, dest, onProgress: onProgress);

  /// 把 [uid] 对应的视频文件资产下载到 [destination]。清单里无此 uid，或清单记录的
  /// 视频资产在命名空间下已不存在 → 抛 [SyncBackendError]（调用方提示下载失败）。
  Future<void> getRemoteVideo(
    String uid,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final RemoteVideoManifestEntry entry = await _requireEntry(uid);
    await _download(entry.videoAsset, destination, onProgress: onProgress);
  }

  /// 把 [uid] 对应的封面资产下载到 [destination]；该条目无封面记录返回 false（不抛，
  /// 占位卡回退无封面渲染）；有封面记录但下载失败仍向上抛。
  Future<bool> getRemoteVideoCover(
    String uid,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final RemoteVideoManifestEntry entry = await _requireEntry(uid);
    final String? cover = entry.coverAsset;
    if (cover == null || cover.isEmpty) return false;
    await _download(cover, destination, onProgress: onProgress);
    return true;
  }

  Future<RemoteVideoManifestEntry> _requireEntry(String uid) async {
    for (final RemoteVideoManifestEntry e in await listRemoteVideoManifest()) {
      if (e.uid == uid) return e;
    }
    throw SyncBackendError('remote video not found in manifest: $uid');
  }

  Future<void> _download(
    String assetName,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    final String ns = await backend.ensureNamespace(kSyncVideosNamespace);
    final AssetEntry? asset = await backend.findAsset(ns, assetName);
    if (asset == null) {
      throw SyncBackendError('remote video asset missing: $assetName');
    }
    await backend.getAsset(asset.id, destination,
        onProgress: syncTransferFractionOnly(onProgress));
  }
}

/// 云盘视频的**流播**视图（对齐 SenPlayer 的网盘直连）：播放页只认
/// [RemoteVideoClient]，这里给它一份只做流播的实现。
///
/// 流地址是本地 [CloudVideoStreamRelay] 的 loopback 地址——每个 `Range` 请求都经
/// [SyncAssetRangeReader] 现取直链 / 现刷 token 并按偏移解混淆，所以暂停很久再 seek
/// 也不会撞上过期链接；预签名 URL 与 Bearer 头不出 Dart 层。
///
/// 云清单没有外挂字幕、没有服务端断点，这两组方法按 [RemoteVideoClient] 契约给
/// 「不支持」的答复：断点读回 (0, 0)、上报 no-op——进度由播放页按
/// `videoRemotePositionEpisodePrefKey(<manifest uid>, 0)` 落本机 prefs，键只取
/// 云端条目身份，与临期 URL / 本地端口无关；下载入库后由库页把它接到本地行。
/// 流里的内嵌字幕照常由 libmpv 解出。
class CloudStreamVideoClient extends RemoteVideoClient {
  CloudStreamVideoClient._(this._cloud, this._reader, this._relay);

  final CloudRemoteVideoClient _cloud;
  final SyncAssetRangeReader _reader;
  final Future<CloudVideoStreamRelay> Function() _relay;

  /// manifest uid → 视频资产（id + 名字）；资产上传即定、换内容会换名，进程内缓存即可。
  final Map<String, AssetEntry> _videoAssets = <String, AssetEntry>{};

  @override
  String get remoteLibrarySourceId => _cloud.remoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() => _cloud.listRemoteVideos();

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) =>
      _cloud.downloadRemoteVideo(
        id,
        dest,
        onProgress: onProgress,
        onBytes: onBytes,
        cancelSignal: cancelSignal,
      );

  /// 云视频都是单集条目，[episodeIndex] 不参与寻址。
  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    final AssetEntry asset = await _videoAsset(id);
    await _preflight(asset.id);
    final CloudVideoStreamRelay relay = await _relay();
    final Uri url = relay.register(
      reader: _reader,
      source: remoteLibrarySourceId,
      assetId: asset.id,
      fileName: asset.name,
    );
    return RemoteVideoStreamUrls(streamUrl: url.toString());
  }

  /// 起播前先真读一个字节。
  ///
  /// 登录失效（refresh token 过期 / 被吊销）这类「根本读不了」的失败要在这里以原类型
  /// （[SyncAuthError] 等）抛给播放页，播放页才能说「请重新登录」；否则它们只会在中继
  /// 里变成一个 502，libmpv 报「打不开」，用户看到的是通用失败。顺带把直链 / token /
  /// 混淆探测预热进缓存，内核的首个请求直接复用，不多一轮 API 往返。
  Future<void> _preflight(String assetId) async {
    final SyncAssetRange head;
    try {
      head = await _reader.openAssetRange(assetId, start: 0, end: 0);
    } on SyncAssetRangeNotSatisfiable {
      return; // 空文件：交给中继照常回 416，这里不替它判。
    }
    await head.bytes.drain<void>();
  }

  Future<AssetEntry> _videoAsset(String uid) async {
    final AssetEntry? cached = _videoAssets[uid];
    if (cached != null) return cached;
    final RemoteVideoManifestEntry entry = await _cloud._requireEntry(uid);
    final String ns =
        await _cloud.backend.ensureNamespace(kSyncVideosNamespace);
    final AssetEntry? asset =
        await _cloud.backend.findAsset(ns, entry.videoAsset);
    if (asset == null) {
      throw SyncBackendError('remote video asset missing: ${entry.videoAsset}');
    }
    final AssetEntry resolved =
        AssetEntry(id: asset.id, name: entry.videoAsset);
    _videoAssets[uid] = resolved;
    return resolved;
  }

  /// 云清单不带外挂字幕：[remoteVideoStreamUrls] 从不给 `subtitleUrl`，播放页不会
  /// 走到这里；真被调到就如实失败（调用方已按「无字幕、视频照常播」兜底）。
  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    throw SyncBackendError('cloud videos have no server-side subtitles: $id');
  }

  /// 云盘没有服务端断点：按契约回 (0, 0)，播放页只用本机 prefs 里的断点。
  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  /// 云盘没有服务端断点可上报；本机 prefs 已由播放页写好。
  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
