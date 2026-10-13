// AI 多 key 轮换（反馈 #Su6zUDHzLk）：存储迁移、失败归类、冷却、轮换顺序。
//
// 轮换走真实的 AiChatClient + MockClient：判据是「这次请求实际带着哪把 key 发了
// 几次」，而不是某个内部函数的返回值——轮换写错在生产里的表现只是「明明配了两把
// key，第一把一挂整个功能就挂」。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_key_rotation.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AiProviderConfig _provider(List<AiApiKey> keys) => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'OpenAI',
  baseUrl: Uri.parse('https://api.example.com/v1'),
  apiKeys: keys,
  model: 'm',
);

http.Response _ok() => http.Response(
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

/// 按 Bearer key 决定应答的假服务端；[calls] 记下每次请求带的 key（按顺序）。
class _FakeServer {
  _FakeServer(this.responses);

  final Map<String, http.Response Function()> responses;
  final List<String> calls = <String>[];

  MockClient get client => MockClient((http.Request request) async {
    final String key = (request.headers['authorization'] ?? '').replaceFirst(
      'Bearer ',
      '',
    );
    calls.add(key);
    final http.Response Function()? respond = responses[key];
    return respond == null ? http.Response('{}', 500) : respond();
  });
}

void main() {
  group('存储：单 key → 列表的无损迁移', () {
    test('单 key 时代的记录（只有 apiKeyB64）读成一元素列表', () {
      final String legacy = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'p1',
          'presetId': 'openai',
          'name': 'OpenAI',
          'baseUrl': 'https://api.openai.com/v1',
          'apiKeyB64': base64Encode(utf8.encode('sk-legacy')),
          'model': 'gpt',
          'protocol': 'openAiCompatible',
          'enabled': true,
        },
      ]);
      final AiProviderConfig config = decodeAiProviderConfigs(legacy).single;
      expect(config.apiKeys, <AiApiKey>[const AiApiKey('sk-legacy')]);
      expect(config.apiKey, 'sk-legacy');
      expect(config.isUsable, isTrue);
    });

    test('多 key 往返保留顺序与启用开关，并照旧写 apiKeyB64 给旧版本读', () {
      final AiProviderConfig source = _provider(const <AiApiKey>[
        AiApiKey('sk-a', enabled: false),
        AiApiKey('sk-b'),
        AiApiKey('  '),
        AiApiKey('sk-c'),
      ]);
      final String raw = encodeAiProviderConfigs(<AiProviderConfig>[source]);
      expect(raw, isNot(contains('sk-a')));
      expect(raw, isNot(contains('sk-b')));

      final Map<String, Object?> json =
          (jsonDecode(raw) as List<Object?>).single! as Map<String, Object?>;
      // 降级到旧版本时，旧解码器只认 apiKeyB64：写的是第一把**参与请求**的 key。
      expect(utf8.decode(base64Decode(json['apiKeyB64']! as String)), 'sk-b');

      final AiProviderConfig back = decodeAiProviderConfigs(raw).single;
      expect(back.apiKeys, const <AiApiKey>[
        AiApiKey('sk-a', enabled: false),
        AiApiKey('sk-b'),
        AiApiKey('sk-c'),
      ]);
      expect(back.activeApiKeys, <String>['sk-b', 'sk-c']);
      expect(back.apiKey, 'sk-b');
    });

    test('全部停用 = 未配置完整；重复的 key 只留第一把', () {
      expect(
        _provider(const <AiApiKey>[AiApiKey('sk-a', enabled: false)]).isUsable,
        isFalse,
      );
      final String raw = jsonEncode(<Object?>[
        <String, Object?>{
          'id': 'p1',
          'baseUrl': 'https://api.openai.com/v1',
          'model': 'm',
          'apiKeys': <Object?>[
            <String, Object?>{'keyB64': base64Encode(utf8.encode('sk-a'))},
            <String, Object?>{'keyB64': base64Encode(utf8.encode('sk-a'))},
          ],
        },
      ]);
      expect(decodeAiProviderConfigs(raw).single.apiKeys, hasLength(1));
    });

    test('末 4 位', () {
      expect(const AiApiKey(' sk-abcdef1234 ').tail, '1234');
      expect(const AiApiKey('xy').tail, 'xy');
    });
  });

  group('失败归类', () {
    final DateTime now = DateTime.utc(2026, 10, 13, 12);
    AiChatFailure classify(int status, String body, {String? retryAfter}) =>
        classifyAiHttpFailure(
          statusCode: status,
          bodyBytes: utf8.encode(body),
          retryAfterHeader: retryAfter,
          now: now,
        );

    test('鉴权 / 限流 / 余额换 key，其余不换', () {
      expect(classify(401, '').message, 'unauthorized');
      expect(classify(403, '').message, 'unauthorized');
      expect(classify(402, '').message, 'quota_exhausted');
      expect(
        classify(429, '{"error":{"code":"insufficient_quota"}}').message,
        'quota_exhausted',
      );
      expect(
        classify(400, '{"error":{"message":"Insufficient Balance"}}').message,
        'quota_exhausted',
      );
      expect(
        classify(
          400,
          '{"error":{"status":"INVALID_ARGUMENT",'
          '"details":[{"reason":"API_KEY_INVALID"}]}}',
        ).message,
        'unauthorized',
      );
      expect(classify(400, '{"error":"bad model"}').message, 'http_400');
      expect(classify(500, '').message, 'http_500');
      expect(classify(500, '').rotatesKey, isFalse);
      expect(classify(401, '').rotatesKey, isTrue);
      expect(classify(402, '').rotatesKey, isTrue);
    });

    test('429 带上 Retry-After（秒数与 HTTP-date 两种形状）', () {
      final AiChatFailure seconds = classify(429, '', retryAfter: '30');
      expect(seconds.message, 'rate_limited');
      expect(seconds.retryAfter, const Duration(seconds: 30));
      final AiChatFailure date = classify(
        429,
        '',
        retryAfter: 'Tue, 13 Oct 2026 12:02:00 GMT',
      );
      expect(date.retryAfter, const Duration(minutes: 2));
      expect(classify(429, '').retryAfter, isNull);
    });
  });

  group('冷却时长', () {
    final DateTime now = DateTime.utc(2026, 10, 13, 12);

    test('无 Retry-After 时指数退避，封顶一天', () {
      AiKeyHealth? health;
      final List<Duration> cooldowns = <Duration>[];
      for (int i = 0; i < 14; i++) {
        health = nextAiKeyHealth(
          previous: health,
          reason: 'unauthorized',
          retryAfter: null,
          now: now,
        );
        cooldowns.add(health.cooldownUntil.difference(now));
      }
      expect(cooldowns.take(4), const <Duration>[
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 4),
        Duration(minutes: 8),
      ]);
      expect(cooldowns.last, kAiKeyMaxCooldown);
      expect(health!.failures, 14);
    });

    test('Retry-After 优先于退避', () {
      final AiKeyHealth health = nextAiKeyHealth(
        previous: null,
        reason: 'rate_limited',
        retryAfter: const Duration(seconds: 90),
        now: now,
      );
      expect(health.cooldownUntil, now.add(const Duration(seconds: 90)));
    });

    test('健康记录 JSON 往返；畸形记录当作没有', () {
      final AiKeyHealth health = nextAiKeyHealth(
        previous: null,
        reason: 'quota_exhausted',
        retryAfter: null,
        now: now,
      );
      final AiKeyHealth back = AiKeyHealth.fromJson(health.toJson())!;
      expect(back.cooldownUntil, health.cooldownUntil);
      expect(back.failures, 1);
      expect(back.reason, 'quota_exhausted');
      expect(AiKeyHealth.fromJson(<String, Object?>{'until': 'x'}), isNull);
    });
  });

  group('AiChatClient 轮换', () {
    late InMemoryAiKeyHealthStore store;
    late DateTime now;

    setUp(() {
      store = InMemoryAiKeyHealthStore();
      now = DateTime.utc(2026, 10, 13, 12);
    });

    AiChatClient clientFor(_FakeServer server) => AiChatClient(
      client: server.client,
      healthStore: store,
      clock: () => now,
    );

    Future<String> ask(AiChatClient client, AiProviderConfig provider) =>
        client.complete(
          provider: provider,
          messages: const <AiChatMessage>[AiChatMessage.user('hi')],
        );

    AiKeyHealth? healthOf(String key) =>
        store.read(aiKeyFingerprint('p1', key));

    test('第一把被限流 → 换第二把重试当前请求；第一把按 Retry-After 冷却', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': () => http.Response(
          '{}',
          429,
          headers: <String, String>{'retry-after': '120'},
        ),
        'sk-b': _ok,
      });
      final AiProviderConfig provider = _provider(const <AiApiKey>[
        AiApiKey('sk-a'),
        AiApiKey('sk-b'),
      ]);
      final AiChatClient client = clientFor(server);

      expect(await ask(client, provider), 'ok');
      expect(server.calls, <String>['sk-a', 'sk-b']);
      expect(
        healthOf('sk-a')!.cooldownUntil,
        now.add(const Duration(seconds: 120)),
      );
      expect(healthOf('sk-b'), isNull);

      // 冷却期内下一次请求直接从第二把开始。
      server.calls.clear();
      expect(await ask(client, provider), 'ok');
      expect(server.calls, <String>['sk-b']);

      // 冷却到期后第一把重新排回第一位（服务端恢复了 → 成功并清掉记录）。
      server.responses['sk-a'] = _ok;
      now = now.add(const Duration(seconds: 121));
      server.calls.clear();
      expect(await ask(client, provider), 'ok');
      expect(server.calls, <String>['sk-a']);
      expect(healthOf('sk-a'), isNull);
    });

    test('全部失效：每把只试一次，抛最后一个真实错误，各自记冷却', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': () => http.Response('{}', 401),
        'sk-b': () => http.Response('{}', 402),
      });
      final AiChatClient client = clientFor(server);
      final AiProviderConfig provider = _provider(const <AiApiKey>[
        AiApiKey('sk-a'),
        AiApiKey('sk-b'),
      ]);

      await expectLater(
        ask(client, provider),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure f) => f.message,
            'message',
            'quota_exhausted',
          ),
        ),
      );
      expect(server.calls, <String>['sk-a', 'sk-b']);
      expect(healthOf('sk-a')!.reason, 'unauthorized');
      expect(healthOf('sk-b')!.reason, 'quota_exhausted');

      // 全在冷却：不凭本地记录编一个失败，而是真打最早到期的那一把一次。
      server.calls.clear();
      now = now.add(const Duration(seconds: 10));
      await expectLater(ask(client, provider), throwsA(isA<AiChatFailure>()));
      expect(server.calls, hasLength(1));
      // 连续第二次失败，退避翻倍。
      final AiKeyHealth again = healthOf(server.calls.single)!;
      expect(again.failures, 2);
      expect(again.cooldownUntil, now.add(const Duration(minutes: 2)));
    });

    test('与 key 无关的失败（5xx）不换 key、不记冷却', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': () => http.Response('{}', 503),
        'sk-b': _ok,
      });
      await expectLater(
        ask(
          clientFor(server),
          _provider(const <AiApiKey>[AiApiKey('sk-a'), AiApiKey('sk-b')]),
        ),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure f) => f.message,
            'message',
            'http_503',
          ),
        ),
      );
      expect(server.calls, <String>['sk-a']);
      expect(healthOf('sk-a'), isNull);
    });

    test('停用的 key 不发；单 key 冷却中照样每次真发（与单 key 时代行为一致）', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-b': () => http.Response('{}', 429),
      });
      final AiChatClient client = clientFor(server);
      final AiProviderConfig provider = _provider(const <AiApiKey>[
        AiApiKey('sk-a', enabled: false),
        AiApiKey('sk-b'),
      ]);
      for (int i = 0; i < 3; i++) {
        await expectLater(ask(client, provider), throwsA(isA<AiChatFailure>()));
      }
      expect(server.calls, <String>['sk-b', 'sk-b', 'sk-b']);
    });

    test('listModels / ping 同样轮换', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': () => http.Response('{}', 401),
        'sk-b': () => http.Response(
          jsonEncode(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{'id': 'm1'},
            ],
          }),
          200,
        ),
      });
      final List<String> models = await clientFor(server).listModels(
        _provider(const <AiApiKey>[AiApiKey('sk-a'), AiApiKey('sk-b')]),
      );
      expect(models, <String>['m1']);
      expect(server.calls, <String>['sk-a', 'sk-b']);
    });
  });
}
