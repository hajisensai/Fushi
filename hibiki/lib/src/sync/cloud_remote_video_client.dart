import 'dart:async';
import 'dart:io';

import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart' show SyncBackendError;
import 'package:hibiki/src/sync/sync_orchestrator.dart'
    show kSyncVideosNamespace, kSyncVideosManifestName;
import 'package:hibiki/src/sync/video_manifest.dart';

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
class CloudRemoteVideoClient {
  CloudRemoteVideoClient({required this.backend});

  /// 远端资产存取层；务必是 `resolveSyncBackend` 的产物（带解混淆装饰层）。
  final SyncAssetStore backend;

  /// 读 `__videos__/videos.json` 目录清单，返回全部云视频条目（uid/title/大小/
  /// importedAt/videoAsset/coverAsset）。命名空间或清单缺失（从未有设备上传）→ 空表。
  /// 清单结构非法（[FormatException]）向上抛，交调用方按「本轮云视频不可用」降级。
  Future<List<RemoteVideoManifestEntry>> listRemoteVideos() async {
    final String ns = await backend.ensureNamespace(kSyncVideosNamespace);
    final AssetEntry? asset =
        await backend.findAsset(ns, kSyncVideosManifestName);
    if (asset == null) return const <RemoteVideoManifestEntry>[];
    final Object? json = await backend.getJsonAsset(asset.id);
    if (json == null) return const <RemoteVideoManifestEntry>[];
    return RemoteVideoManifest.fromJson(json).videos;
  }

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
    for (final RemoteVideoManifestEntry e in await listRemoteVideos()) {
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
