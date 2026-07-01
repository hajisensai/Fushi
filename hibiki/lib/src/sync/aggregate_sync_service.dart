import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hibiki/src/sync/aggregate_merge_service.dart';
import 'package:hibiki/src/sync/aggregate_snapshot.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki_audio/hibiki_audio.dart' show FavoriteSentence;
import 'package:hibiki_core/hibiki_core.dart';

/// Reserved top-level folder (under the backend root) that holds per-device
/// aggregate snapshots. Named alongside `__dictionaries__` / `__local_audio__`,
/// it must be filtered from any listing that treats root children as books.
const String kSyncAggregateNamespace = '__aggregate__';

/// Suffix of a device's aggregate snapshot asset inside the namespace. The
/// asset name is `<deviceId><suffix>`, one file per device so two devices never
/// clobber each other's snapshot (the whole point of the per-device layout).
const String _aggregateAssetSuffix = '.hibikiaggregate';

/// Preference key holding the favorite-sentence JSON list. Mirrors
/// `FavoriteSentenceRepository._key` and BackupMergeEngine's constant; kept in
/// sync by favorite_sentence_pref_key_guard_test.dart.
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
/// JSON snapshot asset `<deviceId>.hibikiaggregate`. On a sync the device:
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

  final HibikiDatabase _db;

  /// Runs one aggregate sync over [store]. [deviceId] is this device's stable id
  /// (SyncRepository.getOrCreateDeviceId), used to name its own snapshot asset.
  ///
  /// First-sync degradation: an absent `__aggregate__` namespace (no peer ever
  /// uploaded) means there is nothing to pull; the device still uploads its own
  /// snapshot so peers can pull it next time. A device with no local aggregate
  /// state AND no peer snapshots uploads nothing (nothing to share).
  Future<void> sync({
    required SyncAssetStore store,
    required String deviceId,
  }) async {
    // 1) Materialise local state.
    final AggregateSnapshot localSnapshot = await materializeLocalSnapshot();

    // 2) Ensure the reserved namespace, list peer snapshots.
    final String ns = await store.ensureNamespace(kSyncAggregateNamespace);
    final List<AssetEntry> children = await store.listChildren(ns);

    final String ownAssetName = '$deviceId$_aggregateAssetSuffix';

    // 3) Fold every OTHER device's snapshot into the local one. Own asset is
    //    skipped (it is a stale echo of our own state; re-folding it is a no-op
    //    anyway, but skipping saves a download).
    AggregateSnapshot merged = localSnapshot;
    for (final AssetEntry entry in children) {
      if (entry.isFolder) continue;
      if (!entry.name.endsWith(_aggregateAssetSuffix)) continue;
      if (entry.name == ownAssetName) continue;
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
    //    Nothing to share on a device with an empty merged state and no peers:
    //    skip the write so a fresh device does not litter an empty asset.
    if (merged.isEmpty) return;
    await store.putJsonAsset(ns, ownAssetName, merged.toJson());
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
      if (localSnapshot.isEmpty) return; // Nothing to share, nothing to fold.
      await pushMerged(localSnapshot.toJson());
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
    //    Nothing to share on an all-empty merge: skip the write.
    if (merged.isEmpty) return;
    await pushMerged(merged.toJson());
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
      videoHourly: _mergeHourly(local.videoHourly, remote.videoHourly),
      miningStats: _mergeMining(local.miningStats, remote.miningStats),
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

  /// Reads the whole local aggregate state (four statistic tables + mining +
  /// favorite words + favorite-sentence pref blob) into a snapshot. Pure read,
  /// no mutation.
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
      videoStats: <VideoStatRecord>[
        for (final VideoWatchStatisticRow r in video)
          VideoStatRecord(
            title: r.title,
            dateKey: r.dateKey,
            subtitleChars: r.subtitleChars,
            watchTimeMs: r.watchTimeMs,
            lastModified: r.lastModified,
          ),
      ],
      readingHourly: <HourlyRecord>[
        for (final ReadingHourlyLogRow r in readingHourly)
          HourlyRecord(
            dateKey: r.dateKey,
            hour: r.hour,
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
    for (final ReadingStatRecord r in snapshot.readingStats) {
      await _db.setReadingStatistic(ReadingStatisticsCompanion(
        title: Value(r.title),
        dateKey: Value(r.dateKey),
        charactersRead: Value(r.charactersRead),
        readingTimeMs: Value(r.readingTimeMs),
        lastStatisticModified: Value(r.lastStatisticModified),
      ));
    }
    for (final VideoStatRecord r in snapshot.videoStats) {
      await _db.setVideoWatchStatistic(VideoWatchStatisticsCompanion(
        title: Value(r.title),
        dateKey: Value(r.dateKey),
        subtitleChars: Value(r.subtitleChars),
        watchTimeMs: Value(r.watchTimeMs),
        lastModified: Value(r.lastModified),
      ));
    }
    for (final HourlyRecord r in snapshot.readingHourly) {
      await _db.setReadingHourlyLog(
        dateKey: r.dateKey,
        hour: r.hour,
        readingTimeMs: r.durationMs,
      );
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
    for (final FavoriteWordRecord r in snapshot.favoriteWords) {
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
    final String json =
        jsonEncode(union.map((FavoriteSentence s) => s.toJson()).toList());
    await _db.setPref(_favoriteSentencesPrefKey, json);
  }
}
