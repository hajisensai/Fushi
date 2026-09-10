import 'dart:collection';
import 'dart:io';

import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
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
      this.mappingError});
  final AnidbHashIdentityStatus status;
  final AnidbEd2kHash? hash;
  final AnidbFileIdentity? identity;

  /// The exact FILE query hash that returned this identity, including variants.
  final String? matchedEd2k;
  final AnimeIdentityMappingResult? mapping;
  final Object? error;
  final Object? mappingError;
  int? get confirmedMalId => mapping?.confirmedMalId;
}

typedef AnidbFileHasher = Future<AnidbEd2kHash> Function(String path,
    {bool Function()? isCancelled, void Function(int, int)? onProgress});
typedef AnidbIdentityLookup = Future<AnidbFileIdentity?> Function(
    {required int size, required String ed2k});

/// Hashing is strictly opt-in and requires a registered, configured UDP client.
/// A positive FILE response remains a match even if MAL mapping is unavailable.
class AnidbHashIdentityService {
  AnidbHashIdentityService(
      {required this.enabled,
      required this.config,
      AnimeIdentityMapping? mapping,
      AnidbUdpFileClient? client,
      AnidbFileHasher? hasher,
      AnidbIdentityLookup? lookup,
      this.maxCachedHashes = 512})
      : assert(maxCachedHashes > 0),
        _mapping = mapping ?? AnimeIdentityMapping(),
        _ownsMapping = mapping == null,
        _client = client ?? AnidbUdpFileClient(config: config),
        _hasher = hasher ?? hashAnidbFile,
        _lookup = lookup;

  final bool enabled;
  final AnidbUdpConfig config;
  final int maxCachedHashes;
  final AnimeIdentityMapping _mapping;
  final bool _ownsMapping;
  final AnidbUdpFileClient _client;
  final AnidbFileHasher _hasher;
  final AnidbIdentityLookup? _lookup;
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
        return AnidbHashIdentityResult(
            status: AnidbHashIdentityStatus.notFound, hash: hash);
      }
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

  static void _checkCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) throw const AnidbHashCancelled();
  }

  Future<void> close() async {
    await _client.close();
    if (_ownsMapping) _mapping.close();
    _hashes.clear();
  }
}
