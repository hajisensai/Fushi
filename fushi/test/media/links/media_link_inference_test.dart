import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/links/media_link_inference_host.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';
import 'package:fushi_engine/media/video/metadata/mal_video_metadata_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 作品图谱推断（L1）：确定性规则、AI 裁决的解析与落库口径。全部离线（MockClient /
/// 注入的 fetcher），不联网。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  MediaLinkSubject subject(
    MediaLinkKind kind,
    String key,
    List<String> titles, {
    Map<String, String> ids = const <String, String>{},
  }) => MediaLinkSubject(
    endpoint: (kind: kind, key: key),
    titles: titles,
    externalIds: ids,
  );

  http.Response json(Object payload) => http.Response(
    jsonEncode(payload),
    200,
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  group('规则', () {
    test('标题强度：相同 1，包含（短的 ≥4 字符）0.75，太短 / 不沾边 0', () {
      expect(
        titleMatchStrength(<String>['ＣＬＡＮＮＡＤ'], <String>['clannad']),
        1,
        reason: '全角 / 大小写走库页搜索同一归一化',
      );
      expect(
        titleMatchStrength(<String>['とある魔術の禁書目録'], <String>['とある魔術の禁書目録 第1巻']),
        0.75,
      );
      expect(titleMatchStrength(<String>['AB'], <String>['ABC Story']), 0);
      expect(titleMatchStrength(<String>['Kanon'], <String>['Air']), 0);
    });

    test('MAL 原作 → 本地书：书是原作（from），标题相同 0.6，包含 0.45，对不上不出', () {
      final MediaLinkSubject anime = subject(
        MediaLinkKind.videoCollection,
        '1',
        <String>['Spice and Wolf'],
        ids: <String, String>{'mal': '2966'},
      );
      final List<MediaLinkCandidate> out = matchMalSourceMaterial(
        video: anime,
        sources: const <MalSourceMaterial>[
          MalSourceMaterial(malId: 9115, name: 'Ookami to Koushinryou'),
        ],
        books: <MediaLinkSubject>[
          subject(MediaLinkKind.book, 'b1', <String>['Ookami to Koushinryou']),
          subject(MediaLinkKind.book, 'b2', <String>[
            'Ookami to Koushinryou Vol. 2',
          ]),
          subject(MediaLinkKind.book, 'b3', <String>['Unrelated']),
        ],
      );
      expect(out.map((MediaLinkCandidate c) => c.from.endpoint.key), <String>[
        'b1',
        'b2',
      ]);
      expect(out.first.to.endpoint.kind, MediaLinkKind.videoCollection);
      expect(out.first.relation, MediaLinkRelation.adaptation);
      expect(out.first.source, MediaLinkSource.mal);
      expect(out.first.confidence, 0.6);
      expect(out[1].confidence, 0.45);
      expect(out.first.idEvidence, isFalse, reason: 'Jikan 不给 ISBN：只有标题佐证');
    });

    test('标题规则跨模块才出候选（同模块不出）', () {
      final List<MediaLinkCandidate> out = matchSubjectsByTitle(
        subject: subject(MediaLinkKind.game, 'g', <String>['Clannad']),
        others: <MediaLinkSubject>[
          subject(MediaLinkKind.game, 'g2', <String>['Clannad']),
          subject(MediaLinkKind.videoCollection, '3', <String>['CLANNAD']),
        ],
      );
      expect(out, hasLength(1));
      expect(out.single.relation, MediaLinkRelation.sameWork);
      expect(out.single.source, kMediaLinkTitleMatchSource);
    });
  });

  group('落库', () {
    final MediaLinkCandidate candidate = MediaLinkCandidate(
      from: subject(MediaLinkKind.game, 'g1', <String>['Clannad']),
      to: subject(MediaLinkKind.videoCollection, '5', <String>['CLANNAD']),
      relation: MediaLinkRelation.sameWork,
      source: kMediaLinkTitleMatchSource,
      confidence: 0.35,
      reason: 'Titles match',
    );

    test('无 AI：写成未确认建议；重复候选 / 已否决的对不再写', () async {
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome first = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[candidate, candidate],
      );
      expect(first.proposed, 1);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.isUserConfirmed, isFalse);
      expect(row.reason, 'Titles match');
      await db.removeMediaLink(mediaLinkIdOf(row));
      final MediaLinkInferenceOutcome again = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[candidate],
      );
      expect(again.proposed, 0, reason: '否决墓碑挡住重复提议');
    });

    test('AI：不相关不写；相关按 AI 的关系 / 方向 / 置信度写成 source=ai 的建议', () async {
      final FushiDatabase db = memDb();
      final MediaLinkCandidate other = MediaLinkCandidate(
        from: subject(MediaLinkKind.game, 'g2', <String>['Air']),
        to: subject(MediaLinkKind.videoCollection, '6', <String>['AIR']),
        relation: MediaLinkRelation.sameWork,
        source: kMediaLinkTitleMatchSource,
        confidence: 0.35,
        reason: 'Titles match',
      );
      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[candidate, other],
        judge: _FixedJudge(<MediaLinkVerdict?>[
          const MediaLinkVerdict(
            related: true,
            relation: MediaLinkRelation.adaptation,
            fromIsOriginal: false,
            confidence: 0.8,
            reason: 'Anime adapts the game? no: the game is based on it',
          ),
          const MediaLinkVerdict(
            related: false,
            relation: MediaLinkRelation.sameWork,
            fromIsOriginal: null,
            confidence: 0.9,
            reason: 'Different works',
          ),
        ]),
      );
      expect(out.proposed, 1);
      expect(out.rejectedByAi, 1);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.source, MediaLinkSource.ai);
      expect(row.relation, 'adaptation');
      expect(
        row.fromKind,
        'video_collection',
        reason: 'AI 说 to（动画）才是原作：方向翻转为 动画 → 游戏',
      );
      expect(row.confidence, 0.8);
      expect(row.isUserConfirmed, isFalse, reason: 'AI 结论一律只作建议');
      expect(row.reason, contains('Titles match'), reason: '保留确定性证据');
    });

    test('自动确认只在 打开 + 共享 id 佐证 + AI 高置信 三者同时成立', () async {
      final FushiDatabase db = memDb();
      final MediaLinkCandidate withId = MediaLinkCandidate(
        from: subject(MediaLinkKind.game, 'g9', <String>['X']),
        to: subject(MediaLinkKind.videoCollection, '9', <String>['X']),
        relation: MediaLinkRelation.sameWork,
        source: MediaLinkSource.vndb,
        confidence: 0.9,
        reason: 'shared id',
        idEvidence: true,
      );
      const MediaLinkVerdict high = MediaLinkVerdict(
        related: true,
        relation: MediaLinkRelation.sameWork,
        fromIsOriginal: null,
        confidence: 0.95,
        reason: 'ok',
      );
      final MediaLinkInferenceOutcome off = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[candidate],
        judge: _FixedJudge(const <MediaLinkVerdict?>[high]),
        autoConfirm: true,
      );
      expect(off.autoConfirmed, 0, reason: '只有标题佐证：不自动确认');
      final MediaLinkInferenceOutcome on = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[withId],
        judge: _FixedJudge(const <MediaLinkVerdict?>[high]),
        autoConfirm: true,
      );
      expect(on.autoConfirmed, 1);
      expect(
        (await db.mediaLinksForEndpoint(
          MediaLinkKind.game,
          'g9',
        )).single.isUserConfirmed,
        isTrue,
      );
    });
  });

  group('AI 回复解析', () {
    test('按下标回填；越界 / 未知关系 / 非法置信度丢弃；不接受 AI 给的 id', () {
      final List<MediaLinkVerdict?> v = parseAiMediaLinkVerdicts(
        '```json\n${jsonEncode(<String, Object?>{
          'verdicts': <Object?>[
            <String, Object?>{'index': 1, 'related': true, 'relation': 'adaptation', 'original': 'b', 'confidence': 0.7, 'reason': 'r', 'id': 'v999'},
            <String, Object?>{'index': 0, 'related': true, 'relation': 'sequel', 'confidence': 0.7},
            <String, Object?>{'index': 2, 'related': true, 'relation': 'same_work', 'confidence': 7},
            <String, Object?>{'index': 5, 'related': false, 'confidence': 0.5},
          ],
        })}\n```',
        3,
      );
      expect(v[0], isNull, reason: '未知关系');
      expect(v[1]!.relation, MediaLinkRelation.adaptation);
      expect(v[1]!.fromIsOriginal, isFalse);
      expect(v[2], isNull, reason: '置信度越界');
    });

    test('AiMediaLinkJudge 只发候选证据、按下标取结论', () async {
      late Map<String, Object?> sent;
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return json(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{
                  'content': jsonEncode(<String, Object?>{
                    'verdicts': <Object?>[
                      <String, Object?>{
                        'index': 0,
                        'related': true,
                        'relation': 'same_work',
                        'original': 'unknown',
                        'confidence': 0.6,
                        'reason': 'same visual novel',
                      },
                    ],
                  }),
                },
              },
            ],
          });
        }),
      );
      addTearDown(client.close);
      final AiMediaLinkJudge judge = AiMediaLinkJudge(
        client: client,
        provider: AiProviderConfig(
          id: 'p',
          presetId: kAiCustomPresetId,
          name: 'p',
          baseUrl: Uri.parse('https://example.com/v1'),
          apiKey: 'k',
          model: 'm',
        ),
      );
      final List<MediaLinkVerdict?> out = await judge.judge(
        <MediaLinkCandidate>[
          MediaLinkCandidate(
            from: subject(
              MediaLinkKind.game,
              'g',
              <String>['Clannad'],
              ids: <String, String>{'vndb': 'v4'},
            ),
            to: subject(MediaLinkKind.videoCollection, '1', <String>[
              'CLANNAD',
            ]),
            relation: MediaLinkRelation.sameWork,
            source: kMediaLinkTitleMatchSource,
            confidence: 0.35,
            reason: 'Titles match',
          ),
        ],
      );
      expect(out.single!.related, isTrue);
      final List<Object?> messages = sent['messages']! as List<Object?>;
      final String user =
          (messages.last! as Map<String, Object?>)['content']! as String;
      final Map<String, Object?> payload =
          jsonDecode(user) as Map<String, Object?>;
      final Map<String, Object?> first =
          (payload['candidates']! as List<Object?>).single!
              as Map<String, Object?>;
      expect((first['a']! as Map<String, Object?>)['ids'], <String, Object?>{
        'vndb': 'v4',
      });
      expect(first['evidence'], 'Titles match');
    });
  });

  test(
    'MAL fetchSourceMaterial 只取 Adaptation 的 manga 条目（离线 fixture）',
    () async {
      final MalVideoMetadataProvider mal = MalVideoMetadataProvider(
        requestGate: MalVideoMetadataRequestGate(interval: Duration.zero),
        client: MockClient((http.Request request) async {
          expect(request.url.path, endsWith('/anime/2966/full'));
          return json(<String, Object?>{
            'data': <String, Object?>{
              'mal_id': 2966,
              'title': 'Ookami to Koushinryou',
              'type': 'TV',
              'relations': <Object?>[
                <String, Object?>{
                  'relation': 'Adaptation',
                  'entry': <Object?>[
                    <String, Object?>{
                      'mal_id': 9115,
                      'type': 'manga',
                      'name': 'Ookami to Koushinryou',
                    },
                  ],
                },
                <String, Object?>{
                  'relation': 'Sequel',
                  'entry': <Object?>[
                    <String, Object?>{
                      'mal_id': 5341,
                      'type': 'anime',
                      'name': 'Ookami to Koushinryou II',
                    },
                  ],
                },
              ],
            },
          });
        }),
      );
      addTearDown(mal.close);
      final List<MalSourceMaterial> out = await mal.fetchSourceMaterial('2966');
      expect(out.map((MalSourceMaterial m) => m.malId), <int>[9115]);
    },
  );

  test('以视频合集为中心跑一轮：MAL 原作对上本地书；Bangumi 身份不参与', () async {
    final FushiDatabase db = memDb();
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'spice',
        title: 'Ookami to Koushinryou',
        epubPath: '/tmp/spice.epub',
        extractDir: '/tmp/spice',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: 0,
      ),
    );
    final int collectionId = await db.createMediaCollection('Spice and Wolf');
    final int workId = await db
        .into(db.videoMetadataWorks)
        .insert(
          VideoMetadataWorksCompanion.insert(
            collectionId: Value<int?>(collectionId),
            mediaType: 'tv',
            title: 'Spice and Wolf',
            updatedAt: 1,
          ),
        );
    for (final MapEntry<String, String> id in <String, String>{
      'mal': '2966',
      'bangumi': '1',
    }.entries) {
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
    final MediaLinkLibrarySnapshot library =
        await MediaLinkLibrarySnapshot.load(db);
    expect(library.videos.single.externalIds, <String, String>{
      'mal': '2966',
    }, reason: 'Bangumi 身份不进推断（所有者 2026-10-24 拍板）');

    final List<String> fetched = <String>[];
    final int added = await runMediaLinkInference(
      db: db,
      self: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(collectionId),
      ),
      fetchMalSourceMaterial: (String malId) async {
        fetched.add(malId);
        return const <MalSourceMaterial>[
          MalSourceMaterial(malId: 9115, name: 'Ookami to Koushinryou'),
        ];
      },
    );
    expect(fetched, <String>['2966']);
    expect(added, 1);
    final MediaLinkRow row = (await db.allMediaLinks()).single;
    expect(row.fromKind, 'book');
    expect(row.fromKey, 'spice');
    expect(row.source, MediaLinkSource.mal);
    expect(row.isUserConfirmed, isFalse);
  });
}

class _FixedJudge implements MediaLinkJudge {
  _FixedJudge(this.verdicts);

  final List<MediaLinkVerdict?> verdicts;

  @override
  Future<List<MediaLinkVerdict?>> judge(
    List<MediaLinkCandidate> candidates,
  ) async => verdicts.take(candidates.length).toList();
}
