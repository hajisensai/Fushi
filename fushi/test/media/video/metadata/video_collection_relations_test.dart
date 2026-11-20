import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_collection_relation_sync.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_related_works.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:test/test.dart';

/// 刮削源系列关系 → `collection_relations`：AniDB XML / MAL relations 的映射（纯
/// 函数）、写库幂等与升级绑定、作品资料写库出口（store.apply）、存量补填；v162 起
/// 起点 / 已绑定目标可以是单视频（散装电影），TMDB 电影读合集成员。
const String _xml = '''
<anime id="100" restricted="false">
  <type>TV Series</type>
  <titles><title xml:lang="x-jat" type="main">Show</title></titles>
  <relatedanime>
    <anime id="200" type="Sequel">Show 2</anime>
    <anime id="50" type="Prequel">Show 0</anime>
    <anime id="300" type="Side Story">Show Gaiden</anime>
    <anime id="400" type="Parent Story">Big Show</anime>
    <anime id="500" type="Summary">Show Recap</anime>
    <anime id="600" type="Alternative Version">Show Remake</anime>
    <anime id="700" type="Character">Show Cameo</anime>
    <anime id="200" type="Sequel">duplicate</anime>
    <anime id="x" type="Sequel">bad id</anime>
  </relatedanime>
</anime>
''';

Map<String, Object?> _malItem() => <String, Object?>{
  'mal_id': 1,
  'relations': <Object?>[
    <String, Object?>{
      'relation': 'Sequel',
      'entry': <Object?>[
        <String, Object?>{'mal_id': 2, 'type': 'anime', 'name': 'Show 2'},
      ],
    },
    <String, Object?>{
      'relation': 'Adaptation',
      'entry': <Object?>[
        <String, Object?>{'mal_id': 9, 'type': 'manga', 'name': 'Show manga'},
      ],
    },
    <String, Object?>{
      'relation': 'Spin-Off',
      'entry': <Object?>[
        <String, Object?>{'mal_id': 3, 'type': 'anime', 'name': 'Show Chibi'},
      ],
    },
    <String, Object?>{
      'relation': 'Side Story',
      'entry': <Object?>[
        <String, Object?>{'mal_id': 4, 'type': 'anime', 'name': 'Show OVA'},
      ],
    },
  ],
};

void main() {
  group('映射（纯函数）', () {
    test('AniDB relatedanime：全部类型映射到六个落库值，同 aid 去重、坏 id 丢弃', () {
      final List<VideoRelatedWork> related = aniDbRelatedWorksFromXml(_xml)!;
      expect(
        <String>[
          for (final VideoRelatedWork r in related)
            '${r.externalId}:${r.relationType}:${r.title}',
        ],
        <String>[
          '200:sequel:Show 2',
          '50:prequel:Show 0',
          '300:side_story:Show Gaiden',
          '400:other:Big Show',
          '500:other:Show Recap',
          '600:other:Show Remake',
          '700:other:Show Cameo',
        ],
      );
      expect(
        related.every((VideoRelatedWork r) => r.provider == 'anidb'),
        isTrue,
      );
    });

    test('AniDB 错误响应 / 坏 XML → null（与「没有相关作品」区分）', () {
      expect(aniDbRelatedWorksFromXml('<error>banned</error>'), isNull);
      expect(aniDbRelatedWorksFromXml('not xml <'), isNull);
      expect(
        aniDbRelatedWorksFromXml('<anime id="1"><titles/></anime>'),
        isEmpty,
      );
    });

    test('MAL relations：只取 anime 条目，Spin-Off → spin_off', () {
      expect(
        <String>[
          for (final VideoRelatedWork r in malRelatedWorksFromItem(_malItem()))
            '${r.externalId}:${r.relationType}',
        ],
        <String>['2:sequel', '3:spin_off', '4:side_story'],
      );
    });

    test('rawPayload：没带关系信息返回 null，带了（含空表）才算权威', () {
      expect(
        relatedWorksFromRawPayload('anidb', <String, Object?>{'aid': 1}),
        isNull,
      );
      expect(
        relatedWorksFromRawPayload('tmdb', <String, Object?>{'id': 1}),
        isNull,
      );
      expect(relatedWorksFromRawPayload('anidb', null), isNull);
      expect(
        relatedWorksFromRawPayload('anidb', <String, Object?>{
          kAniDbRelatedPayloadKey: <Object?>[],
        }),
        isEmpty,
      );
      final List<VideoRelatedWork> fromPayload = relatedWorksFromRawPayload(
        'anidb',
        <String, Object?>{
          kAniDbRelatedPayloadKey: <Object?>[
            for (final VideoRelatedWork r in aniDbRelatedWorksFromXml(_xml)!)
              r.toPayload(),
          ],
        },
      )!;
      expect(fromPayload, aniDbRelatedWorksFromXml(_xml));
      expect(relatedWorksFromRawPayload('mal', _malItem()), hasLength(3));
    });

    test('TMDB 合集成员：按上映日期排、未定档殿后，只记相邻的前传 / 续作', () {
      final List<Object?> parts = <Object?>[
        <String, Object?>{'id': 4, 'title': 'Next', 'release_date': ''},
        <String, Object?>{'id': 3, 'title': 'C', 'release_date': '2010-05-01'},
        <String, Object?>{'id': 1, 'title': 'A', 'release_date': '2001-05-01'},
        <String, Object?>{'id': 2, 'title': 'B', 'release_date': '2005-05-01'},
        <String, Object?>{'id': 2, 'title': 'dup', 'release_date': '2005'},
      ];
      String text(List<VideoRelatedWork> l) => <String>[
        for (final VideoRelatedWork r in l)
          '${r.provider}:${r.externalId}:${r.relationType}:${r.title}',
      ].join(',');
      expect(
        text(tmdbRelatedWorksFromCollectionParts('2', parts)),
        'tmdb:1:prequel:A,tmdb:3:sequel:C',
      );
      expect(
        text(tmdbRelatedWorksFromCollectionParts('1', parts)),
        'tmdb:2:sequel:B',
      );
      expect(
        text(tmdbRelatedWorksFromCollectionParts('3', parts)),
        'tmdb:2:prequel:B,tmdb:4:sequel:Next',
      );
      expect(tmdbRelatedWorksFromCollectionParts('99', parts), isEmpty);

      // rawPayload：剧集（没有 belongs_to_collection 键）/ 成员缺失 → null；
      // 不属于任何合集 → 空表（权威）。
      expect(
        relatedWorksFromRawPayload('tmdb', <String, Object?>{'id': 2}),
        isNull,
      );
      expect(
        relatedWorksFromRawPayload('tmdb', <String, Object?>{
          'id': 2,
          'belongs_to_collection': <String, Object?>{'id': 5},
        }),
        isNull,
      );
      expect(
        relatedWorksFromRawPayload('tmdb', <String, Object?>{
          'id': 2,
          'belongs_to_collection': null,
        }),
        isEmpty,
      );
      expect(
        relatedWorksFromRawPayload('tmdb', <String, Object?>{
          'id': 2,
          'belongs_to_collection': <String, Object?>{'id': 5},
          kTmdbCollectionPartsPayloadKey: parts,
        }),
        hasLength(2),
      );
      expect(
        tmdbCollectionPartsFromResponse(<String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'id': 1, 'title': 'A', 'release_date': '2001'},
            <String, Object?>{'id': 2, 'name': 'TV', 'media_type': 'tv'},
            <String, Object?>{'title': 'no id'},
          ],
        }),
        <Map<String, Object?>>[
          <String, Object?>{'id': 1, 'title': 'A', 'release_date': '2001'},
        ],
      );
    });
  });

  group('写库', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(
        NativeDatabase.memory(
          setup: (CommonDatabase raw) =>
              raw.execute('PRAGMA foreign_keys = ON'),
        ),
      );
    });
    tearDown(() => db.close());

    Future<int> work(
      int? collectionId,
      String provider,
      String externalId, {
      String mediaType = 'tv',
      String? bookUid,
    }) async {
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(collectionId),
          bookUid: Value<String?>(bookUid),
          mediaType: mediaType,
          title: '$provider:$externalId',
          updatedAt: 1,
        ),
      );
      await db.replaceVideoMetadataProviderIdentities(
        workId: workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$workId:$provider',
            workId: Value<int?>(workId),
            provider: provider,
            externalId: externalId,
            isPrimary: const Value<bool>(true),
            updatedAt: 1,
          ),
        ],
      );
      return workId;
    }

    Future<List<String>> rows(int collectionId) async => <String>[
      for (final CollectionRelationRow r in await db.getCollectionRelations(
        collectionId,
      ))
        '${r.source}:${r.subjectId}:${r.relationType}:${r.targetCollectionId}',
    ];

    test('已在本机的目标绑定、指回自己的跳过、重刮幂等且不残留、local 行不动', () async {
      final int s1 = await db.createMediaCollection(
        'S1',
        collectionType: 'playlist',
      );
      final int s2 = await db.createMediaCollection(
        'S2',
        collectionType: 'playlist',
      );
      await work(s1, 'anidb', '100');
      await work(s2, 'anidb', '200');
      await db.replaceCollectionRelations(s1, <CollectionRelationsCompanion>[
        CollectionRelationsCompanion.insert(
          collectionId: Value<int?>(s1),
          relationType: 'sequel',
          targetCollectionId: Value<int?>(s2),
          source: 'local',
          subjectId: 'collection:$s2',
          title: 'S2',
        ),
      ]);
      const List<VideoRelatedWork> first = <VideoRelatedWork>[
        VideoRelatedWork(
          provider: 'anidb',
          externalId: '200',
          relationType: 'sequel',
          title: 'Show 2',
        ),
        VideoRelatedWork(
          provider: 'anidb',
          externalId: '100',
          relationType: 'other',
          title: 'self',
        ),
        VideoRelatedWork(
          provider: 'anidb',
          externalId: '300',
          relationType: 'side_story',
          title: 'Gaiden',
        ),
      ];
      expect(
        await syncScrapedCollectionRelations(
          db,
          owner: VideoRelationOwner.collection(s1),
          source: 'anidb',
          related: first,
        ),
        2,
      );
      expect(await rows(s1), <String>[
        'local:collection:$s2:sequel:$s2',
        'anidb:200:sequel:$s2',
        'anidb:300:side_story:null',
      ]);
      // 重刮：同一份 → 不重复；源撤掉 300 → 删掉。
      await syncScrapedCollectionRelations(
        db,
        owner: VideoRelationOwner.collection(s1),
        source: 'anidb',
        related: first,
      );
      expect(await rows(s1), hasLength(3));
      await syncScrapedCollectionRelations(
        db,
        owner: VideoRelationOwner.collection(s1),
        source: 'anidb',
        related: first.sublist(0, 1),
      );
      expect(await rows(s1), <String>[
        'local:collection:$s2:sequel:$s2',
        'anidb:200:sequel:$s2',
      ]);
    });

    test('升级绑定：目标后来入库 / 刮完，纯刮削行补上本地合集；目标是电影记 movie', () async {
      final int s1 = await db.createMediaCollection(
        'S1',
        collectionType: 'playlist',
      );
      await work(s1, 'anidb', '100');
      await syncScrapedCollectionRelations(
        db,
        owner: VideoRelationOwner.collection(s1),
        source: 'anidb',
        related: const <VideoRelatedWork>[
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '200',
            relationType: 'sequel',
            title: 'Show 2',
          ),
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '900',
            relationType: 'other',
            title: 'Movie',
          ),
        ],
      );
      expect(await rows(s1), <String>[
        'anidb:200:sequel:null',
        'anidb:900:other:null',
      ]);

      final int s2 = await db.createMediaCollection(
        'S2',
        collectionType: 'playlist',
      );
      await work(s2, 'anidb', '200');
      expect(
        await bindCollectionRelationsToWork(
          db,
          owner: VideoRelationOwner.collection(s2),
          identities: <(String, String)>[('anidb', '200')],
        ),
        1,
      );
      final int m = await db.createMediaCollection(
        'M',
        collectionType: 'playlist',
      );
      await work(m, 'anidb', '900', mediaType: 'movie');
      // 重刮时反查到电影目标：other → movie，已绑定的保持。
      await syncScrapedCollectionRelations(
        db,
        owner: VideoRelationOwner.collection(s1),
        source: 'anidb',
        related: const <VideoRelatedWork>[
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '200',
            relationType: 'sequel',
            title: 'Show 2',
          ),
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '900',
            relationType: 'other',
            title: 'Movie',
          ),
        ],
      );
      expect(await rows(s1), <String>[
        'anidb:200:sequel:$s2',
        'anidb:900:movie:$m',
      ]);
    });

    test('store.apply（作品资料写库出口）落关系、绑定别处指向本作品的行；载荷没带关系不清旧行', () async {
      final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
      Future<VideoSourceScrapeWork> localWork(String name) async {
        final int id = await db.createMediaCollection(
          name,
          collectionType: 'playlist',
        );
        await db.upsertVideoBook(
          VideoBooksCompanion(
            bookUid: Value<String>('$name-e1'),
            title: Value<String>('$name-e1'),
            videoPath: Value<String>('D:/$name/$name - 01.mkv'),
          ),
        );
        await db.addToCollection(id, MediaKind.video, '$name-e1');
        return VideoSourceScrapeWork(
          source: null,
          collection: (await db.getMediaCollectionById(id))!,
          title: name,
          members: <VideoBookRow>[
            (await db.getVideoBookByBookUid('$name-e1'))!,
          ],
        );
      }

      VideoMetadataWork anidb(String aid, List<VideoRelatedWork>? related) =>
          VideoMetadataWork(
            provider: VideoMetadataProviderKind.anidb,
            kind: VideoMetadataMediaKind.tv,
            title: 'aid $aid',
            ids: <VideoMetadataId>[VideoMetadataId(type: 'anidb', value: aid)],
            rawPayload: <String, Object?>{
              'aid': int.parse(aid),
              if (related != null)
                kAniDbRelatedPayloadKey: <Object?>[
                  for (final VideoRelatedWork r in related) r.toPayload(),
                ],
            },
          );

      final VideoSourceScrapeWork first = await localWork('First');
      await store.apply(
        first,
        anidb('100', const <VideoRelatedWork>[
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '200',
            relationType: 'sequel',
            title: 'Second',
          ),
        ]),
      );
      final int firstId = first.collection!.id;
      expect(await rows(firstId), <String>['anidb:200:sequel:null']);

      final VideoSourceScrapeWork second = await localWork('Second');
      await store.apply(second, anidb('200', const <VideoRelatedWork>[]));
      expect(await rows(firstId), <String>[
        'anidb:200:sequel:${second.collection!.id}',
      ]);

      // AniDB 只有目录（没带 related）：不清已有关系。
      await store.apply(first, anidb('100', null));
      expect(await rows(firstId), hasLength(1));
    });

    test('存量补填：AniDB 读落盘 XML、MAL 读 details 快照，TMDB 补不出不动', () async {
      final Directory dir = await Directory.systemTemp.createTemp('anidb_xml');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'AnimeDoc_100.xml')).writeAsString(_xml);

      final int a = await db.createMediaCollection(
        'A',
        collectionType: 'playlist',
      );
      final int b = await db.createMediaCollection(
        'B',
        collectionType: 'playlist',
      );
      final int seq = await db.createMediaCollection(
        'Seq',
        collectionType: 'playlist',
      );
      final int t = await db.createMediaCollection(
        'T',
        collectionType: 'playlist',
      );
      await work(a, 'anidb', '100');
      final int malWork = await work(b, 'mal', '1');
      await work(seq, 'anidb', '200');
      await work(t, 'tmdb', '77');
      await db.replaceVideoMetadataRawSnapshots(
        'work:$malWork:mal',
        <VideoMetadataRawSnapshotsCompanion>[
          VideoMetadataRawSnapshotsCompanion.insert(
            identityKey: 'work:$malWork:mal',
            snapshotKind: 'details',
            rawJson: jsonEncode(_malItem()),
            fetchedAt: 1,
          ),
        ],
      );

      final CollectionRelationBackfillResult r =
          await backfillScrapedCollectionRelations(
            db,
            aniDbXmlDirectory: () async => dir,
          );
      expect(r.works, 4);
      expect(r.worksWithRelations, 2);
      expect(r.rows, 7 + 3);
      expect((await rows(a)).first, 'anidb:200:sequel:$seq');
      expect(await rows(b), hasLength(3));
      expect(await rows(t), isEmpty);
      // 幂等：再跑一次行数不变。
      await backfillScrapedCollectionRelations(
        db,
        aniDbXmlDirectory: () async => dir,
      );
      expect(await rows(a), hasLength(7));
    });

    Future<void> movieVideo(String uid) => db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(uid),
        videoPath: Value<String>('D:/$uid.mkv'),
      ),
    );

    String rowText(CollectionRelationRow r) =>
        '${r.source}:${r.subjectId}:${r.relationType}:'
        '${r.targetCollectionId ?? r.targetBookUid}';

    test('散装电影（单视频作品）当起点和已绑定目标；删视频清边、目标视频被删退回纯刮削态', () async {
      final Directory dir = await Directory.systemTemp.createTemp('anidb_xml');
      addTearDown(() => dir.delete(recursive: true));
      await File(p.join(dir.path, 'AnimeDoc_100.xml')).writeAsString(_xml);
      await File(p.join(dir.path, 'AnimeDoc_300.xml')).writeAsString('''
<anime id="300" restricted="false">
  <type>Movie</type>
  <relatedanime>
    <anime id="100" type="Parent Story">Show</anime>
  </relatedanime>
</anime>
''');
      final int a = await db.createMediaCollection(
        'A',
        collectionType: 'playlist',
      );
      await work(a, 'anidb', '100');
      await movieVideo('m300');
      await work(null, 'anidb', '300', mediaType: 'movie', bookUid: 'm300');

      final CollectionRelationBackfillResult r =
          await backfillScrapedCollectionRelations(
            db,
            aniDbXmlDirectory: () async => dir,
          );
      expect(r.works, 2, reason: '散装电影也是补填对象');
      expect(r.worksWithRelations, 2);
      // A → 300：外传 + 目标在本机是电影 → movie，已绑定到单视频 m300。
      expect(
        (await db.getCollectionRelations(a)).map(rowText),
        contains('anidb:300:movie:m300'),
      );
      // 电影 → A：起点是单视频，目标是合集 A（Parent Story → other）。
      final List<CollectionRelationRow> fromMovie = await db
          .getVideoBookRelations('m300');
      expect(fromMovie.map(rowText), <String>['anidb:100:other:$a']);
      expect(fromMovie.single.collectionId, isNull);
      expect(fromMovie.single.bookUid, 'm300');

      // 幂等。
      await backfillScrapedCollectionRelations(
        db,
        aniDbXmlDirectory: () async => dir,
      );
      expect(await db.getVideoBookRelations('m300'), hasLength(1));
      expect(await rows(a), hasLength(7));

      // 删电影：它起点的边 cascade 清掉，A 指向它的边退回纯刮削态（行还在）。
      await db.deleteVideoBook('m300');
      expect(await db.getVideoBookRelations('m300'), isEmpty);
      final CollectionRelationRow toMovie = (await db.getCollectionRelations(
        a,
      )).singleWhere((CollectionRelationRow r) => r.subjectId == '300');
      expect(toMovie.targetBookUid, isNull);
      expect(toMovie.targetCollectionId, isNull);
    });

    test('升级绑定到单视频：电影后来入库，别的合集指向它的纯刮削行补上 targetBookUid', () async {
      final int a = await db.createMediaCollection(
        'A',
        collectionType: 'playlist',
      );
      await work(a, 'anidb', '100');
      await syncScrapedCollectionRelations(
        db,
        owner: VideoRelationOwner.collection(a),
        source: 'anidb',
        related: const <VideoRelatedWork>[
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '900',
            relationType: 'other',
            title: 'Movie',
          ),
        ],
      );
      await movieVideo('m900');
      await work(null, 'anidb', '900', mediaType: 'movie', bookUid: 'm900');
      expect(
        await bindCollectionRelationsToWork(
          db,
          owner: const VideoRelationOwner.video('m900'),
          identities: <(String, String)>[('anidb', '900')],
        ),
        1,
      );
      expect((await db.getCollectionRelations(a)).map(rowText), <String>[
        'anidb:900:other:m900',
      ]);
      // 已绑定的不会被再绑一次；手动改绑合集时单视频目标随之清掉（CHECK 至多一个）。
      expect(
        await bindCollectionRelationsToWork(
          db,
          owner: const VideoRelationOwner.video('m900'),
          identities: <(String, String)>[('anidb', '900')],
        ),
        0,
      );
      final int b = await db.createMediaCollection(
        'B',
        collectionType: 'playlist',
      );
      final CollectionRelationRow row = (await db.getCollectionRelations(
        a,
      )).single;
      await db.bindCollectionRelationTarget(row.id, b);
      final CollectionRelationRow rebound = (await db.getCollectionRelations(
        a,
      )).single;
      expect(rebound.targetCollectionId, b);
      expect(rebound.targetBookUid, isNull);
    });

    test('store.apply：单视频作品刮完落起点为单视频的关系，并把别处指向它的行绑上', () async {
      final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
      final int a = await db.createMediaCollection(
        'A',
        collectionType: 'playlist',
      );
      await work(a, 'anidb', '100');
      await syncScrapedCollectionRelations(
        db,
        owner: VideoRelationOwner.collection(a),
        source: 'anidb',
        related: const <VideoRelatedWork>[
          VideoRelatedWork(
            provider: 'anidb',
            externalId: '300',
            relationType: 'side_story',
            title: 'Movie',
          ),
        ],
      );
      await movieVideo('m300');
      await store.apply(
        VideoSourceScrapeWork(
          source: null,
          collection: null,
          title: 'Movie',
          members: <VideoBookRow>[(await db.getVideoBookByBookUid('m300'))!],
        ),
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.anidb,
          kind: VideoMetadataMediaKind.movie,
          title: 'Movie',
          ids: <VideoMetadataId>[VideoMetadataId(type: 'anidb', value: '300')],
          rawPayload: <String, Object?>{
            'aid': 300,
            kAniDbRelatedPayloadKey: <Object?>[
              const VideoRelatedWork(
                provider: 'anidb',
                externalId: '100',
                relationType: 'other',
                title: 'Show',
              ).toPayload(),
            ],
          },
        ),
      );
      expect((await db.getVideoBookRelations('m300')).map(rowText), <String>[
        'anidb:100:other:$a',
      ]);
      expect((await db.getCollectionRelations(a)).map(rowText), <String>[
        'anidb:300:side_story:m300',
      ]);

      // 电影后来并进一个合集、由合集级作品接管：成员自己那部作品连同它刮来的
      // 关系一起作废。
      final int box = await db.createMediaCollection(
        'Box',
        collectionType: 'playlist',
      );
      await db.addToCollection(box, MediaKind.video, 'm300');
      await store.apply(
        VideoSourceScrapeWork(
          source: null,
          collection: (await db.getMediaCollectionById(box))!,
          title: 'Box',
          members: <VideoBookRow>[(await db.getVideoBookByBookUid('m300'))!],
        ),
        VideoMetadataWork(
          provider: VideoMetadataProviderKind.anidb,
          kind: VideoMetadataMediaKind.tv,
          title: 'Box',
          ids: <VideoMetadataId>[VideoMetadataId(type: 'anidb', value: '999')],
          rawPayload: const <String, Object?>{'aid': 999},
        ),
      );
      expect(await db.getVideoBookRelations('m300'), isEmpty);
    });

    test('TMDB：电影合集成员落成前传 / 续作，tmdb 关系只绑电影作品（剧集 id 另一命名空间）', () async {
      final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
      // 剧集作品恰好也叫 tmdb:11——不能被当成电影 11 绑上。
      final int tv = await db.createMediaCollection(
        'TV',
        collectionType: 'playlist',
      );
      await work(tv, 'tmdb', '11');
      await movieVideo('m13');
      await work(null, 'tmdb', '13', mediaType: 'movie', bookUid: 'm13');
      await movieVideo('m12');
      final List<Object?> parts = <Object?>[
        <String, Object?>{
          'id': 13,
          'title': 'Part 3',
          'release_date': '2005-01-01',
        },
        <String, Object?>{
          'id': 11,
          'title': 'Part 1',
          'release_date': '2001-01-01',
        },
        <String, Object?>{
          'id': 12,
          'title': 'Part 2',
          'release_date': '2003-01-01',
        },
      ];
      Map<String, Object?> details({List<Object?>? parts}) => <String, Object?>{
        'id': 12,
        'belongs_to_collection': <String, Object?>{'id': 5, 'name': 'Saga'},
        if (parts != null) kTmdbCollectionPartsPayloadKey: parts,
      };
      VideoMetadataWork movie(Map<String, Object?> payload) =>
          VideoMetadataWork(
            provider: VideoMetadataProviderKind.tmdb,
            kind: VideoMetadataMediaKind.movie,
            title: 'Part 2',
            ids: <VideoMetadataId>[VideoMetadataId(type: 'tmdb', value: '12')],
            rawPayload: payload,
          );
      final VideoSourceScrapeWork local = VideoSourceScrapeWork(
        source: null,
        collection: null,
        title: 'Part 2',
        members: <VideoBookRow>[(await db.getVideoBookByBookUid('m12'))!],
      );
      await store.apply(local, movie(details(parts: parts)));
      expect((await db.getVideoBookRelations('m12')).map(rowText), <String>[
        'tmdb:11:prequel:null',
        'tmdb:13:sequel:m13',
      ]);
      // 合集请求失败（载荷不带成员）：不清旧行，作品照常写库。
      await store.apply(local, movie(details()));
      expect(await db.getVideoBookRelations('m12'), hasLength(2));
      // 不属于任何合集：源明确说没有 → 清掉。
      await store.apply(
        local,
        movie(<String, Object?>{'id': 12, 'belongs_to_collection': null}),
      );
      expect(await db.getVideoBookRelations('m12'), isEmpty);
    });

    test('TMDB 存量补填只读 details 快照里的合集成员，不联网', () async {
      await movieVideo('m12');
      final int w = await work(
        null,
        'tmdb',
        '12',
        mediaType: 'movie',
        bookUid: 'm12',
      );
      await db.replaceVideoMetadataRawSnapshots(
        'work:$w:tmdb',
        <VideoMetadataRawSnapshotsCompanion>[
          VideoMetadataRawSnapshotsCompanion.insert(
            identityKey: 'work:$w:tmdb',
            snapshotKind: 'details',
            rawJson: jsonEncode(<String, Object?>{
              'id': 12,
              'belongs_to_collection': <String, Object?>{'id': 5},
              kTmdbCollectionPartsPayloadKey: <Object?>[
                <String, Object?>{
                  'id': 11,
                  'title': 'P1',
                  'release_date': '2001',
                },
                <String, Object?>{
                  'id': 12,
                  'title': 'P2',
                  'release_date': '2003',
                },
              ],
            }),
            fetchedAt: 1,
          ),
        ],
      );
      final CollectionRelationBackfillResult r =
          await backfillScrapedCollectionRelations(
            db,
            aniDbXmlDirectory: () async => null,
          );
      expect(r.rows, 1);
      expect((await db.getVideoBookRelations('m12')).map(rowText), <String>[
        'tmdb:11:prequel:null',
      ]);
    });
  });
}
