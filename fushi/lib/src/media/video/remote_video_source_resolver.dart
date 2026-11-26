import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/jellyfin_library_scope.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

/// 当前的远端视频来源（TODO-2119）：互联优先、次选 Jellyfin / Emby 媒体服务器、
/// 否则回退云盘。只解析来源、不取清单。
///
/// 这条链的顺序只写在这里：视频库页的取数 / 打开合集与「同一作品」卡片的远端海报
/// 都经它，不会出现「库页认 Jellyfin、别处认云盘」的分叉。
///
/// [interconnect] / [jellyfin] / [cloud] 是测试注入点（`HomeVideoPage` 的
/// widget 钩子原样转进来），缺省走生产解析。Jellyfin 的混排闸门
/// （`jellyfin_show_in_library`，B4）放在注入点**之前**：注入的 client 同样过闸，
/// 闸门测试测的才是真判据。
Future<RemoteVideoSource?> resolveRemoteVideoSource({
  required PreferencesRepository prefs,
  required FushiDatabase database,
  Future<RemoteVideoClient?> Function()? interconnect,
  Future<JellyfinVideoClient?> Function()? jellyfin,
  Future<CloudRemoteVideoClient?> Function()? cloud,
}) async {
  final RemoteVideoClient? live = interconnect != null
      ? await interconnect()
      : await resolveInterconnectVideoClient(database: database);
  if (live != null) return live;
  if (prefs.jellyfinShowInLibrary) {
    final JellyfinVideoClient? server = jellyfin != null
        ? await jellyfin()
        : await resolveJellyfinLibraryClient(
            prefs: prefs,
            syncRepo: SyncRepository(database),
          );
    if (server != null) return server;
  }
  return cloud != null
      ? await cloud()
      : await resolveCloudRemoteVideoClient(database: database);
}

/// 视频库可见的远端来源：「显示远端条目」（`show_remote_entries`）关着时 null。
///
/// 视频库页在取数与打开合集前用同一个开关挡住远端来源；库页以外要远端视频的地方
/// （「同一作品」卡片的远端海报）经这里，关掉远端条目的用户不会在别处又看到远端内容。
Future<RemoteVideoSource?> resolveVisibleRemoteVideoSource({
  required PreferencesRepository prefs,
  required FushiDatabase database,
}) async {
  if (!prefs.showRemoteEntries) return null;
  return resolveRemoteVideoSource(prefs: prefs, database: database);
}

/// 互联分支：互联开关开着且已配对（能恢复鉴权）时出它的 live 库，否则 null。
///
/// 互联已从 backendType 解耦成独立开关，可与云备份并存；关着时 null，链落到
/// Jellyfin / 云盘。
Future<RemoteVideoClient?> resolveInterconnectVideoClient({
  required FushiDatabase database,
}) async {
  final SyncRepository syncRepo = SyncRepository(database);
  if (!await syncRepo.isInterconnectEnabled()) return null;
  final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
  if (!await backend.restoreAuth(syncRepo)) return null;
  return backend;
}

/// 云盘分支（多端库联合视图 §2.2/§2.6）：把 `resolveSyncBackend` 的产物（含解混淆
/// 装饰层）包进 [CloudRemoteVideoClient]，读 `__videos__/videos.json` 目录清单。
/// 与书侧云分支同范式；互联后端（fushiServer）走 [resolveInterconnectVideoClient]，
/// 这里只对云盘后端出 client。云备份关掉 / 鉴权失败 / 无后端时 null。
Future<CloudRemoteVideoClient?> resolveCloudRemoteVideoClient({
  required FushiDatabase database,
}) async {
  final SyncRepository syncRepo = SyncRepository(database);
  // 云备份通道被用户关掉：不读云盘视频目录（与同步通道枚举同一判据）。
  if (!await syncRepo.isCloudSyncEnabled()) return null;
  final SyncBackendType type = await syncRepo.getBackendType();
  if (type == SyncBackendType.fushiServer) return null;
  final SyncBackend backend = resolveSyncBackend(type);
  if (!await backend.restoreAuth(syncRepo)) return null;
  return CloudRemoteVideoClient(backend: backend, backendType: type);
}
