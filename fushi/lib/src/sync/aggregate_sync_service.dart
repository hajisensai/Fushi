import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi/src/sync/aggregate_merge_service.dart';
import 'package:fushi/src/sync/aggregate_snapshot.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show
        FavoriteSentence,
        FavoriteSentenceRepository,
        kFavoriteSentenceTombstoneType;
import 'package:fushi_core/fushi_core.dart';

/// Reserved top-level folder (under the backend root) that holds per-device
/// aggregate snapshots. Named alongside `__dictionaries__` / `__local_audio__`,
/// it must be filtered from any listing that treats root children as books.
const String kSyncAggregateNamespace = '__aggregate__';

/// Suffix of a device's aggregate snapshot asset inside the namespace. The
/// asset name is `<deviceId><suffix>`, one file per device so two devices never
/// clobber each other's snapshot (the whole point of the per-device layout).
const String _aggregateAssetSuffix = '.fushiaggregate';

/// Hibiki 时代写下的同一资产的后缀（W9-4 改名前）。**只读不写**：云根迁移只把
/// 根文件夹改名、内容原样保留，所以用户云上仍有大量旧后缀快照；listing 只认新
/// 后缀会把它们当成陌生文件跳过 = 静默丢掉迁移过来的聚合状态。写侧一律新后缀，
/// 旧快照被折进来后自然随下一轮 per-device 快照过期。
const String _legacyAggregateAssetSuffix = '.hibikiaggregate';

/// 该资产名是否是（新或旧）聚合快照。
bool _isAggregateAsset(String name) =>
    name.endsWith(_aggregateAssetSuffix) ||
    name.endsWith(_legacyAggregateAssetSuffix);

/// Preference key holding the favorite-sentence JSON list. Mirrors
/// `FavoriteSentenceRepository._key` and BackupMergeEngine's constant; kept in
/// sync behaviourally by favorite_sentence_merge_import_test.dart.
const String _favoriteSentencesPrefKey = 'favorite_sentences';

/// Drives the `aggregate` sync dimension over any cloud [SyncAssetStore]
/// (Google Drive / OneDrive / Dropbox / WebDAV / FTP / SFTP), the TODO-1056
/// phase-B channel. Statistics and favorites are collection / monotonic
/// families, so their cross-device merge needs no baseline and no conflict
/// prompt: it is only-grows, never-shrinks-a-value, idempotent, and commutative
/// on the union set - exactly [AggregateMergeService]'s guarantees, which this
/// service reuses verbatim (it invents no new merge algorithm).
///
/// Layout: under the reserved `__aggregate__` namespace each device owns ONE
/// JSON snapshot asset `<deviceId>.fushiaggregate`（Hibiki 时代写的旧后缀
/// `.hibikiaggregate` 仍被读入，见 [_legacyAggregateAssetSuffix]）。On a sync the device:
///   1. materialises its own current aggregate state into a snapshot;
///   2. downloads every OTHER device's snapshot and folds them all - plus its
///      own materialised state - through [AggregateMergeService];
///   3. applies the merged result back into its local DB (MAX / union writes
///      only, so re-applying is a no-op);
///   4. re-materialises and uploads its own (now merged) snapshot.
///
/// Deletions never propagate (a favorite removed on one device is not
/// resurrected from a peer snapshot); statistics only ever move up (per-bucket
/// MAX, never SUM, so a re-sync never double-counts). No schema change: the
/// snapshot is a transient JSON asset, the local state lives in the existing
/// statistic tables + favorite_sentences pref.
class AggregateSyncService {
  AggregateSyncService(this._db);

  final FushiDatabase _db;

  /// Runs one aggregate sync over [store]. [deviceId] is this device's stable id
  /// (SyncRepository.getOrCreateDeviceId), used to name its own snapshot asset.
  ///
  /// First-sync degradation: an absent `__aggregate__` namespace (no peer ever
  /// uploaded) means there is nothing to pull; the device still uploads its own
  /// snapshot so peers can pull it next time. A device with no local aggregate
  /// state AND no peer snapshots uploads nothing (nothing to share).
  /// 返回**是否真的上传了**本端快照。调用方据此决定增量索引的 revision 要不要 +1
  /// （见 `SyncRunReport.remoteMutated`）：这一步历史上是无条件写的，而无条件写会让
  /// 每台设备每轮同步都在远端留下改动痕迹，于是所有对端的「无人动过」判据永远为假、
  /// 依赖它的阶段跳过全部失效，多设备之间互相触发、永不收敛。
  Future<bool> sync({
    required SyncAssetStore store,
    required String deviceId,
  }) async {
    // 1) Materialise local state.
    final AggregateSnapshot localSnapshot = await materializeLocalSnapshot();

    // 2) Ensure the reserved namespace, list peer snapshots.
    final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
    final List<AssetEntry> children = await store.listChildren(ns);

    final String ownAssetName = '$deviceId$_aggregateAssetSuffix';
    // 本机在 Hibiki 时代写下的同一份快照：同样是「自己状态的回声」，本地库已经
    // 带着迁移过来的状态，折回来只会复活本地已删的条目，故与新名一并跳过。
    final String ownLegacyAssetName = '$deviceId$_legacyAggregateAssetSuffix';

    // 3) Fold every OTHER device's snapshot into the local one. Own asset is
    //    skipped (it is a stale echo of our own state; re-folding it is a no-op
    //    anyway, but skipping saves a download).
    AggregateSnapshot merged = localSnapshot;
    for (final AssetEntry entry in children) {
      if (entry.isFolder) continue;
      if (!_isAggregateAsset(entry.name)) continue;
      if (entry.name == ownAssetName) continue;
      if (entry.name == ownLegacyAssetName) continue;
      Object? peerJson;
      try {
        peerJson = await store.getJsonAsset(entry.id);
      } catch (_) {
        // A single unreadable peer snapshot must not abort the sweep; skip it.
        continue;
      }
      final AggregateSnapshot peer = AggregateSnapshot.fromJson(peerJson);
      merged = mergeSnapshots(merged, peer);
    }

    // 4) Apply the merged result back locally (MAX / union writes; idempotent).
    if (!identical(merged, localSnapshot)) {
      await applySnapshotToLocal(merged);
    }

    // 5) Upload this device's now-merged snapshot so peers converge next sync.
    //    BUG-1572：上行前先过墓碑。merged 是 local ∪ peer，peer 那份仍带着本机**已
    //    删掉**的统计/收藏词/收藏句——applySnapshotToLocal 只在写回本地时跳过它们，
    //    推出去的却是未裁剪的 merged，等于本机把自己删掉的东西又发布回云/host。对端
    //    没有本机的墓碑，照单落库；本机下轮再拉回来（或本地墓碑被 clearStatisticsTombstone
    //    清掉后拉回来）= 数据复活。裁剪规则与 applySnapshotToLocal 同源（filterTombstoned）。
    //    Nothing to share on a device with an empty merged state and no peers:
    //    skip the write so a fresh device does not litter an empty asset.
    final AggregateSnapshot outgoing = await filterTombstoned(merged);
    if (outgoing.isEmpty) return false;

    // 内容与本端上次上传的完全一致时不再重传：远端那份就是这份，重写一遍除了让
    // 所有对端误以为「本端又改了远端」之外没有任何作用。
    //
    // 判据同时要求**远端确实还存在**本端那份资产（`children` 里已经列到了，免费）：
    // 只信本地记录的话，远端那份被删掉后本端会永远拒绝重传，peers 再也拿不到本端
    // 的数据。
    final Map<String, dynamic> payload = outgoing.toJson();
    final String hash = _stableHash(jsonEncode(payload));
    final bool ownAssetPresent =
        children.any((AssetEntry e) => !e.isFolder && e.name == ownAssetName);
    if (ownAssetPresent &&
        hash == await _db.getPrefTyped<String>(_kLastPushedHashKey, '')) {
      return false;
    }

    await store.putJsonAsset(ns, ownAssetName, payload);
    await _db.setPrefTyped<String>(_kLastPushedHashKey, hash);
    return true;
  }

  /// 本端上次成功上传的聚合快照内容哈希（设备本地，纯缓存：丢了最多多传一次）。
  static const String _kLastPushedHashKey = 'sync_aggregate_last_pushed_hash';

  /// FNV-1a（64 位）。不是安全哈希，只用来判「内容变没变」，需要的只有确定性和零
  /// 依赖；碰撞的后果是漏传一次快照，概率 2^-64 量级。
  ///
  /// 不用 `Object.hashCode`：Dart 不保证它跨运行稳定，用它会让每轮都判成「变了」，
  /// 去重形同虚设；更糟的是它可能在部分平台上恰好稳定，于是问题只在部分用户身上出现。
  static String _stableHash(String input) {
    const int prime = 0x01000193;
    int hi = 0xcbf29ce4;
    int lo = 0x84222325;
    for (final int unit in input.codeUnits) {
      lo ^= unit;
      final int loProduct = lo * prime;
      final int hiProduct = hi * prime + (loProduct ~/ 0x100000000);
      lo = loProduct & 0xffffffff;
      hi = hiProduct & 0xffffffff;
    }
    return hi.toRadixString(16).padLeft(8, '0') +
        lo.toRadixString(16).padLeft(8, '0');
  }

  /// Runs one aggregate sync over the interconnect live channel (TODO-1056
  /// phase C). Same only-grows / MAX / union / idempotent semantics as the cloud
  /// [sync], but the transport is a single host snapshot fetched over the LAN
  /// server instead of per-device snapshot files in a `__aggregate__` namespace.
  ///
  /// [fetchRemote] GETs the host's aggregate snapshot JSON (the client backend
  /// returns null when the host is old / lacks the endpoint — an old-server
  /// degradation: the client then only PUSHES its own materialised snapshot so a
  /// newer host would still receive it, and skips the local fold with no crash).
  /// [pushMerged] PUTs the merged snapshot JSON back to the host, where the host
  /// folds it into its own DB (MAX / union, idempotent).
  ///
  /// Flow: materialise local -> GET host snapshot -> fold via [mergeSnapshots]
  /// (single source of truth) -> apply locally (MAX / union writes only) -> PUT
  /// merged back. First sync (host empty) still converges: an empty peer folds to
  /// the local snapshot, applied as a no-op, then pushed so the host converges.
  /// A device with an empty merged state pushes nothing (nothing to share).
  ///
  /// No schema change; the snapshot is a transient JSON payload, local state
  /// lives in the existing statistic tables + favorite_sentences pref.
  Future<void> syncOverClient({
    required Future<Object?> Function() fetchRemote,
    required Future<void> Function(Object json) pushMerged,
  }) async {
    // 1) Materialise local state.
    final AggregateSnapshot localSnapshot = await materializeLocalSnapshot();

    // 2) Fetch the host's snapshot. null => old host without the endpoint:
    //    degrade to push-only (still share our state; skip the local fold).
    final Object? remoteJson = await fetchRemote();
    if (remoteJson == null) {
      // BUG-1572：即便这条退化路径推的是纯本地快照，也走同一道裁剪——本地
      // materialise 与墓碑之间没有强制不变量（例如收藏句 pref 与墓碑表分居两处），
      // 让「推出去的东西必过墓碑」在**每条**上行路径上都成立，而不是靠推理。
      final AggregateSnapshot localOutgoing =
          await filterTombstoned(localSnapshot);
      if (localOutgoing.isEmpty) return; // Nothing to share, nothing to fold.
      await pushMerged(localOutgoing.toJson());
      return;
    }

    // 3) Fold the host snapshot into the local one through the same pure merge
    //    the cloud channel uses (single source of truth; commutative/idempotent).
    final AggregateSnapshot remote = AggregateSnapshot.fromJson(remoteJson);
    final AggregateSnapshot merged = mergeSnapshots(localSnapshot, remote);

    // 4) Apply the merged result back locally (MAX / union writes; idempotent).
    if (!identical(merged, localSnapshot)) {
      await applySnapshotToLocal(merged);
    }

    // 5) Push the merged snapshot back so the host converges to the union.
    //    BUG-1572：与云通道同律，上行前按本机墓碑裁剪，否则 host 会把本机已删的
    //    统计/收藏落库并在下轮回灌本机（复活）。
    //    Nothing to share on an all-empty merge: skip the write.
    final AggregateSnapshot outgoing = await filterTombstoned(merged);
    if (outgoing.isEmpty) return;
    await pushMerged(outgoing.toJson());
  }

  /// 按本机删除墓碑裁剪一份**将要上行**的快照，规则与 [applySnapshotToLocal] 写回
  /// 本地时的跳过规则逐条同源（BUG-1572）：
  ///   - 阅读统计：命中 `(title, statSourceBook)` 统计墓碑 → 剔除；
  ///   - 视频统计：命中 `(title, statSourceVideo)` → 剔除；
  ///   - 查词/制卡计数：命中 `(title, sourceType)` → 剔除；
  ///   - 收藏词：命中 `favoriteword` 删除墓碑（按 [FushiDatabase.favoriteWordItemKey]）→ 剔除；
  ///   - 收藏句：命中 `favoritesentence` 删除墓碑 → 剔除。
  ///
  /// 逐时桶（readingHourly / readingHourlyByFormat / videoHourly）与 miningStats 的
  /// wire 键里**没有 title**，无法归因到被删的书/视频，故与 apply 侧一样原样保留——
  /// 两侧同样处理，才谈得上「推出去的 == 会写回来的」。
  ///
  /// 无任何墓碑时返回入参本身（零拷贝，且 `identical` 仍成立）。
  @visibleForTesting
  Future<AggregateSnapshot> filterTombstoned(AggregateSnapshot snapshot) async {
    final Set<(String, String)> statTombstoned =
        await _db.getStatisticsTombstoneKeys();
    final Set<String> favWordTombstoned = <String>{
      for (final SyncDeletionTombstoneRow row
          in await _db.getSyncDeletionTombstonesOfType('favoriteword'))
        row.itemKey,
    };
    final Set<String> favSentenceTombstoned = <String>{
      for (final SyncDeletionTombstoneRow row in await _db
          .getSyncDeletionTombstonesOfType(kFavoriteSentenceTombstoneType))
        row.itemKey,
    };
    if (statTombstoned.isEmpty &&
        favWordTombstoned.isEmpty &&
        favSentenceTombstoned.isEmpty) {
      return snapshot;
    }
    return AggregateSnapshot(
      readingStats: <ReadingStatRecord>[
        for (final ReadingStatRecord r in snapshot.readingStats)
          if (!statTombstoned.contains((r.title, FushiDatabase.statSourceBook)))
            r,
      ],
      videoStats: <VideoStatRecord>[
        for (final VideoStatRecord r in snapshot.videoStats)
          if (!statTombstoned
              .contains((r.title, FushiDatabase.statSourceVideo)))
            r,
      ],
      readingHourly: snapshot.readingHourly,
      readingHourlyByFormat: snapshot.readingHourlyByFormat,
      videoHourly: snapshot.videoHourly,
      miningStats: snapshot.miningStats,
      lookupMiningCounters: <LookupMiningRecord>[
        for (final LookupMiningRecord r in snapshot.lookupMiningCounters)
          if (!statTombstoned.contains((r.title, r.sourceType))) r,
      ],
      favoriteWords: <FavoriteWordRecord>[
        for (final FavoriteWordRecord r in snapshot.favoriteWords)
          if (!favWordTombstoned.contains(FushiDatabase.favoriteWordItemKey(
              r.expression, r.reading, r.sourceType)))
            r,
      ],
      favoriteSentences: <FavoriteSentence>[
        for (final FavoriteSentence s in snapshot.favoriteSentences)
          if (!favSentenceTombstoned
              .contains(FavoriteSentenceRepository.itemKeyOf(s)))
            s,
      ],
    );
  }

  /// Pure fold of two snapshots through [AggregateMergeService] - the single
  /// source of truth for every family's merge semantics. No new algorithm here:
  /// each list is projected to the keyed map the fold expects, MAX-/union-ed,
  /// then flattened back to a row list. Commutative and idempotent because the
  /// underlying folds are.
  @visibleForTesting
  static AggregateSnapshot mergeSnapshots(
    AggregateSnapshot local,
    AggregateSnapshot remote,
  ) {
    return AggregateSnapshot(
      readingStats: _mergeReadingStats(local.readingStats, remote.readingStats),
      videoStats: _mergeVideoStats(local.videoStats, remote.videoStats),
      readingHourly: _mergeHourly(local.readingHourly, remote.readingHourly),
      readingHourlyByFormat: _mergeHourlyFormats(
        local.readingHourlyByFormat,
        remote.readingHourlyByFormat,
      ),
      videoHourly: _mergeHourly(local.videoHourly, remote.videoHourly),
      miningStats: _mergeMining(local.miningStats, remote.miningStats),
      lookupMiningCounters: _mergeLookupMining(
        local.lookupMiningCounters,
        remote.lookupMiningCounters,
      ),
      favoriteWords: AggregateMergeService.mergeUniqueByKey<FavoriteWordRecord>(
        local.favoriteWords,
        remote.favoriteWords,
        (FavoriteWordRecord r) => r.uniqueKey,
      ),
      favoriteSentences: AggregateMergeService.mergeFavoriteSentences(
        local.favoriteSentences,
        remote.favoriteSentences,
      ),
    );
  }

  static List<ReadingStatRecord> _mergeReadingStats(
    List<ReadingStatRecord> local,
    List<ReadingStatRecord> remote,
  ) {
    final Map<String, StatBucket> localMap = <String, StatBucket>{
      for (final ReadingStatRecord r in local)
        r.key: StatBucket(<String, int>{
          'charactersRead': r.charactersRead,
          'readingTimeMs': r.readingTimeMs,
          'lastStatisticModified': r.lastStatisticModified,
        }),
    };
    final Map<String, StatBucket> remoteMap = <String, StatBucket>{
      for (final ReadingStatRecord r in remote)
        r.key: StatBucket(<String, int>{
          'charactersRead': r.charactersRead,
          'readingTimeMs': r.readingTimeMs,
          'lastStatisticModified': r.lastStatisticModified,
        }),
    };
    final Map<String, ReadingStatRecord> idById = <String, ReadingStatRecord>{
      for (final ReadingStatRecord r in local) r.key: r,
      for (final ReadingStatRecord r in remote) r.key: r,
    };
    final Map<String, StatBucket> mergedMap =
        AggregateMergeService.mergeStatBuckets(localMap, remoteMap);
    return <ReadingStatRecord>[
      for (final MapEntry<String, StatBucket> e in mergedMap.entries)
        ReadingStatRecord(
          title: idById[e.key]!.title,
          dateKey: idById[e.key]!.dateKey,
          charactersRead: e.value.fields['charactersRead']!,
          readingTimeMs: e.value.fields['readingTimeMs']!,
          lastStatisticModified: e.value.fields['lastStatisticModified']!,
        ),
    ];
  }

  static List<VideoStatRecord> _mergeVideoStats(
    List<VideoStatRecord> local,
    List<VideoStatRecord> remote,
  ) {
    final Map<String, StatBucket> localMap = <String, StatBucket>{
      for (final VideoStatRecord r in local)
        r.key: StatBucket(<String, int>{
          'subtitleChars': r.subtitleChars,
          'watchTimeMs': r.watchTimeMs,
          'lastModified': r.lastModified,
        }),
    };
    final Map<String, StatBucket> remoteMap = <String, StatBucket>{
      for (final VideoStatRecord r in remote)
        r.key: StatBucket(<String, int>{
          'subtitleChars': r.subtitleChars,
          'watchTimeMs': r.watchTimeMs,
          'lastModified': r.lastModified,
        }),
    };
    final Map<String, VideoStatRecord> idById = <String, VideoStatRecord>{
      for (final VideoStatRecord r in local) r.key: r,
      for (final VideoStatRecord r in remote) r.key: r,
    };
    final Map<String, StatBucket> mergedMap =
        AggregateMergeService.mergeStatBuckets(localMap, remoteMap);
    return <VideoStatRecord>[
      for (final MapEntry<String, StatBucket> e in mergedMap.entries)
        VideoStatRecord(
          title: idById[e.key]!.title,
          dateKey: idById[e.key]!.dateKey,
          subtitleChars: e.value.fields['subtitleChars']!,
          watchTimeMs: e.value.fields['watchTimeMs']!,
          lastModified: e.value.fields['lastModified']!,
        ),
    ];
  }

  static List<HourlyRecord> _mergeHourly(
    List<HourlyRecord> local,
    List<HourlyRecord> remote,
  ) {
    final Map<String, int> localMap = <String, int>{
      for (final HourlyRecord r in local) r.key: r.durationMs,
    };
    final Map<String, int> remoteMap = <String, int>{
      for (final HourlyRecord r in remote) r.key: r.durationMs,
    };
    final Map<String, HourlyRecord> idById = <String, HourlyRecord>{
      for (final HourlyRecord r in local) r.key: r,
      for (final HourlyRecord r in remote) r.key: r,
    };
    final Map<String, int> mergedMap =
        AggregateMergeService.mergeMaxCounters(localMap, remoteMap);
    return <HourlyRecord>[
      for (final MapEntry<String, int> e in mergedMap.entries)
        HourlyRecord(
          dateKey: idById[e.key]!.dateKey,
          hour: idById[e.key]!.hour,
          durationMs: e.value,
        ),
    ];
  }

  /// 把按 format 分桶的本地行折叠成 {dateKey, hour} 逐时总量（旧 wire 形状，
  /// 见 materializeLocalSnapshot 的 readingHourly 注释）。
  static List<HourlyRecord> _foldHourlyTotals(List<ReadingHourlyLogRow> rows) {
    final Map<String, int> sums = <String, int>{};
    final Map<String, (String, int)> hourByKey = <String, (String, int)>{};
    for (final ReadingHourlyLogRow r in rows) {
      final String key = '${r.dateKey}|${r.hour}';
      sums[key] = (sums[key] ?? 0) + r.readingTimeMs;
      hourByKey[key] = (r.dateKey, r.hour);
    }
    return <HourlyRecord>[
      for (final MapEntry<String, int> e in sums.entries)
        HourlyRecord(
          dateKey: hourByKey[e.key]!.$1,
          hour: hourByKey[e.key]!.$2,
          durationMs: e.value,
        ),
    ];
  }

  /// 按写入面拆分的逐时桶（{dateKey, hour, format}，v67）：与 [_mergeHourly]
  /// 同款 MAX 折叠，只是 key 多了 format 一维。
  static List<HourlyFormatRecord> _mergeHourlyFormats(
    List<HourlyFormatRecord> local,
    List<HourlyFormatRecord> remote,
  ) {
    final Map<String, int> localMap = <String, int>{
      for (final HourlyFormatRecord r in local) r.key: r.durationMs,
    };
    final Map<String, int> remoteMap = <String, int>{
      for (final HourlyFormatRecord r in remote) r.key: r.durationMs,
    };
    final Map<String, HourlyFormatRecord> idById = <String, HourlyFormatRecord>{
      for (final HourlyFormatRecord r in local) r.key: r,
      for (final HourlyFormatRecord r in remote) r.key: r,
    };
    final Map<String, int> mergedMap =
        AggregateMergeService.mergeMaxCounters(localMap, remoteMap);
    return <HourlyFormatRecord>[
      for (final MapEntry<String, int> e in mergedMap.entries)
        HourlyFormatRecord(
          dateKey: idById[e.key]!.dateKey,
          hour: idById[e.key]!.hour,
          format: idById[e.key]!.format,
          durationMs: e.value,
        ),
    ];
  }

  static List<MiningRecord> _mergeMining(
    List<MiningRecord> local,
    List<MiningRecord> remote,
  ) {
    final Map<String, int> localMap = <String, int>{
      for (final MiningRecord r in local) r.key: r.count,
    };
    final Map<String, int> remoteMap = <String, int>{
      for (final MiningRecord r in remote) r.key: r.count,
    };
    final Map<String, MiningRecord> idById = <String, MiningRecord>{
      for (final MiningRecord r in local) r.key: r,
      for (final MiningRecord r in remote) r.key: r,
    };
    final Map<String, int> mergedMap =
        AggregateMergeService.mergeMaxCounters(localMap, remoteMap);
    return <MiningRecord>[
      for (final MapEntry<String, int> e in mergedMap.entries)
        MiningRecord(
          sourceType: idById[e.key]!.sourceType,
          dateKey: idById[e.key]!.dateKey,
          count: e.value,
        ),
    ];
  }

  /// MAX-union of lookup/mining counter buckets keyed by {title, sourceType,
  /// dateKey}. Both count columns (lookupCount, mineCount) are MAX-ed
  /// independently through [StatBucket]; a bucket on only one side is kept
  /// verbatim. [bookKey] is not part of the key: on a collision the identity is
  /// kept only when BOTH sides carry the same value; any disagreement (incl.
  /// null-vs-known) folds to null（v76/review3-3：wire null 的语义是「刻意混桶/
  /// 未归因」而非「不知道」，非空覆盖会把混桶总量重新归因单一视频）。判据对称，
  /// 合并顺序无关。
  static List<LookupMiningRecord> _mergeLookupMining(
    List<LookupMiningRecord> local,
    List<LookupMiningRecord> remote,
  ) {
    final Map<String, StatBucket> localMap = <String, StatBucket>{
      for (final LookupMiningRecord r in local)
        r.key: StatBucket(<String, int>{
          'lookupCount': r.lookupCount,
          'mineCount': r.mineCount,
        }),
    };
    final Map<String, StatBucket> remoteMap = <String, StatBucket>{
      for (final LookupMiningRecord r in remote)
        r.key: StatBucket(<String, int>{
          'lookupCount': r.lookupCount,
          'mineCount': r.mineCount,
        }),
    };
    // Identity + bookKey resolution（review3-3）：v76 起 wire null 的语义是
    // 「刻意混桶/未归因」（见 _foldLookupMiningRows），不再是「不知道、谁知道听
    // 谁的」。两侧对同一桶的身份**一致才保留**，任一侧 null 或互相矛盾 → null
    // ——旧的「null 被非空覆盖」规则会把混桶求和总量重新归因到单一视频，在下游
    // 全新设备上复刻互串。peer-only 桶（本地无记录）仍原样落地保住身份。
    final Map<String, LookupMiningRecord> metaByKey =
        <String, LookupMiningRecord>{};
    for (final LookupMiningRecord r in local) {
      metaByKey[r.key] = r;
    }
    for (final LookupMiningRecord r in remote) {
      final LookupMiningRecord? existing = metaByKey[r.key];
      if (existing == null) {
        metaByKey[r.key] = r;
      } else if (existing.bookKey != r.bookKey) {
        metaByKey[r.key] = LookupMiningRecord(
          bookKey: null,
          title: existing.title,
          sourceType: existing.sourceType,
          dateKey: existing.dateKey,
          lookupCount: existing.lookupCount,
          mineCount: existing.mineCount,
        );
      }
    }
    final Map<String, StatBucket> mergedMap =
        AggregateMergeService.mergeStatBuckets(localMap, remoteMap);
    return <LookupMiningRecord>[
      for (final MapEntry<String, StatBucket> e in mergedMap.entries)
        LookupMiningRecord(
          bookKey: metaByKey[e.key]!.bookKey,
          title: metaByKey[e.key]!.title,
          sourceType: metaByKey[e.key]!.sourceType,
          dateKey: metaByKey[e.key]!.dateKey,
          lookupCount: e.value.fields['lookupCount']!,
          mineCount: e.value.fields['mineCount']!,
        ),
    ];
  }

  /// v76（review3-1）：watch 行按 wire 键 {title,dateKey} 求和上行——per-uid
  /// 多行直接逐行上行会 last-wins 丢数（见 materializeLocalSnapshot 处注释）。
  /// wire 不带身份（VideoStatRecord 无 bookUid 字段，冻结），无 metadata 之忧。
  ///
  /// 已知精度限制（review4-3，与 backup_merge_engine 的「宁可保留全部数据也不
  /// 瞎塌」同族取舍）：备份合并可能让「无身份总量行」与 per-uid 行并存（两侧
  /// v76 回填不对称时），二者是否重叠不可判——求和假设不相交（独立设备各看各的
  /// 就是不相交），重叠时汇总偏高并经 MAX 固化。取 max 则在不相交时把真实观看
  /// 砍半。两个方向都有错法，沿用「不丢数」侧，与 counters fold 一致。
  static List<VideoStatRecord> _foldVideoStatRows(
      List<VideoWatchStatisticRow> rows) {
    final Map<String, VideoStatRecord> byWireKey = <String, VideoStatRecord>{};
    for (final VideoWatchStatisticRow r in rows) {
      final VideoStatRecord record = VideoStatRecord(
        title: r.title,
        dateKey: r.dateKey,
        subtitleChars: r.subtitleChars,
        watchTimeMs: r.watchTimeMs,
        lastModified: r.lastModified,
      );
      final VideoStatRecord? existing = byWireKey[record.key];
      if (existing == null) {
        byWireKey[record.key] = record;
      } else {
        byWireKey[record.key] = VideoStatRecord(
          title: existing.title,
          dateKey: existing.dateKey,
          subtitleChars: existing.subtitleChars + record.subtitleChars,
          watchTimeMs: existing.watchTimeMs + record.watchTimeMs,
          lastModified: existing.lastModified > record.lastModified
              ? existing.lastModified
              : record.lastModified,
        );
      }
    }
    return byWireKey.values.toList();
  }

  /// v76：lookup_mining_counters 本地行 per-identity 可多行（bookKey 进唯一键），
  /// wire 合并键仍冻结在 {title, sourceType, dateKey}——直接逐行上行会在合并 map
  /// 构建时 last-wins **静默丢数**（同 title 多行只剩最后一行）。按 wire 键把多行
  /// 求和成单条 record。
  ///
  /// bookKey metadata 只在**无歧义**时携带：wire 桶内全部行同一非空身份 → 带它；
  /// 混桶（多身份 / 身份+'' 并存）→ null。求和总量盖上任意单一身份会让接收端把
  /// 整个 title 日总量归因到一个视频——在对端重新制造 v76 要根治的互串，且与本地
  /// 塌缩路径（setLookupCount 多行分支如实写 ''）自相矛盾（review-1）。
  static List<LookupMiningRecord> _foldLookupMiningRows(
      List<LookupMiningCounterRow> rows) {
    final Map<String, LookupMiningRecord> byWireKey =
        <String, LookupMiningRecord>{};
    for (final LookupMiningCounterRow r in rows) {
      final LookupMiningRecord record = LookupMiningRecord(
        bookKey: r.bookKey.isEmpty ? null : r.bookKey,
        title: r.title,
        sourceType: r.sourceType,
        dateKey: r.dateKey,
        lookupCount: r.lookupCount,
        mineCount: r.mineCount,
      );
      final LookupMiningRecord? existing = byWireKey[record.key];
      if (existing == null) {
        byWireKey[record.key] = record;
      } else {
        byWireKey[record.key] = LookupMiningRecord(
          bookKey: existing.bookKey == record.bookKey ? existing.bookKey : null,
          title: existing.title,
          sourceType: existing.sourceType,
          dateKey: existing.dateKey,
          lookupCount: existing.lookupCount + record.lookupCount,
          mineCount: existing.mineCount + record.mineCount,
        );
      }
    }
    return byWireKey.values.toList();
  }

  /// Reads the whole local aggregate state (four statistic tables + mining +
  /// lookup/mine per-book counters + favorite words + favorite-sentence pref
  /// blob) into a snapshot. Pure read, no mutation.
  Future<AggregateSnapshot> materializeLocalSnapshot() async {
    final List<ReadingStatisticRow> reading =
        await _db.getAllReadingStatistics();
    final List<VideoWatchStatisticRow> video =
        await _db.getAllVideoWatchStatistics();
    final List<ReadingHourlyLogRow> readingHourly =
        await _db.getAllReadingHourlyLogs();
    final List<VideoHourlyLogRow> videoHourly =
        await _db.getAllVideoHourlyLogs();
    final List<MiningStatisticRow> mining = await _db.getAllMiningStatistics();
    final List<LookupMiningCounterRow> lookupMining =
        await _db.getAllLookupMiningCounters();
    final List<FavoriteWordRow> favWords = await _db.getAllFavoriteWords();
    final List<FavoriteSentence> favSentences = await _readFavoriteSentences();

    return AggregateSnapshot(
      readingStats: <ReadingStatRecord>[
        for (final ReadingStatisticRow r in reading)
          ReadingStatRecord(
            title: r.title,
            dateKey: r.dateKey,
            charactersRead: r.charactersRead,
            readingTimeMs: r.readingTimeMs,
            lastStatisticModified: r.lastStatisticModified,
          ),
      ],
      // v76（review3-1）：watch 行 v39 起 per-uid 可多行，wire 键只有
      // {title,dateKey}——逐行上行会在合并 map 构建时 last-wins **静默丢数**
      // （同名双视频只剩最后一行的时长，apply 再把本地两行删掉写回小值 =
      // 每轮同步永久丢观看时长）。与 counters 的 fold 同律：按 wire 键求和。
      videoStats: _foldVideoStatRows(video),
      // 旧 wire 形状 = 逐时总量：v67 起本地行按 format 分桶，这里先按
      // {dateKey, hour} 折叠回「该小时全部阅读面之和」，旧端看到的字节语义与
      // 拆分前完全一致；拆分数据走下面的 readingHourlyByFormat。
      readingHourly: _foldHourlyTotals(readingHourly),
      readingHourlyByFormat: <HourlyFormatRecord>[
        for (final ReadingHourlyLogRow r in readingHourly)
          HourlyFormatRecord(
            dateKey: r.dateKey,
            hour: r.hour,
            format: r.format,
            durationMs: r.readingTimeMs,
          ),
      ],
      videoHourly: <HourlyRecord>[
        for (final VideoHourlyLogRow r in videoHourly)
          HourlyRecord(
            dateKey: r.dateKey,
            hour: r.hour,
            durationMs: r.watchTimeMs,
          ),
      ],
      miningStats: <MiningRecord>[
        for (final MiningStatisticRow r in mining)
          MiningRecord(
            sourceType: r.sourceType,
            dateKey: r.dateKey,
            count: r.count,
          ),
      ],
      lookupMiningCounters: _foldLookupMiningRows(lookupMining),
      favoriteWords: <FavoriteWordRecord>[
        for (final FavoriteWordRow r in favWords)
          FavoriteWordRecord(
            expression: r.expression,
            reading: r.reading,
            glossary: r.glossary,
            sourceType: r.sourceType,
            dateKey: r.dateKey,
            createdAt: r.createdAt,
          ),
      ],
      favoriteSentences: favSentences,
    );
  }

  /// Applies a merged snapshot back into the local DB using ONLY MAX / union
  /// writes, so re-applying the same snapshot is a no-op (the guarantee online
  /// sync needs). Statistics go through the overwrite setters after the Dart
  /// side already folded MAX, mining through setMiningCount (MAX), favorite
  /// words through the idempotent addFavoriteWord, and favorite sentences
  /// through the same pure fold + pref write BackupMergeEngine uses.
  Future<void> applySnapshotToLocal(AggregateSnapshot snapshot) async {
    // TODO-1204 后续：统计删除墓碑。用户在统计页删掉某本书/视频的统计后，本地行已删、
    // 但 peer 快照仍带该书的旧 MAX 值——[mergeSnapshots] 会把它 union 回 merged，若直接
    // 写回就复活了。这里按 (title, sourceType) 跳过被删的书统计，让本设备删掉的书不被
    // peer 快照复活（墓碑本地生效；用户重读该书 / 查词会清墓碑，见 database.dart 的
    // add* 方法）。reading→'book'、video→'video'、lookup_mining_counters 用其 sourceType。
    final Set<(String, String)> tombstoned =
        await _db.getStatisticsTombstoneKeys();
    for (final ReadingStatRecord r in snapshot.readingStats) {
      if (tombstoned.contains((r.title, FushiDatabase.statSourceBook))) {
        continue;
      }
      await _db.setReadingStatistic(ReadingStatisticsCompanion(
        title: Value(r.title),
        dateKey: Value(r.dateKey),
        charactersRead: Value(r.charactersRead),
        readingTimeMs: Value(r.readingTimeMs),
        lastStatisticModified: Value(r.lastStatisticModified),
      ));
    }
    for (final VideoStatRecord r in snapshot.videoStats) {
      if (tombstoned.contains((r.title, FushiDatabase.statSourceVideo))) {
        continue;
      }
      await _db.setVideoWatchStatistic(VideoWatchStatisticsCompanion(
        title: Value(r.title),
        dateKey: Value(r.dateKey),
        subtitleChars: Value(r.subtitleChars),
        watchTimeMs: Value(r.watchTimeMs),
        lastModified: Value(r.lastModified),
      ));
    }
    // v67 两步落库，顺序有意：
    // ① 先落按写入面拆分的桶（新端互相之间的完整拆分数据；OVERWRITE 落
    //    Dart 侧已折好的 MAX 绝对值，format 裸串逐字节透传）。
    for (final HourlyFormatRecord r in snapshot.readingHourlyByFormat) {
      await _db.setReadingHourlyLog(
        dateKey: r.dateKey,
        hour: r.hour,
        readingTimeMs: r.durationMs,
        format: r.format,
      );
    }
    // ② 再做逐时总量的差额归因：旧端上传只有总量（不带 format），其中超出
    //    本地该小时全部 format 桶之和的部分无法归因到任何写入面，累加进 ''
    //    （未区分）桶。数学上 sum_f MAX_d ≥ MAX_d sum_f，全新端环境差额恒
    //    ≤ 0（绝不虚增）；重复应用同一快照差额为 0（幂等，与本方法其余
    //    family 的 MAX/union 保证一致）。
    if (snapshot.readingHourly.isNotEmpty) {
      final Map<String, int> localSums = <String, int>{};
      for (final ReadingHourlyLogRow row
          in await _db.getAllReadingHourlyLogs()) {
        final String key = '${row.dateKey}|${row.hour}';
        localSums[key] = (localSums[key] ?? 0) + row.readingTimeMs;
      }
      for (final HourlyRecord r in snapshot.readingHourly) {
        final int deficit =
            r.durationMs - (localSums['${r.dateKey}|${r.hour}'] ?? 0);
        if (deficit > 0) {
          await _db.addUnattributedHourlyReadingTime(
            dateKey: r.dateKey,
            hour: r.hour,
            deltaMs: deficit,
          );
        }
      }
    }
    for (final HourlyRecord r in snapshot.videoHourly) {
      await _db.setVideoHourlyLog(
        dateKey: r.dateKey,
        hour: r.hour,
        watchTimeMs: r.durationMs,
      );
    }
    for (final MiningRecord r in snapshot.miningStats) {
      await _db.setMiningCount(
        sourceType: r.sourceType,
        dateKey: r.dateKey,
        count: r.count,
      );
    }
    for (final LookupMiningRecord r in snapshot.lookupMiningCounters) {
      // TODO-1204 后续：跳过被删书的查词/制卡计数（按 (title, sourceType) 命中墓碑）。
      if (tombstoned.contains((r.title, r.sourceType))) continue;
      // Both setters are MAX-union on {title, sourceType, dateKey}: setLookupCount
      // creates or lifts the row's lookupCount, then setMineCountPerBook lifts
      // the same row's mineCount. Order is safe because the first call
      // materialises the row the second one updates; re-applying is a no-op.
      await _db.setLookupCount(
        bookKey: r.bookKey,
        title: r.title,
        sourceType: r.sourceType,
        dateKey: r.dateKey,
        count: r.lookupCount,
      );
      await _db.setMineCountPerBook(
        bookKey: r.bookKey,
        title: r.title,
        sourceType: r.sourceType,
        dateKey: r.dateKey,
        count: r.mineCount,
      );
    }
    // 删除传播：跳过有 `favoriteword` sync 删除墓碑的收藏——否则本设备取消收藏后，
    // peer 快照的并集会把它重新加回（复活，正是要治的痛点）。与上面统计墓碑同律。
    final Set<String> favTombstoned = <String>{
      for (final SyncDeletionTombstoneRow row
          in await _db.getSyncDeletionTombstonesOfType('favoriteword'))
        row.itemKey,
    };
    for (final FavoriteWordRecord r in snapshot.favoriteWords) {
      if (favTombstoned.contains(FushiDatabase.favoriteWordItemKey(
          r.expression, r.reading, r.sourceType))) {
        continue;
      }
      // addFavoriteWord is idempotent on {expression, reading, sourceType}:
      // a word the device already has returns false, a peer-only word inserts.
      await _db.addFavoriteWord(
        expression: r.expression,
        reading: r.reading,
        glossary: r.glossary,
        sourceType: r.sourceType,
        dateKey: r.dateKey,
      );
    }
    await _writeFavoriteSentences(snapshot.favoriteSentences);
  }

  /// Folds an INCOMING peer snapshot into the local DB safely: materialises the
  /// local state first, MAX/union-merges the peer on top (single source of truth
  /// [mergeSnapshots]), then applies the merged result. Unlike calling
  /// [applySnapshotToLocal] directly with a raw peer snapshot, this can NEVER
  /// shrink a local value — a peer bucket smaller than the local one is dominated
  /// by the local side in the MAX fold. Used by the interconnect HOST when it
  /// receives a client-pushed snapshot (the host has not pre-merged its own state
  /// into what the client sent, so it must fold here), keeping the never-shrinks /
  /// idempotent invariants on the host side too. Returns nothing; local DB is the
  /// side effect.
  Future<void> foldIntoLocal(AggregateSnapshot incoming) async {
    if (incoming.isEmpty) return; // Nothing to fold: no-op (idempotent).
    final AggregateSnapshot local = await materializeLocalSnapshot();
    final AggregateSnapshot merged = mergeSnapshots(local, incoming);
    await applySnapshotToLocal(merged);
  }

  /// Reads the favorite-sentence pref blob into models, tolerating a
  /// null/empty/malformed value (empty list) so a corrupt pref never aborts.
  Future<List<FavoriteSentence>> _readFavoriteSentences() async {
    final String? raw = await _db.getPref(_favoriteSentencesPrefKey);
    if (raw == null || raw.isEmpty) return const <FavoriteSentence>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <FavoriteSentence>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(FavoriteSentence.fromJson)
          .toList();
    } catch (_) {
      return const <FavoriteSentence>[];
    }
  }

  /// Merges [merged] favorite sentences with whatever the pref currently holds
  /// (a concurrent local add during the sync must not be lost) and writes the
  /// union back. The extra fold is idempotent, so writing an already-merged set
  /// is a no-op.
  Future<void> _writeFavoriteSentences(List<FavoriteSentence> merged) async {
    if (merged.isEmpty) return;
    final List<FavoriteSentence> current = await _readFavoriteSentences();
    final List<FavoriteSentence> union =
        AggregateMergeService.mergeFavoriteSentences(current, merged);
    // 删除传播：剔除有 `favoritesentence` 删除墓碑的收藏句——否则本设备取消收藏后，peer
    // 快照的并集会把它重新加回（复活）。与收藏词墓碑抑制（applySnapshotToLocal 内）同律。
    final Set<String> tombstoned = <String>{
      for (final SyncDeletionTombstoneRow row in await _db
          .getSyncDeletionTombstonesOfType(kFavoriteSentenceTombstoneType))
        row.itemKey,
    };
    final List<FavoriteSentence> out = tombstoned.isEmpty
        ? union
        : union
            .where((FavoriteSentence s) =>
                !tombstoned.contains(FavoriteSentenceRepository.itemKeyOf(s)))
            .toList();
    final String json =
        jsonEncode(out.map((FavoriteSentence s) => s.toJson()).toList());
    await _db.setPref(_favoriteSentencesPrefKey, json);
  }
}
