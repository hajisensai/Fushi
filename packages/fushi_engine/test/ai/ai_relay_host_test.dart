import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:fushi_engine/ai/ai_relay.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/sync/ai_relay_routes.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

// 「互联主机」AI 提供商（反馈 M8KvhMTHVS）的协议级测试：真起一台 FushiSyncServer 当主机，
// 客户端 AiChatClient 拿一家互联主机提供商，经真实 HTTP（带配对口令的 Basic 鉴权）把补全
// 交给主机；主机用它自己那家提供商（假上游，MockClient）执行。断言 key 只出现在主机发往
// 上游的请求里，从不出现在主机回给客户端的任何应答里。

const String _hostKey = 'sk-host-secret-0123456789';

class _Settings implements AiSettingsSource {
  _Settings(this.aiProviders, {String? defaultProviderId})
    : aiFeatureAssignments = AiFeatureAssignments(
        defaultProviderId: defaultProviderId,
      );

  @override
  List<AiProviderConfig> aiProviders;

  @override
  AiFeatureAssignments aiFeatureAssignments;

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];

  @override
  WebSearchConfig? get aiWebSearch => null;
}

class _Prefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

/// 测试用的客户端出口：真 HTTP + Basic 鉴权，记下主机回的原始应答体。
class _HttpTransport implements AiRelayTransport {
  _HttpTransport(this.server, this.token);

  final FushiSyncServer server;
  final String token;
  final List<String> rawReplies = <String>[];
  int lastStatus = 0;

  @override
  Future<Map<String, Object?>> post(
    String hostId,
    String path,
    Map<String, Object?> body,
  ) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      req.headers.set(
        'Authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      lastStatus = res.statusCode;
      rawReplies.add(text);
      if (res.statusCode == 404) {
        throw const AiChatFailure(kAiRelayHostUnsupported);
      }
      if (res.statusCode != 200) throw AiChatFailure('http_${res.statusCode}');
      return (jsonDecode(text) as Map).cast<String, Object?>();
    } finally {
      client.close(force: true);
    }
  }
}

AiProviderConfig _hostProvider({
  String id = 'host-openai',
  bool tools = true,
}) => AiProviderConfig(
  id: id,
  presetId: 'openai',
  name: 'Host OpenAI',
  baseUrl: Uri.parse('https://api.example.com/v1'),
  apiKey: _hostKey,
  model: 'gpt-host',
  toolCallingOverride: tools
      ? AiToolCallingOverride.forceOn
      : AiToolCallingOverride.forceOff,
);

AiProviderConfig _relayProvider({String? providerId}) =>
    AiProviderConfig.interconnectHost(
      id: 'relay-1',
      name: 'Desk',
      relay: AiRelayTarget(hostId: 'host-abc', providerId: providerId),
      toolCallingOverride: AiToolCallingOverride.forceOn,
    );

void main() {
  late Directory tmp;
  late FushiSyncServer server;
  late String token;
  late _Settings settings;
  late _Prefs prefs;
  late _HttpTransport transport;
  late List<http.Request> upstream;
  late http.Response Function(http.Request) upstreamReply;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ai_relay_host_');
    settings = _Settings(<AiProviderConfig>[
      _hostProvider(),
    ], defaultProviderId: 'host-openai');
    prefs = _Prefs();
    upstream = <http.Request>[];
    upstreamReply = (http.Request _) => http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'content': 'from host'},
            'finish_reason': 'stop',
          },
        ],
        'usage': <String, Object?>{'prompt_tokens': 7, 'completion_tokens': 3},
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
    server =
        FushiSyncServer(
            syncDataDir: tmp.path,
            port: 0,
            token: token = FushiSyncServer.generateToken(),
            prefs: prefs,
          )
          ..aiRelaySettings = (() => settings)
          ..aiRelayClientFactory = (() => AiChatClient(
            rateLimiter: AiRateLimiter(),
            client: MockClient((http.Request request) async {
              upstream.add(request);
              return upstreamReply(request);
            }),
          ));
    await server.start();
    transport = _HttpTransport(server, token);
  });

  tearDown(() async {
    await server.stop();
    await tmp.delete(recursive: true);
  });

  AiChatClient client() {
    final AiChatClient c = AiChatClient(
      rateLimiter: AiRateLimiter(),
      relayTransport: transport,
      // 互联主机提供商绝不能直连任何上游：这里一碰就判红。
      client: MockClient((http.Request request) async {
        fail(
          'relay provider must not call an upstream directly: ${request.url}',
        );
      }),
    );
    addTearDown(c.close);
    return c;
  }

  test('complete 经主机执行：上游收到主机的 key，客户端拿回正文与用量，应答里没有 key', () async {
    final AiChatCompletion done = await client().completeWithUsage(
      provider: _relayProvider(),
      messages: const <AiChatMessage>[
        AiChatMessage.system('be brief', cacheable: true),
        AiChatMessage.user('hello'),
      ],
      maxTokens: 123,
    );
    expect(done.text, 'from host');
    expect(done.usage?.inputTokens, 7);
    expect(done.usage?.outputTokens, 3);
    expect(done.stopReason, 'stop');

    expect(upstream, hasLength(1));
    expect(upstream.single.headers['Authorization'], 'Bearer $_hostKey');
    final Map<String, Object?> sent = (jsonDecode(upstream.single.body) as Map)
        .cast<String, Object?>();
    expect(sent['model'], 'gpt-host');
    expect(sent['max_tokens'], 123);
    expect(jsonEncode(sent['messages']), contains('hello'));
    expect(jsonEncode(sent['messages']), contains('be brief'));
    for (final String raw in transport.rawReplies) {
      expect(raw, isNot(contains(_hostKey)));
      expect(raw, isNot(contains('api.example.com')));
    }
  });

  test('chat 带工具往返：工具描述到达上游，工具调用与历史回放原样回到客户端', () async {
    upstreamReply = (http.Request _) => http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': '',
              'tool_calls': <Object?>[
                <String, Object?>{
                  'id': 'call_1',
                  'type': 'function',
                  'function': <String, Object?>{
                    'name': 'library_search',
                    'arguments': '{"query":"ruri"}',
                  },
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
    final AiChatTurn turn = await client().chat(
      provider: _relayProvider(),
      messages: const <AiChatMessage>[
        AiChatMessage.user('find ruri'),
        AiChatMessage.assistantToolCalls('', <AiChatToolCall>[
          AiChatToolCall(
            id: 'call_0',
            name: 'library_search',
            arguments: <String, Object?>{'query': 'x'},
          ),
        ]),
        AiChatMessage.toolResult(
          toolCallId: 'call_0',
          toolName: 'library_search',
          content: 'none',
          isError: true,
        ),
      ],
      tools: const <AiChatToolSpec>[
        AiChatToolSpec(
          name: 'library_search',
          description: 'Search the library.',
          parameters: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'query': <String, Object?>{'type': 'string'},
            },
          },
        ),
      ],
    );
    expect(turn.toolCalls, hasLength(1));
    expect(turn.toolCalls.single.id, 'call_1');
    expect(turn.toolCalls.single.name, 'library_search');
    expect(turn.toolCalls.single.arguments, <String, Object?>{'query': 'ruri'});
    expect(turn.stopReason, 'tool_calls');

    final Map<String, Object?> sent = (jsonDecode(upstream.single.body) as Map)
        .cast<String, Object?>();
    expect(jsonEncode(sent['tools']), contains('library_search'));
    final String history = jsonEncode(sent['messages']);
    expect(history, contains('call_0'));
    expect(history, contains('"role":"tool"'));
  });

  test('图片随消息转发到主机', () async {
    await client().complete(
      provider: _relayProvider(),
      messages: const <AiChatMessage>[
        AiChatMessage.user(
          'read this',
          images: <AiChatImage>[
            AiChatImage(bytes: <int>[1, 2, 3], mimeType: 'image/jpeg'),
          ],
        ),
      ],
    );
    expect(upstream.single.body, contains(base64Encode(<int>[1, 2, 3])));
    expect(upstream.single.body, contains('image/jpeg'));
  });

  test('提供商清单只列可用、非互联的那几家，不含 key 与地址', () async {
    settings.aiProviders = <AiProviderConfig>[
      _hostProvider(),
      _hostProvider(id: 'no-tools', tools: false),
      _hostProvider(id: 'off').copyWith(enabled: false),
      AiProviderConfig.interconnectHost(
        id: 'chained',
        name: 'Other host',
        relay: const AiRelayTarget(hostId: 'h2'),
      ),
    ];
    final AiRelayProviderList list = await fetchAiRelayProviders(
      'host-abc',
      transport: transport,
    );
    expect(list.providers.map((AiRelayProviderInfo p) => p.id), <String>[
      'host-openai',
      'no-tools',
    ]);
    expect(list.defaultProviderId, 'host-openai');
    expect(list.byId('host-openai')!.supportsTools, isTrue);
    expect(list.byId('no-tools')!.supportsTools, isFalse);
    expect(list.byId('host-openai')!.model, 'gpt-host');
    expect(transport.rawReplies.single, isNot(contains(_hostKey)));
    expect(transport.rawReplies.single, isNot(contains('api.example.com')));
  });

  test('指定主机上的另一家：按 id 执行；指定的那家不在 → relay_no_provider', () async {
    settings.aiProviders = <AiProviderConfig>[
      _hostProvider(),
      _hostProvider(id: 'second').copyWith(model: 'gpt-second'),
    ];
    await client().complete(
      provider: _relayProvider(providerId: 'second'),
      messages: const <AiChatMessage>[AiChatMessage.user('hi')],
    );
    expect((jsonDecode(upstream.single.body) as Map)['model'], 'gpt-second');
    await expectLater(
      client().complete(
        provider: _relayProvider(providerId: 'gone'),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayNoProvider,
        ),
      ),
    );
  });

  test('主机没设默认、也没指定 → relay_no_provider；不会碰到上游', () async {
    settings.aiFeatureAssignments = const AiFeatureAssignments();
    await expectLater(
      client().complete(
        provider: _relayProvider(),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayNoProvider,
        ),
      ),
    );
    expect(upstream, isEmpty);
  });

  test('主机关了开关 → relay_disabled，能力位不再声明；开着时声明', () async {
    Future<Map<String, Object?>> capabilities() async {
      final HttpClient c = HttpClient();
      try {
        final HttpClientRequest req = await c.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/capabilities'),
        );
        req.headers.set(
          'Authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
        final HttpClientResponse res = await req.close();
        return (jsonDecode(await res.transform(utf8.decoder).join()) as Map)
            .cast<String, Object?>();
      } finally {
        c.close(force: true);
      }
    }

    expect((await capabilities())[kAiRelayCapability], isTrue);
    await prefs.setPref(kInterconnectAiRelayEnabledPref, false);
    expect((await capabilities())[kAiRelayCapability], isNull);
    await expectLater(
      client().complete(
        provider: _relayProvider(),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayDisabled,
        ),
      ),
    );
    await expectLater(
      fetchAiRelayProviders('host-abc', transport: transport),
      throwsA(isA<AiChatFailure>()),
    );
    expect(upstream, isEmpty);
  });

  test('上游失败的短码原样回到客户端（主机 key 被拒 → unauthorized），且只打一次', () async {
    upstreamReply = (http.Request _) =>
        http.Response('{"error":"bad key"}', 401);
    await expectLater(
      client().complete(
        provider: _relayProvider(),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          'unauthorized',
        ),
      ),
    );
    expect(upstream, hasLength(1));
    // 语义失败走 200 + {ok:false}：非 2xx 会让客户端通道换下一条地址重发。
    expect(transport.lastStatus, 200);
  });

  test('请求体不合规 → relay_bad_request（不是 500）', () async {
    final Map<String, Object?> reply = await transport.post(
      'host-abc',
      kAiRelayChatPath,
      <String, Object?>{
        'mode': 'complete',
        'messages': <Object?>[
          <String, Object?>{'role': 'wizard', 'content': 'x'},
        ],
      },
    );
    expect(reply, <String, Object?>{'ok': false, 'error': kAiRelayBadRequest});
    expect(upstream, isEmpty);
  });

  test('测试连接：主机对所选那家真发一次最小请求', () async {
    await client().ping(_relayProvider());
    expect(upstream, hasLength(1));
    expect(upstream.single.headers['Authorization'], 'Bearer $_hostKey');
  });

  test('没接 AI 转发的主机（老版本）→ 404', () async {
    final FushiSyncServer old = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: token,
    );
    await old.start();
    addTearDown(old.stop);
    final _HttpTransport t = _HttpTransport(old, token);
    await expectLater(
      AiChatClient(relayTransport: t).complete(
        provider: _relayProvider(),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayHostUnsupported,
        ),
      ),
    );
    expect(t.lastStatus, 404);
  });

  test('本机没装配互联通道 → relay_unavailable；拉模型 / 转录 → 不支持', () async {
    final AiRelayTransport? saved = aiRelayTransport;
    aiRelayTransport = null;
    addTearDown(() => aiRelayTransport = saved);
    final AiChatClient bare = AiChatClient(rateLimiter: AiRateLimiter());
    addTearDown(bare.close);
    await expectLater(
      bare.complete(
        provider: _relayProvider(),
        messages: const <AiChatMessage>[AiChatMessage.user('hi')],
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayUnavailable,
        ),
      ),
    );
    await expectLater(
      bare.listModels(_relayProvider()),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayOperationUnsupported,
        ),
      ),
    );
    await expectLater(
      bare.transcribeAudio(
        provider: _relayProvider(),
        audioBytes: const <int>[0],
        fileName: 'a.mp3',
        contentType: 'audio/mpeg',
      ),
      throwsA(
        isA<AiChatFailure>().having(
          (AiChatFailure f) => f.message,
          'message',
          kAiRelayOperationUnsupported,
        ),
      ),
    );
  });

  group('配置', () {
    test('互联主机提供商 JSON 往返，不存 key / 地址；只要启用就可用', () {
      final AiProviderConfig relay = _relayProvider(providerId: 'second');
      final String encoded = encodeAiProviderConfigs(<AiProviderConfig>[relay]);
      expect(encoded, isNot(contains('apiKey')));
      expect(encoded, isNot(contains('baseUrl')));
      final AiProviderConfig back = decodeAiProviderConfigs(encoded).single;
      expect(
        back.relay,
        const AiRelayTarget(hostId: 'host-abc', providerId: 'second'),
      );
      expect(back.isInterconnectHost, isTrue);
      expect(back.isUsable, isTrue);
      expect(back.supportsToolCalling, isTrue);
      expect(back.copyWith(enabled: false).isUsable, isFalse);
      expect(back.copyWith(name: 'x').relay, back.relay);
      // 功能指派照常解析到它：所有 AI 功能经同一层拿到这个选项。
      expect(
        const AiFeatureAssignments(
          defaultProviderId: 'relay-1',
        ).resolve(AiFeature.dictStyle, <AiProviderConfig>[back])?.id,
        'relay-1',
      );
    });

    test('普通提供商的编码不变（没有 relay 字段）', () {
      final String encoded = encodeAiProviderConfigs(<AiProviderConfig>[
        _hostProvider(),
      ]);
      expect(encoded, isNot(contains('relay')));
      expect(decodeAiProviderConfigs(encoded).single.relay, isNull);
    });
  });
}
