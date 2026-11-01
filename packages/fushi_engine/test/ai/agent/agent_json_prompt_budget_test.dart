// 反馈 GewyVIt5oo：模型不支持原生 tool calling 时，AI 助手每轮把每条工具的完整
// JSON Schema 写进系统提示，上下文 4k 的本地模型（LM Studio 默认）第一轮就超长；
// 服务端回的 400「context length」只被报成看不懂的 `http_400`。
import 'dart:convert';

import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:test/test.dart';

/// 一条带长描述、长参数说明与嵌套 items 的工具（与真实目录里 `settings.set` 一类同量级）。
AgentToolSpec _bigTool(int i) => AgentToolSpec(
  name: 'domain$i.do_thing',
  description:
      'Do thing number $i. ${'This sentence pads the description with details the model only needs after ops.describe. ' * 6}',
  parameters: <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'id': <String, Object?>{
        'type': 'string',
        'description':
            'Identifier. ${'Long explanation of the identifier. ' * 10}',
      },
      'mode': <String, Object?>{
        'type': 'string',
        'enum': <String>['fast', 'slow'],
        'description': 'Mode. ${'More words. ' * 10}',
      },
      'items': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'label': <String, Object?>{
              'type': 'string',
              'description': 'x' * 200,
            },
          },
        },
      },
      'limit': <String, Object?>{'type': 'integer'},
    },
    'required': <String>['id', 'mode'],
  },
);

void main() {
  group('降级协议系统提示分层', () {
    test('非元工具只给一行签名 + 截短摘要，不带完整 schema', () {
      final List<AgentToolSpec> tools = <AgentToolSpec>[
        for (int i = 0; i < 20; i++) _bigTool(i),
      ];
      final String fullSchemas = tools
          .map((AgentToolSpec t) => jsonEncode(t.parameters))
          .join();
      final String prompt = buildAgentJsonSystemPrompt(tools);

      expect(
        prompt,
        contains(
          '- domain0__do_thing(id: string, mode: "fast"|"slow", '
          'items?: object[], limit?: integer): Do thing number 0.',
        ),
      );
      expect(prompt, isNot(contains('Long explanation of the identifier')));
      expect(prompt, isNot(contains('pads the description')));
      // 20 条重工具：旧实现光 schema 就是几万字；分层后整份提示远小于 schema 总和。
      expect(prompt.length, lessThan(fullSchemas.length ~/ 4));
      expect(prompt.length, lessThan(6000));
      expect(prompt, contains('call ops__describe'));
    });

    test('签名：无参数、类型数组、items 缺省', () {
      expect(agentCompactSignature(const <String, Object?>{}), '()');
      expect(
        agentCompactSignature(const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'value': <String, Object?>{},
            'n': <String, Object?>{
              'type': <String>['integer', 'null'],
            },
            'tags': <String, Object?>{'type': 'array'},
          },
          'required': <String>['value'],
        }),
        '(value: any, n?: integer|null, tags?: any[])',
      );
    });

    test('摘要截在第一句；超长截断带省略号', () {
      expect(
        agentCompactDescription('Read a setting. More.'),
        'Read a setting.',
      );
      final String long = agentCompactDescription('a' * 500);
      expect(long.length, kAgentCompactDescriptionChars);
      expect(long.endsWith('…'), isTrue);
    });
  });

  group('上下文超长归类', () {
    AiChatFailure classify(int status, String body) => classifyAiHttpFailure(
      statusCode: status,
      bodyBytes: utf8.encode(body),
      retryAfterHeader: null,
      now: DateTime(2026, 11, 1),
    );

    test('各家超长错误体 → context_overflow，且不算临时性失败', () {
      for (final (int, String) sample in <(int, String)>[
        (
          400,
          '{"error":{"code":"context_length_exceeded","message":"This model\'s maximum context length is 8192 tokens."}}',
        ),
        (
          400,
          '{"error":{"message":"the request exceeds the available context size, try increasing it"}}',
        ),
        (
          400,
          '{"error":"Trying to keep the first 5210 tokens when context the overflows. However, the model is loaded with context length of only 4096 tokens"}',
        ),
        (
          400,
          '{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}',
        ),
        (
          400,
          '{"error":{"message":"The input token count exceeds the maximum number of tokens allowed"}}',
        ),
        (500, '{"error":"input exceeds n_ctx"}'),
        (413, '{"error":"context window exceeded"}'),
      ]) {
        final AiChatFailure failure = classify(sample.$1, sample.$2);
        expect(failure.message, kAiContextOverflowCode, reason: sample.$2);
        expect(failure.isTransient, isFalse);
      }
    });

    test('429 的 tokens-per-minute 限流仍是限流；无关 400 仍是 http_400', () {
      expect(
        classify(
          429,
          '{"error":{"message":"Request too large for gpt-4o: Limit 30000 tokens per min"}}',
        ).message,
        'rate_limited',
      );
      expect(classify(400, '{"error":"bad json"}').message, 'http_400');
    });
  });
}
