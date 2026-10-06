import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_video_acquisition_assistant.dart';
import 'package:fushi_engine/ai/ai_video_identity_assistant.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p',
  presetId: 'custom',
  name: 'Test',
  baseUrl: Uri.parse('https://example.test/v1'),
  apiKey: 'k',
  model: 'm',
);

/// OpenAI 形状的假客户端：记录请求体、回固定文本。
AiChatClient _clientReplying(
  String content, {
  void Function(Map<String, Object?> body)? onRequest,
}) => AiChatClient(
  client: MockClient((http.Request request) async {
    onRequest?.call(jsonDecode(request.body) as Map<String, Object?>);
    return http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': content},
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }),
);

const VideoAcquisitionQuestion _qualityQuestion = VideoAcquisitionQuestion(
  slot: VideoAcquisitionSlot.quality,
  options: <VideoAcquisitionOption>[
    VideoAcquisitionOption(id: '2160p', label: '2160p'),
    VideoAcquisitionOption(id: '1080p', label: '1080p'),
    VideoAcquisitionOption(id: '720p'),
  ],
);

VideoAcquisitionIntentQuery _query({
  String utterance = '1080 的',
  VideoAcquisitionQuestion? pendingQuestion = _qualityQuestion,
  List<({String role, String text})> history =
      const <({String role, String text})>[],
}) => VideoAcquisitionIntentQuery(
  utterance: utterance,
  stage: VideoAcquisitionStage.collectingSlots.name,
  locale: 'zh-CN',
  pendingQuestion: pendingQuestion,
  slots: const <String, Object?>{
    'workTitle': 'Frieren',
    'workChosen': true,
    'workKind': 'tv',
    'airing': 'finished',
    'mode': 'download',
  },
  history: history,
);

VideoAcquisitionIntent _parse(String reply, {int optionCount = 3}) =>
    parseVideoAcquisitionIntent(reply, optionCount: optionCount);

void main() {
  group('parseVideoAcquisitionIntent', () {
    test('合法回复：每个字段都进补丁', () {
      final VideoAcquisitionIntent intent = _parse('''
{"intent": "provide", "workQueries": ["葬送のフリーレン", "Sousou no Frieren", "Frieren: Beyond Journey's End"],
 "category": "anime", "season": 2, "episode": 3, "episodeRange": {"from": 1, "to": 4},
 "allEpisodes": false, "quality": "1080p", "qualityRemember": true,
 "subtitleLanguage": "ja", "subtitleLanguageRemember": false, "mode": "subscribe",
 "choiceIndex": 1}
''');
      expect(intent.kind, VideoAcquisitionIntentKind.provide);
      final VideoAcquisitionIntentPatch patch = intent.patch;
      expect(patch.workQueries, <String>[
        '葬送のフリーレン',
        'Sousou no Frieren',
        "Frieren: Beyond Journey's End",
      ]);
      expect(patch.category, VideoDiscoveryCategory.anime);
      expect(patch.season, 2);
      expect(patch.episode, 3);
      expect(patch.episodeRange, (from: 1, to: 4));
      expect(patch.allEpisodes, isFalse);
      expect(patch.quality, VideoAcquisitionQuality.p1080);
      expect(patch.qualityRemember, isTrue);
      expect(patch.subtitleLanguage, 'ja');
      expect(patch.subtitleLanguageRemember, isFalse);
      expect(patch.mode, VideoAcquisitionMode.subscribe);
      expect(patch.choiceIndex, 1);
      expect(patch.isEmpty, isFalse);
    });

    test('```json 围栏与前后散文都能容忍', () {
      final VideoAcquisitionIntent intent = _parse(
        'Sure, here is the patch:\n```json\n{"intent": "confirm"}\n```\nDone.',
      );
      expect(intent.kind, VideoAcquisitionIntentKind.confirm);
      expect(intent.patch.isEmpty, isTrue);
    });

    test('枚举越界逐字段丢弃：quality "4k" 丢、mode 留', () {
      final VideoAcquisitionIntent intent = _parse(
        '{"intent": "provide", "quality": "4k", "mode": "download", '
        '"category": "ova", "subtitleLanguage": "xx"}',
      );
      expect(intent.kind, VideoAcquisitionIntentKind.provide);
      expect(intent.patch.quality, isNull);
      expect(intent.patch.category, isNull);
      expect(intent.patch.subtitleLanguage, isNull, reason: 'xx 不在白名单');
      expect(intent.patch.mode, VideoAcquisitionMode.download);
    });

    test('字幕语言白名单覆盖 OpenSubtitles 常见语言（fra / es-ES 归一）', () {
      expect(
        _parse(
          '{"intent": "provide", "subtitleLanguage": "fra"}',
        ).patch.subtitleLanguage,
        'fr',
      );
      expect(
        _parse(
          '{"intent": "provide", "subtitleLanguage": "es-ES"}',
        ).patch.subtitleLanguage,
        'es',
      );
    });

    test('scope：整套 / 全部剧场版 / 全部剧集，非法值丢弃', () {
      expect(
        _parse('{"intent": "provide", "scope": "movies"}').patch.scope,
        VideoAcquisitionScope.franchiseMovies,
      );
      expect(
        _parse('{"intent": "provide", "scope": "ALL"}').patch.scope,
        VideoAcquisitionScope.franchise,
      );
      expect(
        _parse('{"intent": "provide", "scope": "everything"}').patch.scope,
        isNull,
      );
    });

    test('系统提示列出 scope 的全部枚举值', () {
      final String prompt = buildVideoAcquisitionIntentSystemPrompt(
        locale: 'zh-CN',
      );
      for (final VideoAcquisitionScope scope in VideoAcquisitionScope.values) {
        expect(prompt, contains('"${scope.storageKey}"'));
      }
    });

    // BUG-2963：「全部哆啦A梦剧场版」被解析成 category=movie，作品搜索只剩 TMDB，
    // 服务端没配 TMDB key 就直接「TMDB is not configured」；动画剧场版属于 anime。
    test('BUG-2963 category 是媒介不是形态：动画剧场版归 anime，用 scope 表达「全部剧场版」', () {
      final String prompt = buildVideoAcquisitionIntentSystemPrompt(
        locale: 'zh-CN',
      );
      expect(prompt, contains('"category" is the medium, not the format'));
      expect(prompt, contains('including anime theatrical films'));
      expect(
        prompt,
        contains('"category": "anime" with "scope": "movies", never'),
      );
    });

    test('「帮我下 X」不算选了模式：放送中的作品要留给 app 去问下载还是订阅', () {
      final String prompt = buildVideoAcquisitionIntentSystemPrompt(
        locale: 'zh-CN',
      );
      expect(prompt, contains('does NOT state a mode'));
      expect(prompt, contains('帮我下X'));
      expect(prompt, isNot(contains('"download" for "download / get')));
    });

    test('quality "best" / "1440p" 是合法档位', () {
      expect(
        _parse('{"intent": "provide", "quality": "best"}').patch.quality,
        VideoAcquisitionQuality.best,
      );
      expect(
        _parse('{"intent": "provide", "quality": "1440p"}').patch.quality,
        VideoAcquisitionQuality.p1440,
      );
    });

    test('枚举比对忽略大小写；quality 走 fromStorageKey', () {
      final VideoAcquisitionIntent intent = _parse(
        '{"intent": "Provide", "mode": "SUBSCRIBE", "quality": "1080P", '
        '"category": "Anime"}',
      );
      expect(intent.kind, VideoAcquisitionIntentKind.provide);
      expect(intent.patch.mode, VideoAcquisitionMode.subscribe);
      expect(intent.patch.quality, VideoAcquisitionQuality.p1080);
      expect(intent.patch.category, VideoDiscoveryCategory.anime);
    });

    test('subtitleLanguage 先归一再比白名单；original / none 原样', () {
      expect(
        _parse(
          '{"intent":"provide","subtitleLanguage":"jpn"}',
        ).patch.subtitleLanguage,
        'ja',
      );
      expect(
        _parse(
          '{"intent":"provide","subtitleLanguage":"zh-CN"}',
        ).patch.subtitleLanguage,
        'zh',
      );
      expect(
        _parse(
          '{"intent":"provide","subtitleLanguage":"Original"}',
        ).patch.subtitleLanguage,
        kVideoAcquisitionSubtitleOriginal,
      );
      expect(
        _parse(
          '{"intent":"provide","subtitleLanguage":"none"}',
        ).patch.subtitleLanguage,
        kVideoAcquisitionSubtitleNone,
      );
      expect(
        _parse('{"intent":"provide","subtitleLanguage":42}').kind,
        VideoAcquisitionIntentKind.unclear,
        reason: '非字符串丢弃后补丁全空 → unclear',
      );
    });

    test('choiceIndex 宽容解析：int / "1" / 1.0；越界或没有问题 → null', () {
      for (final String raw in <String>['1', '"1"', '1.0']) {
        final VideoAcquisitionIntent intent = _parse(
          '{"intent": "choose", "choiceIndex": $raw}',
        );
        expect(intent.kind, VideoAcquisitionIntentKind.choose, reason: raw);
        expect(intent.patch.choiceIndex, 1, reason: raw);
      }
      for (final String raw in <String>['3', '-1', '1.5', '"x"', 'null']) {
        expect(
          _parse('{"intent": "choose", "choiceIndex": $raw}').patch.choiceIndex,
          isNull,
          reason: raw,
        );
      }
      expect(
        _parse(
          '{"intent": "choose", "choiceIndex": 0}',
          optionCount: 0,
        ).patch.choiceIndex,
        isNull,
        reason: '没有挂起的问题时下标无意义',
      );
    });

    test('season / episode / episodeRange 越界丢弃', () {
      final VideoAcquisitionIntent intent = _parse(
        '{"intent": "provide", "season": 0, "episode": 10000, '
        '"episodeRange": {"from": 5, "to": 2}, "mode": "download"}',
      );
      expect(intent.patch.season, isNull);
      expect(intent.patch.episode, isNull);
      expect(intent.patch.episodeRange, isNull);
      expect(intent.patch.mode, VideoAcquisitionMode.download);

      final VideoAcquisitionIntent edge = _parse(
        '{"intent": "provide", "season": 99, "episode": "12", '
        '"episodeRange": {"from": 1.0, "to": 9999}}',
      );
      expect(edge.patch.season, 99);
      expect(edge.patch.episode, 12);
      expect(edge.patch.episodeRange, (from: 1, to: 9999));
      expect(
        _parse('{"intent":"provide","episodeRange":{"from":1}}').kind,
        VideoAcquisitionIntentKind.unclear,
        reason: '缺 to 的范围整个丢弃',
      );
    });

    test('workQueries 截断 / 折叠空白 / 去重 / 最多 4 条', () {
      final String long = 'x' * 100;
      final VideoAcquisitionIntent intent = _parse(
        '{"intent": "provide", "workQueries": ["  a   b ", "A B", "$long", '
        '"", 7, "c", "d", "e"]}',
      );
      expect(intent.patch.workQueries, <String>['a b', 'x' * 80, 'c', 'd']);
    });

    test('*Remember 非 bool → null', () {
      final VideoAcquisitionIntent intent = _parse(
        '{"intent": "provide", "quality": "720p", "qualityRemember": "yes", '
        '"subtitleLanguageRemember": 1, "allEpisodes": "true"}',
      );
      expect(intent.patch.qualityRemember, isNull);
      expect(intent.patch.subtitleLanguageRemember, isNull);
      expect(intent.patch.allEpisodes, isNull);
      expect(intent.patch.quality, VideoAcquisitionQuality.p720);
    });

    test('「哪个最好」→ recommend，choiceIndex 可选且按 optionCount 校验（BUG-2933）', () {
      final VideoAcquisitionIntent bare = _parse('{"intent": "recommend"}');
      expect(bare.kind, VideoAcquisitionIntentKind.recommend);
      expect(bare.patch.choiceIndex, isNull);
      final VideoAcquisitionIntent picked = _parse(
        '{"intent": "recommend", "choiceIndex": 1}',
      );
      expect(picked.kind, VideoAcquisitionIntentKind.recommend);
      expect(picked.patch.choiceIndex, 1);
      final VideoAcquisitionIntent outOfRange = _parse(
        '{"intent": "recommend", "choiceIndex": 9}',
      );
      expect(outOfRange.kind, VideoAcquisitionIntentKind.recommend);
      expect(outOfRange.patch.choiceIndex, isNull);
    });

    test('坏 JSON / 非对象 / intent 越界 → unclear', () {
      for (final String reply in <String>[
        '{"intent": }',
        'no json',
        '[1]',
        '{"quality": "1080p"}',
        '{"intent": "download", "quality": "1080p"}',
      ]) {
        final VideoAcquisitionIntent intent = _parse(reply);
        expect(intent.kind, VideoAcquisitionIntentKind.unclear, reason: reply);
        expect(intent.patch.isEmpty, isTrue, reason: reply);
      }
    });

    test('intent=provide 且补丁全空 → unclear；其它意图允许空补丁', () {
      expect(
        _parse('{"intent": "provide"}').kind,
        VideoAcquisitionIntentKind.unclear,
      );
      expect(
        _parse('{"intent": "provide", "quality": "4k"}').kind,
        VideoAcquisitionIntentKind.unclear,
        reason: '唯一字段被丢弃后等于什么都没说',
      );
      for (final VideoAcquisitionIntentKind kind
          in VideoAcquisitionIntentKind.values) {
        if (kind == VideoAcquisitionIntentKind.provide) continue;
        expect(_parse('{"intent": "${kind.name}"}').kind, kind);
      }
    });
  });

  group('提示词', () {
    test('系统提示含全部枚举值、locale 与「不决策不发问」的边界', () {
      final String prompt = buildVideoAcquisitionIntentSystemPrompt(
        locale: 'zh-CN',
      );
      for (final VideoAcquisitionIntentKind kind
          in VideoAcquisitionIntentKind.values) {
        expect(prompt, contains('"${kind.name}"'));
      }
      for (final VideoAcquisitionMode mode in VideoAcquisitionMode.values) {
        expect(prompt, contains('"${mode.name}"'));
      }
      for (final VideoAcquisitionQuality quality
          in VideoAcquisitionQuality.values) {
        expect(prompt, contains('"${quality.storageKey}"'));
      }
      for (final String code in kVideoAcquisitionSubtitleLanguageCodes) {
        expect(prompt, contains('"$code"'));
      }
      expect(prompt, contains('"$kVideoAcquisitionSubtitleOriginal"'));
      expect(prompt, contains('"$kVideoAcquisitionSubtitleNone"'));
      for (final VideoDiscoveryCategory category
          in VideoDiscoveryCategory.values) {
        expect(prompt, contains('"${category.name}"'));
      }
      expect(prompt, contains('"zh-CN"'));
      expect(prompt, contains('never ask questions'));
      expect(prompt, contains('choiceIndex'));
      expect(prompt, contains('80 characters'));
    });

    test('用户提示是 JSON：含 options（index+label）、slots、history、utterance', () {
      final String prompt = buildVideoAcquisitionIntentUserPrompt(
        _query(
          history: <({String role, String text})>[
            (role: 'user', text: '下 Frieren'),
            (role: 'assistant', text: '要什么画质？'),
          ],
        ),
      );
      final Map<String, Object?> decoded =
          jsonDecode(prompt) as Map<String, Object?>;
      expect(decoded['locale'], 'zh-CN');
      expect(decoded['stage'], 'collectingSlots');
      expect(decoded['utterance'], '1080 的');
      final Map<String, Object?> pending =
          decoded['pendingQuestion'] as Map<String, Object?>;
      expect(pending['slot'], 'quality');
      final List<Object?> options = pending['options'] as List<Object?>;
      expect(options, hasLength(3));
      expect((options[1] as Map<String, Object?>)['index'], 1);
      expect((options[1] as Map<String, Object?>)['label'], '1080p');
      expect(
        (options[2] as Map<String, Object?>)['label'],
        '720p',
        reason: 'label 为空时回落 id',
      );
      expect(
        (decoded['slots'] as Map<String, Object?>)['workTitle'],
        'Frieren',
      );
      final List<Object?> history = decoded['history'] as List<Object?>;
      expect(history, hasLength(2));
      expect((history.first as Map<String, Object?>)['role'], 'user');
    });

    test('没有挂起问题时 pendingQuestion 为 null；history 只留最后 6 条', () {
      final VideoAcquisitionIntentQuery query = _query(
        pendingQuestion: null,
        history: <({String role, String text})>[
          for (int i = 0; i < 9; i += 1) (role: 'user', text: 'm$i'),
        ],
      );
      expect(query.history, hasLength(kVideoAcquisitionIntentHistoryLimit));
      expect(query.history.first.text, 'm3');
      expect(query.history.last.text, 'm8');
      final Map<String, Object?> decoded =
          jsonDecode(buildVideoAcquisitionIntentUserPrompt(query))
              as Map<String, Object?>;
      expect(decoded['pendingQuestion'], isNull);
    });

    test('candidates：非空时进用户提示，空时整个键不出现（BUG-2933）', () {
      final VideoAcquisitionIntentQuery withCandidates =
          VideoAcquisitionIntentQuery(
            utterance: '哪个最好',
            stage: VideoAcquisitionStage.awaitingResourceConfirm.name,
            locale: 'zh-CN',
            pendingQuestion: null,
            slots: const <String, Object?>{},
            candidates: const <Map<String, Object?>>[
              <String, Object?>{
                'optionIndex': 0,
                'current': true,
                'releaseGroup': 'Alpha',
              },
              <String, Object?>{
                'optionIndex': 1,
                'current': false,
                'releaseGroup': 'Beta',
              },
            ],
          );
      final Map<String, Object?> decoded =
          jsonDecode(buildVideoAcquisitionIntentUserPrompt(withCandidates))
              as Map<String, Object?>;
      final List<Object?> candidates = decoded['candidates'] as List<Object?>;
      expect(candidates, hasLength(2));
      expect((candidates[1] as Map<String, Object?>)['releaseGroup'], 'Beta');

      final Map<String, Object?> without =
          jsonDecode(buildVideoAcquisitionIntentUserPrompt(_query()))
              as Map<String, Object?>;
      expect(without.containsKey('candidates'), isFalse);
    });

    test('系统提示讲清 recommend 与 candidates 的用法（BUG-2933）', () {
      final String prompt = buildVideoAcquisitionIntentSystemPrompt(
        locale: 'zh-CN',
      );
      expect(prompt, contains('"recommend"'));
      expect(prompt, contains('"candidates"'));
      expect(prompt, contains('optionIndex'));
    });

    test('身份判定系统提示：口头作品名语境、多季无季号 → null、不选剧场版', () {
      final String prompt = buildAiVideoAcquisitionIdentitySystemPrompt(
        locale: 'ja',
      );
      expect(prompt, contains('"key"'));
      expect(prompt, contains('"confidence"'));
      expect(prompt, contains('did not mention a season'));
      expect(prompt, contains('OVA'));
      expect(prompt, contains('"ja"'));
      expect(
        prompt,
        isNot(contains('local video folder')),
        reason: '不是刮削那份「本地目录」提示',
      );
    });
  });

  group('requestVideoAcquisitionIntent', () {
    test('发 system+user 两条、max_tokens 512，回复按 optionCount 校验', () async {
      late Map<String, Object?> sent;
      final AiChatClient client = _clientReplying(
        '{"intent": "choose", "choiceIndex": "1"}',
        onRequest: (Map<String, Object?> body) => sent = body,
      );
      final VideoAcquisitionIntent intent = await requestVideoAcquisitionIntent(
        client: client,
        provider: _provider(),
        query: _query(),
      );
      final List<Object?> messages = sent['messages'] as List<Object?>;
      expect(messages, hasLength(2));
      expect((messages.first as Map<String, Object?>)['role'], 'system');
      expect(
        (messages.first as Map<String, Object?>)['content'],
        contains('"choose"'),
      );
      expect((messages.last as Map<String, Object?>)['role'], 'user');
      expect(
        (messages.last as Map<String, Object?>)['content'],
        contains('"1080 的"'),
      );
      expect(sent['max_tokens'], 512);
      expect(intent.kind, VideoAcquisitionIntentKind.choose);
      expect(intent.patch.choiceIndex, 1);
    });

    test('没有挂起问题时 optionCount = 0，choiceIndex 一律丢弃', () async {
      final VideoAcquisitionIntent intent = await requestVideoAcquisitionIntent(
        client: _clientReplying('{"intent": "confirm", "choiceIndex": 0}'),
        provider: _provider(),
        query: _query(pendingQuestion: null),
      );
      expect(intent.kind, VideoAcquisitionIntentKind.confirm);
      expect(intent.patch.choiceIndex, isNull);
    });
  });

  group('requestAiVideoAcquisitionIdentity', () {
    test('走本流程的系统提示，回复经候选 key 白名单', () async {
      late Map<String, Object?> sent;
      final AiVideoIdentityQuery query = AiVideoIdentityQuery(
        localTitles: <String>['Frieren', '葬送のフリーレン'],
        candidates: <AiVideoIdentityCandidate>[
          AiVideoIdentityCandidate(
            key: 'mal:52991',
            titles: <String>['Sousou no Frieren'],
            mediaKind: VideoMetadataMediaKind.tv,
            year: 2023,
          ),
          AiVideoIdentityCandidate(
            key: 'mal:59978',
            titles: <String>['Sousou no Frieren 2nd Season'],
            mediaKind: VideoMetadataMediaKind.tv,
            year: 2026,
          ),
        ],
        locale: 'zh-CN',
      );
      final AiVideoIdentityDecision decision =
          await requestAiVideoAcquisitionIdentity(
            client: _clientReplying(
              '{"key": "mal:99999", "confidence": 0.99, "reason": "编的"}',
              onRequest: (Map<String, Object?> body) => sent = body,
            ),
            provider: _provider(),
            query: query,
          );
      expect(decision.key, isNull, reason: '不在候选集合里的 key 丢弃');
      expect(decision.confidence, 0);
      final List<Object?> messages = sent['messages'] as List<Object?>;
      expect(
        (messages.first as Map<String, Object?>)['content'],
        contains('The user named a video work'),
      );
      expect(
        (messages.last as Map<String, Object?>)['content'],
        contains('"mal:59978"'),
      );
    });
  });

  group('生产装配', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    Future<void> assign() async {
      await prefs.setAiProviders(<AiProviderConfig>[_provider()]);
      await prefs.setAiFeatureAssignments(
        const AiFeatureAssignments().withAssignment(AiFeature.acquire, 'p'),
      );
    }

    test('未指派 → 两个装配都回 null 且不发请求', () async {
      int requests = 0;
      AiChatClient factory() => _clientReplying(
        '{"intent":"confirm"}',
        onRequest: (_) => requests += 1,
      );
      expect(resolveVideoAcquireAiProvider(prefs), isNull);
      final VideoAcquisitionIntent? intent =
          await createPreferencesVideoAcquisitionIntentParser(
            prefs,
            clientFactory: factory,
          )(_query());
      expect(intent, isNull);
      final AiVideoIdentityDecision? decision =
          await createPreferencesVideoAcquisitionIdentityDecider(
            prefs,
            clientFactory: factory,
          )(
            AiVideoIdentityQuery(
              localTitles: <String>['x'],
              candidates: <AiVideoIdentityCandidate>[],
            ),
          );
      expect(decision, isNull);
      expect(requests, 0);
    });

    test('指派了 acquire（而非 videoIdentify）→ 现取提供商并发请求', () async {
      await assign();
      expect(resolveVideoAcquireAiProvider(prefs)?.id, 'p');
      int requests = 0;
      final VideoAcquisitionIntent? intent =
          await createPreferencesVideoAcquisitionIntentParser(
            prefs,
            clientFactory: () => _clientReplying(
              '{"intent":"provide","mode":"subscribe"}',
              onRequest: (_) => requests += 1,
            ),
          )(_query());
      expect(intent?.kind, VideoAcquisitionIntentKind.provide);
      expect(intent?.patch.mode, VideoAcquisitionMode.subscribe);
      expect(requests, 1);
    });

    test('调用失败：AiChatFailure 原样抛出', () async {
      await assign();
      final AiChatClient failing = AiChatClient(
        client: MockClient(
          (http.Request request) async => http.Response('nope', 500),
        ),
      );
      await expectLater(
        createPreferencesVideoAcquisitionIntentParser(
          prefs,
          clientFactory: () => failing,
        )(_query()),
        throwsA(isA<AiChatFailure>()),
      );
      await expectLater(
        createPreferencesVideoAcquisitionIdentityDecider(
          prefs,
          clientFactory: () => failing,
        )(
          AiVideoIdentityQuery(
            localTitles: <String>['x'],
            candidates: <AiVideoIdentityCandidate>[],
          ),
        ),
        throwsA(isA<AiChatFailure>()),
      );
    });
  });

  group('别名 → 正式名（联网资料）', () {
    setUp(WebKnowledgeClient.resetFailureCooldowns);

    /// 只开中文维基；响应形状取自 2026-09-29 对 zh.wikipedia.org 的实测。
    WebKnowledgeClient zhWiki({required bool hit}) => WebKnowledgeClient(
      sites: <WebKnowledgeSite>[kBuiltinWebKnowledgeSites.first],
      client: MockClient((http.Request request) async {
        final String action = request.url.queryParameters['action'] ?? '';
        final Object body = action == 'opensearch'
            ? <Object?>[
                'fx外汇战士',
                if (hit) <String>['FX战士久留美'] else <String>[],
                if (hit) <String>[''] else <String>[],
                if (hit)
                  <String>['https://zh.wikipedia.org/wiki/FX战士久留美']
                else
                  <String>[],
              ]
            : <String, Object?>{
                'query': <String, Object?>{
                  'pages': <Object?>[
                    <String, Object?>{
                      'title': 'FX战士久留美',
                      'extract':
                          '《FX战士久留美》（日语：FX戦士くるみちゃん）是日本的漫画作品，'
                          '2023年改编为电视动画。',
                    },
                  ],
                },
              };
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
      }),
    );

    test('资料命中 → 资料正文进提示词，返回 AI 抄出的正式名（去掉原话）', () async {
      Map<String, Object?>? sent;
      final List<String> titles = await requestAiVideoAlias(
        client: _clientReplying(
          '{"queries": ["FX戦士くるみちゃん", "fx外汇战士", "FX战士久留美"]}',
          onRequest: (Map<String, Object?> body) => sent = body,
        ),
        provider: _provider(),
        web: zhWiki(hit: true),
        query: 'fx外汇战士',
      );
      expect(titles, <String>['FX戦士くるみちゃん', 'FX战士久留美']);
      final String prompt = jsonEncode(sent);
      expect(prompt, contains('FX戦士くるみちゃん'));
      expect(prompt, contains('fx外汇战士'));
    });

    test('资料站没有结果 → 空，且不发 AI 请求', () async {
      bool called = false;
      final List<String> titles = await requestAiVideoAlias(
        client: _clientReplying(
          '{"queries": ["X"]}',
          onRequest: (_) => called = true,
        ),
        provider: _provider(),
        web: zhWiki(hit: false),
        query: 'fx外汇战士',
      );
      expect(titles, isEmpty);
      expect(called, isFalse);
    });

    test('没启用资料站 → 空，且不发 AI 请求', () async {
      bool called = false;
      final List<String> titles = await requestAiVideoAlias(
        client: _clientReplying(
          '{"queries": ["X"]}',
          onRequest: (_) => called = true,
        ),
        provider: _provider(),
        web: WebKnowledgeClient(sites: const <WebKnowledgeSite>[]),
        query: 'fx外汇战士',
      );
      expect(titles, isEmpty);
      expect(called, isFalse);
    });
  });
}
