import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 视觉消息的 wire 形状：三家协议各有各的图片段写法，写错一家就是那家「能连上、
/// 一发图就 400」。纯文本消息的形状另由 `ai_provider_settings_test.dart` 钉住，
/// 这里额外钉「无图时仍发纯字符串」——兼容端点不认 content 数组。
void main() {
  const AiChatImage image = AiChatImage(
    bytes: <int>[1, 2, 3],
    mimeType: 'image/png',
  );
  final String b64 = base64Encode(<int>[1, 2, 3]);

  late Map<String, Object?> sent;

  AiChatClient clientReturning(Object? body) => AiChatClient(
    client: MockClient((http.Request request) async {
      sent = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
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

  test('OpenAI 兼容：图片走 image_url data URL，文字段在图之后', () async {
    final AiChatClient client = clientReturning(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'content': 'ok'},
        },
      ],
    });
    addTearDown(client.close);
    await client.complete(
      provider: provider(AiWireProtocol.openAiCompatible),
      messages: <AiChatMessage>[
        const AiChatMessage.system('sys'),
        const AiChatMessage.user('read', images: <AiChatImage>[image]),
      ],
    );
    final List<Object?> messages = sent['messages']! as List<Object?>;
    expect((messages.first! as Map<String, Object?>)['content'], 'sys');
    final List<Object?> content =
        (messages.last! as Map<String, Object?>)['content']! as List<Object?>;
    expect(content, <Object?>[
      <String, Object?>{
        'type': 'image_url',
        'image_url': <String, Object?>{'url': 'data:image/png;base64,$b64'},
      },
      <String, Object?>{'type': 'text', 'text': 'read'},
    ]);
  });

  test('OpenAI 兼容：无图消息仍是纯字符串 content', () async {
    final AiChatClient client = clientReturning(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'content': 'ok'},
        },
      ],
    });
    addTearDown(client.close);
    await client.complete(
      provider: provider(AiWireProtocol.openAiCompatible),
      messages: <AiChatMessage>[const AiChatMessage.user('hi')],
    );
    final List<Object?> messages = sent['messages']! as List<Object?>;
    expect((messages.single! as Map<String, Object?>)['content'], 'hi');
  });

  test('Anthropic：图片走 base64 source 块', () async {
    final AiChatClient client = clientReturning(<String, Object?>{
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': 'ok'},
      ],
    });
    addTearDown(client.close);
    await client.complete(
      provider: provider(AiWireProtocol.anthropicMessages),
      messages: <AiChatMessage>[
        const AiChatMessage.user('read', images: <AiChatImage>[image]),
      ],
    );
    final List<Object?> messages = sent['messages']! as List<Object?>;
    final List<Object?> content =
        (messages.single! as Map<String, Object?>)['content']! as List<Object?>;
    expect(content, <Object?>[
      <String, Object?>{
        'type': 'image',
        'source': <String, Object?>{
          'type': 'base64',
          'media_type': 'image/png',
          'data': b64,
        },
      },
      <String, Object?>{'type': 'text', 'text': 'read'},
    ]);
  });

  test('Gemini：图片走 inline_data part', () async {
    final AiChatClient client = clientReturning(<String, Object?>{
      'candidates': <Object?>[
        <String, Object?>{
          'content': <String, Object?>{
            'parts': <Object?>[
              <String, Object?>{'text': 'ok'},
            ],
          },
        },
      ],
    });
    addTearDown(client.close);
    await client.complete(
      provider: provider(AiWireProtocol.geminiGenerateContent),
      messages: <AiChatMessage>[
        const AiChatMessage.user('read', images: <AiChatImage>[image]),
      ],
    );
    final List<Object?> contents = sent['contents']! as List<Object?>;
    final List<Object?> parts =
        (contents.single! as Map<String, Object?>)['parts']! as List<Object?>;
    expect(parts, <Object?>[
      <String, Object?>{
        'inline_data': <String, Object?>{'mime_type': 'image/png', 'data': b64},
      },
      <String, Object?>{'text': 'read'},
    ]);
  });
}
