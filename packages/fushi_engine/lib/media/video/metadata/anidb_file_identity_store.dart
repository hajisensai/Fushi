import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';

/// 一份内容在 AniDB 的持久身份（对齐 Shoko：键是 `(ed2k, size)`，路径附属）。
///
/// [identity] 为 null 表示 AniDB 尚未收录该哈希（FILE 回 320）；[resolvedAt]
/// 是最近一次问 AniDB 的时刻，未收录的行到期后要再问一次。
class AnidbFileIdentityRecord {
  const AnidbFileIdentityRecord({
    required this.ed2k,
    required this.size,
    required this.resolvedAt,
    this.identity,
    this.filePath,
    this.fileModifiedAt,
  });

  final String ed2k;
  final int size;
  final AnidbFileIdentity? identity;
  final String? filePath;
  final DateTime? fileModifiedAt;
  final DateTime resolvedAt;

  bool get isMatch => identity != null;

  /// 未收录的记录是否还没到复查期：AniDB 收录有滞后，一周后再问一次。
  bool isFreshMiss(DateTime now) =>
      identity == null && now.difference(resolvedAt) < unknownFileRecheck;

  static const Duration unknownFileRecheck = Duration(days: 7);
}

/// 文件级 AniDB 身份的持久层；[AnidbHashIdentityService] 先查它再算哈希 / 发 FILE。
abstract interface class AnidbFileIdentityStore {
  /// 按「路径 + 大小」取最近一次记下的身份（免重算哈希）；[modifiedAt] 不同
  /// 视为内容换过，返回 null。
  Future<AnidbFileIdentityRecord?> findForFile({
    required String filePath,
    required int size,
    required DateTime modifiedAt,
  });

  /// 按内容键取身份（文件搬家 / 改名后哈希仍能命中）。
  Future<AnidbFileIdentityRecord?> findByHash({
    required String ed2k,
    required int size,
  });

  Future<void> save(AnidbFileIdentityRecord record);
}

/// Drift 实现：`anidb_file_identities`（schema v106）。
class AnidbFileIdentityDatabaseStore implements AnidbFileIdentityStore {
  AnidbFileIdentityDatabaseStore(this._database);

  final FushiDatabase _database;

  @override
  Future<AnidbFileIdentityRecord?> findForFile({
    required String filePath,
    required int size,
    required DateTime modifiedAt,
  }) async {
    final AnidbFileIdentityRow? row = await _database.anidbFileIdentityByPath(
      filePath: filePath,
      fileSize: size,
    );
    if (row == null ||
        row.fileModifiedAt != modifiedAt.millisecondsSinceEpoch) {
      return null;
    }
    return _fromRow(row);
  }

  @override
  Future<AnidbFileIdentityRecord?> findByHash({
    required String ed2k,
    required int size,
  }) async {
    final AnidbFileIdentityRow? row = await _database.anidbFileIdentityByHash(
      ed2k: ed2k,
      fileSize: size,
    );
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<void> save(AnidbFileIdentityRecord record) {
    final AnidbFileIdentity? identity = record.identity;
    return _database.upsertAnidbFileIdentity(AnidbFileIdentitiesCompanion(
      ed2k: Value(record.ed2k.toLowerCase()),
      fileSize: Value(record.size),
      anidbFileId: Value(identity?.fileId),
      anidbAnimeId: Value(identity?.animeId),
      anidbEpisodeId: Value(identity?.episodeId),
      episodeNumber: Value(identity?.episodeNumber ?? ''),
      romajiTitle: Value(identity?.romajiTitle ?? ''),
      kanjiTitle: Value(identity?.kanjiTitle ?? ''),
      englishTitle: Value(identity?.englishTitle ?? ''),
      episodeTitle: Value(identity?.episodeTitle ?? ''),
      episodeRomajiTitle: Value(identity?.episodeRomajiTitle ?? ''),
      episodeKanjiTitle: Value(identity?.episodeKanjiTitle ?? ''),
      filePath: Value(record.filePath),
      fileModifiedAt: Value(record.fileModifiedAt?.millisecondsSinceEpoch),
      resolvedAt: Value(record.resolvedAt.millisecondsSinceEpoch),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
  }

  static AnidbFileIdentityRecord _fromRow(AnidbFileIdentityRow row) {
    final int? fileId = row.anidbFileId;
    final int? animeId = row.anidbAnimeId;
    final int? episodeId = row.anidbEpisodeId;
    return AnidbFileIdentityRecord(
      ed2k: row.ed2k,
      size: row.fileSize,
      identity: fileId == null || animeId == null || episodeId == null
          ? null
          : AnidbFileIdentity(
              fileId: fileId,
              animeId: animeId,
              episodeId: episodeId,
              episodeNumber: row.episodeNumber,
              romajiTitle: row.romajiTitle,
              kanjiTitle: row.kanjiTitle,
              englishTitle: row.englishTitle,
              episodeTitle: row.episodeTitle,
              episodeRomajiTitle: row.episodeRomajiTitle,
              episodeKanjiTitle: row.episodeKanjiTitle,
            ),
      filePath: row.filePath,
      fileModifiedAt: row.fileModifiedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.fileModifiedAt!),
      resolvedAt: DateTime.fromMillisecondsSinceEpoch(row.resolvedAt),
    );
  }
}
