import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';

/// 一次「标记已看 / 未看」的结果。
class WatchedMarkResult {
  const WatchedMarkResult({
    this.localChanged = 0,
    this.remoteChanged = 0,
    this.remoteFailed = 0,
  });

  /// 本地行实际改动的条数（已是目标状态的不计）。
  final int localChanged;

  /// 媒体服务器上标记成功的条数。
  final int remoteChanged;

  /// 媒体服务器上标记失败的条数（离线 / 令牌失效 / 条目已删）。
  final int remoteFailed;

  bool get hasFailures => remoteFailed > 0;
  int get total => localChanged + remoteChanged;
}

/// 手动标记视频已看 / 未看的**唯一**入口（视频库卡菜单、系列页集菜单、多选批量、
/// 媒体服务器详情页、CLI 共用）。
///
/// - 本地行：[FushiDatabase.setVideosCompleted]，一个事务。只动 `completedAt`，
///   观看位置不变（完整重置走「清除观看进度」）。
/// - 媒体服务器条目：[remoteMarker]（Jellyfin / Emby 的 PlayedItems 端点）逐条
///   发；单条失败不挡其余，计入 [WatchedMarkResult.remoteFailed] 让调用方提示。
///   互联 / 云盘来源没有这个协议，调用方不会传 [remoteIds]。
Future<WatchedMarkResult> setVideosWatched({
  required FushiDatabase db,
  required bool watched,
  List<String> localUids = const <String>[],
  List<String> remoteIds = const <String>[],
  RemoteVideoPlayedMark? remoteMarker,
  DateTime? now,
}) async {
  final int local = await db.setVideosCompleted(
    localUids,
    watched ? (now ?? DateTime.now()) : null,
  );
  int ok = 0;
  int failed = 0;
  final RemoteVideoPlayedMark? marker = remoteMarker;
  for (final String id in remoteIds) {
    if (marker == null) {
      failed++;
      continue;
    }
    try {
      await marker.setRemoteVideoPlayed(id, played: watched);
      ok++;
    } catch (e) {
      debugPrint('[watched-mark] remote $id failed: $e');
      failed++;
    }
  }
  return WatchedMarkResult(
    localChanged: local,
    remoteChanged: ok,
    remoteFailed: failed,
  );
}

/// 「这一集及之前」：在**显示顺序**里取到 [index]（含）为止的全部条目。越界 / 负数
/// 返回空。纯函数，便于单测。
List<T> itemsThrough<T>(List<T> ordered, int index) {
  if (index < 0 || index >= ordered.length) return <T>[];
  return ordered.sublist(0, index + 1);
}
