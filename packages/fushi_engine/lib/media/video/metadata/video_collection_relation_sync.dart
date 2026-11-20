/// 把刮削源给出的系列关系（[VideoRelatedWork]）落进 `collection_relations`，并在
/// 目标作品入库 / 刮削完成时把纯刮削行升级成已绑定。
///
/// 写入时机只有两处，都不联网：
/// - 作品资料写库的统一出口 `VideoMetadataDatabaseStore.apply`（刮削成功落库时，
///   用本次响应里本来就有的关系）；
/// - 存量补填 [backfillScrapedCollectionRelations]（AniDB 读已落盘的
///   `AnimeDoc_{aid}.xml`，其余读 details 快照），挂在库管家 ⑤ 作品层之前。
///
/// 只有挂在**合集**上的作品能当起点（`collection_relations.collection_id` 非空）；
/// 挂在单个视频上的作品（散装电影）没有起点可存，跳过。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Value, Variable;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/metadata/video_related_works.dart';
import 'package:path/path.dart' as p;

/// 用 [related]（[source] 这个源给出的完整关系列表）整体替换合集 [collectionId]
/// 来自该源的关系行。返回写入的行数。
///
/// - 目标按外部 id 反查本机作品（[FushiDatabase.getVideoMetadataWorkByProviderIdentity]），
///   命中挂合集的作品就填 `targetCollectionId`（已绑定）；指回自己的跳过；
/// - 本轮反查不到、但旧行已绑定（用户手动绑过 / 之前反查到过）的保留旧绑定；
/// - 续作 / 前传之外的关系，目标在本机是电影（`media_type = movie`）就记成 `movie`；
/// - 同一合集同一 `(source, subjectId)` 只一行（表唯一键），重刮整体替换不残留。
Future<int> syncScrapedCollectionRelations(
  FushiDatabase db, {
  required int collectionId,
  required String source,
  required List<VideoRelatedWork> related,
}) async {
  final Map<String, int?> previousTargets = <String, int?>{
    for (final CollectionRelationRow r in await db.getCollectionRelations(
      collectionId,
    ))
      if (r.source == source) r.subjectId: r.targetCollectionId,
  };
  final List<CollectionRelationsCompanion> rows =
      <CollectionRelationsCompanion>[];
  final Set<String> seen = <String>{};
  for (final VideoRelatedWork r in related) {
    if (r.provider != source || !seen.add(r.externalId)) continue;
    final VideoMetadataWorkRow? target = await db
        .getVideoMetadataWorkByProviderIdentity(
          provider: source,
          externalId: r.externalId,
        );
    if (target != null && target.collectionId == collectionId) continue;
    final int? targetCollectionId =
        target?.collectionId ?? previousTargets[r.externalId];
    if (targetCollectionId == collectionId) continue;
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
        collectionId: collectionId,
        relationType: relationType,
        sortIndex: Value<int>(rows.length),
        targetCollectionId: Value<int?>(targetCollectionId),
        source: source,
        subjectId: r.externalId,
        title: title,
      ),
    );
  }
  await db.replaceSourceCollectionRelations(collectionId, source, rows);
  return rows.length;
}

/// 合集 [collectionId] 上的作品带着 [identities]（`(provider, externalId)`）入库 /
/// 刮完了：把别的合集里指向这些外部 id 的纯刮削行升级成已绑定。返回绑定的行数。
Future<int> bindCollectionRelationsToWork(
  FushiDatabase db, {
  required int collectionId,
  required Iterable<(String, String)> identities,
}) async {
  int bound = 0;
  for (final (String provider, String externalId) in identities.toSet()) {
    bound += await db.bindCollectionRelationsBySubject(
      provider,
      externalId,
      collectionId,
    );
  }
  return bound;
}

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

/// 存量补填：已经刮过的合集作品不重新联网也补出系列关系。
///
/// - 主源 AniDB：读 [aniDbXmlDirectory] 下的 `AnimeDoc_{aid}.xml`（刮削时落盘的
///   缓存）；没有文件再看 details 快照（新版刮的快照里带关系）；
/// - 主源 MAL：details 快照（Jikan `full` 原样，带 `relations`）；
/// - 主源 TMDB：快照只有 `belongs_to_collection` 的合集 id、没有成员，补不出。
/// 读不到关系信息的作品不动它已有的行。最后对全部合集作品的外部身份跑一遍升级绑定。
Future<CollectionRelationBackfillResult> backfillScrapedCollectionRelations(
  FushiDatabase db, {
  required AniDbXmlDirectoryResolver aniDbXmlDirectory,
}) async {
  final List<
    ({int collectionId, String provider, String externalId, String identityKey})
  >
  primaries =
      <
        ({
          int collectionId,
          String provider,
          String externalId,
          String identityKey,
        })
      >[
        for (final row
            in await db
                .customSelect(
                  'SELECT w.collection_id AS cid, i.provider AS provider, '
                  'i.external_id AS eid, i.identity_key AS ikey '
                  'FROM video_metadata_works w '
                  'JOIN video_metadata_provider_identities i '
                  'ON i.work_id = w.id AND i.is_primary = 1 '
                  'WHERE w.collection_id IS NOT NULL '
                  'ORDER BY w.collection_id',
                )
                .get())
          (
            collectionId: row.read<int>('cid'),
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
      collectionId: w.collectionId,
      source: w.provider,
      related: related,
    );
  }

  final Map<int, Set<(String, String)>> identitiesByCollection =
      <int, Set<(String, String)>>{};
  for (final row
      in await db
          .customSelect(
            'SELECT w.collection_id AS cid, i.provider AS provider, '
            'i.external_id AS eid '
            'FROM video_metadata_works w '
            'JOIN video_metadata_provider_identities i ON i.work_id = w.id '
            'WHERE w.collection_id IS NOT NULL',
          )
          .get()) {
    (identitiesByCollection[row.read<int>('cid')] ??= <(String, String)>{}).add(
      (row.read<String>('provider'), row.read<String>('eid')),
    );
  }
  int bound = 0;
  for (final MapEntry<int, Set<(String, String)>> e
      in identitiesByCollection.entries) {
    bound += await bindCollectionRelationsToWork(
      db,
      collectionId: e.key,
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
