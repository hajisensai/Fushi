import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/scraper/bangumi_client.dart';
import 'package:hibiki/src/media/video/scraper/collection_relations_scrape.dart';
import 'package:hibiki/src/media/video/scraper/tmdb_client.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:drift/drift.dart' show Value;

/// TODO-2484：合集「相关作品」抓取层守卫。全部走内存 DB + MockClient，无真实网络。
void main() {
  Future<HibikiDatabase> openDb() async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (CommonDatabase rawDb) =>
            rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
    addTearDown(db.close);
    return db;
  }

  Future<int> boundCollection(
    HibikiDatabase db, {
    String name = '本篇',
    String source = 'bangumi',
    String subjectId = '100',
    String? detailUrl,
    String? airDate,
  }) async {
    final int id = await db.createMediaCollection(name);
    await db.upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion.insert(
      collectionId: Value<int>(id),
      source: source,
      subjectId: subjectId,
      title: name,
      airDate: Value<String?>(airDate),
      detailUrl: Value<String?>(detailUrl),
      scrapedAt: DateTime(2026),
    ));
    return id;
  }

  group('mapBangumiRelation', () {
    test('maps the six known relation words and defaults to other', () {
      expect(mapBangumiRelation('前传'), CollectionRelationType.prequel);
      expect(mapBangumiRelation('续集'), CollectionRelationType.sequel);
      expect(mapBangumiRelation('番外篇'), CollectionRelationType.sideStory);
      expect(mapBangumiRelation('外传'), CollectionRelationType.sideStory);
      expect(mapBangumiRelation('剧场版'), CollectionRelationType.movie);
      expect(mapBangumiRelation('衍生'), CollectionRelationType.spinOff);
      expect(mapBangumiRelation('总集篇'), CollectionRelationType.other);
      expect(mapBangumiRelation('主线故事'), CollectionRelationType.other);
    });

    test('wire round-trip is stable and unknown wire falls back to other', () {
      for (final CollectionRelationType type in CollectionRelationType.values) {
        expect(CollectionRelationType.fromWire(type.wire), type);
      }
      expect(CollectionRelationType.sideStory.wire, 'side_story');
      expect(CollectionRelationType.fromWire('future_kind'),
          CollectionRelationType.other);
    });
  });

  group('parseBangumiRelatedSubjects', () {
    test('keeps anime/real, drops music and relation-less items', () {
      final String body = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 201,
          'type': 2,
          'name': 'Sequel',
          'name_cn': '续作',
          'relation': '续集',
          'images': <String, Object?>{'large': 'https://img/l.jpg'},
        },
        <String, Object?>{
          'id': 202,
          'type': 3, // 音乐（OST）→ 滤掉
          'name': 'OST',
          'relation': '原声集',
        },
        <String, Object?>{
          'id': 203,
          'type': 2,
          'name': 'NoRelation', // 缺 relation → 滤掉
        },
      ]);
      final List<BangumiRelatedSubject> related =
          parseBangumiRelatedSubjects(body);
      expect(related, hasLength(1));
      expect(related.single.subjectId, '201');
      expect(related.single.title, '续作');
      expect(related.single.relation, '续集');
      expect(related.single.coverUrl, 'https://img/l.jpg');
    });

    test('non-array payload throws ScrapeNetworkException', () {
      expect(() => parseBangumiRelatedSubjects('{"error":"x"}'),
          throwsA(isA<ScrapeNetworkException>()));
    });
  });

  group('tmdb parsers', () {
    test('tmdbKindFromDetailUrl distinguishes tv and movie', () {
      expect(tmdbKindFromDetailUrl('https://www.themoviedb.org/tv/100'),
          TmdbSubjectKind.tv);
      expect(tmdbKindFromDetailUrl('https://www.themoviedb.org/movie/7'),
          TmdbSubjectKind.movie);
      expect(tmdbKindFromDetailUrl('https://bgm.tv/subject/1'), isNull);
      expect(tmdbKindFromDetailUrl(null), isNull);
    });

    test('parseTmdbTvDetail extracts seasons', () {
      final String body = jsonEncode(<String, Object?>{
        'name': '某剧',
        'seasons': <Object?>[
          <String, Object?>{
            'id': 900,
            'season_number': 0,
            'name': '特别篇',
            'poster_path': '/sp.jpg',
          },
          <String, Object?>{
            'id': 901,
            'season_number': 1,
            'name': '第 1 季',
            'air_date': '2023-01-04',
          },
        ],
      });
      final TmdbTvDetail detail = parseTmdbTvDetail(body);
      expect(detail.seasons, hasLength(2));
      expect(detail.seasons.first.seasonNumber, 0);
      expect(detail.seasons.last.seasonId, '901');
    });

    test('parseTmdbMovieCollectionRef reads belongs_to_collection or null', () {
      expect(
        parseTmdbMovieCollectionRef(jsonEncode(<String, Object?>{
          'belongs_to_collection': <String, Object?>{'id': 55, 'name': '系列'},
        }))!
            .collectionId,
        '55',
      );
      expect(
        parseTmdbMovieCollectionRef(
            jsonEncode(<String, Object?>{'belongs_to_collection': null})),
        isNull,
      );
    });

    test('parseTmdbCollectionParts extracts member movies', () {
      final List<TmdbCollectionPart> parts =
          parseTmdbCollectionParts(jsonEncode(<String, Object?>{
        'parts': <Object?>[
          <String, Object?>{
            'id': 7,
            'title': '第一部',
            'release_date': '2001-01-01',
            'poster_path': '/p1.jpg',
          },
          <String, Object?>{'id': 8, 'title': '第二部'},
          <String, Object?>{'title': '缺 id 丢弃'},
        ],
      }));
      expect(parts, hasLength(2));
      expect(parts.first.movieId, '7');
    });
  });

  group('scrapeCollectionRelations (bangumi)', () {
    MockClient bangumiRelationsClient(List<Object?> payload) =>
        MockClient((http.Request req) async {
          if (req.url.path.endsWith('/subjects/100/subjects')) {
            return http.Response.bytes(utf8.encode(jsonEncode(payload)), 200,
                headers: <String, String>{
                  'content-type': 'application/json; charset=utf-8',
                });
          }
          return http.Response('not found', 404);
        });

    test('writes edges, auto-binds local collections by subject and by title',
        () async {
      final HibikiDatabase db = await openDb();
      final int self = await boundCollection(db);
      // 目标 A：另一合集已刮过 subject 201 → 按 (source, subjectId) 绑定。
      final int targetA =
          await boundCollection(db, name: '续篇合集', subjectId: '201');
      // 目标 B：无刮削绑定，但合集名与关联条目标题精确相同 → 标题兜底绑定。
      final int targetB = await db.createMediaCollection('剧场版之名');

      final BangumiClient bangumi = BangumiClient(
        client: bangumiRelationsClient(<Object?>[
          <String, Object?>{
            'id': 201,
            'type': 2,
            'name_cn': '续作',
            'name': 'Sequel',
            'relation': '续集',
          },
          <String, Object?>{
            'id': 202,
            'type': 2,
            'name_cn': '剧场版之名',
            'name': 'Movie',
            'relation': '剧场版',
          },
          <String, Object?>{
            'id': 100, // 自引用脏数据：subject 与自身相同 → 不得绑回自己。
            'type': 2,
            'name_cn': '本篇',
            'name': 'Self',
            'relation': '其他',
          },
        ]),
      );
      addTearDown(bangumi.close);

      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: self,
        bangumi: bangumi,
      );
      expect(report.sourceErrors, isEmpty);
      expect(report.written, 3);
      expect(report.boundLocal, 2);

      final List<CollectionRelationRow> edges =
          await db.getCollectionRelations(self);
      expect(edges, hasLength(3));
      expect(edges[0].relationType, 'sequel');
      expect(edges[0].targetCollectionId, targetA);
      expect(edges[1].relationType, 'movie');
      expect(edges[1].targetCollectionId, targetB,
          reason: '无 subject 绑定时按标题精确匹配兜底');
      expect(edges[2].targetCollectionId, isNull,
          reason: '自引用条目绝不绑回自身（标题匹配也排除自身）');
      expect(edges.map((CollectionRelationRow e) => e.sortIndex).toList(),
          <int>[0, 1, 2]);
    });

    test('source failure keeps previous edges and reports the error', () async {
      final HibikiDatabase db = await openDb();
      final int self = await boundCollection(db);
      final BangumiClient good = BangumiClient(
        client: bangumiRelationsClient(<Object?>[
          <String, Object?>{
            'id': 201,
            'type': 2,
            'name': 'Sequel',
            'relation': '续集',
          },
        ]),
      );
      addTearDown(good.close);
      await scrapeCollectionRelations(
          db: db, collectionId: self, bangumi: good);
      expect(await db.getCollectionRelations(self), hasLength(1));

      final BangumiClient bad = BangumiClient(
        client:
            MockClient((http.Request req) async => http.Response('boom', 500)),
      );
      addTearDown(bad.close);
      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: self,
        bangumi: bad,
      );
      expect(report.sourceErrors, isNotEmpty, reason: '源失败必须上报不吞');
      expect(await db.getCollectionRelations(self), hasLength(1),
          reason: '源失败时不得把上次刮到的关系清空');
    });

    test('missing scrape binding throws StateError', () async {
      final HibikiDatabase db = await openDb();
      final int bare = await db.createMediaCollection('未刮削');
      expect(
        () => scrapeCollectionRelations(db: db, collectionId: bare),
        throwsStateError,
      );
    });

    test(
        'duplicate subjects from source are deduped first-wins '
        '(no unique-key rollback)', () async {
      final HibikiDatabase db = await openDb();
      final int self = await boundCollection(db);
      final BangumiClient bangumi = BangumiClient(
        client: bangumiRelationsClient(<Object?>[
          <String, Object?>{
            'id': 201,
            'type': 2,
            'name': 'Dup',
            'relation': '续集',
          },
          <String, Object?>{
            'id': 201,
            'type': 2,
            'name': 'Dup again',
            'relation': '其他',
          },
        ]),
      );
      addTearDown(bangumi.close);
      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: self,
        bangumi: bangumi,
      );
      expect(report.sourceErrors, isEmpty);
      expect(report.written, 1,
          reason: '同 (source, subjectId) 重复条目首见保留——不去重会撞唯一键'
              '把整批替换回滚成零写入');
      final CollectionRelationRow edge =
          (await db.getCollectionRelations(self)).single;
      expect(edge.relationType, 'sequel', reason: '首见（续集）保留');
    });
  });

  group('scrapeCollectionRelations (tmdb)', () {
    MockClient tmdbApiClient(Map<String, String> pathToBody) =>
        MockClient((http.Request req) async {
          final String? body = pathToBody[req.url.path];
          if (body == null) return http.Response('not found', 404);
          return http.Response.bytes(utf8.encode(body), 200,
              headers: <String, String>{
                'content-type': 'application/json; charset=utf-8',
              });
        });

    test(
        'tv seasons become edges (specials=side_story) and season edges '
        'never bind by subject id', () async {
      final HibikiDatabase db = await openDb();
      final int self = await boundCollection(
        db,
        source: 'tmdb',
        subjectId: '77',
        detailUrl: 'https://www.themoviedb.org/tv/77',
      );
      // 撞号干扰：另一合集的刮削绑定 subjectId 恰好等于季 id 901（tv/movie id
      // 与季 id 空间独立、必然撞号）。季边若按 subject 反查会错绑到它。
      final int decoy = await boundCollection(
        db,
        name: '撞号合集',
        source: 'tmdb',
        subjectId: '901',
      );
      // 标题精确匹配兜底对季边仍然生效。
      final int titleTarget = await db.createMediaCollection('第 2 季');

      final TmdbClient tmdb = TmdbClient(
        apiKey: 'k',
        client: tmdbApiClient(<String, String>{
          '/3/tv/77': jsonEncode(<String, Object?>{
            'name': 'Show',
            'seasons': <Object?>[
              <String, Object?>{
                'id': 900,
                'season_number': 0,
                'name': '特别篇',
              },
              <String, Object?>{
                'id': 901,
                'season_number': 1,
                'name': '第 1 季',
                'poster_path': '/s1.jpg',
              },
              <String, Object?>{
                'id': 902,
                'season_number': 2,
                'name': '第 2 季',
              },
            ],
          }),
        }),
      );
      addTearDown(tmdb.close);

      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: self,
        tmdb: tmdb,
      );
      expect(report.sourceErrors, isEmpty);
      expect(report.written, 3);
      expect(report.boundLocal, 1);

      final List<CollectionRelationRow> edges =
          await db.getCollectionRelations(self);
      expect(edges[0].relationType, 'side_story',
          reason: 'season 0（特别篇）归 side_story');
      expect(edges[0].title, '特别篇');
      expect(edges[1].relationType, 'other');
      expect(edges[1].targetCollectionId, isNull,
          reason: '季边绝不按 subject 反查——季 id 901 撞上 decoy 合集的 '
              'tv id 901 也不能绑');
      expect(edges[1].coverUrl, '${TmdbClient.posterBase}/s1.jpg');
      expect(edges[2].targetCollectionId, titleTarget, reason: '季边仍走标题精确匹配兜底');
      expect(decoy, isNot(titleTarget));
    });

    test('movie parts typed by release date relative to self, self excluded',
        () async {
      final HibikiDatabase db = await openDb();
      final int self = await boundCollection(
        db,
        source: 'tmdb',
        subjectId: '55',
        detailUrl: 'https://www.themoviedb.org/movie/55',
        airDate: '2005-06-01',
      );
      final TmdbClient tmdb = TmdbClient(
        apiKey: 'k',
        client: tmdbApiClient(<String, String>{
          '/3/movie/55': jsonEncode(<String, Object?>{
            'belongs_to_collection': <String, Object?>{'id': 5, 'name': '系列'},
          }),
          '/3/collection/5': jsonEncode(<String, Object?>{
            'parts': <Object?>[
              <String, Object?>{
                'id': 55,
                'title': '本体',
                'release_date': '2005-06-01',
              },
              <String, Object?>{
                'id': 54,
                'title': '前作',
                'release_date': '2001-01-01',
              },
              <String, Object?>{
                'id': 56,
                'title': '续作',
                'release_date': '2010-01-01',
              },
              <String, Object?>{'id': 57, 'title': '未定档'},
            ],
          }),
        }),
      );
      addTearDown(tmdb.close);

      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: self,
        tmdb: tmdb,
      );
      expect(report.sourceErrors, isEmpty);
      final List<CollectionRelationRow> edges =
          await db.getCollectionRelations(self);
      expect(edges, hasLength(3), reason: '排除自身（id 55）');
      expect(
        <String, String>{
          for (final CollectionRelationRow e in edges) e.title: e.relationType,
        },
        <String, String>{
          '前作': 'prequel',
          '续作': 'sequel',
          '未定档': 'other',
        },
        reason: '按上映日期相对本条目分型，无日期归 other',
      );
    });

    test('detailUrl-less subject probes tv first, falls back to movie on 404',
        () async {
      final HibikiDatabase db = await openDb();
      final int self = await boundCollection(
        db,
        source: 'tmdb',
        subjectId: '55',
        airDate: '2005-06-01',
      );
      final List<String> requested = <String>[];
      final TmdbClient tmdb = TmdbClient(
        apiKey: 'k',
        client: MockClient((http.Request req) async {
          requested.add(req.url.path);
          final Map<String, String> routes = <String, String>{
            // '/3/tv/55' 不注册 → 404 → 回退 movie 探测。
            '/3/movie/55': jsonEncode(<String, Object?>{
              'belongs_to_collection': <String, Object?>{'id': 5},
            }),
            '/3/collection/5': jsonEncode(<String, Object?>{
              'parts': <Object?>[
                <String, Object?>{
                  'id': 54,
                  'title': '前作',
                  'release_date': '2001-01-01',
                },
              ],
            }),
          };
          final String? body = routes[req.url.path];
          if (body == null) return http.Response('not found', 404);
          return http.Response.bytes(utf8.encode(body), 200);
        }),
      );
      addTearDown(tmdb.close);

      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: self,
        tmdb: tmdb,
      );
      expect(report.sourceErrors, isEmpty);
      expect(requested.first, '/3/tv/55', reason: '缺 detailUrl 先按 tv 探测');
      final List<CollectionRelationRow> edges =
          await db.getCollectionRelations(self);
      expect(edges.single.relationType, 'prequel',
          reason: 'tv 404 后回退 movie 路径产出系列成员边');
    });
  });
}
