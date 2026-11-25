import 'dart:convert';

import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        DatabaseConnection,
        QueryExecutor,
        QueryInterceptor,
        Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/library_curate/library_curate_link_ops.dart';
import 'package:fushi/src/media/links/media_link_inference_host.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// AI 关系裁决的系列关系（续作 / 外传）与省额度口径：同类候选只交 AI、方向兜底、
/// 提示词去重、截断抢救、中途失败保留已得结论、一批端点合并成一次裁决。全部离线。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  /// 一个刮过（有作品行、没有外部身份）的视频合集。
  Future<int> videoCollection(FushiDatabase db, String name) async {
    final int id = await db.createMediaCollection(name);
    await db
        .into(db.videoMetadataWorks)
        .insert(
          VideoMetadataWorksCompanion.insert(
            collectionId: Value<int?>(id),
            mediaType: 'tv',
            title: name,
            updatedAt: 1,
          ),
        );
    return id;
  }

  MediaLinkSubject subject(
    MediaLinkKind kind,
    String key,
    List<String> titles, {
    int? year,
    Map<String, String> ids = const <String, String>{},
    Set<String> seriesSources = const <String>{},
  }) => MediaLinkSubject(
    endpoint: (kind: kind, key: key),
    titles: titles,
    year: year,
    externalIds: ids,
    seriesSources: seriesSources,
  );

  MediaLinkVerdict series(
    MediaLinkRelation relation, {
    bool? fromIsOriginal,
    double confidence = 0.95,
  }) => MediaLinkVerdict(
    related: true,
    relation: relation,
    fromIsOriginal: fromIsOriginal,
    confidence: confidence,
    reason: 'ai says',
  );

  AiProviderConfig provider() => AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
  );

  http.Response chat(String content) => http.Response(
    jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'content': content},
        },
      ],
    }),
    200,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  group('同类系列候选（R3）', () {
    test('视频 ↔ 视频标题沾边出 aiOnly 续作候选：年份早的在前；书不出', () {
      final MediaLinkSubject s2 = subject(
        MediaLinkKind.videoCollection,
        '2',
        <String>['Spice and Wolf II'],
        year: 2009,
      );
      final List<MediaLinkCandidate> out = matchSeriesByTitle(
        subject: s2,
        others: <MediaLinkSubject>[
          s2,
          subject(MediaLinkKind.videoCollection, '1', <String>[
            'Spice and Wolf',
          ], year: 2008),
          subject(MediaLinkKind.videoEpisode, 'movie', <String>[
            'Spice and Wolf The Movie',
          ]),
          subject(MediaLinkKind.game, 'g', <String>['Spice and Wolf']),
          subject(MediaLinkKind.videoCollection, '9', <String>['Unrelated']),
        ],
      );
      expect(out, hasLength(1), reason: '游戏不是同类；电影与 II 互不包含');
      expect(out.single.aiOnly, isTrue);
      expect(out.single.relation, MediaLinkRelation.sequel);
      expect(out.single.from.endpoint.key, '1', reason: '2008 在 2009 之前');
      expect(out.single.to.endpoint.key, '2');

      expect(
        matchSeriesByTitle(
          subject: subject(MediaLinkKind.book, 'b1', <String>['Spice 1']),
          others: <MediaLinkSubject>[
            subject(MediaLinkKind.book, 'b2', <String>['Spice 12']),
          ],
        ),
        isEmpty,
        reason: '同系列各卷不出候选',
      );
    });

    test('两端的系列关系都由同一个资料源刮过、或刮削关系已连上的不出；最多 6 条', () {
      final MediaLinkSubject self = subject(
        MediaLinkKind.videoCollection,
        '1',
        <String>['Fate'],
        ids: <String, String>{'anidb': '1'},
        seriesSources: <String>{'anidb'},
      );
      final MediaLinkSubject sameSource = subject(
        MediaLinkKind.videoCollection,
        '2',
        <String>['Fate/Zero'],
        ids: <String, String>{'anidb': '2'},
        seriesSources: <String>{'anidb'},
      );
      final MediaLinkSubject otherSource = subject(
        MediaLinkKind.videoCollection,
        '3',
        <String>['Fate/stay night'],
        ids: <String, String>{'tmdb': '3'},
      );
      final MediaLinkSubject linked = subject(
        MediaLinkKind.videoCollection,
        '4',
        <String>['Fate/Apocrypha'],
      );
      final List<MediaLinkCandidate> out = matchSeriesByTitle(
        subject: self,
        others: <MediaLinkSubject>[sameSource, otherSource, linked],
        alreadyLinked: (MediaLinkEndpoint a, MediaLinkEndpoint b) =>
            a == linked.endpoint || b == linked.endpoint,
      );
      expect(out.map((MediaLinkCandidate c) => c.to.endpoint.key), <String>[
        '3',
      ]);

      // 同源有 id、但源不提供系列关系：VNDB 游戏之间、TMDB 剧集 ↔ TMDB 剧场版照样出。
      expect(
        matchSeriesByTitle(
          subject: subject(
            MediaLinkKind.game,
            'g1',
            <String>['Fate/stay night'],
            ids: <String, String>{'vndb': 'v11'},
          ),
          others: <MediaLinkSubject>[
            subject(
              MediaLinkKind.game,
              'g2',
              <String>['Fate/stay night Realta Nua'],
              ids: <String, String>{'vndb': 'v3770'},
            ),
          ],
        ),
        hasLength(1),
        reason: 'VNDB 关系不落库，两款刮过 VNDB 的游戏仍要问 AI',
      );
      expect(
        matchSeriesByTitle(
          subject: subject(
            MediaLinkKind.videoCollection,
            'tv',
            <String>['Violet Evergarden'],
            year: 2018,
            ids: <String, String>{'tmdb': '75214'},
          ),
          others: <MediaLinkSubject>[
            subject(
              MediaLinkKind.videoEpisode,
              'movie',
              <String>['Violet Evergarden the Movie'],
              year: 2020,
              ids: <String, String>{'tmdb': '533514'},
            ),
          ],
        ),
        hasLength(1),
        reason: 'TMDB 剧集与剧场版之间没有关系行',
      );
      expect(
        matchSeriesByTitle(
          subject: subject(
            MediaLinkKind.videoEpisode,
            'm1',
            <String>['Kizumonogatari'],
            ids: <String, String>{'tmdb': '1'},
            seriesSources: <String>{'tmdb'},
          ),
          others: <MediaLinkSubject>[
            subject(
              MediaLinkKind.videoEpisode,
              'm2',
              <String>['Kizumonogatari II'],
              ids: <String, String>{'tmdb': '2'},
              seriesSources: <String>{'tmdb'},
            ),
          ],
        ),
        isEmpty,
        reason: '两端都是 TMDB 合集成员：合集关系是权威的',
      );

      final List<MediaLinkCandidate> many = matchSeriesByTitle(
        subject: subject(MediaLinkKind.game, 'g0', <String>['Rance']),
        others: <MediaLinkSubject>[
          for (int i = 1; i <= 10; i++)
            subject(MediaLinkKind.game, 'g$i', <String>['Rance $i']),
        ],
      );
      expect(many, hasLength(kMediaLinkSeriesCandidateLimit));
    });
  });

  test('库快照的 seriesSources：AniDB / MAL 有身份就算，TMDB 只认有关系行的，VNDB 不算', () async {
    final FushiDatabase db = memDb();
    Future<int> scraped(String name, Map<String, String> ids) async {
      final int cid = await db.createMediaCollection(name);
      final int workId = await db
          .into(db.videoMetadataWorks)
          .insert(
            VideoMetadataWorksCompanion.insert(
              collectionId: Value<int?>(cid),
              mediaType: 'tv',
              title: name,
              updatedAt: 1,
            ),
          );
      for (final MapEntry<String, String> id in ids.entries) {
        await db
            .into(db.videoMetadataProviderIdentities)
            .insert(
              VideoMetadataProviderIdentitiesCompanion.insert(
                identityKey: 'work:$workId:${id.key}',
                workId: Value<int?>(workId),
                provider: id.key,
                externalId: id.value,
                updatedAt: 1,
              ),
            );
      }
      return cid;
    }

    final int anime = await scraped('Anime', <String, String>{
      'anidb': '1',
      'tmdb': '10',
    });
    final int movie = await scraped('Movie', <String, String>{'tmdb': '20'});
    final int tv = await scraped('TV', <String, String>{'tmdb': '30'});
    // 只有 Movie 有 TMDB 合集成员落下的关系行（纯刮削行，目标不在本机）。
    await db
        .into(db.collectionRelations)
        .insert(
          CollectionRelationsCompanion.insert(
            collectionId: Value<int?>(movie),
            relationType: 'sequel',
            source: 'tmdb',
            subjectId: '21',
            title: 'Movie 2',
          ),
        );
    final MediaLinkLibrarySnapshot library =
        await MediaLinkLibrarySnapshot.load(db);
    Set<String> sourcesOf(int cid) => library.find((
      kind: MediaLinkKind.videoCollection,
      key: collectionTagEntryKey(cid),
    ))!.seriesSources;
    expect(sourcesOf(anime), <String>{'anidb'}, reason: 'TMDB 没有关系行');
    expect(sourcesOf(movie), <String>{'tmdb'});
    expect(sourcesOf(tv), isEmpty, reason: 'TMDB 剧集的关系不落库');
  });

  group('落库', () {
    MediaLinkCandidate seriesCandidate({int? fromYear, int? toYear}) =>
        MediaLinkCandidate(
          from: subject(MediaLinkKind.videoCollection, '1', <String>[
            'K-On!',
          ], year: fromYear),
          to: subject(MediaLinkKind.videoCollection, '2', <String>[
            'K-On!!',
          ], year: toYear),
          relation: MediaLinkRelation.sequel,
          source: kMediaLinkTitleMatchSource,
          confidence: 0.2,
          reason: 'Titles overlap',
          aiOnly: true,
        );

    test('aiOnly 候选：没有裁决器 / 没判出来都不写', () async {
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome noJudge = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[seriesCandidate()],
        trigger: MediaLinkInferenceTrigger.manual,
      );
      expect(noJudge.written, 0);
      final MediaLinkInferenceOutcome noVerdict =
          await applyMediaLinkCandidates(
            db: db,
            candidates: <MediaLinkCandidate>[seriesCandidate()],
            trigger: MediaLinkInferenceTrigger.manual,
            judge: _FixedJudge(<MediaLinkVerdict?>[null]),
          );
      expect(noVerdict.written, 0);
      expect(noVerdict.discarded, 1);
      expect(await db.allMediaLinks(), isEmpty);
    });

    test('续作方向：AI 给了就用；说不清按年份定并生效', () async {
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        // 候选方向故意放反（2010 → 2009），AI 不给方向。
        candidates: <MediaLinkCandidate>[
          seriesCandidate(fromYear: 2010, toYear: 2009),
        ],
        trigger: MediaLinkInferenceTrigger.automatic,
        judge: _FixedJudge(<MediaLinkVerdict?>[
          series(MediaLinkRelation.sequel),
        ]),
      );
      expect(out.applied, 1);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.relation, 'sequel');
      expect(row.fromKey, '2', reason: '2009 的是前作');
      expect(row.toKey, '1');
      expect(row.confirmedBy, MediaLinkConfirmer.ai);
    });

    test('续作方向说不清又没有年份 / 与年份矛盾：只作建议，不退成 same_work', () async {
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome unknown = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[seriesCandidate()],
        trigger: MediaLinkInferenceTrigger.manual,
        judge: _FixedJudge(<MediaLinkVerdict?>[
          series(MediaLinkRelation.sideStory),
        ]),
      );
      expect(unknown.applied, 0);
      expect(unknown.suggested, 1);
      MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.relation, 'side_story');
      expect(row.fromKey, '1', reason: '沿用候选原方向');
      expect(row.confirmedBy, isNull);

      final FushiDatabase db2 = memDb();
      final MediaLinkInferenceOutcome conflict = await applyMediaLinkCandidates(
        db: db2,
        candidates: <MediaLinkCandidate>[
          seriesCandidate(fromYear: 2010, toYear: 2009),
        ],
        trigger: MediaLinkInferenceTrigger.manual,
        judge: _FixedJudge(<MediaLinkVerdict?>[
          series(MediaLinkRelation.sequel, fromIsOriginal: true),
        ]),
      );
      expect(conflict.applied, 0, reason: 'AI 说 2010 的是前作，与年份矛盾');
      expect(conflict.suggested, 1);
      row = (await db2.allMediaLinks()).single;
      expect(row.fromKey, '1', reason: '方向照 AI 的写，交用户看');
    });

    test('同类候选被判成同一作品：不自动并，只作建议', () async {
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[seriesCandidate()],
        trigger: MediaLinkInferenceTrigger.manual,
        judge: _FixedJudge(<MediaLinkVerdict?>[
          series(MediaLinkRelation.sameWork),
        ]),
      );
      expect(out.applied, 0);
      expect(out.suggested, 1);
      expect((await db.allMediaLinks()).single.relation, 'same_work');
    });

    test('作品图里没有的孤立端点按单成员作品记账：同一轮先后连上两部已成形作品，'
        '自动路径上后一条降为建议', () async {
      final FushiDatabase db = memDb();
      MediaLinkSubject game(String key) =>
          subject(MediaLinkKind.game, key, <String>[key]);
      MediaLinkSubject book(String key) =>
          subject(MediaLinkKind.book, key, <String>[key]);
      MediaLinkCandidate idLink(MediaLinkSubject from, MediaLinkSubject to) =>
          MediaLinkCandidate(
            from: from,
            to: to,
            relation: MediaLinkRelation.sameWork,
            source: kMediaLinkTitleMatchSource,
            confidence: 0.9,
            reason: 'shared id',
            idEvidence: true,
          );
      // 作品图：A = {a1, a2}、B = {b1, b2, b3}；x、y 还没有任何连接（图里没有）。
      final Map<String, ({Object id, int size})> works =
          <String, ({Object id, int size})>{
            'a1': (id: 'A', size: 2),
            'a2': (id: 'A', size: 2),
            'b1': (id: 'B', size: 3),
            'b2': (id: 'B', size: 3),
            'b3': (id: 'B', size: 3),
          };
      ({Object id, int size})? workOf(MediaLinkEndpoint e) => works[e.key];

      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[
          // x 先并进 A，再连 B：A + x 与 B 都已成形 → 降为建议。
          idLink(game('x'), book('a1')),
          idLink(game('x'), book('b1')),
          // y 先并进 B，再连 A 的另一个成员：同样降为建议。
          idLink(game('y'), book('b2')),
          idLink(game('y'), book('a2')),
          // 两个孤立端点互连（各 1 个成员）照常生效。
          idLink(game('z1'), book('z2')),
        ],
        trigger: MediaLinkInferenceTrigger.automatic,
        workOf: workOf,
      );
      expect(out.applied, 3, reason: 'x→a1、y→b2、z1→z2');
      expect(out.suggested, 2, reason: 'x→b1、y→a2 会把 A、B 并成一部');
      final Set<String> suggested = <String>{
        for (final MediaLinkRow r in await db.allMediaLinks())
          if (r.confirmedBy == null)
            (<String>[r.fromKey, r.toKey]..sort()).join('-'),
      };
      expect(suggested, <String>{'b1-x', 'a2-y'}, reason: '无方向关系两端已规范化');

      // 手动路径不做这条兜底。
      final FushiDatabase db2 = memDb();
      final MediaLinkInferenceOutcome manual = await applyMediaLinkCandidates(
        db: db2,
        candidates: <MediaLinkCandidate>[
          idLink(game('x'), book('a1')),
          idLink(game('x'), book('b1')),
        ],
        trigger: MediaLinkInferenceTrigger.manual,
        workOf: workOf,
      );
      expect(manual.applied, 2);
    });

    test('同一对条目多条候选：强证据顶掉弱的，只问 AI 一次', () async {
      final FushiDatabase db = memDb();
      final MediaLinkSubject book = subject(MediaLinkKind.book, 'b', <String>[
        'Spice and Wolf',
      ]);
      final MediaLinkSubject video = subject(
        MediaLinkKind.videoCollection,
        '1',
        <String>['Spice and Wolf'],
      );
      final _FixedJudge judge = _FixedJudge(<MediaLinkVerdict?>[null]);
      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[
          MediaLinkCandidate(
            from: video,
            to: book,
            relation: MediaLinkRelation.sameWork,
            source: kMediaLinkTitleMatchSource,
            confidence: 0.35,
            reason: 'Titles match',
          ),
          MediaLinkCandidate(
            from: book,
            to: video,
            relation: MediaLinkRelation.adaptation,
            source: MediaLinkSource.mal,
            confidence: kMediaLinkMalStrongTitleConfidence,
            reason: 'MAL source',
          ),
        ],
        trigger: MediaLinkInferenceTrigger.automatic,
        judge: judge,
      );
      expect(judge.seen, hasLength(1));
      expect(judge.seen.single.source, MediaLinkSource.mal);
      expect(out.applied, 1, reason: 'MAL 强匹配直接生效');
      expect((await db.allMediaLinks()).single.relation, 'adaptation');
    });
  });

  group('提示词与解析', () {
    test('条目只发一遍、标题去重限量、不发证据句', () {
      final MediaLinkSubject center = subject(
        MediaLinkKind.game,
        'g',
        <String>[
          'Clannad',
          'CLANNAD',
          'クラナド',
          'Kuranado',
          'Clannad Full Voice',
          'Clannad Memorial Edition',
        ],
        ids: <String, String>{'vndb': 'v4'},
      );
      final String prompt = buildAiMediaLinkUserPrompt(<MediaLinkCandidate>[
        for (int i = 0; i < 3; i++)
          MediaLinkCandidate(
            from: center,
            to: subject(MediaLinkKind.videoCollection, '$i', <String>[
              'Clannad $i',
            ]),
            relation: MediaLinkRelation.sameWork,
            source: kMediaLinkTitleMatchSource,
            confidence: 0.25,
            reason: 'A LONG EVIDENCE SENTENCE',
          ),
      ]);
      final Map<String, Object?> payload =
          jsonDecode(prompt) as Map<String, Object?>;
      final List<Object?> items = payload['items']! as List<Object?>;
      expect(items, hasLength(4), reason: '中心条目只出现一次');
      final List<Object?> titles =
          (items.first! as Map<String, Object?>)['t']! as List<Object?>;
      expect(titles, hasLength(kAiMediaLinkMaxTitlesPerItem));
      expect(titles, isNot(contains('CLANNAD')), reason: '规范化后相同的只留一个');
      expect(prompt, isNot(contains('EVIDENCE')));
      expect(
        (payload['pairs']! as List<Object?>).map(
          (Object? p) => (p! as Map<String, Object?>)['a'],
        ),
        everyElement(0),
      );
    });

    test('短键回复；none 不要理由；prequel 反向；同义词；数字写成字符串也认', () {
      final List<MediaLinkVerdict?> v = parseAiMediaLinkVerdicts(
        jsonEncode(<String, Object?>{
          'v': <Object?>[
            <String, Object?>{'i': 0, 'r': 'none', 'c': 0.9},
            <String, Object?>{
              'i': '1',
              'r': 'Prequel',
              'o': 'a',
              'c': '0.8',
              'why': 'earlier story',
            },
            <String, Object?>{'i': 2.0, 'r': 'spin-off', 'o': '?', 'c': 0.7},
            <String, Object?>{'i': 3, 'r': 'remake', 'c': 0.7},
          ],
        }),
        4,
      );
      expect(v[0]!.related, isFalse);
      expect(v[1]!.relation, MediaLinkRelation.sequel);
      expect(v[1]!.fromIsOriginal, isFalse, reason: 'a 是 b 的前传 = b 在前');
      expect(v[1]!.confidence, 0.8);
      expect(v[1]!.reason, 'earlier story');
      expect(v[2]!.relation, MediaLinkRelation.sideStory);
      expect(v[2]!.fromIsOriginal, isNull);
      expect(v[3], isNull, reason: '不认识的关系');
    });

    test('回复被截断：已写完的结论照常取用', () {
      const String cut =
          '{"v":[{"i":0,"r":"sequel","o":"a","c":0.9,"why":"season 2"},'
          '{"i":1,"r":"none","c":0.8},{"i":2,"r":"adapt';
      final List<MediaLinkVerdict?> v = parseAiMediaLinkVerdicts(cut, 3);
      expect(v[0]!.relation, MediaLinkRelation.sequel);
      expect(v[1]!.related, isFalse);
      expect(v[2], isNull);
    });

    test('后面的批次失败：保留前面的结论，不再继续请求；第一批失败照常抛', () async {
      int calls = 0;
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          calls++;
          if (calls > 1) return http.Response('{"error":"bad key"}', 401);
          return chat(
            jsonEncode(<String, Object?>{
              'v': <Object?>[
                <String, Object?>{'i': 0, 'r': 'none', 'c': 0.9},
              ],
            }),
          );
        }),
      );
      addTearDown(client.close);
      final List<MediaLinkCandidate> candidates = <MediaLinkCandidate>[
        for (int i = 0; i < kAiMediaLinkMaxCandidatesPerRequest * 3; i++)
          MediaLinkCandidate(
            from: subject(MediaLinkKind.game, 'g$i', <String>['G$i']),
            to: subject(MediaLinkKind.videoCollection, '$i', <String>['V$i']),
            relation: MediaLinkRelation.sameWork,
            source: kMediaLinkTitleMatchSource,
            confidence: 0.35,
            reason: 'r',
          ),
      ];
      final AiMediaLinkJudge judge = AiMediaLinkJudge(
        client: client,
        provider: provider(),
      );
      final List<MediaLinkVerdict?> out = await judge.judge(candidates);
      expect(out, hasLength(candidates.length));
      expect(out.first!.related, isFalse);
      expect(out.skip(1), everyElement(isNull));
      expect(judge.partialFailure, isNotNull);
      expect(judge.requestCount, 2, reason: '第二批失败后不发第三批');

      final AiMediaLinkJudge down = AiMediaLinkJudge(
        client: client,
        provider: provider(),
      );
      await expectLater(down.judge(candidates), throwsA(isA<AiChatFailure>()));
    });
  });

  group('裁决缓存', () {
    MediaLinkCandidate pair(
      String title, {
      bool swapped = false,
      String videoTitle = 'CLANNAD',
      MediaLinkRelation relation = MediaLinkRelation.sameWork,
    }) {
      final MediaLinkSubject game = subject(MediaLinkKind.game, 'g', <String>[
        title,
      ]);
      final MediaLinkSubject video = subject(
        MediaLinkKind.videoCollection,
        '1',
        <String>[videoTitle],
      );
      return MediaLinkCandidate(
        from: swapped ? video : game,
        to: swapped ? game : video,
        relation: relation,
        source: kMediaLinkTitleMatchSource,
        confidence: 0.35,
        reason: 'r',
      );
    }

    test('问过的一对不再发请求；两端反着摆方向照样对；AI 输入 / 模型变了重问；过期重问', () async {
      final FushiDatabase db = memDb();
      int calls = 0;
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          calls++;
          return chat(
            jsonEncode(<String, Object?>{
              'v': <Object?>[
                <String, Object?>{
                  'i': 0,
                  'r': 'adaptation',
                  'o': 'a',
                  'c': 0.8,
                  'why': 'game first',
                },
              ],
            }),
          );
        }),
      );
      addTearDown(client.close);
      int now = 1000;
      AiMediaLinkJudge judge({String model = 'm'}) => AiMediaLinkJudge(
        client: client,
        provider: AiProviderConfig(
          id: 'p',
          presetId: kAiCustomPresetId,
          name: 'p',
          baseUrl: Uri.parse('https://example.com/v1'),
          apiKey: 'k',
          model: model,
        ),
        cache: MediaLinkVerdictCache(db, now: () => now),
      );

      final AiMediaLinkJudge first = judge();
      final MediaLinkVerdict asked = (await first.judge(<MediaLinkCandidate>[
        pair('Clannad'),
      ])).single!;
      expect(asked.fromIsOriginal, isTrue, reason: 'a = 游戏是原作');
      expect(calls, 1);

      final AiMediaLinkJudge second = judge();
      final MediaLinkVerdict cached = (await second.judge(<MediaLinkCandidate>[
        pair('Clannad', swapped: true),
      ])).single!;
      expect(calls, 1, reason: '同一对、AI 输入没变：不发请求');
      expect(second.requestCount, 0);
      expect(second.cacheHits, 1);
      expect(cached.relation, MediaLinkRelation.adaptation);
      expect(cached.confidence, 0.8);
      expect(cached.reason, 'game first');
      expect(cached.fromIsOriginal, isFalse, reason: '这次 from 是动画，原作仍是游戏');

      await judge().judge(<MediaLinkCandidate>[
        pair('Clannad', relation: MediaLinkRelation.adaptation),
      ]);
      expect(calls, 2, reason: '规则的猜测变了 = 提示词里的 guess 变了');

      await judge().judge(<MediaLinkCandidate>[
        pair('Clannad', videoTitle: 'CLANNAD After Story'),
      ]);
      expect(calls, 3, reason: '标题变了 = AI 输入变了');
      await judge(model: 'other').judge(<MediaLinkCandidate>[
        pair('Clannad', videoTitle: 'CLANNAD After Story'),
      ]);
      expect(calls, 4, reason: '换了模型');
      expect(
        await db.mediaLinkAiVerdictsSince(0),
        hasLength(1),
        reason: '同一对只留最新一条',
      );

      now += kAiMediaLinkVerdictCacheTtl.inMilliseconds + 1;
      await judge(model: 'other').judge(<MediaLinkCandidate>[
        pair('Clannad', videoTitle: 'CLANNAD After Story'),
      ]);
      expect(calls, 5, reason: '过期重问');
    });

    test('不相关的结论也记：第二轮推断零请求、仍然不写', () async {
      final FushiDatabase db = memDb();
      int calls = 0;
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          calls++;
          return chat('{"v":[{"i":0,"r":"none","c":0.9}]}');
        }),
      );
      addTearDown(client.close);
      for (int round = 0; round < 2; round++) {
        final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
          db: db,
          candidates: <MediaLinkCandidate>[pair('Clannad')],
          trigger: MediaLinkInferenceTrigger.manual,
          judge: AiMediaLinkJudge(
            client: client,
            provider: provider(),
            cache: MediaLinkVerdictCache(db),
          ),
        );
        expect(out.written, 0);
        expect(out.discarded, 1);
      }
      expect(calls, 1);
      expect(await db.allMediaLinks(), isEmpty);
    });

    // HBK-AUDIT-043：查少数候选不读整张有效期内的缓存；清过期按独立频率，不随批次走。
    test('按候选端点对查缓存：读回行数 = 候选数、走主键；清过期一天一次、不随批次', () async {
      final _VerdictTableCounter counter = _VerdictTableCounter();
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory().interceptWith(counter)),
      );
      addTearDown(db.close);
      int calls = 0;
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          calls++;
          return chat('{"v":[{"i":0,"r":"none","c":0.9}]}');
        }),
      );
      addTearDown(client.close);
      int now = kAiMediaLinkVerdictCacheTtl.inMilliseconds * 2;
      AiMediaLinkJudge judge() => AiMediaLinkJudge(
        client: client,
        provider: provider(),
        cache: MediaLinkVerdictCache(db, now: () => now),
      );

      // 表里先攒 300 对别的组合（有效期内）+ 1 条过期行。
      const int unrelated = 300;
      await db.upsertMediaLinkAiVerdicts(<MediaLinkAiVerdictsCompanion>[
        for (int i = 0; i < unrelated; i++)
          MediaLinkAiVerdictsCompanion.insert(
            aKind: 'game',
            aKey: 'other$i',
            bKind: 'video_collection',
            bKey: 'other$i',
            fingerprint: 'f',
            related: false,
            confidence: 0.9,
            judgedAt: now,
          ),
        MediaLinkAiVerdictsCompanion.insert(
          aKind: 'game',
          aKey: 'stale',
          bKind: 'video_collection',
          bKey: 'stale',
          fingerprint: 'f',
          related: false,
          confidence: 0.9,
          judgedAt: now - kAiMediaLinkVerdictCacheTtl.inMilliseconds - 1,
        ),
      ]);
      Future<bool> staleRowPresent() async =>
          (await db.mediaLinkAiVerdictsSince(
            0,
          )).any((MediaLinkAiVerdictRow r) => r.aKey == 'stale');

      // 第一次：没缓存 → 问 → 记；这个数据库头一回记，顺带清过期。
      await judge().judge(<MediaLinkCandidate>[pair('Clannad')]);
      expect(calls, 1);
      expect(counter.deletes, 1);
      expect(await staleRowPresent(), isFalse);

      // 第二次：命中。只读回这一对，不是整表 301 行；且走主键索引而非全表扫描。
      counter.reset();
      final AiMediaLinkJudge hit = judge();
      await hit.judge(<MediaLinkCandidate>[pair('Clannad')]);
      expect(hit.cacheHits, 1);
      expect(calls, 1);
      expect(counter.selects, 1);
      expect(counter.rowsRead, 1, reason: '表里另有 $unrelated 对，不该读回');
      expect(counter.plans, isNotEmpty);
      expect(
        counter.plans.where((String d) => d.startsWith('SCAN')),
        isEmpty,
        reason: '按主键逐对 SEARCH：${counter.plans}',
      );

      // 一次推断分三批记（45 条新候选），同一天内不再清：又插一条过期行，它留着。
      await db.upsertMediaLinkAiVerdicts(<MediaLinkAiVerdictsCompanion>[
        MediaLinkAiVerdictsCompanion.insert(
          aKind: 'game',
          aKey: 'stale',
          bKind: 'video_collection',
          bKey: 'stale',
          fingerprint: 'f',
          related: false,
          confidence: 0.9,
          judgedAt: now - kAiMediaLinkVerdictCacheTtl.inMilliseconds - 1,
        ),
      ]);
      counter.reset();
      final List<MediaLinkCandidate> batchOf45 = <MediaLinkCandidate>[
        for (int i = 0; i < kAiMediaLinkMaxCandidatesPerRequest * 2 + 5; i++)
          MediaLinkCandidate(
            from: subject(MediaLinkKind.game, 'n$i', <String>['N$i']),
            to: subject(MediaLinkKind.videoCollection, 'n$i', <String>['M$i']),
            relation: MediaLinkRelation.sameWork,
            source: kMediaLinkTitleMatchSource,
            confidence: 0.35,
            reason: 'r',
          ),
      ];
      final AiMediaLinkJudge multi = judge();
      await multi.judge(batchOf45);
      expect(multi.requestCount, 3);
      expect(counter.rowsRead, 0, reason: '45 对都没缓存，不读回别的组合');
      expect(
        counter.plans.where((String d) => d.startsWith('SCAN')),
        isEmpty,
        reason: '多对也逐对走主键：${counter.plans}',
      );
      expect(counter.deletes, 0, reason: '三批记录都不再清过期');
      expect(await staleRowPresent(), isTrue);

      // 过了清理间隔，下一次记录顺带清掉。
      now += kAiMediaLinkVerdictPruneInterval.inMilliseconds;
      counter.reset();
      await judge().judge(<MediaLinkCandidate>[
        pair('Clannad', videoTitle: 'CLANNAD After Story'),
      ]);
      expect(counter.deletes, 1);
      expect(await staleRowPresent(), isFalse);
    });
  });

  test('库管家一批端点：候选合并、同一对只问一次、整批一次裁决', () async {
    final FushiDatabase db = memDb();
    final List<int> collections = <int>[
      for (final String name in <String>[
        'Spice and Wolf',
        'Spice and Wolf II',
        'Spice and Wolf Movie',
      ])
        await videoCollection(db, name),
    ];
    final List<MediaLinkEndpoint> endpoints = <MediaLinkEndpoint>[
      for (final int id in collections)
        (kind: MediaLinkKind.videoCollection, key: collectionTagEntryKey(id)),
    ];
    final _FixedJudge judge = _FixedJudge(<MediaLinkVerdict?>[
      for (int i = 0; i < 3; i++)
        series(MediaLinkRelation.sequel, fromIsOriginal: true),
    ]);
    final LibraryCurateLinkResult r = await runLibraryCurateLinkInference(
      db: db,
      endpoints: endpoints,
      trigger: MediaLinkInferenceTrigger.automatic,
      deps: LibraryCurateLinkDeps(
        fetchMalSourceMaterial: (String id) async => const <Never>[],
        lookupWikidataAnime: (Iterable<String> ids) async =>
            const <String, Set<String>>{},
        judge: judge,
      ),
    );
    expect(r.requests, 1, reason: '三个端点合成一次裁决');
    expect(judge.seen, hasLength(2), reason: '本篇 ↔ II、本篇 ↔ Movie');
    final Set<String> pairs = <String>{
      for (final MediaLinkCandidate c in judge.seen)
        mediaLinkPairKey(c.from.endpoint, c.to.endpoint),
    };
    expect(pairs, hasLength(judge.seen.length), reason: '同一对不重复问');
    expect(r.applied, judge.seen.length);
    expect(
      (await db.allMediaLinks()).map((MediaLinkRow l) => l.relation),
      everyElement('sequel'),
    );

    // 没有裁决器：同类候选不出，什么都不写。
    final FushiDatabase db2 = memDb();
    final int a = await videoCollection(db2, 'Spice and Wolf');
    await videoCollection(db2, 'Spice and Wolf II');
    final LibraryCurateLinkResult none = await runLibraryCurateLinkInference(
      db: db2,
      endpoints: <MediaLinkEndpoint>[
        (kind: MediaLinkKind.videoCollection, key: collectionTagEntryKey(a)),
      ],
      trigger: MediaLinkInferenceTrigger.manual,
      deps: LibraryCurateLinkDeps(
        fetchMalSourceMaterial: (String id) async => const <Never>[],
        lookupWikidataAnime: (Iterable<String> ids) async =>
            const <String, Set<String>>{},
      ),
    );
    expect(none.writes, isEmpty);
    expect(await db2.allMediaLinks(), isEmpty);
  });
}

class _FixedJudge implements MediaLinkJudge {
  _FixedJudge(this.verdicts);

  final List<MediaLinkVerdict?> verdicts;
  final List<MediaLinkCandidate> seen = <MediaLinkCandidate>[];

  @override
  Future<List<MediaLinkVerdict?>> judge(
    List<MediaLinkCandidate> candidates,
  ) async {
    seen.addAll(candidates);
    return <MediaLinkVerdict?>[
      for (int i = 0; i < candidates.length; i++)
        i < verdicts.length ? verdicts[i] : null,
    ];
  }
}

/// 数 `media_link_ai_verdicts` 上的 SELECT 次数 / 读回行数 / DELETE 次数，并记下每条
/// SELECT 的查询计划（EXPLAIN QUERY PLAN 的 detail 列）。
class _VerdictTableCounter extends QueryInterceptor {
  int selects = 0;
  int rowsRead = 0;
  int deletes = 0;
  final List<String> plans = <String>[];

  void reset() {
    selects = 0;
    rowsRead = 0;
    deletes = 0;
    plans.clear();
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final List<Map<String, Object?>> rows = await executor.runSelect(
      statement,
      args,
    );
    if (statement.contains('FROM "media_link_ai_verdicts"')) {
      selects++;
      rowsRead += rows.length;
      for (final Map<String, Object?> step in await executor.runSelect(
        'EXPLAIN QUERY PLAN $statement',
        args,
      )) {
        plans.add('${step['detail']}');
      }
    }
    return rows;
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('"media_link_ai_verdicts"')) deletes++;
    return executor.runDelete(statement, args);
  }
}
