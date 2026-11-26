// BUG-5468：OpenAI 提供商从 gpt-5-mini（推理档位「低」）换成 gpt-4o-mini 后，存着的
// `reasoningEffort` 照发 `reasoning_effort`，官方对非推理模型回 400
// `unsupported_parameter`，此后每个请求都失败，界面只报「服务返回错误（400）」。
import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final Uri _official = Uri.parse('https://api.openai.com/v1');

AiProviderConfig _provider({
  required String model,
  AiReasoningEffort effort = AiReasoningEffort.low,
  String baseUrl = 'https://api.openai.com/v1',
}) => AiProviderConfig(
  id: 'p',
  presetId: 'openai',
  name: 'OpenAI',
  baseUrl: Uri.parse(baseUrl),
  apiKey: 'sk-test',
  model: model,
  protocol: AiWireProtocol.openAiCompatible,
  reasoningEffort: effort,
);

bool _accepts(String model, {Uri? baseUrl}) => aiModelAcceptsReasoningEffort(
  protocol: AiWireProtocol.openAiCompatible,
  baseUrl: baseUrl ?? _official,
  model: model,
);

AiChatFailure _classify(int status, String body) => classifyAiHttpFailure(
  statusCode: status,
  bodyBytes: utf8.encode(body),
  retryAfterHeader: null,
  now: DateTime(2026, 11, 23),
);

void main() {
  group('aiModelAcceptsReasoningEffort', () {
    test('OpenAI 官方：旧族非推理模型不收', () {
      for (final String model in <String>[
        'gpt-4o-mini',
        'gpt-4o',
        'GPT-4o-2024-08-06',
        'gpt-4.1',
        'gpt-4.1-nano',
        'gpt-4-turbo',
        'gpt-3.5-turbo',
        'chatgpt-4o-latest',
        'gpt-5-chat-latest',
        'gpt-5.1-chat-latest',
        'gpt-5-search-api',
        'ft:gpt-4o-mini-2024-07-18:org::abc123',
      ]) {
        expect(_accepts(model), isFalse, reason: model);
      }
    });

    test('OpenAI 官方：推理模型（含 Fushi 还不认识的新模型）收', () {
      for (final String model in <String>[
        'gpt-5-mini',
        'gpt-5',
        'gpt-5.1',
        'o3-mini',
        'o4-mini',
        'o1',
        'gpt-6',
        'ft:o4-mini-2025-04-16:org::abc',
      ]) {
        expect(_accepts(model), isTrue, reason: model);
      }
    });

    test('其余兼容端点信用户的显式选择（Fushi 无从得知它收不收）', () {
      expect(
        _accepts(
          'gpt-4o-mini',
          baseUrl: Uri.parse('https://openrouter.ai/api/v1'),
        ),
        isTrue,
      );
      expect(
        _accepts(
          'deepseek-chat',
          baseUrl: Uri.parse('https://api.deepseek.com'),
        ),
        isTrue,
      );
    });

    test('Anthropic / Gemini 载荷从不带这个字段 → 不收', () {
      for (final AiWireProtocol protocol in <AiWireProtocol>[
        AiWireProtocol.anthropicMessages,
        AiWireProtocol.geminiGenerateContent,
      ]) {
        expect(
          aiModelAcceptsReasoningEffort(
            protocol: protocol,
            baseUrl: Uri.parse('https://api.anthropic.com'),
            model: 'claude-sonnet-5',
          ),
          isFalse,
          reason: protocol.name,
        );
      }
    });

    test('effectiveAiReasoningEffort：不收时归 none，收时原样', () {
      expect(
        effectiveAiReasoningEffort(_provider(model: 'gpt-4o-mini')),
        AiReasoningEffort.none,
      );
      expect(
        effectiveAiReasoningEffort(
          _provider(model: 'gpt-5-mini', effort: AiReasoningEffort.high),
        ),
        AiReasoningEffort.high,
      );
    });
  });

  group('请求载荷', () {
    late List<Map<String, Object?>> sent;

    AiChatClient clientReplying(http.Response Function() reply) {
      sent = <Map<String, Object?>>[];
      return AiChatClient(
        client: MockClient((http.Request request) async {
          sent.add(jsonDecode(request.body) as Map<String, Object?>);
          return reply();
        }),
        rateLimiter: AiRateLimiter(),
      );
    }

    http.Response ok() => http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

    test('复现路径：gpt-4o-mini + 存着的「低」→ 不发 reasoning_effort，请求成功', () async {
      final AiChatClient client = clientReplying(ok);
      addTearDown(client.close);
      final String reply = await client.complete(
        provider: _provider(model: 'gpt-4o-mini'),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      );
      expect(reply, 'ok');
      expect(sent.single.containsKey('reasoning_effort'), isFalse);
    });

    test('gpt-5-mini + 「低」→ 照发 reasoning_effort: low', () async {
      final AiChatClient client = clientReplying(ok);
      addTearDown(client.close);
      await client.complete(
        provider: _provider(model: 'gpt-5-mini'),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      );
      expect(sent.single['reasoning_effort'], 'low');
    });

    test('兼容端点不收：400 归成 reasoning_unsupported，只发一次、不重试', () async {
      final AiChatClient client = clientReplying(
        () => http.Response(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{
              'message':
                  "Unsupported parameter: 'reasoning_effort' is not "
                  'supported with this model.',
              'type': 'invalid_request_error',
              'param': 'reasoning_effort',
              'code': 'unsupported_parameter',
            },
          }),
          400,
          headers: <String, String>{'content-type': 'application/json'},
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.complete(
          provider: _provider(
            model: 'some-model',
            baseUrl: 'https://relay.example.com/v1',
          ),
          messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        ),
        throwsA(
          isA<AiChatFailure>()
              .having(
                (AiChatFailure f) => f.message,
                'message',
                kAiReasoningUnsupportedCode,
              )
              .having((AiChatFailure f) => f.isTransient, 'isTransient', false),
        ),
      );
      expect(sent, hasLength(1));
      expect(sent.single['reasoning_effort'], 'low');
    });
  });

  test('classifyAiHttpFailure：兼容层的其他措辞也认，不提该字段的 400 照旧', () {
    expect(
      _classify(
        400,
        '{"error":{"message":"Unrecognized request argument supplied: '
        'reasoning_effort"}}',
      ).message,
      kAiReasoningUnsupportedCode,
    );
    expect(
      _classify(
        422,
        '{"detail":"reasoning_effort: extra fields not permitted"}',
      ).message,
      kAiReasoningUnsupportedCode,
    );
    expect(_classify(400, '{"error":{"message":"bad"}}').message, 'http_400');
  });
}
