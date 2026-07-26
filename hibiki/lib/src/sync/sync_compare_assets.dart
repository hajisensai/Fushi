import 'dart:developer' as developer;
import 'dart:io';

import 'package:hibiki/src/models/local_audio_manager.dart';
import 'package:hibiki/src/sync/cloud_remote_video_client.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_orchestrator.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 一条资产对比项：按跨端身份键对齐本端与远端的存在性。
///
/// [localId] / [remoteId] 都非空 = 两端都有（已同步）；只有一边非空 = 该边独有，
/// UI 据此给「上传」或「下载」动作。二者同时为 null 是非法状态，构造点保证不产生。
class SyncAssetEntry {
  const SyncAssetEntry({
    required this.kind,
    required this.name,
    required this.identity,
    this.localId,
    this.remoteId,
    this.localSizeBytes,
    this.remoteSizeBytes,
  });

  final SyncAssetKind kind;

  /// 显示名（书名 / 词典名 / 音频库显示名 / 视频标题）。
  final String name;

  /// 跨端身份键：两端按它对齐。词典=name，有声书=bookKey 或 SRT uid，
  /// 音频库=displayName，视频=`VideoBooks.bookUid`。
  final String identity;

  /// 本端定位符：词典名 / 有声书 bookKey|uid / 音频库 DB 文件路径 / 视频文件路径。
  /// null = 远端独有。
  final String? localId;

  /// 远端定位符：云后端的 [AssetEntry.id]，互联的传输身份键。null = 本端独有。
  final String? remoteId;

  final int? localSizeBytes;
  final int? remoteSizeBytes;

  bool get hasLocal => localId != null;
  bool get hasRemote => remoteId != null;

  /// 两端都有且（若双方都能报告尺寸）内容尺寸一致，才算已经收敛。
  ///
  /// 视频传输本身会在尺寸不同时覆盖远端；这里必须使用同一判据，否则远端旧文件/
  /// 截断文件会被 UI 误标成“已同步”，上传按钮也随之消失。
  bool get isSynced {
    if (!hasLocal || !hasRemote) return false;
    if (kind == SyncAssetKind.video &&
        localSizeBytes != null &&
        remoteSizeBytes != null &&
        localSizeBytes != remoteSizeBytes) {
      return false;
    }
    return true;
  }

  SyncAssetEntry copyWith({
    String? localId,
    String? remoteId,
    bool clearRemote = false,
    bool clearLocal = false,
  }) =>
      SyncAssetEntry(
        kind: kind,
        name: name,
        identity: identity,
        localId: clearLocal ? null : (localId ?? this.localId),
        remoteId: clearRemote ? null : (remoteId ?? this.remoteId),
        localSizeBytes: localSizeBytes,
        remoteSizeBytes: remoteSizeBytes,
      );
}

const String kDictionaryAssetSuffix = '.hibikidict';
const String kLocalAudioAssetSuffix = '.hibikiaudiolib';

/// 枚举四类资产在本端/远端的存在性，供「本地 vs 远端」对比框渲染。
///
/// 四个维度的远端清单**互相独立**，一律并发发起（[Future.wait]）：加维度不加墙钟
/// 时间。任一维度失败只丢该维度（记日志），不让一次列举失败把整个对比框打成错误页
/// ——用户宁可看到「书 + 词典」也不想看到一片红。
///
/// [cloudAudiobookIds] 是云后端在书籍扫描阶段**已经**拿到的 `audiobook.hibikiaudio`
/// 定位符（书名 -> assetId）。云有声书就藏在书文件夹里，书籍那一轮已经列过；这里复用
/// 而不是再列一遍远端，省掉 N 次网络往返。互联后端传空表（它走 host 有声书清单）。
///
/// 它是 **Future**：调用方可以把书籍扫描与本函数同时发出去，只有有声书这一维真正
/// 需要它时才等——否则整个资产列举会被书籍那一轮的耗时白白串起来。
Future<List<SyncAssetEntry>> fetchSyncAssetEntries({
  required HibikiDatabase db,
  required SyncBackend backend,
  required List<LocalAudioDbEntry> localAudioEntries,
  Future<Map<String, String>>? cloudAudiobookIds,
  bool includeDictionaries = true,
  void Function(String dimension, Object error)? onError,
}) async {
  final List<List<SyncAssetEntry>> groups = await Future.wait(
    <Future<List<SyncAssetEntry>>>[
      if (includeDictionaries)
        _guard('dictionaries', () => _fetchDictionaries(db, backend), onError)
      else
        Future<List<SyncAssetEntry>>.value(const <SyncAssetEntry>[]),
      _guard('audiobooks',
          () => _fetchAudiobooks(db, backend, cloudAudiobookIds), onError),
      _guard('localAudio', () => _fetchLocalAudio(backend, localAudioEntries),
          onError),
      _guard('videos', () => _fetchVideos(db, backend), onError),
    ],
  );
  return <SyncAssetEntry>[for (final List<SyncAssetEntry> g in groups) ...g];
}

Future<List<SyncAssetEntry>> _guard(
  String label,
  Future<List<SyncAssetEntry>> Function() body,
  void Function(String dimension, Object error)? onError,
) async {
  try {
    return await body();
  } catch (e) {
    onError?.call(label, e);
    developer.log(
      'Failed to list $label for the compare dialog',
      error: e,
      name: 'SyncCompare',
    );
    return const <SyncAssetEntry>[];
  }
}

// ── 词典 ──────────────────────────────────────────────────────────────────────

Future<List<SyncAssetEntry>> _fetchDictionaries(
  HibikiDatabase db,
  SyncBackend backend,
) async {
  final Map<String, String> remote = <String, String>{};
  final Map<String, int?> remoteSizes = <String, int?>{};
  if (backend is HibikiClientSyncBackend) {
    for (final RemoteDictionaryInfo d
        in await backend.listRemoteDictionaries()) {
      remote[d.name] = d.name;
    }
  } else {
    final String ns = await backend.ensureNamespace(kSyncDictionaryNamespace);
    for (final AssetEntry e in await backend.listChildren(ns)) {
      if (e.isFolder || !e.name.endsWith(kDictionaryAssetSuffix)) continue;
      final String name =
          e.name.substring(0, e.name.length - kDictionaryAssetSuffix.length);
      remote[name] = e.id;
      remoteSizes[name] = e.sizeBytes;
    }
  }

  final Set<String> local = <String>{
    for (final DictionaryMetaRow d in await db.getAllDictionaryMetadata())
      d.name,
  };

  return _align(
    kind: SyncAssetKind.dictionary,
    identities: <String>{...local, ...remote.keys},
    nameOf: (String id) => id,
    localIdOf: (String id) => local.contains(id) ? id : null,
    remoteIdOf: (String id) => remote[id],
    remoteSizeOf: (String id) => remoteSizes[id],
  );
}

// ── 有声书 ────────────────────────────────────────────────────────────────────

Future<List<SyncAssetEntry>> _fetchAudiobooks(
  HibikiDatabase db,
  SyncBackend backend,
  Future<Map<String, String>>? cloudAudiobookIdsFuture,
) async {
  // 本端：EPUB 配对的有声书按 bookKey，纯 SRT（standalone）按 uid —— 与
  // [RemoteAudiobookInfo.identity] 同一身份规则，否则两端对不齐。
  final Map<String, String> localNames = <String, String>{};
  for (final AudiobookRow a in await db.getAllAudiobooks()) {
    if (a.bookKey.isEmpty) continue;
    localNames[a.bookKey] = a.bookKey;
  }
  for (final SrtBookRow s in await db.getAllSrtBooks()) {
    // srt-backed 的 uid 已由上面的 Audiobooks 行按 bookKey 覆盖；standalone
    // （无 Audiobooks 行）身份只能是 uid。
    final String byKey = s.bookKey;
    if (byKey.isNotEmpty && localNames.containsKey(byKey)) {
      localNames[byKey] = s.title;
      continue;
    }
    localNames[s.uid] = s.title;
  }

  final Map<String, String> remote = <String, String>{};
  final Map<String, String> remoteNames = <String, String>{};
  if (backend is HibikiClientSyncBackend) {
    for (final RemoteAudiobookInfo a in await backend.listRemoteAudiobooks()) {
      final String id = a.identity;
      if (id.isEmpty) continue;
      remote[id] = id;
      final String? title = a.title;
      if (title != null && title.isNotEmpty) remoteNames[id] = title;
    }
  } else {
    // 云后端：有声书包在各自书文件夹里，书籍扫描阶段已拿到 assetId（书名 -> id）。
    final Map<String, String> cloudAudiobookIds =
        await (cloudAudiobookIdsFuture ??
            Future<Map<String, String>>.value(const <String, String>{}));
    cloudAudiobookIds.forEach((String title, String assetId) {
      final String id = sanitizeTtuFilename(title);
      remote[id] = assetId;
      remoteNames[id] = title;
    });
  }

  return _align(
    kind: SyncAssetKind.audiobook,
    identities: <String>{...localNames.keys, ...remote.keys},
    nameOf: (String id) => remoteNames[id] ?? localNames[id] ?? id,
    localIdOf: (String id) => localNames.containsKey(id) ? id : null,
    remoteIdOf: (String id) => remote[id],
  );
}

// ── 音频数据库（本地音频来源） ────────────────────────────────────────────────

Future<List<SyncAssetEntry>> _fetchLocalAudio(
  SyncBackend backend,
  List<LocalAudioDbEntry> localAudioEntries,
) async {
  final Map<String, String> remote = <String, String>{};
  final Map<String, int?> remoteSizes = <String, int?>{};
  if (backend is HibikiClientSyncBackend) {
    for (final RemoteLocalAudioInfo a in await backend.listRemoteLocalAudio()) {
      if (a.displayName.isEmpty) continue;
      remote[a.displayName] = a.displayName;
    }
  } else {
    final String ns = await backend.ensureNamespace(kSyncLocalAudioNamespace);
    for (final AssetEntry e in await backend.listChildren(ns)) {
      if (e.isFolder || !e.name.endsWith(kLocalAudioAssetSuffix)) continue;
      final String name =
          e.name.substring(0, e.name.length - kLocalAudioAssetSuffix.length);
      remote[name] = e.id;
      remoteSizes[name] = e.sizeBytes;
    }
  }

  final Map<String, LocalAudioDbEntry> local = <String, LocalAudioDbEntry>{
    for (final LocalAudioDbEntry d in localAudioEntries)
      if (d.displayName.isNotEmpty) d.displayName: d,
  };

  return _align(
    kind: SyncAssetKind.localAudioDb,
    identities: <String>{...local.keys, ...remote.keys},
    nameOf: (String id) => id,
    localIdOf: (String id) {
      final String? path = local[id]?.path;
      return path != null && File(path).existsSync() ? path : null;
    },
    remoteIdOf: (String id) => remote[id],
    localSizeOf: (String id) {
      final String? path = local[id]?.path;
      if (path == null) return null;
      final File f = File(path);
      return f.existsSync() ? f.lengthSync() : null;
    },
    remoteSizeOf: (String id) => remoteSizes[id],
  );
}

// ── 视频 ──────────────────────────────────────────────────────────────────────

Future<List<SyncAssetEntry>> _fetchVideos(
  HibikiDatabase db,
  SyncBackend backend,
) async {
  final Map<String, String> remote = <String, String>{};
  final Map<String, String> remoteNames = <String, String>{};
  final Map<String, int?> remoteSizes = <String, int?>{};

  if (backend is HibikiClientSyncBackend) {
    for (final RemoteVideoInfo v in await backend.listRemoteVideos()) {
      if (v.id.isEmpty) continue;
      remote[v.id] = v.id;
      remoteNames[v.id] = v.title;
      remoteSizes[v.id] = v.sizeBytes;
    }
  } else {
    // 云后端的真相源是 `__videos__/videos.json` 清单，不是命名空间里的裸文件名：
    // 资产名经 videoAssetName 清洗过，反推不回 uid。复用占位卡同一个读清单客户端
    // （单一真相源），远端定位符就用 uid —— 下载也由该客户端按 uid 解析资产。
    for (final RemoteVideoManifestEntry v
        in await CloudRemoteVideoClient(backend: backend).listRemoteVideos()) {
      if (v.uid.isEmpty) continue;
      remote[v.uid] = v.uid;
      remoteNames[v.uid] = v.title;
      remoteSizes[v.uid] = v.sizeBytes;
    }
  }

  final Map<String, VideoBookRow> local = <String, VideoBookRow>{
    for (final VideoBookRow v in await db.allVideoBooks())
      // 与同步真正会传的集合用同一个谓词：否则会列出永远传不上去的行。
      if (isUploadableLocalVideo(v) && v.bookUid.isNotEmpty) v.bookUid: v,
  };

  return _align(
    kind: SyncAssetKind.video,
    identities: <String>{...local.keys, ...remote.keys},
    nameOf: (String id) => local[id]?.title ?? remoteNames[id] ?? id,
    localIdOf: (String id) {
      final String? path = local[id]?.videoPath;
      return path != null && File(path).existsSync() ? path : null;
    },
    remoteIdOf: (String id) => remote[id],
    localSizeOf: (String id) {
      final String? path = local[id]?.videoPath;
      if (path == null) return null;
      final File f = File(path);
      return f.existsSync() ? f.lengthSync() : null;
    },
    remoteSizeOf: (String id) => remoteSizes[id],
  );
}

// ── 对齐 ──────────────────────────────────────────────────────────────────────

/// 把「本端集合」与「远端集合」按身份键对齐成 [SyncAssetEntry] 列表，按显示名排序。
List<SyncAssetEntry> _align({
  required SyncAssetKind kind,
  required Set<String> identities,
  required String Function(String identity) nameOf,
  required String? Function(String identity) localIdOf,
  required String? Function(String identity) remoteIdOf,
  int? Function(String identity)? localSizeOf,
  int? Function(String identity)? remoteSizeOf,
}) {
  final List<SyncAssetEntry> out = <SyncAssetEntry>[];
  for (final String id in identities) {
    if (id.isEmpty) continue;
    final String? localId = localIdOf(id);
    final String? remoteId = remoteIdOf(id);
    if (localId == null && remoteId == null) continue;
    out.add(SyncAssetEntry(
      kind: kind,
      name: nameOf(id),
      identity: id,
      localId: localId,
      remoteId: remoteId,
      localSizeBytes: localId == null ? null : localSizeOf?.call(id),
      remoteSizeBytes: remoteId == null ? null : remoteSizeOf?.call(id),
    ));
  }
  out.sort((SyncAssetEntry a, SyncAssetEntry b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
