import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `completeWithUsage` 按三种协议解析 token 用量：取不到的项是 null，**不是 0**
/// （费用统计要把缺失当「未知」单独计数）；`complete` 委托它、行为不变。
void main() {
  AiChatClient clientReturning(Object? body) => AiChatClient(
    rateLimiter: AiRateLimiter(),
    client: MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    ),
  );

  AiProviderConfig provider(AiWireProtocol protocol) => AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
    protocol: protocol,
  );

  Future<AiChatCompletion> ask(AiWireProtocol protocol, Object? body) async {
    final AiChatClient client = clientReturning(body);
    addTearDown(client.close);
    return client.completeWithUsage(
      provider: provider(protocol),
      messages: const <AiChatMessage>[AiChatMessage.user('hi')],
    );
  }

  Map<String, Object?> openAiBody(Map<String, Object?>? usage) =>
      <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
        if (usage != null) 'usage': usage,
      };

  test('OpenAI：cached_tokens 从 prompt_tokens 里减掉记成缓存读取；无缓存写入', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.openAiCompatible,
      openAiBody(<String, Object?>{
        'prompt_tokens': 1000,
        'completion_tokens': 50,
        'prompt_tokens_details': <String, Object?>{'cached_tokens': 600},
      }),
    );
    expect(r.text, 'ok');
    expect(
      r.usage,
      const AiChatUsage(
        inputTokens: 400,
        outputTokens: 50,
        cacheReadTokens: 600,
      ),
    );
    expect(r.usage!.cacheWriteTokens, isNull);
  });

  test('DeepSeek：prompt_cache_hit_tokens 当缓存读取', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.openAiCompatible,
      openAiBody(<String, Object?>{
        'prompt_tokens': 300,
        'completion_tokens': 20,
        'prompt_cache_hit_tokens': 100,
        'prompt_cache_miss_tokens': 200,
      }),
    );
    expect(
      r.usage,
      const AiChatUsage(
        inputTokens: 200,
        outputTokens: 20,
        cacheReadTokens: 100,
      ),
    );
  });

  test('OpenAI：没报缓存字段时缓存读取是 null 而不是 0', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.openAiCompatible,
      openAiBody(<String, Object?>{
        'prompt_tokens': 300,
        'completion_tokens': 20,
      }),
    );
    expect(r.usage!.inputTokens, 300);
    expect(r.usage!.cacheReadTokens, isNull);
  });

  test('应答没有 usage 段：usage 为 null；complete 照常只返回正文', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.openAiCompatible,
      openAiBody(null),
    );
    expect(r.text, 'ok');
    expect(r.usage, isNull);

    final AiChatClient client = clientReturning(openAiBody(null));
    addTearDown(client.close);
    expect(
      await client.complete(
        provider: provider(AiWireProtocol.openAiCompatible),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      'ok',
    );
  });

  test('usage 段里一个认得的字段都没有：null', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.openAiCompatible,
      openAiBody(<String, Object?>{'total_tokens': 'n/a'}),
    );
    expect(r.usage, isNull);
  });

  test('Anthropic：四项分开报', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.anthropicMessages,
      <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'ok'},
        ],
        'usage': <String, Object?>{
          'input_tokens': 12,
          'output_tokens': 345,
          'cache_read_input_tokens': 6789,
          'cache_creation_input_tokens': 1000,
        },
      },
    );
    expect(
      r.usage,
      const AiChatUsage(
        inputTokens: 12,
        outputTokens: 345,
        cacheReadTokens: 6789,
        cacheWriteTokens: 1000,
      ),
    );
  });

  test('Anthropic：没开提示缓存时缓存两项为 null', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.anthropicMessages,
      <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'ok'},
        ],
        'usage': <String, Object?>{'input_tokens': 12, 'output_tokens': 3},
      },
    );
    expect(r.usage!.cacheReadTokens, isNull);
    expect(r.usage!.cacheWriteTokens, isNull);
  });

  test('Gemini：缓存从 promptTokenCount 里减掉；思考算输出', () async {
    final AiChatCompletion r = await ask(
      AiWireProtocol.geminiGenerateContent,
      <String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': 'ok'},
              ],
            },
          },
        ],
        'usageMetadata': <String, Object?>{
          'promptTokenCount': 900,
          'cachedContentTokenCount': 400,
          'candidatesTokenCount': 30,
          'thoughtsTokenCount': 70,
        },
      },
    );
    expect(
      r.usage,
      const AiChatUsage(
        inputTokens: 500,
        outputTokens: 100,
        cacheReadTokens: 400,
      ),
    );
  });

  test('空正文仍抛 empty_response（与 complete 同一口径）', () async {
    final AiChatClient empty = AiChatClient(
      rateLimiter: AiRateLimiter(),
      client: MockClient(
        (http.Request request) async => http.Response(
          jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'message': <String, Object?>{'content': '  '},
              },
            ],
            'usage': <String, Object?>{'prompt_tokens': 5},
          }),
          200,
        ),
      ),
    );
    addTearDown(empty.close);
    await expectLater(
      empty.completeWithUsage(
        provider: provider(AiWireProtocol.openAiCompatible),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          'empty_response',
        ),
      ),
    );
  });

  test('AiChatUsage JSON 往返只带非 null 项', () {
    const AiChatUsage u = AiChatUsage(inputTokens: 3, cacheReadTokens: 0);
    expect(u.toJson(), <String, Object?>{'input': 3, 'cacheRead': 0});
    expect(AiChatUsage.fromJson(u.toJson()), u);
  });
}
