import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 一条播放位置：毫秒位置 + 最后更新时刻（epoch 毫秒，0 = 无记录 / 旧数据）。
typedef PlaybackPosition = ({int positionMs, int updatedAtMs});

/// 一轮 sweep 开头一次读齐的位置基线（assetKey → 位置毫秒）与「待确认」推送基线
/// （见 [InterconnectPlaybackPositionSync.loadBaselineSnapshot]）。
typedef PlaybackBaselineSnapshot = ({
  Map<String, int> baselines,
  Map<String, int> pending,
});

/// 播放页实时上报（[InterconnectPlaybackPositionSync.reportLive]）的结局（BUG-4278）。
enum LiveReportResult {
  /// host 确认停在上报位置，基线已推进。
  confirmed,

  /// host 没采纳或已被别的设备改写：基线不动，交给下一轮 sweep 判定。
  held,
}

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

  /// 从整表偏好快照读本端位置（与 [localPosition] 同口径，零 SQL）。
  ///
  /// [prefs] 是 sweep 开头一次读齐的 `preferences`（[FushiDatabase.getAllPrefs]）；
  /// [rowPositionMs] 是视频的 `VideoBooks.lastPositionMs`（无行 = null，有声书忽略）。
  /// 只用于 sweep 的「已收敛则跳过」判定；需要落地时一律回到 [localPosition] 重读。
  PlaybackPosition localPositionFromPrefs(
    String key, {
    required Map<String, String> prefs,
    int? rowPositionMs,
  }) {
    int readInt(String prefKey) {
      final String? raw = prefs[prefKey];
      return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
    }

    switch (kind) {
      case PlaybackPositionKind.video:
        return (
          positionMs: rowPositionMs ?? readInt(videoRemotePositionPrefKey(key)),
          updatedAtMs: readInt(videoRemotePositionAtPrefKey(key)),
        );
      case PlaybackPositionKind.audiobook:
        return (
          positionMs: readInt(audiobookPositionPrefKey(key)),
          updatedAtMs: readInt(audiobookPositionAtPrefKey(key)),
        );
    }
  }

  /// 一次读齐本种类全部条目的基线与「待确认」基线（两条查询），供 sweep 在内存里
  /// 判定 [isSettled]，免逐条 `getSyncBaseline`。
  Future<PlaybackBaselineSnapshot> loadBaselineSnapshot() async => (
    baselines: await _db.getSyncBaselinesForDimension(dimension),
    pending: await _db.getSyncBaselinesForDimension(pendingDimension),
  );

  /// 两端已完全收敛、这一轮无事可做：位置与时间戳都相同、基线已等于该位置、
  /// 没有「待确认」推送。
  ///
  /// 此时原路径是 [decide] → synced → [alignSynced]：不 PUT（时间戳相等）、不落
  /// 本端（时间戳相等）、只把同一个值重写一遍基线并删一条不存在的待确认行——
  /// 净效果为零，却是每条目每轮固定的读写。条件里任何一项不成立都
  /// 不算收敛，调用方回到原路径逐条重读、判定、落地，语义不变。
  static bool isSettled({
    required PlaybackPosition local,
    required PlaybackPosition remote,
    required PlaybackBaselineSnapshot snapshot,
    required String key,
  }) {
    if (snapshot.pending.containsKey(key)) return false;
    if (local.positionMs != remote.positionMs ||
        local.updatedAtMs != remote.updatedAtMs) {
      return false;
    }
    final int recorded = local.positionMs < 0 ? 0 : local.positionMs;
    return snapshot.baselines[key] == recorded;
  }

  /// host 端位置（host 无记录 → 0@0）。
  Future<PlaybackPosition> remotePosition(String key) => switch (kind) {
    PlaybackPositionKind.video => _backend.remoteVideoPosition(key),
    PlaybackPositionKind.audiobook => _backend.remoteAudiobookPosition(key),
  };

  /// 「已发出、尚未确认」推送位置的 dimension（BUG-3528）。
  String get pendingDimension => '${dimension}_pending';

  /// 上次两端达成一致的位置（毫秒）；没有基线返回 null。
  Future<int?> baseline(String key) => _db.getSyncBaseline(key, dimension);

  /// 三方判定的唯一入口：sweep 与冲突弹窗都走这里，不各自读基线。
  ///
  /// 与书籍版 `InterconnectBookProgressSync.decide` 同理（BUG-3528）：PUT 在 host
  /// 端已提交、客户端却超时时基线没推进，下一轮会把 host 上本机自己的写入误判成
  /// 对端改动。推送前记下的「待确认」位置若正是 host 当前位置，先提升为基线。
  Future<BookProgressSyncAction> decide(
    String key, {
    required PlaybackPosition local,
    required PlaybackPosition remote,
  }) async {
    int? base = await baseline(key);
    final int? pending = await _db.getSyncBaseline(key, pendingDimension);
    if (pending != null &&
        remote.updatedAtMs > 0 &&
        pending == remote.positionMs &&
        base != remote.positionMs) {
      await recordBaseline(key, pending);
      base = pending;
    }
    return resolvePlaybackPositionThreeWay(
      local: local,
      remote: remote,
      basePositionMs: base,
    );
  }

  /// 记下两端此刻达成一致的位置；同时作废「待确认」推送。
  Future<void> recordBaseline(String key, int positionMs) async {
    await _db.setSyncBaseline(key, dimension, positionMs < 0 ? 0 : positionMs);
    await _db.deleteSyncBaseline(key, pendingDimension);
  }

  /// 推送前记下「待确认」位置（见 [decide]）。
  Future<void> _recordPending(String key, int positionMs) => _db
      .setSyncBaseline(key, pendingDimension, positionMs < 0 ? 0 : positionMs);

  /// 本端胜出：推给 host（时间戳不新于 host 时抬到 host + 1，见类头），**host 确认**
  /// 停在推送位置后本端只对齐时间戳 pref、记基线（BUG-4278）。返回推送结局与推送
  /// 的位置。
  ///
  /// 推送带前置条件「host 仍停在判定时读到的 [remote]」：
  /// - [LivePushStatus.confirmed]：本端 `_at_` pref 对齐到 host 写后的戳，记基线；
  /// - [LivePushStatus.rejected] / [LivePushStatus.superseded]：host 没采纳或判定后
  ///   被第三台设备改写——删「待确认」行，不动本端、不记基线，下一轮按新事实重判；
  /// - 抛异常（超时 / 断网）：不处理，「待确认」行保留，下一轮 [decide] 照 BUG-3528
  ///   提升。
  ///
  /// 抬戳纪律与书籍版 `InterconnectBookProgressSync.pushLocal` 一致（BUG-3367 的
  /// 书籍版补上了同一套防护）：抬出来的戳
  /// 至少是 [nowMs]；host 已存的超限毒戳（[trustedStoredSyncStamp]）按 0 比较，
  /// 结果再截到 [capFutureSyncStamp]——否则 `毒戳 + 1` 会写进本端 `_at_` pref，
  /// host 却把上报戳截成 `now + 余量`，下一轮两端位置相同、本端戳更新 →
  /// [alignSynced] 又 PUT 一次，每轮重复写。
  Future<({LivePushStatus status, PlaybackPosition agreed})> pushLocal(
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
    await _recordPending(key, agreed.positionMs);
    final LivePositionPush pushed = await _putLive(
      key,
      agreed,
      expectedPositionsMs: <int>[remote.positionMs],
    );
    if (pushed.status != LivePushStatus.confirmed) {
      await _dropPending(key);
      return (status: pushed.status, agreed: agreed);
    }
    // host 可能把戳再抬过（前置条件命中时取 max(上报戳, 已存戳 + 1)），本端对齐到
    // host 写后的那个戳，下一轮两端戳相同、不再重复对齐。
    final int hostTs = capFutureSyncStamp(
      pushed.hostNow?.updatedAtMs ?? ts,
      nowMs: now,
    );
    if (hostTs != local.updatedAtMs) {
      // 比较后写入（BUG-3537）：PUT 期间本端断点若已被改写，抬戳作废，本端留着
      // 更新的那份，下一轮照常再推；host 已确认停在 [agreed]，基线照记。
      await _db.runIfIntPrefUnchanged(
        stampKey: _localAtPrefKey(key),
        expectedStamp: local.updatedAtMs,
        write: () => _db.setPrefTyped<int>(_localAtPrefKey(key), hostTs),
      );
    }
    await recordBaseline(key, agreed.positionMs);
    return (status: LivePushStatus.confirmed, agreed: agreed);
  }

  /// 播放页实时上报（节流回调）：本端位置 [live] 已由播放页写进本地 pref，这里推给
  /// host，**host 确认**后把基线推进到上报位置（BUG-4278）。
  ///
  /// 与 sweep 共用这一入口而不是播放页裸调 `putRemoteVideoPosition`：实时上报本身
  /// 就是「两端在这个位置达成一致」，不推进基线的话，A 串流到 600（host=600、基线
  /// 仍停在旧的 100）→ B 从 600 接着看到 900 → A 下轮 sweep 见 local=600 ≠ 基线、
  /// remote=900 ≠ 基线，会把顺序接力误判成两端分叉而弹冲突（BUG-3367）。
  ///
  /// 前置条件 = 基线与「待确认」位置里非空的那些：host 仍停在两端上次一致的位置（或
  /// 本机上一次已发出的位置）上，说明期间没有别的设备写过，上报可以接续推进——即使
  /// host 的戳因时钟差比本机新（V-C3）。host 已被第三台设备改写 → 不写、不记基线，
  /// 返回 [LiveReportResult.held]，交给下一轮 sweep 判定。
  ///
  /// 两者都没有（这一条从未同步过）：现读 host 跑一次 [decide]——`synced` 只记基线，
  /// `pushLocal` 以读到的 host 位置为前置条件推送，`applyRemote` / `conflict` 不写
  /// （播放中不把 host 值落到本端），返回 held。
  Future<LiveReportResult> reportLive(String key, PlaybackPosition live) async {
    final int? base = await baseline(key);
    final int? pending = await _db.getSyncBaseline(key, pendingDimension);
    final List<int> expected = <int>[
      if (base != null) base,
      if (pending != null && pending != base) pending,
    ];
    if (expected.isEmpty) {
      final PlaybackPosition remote = await remotePosition(key);
      switch (await decide(key, local: live, remote: remote)) {
        case BookProgressSyncAction.synced:
          await recordBaseline(key, live.positionMs);
          return LiveReportResult.confirmed;
        case BookProgressSyncAction.pushLocal:
          expected.add(remote.positionMs);
        case BookProgressSyncAction.applyRemote:
        case BookProgressSyncAction.conflict:
          return LiveReportResult.held;
      }
    }
    await _recordPending(key, live.positionMs);
    final LivePositionPush pushed = await _putLive(
      key,
      live,
      expectedPositionsMs: expected,
    );
    if (pushed.status != LivePushStatus.confirmed) {
      await _dropPending(key);
      return LiveReportResult.held;
    }
    await recordBaseline(key, live.positionMs);
    return LiveReportResult.confirmed;
  }

  /// host 胜出：落回本端，记基线。返回是否真的落地。
  ///
  /// [local] 是判定时读到的本端断点。落地是「比较后写入」（BUG-3537，与书籍版
  /// `InterconnectBookProgressSync.applyRemote` 同纪律）：判定前刚走过一次网络读
  /// host，这期间本机播放器或本机作为互联 host 收到的对端 PUT 可能已写进更新的
  /// 断点；本端时间戳一变就不落地、不记基线，交给下一轮重新判定。
  ///
  /// 落到本端的时间戳截到 [capFutureSyncStamp]：host 上的超限毒戳不进本端
  /// `_at_` pref（视频还会写进 `lastPlayedAt`）。
  Future<bool> applyRemote(
    String key,
    PlaybackPosition remote, {
    required PlaybackPosition local,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool landed = await _writeLocalIfUnchanged(key, (
      positionMs: remote.positionMs,
      updatedAtMs: capFutureSyncStamp(remote.updatedAtMs, nowMs: now),
    ), expected: local);
    if (landed) await recordBaseline(key, remote.positionMs);
    return landed;
  }

  /// 两端位置一致、只是时间戳不同：把较新的时间戳对齐到另一端（沿用此前 LWW 路径
  /// 的对齐写法），记基线。返回本端是否被改写。
  ///
  /// 比较用 host 的可信戳（[trustedStoredSyncStamp]）：host 上的超限毒戳按 0，
  /// 本端胜出、把本端戳推给 host，本端不会被对齐成毒戳。
  Future<bool> alignSynced(
    String key, {
    required PlaybackPosition local,
    required PlaybackPosition remote,
  }) async {
    final int remoteTs = trustedStoredSyncStamp(
      remote.updatedAtMs,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    bool localChanged = false;
    if (local.updatedAtMs > remoteTs) {
      // 位置相同、只推本端较新的戳；host 判定后被改写（superseded）则这次判定作废，
      // 不记基线。host 拒收（rejected）不影响「两端位置一致」这一事实，基线照记。
      final LivePositionPush pushed = await _putLive(
        key,
        local,
        expectedPositionsMs: <int>[remote.positionMs],
      );
      if (pushed.status == LivePushStatus.superseded) {
        await _dropPending(key);
        return false;
      }
    } else if (remoteTs > local.updatedAtMs) {
      // 比较后写入（BUG-3537）：判定后本端被改写就不对齐。
      localChanged = await _writeLocalIfUnchanged(key, remote, expected: local);
    }
    await recordBaseline(key, local.positionMs);
    return localChanged;
  }

  /// 删「待确认」行：这次推送 host 明确没采纳（BUG-4278），它不再携带信息。
  Future<void> _dropPending(String key) =>
      _db.deleteSyncBaseline(key, pendingDimension);

  /// 带前置条件的 live 写入（[InterconnectSyncBackend.putLiveVideoPosition]）。
  Future<LivePositionPush> _putLive(
    String key,
    PlaybackPosition p, {
    required List<int> expectedPositionsMs,
  }) => switch (kind) {
    PlaybackPositionKind.video => _backend.putLiveVideoPosition(
      key,
      p.positionMs,
      p.updatedAtMs,
      expectedPositionsMs: expectedPositionsMs,
    ),
    PlaybackPositionKind.audiobook => _backend.putLiveAudiobookPosition(
      key,
      p.positionMs,
      p.updatedAtMs,
      expectedPositionsMs: expectedPositionsMs,
    ),
  };

  String _localAtPrefKey(String key) => switch (kind) {
    PlaybackPositionKind.video => videoRemotePositionAtPrefKey(key),
    PlaybackPositionKind.audiobook => audiobookPositionAtPrefKey(key),
  };

  /// 本端落地的唯一写口：仅当本端时间戳 pref 仍是判定时读到的 [expected] 才写
  /// （[FushiDatabase.runIfIntPrefUnchanged]，重读与写入同一事务，BUG-3537）。
  Future<bool> _writeLocalIfUnchanged(
    String key,
    PlaybackPosition p, {
    required PlaybackPosition expected,
  }) => _db.runIfIntPrefUnchanged(
    stampKey: _localAtPrefKey(key),
    expectedStamp: expected.updatedAtMs,
    write: () => _writeLocal(key, p),
  );

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
