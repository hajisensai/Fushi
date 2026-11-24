/// 在线视频源（Aniyomi 扩展）的一集按重开规格起播：找到扩展源、建
/// [AnimeSourceVideoClient]。
///
/// 从 `anime_source_library.dart`（入库 / 下载服务，在 AppModel 大 import 环里）拆出：
/// 收藏跳回的解析器（`favorite_video_origin.dart`）只要这一段，不该为此进环
/// （`import_cycle_guard_test.dart`）。`anime_source_library.dart` 原样 export 本文件。
library;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/online/anime_source_book_spec.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';

/// 没入库的在线集按重开规格 [spec] 起播（收藏时记下的 `FavoriteSentence.originLocator`，
/// 收藏夹 / 手机遥控跳回源条目用）：只有这一集，不联网拉剧集列表；[bookUid] 是收藏
/// 时的集 id（播放页的 `bookUid`，断点 / 字幕记忆都按它）。扩展被卸载 / 停用时抛
/// [AnimeSourceLaunchUnavailable]。
Future<({AnimeSourceVideoClient client, RemoteVideoInfo info})>
buildAnimeSourceEpisodeLaunch({
  required AnimeSourceBookSpec spec,
  required String bookUid,
  required MihonManager manager,
  String? Function()? subtitleLanguageResolver,
}) async {
  final ({
    AnimeSourceVideoClient client,
    RemoteVideoInfo info,
    List<RemoteVideoInfo> members,
    int startIndex,
  })
  launch = await launchAnimeSourceMembers(
    spec: spec,
    members: <({String bookUid, MihonEpisode episode})>[
      (bookUid: bookUid, episode: spec.episode),
    ],
    startBookUid: bookUid,
    manager: manager,
    subtitleLanguageResolver: subtitleLanguageResolver,
  );
  return (client: launch.client, info: launch.info);
}

/// `buildAnimeSourceLaunch`（入库行重开）/ [buildAnimeSourceEpisodeLaunch] 的共同本体：找到 [spec]
/// 的扩展源、按 [members]（各集沿用自己的 bookUid）建客户端，起播 [startBookUid]。
Future<
  ({
    AnimeSourceVideoClient client,
    RemoteVideoInfo info,
    List<RemoteVideoInfo> members,
    int startIndex,
  })
>
launchAnimeSourceMembers({
  required AnimeSourceBookSpec spec,
  required List<({String bookUid, MihonEpisode episode})> members,
  required String startBookUid,
  required MihonManager manager,
  String? Function()? subtitleLanguageResolver,
}) async {
  // 起播只要本地已装的扩展与源行：只读库（reload），不走 initialise()——那条会
  // 联网刷新仓库索引（慢网 / 仓库站点不通时一挂就是几十秒），扩展装没装跟它无关。
  // 真实 app 里 manager 首次取用时已在后台跑 initialise，这里不等它。
  await manager.reload();
  MangaOnlineSourceRow? sourceRow;
  for (final MangaOnlineSourceRow candidate in manager.sources) {
    if (candidate.extensionPackage == spec.extensionPackage &&
        candidate.sourceId == spec.sourceId &&
        candidate.enabled) {
      sourceRow = candidate;
      break;
    }
  }
  if (sourceRow == null) {
    throw AnimeSourceLaunchUnavailable(
      'extension ${spec.extensionPackage} / source ${spec.sourceId} '
      'is not installed or enabled',
    );
  }
  final MihonSourceContext context;
  try {
    context = await manager.contextForSource(sourceRow);
  } on Object catch (error) {
    throw AnimeSourceLaunchUnavailable('$error');
  }
  final AnimeSourceVideoClient client = AnimeSourceVideoClient(
    manager: manager,
    context: context,
    anime: spec.anime,
    episodes: <MihonEpisode>[
      for (final ({String bookUid, MihonEpisode episode}) m in members)
        m.episode,
    ],
    episodeIds: <String>[
      for (final ({String bookUid, MihonEpisode episode}) m in members)
        m.bookUid,
    ],
    subtitleLanguageResolver: subtitleLanguageResolver,
  );
  final List<RemoteVideoInfo> infos = client.remoteVideos;
  final int startIndex = infos.indexWhere(
    (RemoteVideoInfo info) => info.id == startBookUid,
  );
  return (
    client: client,
    info: infos[startIndex < 0 ? 0 : startIndex],
    members: infos,
    startIndex: startIndex < 0 ? 0 : startIndex,
  );
}

/// 在线行重开不了：扩展被卸载 / 停用，或行上的规格坏了。
class AnimeSourceLaunchUnavailable implements Exception {
  const AnimeSourceLaunchUnavailable(this.message);

  final String message;

  @override
  String toString() => 'AnimeSourceLaunchUnavailable: $message';
}
