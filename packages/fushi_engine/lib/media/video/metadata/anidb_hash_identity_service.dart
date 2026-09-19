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
      AnidbFileIdentityStore? store,
      DateTime Function()? now,
      this.maxCachedHashes = 512})
      : assert(maxCachedHashes > 0),
        _mapping = mapping ?? AnimeIdentityMapping(),
        _ownsMapping = mapping == null,
        _client = client ?? AnidbUdpFileClient(config: config),
        _hasher = hasher ?? hashAnidbFile,
        _lookup = lookup,
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
          return _fromRecord(known, stat, isCancelled);
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
          await store.save(_recordFor(hash, known.identity, absolutePath,
              resolvedAt: known.resolvedAt, missAttempts: known.missAttempts));
          return _fromRecord(known, stat, isCancelled);
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
      await store
          ?.save(_recordFor(hash, identity, absolutePath, resolvedAt: now));
      AnimeIdentityMappingResult? mapping;
      Object? mappingError;
      try {
        mapping = await _mapping.lookupAnidb(identity.animeId);
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
          identity: identity,
          matchedEd2k: matchedEd2k,
          mapping: mapping,
          mappingError: mappingError);
    } on AnidbHashCancelled {
      return AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.cancelled, hash: hash);
    } catch (error) {
      return AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.failed, hash: hash, error: error);
    }
  }

  /// 持久层记录 → 与在线路径同形的结果；Fribb 映射照查（本地表，便宜），
  /// 这样调用方不用区分「刚问的」与「早就知道的」。
  Future<AnidbHashIdentityResult> _fromRecord(AnidbFileIdentityRecord record,
      FileStat stat, bool Function()? isCancelled) async {
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
