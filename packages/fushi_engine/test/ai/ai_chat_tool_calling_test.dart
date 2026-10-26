import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// `AiChatClient.chat` 的三协议 tool calling：录制形状的 fixture 往返——断言请求
/// wire 形状（tools / 工具调用回放 / tool result 合并 / Anthropic 缓存断点 /
/// Gemini schema 净化与 thoughtSignature 回传），再从应答解析出工具调用、正文、
/// 用量。不打真网。
void main() {
  AiProviderConfig provider(AiWireProtocol protocol) => AiProviderConfig(
    id: 'p',
    presetId: kAiCustomPresetId,
    name: 'p',
    baseUrl: Uri.parse('https://example.com/v1'),
    apiKey: 'k',
    model: 'm',
    protocol: protocol,
  );

  /// 记下每次请求体，回 [reply]。
  ({AiChatClient client, List<Map<String, Object?>> sent}) fixture(
    Object? reply,
  ) {
    final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
    final AiChatClient client = AiChatClient(
      rateLimiter: AiRateLimiter(),
      client: MockClient((http.Request request) async {
        sent.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        return http.Response(
          jsonEncode(reply),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    return (client: client, sent: sent);
  }

  const AiChatToolSpec searchTool = AiChatToolSpec(
    name: 'library_search',
    description: 'Search the library.',
    parameters: <String, Object?>{
      r'$schema': 'http://json-schema.org/draft-07/schema#',
      'type': 'object',
      'additionalProperties': false,
      'properties': <String, Object?>{
        'query': <String, Object?>{'type': 'string', 'default': ''},
        // 参数名恰好叫 default：净化只剥 schema 关键字，不剥参数名。
        'default': <String, Object?>{'type': 'boolean'},
        'filters': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{
            'type': 'object',
            'additionalProperties': false,
            'properties': <String, Object?>{
              'kind': <String, Object?>{
                'anyOf': <Object?>[
                  <String, Object?>{'type': 'string', 'default': 'book'},
                  <String, Object?>{'type': 'null'},
                ],
              },
            },
          },
        },
      },
      'required': <Object?>['query'],
    },
  );
  const AiChatToolSpec openTool = AiChatToolSpec(
    name: 'open_book',
    description: 'Open a book.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'id': <String, Object?>{'type': 'integer'},
      },
    },
  );
  const List<AiChatToolSpec> tools = <AiChatToolSpec>[searchTool, openTool];

  /// 一段完整的历史：system → user → 模型调两个工具 → 两个结果 → 用户追问。
  List<AiChatMessage> history({Map<String, Object?> meta = const {}}) =>
      <AiChatMessage>[
        const AiChatMessage.system('sys'),
        const AiChatMessage.user('find dune'),
        AiChatMessage.assistantToolCalls('', <AiChatToolCall>[
          AiChatToolCall(
            id: 'c1',
            name: 'library_search',
            arguments: const <String, Object?>{'query': 'dune'},
            providerMeta: meta,
          ),
          const AiChatToolCall(
            id: 'c2',
            name: 'open_book',
            arguments: <String, Object?>{'id': 7},
          ),
        ]),
        const AiChatMessage.toolResult(
          toolCallId: 'c1',
          toolName: 'library_search',
          content: '[{"id":7}]',
        ),
        const AiChatMessage.toolResult(
          toolCallId: 'c2',
          toolName: 'open_book',
          content: 'not found',
          isError: true,
        ),
        const AiChatMessage.user('thanks'),
      ];

  group('OpenAI 兼容', () {
    final Map<String, Object?> reply = <String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'finish_reason': 'tool_calls',
          'message': <String, Object?>{
            'role': 'assistant',
            'content': null,
            'tool_calls': <Object?>[
              <String, Object?>{
                'id': 'call_abc',
                'type': 'function',
                'function': <String, Object?>{
                  'name': 'library_search',
                  'arguments': '{"query":"dune","limit":3}',
                },
              },
              <String, Object?>{
                'id': 'call_def',
                'type': 'function',
                'function': <String, Object?>{
                  'name': 'open_book',
                  'arguments': '{"id": 7',
                },
              },
            ],
          },
        },
      ],
      'usage': <String, Object?>{'prompt_tokens': 100, 'completion_tokens': 9},
    };

    test('请求：tools 包成 function、不发 tool_choice；回放与 tool 消息形状', () async {
      final f = fixture(reply);
      await f.client.chat(
        provider: provider(AiWireProtocol.openAiCompatible),
        messages: history(),
        tools: tools,
      );
      final Map<String, Object?> body = f.sent.single;
      expect(body.containsKey('tool_choice'), isFalse);
      expect(body['tools'], <Object?>[
        <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{
            'name': 'library_search',
            'description': 'Search the library.',
            // OpenAI 原样发 schema，不净化。
            'parameters': searchTool.parameters,
          },
        },
        <String, Object?>{
          'type': 'function',
          'function': <String, Object?>{
            'name': 'open_book',
            'description': 'Open a book.',
            'parameters': openTool.parameters,
          },
        },
      ]);
      expect(body['messages'], <Object?>[
        <String, Object?>{'role': 'system', 'content': 'sys'},
        <String, Object?>{'role': 'user', 'content': 'find dune'},
        <String, Object?>{
          'role': 'assistant',
          'content': null,
          'tool_calls': <Object?>[
            <String, Object?>{
              'id': 'c1',
              'type': 'function',
              'function': <String, Object?>{
                'name': 'library_search',
                'arguments': '{"query":"dune"}',
              },
            },
            <String, Object?>{
              'id': 'c2',
              'type': 'function',
              'function': <String, Object?>{
                'name': 'open_book',
                'arguments': '{"id":7}',
              },
            },
          ],
        },
        <String, Object?>{
          'role': 'tool',
          'tool_call_id': 'c1',
          'content': '[{"id":7}]',
        },
        <String, Object?>{
          'role': 'tool',
          'tool_call_id': 'c2',
          'content': 'not found',
        },
        <String, Object?>{'role': 'user', 'content': 'thanks'},
      ]);
    });

    test('应答：解析 tool_calls、坏 arguments 给 _raw、正文 null 当空串', () async {
      final f = fixture(reply);
      final AiChatTurn turn = await f.client.chat(
        provider: provider(AiWireProtocol.openAiCompatible),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        tools: tools,
      );
      expect(turn.text, '');
      expect(turn.hasToolCalls, isTrue);
      expect(turn.stopReason, 'tool_calls');
      expect(turn.toolCalls, hasLength(2));
      expect(turn.toolCalls[0].id, 'call_abc');
      expect(turn.toolCalls[0].name, 'library_search');
      expect(turn.toolCalls[0].arguments, <String, Object?>{
        'query': 'dune',
        'limit': 3,
      });
      expect(turn.toolCalls[1].arguments, <String, Object?>{
        '_raw': '{"id": 7',
      });
      expect(turn.usage, const AiChatUsage(inputTokens: 100, outputTokens: 9));
    });

    test('assistantToolCalls 带正文时 content 发正文', () async {
      final f = fixture(reply);
      await f.client.chat(
        provider: provider(AiWireProtocol.openAiCompatible),
        messages: <AiChatMessage>[
          AiChatMessage.assistantToolCalls('looking', const <AiChatToolCall>[
            AiChatToolCall(id: 'x', name: 'n', arguments: <String, Object?>{}),
          ]),
        ],
      );
      final List<Object?> messages =
          f.sent.single['messages']! as List<Object?>;
      expect((messages.single! as Map)['content'], 'looking');
      expect(
        (((messages.single! as Map)['tool_calls'] as List).single
            as Map)['function'],
        <String, Object?>{'name': 'n', 'arguments': '{}'},
      );
    });
  });

  group('Anthropic', () {
    final Map<String, Object?> reply = <String, Object?>{
      'stop_reason': 'tool_use',
      'content': <Object?>[
        <String, Object?>{'type': 'text', 'text': 'Let me search.'},
        <String, Object?>{
          'type': 'tool_use',
          'id': 'toolu_01',
          'name': 'library_search',
          'input': <String, Object?>{'query': 'dune'},
        },
      ],
      'usage': <String, Object?>{
        'input_tokens': 10,
        'output_tokens': 5,
        'cache_read_input_tokens': 900,
      },
    };

    test(
      '请求：tools 用 input_schema、最后一个挂 cache_control；连续 tool_result 合并',
      () async {
        final f = fixture(reply);
        await f.client.chat(
          provider: provider(AiWireProtocol.anthropicMessages),
          messages: history(),
          tools: tools,
        );
        final Map<String, Object?> body = f.sent.single;
        expect(body['system'], 'sys');
        expect(body['tools'], <Object?>[
          <String, Object?>{
            'name': 'library_search',
            'description': 'Search the library.',
            'input_schema': searchTool.parameters,
          },
          <String, Object?>{
            'name': 'open_book',
            'description': 'Open a book.',
            'input_schema': openTool.parameters,
            'cache_control': <String, Object?>{'type': 'ephemeral'},
          },
        ]);
        expect(body['messages'], <Object?>[
          <String, Object?>{'role': 'user', 'content': 'find dune'},
          <String, Object?>{
            'role': 'assistant',
            // 正文为空：不带空 text 块。
            'content': <Object?>[
              <String, Object?>{
                'type': 'tool_use',
                'id': 'c1',
                'name': 'library_search',
                'input': <String, Object?>{'query': 'dune'},
              },
              <String, Object?>{
                'type': 'tool_use',
                'id': 'c2',
                'name': 'open_book',
                'input': <String, Object?>{'id': 7},
              },
            ],
          },
          <String, Object?>{
            'role': 'user',
            'content': <Object?>[
              <String, Object?>{
                'type': 'tool_result',
                'tool_use_id': 'c1',
                'content': '[{"id":7}]',
              },
              <String, Object?>{
                'type': 'tool_result',
                'tool_use_id': 'c2',
                'content': 'not found',
                'is_error': true,
              },
            ],
          },
          <String, Object?>{'role': 'user', 'content': 'thanks'},
        ]);
      },
    );

    test('assistantToolCalls 带正文时先发 text 块', () async {
      final f = fixture(reply);
      await f.client.chat(
        provider: provider(AiWireProtocol.anthropicMessages),
        messages: <AiChatMessage>[
          const AiChatMessage.user('q'),
          AiChatMessage.assistantToolCalls('hmm', const <AiChatToolCall>[
            AiChatToolCall(id: 'x', name: 'n', arguments: <String, Object?>{}),
          ]),
        ],
      );
      final List<Object?> messages =
          f.sent.single['messages']! as List<Object?>;
      expect((messages[1]! as Map)['content'], <Object?>[
        <String, Object?>{'type': 'text', 'text': 'hmm'},
        <String, Object?>{
          'type': 'tool_use',
          'id': 'x',
          'name': 'n',
          'input': <String, Object?>{},
        },
      ]);
    });

    test('应答：解析 tool_use 块、正文、stop_reason 与用量', () async {
      final f = fixture(reply);
      final AiChatTurn turn = await f.client.chat(
        provider: provider(AiWireProtocol.anthropicMessages),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        tools: tools,
      );
      expect(turn.text, 'Let me search.');
      expect(turn.stopReason, 'tool_use');
      expect(turn.toolCalls.single.id, 'toolu_01');
      expect(turn.toolCalls.single.name, 'library_search');
      expect(turn.toolCalls.single.arguments, <String, Object?>{
        'query': 'dune',
      });
      expect(
        turn.usage,
        const AiChatUsage(
          inputTokens: 10,
          outputTokens: 5,
          cacheReadTokens: 900,
        ),
      );
    });
  });

  group('Gemini', () {
    final Map<String, Object?> reply = <String, Object?>{
      'candidates': <Object?>[
        <String, Object?>{
          'finishReason': 'STOP',
          'content': <String, Object?>{
            'role': 'model',
            'parts': <Object?>[
              <String, Object?>{
                'functionCall': <String, Object?>{
                  'name': 'library_search',
                  'args': <String, Object?>{'query': 'dune'},
                },
                'thoughtSignature': 'sig-AAA',
              },
              <String, Object?>{
                'functionCall': <String, Object?>{
                  'name': 'open_book',
                  'args': <String, Object?>{'id': 7},
                },
              },
            ],
          },
        },
      ],
      'usageMetadata': <String, Object?>{
        'promptTokenCount': 50,
        'candidatesTokenCount': 4,
        'thoughtsTokenCount': 6,
      },
    };

    test('请求：functionDeclarations 用净化后的 schema', () async {
      final f = fixture(reply);
      await f.client.chat(
        provider: provider(AiWireProtocol.geminiGenerateContent),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        tools: tools,
      );
      expect(f.sent.single['tools'], <Object?>[
        <String, Object?>{
          'functionDeclarations': <Object?>[
            <String, Object?>{
              'name': 'library_search',
              'description': 'Search the library.',
              'parameters': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'query': <String, Object?>{'type': 'string'},
                  'default': <String, Object?>{'type': 'boolean'},
                  'filters': <String, Object?>{
                    'type': 'array',
                    'items': <String, Object?>{
                      'type': 'object',
                      'properties': <String, Object?>{
                        'kind': <String, Object?>{
                          'anyOf': <Object?>[
                            <String, Object?>{'type': 'string'},
                            <String, Object?>{'type': 'null'},
                          ],
                        },
                      },
                    },
                  },
                },
                'required': <Object?>['query'],
              },
            },
            <String, Object?>{
              'name': 'open_book',
              'description': 'Open a book.',
              'parameters': openTool.parameters,
            },
          ],
        },
      ]);
    });

    test(
      '请求：回放 functionCall 带回 thoughtSignature；连续 functionResponse 合并',
      () async {
        final f = fixture(reply);
        await f.client.chat(
          provider: provider(AiWireProtocol.geminiGenerateContent),
          messages: history(
            meta: const <String, Object?>{'thoughtSignature': 'sig-AAA'},
          ),
          tools: tools,
        );
        final Map<String, Object?> body = f.sent.single;
        expect(body['systemInstruction'], <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'text': 'sys'},
          ],
        });
        expect(body['contents'], <Object?>[
          <String, Object?>{
            'role': 'user',
            'parts': <Object?>[
              <String, Object?>{'text': 'find dune'},
            ],
          },
          <String, Object?>{
            'role': 'model',
            'parts': <Object?>[
              <String, Object?>{
                'functionCall': <String, Object?>{
                  'name': 'library_search',
                  'args': <String, Object?>{'query': 'dune'},
                },
                'thoughtSignature': 'sig-AAA',
              },
              <String, Object?>{
                'functionCall': <String, Object?>{
                  'name': 'open_book',
                  'args': <String, Object?>{'id': 7},
                },
              },
            ],
          },
          <String, Object?>{
            'role': 'user',
            'parts': <Object?>[
              <String, Object?>{
                'functionResponse': <String, Object?>{
                  'name': 'library_search',
                  'response': <String, Object?>{'content': '[{"id":7}]'},
                },
              },
              <String, Object?>{
                'functionResponse': <String, Object?>{
                  'name': 'open_book',
                  'response': <String, Object?>{
                    'content': 'not found',
                    'error': true,
                  },
                },
              },
            ],
          },
          <String, Object?>{
            'role': 'user',
            'parts': <Object?>[
              <String, Object?>{'text': 'thanks'},
            ],
          },
        ]);
      },
    );

    test(
      '应答：解析 functionCall、本地生成 id、thoughtSignature 进 providerMeta',
      () async {
        final f = fixture(reply);
        final AiChatTurn turn = await f.client.chat(
          provider: provider(AiWireProtocol.geminiGenerateContent),
          messages: const <AiChatMessage>[AiChatMessage.user('hi')],
          tools: tools,
        );
        expect(turn.text, '');
        expect(turn.stopReason, 'STOP');
        expect(turn.toolCalls, hasLength(2));
        expect(turn.toolCalls[0].id, 'call_0');
        expect(turn.toolCalls[0].name, 'library_search');
        expect(turn.toolCalls[0].arguments, <String, Object?>{'query': 'dune'});
        expect(turn.toolCalls[0].providerMeta, <String, Object?>{
          'thoughtSignature': 'sig-AAA',
        });
        expect(turn.toolCalls[1].id, 'call_1');
        expect(turn.toolCalls[1].providerMeta, isEmpty);
        expect(
          turn.usage,
          const AiChatUsage(inputTokens: 50, outputTokens: 10),
        );
      },
    );

    test('应答回放往返：解析出的调用原样带回 thoughtSignature', () async {
      final f = fixture(reply);
      final AiChatTurn turn = await f.client.chat(
        provider: provider(AiWireProtocol.geminiGenerateContent),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        tools: tools,
      );
      await f.client.chat(
        provider: provider(AiWireProtocol.geminiGenerateContent),
        messages: <AiChatMessage>[
          const AiChatMessage.user('hi'),
          AiChatMessage.assistantToolCalls(turn.text, turn.toolCalls),
        ],
        tools: tools,
      );
      final List<Object?> contents = f.sent[1]['contents']! as List<Object?>;
      final List<Object?> parts =
          (contents[1]! as Map)['parts'] as List<Object?>;
      expect((parts[0]! as Map)['thoughtSignature'], 'sig-AAA');
      expect((parts[1]! as Map).containsKey('thoughtSignature'), isFalse);
    });
  });

  group('无 tools 时请求体与 complete 逐字相同', () {
    final Map<AiWireProtocol, Object?> replies = <AiWireProtocol, Object?>{
      AiWireProtocol.openAiCompatible: <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'ok'},
          },
        ],
      },
      AiWireProtocol.anthropicMessages: <String, Object?>{
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'ok'},
        ],
      },
      AiWireProtocol.geminiGenerateContent: <String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': 'ok'},
              ],
            },
          },
        ],
      },
    };
    const List<AiChatMessage> plain = <AiChatMessage>[
      AiChatMessage.system('stable', cacheable: true),
      AiChatMessage.system('tail'),
      AiChatMessage.user(
        'look',
        images: <AiChatImage>[
          AiChatImage(bytes: <int>[1, 2, 3]),
        ],
      ),
      AiChatMessage.assistant('seen'),
      AiChatMessage.user('more'),
    ];

    for (final AiWireProtocol protocol in AiWireProtocol.values) {
      test(protocol.name, () async {
        final List<String> raw = <String>[];
        final AiChatClient client = AiChatClient(
          rateLimiter: AiRateLimiter(),
          client: MockClient((http.Request request) async {
            raw.add(request.body);
            return http.Response(jsonEncode(replies[protocol]), 200);
          }),
        );
        addTearDown(client.close);
        await client.complete(
          provider: provider(protocol),
          messages: plain,
          maxTokens: 321,
        );
        final AiChatTurn turn = await client.chat(
          provider: provider(protocol),
          messages: plain,
          maxTokens: 321,
        );
        expect(turn.text, 'ok');
        expect(turn.toolCalls, isEmpty);
        expect(raw, hasLength(2));
        expect(raw[1], raw[0]);
        expect(raw[0], isNot(contains('tools')));
      });
    }

    test('OpenAI 无工具请求体的固定形状（与改造前逐字一致）', () async {
      final List<String> raw = <String>[];
      final AiChatClient client = AiChatClient(
        rateLimiter: AiRateLimiter(),
        client: MockClient((http.Request request) async {
          raw.add(request.body);
          return http.Response(
            jsonEncode(replies[AiWireProtocol.openAiCompatible]),
            200,
          );
        }),
      );
      addTearDown(client.close);
      await client.chat(
        provider: provider(AiWireProtocol.openAiCompatible),
        messages: const <AiChatMessage>[
          AiChatMessage.system('s'),
          AiChatMessage.user('u'),
          AiChatMessage.assistant('a'),
        ],
        maxTokens: 10,
      );
      expect(
        raw.single,
        '{"model":"m","messages":[{"role":"system","content":"s"},'
        '{"role":"user","content":"u"},{"role":"assistant","content":"a"}],'
        '"max_tokens":10}',
      );
    });
  });

  group('empty_response', () {
    for (final (AiWireProtocol protocol, Object? body)
        in <(AiWireProtocol, Object?)>[
          (
            AiWireProtocol.openAiCompatible,
            <String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{'content': '  '},
                },
              ],
            },
          ),
          (
            AiWireProtocol.anthropicMessages,
            <String, Object?>{'content': <Object?>[]},
          ),
          (
            AiWireProtocol.geminiGenerateContent,
            <String, Object?>{'candidates': <Object?>[]},
          ),
        ]) {
      test('${protocol.name}：无正文无工具调用抛 empty_response', () async {
        final f = fixture(body);
        await expectLater(
          f.client.chat(
            provider: provider(protocol),
            messages: const <AiChatMessage>[AiChatMessage.user('hi')],
            tools: tools,
          ),
          throwsA(
            isA<AiChatFailure>().having(
              (AiChatFailure e) => e.message,
              'message',
              'empty_response',
            ),
          ),
        );
      });
    }
  });

  group('sanitizeGeminiToolSchema', () {
    test('剥关键字不剥参数名，不改原 schema', () {
      final Map<String, Object?> cleaned = sanitizeGeminiToolSchema(
        searchTool.parameters,
      );
      expect(cleaned.containsKey('additionalProperties'), isFalse);
      expect(cleaned.containsKey(r'$schema'), isFalse);
      expect(
        (cleaned['properties']! as Map).keys,
        containsAll(<String>['query', 'default', 'filters']),
      );
      expect(searchTool.parameters.containsKey('additionalProperties'), isTrue);
    });
  });
}
