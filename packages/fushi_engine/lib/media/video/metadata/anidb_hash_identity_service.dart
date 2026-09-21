import 'dart:collection';
import 'dart:io';

import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_file_identity_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';

enum AnidbHashIdentityStatus {
  disabled,
  unavailable,
  notFound,
  matched,
  failed,
  cancelled
}

class AnidbHashIdentityResult {
  const AnidbHashIdentityResult(
      {required this.status,
      this.hash,
      this.identity,
      this.matchedEd2k,
      this.mapping,
      this.error,
      this.mappingError,
      this.episodeInfoError,
      this.fromStore = false,
      this.missAttempts = 0,
      this.missExhausted = false});
  final AnidbHashIdentityStatus status;
  final AnidbEd2kHash? hash;
  final AnidbFileIdentity? identity;

  /// The exact FILE query hash that returned this identity, including variants.
  final String? matchedEd2k;
  final AnimeIdentityMappingResult? mapping;
  final Object? error;
  final Object? mappingError;

  /// 身份已确立、但补问集播出日（UDP `EPISODE`）失败；身份照样有效，只是
  /// 这一轮集级链接少了播出日这一评级维度，下次 sweep 再补。
  final Object? episodeInfoError;
  int? get confirmedMalId => mapping?.confirmedMalId;

  /// 这次结果是从持久层直接复用的（没算哈希、没发 FILE）。
  final bool fromStore;

  /// `notFound` 时：这份内容连续被 AniDB 回 320 的次数，以及是否已用尽自动
  /// 复查次数（Shoko `MaxAutoScanAttemptsPerFile` 15）。
  final int missAttempts;
  final bool missExhausted;
}

typedef AnidbFileHasher = Future<AnidbEd2kHash> Function(String path,
    {bool Function()? isCancelled, void Function(int, int)? onProgress});
typedef AnidbIdentityLookup = Future<AnidbFileIdentity?> Function(
    {required int size, required String ed2k});
typedef AnidbEpisodeLookup = Future<AnidbEpisodeInfo?> Function(
    {required int episodeId});

/// 按 (aid, eid) 取集信息的**首选**来源——AniDB HTTP anime XML（Shoko 路径：
/// 一次拿全集播出日 / 集名，本地缓存 24h）。返回 null / 抛错 → 退到 UDP `EPISODE`。
typedef AnidbEpisodeInfoSource = Future<AnidbEpisodeInfo?> Function(
    {required int animeId, required int episodeId});

/// Hashing is strictly opt-in and requires a registered, configured UDP client.
/// A positive FILE response remains a match even if MAL mapping is unavailable.
///
/// 对齐 Shoko 的文件级流程：先查持久层 [AnidbFileIdentityStore]（路径 + 大小 +
/// mtime 命中免哈希；哈希后按内容键命中免 FILE），只有真正没见过的内容才算
/// ED2K、发 FILE，结果（含 320 未收录）写回持久层。
class AnidbHashIdentityService {
  AnidbHashIdentityService(
      {required this.enabled,
      required this.config,
      AnimeIdentityMapping? mapping,
      AnidbUdpFileClient? client,
      AnidbFileHasher? hasher,
      AnidbIdentityLookup? lookup,
      AnidbEpisodeLookup? episodeLookup,
      AnidbEpisodeInfoSource? episodeInfoSource,
      AnidbFileIdentityStore? store,
      DateTime Function()? now,
      this.maxCachedHashes = 512})
      : assert(maxCachedHashes > 0),
        _mapping = mapping ?? AnimeIdentityMapping(),
        _ownsMapping = mapping == null,
        _client = client ?? AnidbUdpFileClient(config: config),
        _hasher = hasher ?? hashAnidbFile,
        _lookup = lookup,
        _episodeLookup = episodeLookup,
        _episodeInfoSource = episodeInfoSource,
        _store = store,
        _now = now ?? DateTime.now;

  final bool enabled;
  final AnidbUdpConfig config;
  final int maxCachedHashes;
  final AnimeIdentityMapping _mapping;
  final bool _ownsMapping;
  final AnidbUdpFileClient _client;
  final AnidbFileHasher _hasher;
  final AnidbIdentityLookup? _lookup;
  final AnidbEpisodeLookup? _episodeLookup;
  final AnidbEpisodeInfoSource? _episodeInfoSource;
  final AnidbFileIdentityStore? _store;
  final DateTime Function() _now;
  final LinkedHashMap<String, AnidbEd2kHash> _hashes =
      LinkedHashMap<String, AnidbEd2kHash>();
  bool get isConfigured => config.isAvailable;

  Future<AnidbHashIdentityResult> identifyFile(String path,
      {bool Function()? isCancelled,
      void Function(int, int)? onProgress}) async {
    if (!enabled) {
      return const AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.disabled);
    }
    if (!isConfigured) {
      return const AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.unavailable);
    }
    AnidbEd2kHash? hash;
    try {
      _checkCancelled(isCancelled);
      final String absolutePath = File(path).absolute.path;
      final FileStat stat = await File(absolutePath).stat();
      final AnidbFileIdentityStore? store = _store;
      final DateTime now = _now();
      // 到期复查的 320 行：把已累计的复查次数带到这一轮（Shoko 每文件计数）。
      int missAttempts = 0;
      // 持久层快路径：同路径、同大小、同 mtime 就是上次那份内容，直接复用。
      if (store != null && stat.type == FileSystemEntityType.file) {
        final AnidbFileIdentityRecord? known = await store.findForFile(
            filePath: absolutePath, size: stat.size, modifiedAt: stat.modified);
        if (known != null && (known.isMatch || known.isFreshMiss(now))) {
          onProgress?.call(stat.size, stat.size);
          final _BackfilledRecord filled =
              await _backfillEpisodeAirDate(known, store);
          return _fromRecord(filled.record, stat, isCancelled,
              episodeInfoError: filled.error);
        }
        if (known != null) missAttempts = known.missAttempts;
      }
      hash = _hashes.remove(absolutePath);
      if (hash == null ||
          stat.type != FileSystemEntityType.file ||
          stat.size != hash.size ||
          stat.modified != hash.modifiedAt ||
          stat.changed != hash.changedAt) {
        hash = await _hasher(absolutePath,
            isCancelled: isCancelled, onProgress: onProgress);
      } else {
        onProgress?.call(hash.size, hash.size);
      }
      _checkCancelled(isCancelled);
      _hashes[absolutePath] = hash;
      while (_hashes.length > maxCachedHashes) {
        _hashes.remove(_hashes.keys.first);
      }
      // 文件搬家 / 改名：内容键照样命中，只把路径提示更新到新位置。
      if (store != null) {
        final AnidbFileIdentityRecord? known =
            await store.findByHash(ed2k: hash.ed2k, size: hash.size);
        if (known != null && (known.isMatch || known.isFreshMiss(now))) {
          final AnidbFileIdentityRecord moved = _recordFor(
              hash, known.identity, absolutePath,
              resolvedAt: known.resolvedAt, missAttempts: known.missAttempts);
          await store.save(moved);
          final _BackfilledRecord filled =
              await _backfillEpisodeAirDate(moved, store);
          return _fromRecord(filled.record, stat, isCancelled,
              episodeInfoError: filled.error);
        }
        if (known != null) missAttempts = known.missAttempts;
      }
      final AnidbIdentityLookup lookup = _lookup ?? _client.lookup;
      AnidbFileIdentity? identity =
          await lookup(size: hash.size, ed2k: hash.ed2k);
      String? matchedEd2k = identity == null ? null : hash.ed2k;
      _checkCancelled(isCancelled);
      final String? alternate = hash.alternativeEd2k;
      if (identity == null && alternate != null && alternate != hash.ed2k) {
        identity = await lookup(size: hash.size, ed2k: alternate);
        if (identity != null) matchedEd2k = alternate;
        _checkCancelled(isCancelled);
      }
      if (identity == null) {
        await store?.save(_recordFor(hash, null, absolutePath,
            resolvedAt: now, missAttempts: missAttempts + 1));
        return AnidbHashIdentityResult(
            status: AnidbHashIdentityStatus.notFound,
            hash: hash,
            missAttempts: missAttempts + 1);
      }
      // Shoko 集级链接要 AniDB 集播出日，FILE 应答里没有，紧接着按 eid 问一次
      // EPISODE 再落库；一文件多集时其余集的集号 / 集名 / 播出日也只有 EPISODE
      // 能给，一起问。问不到不影响身份本身。
      Object? episodeInfoError;
      AnidbFileIdentity resolved = identity;
      try {
        resolved = await _withEpisodeInfo(resolved);
      } on Object catch (error) {
        episodeInfoError = error;
      }
      await store
          ?.save(_recordFor(hash, resolved, absolutePath, resolvedAt: now));
      AnimeIdentityMappingResult? mapping;
      Object? mappingError;
      try {
        mapping = await _mapping.lookupAnidb(resolved.animeId);
      } catch (error) {
        mappingError = error;
      }
      _checkCancelled(isCancelled);
      final FileStat current = await File(absolutePath).stat();
      if (current.type != FileSystemEntityType.file ||
          current.size != hash.size ||
          current.modified != hash.modifiedAt ||
          current.changed != hash.changedAt) {
        _hashes.remove(absolutePath);
        throw FileSystemException(
            'File changed while resolving AniDB identity', absolutePath);
      }
      return AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: hash,
          identity: resolved,
          matchedEd2k: matchedEd2k,
          mapping: mapping,
          mappingError: mappingError,
          episodeInfoError: episodeInfoError);
    } on AnidbHashCancelled {
      return AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.cancelled, hash: hash);
    } catch (error) {
      return AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.failed, hash: hash, error: error);
    }
  }

  /// 已识别但还没有集播出日 / 其余集集信息的记录（v109 之前落的行 / 上次
  /// EPISODE 没答）：补问一次并写回；失败把错误随结果带出、身份照旧。AniDB 本
  /// 就没登记播出日（`aired` = 0）的集仍是 null，客户端寿命内不会重复问同一个
  /// eid。
  Future<_BackfilledRecord> _backfillEpisodeAirDate(
      AnidbFileIdentityRecord record, AnidbFileIdentityStore store) async {
    final AnidbFileIdentity? identity = record.identity;
    if (identity == null ||
        (identity.episodeAiredAt != null &&
            !identity.hasUnresolvedOtherEpisodes)) {
      return _BackfilledRecord(record);
    }
    final AnidbFileIdentity filled;
    try {
      filled = await _withEpisodeInfo(identity);
    } on Object catch (error) {
      return _BackfilledRecord(record, error: error);
    }
    if (identical(filled, identity)) return _BackfilledRecord(record);
    final AnidbFileIdentityRecord updated = AnidbFileIdentityRecord(
        ed2k: record.ed2k,
        size: record.size,
        identity: filled,
        filePath: record.filePath,
        fileModifiedAt: record.fileModifiedAt,
        resolvedAt: record.resolvedAt,
        missAttempts: record.missAttempts);
    await store.save(updated);
    return _BackfilledRecord(updated);
  }

  /// 按 eid 问 EPISODE：主集取播出日，其余集（一文件多集）取集号 / 播出日 /
  /// 三语集名；都齐了或 AniDB 回 340 时原样返回。注入了 FILE 假实现
  /// （[_lookup]）却没注入 EPISODE 的调用方视为把 AniDB 侧整体换掉了：不补问，
  /// 绝不因此去开真 socket。
  Future<AnidbFileIdentity> _withEpisodeInfo(AnidbFileIdentity identity) async {
    final bool needMain = identity.episodeAiredAt == null;
    if (!needMain && !identity.hasUnresolvedOtherEpisodes) return identity;
    final AnidbEpisodeLookup? udp =
        _episodeLookup ?? (_lookup == null ? _client.episode : null);
    final AnidbEpisodeInfoSource? xml = _episodeInfoSource;
    if (udp == null && xml == null) return identity;
    // Shoko 路径优先：anime XML 里整部作品的集都在（一次请求、24h 缓存）；XML 拿
    // 不到这一集（作品未收录 / HTTP 链不可用）再按 eid 走 UDP EPISODE。
    Future<AnidbEpisodeInfo?> lookup({required int episodeId}) async {
      if (xml != null) {
        try {
          final AnidbEpisodeInfo? fromXml =
              await xml(animeId: identity.animeId, episodeId: episodeId);
          if (fromXml != null) return fromXml;
        } on Object {
          // XML 链失败不影响 UDP 兜底。
        }
      }
      return udp == null ? null : udp(episodeId: episodeId);
    }

    AnidbFileIdentity result = identity;
    if (needMain) {
      final AnidbEpisodeInfo? info =
          await lookup(episodeId: identity.episodeId);
      if (info?.airedAt case final DateTime aired) {
        result = result.copyWith(episodeAiredAt: aired);
      }
    }
    if (identity.hasUnresolvedOtherEpisodes) {
      bool changed = false;
      final List<AnidbEpisodeShare> shares = <AnidbEpisodeShare>[];
      for (final AnidbEpisodeShare share in identity.otherEpisodes) {
        if (share.isResolved) {
          shares.add(share);
          continue;
        }
        final AnidbEpisodeInfo? info = await lookup(episodeId: share.episodeId);
        if (info == null) {
          shares.add(share);
          continue;
        }
        shares.add(share.withInfo(info));
        changed = true;
      }
      if (changed) result = result.copyWith(otherEpisodes: shares);
    }
    return result;
  }

  /// 持久层记录 → 与在线路径同形的结果；Fribb 映射照查（本地表，便宜），
  /// 这样调用方不用区分「刚问的」与「早就知道的」。
  Future<AnidbHashIdentityResult> _fromRecord(AnidbFileIdentityRecord record,
      FileStat stat, bool Function()? isCancelled,
      {Object? episodeInfoError}) async {
    final AnidbEd2kHash hash = AnidbEd2kHash(
        ed2k: record.ed2k,
        size: record.size,
        modifiedAt: stat.modified,
        changedAt: stat.changed);
    final AnidbFileIdentity? identity = record.identity;
    if (identity == null) {
      return AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.notFound,
          hash: hash,
          fromStore: true,
          missAttempts: record.missAttempts,
          missExhausted: record.isExhaustedMiss);
    }
    AnimeIdentityMappingResult? mapping;
    Object? mappingError;
    try {
      mapping = await _mapping.lookupAnidb(identity.animeId);
    } catch (error) {
      mappingError = error;
    }
    _checkCancelled(isCancelled);
    return AnidbHashIdentityResult(
        status: AnidbHashIdentityStatus.matched,
        hash: hash,
        identity: identity,
        matchedEd2k: record.ed2k,
        mapping: mapping,
        mappingError: mappingError,
        episodeInfoError: episodeInfoError,
        fromStore: true);
  }

  static AnidbFileIdentityRecord _recordFor(
          AnidbEd2kHash hash, AnidbFileIdentity? identity, String absolutePath,
          {required DateTime resolvedAt, int missAttempts = 0}) =>
      AnidbFileIdentityRecord(
          ed2k: hash.ed2k,
          size: hash.size,
          identity: identity,
          filePath: absolutePath,
          fileModifiedAt: hash.modifiedAt,
          resolvedAt: resolvedAt,
          missAttempts: identity == null ? missAttempts : 0);

  static void _checkCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const AnidbHashCancelled();
  }

  Future<void> close() async {
    await _client.close();
    if (_ownsMapping) _mapping.close();
    _hashes.clear();
  }
}

/// [AnidbHashIdentityService._backfillEpisodeAirDate] 的结果：可能已补上播出
/// 日的记录 + 补问失败时的错误（身份本身不受影响）。
class _BackfilledRecord {
  const _BackfilledRecord(this.record, {this.error});
  final AnidbFileIdentityRecord record;
  final Object? error;
}
