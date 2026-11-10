import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_baseline_scope.dart';
import 'package:fushi/src/sync/sync_resource_locks.dart';
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

/// 一条播放位置走完一次 live 三方同步的结局（[InterconnectPlaybackPositionSync.syncOne]）。
///
/// [local] / [remote] 是判定用的两端值；[localChanged] = 本端是否被改写（落地
/// host 值或对齐时间戳）；[push] = 推送了本端时的 host 结论（未推送为 null）。
typedef PlaybackPositionSyncStep = ({
  BookProgressSyncAction action,
  PlaybackPosition local,
  PlaybackPosition remote,
  bool localChanged,
  LivePushStatus? push,
});

/// 本机记下的远端视频断点（`video_remote_position_*` 位置 + `_at_` 时间戳键对），
/// **直接读库**。[episodeIndex] 的键规则见 [videoRemotePositionEpisodePrefKey]。
///
/// 这对键有多个写者：播放页（经 `PreferencesRepository.setPref`，库 + 内存缓存）、
/// 互联 sweep 与冲突弹窗（[InterconnectPlaybackPositionSync._writeLocal]，只写库）、
/// 本机作为互联 host 收到的对端 PUT（引擎层，只写库）。库是唯一真相源；读
/// `PreferencesRepository` 的内存缓存会拿到本机上次自己写的旧断点（BUG-4304）。
/// sweep 与播放页开播都从这里读，两处口径不会漂移。
Future<PlaybackPosition> readLocalRemoteVideoPosition(
  FushiDatabase db,
  String uid, {
  int episodeIndex = 0,
}) async => (
  positionMs: await db.getPrefTyped<int>(
    videoRemotePositionEpisodePrefKey(uid, episodeIndex),
    0,
  ),
  updatedAtMs: await db.getPrefTyped<int>(
    videoRemotePositionEpisodeAtPrefKey(uid, episodeIndex),
    0,
  ),
);

/// [readLocalRemoteVideoPosition] 的批量版：从一次读齐的 `video_remote_position_*`
/// 偏好快照（[FushiDatabase.getPrefsByPrefix]）里取 [uid] 的本机断点，解码与
/// [FushiDatabase.getPrefTyped] 同口径。列表展示一次给几十上百条远端条目用，
/// 免逐条两次查询（BUG-4303）。
PlaybackPosition localRemoteVideoPositionFromPrefs(
  Map<String, String> prefs,
  String uid, {
  int episodeIndex = 0,
}) {
  int readInt(String key) {
    final String? raw = prefs[key];
    return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
  }

  return (
    positionMs: readInt(videoRemotePositionEpisodePrefKey(uid, episodeIndex)),
    updatedAtMs: readInt(
      videoRemotePositionEpisodeAtPrefKey(uid, episodeIndex),
    ),
  );
}

/// 互联播放位置的两类条目（BUG-3367）。
enum PlaybackPositionKind { video, audiobook }

/// 一条播放位置的资源键（[syncResourceLocks]）。同一条目的「读基线 / 本端 → 判定
/// → 写 host / 本端 → 记基线」必须原子：sweep、播放页实时上报、冲突弹窗与对比弹窗
/// 各拿各的旧判定交错落地，基线会被旧判定改写（BUG-4279）。
///
/// 加锁顺序在「整轮 → 通道 → 书」之后：持有它的一方不再等任何别的资源。
String syncPlaybackPositionResource(PlaybackPositionKind kind, String key) =>
    'position:${kind.name}:$key';

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
///
/// 基线按 host 分槽（BUG-4281）：一个实例一生只绑一台 host（[bind]），基线读写都落
/// 那台 host 的存储维度，host 读写都钉住它（[InterconnectHostPin]）；会话中途换了
/// host 时 live 读写抛 [InterconnectHostChangedException]，不拿这台 host 的基线去判
/// 另一台 host 的值。sweep 每轮、弹窗每次加载各建新实例。
class InterconnectPlaybackPositionSync {
  InterconnectPlaybackPositionSync({
    required FushiDatabase db,
    required InterconnectSyncBackend backend,
    required this.kind,
  }) : _db = db,
       _backend = backend;

  final FushiDatabase _db;
  final InterconnectSyncBackend _backend;
  final PlaybackPositionKind kind;

  /// 本种类基线的**逻辑** dimension（冲突上报 / 裁决簿用；落库用 [bind] 后的存储
  /// 维度）。
  String get dimension => switch (kind) {
    PlaybackPositionKind.video => kInterconnectVideoPositionDimension,
    PlaybackPositionKind.audiobook => kInterconnectAudiobookPositionDimension,
  };

  Future<void>? _binding;
  InterconnectHostPin? _pin;
  String? _storageDimension;
  String? _storagePendingDimension;

  /// 绑定的 host（[bind] 之前为 null）。
  InterconnectHostPin? get pin => _pin;

  /// 绑到会话此刻所连的 host（BUG-4281）：取作用域、领养升级前的无后缀旧行、记下
  /// 存储维度。同一实例只绑一次（并发调用 await 同一个）；失败下次重试。不发请求。
  Future<void> bind() => _binding ??= _bind().then(
    (_) {},
    onError: (Object e, StackTrace st) {
      _binding = null;
      Error.throwWithStackTrace(e, st);
    },
  );

  Future<void> _bind() async {
    final InterconnectHostScope scope = await _backend.liveHostScope();
    final String? tag = scope.pin.tag;
    await ensureBaselinesAdopted(
      _db,
      logicalDimensions: <String>[dimension, pendingDimension],
      tag: tag,
      adoption: scope.adoption,
    );
    _storageDimension = baselineStorageDimension(dimension, tag);
    _storagePendingDimension = baselineStorageDimension(pendingDimension, tag);
    _pin = scope.pin;
  }

  /// 测试入口：绑定后的基线存储维度。
  @visibleForTesting
  Future<String> storageDimensionForTest() async {
    await bind();
    return _storageDimension!;
  }

  String get _baseDim => _storageDimension!;
  String get _pendingDim => _storagePendingDimension!;

  /// 本端位置。视频：书架视频的位置在 `VideoBooks.lastPositionMs`，流式视频的位置
  /// 在 `video_remote_position_<uid>` pref，时间戳统一取 `_at_` pref（与此前 sweep
  /// 的读法一致）；有声书：`audiobook_pos_<identity>` + `_at_` pref。
  Future<PlaybackPosition> localPosition(String key) async {
    switch (kind) {
      case PlaybackPositionKind.video:
        final VideoBookRow? row = await _db.getVideoBookByBookUid(key);
        final PlaybackPosition prefs = await readLocalRemoteVideoPosition(
          _db,
          key,
        );
        return (
          positionMs: row?.lastPositionMs ?? prefs.positionMs,
          updatedAtMs: prefs.updatedAtMs,
        );
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
        // 与 [localPosition] / 播放页开播同一份键对解码（BUG-4304）。
        final PlaybackPosition prefsPosition =
            localRemoteVideoPositionFromPrefs(prefs, key);
        return (
          positionMs: rowPositionMs ?? prefsPosition.positionMs,
          updatedAtMs: prefsPosition.updatedAtMs,
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
  Future<PlaybackBaselineSnapshot> loadBaselineSnapshot() async {
    await bind();
    return (
      baselines: await _db.getSyncBaselinesForDimension(_baseDim),
      pending: await _db.getSyncBaselinesForDimension(_pendingDim),
    );
  }

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

  /// 绑定的 host 端位置（host 无记录 → 0@0）；会话已换 host 时抛
  /// [InterconnectHostChangedException]。
  Future<PlaybackPosition> remotePosition(String key) async {
    await bind();
    return switch (kind) {
      PlaybackPositionKind.video => _backend.getLiveVideoPosition(
        key,
        pin: _pin,
      ),
      PlaybackPositionKind.audiobook => _backend.getLiveAudiobookPosition(
        key,
        pin: _pin,
      ),
    };
  }

  /// 「已发出、尚未确认」推送位置的逻辑 dimension（BUG-3528）。
  String get pendingDimension => '${dimension}_pending';

  /// 会话仍连着绑定的 host（[InterconnectSyncBackend.verifyHostPin]），否则抛
  /// [InterconnectHostChangedException]。会话已解析时不发请求。
  Future<void> verifyBoundHost() async {
    await bind();
    await _backend.verifyHostPin(_pin!);
  }

  /// 与绑定的 host 上次达成一致的位置（毫秒）；没有基线返回 null。
  Future<int?> baseline(String key) async {
    await bind();
    return _db.getSyncBaseline(key, _baseDim);
  }

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
    final int? pending = await _db.getSyncBaseline(key, _pendingDim);
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

  /// 一条的完整 live 三方同步：重读本端 → [decide] → 推送 / 落地 / 对齐（BUG-4283）。
  ///
  /// sweep（`SyncOrchestrator._syncPositionsLive`）与播放页开播
  /// （[InterconnectRemotePlaybackSession.startPositionFor]）共用这一份，开播不再另走
  /// 一套 LWW。[remote] 是调用方刚从绑定的 host 读到的值，同时作推送的前置条件
  /// （BUG-4279）。冲突时两端都不写，由调用方上报。调用方须已持有该条目的
  /// [syncPlaybackPositionResource] 锁。
  Future<PlaybackPositionSyncStep> syncOne(
    String key, {
    required PlaybackPosition remote,
  }) async {
    final PlaybackPosition local = await localPosition(key);
    final BookProgressSyncAction action = await decide(
      key,
      local: local,
      remote: remote,
    );
    final List<int> expected = <int>[remote.positionMs];
    bool localChanged = false;
    LivePushStatus? push;
    switch (action) {
      case BookProgressSyncAction.synced:
        localChanged = await alignSynced(
          key,
          local: local,
          remote: remote,
          expectedRemotePositions: expected,
        );
      case BookProgressSyncAction.pushLocal:
        push = (await pushLocal(
          key,
          local: local,
          remote: remote,
          expectedRemotePositions: expected,
        )).status;
      case BookProgressSyncAction.applyRemote:
        localChanged = await applyRemote(key, remote, local: local);
      case BookProgressSyncAction.conflict:
        break;
    }
    return (
      action: action,
      local: local,
      remote: remote,
      localChanged: localChanged,
      push: push,
    );
  }

  /// 记下两端此刻达成一致的位置；同时作废「待确认」推送。
  Future<void> recordBaseline(String key, int positionMs) async {
    await bind();
    await _db.setSyncBaseline(key, _baseDim, positionMs < 0 ? 0 : positionMs);
    await _db.deleteSyncBaseline(key, _pendingDim);
  }

  /// 推送前记下「待确认」位置（见 [decide]）。先核对会话仍连着绑定的 host：换了
  /// host 就不在这台 host 的作用域里留一条注定不会发出的「待确认」行。
  Future<void> _recordPending(String key, int positionMs) {
    _backend.checkHostPin(_pin!);
    return _db.setSyncBaseline(
      key,
      _pendingDim,
      positionMs < 0 ? 0 : positionMs,
    );
  }

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
  ///
  /// [expectedRemotePositions] 是前置条件：写者「判定时看到的 host 位置」。省略 =
  /// `[remote.positionMs]`（sweep 判定读到的就是 [remote]）；冲突弹窗传弹窗展示给
  /// 用户的对端值（BUG-4279）。调用方须持有该条目的
  /// [syncPlaybackPositionResource] 锁。
  Future<({LivePushStatus status, PlaybackPosition agreed})> pushLocal(
    String key, {
    required PlaybackPosition local,
    required PlaybackPosition remote,
    List<int>? expectedRemotePositions,
    int? nowMs,
  }) async {
    await bind();
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
      expectedPositionsMs: expectedRemotePositions ?? <int>[remote.positionMs],
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
  ///
  /// 整段在该条目的 [syncPlaybackPositionResource] 锁里（BUG-4279）：锁罩住网络往返，
  /// host 上的写入顺序与基线的写入顺序一致——否则先确认的写可能后记基线，把基线
  /// 倒退；sweep / 弹窗也不会拿各自的旧判定与它交错落地。播放页的每秒上报经
  /// [LivePositionReporter] 合并，积压不超过每条一个在途 + 一个待发。
  Future<LiveReportResult> reportLive(
    String key,
    PlaybackPosition live,
  ) async => (await _reportLiveLocked(key, live)).result;

  /// [reportLive] 的本体；同时带回锁内最后读到的基线（held 时 [LivePositionReporter]
  /// 记下它，基线被 sweep / 弹窗改写后才恢复上报）。
  Future<({LiveReportResult result, int? baseline})> _reportLiveLocked(
    String key,
    PlaybackPosition live,
  ) => syncResourceLocks.withResources(<String>{
    syncPlaybackPositionResource(kind, key),
  }, () => _reportLiveUnlocked(key, live));

  Future<({LiveReportResult result, int? baseline})> _reportLiveUnlocked(
    String key,
    PlaybackPosition live,
  ) async {
    final int? base = await baseline(key);
    final int? pending = await _db.getSyncBaseline(key, _pendingDim);
    final List<int> expected = <int>[
      if (base != null) base,
      if (pending != null && pending != base) pending,
    ];
    if (expected.isEmpty) {
      final PlaybackPosition remote = await remotePosition(key);
      switch (await decide(key, local: live, remote: remote)) {
        case BookProgressSyncAction.synced:
          await recordBaseline(key, live.positionMs);
          return (
            result: LiveReportResult.confirmed,
            baseline: live.positionMs,
          );
        case BookProgressSyncAction.pushLocal:
          expected.add(remote.positionMs);
        case BookProgressSyncAction.applyRemote:
        case BookProgressSyncAction.conflict:
          // decide 可能刚把「待确认」提升成基线：held 记的是此刻的基线。
          return (result: LiveReportResult.held, baseline: await baseline(key));
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
      return (result: LiveReportResult.held, baseline: base);
    }
    await recordBaseline(key, live.positionMs);
    return (result: LiveReportResult.confirmed, baseline: live.positionMs);
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
    await bind();
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
  ///
  /// [expectedRemotePositions] 同 [pushLocal]（省略 = `[remote.positionMs]`）；调用方
  /// 须持有该条目的 [syncPlaybackPositionResource] 锁。
  Future<bool> alignSynced(
    String key, {
    required PlaybackPosition local,
    required PlaybackPosition remote,
    List<int>? expectedRemotePositions,
  }) async {
    await bind();
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
        expectedPositionsMs:
            expectedRemotePositions ?? <int>[remote.positionMs],
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
      _db.deleteSyncBaseline(key, _pendingDim);

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
      pin: _pin,
    ),
    PlaybackPositionKind.audiobook => _backend.putLiveAudiobookPosition(
      key,
      p.positionMs,
      p.updatedAtMs,
      expectedPositionsMs: expectedPositionsMs,
      pin: _pin,
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

/// 播放页的 live 位置上报（BUG-4279）：按条目 single-flight，任意时刻每条最多一个
/// 在途 + 一个待发（只留最新值）。
///
/// 播放页每秒节流一次上报；每次上报都要拿条目锁并走网络往返（旧 host 还多两个
/// GET），慢网下独立发出的上报会排成长队、按旧值逐个打到 host。这里把同一条目的
/// 上报合并：在途时新值只顶替待发槽，在途结束后发待发槽里最新的那一个。
///
/// host 已被别的设备改写（[LiveReportResult.held]）时记下当时的基线：之后的上报先
/// 核对会话仍连着绑定的 host（不发请求），再读一次本地基线，没变（冲突尚未裁决）就
/// 不发网络请求——否则冲突期间每秒一个注定被拒的 PUT；sweep 或弹窗裁决后基线变了，
/// 自动恢复上报；会话换了 host 则换绑、作废 held。
class LivePositionReporter {
  LivePositionReporter({
    required FushiDatabase db,
    required this.backend,
    required PlaybackPositionKind kind,
  }) : _db = db,
       _kind = kind,
       _sync = InterconnectPlaybackPositionSync(
         db: db,
         backend: backend,
         kind: kind,
       );

  /// 上报目标；播放页换了远端客户端就换一个上报器。
  final InterconnectSyncBackend backend;
  final FushiDatabase _db;
  final PlaybackPositionKind _kind;

  /// 绑在某一台 host 上的同步实例（BUG-4281）；会话换了 host 时换新实例。
  InterconnectPlaybackPositionSync _sync;

  /// 有上报在途的条目。
  final Set<String> _inFlight = <String>{};

  /// 条目 → 待发的最新值与它的完成信号。
  final Map<String, ({PlaybackPosition live, Completer<void> done})> _pending =
      <String, ({PlaybackPosition live, Completer<void> done})>{};

  /// 条目 → 被 host 拒绝（held）时的基线（可为 null）。
  final Map<String, int?> _held = <String, int?>{};

  bool _closed = false;

  /// 提交一次上报；返回的 Future 在这一值发送完成、或被更新的值顶替时完成。不抛
  /// （错误 debugPrint）。[close] 之后的上报直接丢弃。
  Future<void> report(String key, PlaybackPosition live) {
    if (_closed) return Future<void>.value();
    final Completer<void> done = Completer<void>();
    if (_inFlight.contains(key)) {
      _pending.remove(key)?.done.complete();
      _pending[key] = (live: live, done: done);
      return done.future;
    }
    _inFlight.add(key);
    unawaited(_drain(key, live, done));
    return done.future;
  }

  /// 不再接受新上报；待发槽里的最后一个值仍会发出（最多一次请求），保住退出时的
  /// 断点接力（BUG-3367）。
  void close() => _closed = true;

  Future<void> _drain(
    String key,
    PlaybackPosition first,
    Completer<void> firstDone,
  ) async {
    PlaybackPosition live = first;
    Completer<void> done = firstDone;
    while (true) {
      await _send(key, live);
      done.complete();
      final ({PlaybackPosition live, Completer<void> done})? next = _pending
          .remove(key);
      if (next == null) break;
      live = next.live;
      done = next.done;
    }
    _inFlight.remove(key);
  }

  Future<void> _send(String key, PlaybackPosition live) async {
    final InterconnectPlaybackPositionSync bound = _sync;
    try {
      await _sendWith(bound, key, live);
    } on InterconnectHostChangedException {
      // 会话换了 host（BUG-4281）：抛出点在发请求之前，这个值没到任何 host。换一个
      // 绑到新 host 的实例，按新 host 的基线把这个值重新判定一次。
      _rebind(bound);
      try {
        await _sendWith(_sync, key, live);
      } catch (e) {
        debugPrint('[sync] live position report "$key" failed: $e');
      }
    } catch (e) {
      debugPrint('[sync] live position report "$key" failed: $e');
    }
  }

  /// [bound] 绑的 host 已不是会话所连的 host（BUG-4281）：换一个新实例（下次用到时
  /// 绑到新 host）。held 记的是旧 host 的基线，一并作废。
  void _rebind(InterconnectPlaybackPositionSync bound) {
    if (!identical(_sync, bound)) return;
    _sync = InterconnectPlaybackPositionSync(
      db: _db,
      backend: backend,
      kind: _kind,
    );
    _held.clear();
  }

  Future<void> _sendWith(
    InterconnectPlaybackPositionSync sync,
    String key,
    PlaybackPosition live,
  ) async {
    if (_held.containsKey(key)) {
      // held 时不发请求，所以要主动核对会话还在不在绑定的 host 上（评审 compat-3）：
      // 换了 host 就在这里抛 [InterconnectHostChangedException]，[_send] 换绑到新
      // host、作废旧 host 的 held，按新 host 的基线重新判定这个值。
      await sync.verifyBoundHost();
      if (await sync.baseline(key) == _held[key]) return;
      _held.remove(key);
    }
    final ({LiveReportResult result, int? baseline}) r = await sync
        ._reportLiveLocked(key, live);
    if (r.result == LiveReportResult.held) {
      _held[key] = r.baseline;
    }
  }
}

/// 互联远端视频这一集的开播位置是否经 [InterconnectRemotePlaybackSession.startPositionFor]
/// 走三方判定（BUG-4283；播放页只在互联客户端上调它）。纯函数。
///
/// - [episodeIndex] > 0（host-playlist 非首集）：那一集的位置不在 sweep 同步的键上，
///   照用本地值；
/// - [EpisodeStartIntent.explicitCue]（换画质 / 换线路回到当前位置）：调用方给的就是
///   此刻的播放位置，不重新判定；
/// - [sourceReviewActive]（卡片回看）：不碰服务器进度（BUG-3490）。
///
/// 其余（首开、合集切成员、换集、自动连播）都判。
bool remoteEpisodeStartUsesThreeWay({
  required int episodeIndex,
  required EpisodeStartIntent intent,
  required bool sourceReviewActive,
}) =>
    episodeIndex <= 0 &&
    intent != EpisodeStartIntent.explicitCue &&
    !sourceReviewActive;

/// 一个互联远端视频播放会话（BUG-4283）：每一集载入时的开播判定 + 实时上报。
///
/// 此前播放页开播用本地 prefs 与 host 清单值做「取较新时间戳」（LWW），不读基线、
/// 不判冲突；合集切成员 / 换集只读本地 prefs。之后的实时上报把这次未经三方判定的
/// 选择当作两端一致的起点。这里让每一集载入（首开、合集切成员、单视频重载）都在
/// 该条位置锁里现读钉住的 host、跑与 sweep 同一份
/// [InterconnectPlaybackPositionSync.syncOne]，开播位置按三方结论取。
///
/// 开播与上报共用 [LivePositionReporter] 里绑定的同一个同步实例：两者落同一台 host
/// 的基线作用域，开播判成冲突时上报器据此 held（见 [startPositionFor]）。
class InterconnectRemotePlaybackSession {
  InterconnectRemotePlaybackSession({
    required FushiDatabase db,
    required this.backend,
  }) : _reporter = LivePositionReporter(
         db: db,
         backend: backend,
         kind: PlaybackPositionKind.video,
       );

  /// 会话所用的互联客户端；播放页换了远端客户端就换一个会话。
  final InterconnectSyncBackend backend;
  final LivePositionReporter _reporter;

  /// 第 [key] 条（视频 uid / 合集成员 id）载入时的开播位置。
  ///
  /// 在该条位置锁内用带 pin 的 GET 现读 host，跑 [InterconnectPlaybackPositionSync.syncOne]：
  /// - `applyRemote` 且落地 → host 位置；本端在判定后被改写（CAS 未落地）→ 重读本端；
  /// - `pushLocal` / `synced` → 本端位置；
  /// - `conflict` → 本端位置（本机断点不被播放器覆盖），并让上报器对该条 held 在当时
  ///   的基线上：本次播放不向 host 上报，冲突留给弹窗；sweep / 弹窗裁决改了基线后
  ///   上报自动恢复。
  ///
  /// 网络失败 / 会话换了 host 时返回 [fallbackMs]（离线照常能播），之后的上报照
  /// [InterconnectPlaybackPositionSync.reportLive] 的规则走。
  Future<int> startPositionFor(String key, {required int fallbackMs}) async {
    final InterconnectPlaybackPositionSync sync = _reporter._sync;
    try {
      return await syncResourceLocks.withResources(<String>{
        syncPlaybackPositionResource(sync.kind, key),
      }, () => _startPositionLocked(sync, key));
    } on InterconnectHostChangedException catch (e) {
      _reporter._rebind(sync);
      debugPrint('[sync] remote playback start "$key": $e');
      return fallbackMs;
    } catch (e) {
      debugPrint('[sync] remote playback start "$key" failed: $e');
      return fallbackMs;
    }
  }

  Future<int> _startPositionLocked(
    InterconnectPlaybackPositionSync sync,
    String key,
  ) async {
    final PlaybackPosition remote = await sync.remotePosition(key);
    final PlaybackPositionSyncStep step = await sync.syncOne(
      key,
      remote: remote,
    );
    final int start;
    switch (step.action) {
      case BookProgressSyncAction.applyRemote:
        start = step.localChanged
            ? remote.positionMs
            : (await sync.localPosition(key)).positionMs;
      case BookProgressSyncAction.pushLocal:
      case BookProgressSyncAction.synced:
        start = step.local.positionMs;
      case BookProgressSyncAction.conflict:
        _reporter._held[key] = await sync.baseline(key);
        return step.local.positionMs < 0 ? 0 : step.local.positionMs;
    }
    // 这一条已按三方结论收敛：此前（同一会话里上一次载入）的 held 作废。
    _reporter._held.remove(key);
    return start < 0 ? 0 : start;
  }

  /// 实时上报（播放页节流回调）；语义见 [LivePositionReporter.report]。
  Future<void> report(String key, PlaybackPosition live) =>
      _reporter.report(key, live);

  /// 不再接受新上报；语义见 [LivePositionReporter.close]。
  void close() => _reporter.close();
}
