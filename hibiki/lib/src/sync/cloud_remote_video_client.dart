import 'dart:async';
import 'dart:io';

import 'package:fushi/src/sync/hibiki_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoSource;
import 'package:fushi/src/sync/sync_asset_store.dart';
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
  CloudRemoteVideoClient({required this.backend, required this.backendType});

  /// 远端资产存取层；务必是 `resolveSyncBackend` 的产物（带解混淆装饰层）。
  final SyncAssetStore backend;

  /// [backend] 背后的云盘类型。只用于把清单缓存分槽——换后端类型（Drive→WebDAV）
  /// 之后两边的 `__videos__/` 内容毫无关系，必须落在不同槽里（BUG-1202）。
  /// [SyncAssetStore] 本身不带身份，所以由构造方（已经查过 `getBackendType()`）传入。
  final SyncBackendType backendType;

  @override
  String get remoteLibrarySourceId =>
      cloudRemoteLibrarySourceId(backendType.name);

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
    );
  }

  /// [RemoteVideoSource] 视图的下载入口；云盘就是整文件重下（无 Range 续传），
  /// 实现委托给既有的 [getRemoteVideo]。
  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
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
    await backend.getAsset(asset.id, destination, onProgress: onProgress);
  }
}
