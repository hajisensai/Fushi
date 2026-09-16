import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/ai/ai_video_identity_assistant.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Set<String> _keys = <String>{'mal:1', 'mal:2', 'tmdb:300'};

AiVideoIdentityQuery _query() => AiVideoIdentityQuery(
  localTitles: <String>['ドラえもん 2005', 'Doraemon'],
  season: 1,
  episodeCount: 12,
  year: 2005,
  sampleFileNames: <String>[for (int i = 1; i <= 7; i++) 'Doraemon - $i.mkv'],
  candidates: <AiVideoIdentityCandidate>[
    AiVideoIdentityCandidate(
      key: 'mal:1',
      titles: <String>['Doraemon (2005)', 'ドラえもん', '', 'ドラえもん'],
      mediaKind: VideoMetadataMediaKind.tv,
      year: 2005,
      synopsis: 'A' * 500,
    ),
    AiVideoIdentityCandidate(
      key: 'mal:2',
      titles: <String>['Doraemon (1979)'],
      mediaKind: VideoMetadataMediaKind.tv,
      year: 1979,
      episodeCount: 1787,
    ),
    AiVideoIdentityCandidate(
      key: 'tmdb:300',
      titles: <String>['Stand by Me Doraemon'],
      mediaKind: VideoMetadataMediaKind.movie,
      year: 2014,
    ),
  ],
  locale: 'zh-CN',
);

void main() {
  group('parseAiVideoIdentityDecision', () {
    test('合法回复：key 在集合内、置信度与理由原样带回', () {
      final AiVideoIdentityDecision decision = parseAiVideoIdentityDecision(
        '```json\n{"key": "mal:1", "confidence": 0.93, "reason": "标题年份一致"}\n```',
        allowedKeys: _keys,
      );
      expect(decision.key, 'mal:1');
      expect(decision.confidence, 0.93);
      expect(decision.reason, '标题年份一致');
      expect(decision.isAutoAcceptable, isTrue);
      expect(decision.confidencePercent, 93);
    });

    test('key 不在候选集合里视为 null，置信度归零', () {
      final AiVideoIdentityDecision decision = parseAiVideoIdentityDecision(
        '{"key": "mal:999", "confidence": 0.99, "reason": "编的"}',
        allowedKeys: _keys,
      );
      expect(decision.key, isNull);
      expect(decision.confidence, 0);
      expect(decision.isAutoAcceptable, isFalse);
    });

    test('key 为 null 时不自动采用', () {
      final AiVideoIdentityDecision decision = parseAiVideoIdentityDecision(
        '{"key": null, "confidence": 0.95, "reason": "两条都像"}',
        allowedKeys: _keys,
      );
      expect(decision.key, isNull);
      expect(decision.isAutoAcceptable, isFalse);
      expect(decision.reason, '两条都像');
    });

    test('置信度越界 / 非数值 → 0', () {
      for (final String raw in <String>['1.5', '-0.1', '"high"', 'null']) {
        final AiVideoIdentityDecision decision = parseAiVideoIdentityDecision(
          '{"key": "mal:1", "confidence": $raw}',
          allowedKeys: _keys,
        );
        expect(decision.key, 'mal:1', reason: raw);
        expect(decision.confidence, 0, reason: raw);
        expect(decision.isAutoAcceptable, isFalse, reason: raw);
      }
    });

    test('低于门槛的合法置信度不自动采用', () {
      final AiVideoIdentityDecision decision = parseAiVideoIdentityDecision(
        '{"key": "mal:1", "confidence": 0.6}',
        allowedKeys: _keys,
      );
      expect(decision.key, 'mal:1');
      expect(decision.confidence, 0.6);
      expect(decision.isAutoAcceptable, isFalse);
      expect(kAiVideoIdentityAutoAcceptConfidence, 0.85);
    });

    test('坏 JSON / 没有对象 → key null、置信度 0', () {
      for (final String reply in <String>['{"key": }', 'no json', '[1]']) {
        final AiVideoIdentityDecision decision = parseAiVideoIdentityDecision(
          reply,
          allowedKeys: _keys,
        );
        expect(decision.key, isNull, reason: reply);
        expect(decision.confidence, 0, reason: reply);
      }
    });
  });

  group('提示词', () {
    test('用户提示包含全部候选 key 与标题、本地线索；简介截断、文件名限 5 条', () {
      final AiVideoIdentityQuery query = _query();
      final String prompt = buildAiVideoIdentityUserPrompt(query);
      final Map<String, Object?> decoded =
          jsonDecode(prompt) as Map<String, Object?>;
      for (final String key in _keys) {
        expect(prompt, contains('"$key"'));
      }
      expect(prompt, contains('Doraemon (2005)'));
      expect(prompt, contains('Doraemon (1979)'));
      expect(prompt, contains('Stand by Me Doraemon'));
      expect(prompt, contains('ドラえもん 2005'));
      expect(decoded['season'], 1);
      expect(decoded['localEpisodeCount'], 12);
      expect(decoded['year'], 2005);
      expect((decoded['sampleFileNames'] as List<Object?>).length, 5);
      expect(query.candidates.first.titles, <String>[
        'Doraemon (2005)',
        'ドラえもん',
      ]);
      final String synopsis = query.candidates.first.synopsis!;
      expect(synopsis.length, kAiVideoIdentitySynopsisMaxChars + 1);
      expect(synopsis, endsWith('…'));
    });

    test('系统提示要求只回 JSON、说明 null 规则、带上 locale', () {
      final String prompt = buildAiVideoIdentitySystemPrompt(locale: 'ja');
      expect(prompt, contains('"key"'));
      expect(prompt, contains('"confidence"'));
      expect(prompt, contains('null'));
      expect(prompt, contains('season'));
      expect(prompt, contains('episode count'));
      expect(prompt, contains('"ja"'));
    });

    test('cacheKey 只看本地线索与候选 key，与候选顺序无关的字段变了才变', () {
      final AiVideoIdentityQuery a = _query();
      final AiVideoIdentityQuery b = _query();
      expect(a.cacheKey, b.cacheKey);
      final AiVideoIdentityQuery c = AiVideoIdentityQuery(
        localTitles: a.localTitles,
        candidates: a.candidates.take(2).toList(),
        season: a.season,
        episodeCount: a.episodeCount,
        year: a.year,
      );
      expect(c.cacheKey, isNot(a.cacheKey));
    });
  });

  group('requestAiVideoIdentity', () {
    test('走 AiChatClient 发 system+user 两条消息，回复经白名单校验', () async {
      late Map<String, Object?> sent;
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{
                    'content':
                        '{"key": "mal:1", "confidence": 0.9, "reason": "ok"}',
                  },
                },
              ],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      final AiVideoIdentityDecision decision = await requestAiVideoIdentity(
        client: client,
        provider: AiProviderConfig(
          id: 'p',
          presetId: 'custom',
          name: 'Test',
          baseUrl: Uri.parse('https://example.test/v1'),
          apiKey: 'k',
          model: 'm',
        ),
        query: _query(),
      );
      final List<Object?> messages = sent['messages'] as List<Object?>;
      expect(messages, hasLength(2));
      expect((messages.first as Map<String, Object?>)['role'], 'system');
      expect((messages.last as Map<String, Object?>)['role'], 'user');
      expect(
        (messages.last as Map<String, Object?>)['content'],
        contains('"tmdb:300"'),
      );
      expect(decision.key, 'mal:1');
      expect(decision.isAutoAcceptable, isTrue);
    });
  });

  group('运行记录标记', () {
    test('编码后能原样解出置信度与理由', () {
      const AiVideoIdentityDecision decision = AiVideoIdentityDecision(
        key: 'mal:1',
        confidence: 0.934,
        reason: '标题、年份与季号一致',
      );
      final String message = encodeVideoScrapeAiIdentityNote(decision);
      expect(message, startsWith(kVideoScrapeAiIdentityNotePrefix));
      final VideoScrapeAiIdentityNote note = parseVideoScrapeAiIdentityNote(
        message,
      )!;
      expect(note.confidencePercent, 93);
      expect(note.reason, '标题、年份与季号一致');
    });

    test('没有理由时也能解析；普通 warning 不被误判', () {
      const AiVideoIdentityDecision decision = AiVideoIdentityDecision(
        key: 'mal:1',
        confidence: 1,
      );
      final VideoScrapeAiIdentityNote note = parseVideoScrapeAiIdentityNote(
        encodeVideoScrapeAiIdentityNote(decision),
      )!;
      expect(note.confidencePercent, 100);
      expect(note.reason, '');
      expect(parseVideoScrapeAiIdentityNote('匹配结果存在歧义'), isNull);
      expect(parseVideoScrapeAiIdentityNote('ai:matched'), isNull);
    });
  });
}
