import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 一条播放位置：毫秒位置 + 最后更新时刻（epoch 毫秒，0 = 无记录 / 旧数据）。
typedef PlaybackPosition = ({int positionMs, int updatedAtMs});

/// 互联播放位置的两类条目（BUG-3367）。
enum PlaybackPositionKind { video, audiobook }

/// 互联视频播放位置基线在 `sync_baselines` 里的 dimension（BUG-3367）。值 = 上次
/// 两端达成一致的位置（毫秒）；assetKey = 视频 uid。与书籍的 `progress_live`
/// 同表不同维度。
const String kInterconnectVideoPositionDimension = 'video_position_live';

/// 互联有声书播放位置基线的 dimension（BUG-3367）。assetKey = 有声书 identity
/// （srt-backed = bookKey；纯 SRT = uid，见 [RemoteAudiobookInfo.identity]）。
const String kInterconnectAudiobookPositionDimension =
    'audiobook_position_live';

/// [dimension] 对应的播放位置种类；不是播放位置维度返回 null。
PlaybackPositionKind? playbackPositionKindOfDimension(String dimension) =>
    switch (dimension) {
      kInterconnectVideoPositionDimension => PlaybackPositionKind.video,
      kInterconnectAudiobookPositionDimension => PlaybackPositionKind.audiobook,
      _ => null,
    };

/// 互联播放位置（视频 / 有声书）的三方同步落地层（BUG-3367）：sweep
/// （`SyncOrchestrator`）与冲突弹窗（`PlaybackPositionConflictDialog`）共用同一份
/// 读 / 写 / 记基线，两处口径不会漂移。判定本身是纯函数
/// [resolvePlaybackPositionThreeWay]，这里只做 IO。形态照
/// `InterconnectBookProgressSync`（书籍进度，BUG-2506）。
///
/// 时间戳纪律：host 端 PUT 仍是防御性的「严格较新时间戳者胜」，所以 [pushLocal]
/// 在本端时间戳不新于 host 时把它抬到 `host + 1`，并只把这个戳写回本端的时间戳
/// pref——**不**写 `VideoBooks.lastPlayedAt`：那一列是「这一集是什么时候看的」，
/// 抬戳不是一次观看，写进去会污染合集续播锚点（BUG-1542）。
class InterconnectPlaybackPositionSync {
  const InterconnectPlaybackPositionSync({
    required FushiDatabase db,
    required InterconnectSyncBackend backend,
    required this.kind,
  }) : _db = db,
       _backend = backend;

  final FushiDatabase _db;
  final InterconnectSyncBackend _backend;
  final PlaybackPositionKind kind;

  /// 本种类基线在 `sync_baselines` 里的 dimension。
  String get dimension => switch (kind) {
    PlaybackPositionKind.video => kInterconnectVideoPositionDimension,
    PlaybackPositionKind.audiobook => kInterconnectAudiobookPositionDimension,
  };

  /// 本端位置。视频：书架视频的位置在 `VideoBooks.lastPositionMs`，流式视频的位置
  /// 在 `video_remote_position_<uid>` pref，时间戳统一取 `_at_` pref（与此前 sweep
  /// 的读法一致）；有声书：`audiobook_pos_<identity>` + `_at_` pref。
  Future<PlaybackPosition> localPosition(String key) async {
    switch (kind) {
      case PlaybackPositionKind.video:
        final VideoBookRow? row = await _db.getVideoBookByBookUid(key);
        final int prefsPos = await _db.getPrefTyped<int>(
          videoRemotePositionPrefKey(key),
          0,
        );
        final int at = await _db.getPrefTyped<int>(
          videoRemotePositionAtPrefKey(key),
          0,
        );
        return (positionMs: row?.lastPositionMs ?? prefsPos, updatedAtMs: at);
      case PlaybackPositionKind.audiobook:
        return (
          positionMs: await _db.getPrefTyped<int>(
            audiobookPositionPrefKey(key),
            0,
          ),
          updatedAtMs: await _db.getPrefTyped<int>(
            audiobookPositionAtPrefKey(key),
            0,
          ),
        );
    }
  }

  /// host 端位置（host 无记录 → 0@0）。
  Future<PlaybackPosition> remotePosition(String key) => switch (kind) {
    PlaybackPositionKind.video => _backend.remoteVideoPosition(key),
    PlaybackPositionKind.audiobook => _backend.remoteAudiobookPosition(key),
  };

  /// 上次两端达成一致的位置（毫秒）；没有基线返回 null。
  Future<int?> baseline(String key) => _db.getSyncBaseline(key, dimension);

  /// 记下两端此刻达成一致的位置。
  Future<void> recordBaseline(String key, int positionMs) =>
      _db.setSyncBaseline(key, dimension, positionMs < 0 ? 0 : positionMs);

  /// 本端胜出：推给 host（时间戳不新于 host 时抬到 host + 1，见类头），本端只对齐
  /// 时间戳 pref，记基线。返回两端对齐后的位置。
  ///
  /// 抬戳纪律与书籍版 `InterconnectBookProgressSync.pushLocal` 一致：抬出来的戳
  /// 至少是 [nowMs]；host 已存的超限毒戳（[trustedStoredSyncStamp]）按 0 比较，
  /// 结果再截到 [capFutureSyncStamp]——否则 `毒戳 + 1` 会写进本端 `_at_` pref，
  /// host 却把上报戳截成 `now + 余量`，下一轮两端位置相同、本端戳更新 →
  /// [alignSynced] 又 PUT 一次，每轮重复写。
  Future<PlaybackPosition> pushLocal(
    String key, {
    required PlaybackPosition local,
    required PlaybackPosition remote,
    int? nowMs,
  }) async {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final int remoteTs = trustedStoredSyncStamp(remote.updatedAtMs, nowMs: now);
    int ts = local.updatedAtMs;
    if (ts <= remoteTs) {
      ts = remoteTs + 1;
      if (now > ts) ts = now;
    }
    ts = capFutureSyncStamp(ts, nowMs: now);
    final PlaybackPosition agreed = (
      positionMs: local.positionMs,
      updatedAtMs: ts,
    );
    await _putRemote(key, agreed);
    if (ts != local.updatedAtMs) {
      await _db.setPrefTyped<int>(_localAtPrefKey(key), ts);
    }
    await recordBaseline(key, agreed.positionMs);
    return agreed;
  }

  /// 播放页实时上报（节流回调）：本端位置 [live] 已由播放页写进本地 pref，这里推给
  /// host 并把基线推进到上报位置。
  ///
  /// 与 sweep 共用这一入口而不是播放页裸调 `putRemoteVideoPosition`：实时上报本身
  /// 就是「两端在这个位置达成一致」，不推进基线的话，A 串流到 600（host=600、基线
  /// 仍停在旧的 100）→ B 从 600 接着看到 900 → A 下轮 sweep 见 local=600 ≠ 基线、
  /// remote=900 ≠ 基线，会把顺序接力误判成两端分叉而弹冲突（BUG-3367）。
  ///
  /// host 端 PUT 仍是 LWW：若 host 已存更新的戳而拒收，基线停在本端位置，下一轮
  /// sweep 判「只 host 动了」→ [applyRemote]，与 host 的 LWW 结论一致。
  Future<void> reportLive(String key, PlaybackPosition live) async {
    await _putRemote(key, live);
    await recordBaseline(key, live.positionMs);
  }

  /// host 胜出：落回本端，记基线。
  Future<void> applyRemote(String key, PlaybackPosition remote) async {
    await _writeLocal(key, remote);
    await recordBaseline(key, remote.positionMs);
  }

  /// 两端位置一致、只是时间戳不同：把较新的时间戳对齐到另一端（沿用此前 LWW 路径
  /// 的对齐写法），记基线。返回本端是否被改写。
  Future<bool> alignSynced(
    String key, {
    required PlaybackPosition local,
    required PlaybackPosition remote,
  }) async {
    bool localChanged = false;
    if (local.updatedAtMs > remote.updatedAtMs) {
      await _putRemote(key, local);
    } else if (remote.updatedAtMs > local.updatedAtMs) {
      await _writeLocal(key, remote);
      localChanged = true;
    }
    await recordBaseline(key, local.positionMs);
    return localChanged;
  }

  Future<void> _putRemote(String key, PlaybackPosition p) => switch (kind) {
    PlaybackPositionKind.video => _backend.putRemoteVideoPosition(
      key,
      p.positionMs,
      p.updatedAtMs,
    ),
    PlaybackPositionKind.audiobook => _backend.putRemoteAudiobookPosition(
      key,
      p.positionMs,
      p.updatedAtMs,
    ),
  };

  String _localAtPrefKey(String key) => switch (kind) {
    PlaybackPositionKind.video => videoRemotePositionAtPrefKey(key),
    PlaybackPositionKind.audiobook => audiobookPositionAtPrefKey(key),
  };

  /// 把对端位置落到本端。视频写回 pref 键对，并**仅当本地有 VideoBooks 行时**
  /// 写穿 `lastPositionMs`（流式视频不强建行污染书架）；`playedAt` 用**对端的**
  /// 时刻而不是 now（BUG-1542）。
  Future<void> _writeLocal(String key, PlaybackPosition p) async {
    switch (kind) {
      case PlaybackPositionKind.video:
        await _db.setPrefTyped<int>(
          videoRemotePositionPrefKey(key),
          p.positionMs,
        );
        await _db.setPrefTyped<int>(
          videoRemotePositionAtPrefKey(key),
          p.updatedAtMs,
        );
        if (await _db.getVideoBookByBookUid(key) != null) {
          await _db.updateVideoBookPosition(
            key,
            p.positionMs,
            playedAt: p.updatedAtMs,
          );
        }
      case PlaybackPositionKind.audiobook:
        await _db.setPrefTyped<int>(
          audiobookPositionPrefKey(key),
          p.positionMs,
        );
        await _db.setPrefTyped<int>(
          audiobookPositionAtPrefKey(key),
          p.updatedAtMs,
        );
    }
  }
}
