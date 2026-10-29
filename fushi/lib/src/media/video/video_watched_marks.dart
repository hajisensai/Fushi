import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart'
    show MediaServerBookSpec, MediaServerLaunchUnavailable;
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/bounded_concurrency.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

/// 一次「标记已看 / 未看」的结果。
class WatchedMarkResult {
  const WatchedMarkResult({
    this.localChanged = 0,
    this.remoteChanged = 0,
    this.remoteFailed = 0,
    this.remoteFailedWithLocalRow = 0,
  });

  /// 本地行看完标记实际改动的条数（已是目标状态的不计）。
  final int localChanged;

  /// 媒体服务器上标记成功的条数。
  final int remoteChanged;

  /// 媒体服务器上标记失败的条数（离线 / 令牌失效 / 条目已删 / 服务器已登出）。
  final int remoteFailed;

  /// [remoteFailed] 里**有本地行**的条数——这些条目本机状态已经改好，只是没写到
  /// 服务器；其余是纯远端条目，本机没有任何东西被更新。
  final int remoteFailedWithLocalRow;

  bool get hasFailures => remoteFailed > 0;
  int get total => localChanged + remoteChanged;

  /// 失败的条目是否全都有本地行（提示可以说「本地状态已更新」）。
  bool get failuresKeptLocally =>
      remoteFailed > 0 && remoteFailedWithLocalRow == remoteFailed;
}

/// 按服务器身份（[MediaServerBookSpec.serverId] = [MediaServerConfig.sourceId]）
/// 取「已播放」回写能力。返回 null = 该类服务器没有这个协议（Plex 等，不回写、
/// 不算失败）；抛错 = 服务器不在登录列表里（登出 / 换账号），计入失败。
typedef MediaServerPlayedMarkResolver =
    Future<RemoteVideoPlayedMark?> Function(String serverId);

/// 由设置里的服务器列表建 [MediaServerPlayedMarkResolver]（与从媒体库重开同一
/// 份配置来源，经 `MediaServerConfig.buildBrowser` 的契约，不认具体服务器类型）。
MediaServerPlayedMarkResolver mediaServerPlayedMarkResolver(
  Future<List<MediaServerConfig>> Function() loadConfigs,
) {
  Future<List<MediaServerConfig>>? configs;
  final Map<String, RemoteVideoPlayedMark?> built =
      <String, RemoteVideoPlayedMark?>{};
  return (String serverId) async {
    if (built.containsKey(serverId)) return built[serverId];
    for (final MediaServerConfig config in await (configs ??= loadConfigs())) {
      if (config.sourceId != serverId) continue;
      final Object client = config.buildBrowser().playbackClient;
      return built[serverId] = client is RemoteVideoPlayedMark ? client : null;
    }
    throw const MediaServerLaunchUnavailable('media server is not signed in');
  };
}

/// 服务器回写的并发上限：批量标一整季也不至于串行几十个往返，又不把服务器打爆。
const int kWatchedMarkServerConcurrency = 4;

/// 手动标记视频已看 / 未看的**唯一**入口（视频库卡菜单、合集详情页单集 / 多选、
/// 媒体服务器详情页、CLI / AI 操作共用）。
///
/// - 本地行：[VideoBookRepository.setWatched]——completedAt + 断点归零与互联 LWW
///   镜像同一事务盖戳，一次同步不会把旧断点 / 旧看完状态灌回来。
/// - 本地行里的媒体服务器入库条目（`streamSpecJson` 是 [MediaServerBookSpec]）：
///   同时把「已播放」回写到那台服务器（[mediaServerMarker] 按服务器身份取能力；
///   缺省用设置里的服务器列表），两边不各留一份真相。
/// - 纯远端条目（[remoteIds]，没有本地行）：经 [remoteMarker]（当前远端来源的
///   「已播放」协议）标记；没有能力的来源全部计失败。与本地行同一条目的 id 不重发。
///
/// 服务器侧单条失败不挡其余，计入 [WatchedMarkResult.remoteFailed]；回写有界并发
/// （[kWatchedMarkServerConcurrency]）。
Future<WatchedMarkResult> setVideosWatched({
  required FushiDatabase db,
  required bool watched,
  List<String> localUids = const <String>[],
  List<String> remoteIds = const <String>[],
  RemoteVideoPlayedMark? remoteMarker,
  MediaServerPlayedMarkResolver? mediaServerMarker,
  DateTime? now,
}) async {
  final ({int changed, List<VideoBookRow> rows}) local =
      await VideoBookRepository(
        db,
      ).setWatched(localUids, watched: watched, now: now);

  final List<_ServerMark> marks = <_ServerMark>[
    for (final VideoBookRow row in local.rows)
      if (MediaServerBookSpec.tryParse(row.streamSpecJson)
          case final MediaServerBookSpec spec)
        _ServerMark(itemId: spec.itemId, serverId: spec.serverId, local: true),
  ];
  final Set<String> covered = <String>{
    for (final _ServerMark m in marks) m.itemId,
  };
  for (final String id in remoteIds) {
    if (!covered.add(id)) continue;
    marks.add(_ServerMark(itemId: id, marker: remoteMarker, local: false));
  }
  return _writeBackServerPlayed(
    db: db,
    marks: marks,
    played: watched,
    localChanged: local.changed,
    mediaServerMarker: mediaServerMarker,
  );
}

/// 把 [rows] 里媒体服务器入库条目的「已播放」写成 [played]（撤销恢复本地看完
/// 标记后，让服务器跟着回到原状态用）。其它行忽略。
Future<WatchedMarkResult> writeBackMediaServerPlayed({
  required FushiDatabase db,
  required List<VideoBookRow> rows,
  required bool played,
  MediaServerPlayedMarkResolver? mediaServerMarker,
}) => _writeBackServerPlayed(
  db: db,
  marks: <_ServerMark>[
    for (final VideoBookRow row in rows)
      if (MediaServerBookSpec.tryParse(row.streamSpecJson)
          case final MediaServerBookSpec spec)
        _ServerMark(itemId: spec.itemId, serverId: spec.serverId, local: true),
  ],
  played: played,
  localChanged: 0,
  mediaServerMarker: mediaServerMarker,
);

Future<WatchedMarkResult> _writeBackServerPlayed({
  required FushiDatabase db,
  required List<_ServerMark> marks,
  required bool played,
  required int localChanged,
  MediaServerPlayedMarkResolver? mediaServerMarker,
}) async {
  if (marks.isEmpty) return WatchedMarkResult(localChanged: localChanged);
  final MediaServerPlayedMarkResolver resolve =
      mediaServerMarker ??
      mediaServerPlayedMarkResolver(SyncRepository(db).getMediaServers);
  int ok = 0;
  int failed = 0;
  int failedWithLocal = 0;
  await runBoundedTasks<_ServerMark>(
    marks,
    maxConcurrent: kWatchedMarkServerConcurrency,
    task: (_ServerMark mark) async {
      try {
        final String? serverId = mark.serverId;
        final RemoteVideoPlayedMark? marker = serverId == null
            ? mark.marker
            : await resolve(serverId);
        if (marker == null) {
          // 本地入库条目所在服务器没有「已播放」协议：本地标记就是全部真相。
          if (serverId != null) return;
          throw StateError('source has no played-mark capability');
        }
        await marker.setRemoteVideoPlayed(mark.itemId, played: played);
        ok++;
      } on Object catch (e) {
        debugPrint('[watched-mark] server ${mark.itemId} failed: $e');
        failed++;
        if (mark.local) failedWithLocal++;
      }
    },
  );
  return WatchedMarkResult(
    localChanged: localChanged,
    remoteChanged: ok,
    remoteFailed: failed,
    remoteFailedWithLocalRow: failedWithLocal,
  );
}

class _ServerMark {
  const _ServerMark({
    required this.itemId,
    required this.local,
    this.serverId,
    this.marker,
  });

  final String itemId;

  /// 本地入库行所属服务器（按它解析能力）；纯远端条目为 null，用 [marker]。
  final String? serverId;
  final RemoteVideoPlayedMark? marker;

  /// 是否有本地行（失败提示区分「本地已更新」与「什么都没改」）。
  final bool local;
}

/// 一次标记之后给用户的提示文案：服务器侧有失败时，只有失败条目**全都有本地行**
/// 才说「本地状态已更新」；纯远端条目失败就是什么都没改成。
String watchedMarkFeedback(WatchedMarkResult result, {required bool watched}) {
  if (!result.hasFailures) {
    return watched ? t.video_marked_watched : t.video_marked_unwatched;
  }
  return result.failuresKeptLocally
      ? t.video_mark_server_failed(n: result.remoteFailed)
      : t.video_mark_remote_failed(n: result.remoteFailed);
}

/// 「这一集及之前」：在**显示顺序**里取到 [index]（含）为止的全部条目。越界 / 负数
/// 返回空。纯函数，便于单测。
List<T> itemsThrough<T>(List<T> ordered, int index) {
  if (index < 0 || index >= ordered.length) return <T>[];
  return ordered.sublist(0, index + 1);
}
