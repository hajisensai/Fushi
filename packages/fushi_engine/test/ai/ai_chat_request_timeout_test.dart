// BUG-5467：有声书选角一块回复几千 token，本地模型要生成几分钟；全局 90 秒时限
// 在模型还在正常吐字时就超时（再被当成网络抖动整块重试）。时限改成按客户端给，
// 回复本来就长的调用方建客户端时放宽。
import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final AiProviderConfig _provider = AiProviderConfig(
  id: 'p',
  presetId: 'lmstudio',
  name: 'p',
  baseUrl: Uri.parse('http://127.0.0.1:8888/v1'),
  model: 'm',
  protocol: AiWireProtocol.openAiCompatible,
);

/// 300 毫秒后才回一条正常应答的「慢模型」。
AiChatClient _slowClient({Duration? requestTimeout}) {
  final MockClient mock = MockClient((http.Request request) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': '[]'},
            'finish_reason': 'stop',
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  return requestTimeout == null
      ? AiChatClient(client: mock, rateLimiter: AiRateLimiter())
      : AiChatClient(
          client: mock,
          rateLimiter: AiRateLimiter(),
          requestTimeout: requestTimeout,
        );
}

const List<AiChatMessage> _messages = <AiChatMessage>[AiChatMessage.user('hi')];

void main() {
  test('默认时限仍是 90 秒', () {
    expect(kAiChatRequestTimeout, const Duration(seconds: 90));
  });

  test('客户端时限短于生成耗时：报 network_error', () async {
    final AiChatClient client = _slowClient(
      requestTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(client.close);
    await expectLater(
      client.complete(provider: _provider, messages: _messages),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          'network_error',
        ),
      ),
    );
  });

  test('放宽的客户端时限：同一个慢应答正常拿到', () async {
    final AiChatClient client = _slowClient(
      requestTimeout: const Duration(seconds: 5),
    );
    addTearDown(client.close);
    expect(
      await client.complete(provider: _provider, messages: _messages),
      '[]',
    );
  });
}
