import 'dart:async';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/foundation.dart' show debugPrint, mapEquals;
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo, resolvePositionLww, videoRemotePositionPrefKeys;

/// 远端视频断点的唯一判定：本机库断点与一份已知的 host 断点「取较新时间戳」
/// （[resolvePositionLww]）。开播位置（[resolveRemoteVideoResumeMs]）与库页卡片上的
/// 「看到 X」（[withLocalRemoteVideoPositions]）都走这里，两处不会各算各的
/// （BUG-4231 / BUG-4236）。
PlaybackPosition newestRemoteVideoPosition({
  required PlaybackPosition local,
  required PlaybackPosition host,
}) => resolvePositionLww(
  localPositionMs: local.positionMs,
  localUpdatedAtMs: local.updatedAtMs,
  remotePositionMs: host.positionMs,
  remoteUpdatedAtMs: host.updatedAtMs,
);

/// 清单条目带回的 host 断点属于哪一集：单视频 / 合集成员恒 0；host 播放列表是
/// host 的当前集（清单只带这一集的进度，见播放页 `_resolveRemoteInitialPositionMs`
/// 的 `hostProgressApplies`）。本机断点键按这一集取。
int remoteVideoListedEpisode(RemoteVideoInfo info) =>
    info.isPlaylist ? info.currentEpisode : 0;

/// 远端视频开播位置（TODO-653/885 → BUG-4231）：本机带戳断点、host 清单快照、
/// 互联 host 此刻的断点三者「取较新时间戳」（[newestRemoteVideoPosition]）。
///
/// - 本机断点从库里读（[readLocalRemoteVideoPosition]），与互联 sweep 同一口径。
///   此前播放页读 `PreferencesRepository` 的内存缓存：sweep 把 host 的新断点写进库，
///   缓存仍是本机上次自己看的旧断点，续播就从旧位置开始，随后的实时上报
///   （戳 = now）又把旧位置写回 host、盖掉 host 的新进度。
/// - [listed] 是清单条目带回的 host 断点（清单不适用于这一集时传 `0@0`）。清单
///   有缓存（`RemoteLibraryCache`）且页面常驻，可能是几分钟前的快照。
/// - 互联 host 是视频进度的真相端（sweep 的 `remotePosition` 读的就是它），开播
///   时再问一次 host 此刻的断点；host 不可达时退回前两者（离线照常能播）。
///
/// 只读，不写本机也不写 host。
Future<int> resolveRemoteVideoResumeMs({
  required FushiDatabase db,
  required RemoteVideoClient client,
  required String uid,
  required int episodeIndex,
  required PlaybackPosition listed,
}) async {
  final PlaybackPosition local = await readLocalRemoteVideoPosition(
    db,
    uid,
    episodeIndex: episodeIndex,
  );
  PlaybackPosition host = listed;
  if (client is InterconnectSyncBackend) {
    try {
      final PlaybackPosition live = await client.remoteVideoPosition(
        uid,
        episodeIndex: episodeIndex,
      );
      host = newestRemoteVideoPosition(local: listed, host: live);
    } catch (e) {
      debugPrint('[remoteVideoResume] host position read failed: $e');
    }
  }
  final PlaybackPosition winner = newestRemoteVideoPosition(
    local: local,
    host: host,
  );
  return winner.positionMs < 0 ? 0 : winner.positionMs;
}

/// 远端清单条目换成「本机库断点 vs 清单断点取较新」后的副本（BUG-4236），给库页
/// 卡片的「看到 X」/ 继续观看 / 进度条用。
///
/// 清单是 host 的快照，经 `RemoteLibraryCache`（TTL）缓存，页面又常驻：互联 sweep
/// 把 host 更新的断点落进本机库、或本机刚看完回来，清单里仍是旧值。开播位置早已
/// 认本机库断点（[resolveRemoteVideoResumeMs]），卡片却只认清单，两处显示与实际续播
/// 对不上。这里与开播判定用同一个 [newestRemoteVideoPosition]，本机断点一条前缀
/// 查询读齐。本机断点不新于清单的条目原样返回（同一对象）。
Future<List<RemoteVideoInfo>> withLocalRemoteVideoPositions(
  FushiDatabase db,
  List<RemoteVideoInfo> videos,
) async {
  if (videos.isEmpty) return videos;
  final Map<String, String> prefs = await db.getPrefsByPrefix(
    videoRemotePositionPrefKeys.positionPrefix,
  );
  if (prefs.isEmpty) return videos;
  return <RemoteVideoInfo>[
    for (final RemoteVideoInfo info in videos) _withLocalPosition(info, prefs),
  ];
}

RemoteVideoInfo _withLocalPosition(
  RemoteVideoInfo info,
  Map<String, String> prefs,
) {
  final PlaybackPosition local = localRemoteVideoPositionFromPrefs(
    prefs,
    info.id,
    episodeIndex: remoteVideoListedEpisode(info),
  );
  final PlaybackPosition listed = (
    positionMs: info.positionMs,
    updatedAtMs: info.positionUpdatedAtMs,
  );
  final PlaybackPosition winner = newestRemoteVideoPosition(
    local: local,
    host: listed,
  );
  if (winner == listed) return info;
  return info.withPosition(
    positionMs: winner.positionMs,
    positionUpdatedAtMs: winner.updatedAtMs,
  );
}

/// 本机远端视频断点（`video_remote_position_*` 键族）变了就 emit（不带数据）。
///
/// 这组键的写者互不相识：播放页（经偏好仓库）、互联 sweep 与冲突弹窗（直接写库）、
/// 本机作为互联 host 收到的对端 PUT（引擎层写库）。展示远端条目断点的页面靠这条
/// 数据层信号重读（[withLocalRemoteVideoPositions]），不靠每个写者各自记得通知
/// （BUG-4236）。
///
/// 订阅偏好表的表级更新，比较这组键的快照，变了才发；别的偏好写入不发。首次查询
/// 只登记基线。查询在途时到达的通知合并成一次重查（播放中每秒落一次断点，不排长队）。
/// 用 [FushiDatabase.tableUpdates] + 手动 [StreamController]，不用 drift keyed
/// `.watch()`（BUG-834）。
Stream<void> watchLocalRemoteVideoPositionsChanged(FushiDatabase db) {
  late final StreamController<void> controller;
  StreamSubscription<void>? updatesSub;
  Map<String, String>? last;
  bool running = false;
  bool rerun = false;

  Future<void> check() async {
    if (running) {
      rerun = true;
      return;
    }
    running = true;
    try {
      do {
        rerun = false;
        final Map<String, String> snapshot = await db.getPrefsByPrefix(
          videoRemotePositionPrefKeys.positionPrefix,
        );
        if (controller.isClosed) return;
        final Map<String, String>? previous = last;
        last = snapshot;
        if (previous != null && !mapEquals(previous, snapshot)) {
          controller.add(null);
        }
      } while (rerun && !controller.isClosed);
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
    } finally {
      running = false;
    }
  }

  controller = StreamController<void>(
    onListen: () {
      unawaited(check());
      updatesSub = db
          .tableUpdates(TableUpdateQuery.onTable(db.preferences))
          .listen((_) => unawaited(check()));
    },
    onCancel: () async {
      await updatesSub?.cancel();
    },
  );
  return controller.stream;
}
