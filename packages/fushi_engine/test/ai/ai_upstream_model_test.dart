import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_upstream_model.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

AiProviderConfig _provider(AiWireProtocol protocol, String base) =>
    AiProviderConfig(
      id: 'p',
      presetId: 'custom',
      name: 'p',
      protocol: protocol,
      baseUrl: Uri.parse(base),
      apiKey: 'sk-test',
    );

Future<List<AiUpstreamModel>> _list(
  AiWireProtocol protocol,
  String base,
  Map<String, Object?> body,
) async {
  final AiChatClient client = AiChatClient(
    client: MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    ),
  );
  try {
    return await client.listModels(_provider(protocol, base));
  } finally {
    client.close();
  }
}

void main() {
  test('Anthropic：display_name 与 capabilities.image_input 带回来', () async {
    final List<AiUpstreamModel> models = await _list(
      AiWireProtocol.anthropicMessages,
      'https://api.anthropic.com',
      <String, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'type': 'model',
            'id': 'claude-opus-5-5',
            'display_name': 'Claude Opus 5.5',
            'capabilities': <String, Object?>{
              'image_input': <String, Object?>{'supported': true},
            },
          },
          <String, Object?>{
            'type': 'model',
            'id': 'claude-text-only',
            'display_name': 'Text Only',
            'capabilities': <String, Object?>{
              'image_input': <String, Object?>{'supported': false},
            },
          },
          // 老版本 / 兼容端点没有 capabilities：「没说」不等于「不支持」。
          <String, Object?>{'type': 'model', 'id': 'claude-legacy'},
        ],
        'has_more': false,
      },
    );
    expect(models.map((AiUpstreamModel m) => m.id), <String>[
      'claude-legacy',
      'claude-opus-5-5',
      'claude-text-only',
    ]);
    final AiUpstreamModel opus = models[1];
    expect(opus.displayName, 'Claude Opus 5.5');
    expect(opus.label, 'Claude Opus 5.5');
    expect(opus.acceptsImages, isTrue);
    expect(opus.pricing, isNull);
    expect(models[2].acceptsImages, isFalse);
    expect(models[0].acceptsImages, isNull);
    expect(models[0].displayName, isNull);
    expect(models[0].label, 'claude-legacy');
  });

  test('OpenRouter：name、input_modalities、每 token 单价换算成每百万', () async {
    final List<AiUpstreamModel> models = await _list(
      AiWireProtocol.openAiCompatible,
      'https://openrouter.ai/api/v1',
      <String, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'anthropic/claude-sonnet',
            'name': 'Anthropic: Claude Sonnet',
            'architecture': <String, Object?>{
              'input_modalities': <Object?>['text', 'image'],
            },
            'pricing': <String, Object?>{
              'prompt': '0.000003',
              'completion': '0.000015',
              'input_cache_read': '0.0000003',
              'input_cache_write': '0.00000375',
            },
          },
          <String, Object?>{
            'id': 'deepseek/deepseek-chat',
            'name': 'DeepSeek V3',
            'architecture': <String, Object?>{
              'input_modalities': <Object?>['text'],
            },
            'pricing': <String, Object?>{
              'prompt': '0.0000001',
              'completion': '0.00000032',
            },
          },
          // 动态路由：单价是哨兵 -1，不能当成价格填进去。
          <String, Object?>{
            'id': 'openrouter/auto',
            'name': 'Auto Router',
            'pricing': <String, Object?>{'prompt': '-1', 'completion': '-1'},
          },
        ],
      },
    );
    final AiUpstreamModel sonnet = models[0];
    expect(sonnet.id, 'anthropic/claude-sonnet');
    expect(sonnet.displayName, 'Anthropic: Claude Sonnet');
    expect(sonnet.acceptsImages, isTrue);
    expect(sonnet.pricing!.inputPerMillion, 3);
    expect(sonnet.pricing!.outputPerMillion, 15);
    expect(sonnet.pricing!.cacheReadPerMillion, 0.3);
    expect(sonnet.pricing!.cacheWritePerMillion, 3.75);
    expect(sonnet.pricing!.currency, 'USD');

    final AiUpstreamModel deepseek = models[1];
    expect(deepseek.acceptsImages, isFalse);
    expect(deepseek.pricing!.inputPerMillion, 0.1);
    expect(deepseek.pricing!.outputPerMillion, 0.32);
    expect(deepseek.pricing!.cacheReadPerMillion, isNull);

    final AiUpstreamModel auto = models[2];
    expect(auto.pricing, isNull);
    expect(auto.acceptsImages, isNull);
  });

  test('Gemini：剥 models/ 前缀，displayName 带回来', () async {
    final List<AiUpstreamModel> models = await _list(
      AiWireProtocol.geminiGenerateContent,
      'https://generativelanguage.googleapis.com/v1beta',
      <String, Object?>{
        'models': <Object?>[
          <String, Object?>{
            'name': 'models/gemini-2.5-flash',
            'displayName': 'Gemini 2.5 Flash',
          },
        ],
      },
    );
    expect(models.single.id, 'gemini-2.5-flash');
    expect(models.single.displayName, 'Gemini 2.5 Flash');
    expect(models.single.acceptsImages, isNull);
    expect(models.single.pricing, isNull);
  });

  test('OpenAI 官方只回 id：其余全为 null', () async {
    final List<AiUpstreamModel> models = await _list(
      AiWireProtocol.openAiCompatible,
      'https://api.openai.com/v1',
      <String, Object?>{
        'object': 'list',
        'data': <Object?>[
          <String, Object?>{'id': 'gpt-4.1', 'object': 'model'},
        ],
      },
    );
    expect(models.single.toJson(), <String, Object?>{'id': 'gpt-4.1'});
  });

  test('toJson 只带上游给了的字段', () {
    final List<AiUpstreamModel> models = parseAiUpstreamModels(
      <Object?, Object?>{
        'data': <Object?>[
          <String, Object?>{
            'id': 'x',
            'name': 'X',
            'architecture': <String, Object?>{
              'input_modalities': <Object?>['image'],
            },
            'pricing': <String, Object?>{'prompt': '0.000001', 'completion': 0},
          },
        ],
      },
    );
    expect(models.single.toJson(), <String, Object?>{
      'id': 'x',
      'name': 'X',
      'images': true,
      'pricing': <String, Object?>{'input': 1.0, 'output': 0.0},
    });
  });
}
