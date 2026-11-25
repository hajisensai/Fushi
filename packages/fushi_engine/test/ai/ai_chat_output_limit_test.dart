// BUG-5469：推理模型把 max_tokens 全花在思考上、正文为空并以截断收尾——这不是
// 「模型什么也没回」（empty_response），而是输出额度用尽（output_limit）。三种协议、
// complete / completeWithUsage / chat 与互联主机转发同一口径。
import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_engine/ai/ai_relay.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

AiProviderConfig _provider(AiWireProtocol protocol) => AiProviderConfig(
  id: 'p',
  presetId: 'custom',
  name: 'P',
  baseUrl: Uri.parse('https://api.example.com/v1'),
  apiKey: 'k',
  model: 'm',
  protocol: protocol,
);

AiChatClient _clientReturning(Object? reply) {
  final AiChatClient client = AiChatClient(
    rateLimiter: AiRateLimiter(),
    client: MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(reply),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    ),
  );
  addTearDown(client.close);
  return client;
}

/// 三种协议的空正文应答，停止原因为 [stop]。
Object? _emptyBody(AiWireProtocol protocol, String stop) => switch (protocol) {
  AiWireProtocol.openAiCompatible => <String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{'role': 'assistant', 'content': ''},
        'finish_reason': stop,
      },
    ],
    'usage': <String, Object?>{
      'prompt_tokens': 3000,
      'completion_tokens': 8192,
      'completion_tokens_details': <String, Object?>{'reasoning_tokens': 8192},
    },
  },
  AiWireProtocol.anthropicMessages => <String, Object?>{
    'content': <Object?>[
      <String, Object?>{'type': 'thinking', 'thinking': '...'},
    ],
    'stop_reason': stop,
  },
  AiWireProtocol.geminiGenerateContent => <String, Object?>{
    'candidates': <Object?>[
      <String, Object?>{
        'content': <String, Object?>{'role': 'model'},
        'finishReason': stop,
      },
    ],
  },
};

const Map<AiWireProtocol, (String truncated, String normal)> _stops =
    <AiWireProtocol, (String, String)>{
      AiWireProtocol.openAiCompatible: ('length', 'stop'),
      AiWireProtocol.anthropicMessages: ('max_tokens', 'end_turn'),
      AiWireProtocol.geminiGenerateContent: ('MAX_TOKENS', 'STOP'),
    };

Matcher _failsWith(String code) => throwsA(
  isA<AiChatFailure>().having((AiChatFailure f) => f.message, 'message', code),
);

/// 互联主机通道：原样回 [reply]。
class _FakeRelay implements AiRelayTransport {
  _FakeRelay(this.reply);
  final Map<String, Object?> reply;

  @override
  Future<Map<String, Object?>> post(
    String hostId,
    String path,
    Map<String, Object?> body,
  ) async => reply;
}

void main() {
  for (final MapEntry<AiWireProtocol, (String, String)> e in _stops.entries) {
    final AiWireProtocol protocol = e.key;
    final (String truncated, String normal) = e.value;

    test(
      '${protocol.name}：空正文 + 截断 → output_limit（complete / completeWithUsage '
      '/ chat 同口径）',
      () async {
        final AiChatClient client = _clientReturning(
          _emptyBody(protocol, truncated),
        );
        const List<AiChatMessage> messages = <AiChatMessage>[
          AiChatMessage.user('hi'),
        ];
        await expectLater(
          client.complete(provider: _provider(protocol), messages: messages),
          _failsWith(kAiOutputLimitCode),
        );
        await expectLater(
          client.completeWithUsage(
            provider: _provider(protocol),
            messages: messages,
          ),
          _failsWith(kAiOutputLimitCode),
        );
        await expectLater(
          client.chat(provider: _provider(protocol), messages: messages),
          _failsWith(kAiOutputLimitCode),
        );
      },
    );

    test('${protocol.name}：空正文 + 正常结束仍是 empty_response', () async {
      final AiChatClient client = _clientReturning(
        _emptyBody(protocol, normal),
      );
      await expectLater(
        client.complete(
          provider: _provider(protocol),
          messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        ),
        _failsWith('empty_response'),
      );
    });
  }

  test('output_limit 不是临时性失败，也不换 key', () {
    const AiChatFailure f = AiChatFailure(kAiOutputLimitCode);
    expect(f.isTransient, isFalse);
    expect(f.rotatesKey, isFalse);
    expect(aiChatEmptyReplyFailure('length').message, kAiOutputLimitCode);
    expect(aiChatEmptyReplyFailure(null).message, 'empty_response');
    expect(aiChatEmptyReplyFailure('content_filter').message, 'empty_response');
  });

  group('互联主机转发', () {
    final AiProviderConfig relay = AiProviderConfig.interconnectHost(
      id: 'relay-1',
      name: 'Desk',
      relay: const AiRelayTarget(hostId: 'host-abc'),
    );
    const List<AiChatMessage> messages = <AiChatMessage>[
      AiChatMessage.user('hi'),
    ];

    test('主机回空正文 + 截断 → output_limit', () async {
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        relayTransport: _FakeRelay(<String, Object?>{
          'ok': true,
          'text': '',
          'toolCalls': <Object?>[],
          'stopReason': 'length',
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.complete(provider: relay, messages: messages),
        _failsWith(kAiOutputLimitCode),
      );
      await expectLater(
        client.chat(provider: relay, messages: messages),
        _failsWith(kAiOutputLimitCode),
      );
    });

    test('主机那头已判出 output_limit：短码原样带回', () async {
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        relayTransport: _FakeRelay(<String, Object?>{
          'ok': false,
          'error': kAiOutputLimitCode,
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.complete(provider: relay, messages: messages),
        _failsWith(kAiOutputLimitCode),
      );
    });

    test('主机回空正文 + 正常结束 → empty_response', () async {
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        relayTransport: _FakeRelay(<String, Object?>{
          'ok': true,
          'text': '',
          'toolCalls': <Object?>[],
          'stopReason': 'stop',
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.complete(provider: relay, messages: messages),
        _failsWith('empty_response'),
      );
    });
  });
}
