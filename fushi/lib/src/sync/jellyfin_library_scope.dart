import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// Jellyfin / Emby 条目**混排**进视频库 / 首页的唯一判据（两页共用）：
///
/// - 「显示在视频库」开着：整库枚举（按设置里选的媒体库）。
/// - 关着 / 没登录服务器：null，不连服务器。
///
/// 用户在媒体服务器详情页手动「加入媒体库」的剧 / 电影**不走这里**：入库即落本地
/// `VideoBooks` 行（`bookUid` = 服务器条目 id，见 `MediaServerVideoLibrary`），
/// 「在不在库」只认那些行——这里不再另存一份「加入项」清单。
Future<JellyfinVideoClient?> resolveJellyfinLibraryClient({
  required PreferencesRepository prefs,
  required SyncRepository syncRepo,
}) async {
  if (!prefs.jellyfinShowInLibrary) return null;
  final JellyfinServerConfig? config = await syncRepo.getJellyfinServer();
  return config?.buildClient();
}

/// 是否该真的向服务器要整库清单（而不是只复用缓存）：受「自动列出条目」开关管
/// （BUG-1891）；手动刷新永远照拉。
bool shouldFetchJellyfinList({
  required bool forceRefresh,
  required bool autoList,
}) => forceRefresh || autoList;

/// 混排范围的变更签名：开关一变，签名就变（页面据此作废旧清单并重取）。
String jellyfinLibraryScopeSignature(PreferencesRepository prefs) =>
    '${prefs.jellyfinShowInLibrary}|${prefs.jellyfinAutoListVideos}';
