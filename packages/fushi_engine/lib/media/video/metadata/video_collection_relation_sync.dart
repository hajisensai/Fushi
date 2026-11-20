/// 把刮削源给出的系列关系（[VideoRelatedWork]）落进 `collection_relations`，并在
/// 目标作品入库 / 刮削完成时把纯刮削行升级成已绑定。
///
/// 写入时机只有两处：
/// - 作品资料写库的统一出口 `VideoMetadataDatabaseStore.apply`（刮削成功落库时，
///   用本次响应里本来就有的关系；TMDB 电影的合集成员是刮削时随详情多打的一次
///   `/collection/{id}`，见 `TmdbVideoMetadataProvider.fetchWork`）；
/// - 存量补填 [backfillScrapedCollectionRelations]（AniDB 读已落盘的
///   `AnimeDoc_{aid}.xml`，其余读 details 快照），不联网。
///
/// 旧快照缺 TMDB 合集成员表时由 [refreshMissingTmdbCollectionParts] 按合集去重
/// 联网补上（只写快照里那一个键），批量入口见 `video_series_relation_refresh.dart`
/// 的 `refreshVideoSeriesRelations`（库管家 ⑤ 作品层 / 控制通道共用）。
///
/// 起点与已绑定目标都可以是合集或单视频（v162：挂在单个视频上的作品，散装电影），
/// 见 [VideoRelationOwner]。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show QueryRow, Table, TableInfo, Value, Variable;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/metadata/video_related_works.dart';
import 'package:path/path.dart' as p;

/// 系列关系在本机的一端：合集（[collectionId]）或单视频（[bookUid]），恰好一个。
///
/// 与 `video_metadata_works` 的归属同构：作品挂在合集上就是合集，挂在单个视频上
/// （散装电影）就是那个视频。
final class VideoRelationOwner {
  const VideoRelationOwner.collection(int this.collectionId) : bookUid = null;

  const VideoRelationOwner.video(String this.bookUid) : collectionId = null;

  /// 作品行的归属；两列都空（不该出现）返回 null。
  static VideoRelationOwner? ofWork(VideoMetadataWorkRow work) {
    if (work.collectionId case final int id) {
      return VideoRelationOwner.collection(id);
    }
    if (work.bookUid case final String uid when uid.isNotEmpty) {
      return VideoRelationOwner.video(uid);
    }
    return null;
  }

  /// 关系行的起点。
  static VideoRelationOwner? originOf(CollectionRelationRow row) {
    if (row.collectionId case final int id) {
      return VideoRelationOwner.collection(id);
    }
    if (row.bookUid case final String uid) return VideoRelationOwner.video(uid);
    return null;
  }

  /// 关系行的已绑定目标；纯刮削行返回 null。
  static VideoRelationOwner? targetOf(CollectionRelationRow row) {
    if (row.targetCollectionId case final int id) {
      return VideoRelationOwner.collection(id);
    }
    if (row.targetBookUid case final String uid) {
      return VideoRelationOwner.video(uid);
    }
    return null;
  }

  final int? collectionId;
  final String? bookUid;

  @override
  bool operator ==(Object other) =>
      other is VideoRelationOwner &&
      other.collectionId == collectionId &&
      other.bookUid == bookUid;

  @override
  int get hashCode => Object.hash(collectionId, bookUid);

  @override
  String toString() => collectionId != null
      ? 'VideoRelationOwner.collection($collectionId)'
      : 'VideoRelationOwner.video($bookUid)';
}

/// 用 [related]（[source] 这个源给出的完整关系列表）整体替换起点 [owner] 来自该源
/// 的关系行。返回写入的行数。
///
/// - 目标按外部 id 反查本机作品（[FushiDatabase.getVideoMetadataWorkByProviderIdentity]），
///   命中就按它的归属填 `targetCollectionId` / `targetBookUid`（已绑定）；指回
///   自己的跳过；TMDB 的电影与剧集 id 不同命名空间，`tmdb` 关系只认电影作品；
/// - 本轮反查不到、但旧行已绑定（用户手动绑过 / 之前反查到过）的保留旧绑定；
/// - 续作 / 前传之外的关系，目标在本机是电影（`media_type = movie`）就记成 `movie`；
/// - 同一起点同一 `(source, subjectId)` 只一行（表唯一键），重刮整体替换不残留。
Future<int> syncScrapedCollectionRelations(
  FushiDatabase db, {
  required VideoRelationOwner owner,
  required String source,
  required List<VideoRelatedWork> related,
}) async {
  final List<CollectionRelationRow> existing = owner.collectionId != null
      ? await db.getCollectionRelations(owner.collectionId!)
      : await db.getVideoBookRelations(owner.bookUid!);
  final Map<String, VideoRelationOwner?> previousTargets =
      <String, VideoRelationOwner?>{
        for (final CollectionRelationRow r in existing)
          if (r.source == source) r.subjectId: VideoRelationOwner.targetOf(r),
      };
  final List<CollectionRelationsCompanion> rows =
      <CollectionRelationsCompanion>[];
  final Set<String> seen = <String>{};
  for (final VideoRelatedWork r in related) {
    if (r.provider != source || !seen.add(r.externalId)) continue;
    VideoMetadataWorkRow? target = await db
        .getVideoMetadataWorkByProviderIdentity(
          provider: source,
          externalId: r.externalId,
        );
    if (source == 'tmdb' && target != null && target.mediaType != 'movie') {
      target = null;
    }
    final VideoRelationOwner? targetOwner = target == null
        ? null
        : VideoRelationOwner.ofWork(target);
    if (targetOwner == owner) continue;
    final VideoRelationOwner? bound =
        targetOwner ?? previousTargets[r.externalId];
    if (bound == owner) continue;
    final bool ordered =
        r.relationType == CollectionRelationWire.sequel ||
        r.relationType == CollectionRelationWire.prequel;
    final String relationType = !ordered && target?.mediaType == 'movie'
        ? CollectionRelationWire.movie
        : r.relationType;
    final String title = r.title.isNotEmpty
        ? r.title
        : (target?.title ?? '$source:${r.externalId}');
    rows.add(
      CollectionRelationsCompanion.insert(
        collectionId: Value<int?>(owner.collectionId),
        bookUid: Value<String?>(owner.bookUid),
        relationType: relationType,
        sortIndex: Value<int>(rows.length),
        targetCollectionId: Value<int?>(bound?.collectionId),
        targetBookUid: Value<String?>(bound?.bookUid),
        source: source,
        subjectId: r.externalId,
        title: title,
      ),
    );
  }
  if (owner.collectionId case final int collectionId) {
    await db.replaceSourceCollectionRelations(collectionId, source, rows);
  } else {
    await db.replaceSourceVideoBookRelations(owner.bookUid!, source, rows);
  }
  return rows.length;
}

/// [owner] 上的作品带着 [identities]（`(provider, externalId)`）入库 / 刮完了：把
/// 别处指向这些外部 id 的纯刮削行升级成已绑定。返回绑定的行数。
///
/// 调用方负责只传能当目标的身份（TMDB 剧集的 `tmdb` id 与电影不同命名空间，不传）。
Future<int> bindCollectionRelationsToWork(
  FushiDatabase db, {
  required VideoRelationOwner owner,
  required Iterable<(String, String)> identities,
}) async {
  int bound = 0;
  for (final (String provider, String externalId) in identities.toSet()) {
    if (owner.collectionId case final int collectionId) {
      bound += await db.bindCollectionRelationsBySubject(
        provider,
        externalId,
        collectionId,
      );
    } else {
      bound += await db.bindCollectionRelationsBySubjectToVideo(
        provider,
        externalId,
        owner.bookUid!,
      );
    }
  }
  return bound;
}

/// 作品的外部身份里哪些能当系列关系的目标：`tmdb` 只认电影（剧集 id 是另一个
/// 命名空间，TMDB 合集也只收电影），其余照收。
bool canBindRelationIdentity({
  required String provider,
  required String mediaType,
}) => provider != 'tmdb' || mediaType == 'movie';

/// 存量补填的结果（数字写进库管家 ⑤ 的结果备注 / 日志）。
typedef CollectionRelationBackfillResult = ({
  int works,
  int worksWithRelations,
  int rows,
  int bound,
});

/// 生产环境的 AniDB XML 缓存目录（与 `VideoMetadataProviderRegistry.production`
/// 同一处：`<support>/anidb_anime`）。
typedef AniDbXmlDirectoryResolver = Future<Directory?> Function();

/// 生产环境的 AniDB XML 缓存目录；宿主没装配 [enginePaths]（纯 Dart 测试）时 null。
Future<Directory?> productionAniDbXmlDirectory() async {
  if (enginePaths is UninstalledEnginePaths) return null;
  return Directory(
    p.join((await enginePaths.supportRootDirectory()).path, 'anidb_anime'),
  );
}

/// 存量补填：已经刮过的作品（挂合集的与挂单视频的都算）不重新联网也补出系列关系。
///
/// - 主源 AniDB：读 [aniDbXmlDirectory] 下的 `AnimeDoc_{aid}.xml`（刮削时落盘的
///   缓存）；没有文件再看 details 快照（新版刮的快照里带关系）；
/// - 主源 MAL：details 快照（Jikan `full` 原样，带 `relations`）；
/// - 主源 TMDB（电影）：details 快照里刮削时随附的合集成员；没有（旧快照 / 合集
///   请求失败）就不动。
/// 读不到关系信息的作品不动它已有的行。最后对全部作品的外部身份跑一遍升级绑定。
Future<CollectionRelationBackfillResult> backfillScrapedCollectionRelations(
  FushiDatabase db, {
  required AniDbXmlDirectoryResolver aniDbXmlDirectory,
}) async {
  final List<
    ({
      VideoRelationOwner owner,
      String provider,
      String externalId,
      String identityKey,
    })
  >
  primaries =
      <
        ({
          VideoRelationOwner owner,
          String provider,
          String externalId,
          String identityKey,
        })
      >[
        for (final QueryRow row
            in await db
                .customSelect(
                  'SELECT w.collection_id AS cid, w.book_uid AS uid, '
                  'i.provider AS provider, '
                  'i.external_id AS eid, i.identity_key AS ikey '
                  'FROM video_metadata_works w '
                  'JOIN video_metadata_provider_identities i '
                  'ON i.work_id = w.id AND i.is_primary = 1 '
                  'WHERE w.collection_id IS NOT NULL OR w.book_uid IS NOT NULL '
                  'ORDER BY w.collection_id, w.book_uid',
                )
                .get())
          if (_ownerOfRow(row) case final VideoRelationOwner owner)
            (
              owner: owner,
              provider: row.read<String>('provider'),
              externalId: row.read<String>('eid'),
              identityKey: row.read<String>('ikey'),
            ),
      ];
  Directory? xmlDir;
  bool xmlDirResolved = false;
  int worksWithRelations = 0;
  int rows = 0;
  for (final w in primaries) {
    List<VideoRelatedWork>? related;
    if (w.provider == 'anidb') {
      if (!xmlDirResolved) {
        xmlDirResolved = true;
        try {
          xmlDir = await aniDbXmlDirectory();
        } on Object {
          xmlDir = null;
        }
      }
      final Directory? dir = xmlDir;
      if (dir != null) {
        final File file = File(
          p.join(dir.path, 'AnimeDoc_${w.externalId}.xml'),
        );
        try {
          if (await file.exists()) {
            related = aniDbRelatedWorksFromXml(await file.readAsString());
          }
        } on FileSystemException {
          related = null;
        }
      }
    }
    related ??= await _relatedFromSnapshot(db, w.provider, w.identityKey);
    if (related == null) continue;
    if (related.isNotEmpty) worksWithRelations++;
    rows += await syncScrapedCollectionRelations(
      db,
      owner: w.owner,
      source: w.provider,
      related: related,
    );
  }

  final Map<VideoRelationOwner, Set<(String, String)>> identitiesByOwner =
      <VideoRelationOwner, Set<(String, String)>>{};
  for (final QueryRow row
      in await db
          .customSelect(
            'SELECT w.collection_id AS cid, w.book_uid AS uid, '
            'w.media_type AS media_type, i.provider AS provider, '
            'i.external_id AS eid '
            'FROM video_metadata_works w '
            'JOIN video_metadata_provider_identities i ON i.work_id = w.id '
            'WHERE w.collection_id IS NOT NULL OR w.book_uid IS NOT NULL',
          )
          .get()) {
    final VideoRelationOwner? owner = _ownerOfRow(row);
    if (owner == null) continue;
    final String provider = row.read<String>('provider');
    if (!canBindRelationIdentity(
      provider: provider,
      mediaType: row.read<String>('media_type'),
    )) {
      continue;
    }
    (identitiesByOwner[owner] ??= <(String, String)>{}).add((
      provider,
      row.read<String>('eid'),
    ));
  }
  int bound = 0;
  for (final MapEntry<VideoRelationOwner, Set<(String, String)>> e
      in identitiesByOwner.entries) {
    bound += await bindCollectionRelationsToWork(
      db,
      owner: e.key,
      identities: e.value,
    );
  }
  return (
    works: primaries.length,
    worksWithRelations: worksWithRelations,
    rows: rows,
    bound: bound,
  );
}

/// 为 TMDB 合集 [collectionId] 取精简成员表（`TmdbVideoMetadataProvider.fetchCollectionParts`
/// 的形状）。合集不存在 → null；失败抛出。
typedef TmdbCollectionPartsFetcher =
    Future<List<Map<String, Object?>>?> Function(int collectionId);

/// [refreshMissingTmdbCollectionParts] 的结果：
/// - [missing]：缺成员表的 TMDB 电影 details 快照数；
/// - [refreshed]：写回成员表的快照数；
/// - [requests]：实际发出的合集请求数（每个合集至多一次）；
/// - [failed]：合集请求失败、快照没动的电影数。
typedef TmdbCollectionPartsRefreshResult = ({
  int missing,
  int refreshed,
  int requests,
  int failed,
});

/// 存量补齐：旧版刮的 TMDB 电影 details 快照里只有 `belongs_to_collection.id`、
/// 没有合集成员表（[kTmdbCollectionPartsPayloadKey]），不联网的
/// [backfillScrapedCollectionRelations] 因此补不出前传 / 续作。这里按合集 id 去重，
/// 每个合集只请求一次 [fetchParts]，把成员表写回各自的快照（只改这一个键，作品其它
/// 资料、快照的 `fetched_at` 都不动）。
///
/// 只挑主身份是 `tmdb`、挂在合集或单视频上的作品；已经有成员表（键是 List）的快照
/// 不再请求，所以第二趟是 0 请求。合集 404（null）写回空成员表，同样不再重复请求。
/// 某个合集请求抛 [Exception] → 记日志、该合集下的电影计入 `failed`、快照不动，
/// 本函数不抛。
Future<TmdbCollectionPartsRefreshResult> refreshMissingTmdbCollectionParts(
  FushiDatabase db, {
  required TmdbCollectionPartsFetcher fetchParts,
}) async {
  final List<QueryRow> rows = await db
      .customSelect(
        'SELECT DISTINCT s.identity_key AS ikey, s.raw_json AS raw '
        'FROM video_metadata_works w '
        'JOIN video_metadata_provider_identities i '
        'ON i.work_id = w.id AND i.is_primary = 1 '
        'JOIN video_metadata_raw_snapshots s '
        "ON s.identity_key = i.identity_key AND s.snapshot_kind = 'details' "
        "WHERE i.provider = 'tmdb' "
        'AND (w.collection_id IS NOT NULL OR w.book_uid IS NOT NULL) '
        'ORDER BY s.identity_key',
      )
      .get();
  final Map<int, List<({String identityKey, Map<String, Object?> payload})>>
  byCollection =
      <int, List<({String identityKey, Map<String, Object?> payload})>>{};
  int missing = 0;
  for (final QueryRow row in rows) {
    final Object? decoded;
    try {
      decoded = jsonDecode(row.read<String>('raw'));
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final Map<String, Object?> payload = decoded.map(
      (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
    );
    if (payload[kTmdbCollectionPartsPayloadKey] is List) continue;
    final Object? collection = payload['belongs_to_collection'];
    if (collection is! Map) continue;
    final Object? rawId = collection['id'];
    final int? collectionId = switch (rawId) {
      final int id => id,
      final num id => id.toInt(),
      final String id => int.tryParse(id.trim()),
      _ => null,
    };
    if (collectionId == null) continue;
    missing++;
    (byCollection[collectionId] ??=
            <({String identityKey, Map<String, Object?> payload})>[])
        .add((identityKey: row.read<String>('ikey'), payload: payload));
  }

  int refreshed = 0;
  int requests = 0;
  int failed = 0;
  for (final MapEntry<
        int,
        List<({String identityKey, Map<String, Object?> payload})>
      >
      e
      in byCollection.entries) {
    final List<Map<String, Object?>>? parts;
    requests++;
    try {
      parts = await fetchParts(e.key);
    } on Exception catch (error, stack) {
      engineLog.log('videoRelations.tmdbCollection.${e.key}', error, stack);
      failed += e.value.length;
      continue;
    }
    for (final s in e.value) {
      s.payload[kTmdbCollectionPartsPayloadKey] =
          parts ?? const <Map<String, Object?>>[];
      await db.customUpdate(
        'UPDATE video_metadata_raw_snapshots SET raw_json = ? '
        "WHERE identity_key = ? AND snapshot_kind = 'details'",
        variables: <Variable<Object>>[
          Variable<String>(jsonEncode(s.payload)),
          Variable<String>(s.identityKey),
        ],
        updates: <TableInfo<Table, Object?>>{db.videoMetadataRawSnapshots},
      );
      refreshed++;
    }
  }
  return (
    missing: missing,
    refreshed: refreshed,
    requests: requests,
    failed: failed,
  );
}

VideoRelationOwner? _ownerOfRow(QueryRow row) {
  if (row.readNullable<int>('cid') case final int id) {
    return VideoRelationOwner.collection(id);
  }
  if (row.readNullable<String>('uid') case final String uid
      when uid.isNotEmpty) {
    return VideoRelationOwner.video(uid);
  }
  return null;
}

Future<List<VideoRelatedWork>?> _relatedFromSnapshot(
  FushiDatabase db,
  String provider,
  String identityKey,
) async {
  final List<QueryRow> snapshots = await db
      .customSelect(
        'SELECT raw_json FROM video_metadata_raw_snapshots '
        "WHERE identity_key = ? AND snapshot_kind = 'details'",
        variables: <Variable<Object>>[Variable<String>(identityKey)],
      )
      .get();
  if (snapshots.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(snapshots.first.read<String>('raw_json'));
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  return relatedWorksFromRawPayload(
    provider,
    decoded.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
  );
}
