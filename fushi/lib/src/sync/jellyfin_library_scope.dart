import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// Jellyfin / Emby 条目进媒体库的**唯一**判据（视频页与首页仪表盘共用）：
///
/// - 「显示在视频库」开着：整库枚举（按设置里选的媒体库）。
/// - 关着：只列用户在媒体服务器详情页手动「加入媒体库」的剧 / 电影，各集的
///   [RemoteVideoInfo.importedAt] = 加入时刻（首页「最近添加」靠它）。
/// - 两者都没有 / 没登录服务器：null，不连服务器。
Future<JellyfinVideoClient?> resolveJellyfinLibraryClient({
  required PreferencesRepository prefs,
  required SyncRepository syncRepo,
}) async {
  final JellyfinServerConfig? config = await syncRepo.getJellyfinServer();
  if (config == null) return null;
  final bool showAll = prefs.jellyfinShowInLibrary;
  final Map<String, int> added = prefs.jellyfinLibraryItems(config.sourceId);
  if (!showAll && added.isEmpty) return null;
  return config.buildClient(
    libraryItemIds: showAll ? null : added.keys.toList(),
    libraryItemAddedAtMs: added,
  );
}

/// 是否该真的向服务器要清单（而不是只复用缓存）。整库枚举受「自动列出条目」
/// 开关管（BUG-1891）；只列加入项的清单很小，不受它管；手动刷新永远照拉。
bool shouldFetchJellyfinList({
  required JellyfinVideoClient client,
  required bool forceRefresh,
  required bool autoList,
}) => forceRefresh || client.libraryItemIds != null || autoList;

/// 媒体库范围的变更签名：开关或加入项一变，签名就变（页面据此重取清单）。
String jellyfinLibraryScopeSignature(PreferencesRepository prefs) =>
    '${prefs.jellyfinShowInLibrary}|${prefs.jellyfinAutoListVideos}|'
    '${prefs.getPref('jellyfin_library_items', defaultValue: '')}';
