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

    MediaLinkVerdict verdict(double confidence, {bool related = true}) =>
        MediaLinkVerdict(
          related: related,
          relation: MediaLinkRelation.sameWork,
          fromIsOriginal: null,
          confidence: confidence,
          reason: 'ai says',
        );

    test('无 AI：写成未确认建议；重复候选 / 已否决的对不再写', () async {
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome first = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[candidate, candidate],
        trigger: MediaLinkInferenceTrigger.manual,
      );
      expect(first.suggested, 1);
      expect(first.applied, 0);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.isUserConfirmed, isFalse);
      expect(row.confirmedBy, isNull);
      expect(row.reason, 'Titles match');
      await db.removeMediaLink(mediaLinkIdOf(row));
      final MediaLinkInferenceOutcome again = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[candidate],
        trigger: MediaLinkInferenceTrigger.manual,
      );
      expect(again.written, 0, reason: '否决墓碑挡住重复提议');
    });

    test('AI：不相关丢弃；相关按 AI 的关系 / 方向 / 置信度写，source=ai', () async {
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
        trigger: MediaLinkInferenceTrigger.automatic,
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
      expect(out.suggested, 1, reason: '自动路径 + AI 中置信：建议');
      expect(out.discarded, 1);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.source, MediaLinkSource.ai);
      expect(row.relation, 'adaptation');
      expect(
        row.fromKind,
        'video_collection',
        reason: 'AI 说 to（动画）才是原作：方向翻转为 动画 → 游戏',
      );
      expect(row.confidence, 0.8);
      expect(row.confirmedBy, isNull);
      expect(row.reason, contains('Titles match'), reason: '保留确定性证据');
    });

    // AI 库管家设计稿 §5.2 的表：每一格一个用例。
    final MediaLinkCandidate withId = MediaLinkCandidate(
      from: subject(MediaLinkKind.game, 'g9', <String>['X']),
      to: subject(MediaLinkKind.videoCollection, '9', <String>['X']),
      relation: MediaLinkRelation.adaptation,
      source: MediaLinkSource.wikidata,
      confidence: 0.9,
      reason: 'shared id',
      idEvidence: true,
    );
    final MediaLinkCandidate malStrong = MediaLinkCandidate(
      from: subject(MediaLinkKind.book, 'b1', <String>['Y']),
      to: subject(MediaLinkKind.videoCollection, '10', <String>['Y']),
      relation: MediaLinkRelation.adaptation,
      source: MediaLinkSource.mal,
      confidence: 0.6,
      reason: 'MAL source, exact title',
    );
    final MediaLinkCandidate malWeak = MediaLinkCandidate(
      from: subject(MediaLinkKind.book, 'b2', <String>['Y 1']),
      to: subject(MediaLinkKind.videoCollection, '11', <String>['Y']),
      relation: MediaLinkRelation.adaptation,
      source: MediaLinkSource.mal,
      confidence: 0.45,
      reason: 'MAL source, contained title',
    );

    final List<
      ({
        String name,
        MediaLinkCandidate c,
        MediaLinkVerdict? v,
        MediaLinkDisposition auto,
        MediaLinkDisposition manual,
      })
    >
    table =
        <
          ({
            String name,
            MediaLinkCandidate c,
            MediaLinkVerdict? v,
            MediaLinkDisposition auto,
            MediaLinkDisposition manual,
          })
        >[
          (
            name: '共享外部 id（无 AI）',
            c: withId,
            v: null,
            auto: MediaLinkDisposition.apply,
            manual: MediaLinkDisposition.apply,
          ),
          (
            name: '共享外部 id + AI 低置信',
            c: withId,
            v: verdict(0.3),
            auto: MediaLinkDisposition.apply,
            manual: MediaLinkDisposition.apply,
          ),
          (
            name: 'MAL 原作 + 标题强匹配',
            c: malStrong,
            v: null,
            auto: MediaLinkDisposition.apply,
            manual: MediaLinkDisposition.apply,
          ),
          (
            name: 'MAL 原作 + 标题只是包含（不算强匹配）',
            c: malWeak,
            v: null,
            auto: MediaLinkDisposition.suggest,
            manual: MediaLinkDisposition.suggest,
          ),
          (
            name: '只有标题，AI 高置信',
            c: candidate,
            v: verdict(0.95),
            auto: MediaLinkDisposition.apply,
            manual: MediaLinkDisposition.apply,
          ),
          (
            name: 'AI 中置信',
            c: candidate,
            v: verdict(0.7),
            auto: MediaLinkDisposition.suggest,
            manual: MediaLinkDisposition.apply,
          ),
          (
            name: 'AI 低置信',
            c: candidate,
            v: verdict(0.4),
            auto: MediaLinkDisposition.discard,
            manual: MediaLinkDisposition.suggest,
          ),
          (
            name: 'AI 判不相关（即便有共享 id）',
            c: withId,
            v: verdict(0.95, related: false),
            auto: MediaLinkDisposition.discard,
            manual: MediaLinkDisposition.discard,
          ),
        ];
    for (final ({
          String name,
          MediaLinkCandidate c,
          MediaLinkVerdict? v,
          MediaLinkDisposition auto,
          MediaLinkDisposition manual,
        })
        row
        in table) {
      for (final MediaLinkInferenceTrigger trigger
          in MediaLinkInferenceTrigger.values) {
        final MediaLinkDisposition expected =
            trigger == MediaLinkInferenceTrigger.automatic
            ? row.auto
            : row.manual;
        test('门槛：${row.name} · ${trigger.name} → ${expected.name}', () async {
          expect(
            mediaLinkDispositionOf(
              original: row.c,
              verdict: row.v,
              trigger: trigger,
            ),
            expected,
          );
          final FushiDatabase db = memDb();
          final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
            db: db,
            candidates: <MediaLinkCandidate>[row.c],
            trigger: trigger,
            judge: row.v == null
                ? null
                : _FixedJudge(<MediaLinkVerdict?>[row.v]),
          );
          final List<MediaLinkRow> rows = await db.allMediaLinks();
          switch (expected) {
            case MediaLinkDisposition.apply:
              expect(out.applied, 1);
              expect(out.appliedWrites.single.previous, isNull);
              expect(rows.single.confirmedBy, MediaLinkConfirmer.ai);
              expect(rows.single.isUserConfirmed, isFalse);
              expect(mediaLinkStateOf(rows.single), MediaLinkState.confirmed);
              expect(
                rows.single.updatedAt,
                kMediaLinkAiBaseClock,
                reason: 'AI 凭空新建不推进时钟',
              );
            case MediaLinkDisposition.suggest:
              expect(out.suggested, 1);
              expect(rows.single.confirmedBy, isNull);
              expect(mediaLinkStateOf(rows.single), MediaLinkState.suggested);
            case MediaLinkDisposition.discard:
              expect(out.discarded, 1);
              expect(rows, isEmpty);
          }
        });
      }
    }

    test('§5.4 兜底一：两个外部 id 对不上的视频合集，same_work 不生效、降为建议', () async {
      final MediaLinkCandidate clash = MediaLinkCandidate(
        from: subject(
          MediaLinkKind.videoCollection,
          '1',
          <String>['Z'],
          ids: const <String, String>{'anidb': '100'},
        ),
        to: subject(
          MediaLinkKind.videoCollection,
          '2',
          <String>['Z'],
          ids: const <String, String>{'anidb': '200', 'mal': '7'},
        ),
        relation: MediaLinkRelation.sameWork,
        source: kMediaLinkTitleMatchSource,
        confidence: 0.35,
        reason: 'Titles match',
      );
      expect(mediaLinkExternalIdsConflict(clash), isTrue);
      for (final MediaLinkInferenceTrigger trigger
          in MediaLinkInferenceTrigger.values) {
        final FushiDatabase db = memDb();
        final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
          db: db,
          candidates: <MediaLinkCandidate>[clash],
          trigger: trigger,
          judge: _FixedJudge(<MediaLinkVerdict?>[verdict(0.99)]),
        );
        expect(out.applied, 0, reason: trigger.name);
        expect(out.suggested, 1, reason: trigger.name);
      }
      // 有一个来源的 id 相同 = 不冲突；非 same_work（改编等）之间 id 本来就不同，不管。
      final MediaLinkCandidate same = MediaLinkCandidate(
        from: clash.from,
        to: subject(
          MediaLinkKind.videoCollection,
          '3',
          <String>['Z'],
          ids: const <String, String>{'anidb': '100'},
        ),
        relation: MediaLinkRelation.sameWork,
        source: kMediaLinkTitleMatchSource,
        confidence: 0.35,
        reason: 'Titles match',
      );
      expect(mediaLinkExternalIdsConflict(same), isFalse);
      expect(
        mediaLinkExternalIdsConflict(
          clash.copyWith(relation: MediaLinkRelation.adaptation),
        ),
        isFalse,
      );
    });

    test('§5.4 兜底二：自动路径上把两部已成形的作品并成一部 → 降为建议；手动照常生效', () async {
      ({Object id, int size})? workOf(MediaLinkEndpoint e) => switch (e.key) {
        'g1' => (id: 'A', size: 3),
        '5' => (id: 'B', size: 2),
        _ => null,
      };
      final MediaLinkVerdict high = verdict(0.95);
      final FushiDatabase autoDb = memDb();
      final MediaLinkInferenceOutcome auto = await applyMediaLinkCandidates(
        db: autoDb,
        candidates: <MediaLinkCandidate>[candidate],
        trigger: MediaLinkInferenceTrigger.automatic,
        judge: _FixedJudge(<MediaLinkVerdict?>[high]),
        workOf: workOf,
      );
      expect(auto.applied, 0);
      expect(auto.suggested, 1);
      final FushiDatabase manualDb = memDb();
      final MediaLinkInferenceOutcome manual = await applyMediaLinkCandidates(
        db: manualDb,
        candidates: <MediaLinkCandidate>[candidate],
        trigger: MediaLinkInferenceTrigger.manual,
        judge: _FixedJudge(<MediaLinkVerdict?>[high]),
        workOf: workOf,
      );
      expect(manual.applied, 1);
      // 一边是单个条目：只是把它挂进作品，照常生效；不提供 workOf 跳过检查。
      expect(
        mediaLinkFusesWorks((id: 'A', size: 5), (id: 'C', size: 1)),
        isFalse,
      );
      expect(
        mediaLinkFusesWorks((id: 'A', size: 5), (id: 'A', size: 5)),
        isFalse,
      );
      final FushiDatabase noWork = memDb();
      expect(
        (await applyMediaLinkCandidates(
          db: noWork,
          candidates: <MediaLinkCandidate>[candidate],
          trigger: MediaLinkInferenceTrigger.automatic,
          judge: _FixedJudge(<MediaLinkVerdict?>[high]),
        )).applied,
        1,
      );
    });

    test('同一轮里先生效的连接计入分量：第二条把两部作品并起来时降为建议', () async {
      final MediaLinkCandidate first = MediaLinkCandidate(
        from: subject(MediaLinkKind.book, 'b1', <String>['W']),
        to: subject(MediaLinkKind.book, 'b2', <String>['W']),
        relation: MediaLinkRelation.sameWork,
        source: MediaLinkSource.wikidata,
        confidence: 0.9,
        reason: 'id',
        idEvidence: true,
      );
      final MediaLinkCandidate second = MediaLinkCandidate(
        from: subject(MediaLinkKind.book, 'b2', <String>['W']),
        to: subject(MediaLinkKind.game, 'g7', <String>['W']),
        relation: MediaLinkRelation.sameWork,
        source: MediaLinkSource.wikidata,
        confidence: 0.9,
        reason: 'id',
        idEvidence: true,
      );
      // b1 / b2 各自单独；g7 已在一部两成员的作品里。
      ({Object id, int size})? workOf(MediaLinkEndpoint e) => switch (e.key) {
        'b1' => (id: 'P', size: 1),
        'b2' => (id: 'Q', size: 1),
        'g7' => (id: 'R', size: 2),
        _ => null,
      };
      final FushiDatabase db = memDb();
      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[first, second],
        trigger: MediaLinkInferenceTrigger.automatic,
        workOf: workOf,
      );
      expect(out.applied, 1, reason: 'b1+b2 生效后成了两成员的作品');
      expect(out.suggested, 1, reason: '再并 g7 的两成员作品：降为建议');
    });

    test('用户确认过 / 否决过的一对：AI 不碰', () async {
      final FushiDatabase db = memDb();
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.adaptation,
        from: withId.from.endpoint,
        to: withId.to.endpoint,
        at: 3,
      );
      final MediaLinkInferenceOutcome out = await applyMediaLinkCandidates(
        db: db,
        candidates: <MediaLinkCandidate>[withId],
        trigger: MediaLinkInferenceTrigger.manual,
      );
      expect(out.written, 0);
      final MediaLinkRow row = (await db.allMediaLinks()).single;
      expect(row.confirmedBy, MediaLinkConfirmer.user);
      expect(row.source, MediaLinkSource.manual);
    });
  });

  group('AI 回复解析', () {
    test('按下标回填；越界 / 未知关系 / 非法置信度丢弃；不接受 AI 给的 id', () {
      final List<MediaLinkVerdict?> v = parseAiMediaLinkVerdicts(
        '```json\n${jsonEncode(<String, Object?>{
          'verdicts': <Object?>[
            <String, Object?>{'index': 1, 'related': true, 'relation': 'adaptation', 'original': 'b', 'confidence': 0.7, 'reason': 'r', 'id': 'v999'},
            <String, Object?>{'index': 0, 'related': true, 'relation': 'remake_of', 'confidence': 0.7},
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
      // 系列关系（续作 / 外传）是认得的关系：方向不明时不退成 same_work（见
      // applyMediaLinkCandidates），这里只管解析。
      final List<MediaLinkVerdict?> series = parseAiMediaLinkVerdicts(
        jsonEncode(<String, Object?>{
          'verdicts': <Object?>[
            <String, Object?>{
              'index': 0,
              'related': true,
              'relation': 'sequel',
              'original': 'a',
              'confidence': 0.8,
            },
            <String, Object?>{
              'index': 1,
              'related': true,
              'relation': 'side_story',
              'original': 'b',
              'confidence': 0.8,
            },
          ],
        }),
        2,
      );
      expect(series[0]!.relation, MediaLinkRelation.sequel);
      expect(series[0]!.fromIsOriginal, isTrue);
      expect(series[1]!.relation, MediaLinkRelation.sideStory);
      expect(series[1]!.fromIsOriginal, isFalse);
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
      final List<Object?> items = payload['items']! as List<Object?>;
      expect(items, hasLength(2));
      expect((items.first! as Map<String, Object?>)['ids'], <String, Object?>{
        'vndb': 'v4',
      });
      expect(payload['pairs'], <Object?>[
        <String, Object?>{
          'i': 0,
          'a': 0,
          'b': 1,
          'src': kMediaLinkTitleMatchSource,
          'guess': 'same_work',
        },
      ]);
      expect(user, isNot(contains('Titles match')), reason: '证据句不再发');
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
      lookupWikidataAnime: (Iterable<String> _) async =>
          const <String, Set<String>>{},
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
