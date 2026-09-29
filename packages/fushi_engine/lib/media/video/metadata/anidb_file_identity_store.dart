import 'dart:convert';

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
    this.missAttempts = 0,
  });

  final String ed2k;
  final int size;
  final AnidbFileIdentity? identity;
  final String? filePath;
  final DateTime? fileModifiedAt;
  final DateTime resolvedAt;

  /// FILE 连续回 320 的次数（识别成功即归零）。
  final int missAttempts;

  bool get isMatch => identity != null;

  /// 未收录的记录是否还不该再问：Shoko `CheckAniDBFileUpdatesJob` 按
  /// `File_UpdateFrequency`（默认每日）重扫未识别文件，尝试次数超过
  /// `MaxAutoScanAttemptsPerFile`（默认 15）就不再自动重扫。AniDB 收录新文件
  /// 通常在几天内，每日一问既跟得上又不刷服务器。
  bool isFreshMiss(DateTime now) =>
      identity == null &&
      (missAttempts >= maxMissAttempts ||
          now.difference(resolvedAt) < unknownFileRecheck);

  /// 复查次数用尽：不再自动问 AniDB（换文件内容会有新键，自然重来）。
  bool get isExhaustedMiss =>
      identity == null && missAttempts >= maxMissAttempts;

  static const Duration unknownFileRecheck = Duration(days: 1);
  static const int maxMissAttempts = 15;
}

/// `other_episodes` 列的编码：`[[eid, 百分比], …]`，空列表存 `''`。
String encodeOtherEpisodes(List<AnidbEpisodeShare> shares) => shares.isEmpty
    ? ''
    : jsonEncode(<List<Object?>>[
        for (final AnidbEpisodeShare share in shares)
          // 未问到集信息：`[eid, pct]`；问到了：再接 `epno, airedMs|null,
          // eng, romaji, kanji`（同一列两种长度并存，v109 存量行照旧可读）。
          if (share.episodeNumber case final String epno)
            <Object?>[
              share.episodeId,
              share.percentage,
              epno,
              share.airedAt?.millisecondsSinceEpoch,
              share.englishTitle ?? '',
              share.romajiTitle ?? '',
              share.kanjiTitle ?? '',
            ]
          else
            <Object?>[share.episodeId, share.percentage],
      ]);

/// [encodeOtherEpisodes] 的逆；坏数据当空（身份主列不受影响）。
List<AnidbEpisodeShare> decodeOtherEpisodes(String raw) {
  if (raw.trim().isEmpty) return const <AnidbEpisodeShare>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <AnidbEpisodeShare>[];
  }
  if (decoded is! List) return const <AnidbEpisodeShare>[];
  return <AnidbEpisodeShare>[
    for (final Object? item in decoded)
      if (item is List &&
          (item.length == 2 || item.length == 7) &&
          item[0] is int &&
          item[1] is int &&
          (item[0] as int) > 0)
        if (item.length == 2 || item[2] is! String)
          AnidbEpisodeShare(
              episodeId: item[0] as int, percentage: item[1] as int)
        else
          AnidbEpisodeShare(
            episodeId: item[0] as int,
            percentage: item[1] as int,
            episodeNumber: item[2] as String,
            airedAt: item[3] is int
                ? DateTime.fromMillisecondsSinceEpoch(item[3] as int,
                    isUtc: true)
                : null,
            englishTitle: item[4] is String ? item[4] as String : '',
            romajiTitle: item[5] is String ? item[5] as String : '',
            kanjiTitle: item[6] is String ? item[6] as String : '',
          ),
  ];
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

/// Drift 实现：`anidb_file_identities`（schema v106，v108 加 `miss_attempts`，
/// v109 加 `episode_aired_at`）。
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
      episodeAiredAt:
          Value(identity?.episodeAiredAt?.toUtc().millisecondsSinceEpoch),
      otherEpisodes: Value(encodeOtherEpisodes(
          identity?.otherEpisodes ?? const <AnidbEpisodeShare>[])),
      isDeprecated: Value(identity?.isDeprecated ?? false),
      fileState: Value(identity?.fileState ?? 0),
      animeType: Value(identity?.animeType ?? ''),
      filePath: Value(record.filePath),
      fileModifiedAt: Value(record.fileModifiedAt?.millisecondsSinceEpoch),
      missAttempts: Value(identity == null ? record.missAttempts : 0),
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
              episodeAiredAt: row.episodeAiredAt == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(row.episodeAiredAt!,
                      isUtc: true),
              otherEpisodes: decodeOtherEpisodes(row.otherEpisodes),
              isDeprecated: row.isDeprecated,
              fileState: row.fileState,
              animeType: row.animeType,
            ),
      filePath: row.filePath,
      fileModifiedAt: row.fileModifiedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.fileModifiedAt!),
      resolvedAt: DateTime.fromMillisecondsSinceEpoch(row.resolvedAt),
      missAttempts: row.missAttempts,
    );
  }
}
