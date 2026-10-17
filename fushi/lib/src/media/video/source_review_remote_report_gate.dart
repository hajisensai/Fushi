import 'package:fushi/src/sync/remote_video_client.dart';

/// 卡片片段回看期间的远端播放上报闸门（BUG-3490）。
///
/// 回看直接串流远端视频（互联 host / Jellyfin / Emby / Plex），「不影响观看进度」
/// 靠的不是先下载，而是回看期间一条会改服务器状态的上报都不发：
///
/// - 互联 host：`/streamurl` 与 `/stream` 只签发 token、读文件，不碰进度；进度只经
///   [RemoteVideoClient.putRemoteVideoPosition]（及同一端点的实时接力）写入。
/// - Jellyfin / Emby：`POST /Items/{id}/PlaybackInfo` 与 `/Videos/{id}/stream` 不改
///   UserData；断点、`Played`、`PlayCount`、`LastPlayedDate` 只由
///   `/Sessions/Playing`（[RemoteVideoPlaybackSession.startRemoteVideoPlayback]）、
///   `/Sessions/Playing/Progress`（[RemoteVideoClient.putRemoteVideoPosition] /
///   [RemoteVideoPlaybackSession.setRemoteVideoPlaybackPaused]）与
///   `/Sessions/Playing/Stopped`（[RemoteVideoPlaybackStop.stopRemoteVideoPlayback]，
///   过阈值即标已看）这三段会话上报写入。
/// - Plex：直出 part URL 不 scrobble；`viewOffset` 与已看只由 `/:/timeline` 与
///   `/:/scrobble`（同样挂在上面四个方法后面）写入。
///
/// 所以闸门只需在这四个方法前判一次「是否回看中」：回看中一律不发，返回 false。
/// 「从这里继续观看」之后 [isReview] 变 false，播放页先补发一次起播上报，此后与平常
/// 观看完全一致。
class SourceReviewRemoteReportGate {
  /// [isReview] 每次上报前现读：回看态随「从这里继续观看」翻转，不能在构造时快照。
  SourceReviewRemoteReportGate({required bool Function() isReview})
    : _isReview = isReview;

  final bool Function() _isReview;

  /// 当前是否压住所有远端上报。
  bool get suppressed => _isReview();

  /// 起播上报（Jellyfin / Emby `/Sessions/Playing`、Plex timeline `playing`）。
  /// 回看中或来源没有会话协议时不发，返回 false。
  Future<bool> start(Object? client, String id, int positionMs) async {
    if (_isReview() || client is! RemoteVideoPlaybackSession) return false;
    await client.startRemoteVideoPlayback(id, _clamp(positionMs));
    return true;
  }

  /// 暂停 / 继续即时上报。
  Future<bool> paused(
    Object? client,
    String id,
    int positionMs, {
    required bool paused,
  }) async {
    if (_isReview() || client is! RemoteVideoPlaybackSession) return false;
    await client.setRemoteVideoPlaybackPaused(
      id,
      _clamp(positionMs),
      paused: paused,
    );
    return true;
  }

  /// 周期断点上报。
  Future<bool> position(
    RemoteVideoClient client,
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {
    if (_isReview()) return false;
    await client.putRemoteVideoPosition(
      id,
      _clamp(positionMs),
      updatedAtMs,
      episodeIndex: episodeIndex,
    );
    return true;
  }

  /// 停止上报（Jellyfin / Emby 过阈值即标已看、Plex 过 90% 另发 scrobble）。
  Future<bool> stop(Object? client, String id, int positionMs) async {
    if (_isReview() || client is! RemoteVideoPlaybackStop) return false;
    await client.stopRemoteVideoPlayback(id, _clamp(positionMs));
    return true;
  }

  static int _clamp(int positionMs) => positionMs < 0 ? 0 : positionMs;
}

/// 卡片片段回看中暂存的「保存用户播放选择」动作（BUG-3490）。
///
/// 回看中切换音轨 / 字幕 / 调轴只在本次生效；对应的保存动作按种类 [K] 暂存（同种
/// 只留最后一次，key 与值由调用方在切换当时捕获进闭包），点「从这里继续观看」时
/// [flush] 按正常逻辑补存。回看中退出则不 flush、整批丢弃。
class SourceReviewDeferredWrites<K> {
  /// [isReview] 每次保存前现读（与 [SourceReviewRemoteReportGate] 同一判据）。
  SourceReviewDeferredWrites({required bool Function() isReview})
    : _isReview = isReview;

  final bool Function() _isReview;
  final Map<K, Future<void> Function()> _pending =
      <K, Future<void> Function()>{};

  /// 暂存中的种类（按首次暂存先后）。
  Iterable<K> get pendingKinds => _pending.keys;

  /// 保存一次选择：回看中暂存（覆盖同种旧值），否则立即写。
  Future<void> save(K kind, Future<void> Function() write) async {
    if (_isReview()) {
      _pending[kind] = write;
      return;
    }
    await write();
  }

  /// 作废某一种暂存（例如它指向的字幕文件已被删除）。
  void discard(K kind) => _pending.remove(kind);

  /// 补存全部暂存；单条失败交给 [onError]，不影响其余各条。
  Future<void> flush({void Function(Object error)? onError}) async {
    final List<Future<void> Function()> writes = _pending.values.toList();
    _pending.clear();
    for (final Future<void> Function() write in writes) {
      try {
        await write();
      } catch (e) {
        onError?.call(e);
      }
    }
  }
}
