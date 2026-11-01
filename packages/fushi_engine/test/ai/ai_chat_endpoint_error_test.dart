// 反馈 GewyVIt5oo：本地 LM Studio 对它不认识的路径回
// `200 {"error":"Unexpected endpoint or method. (POST /chat/completions)"}`。
// 旧实现当成功应答解析，最终报「AI 没有返回内容」，用户无从判断是地址错了。
import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

AiProviderConfig _provider(AiWireProtocol protocol) => AiProviderConfig(
  id: 'p',
  // LM Studio 预设不要求 key。
  presetId: 'lmstudio',
  name: 'p',
  baseUrl: Uri.parse('http://192.168.0.178:1234'),
  model: 'm',
  protocol: protocol,
);

AiChatClient _client(Object reply) => AiChatClient(
  client: MockClient(
    (http.Request request) async => http.Response(
      jsonEncode(reply),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    ),
  ),
  rateLimiter: AiRateLimiter(),
);

Matcher _failure(String code) => isA<AiChatFailure>().having(
  (AiChatFailure f) => f.message,
  'message',
  code,
);

void main() {
  const Map<String, Object?> lmStudioError = <String, Object?>{
    'error': 'Unexpected endpoint or method. (POST /chat/completions)',
  };

  test('2xx 错误体：chat / complete / ping 都报 endpoint_error', () async {
    final AiProviderConfig provider = _provider(
      AiWireProtocol.openAiCompatible,
    );
    final AiChatClient client = _client(lmStudioError);
    addTearDown(client.close);
    const List<AiChatMessage> messages = <AiChatMessage>[
      AiChatMessage.user('hi'),
    ];
    await expectLater(
      client.chat(provider: provider, messages: messages),
      throwsA(_failure(kAiEndpointErrorCode)),
    );
    await expectLater(
      client.complete(provider: provider, messages: messages),
      throwsA(_failure(kAiEndpointErrorCode)),
    );
    await expectLater(
      client.ping(provider),
      throwsA(_failure(kAiEndpointErrorCode)),
    );
  });

  test('正常应答顺带 error: null 不受影响', () async {
    final AiChatClient client = _client(<String, Object?>{
      'error': null,
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'role': 'assistant', 'content': 'ok'},
        },
      ],
    });
    addTearDown(client.close);
    expect(
      await client.complete(
        provider: _provider(AiWireProtocol.openAiCompatible),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      'ok',
    );
  });
}
