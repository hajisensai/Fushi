// AI 多 key 轮换（反馈 #Su6zUDHzLk）：存储迁移、失败归类、冷却、轮换顺序。
//
// 轮换走真实的 AiChatClient + MockClient：判据是「这次请求实际带着哪把 key 发了
// 几次」，而不是某个内部函数的返回值——轮换写错在生产里的表现只是「明明配了两把
// key，第一把一挂整个功能就挂」。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_key_rotation.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
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

/// 并发测试的假服务端：两个请求都停在 sk-a 上，由测试决定应答先后。
typedef _HeldOnA = ({
  MockClient client,
  List<Completer<http.Response>> replies,
  Future<void> bothOnA,
});

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

    test('余额判据只认明确的错误码 / 短语，裸词 billing 不算', () {
      // 正例：各家额度 / 余额耗尽时真实返回的码与短语。
      for (final (int status, String body) in <(int, String)>[
        (400, '{"error":{"code":"billing_hard_limit_reached"}}'),
        (
          429,
          '{"error":{"code":"billing_not_active","message":"Your account is '
              'not active, please check your billing details on our website."}}',
        ),
        (
          429,
          '{"error":{"type":"exceeded_current_quota_error","message":"Your '
              'account is suspended, please check your plan and billing '
              'details"}}',
        ),
        (
          400,
          '{"code":"Arrearage","message":"Access denied, please make sure '
              'your account is in good standing."}',
        ),
        (403, '{"message":"Sorry, your account balance is insufficient"}'),
        (
          400,
          '{"type":"error","error":{"type":"invalid_request_error","message":'
              '"Your credit balance is too low to access the Anthropic API. '
              'Please go to Plans & Billing to upgrade or purchase credits."}}',
        ),
      ]) {
        expect(classify(status, body).message, 'quota_exhausted', reason: body);
      }

      // 反例：Gemini 的普通限流正文里也写着 billing——必须仍是限流，并保住
      // Retry-After（被当成余额耗尽会丢掉它、改按失败次数指数退避）。
      final AiChatFailure gemini = classify(
        429,
        '{"error":{"code":429,"message":"You exceeded your current quota, '
        'please check your plan and billing details.",'
        '"status":"RESOURCE_EXHAUSTED"}}',
        retryAfter: '30',
      );
      expect(gemini.message, 'rate_limited');
      expect(gemini.retryAfter, const Duration(seconds: 30));
      // 正文顺带提到 billing 的无关请求错误：与 key 无关，不换 key。
      expect(
        classify(
          400,
          '{"error":{"message":"Unknown parameter: billing_address"}}',
        ).message,
        'http_400',
      );
      // 403 本来就按鉴权换 key；不因提到 billing 被改判成余额耗尽。
      expect(
        classify(
          403,
          '{"error":{"message":"Billing account for this project is '
          'disabled"}}',
        ).message,
        'unauthorized',
      );
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
      // 解码出来的新对象与原记录值相等（并发落账靠值相等判断「记录变没变」）。
      expect(back, health);
      expect(back.hashCode, health.hashCode);
    });
  });

  group('并发落账：同一把 key 上同时在飞的请求', () {
    final DateTime now = DateTime.utc(2026, 10, 13, 12);
    const String fp = 'fp';
    late InMemoryAiKeyHealthStore store;

    setUp(() => store = InMemoryAiKeyHealthStore());

    void fail(AiKeyHealth? seen, {Duration? retryAfter}) => store.update(
      fp,
      (AiKeyHealth? current) => aiKeyHealthAfterFailure(
        seen: seen,
        current: current,
        reason: 'rate_limited',
        retryAfter: retryAfter,
        now: now,
      ),
    );

    void succeed(AiKeyHealth? seen) => store.update(
      fp,
      (AiKeyHealth? current) =>
          aiKeyHealthAfterSuccess(seen: seen, current: current),
    );

    test('同一旧视图出发的两次无 Retry-After 失败只记一次退避', () {
      fail(null);
      fail(null);
      final AiKeyHealth health = store.read(fp)!;
      expect(health.failures, 1);
      expect(health.cooldownUntil, now.add(kAiKeyBaseCooldown));
    });

    test('并发失败里更长的 Retry-After 胜出，失败次数仍不累加', () {
      fail(null);
      fail(null, retryAfter: const Duration(minutes: 10));
      final AiKeyHealth health = store.read(fp)!;
      expect(health.failures, 1);
      expect(health.cooldownUntil, now.add(const Duration(minutes: 10)));
    });

    test('真正的连续失败（发出前就看到了上一次失败）照常翻倍', () {
      fail(null);
      fail(store.read(fp));
      final AiKeyHealth health = store.read(fp)!;
      expect(health.failures, 2);
      expect(health.cooldownUntil, now.add(const Duration(minutes: 2)));
    });

    test('按旧视图发出的成功不抹掉别处刚记的冷却；看到了那条冷却的成功才清', () {
      fail(null);
      succeed(null);
      expect(store.read(fp)!.failures, 1);
      succeed(store.read(fp));
      expect(store.read(fp), isNull);
    });

    test('先成功后失败：失败从第一次重新计', () {
      fail(null);
      final AiKeyHealth? seen = store.read(fp);
      // 两个请求都在冷却记录存在时发出；成功先回来清掉了它。
      succeed(seen);
      expect(store.read(fp), isNull);
      fail(seen);
      expect(store.read(fp)!.failures, 1);
    });
  });

  group('AiChatClient 轮换', () {
    late InMemoryAiKeyHealthStore store;
    late DateTime now;

    setUp(() {
      store = InMemoryAiKeyHealthStore();
      now = DateTime.utc(2026, 10, 13, 12);
    });

    /// 重试退避不真等：限频器与客户端共用假时钟，sleep 只把时间往前拨。
    AiRateLimiter fakeLimiter() => AiRateLimiter(
      now: () => now,
      sleep: (Duration d) async => now = now.add(d),
    );

    AiChatClient clientFor(_FakeServer server) => AiChatClient(
      client: server.client,
      healthStore: store,
      clock: () => now,
      rateLimiter: fakeLimiter(),
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

    test('与 key 无关的失败（5xx）不换 key、不记冷却（只按临时性失败原样重试）', () async {
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
      expect(server.calls, <String>[
        for (int i = 0; i < kAiChatMaxAttempts; i++) 'sk-a',
      ]);
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
      // 第一次请求：冷却 1 分钟，等到期后重试一次（再失败冷却 2 分钟，超过重试
      // 上限不再干等）；之后两次请求各在冷却中真打一次。
      expect(server.calls, <String>['sk-b', 'sk-b', 'sk-b', 'sk-b']);
    });

    test('放弃后整家先停一会儿：下一个请求不紧接着再撞 429（仍然真发）', () async {
      // 用户本机漫画 AI OCR 一页接一页吃 429：单 key 冷却拦不住请求、放弃时又没
      // 写退避，下一页立刻拿到空位。
      final List<DateTime> sentAt = <DateTime>[];
      final AiChatClient client = AiChatClient(
        client: MockClient((http.Request request) async {
          sentAt.add(now);
          return http.Response('{}', 429);
        }),
        healthStore: store,
        clock: () => now,
        rateLimiter: fakeLimiter(),
      );
      final AiProviderConfig provider = _provider(const <AiApiKey>[
        AiApiKey('sk-a'),
      ]);
      await expectLater(ask(client, provider), throwsA(isA<AiChatFailure>()));
      final DateTime gaveUp = sentAt.last;
      await expectLater(ask(client, provider), throwsA(isA<AiChatFailure>()));
      expect(sentAt.length, greaterThan(2), reason: '下一个请求仍然真的发出去');
      final DateTime next = sentAt[sentAt.indexOf(gaveUp) + 1];
      expect(
        next.difference(gaveUp),
        greaterThanOrEqualTo(kAiChatMaxRetryWait),
        reason: '放弃时留下的整家退避让下一个请求排到之后',
      );
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

    /// sk-a 的应答由测试逐个放行（[replies] 按到达顺序），sk-b 恒成功。
    _HeldOnA heldOnA() {
      final List<Completer<http.Response>> replies =
          <Completer<http.Response>>[];
      final Completer<void> bothOnA = Completer<void>();
      final MockClient client = MockClient((http.Request request) async {
        final String key = (request.headers['authorization'] ?? '')
            .replaceFirst('Bearer ', '');
        if (key != 'sk-a') return _ok();
        final Completer<http.Response> reply = Completer<http.Response>();
        replies.add(reply);
        if (replies.length == 2) bothOnA.complete();
        return reply.future;
      });
      return (client: client, replies: replies, bothOnA: bothOnA.future);
    }

    final AiProviderConfig twoKeys = _provider(const <AiApiKey>[
      AiApiKey('sk-a'),
      AiApiKey('sk-b'),
    ]);

    test('两个并发请求在同一把 key 上都吃到无 Retry-After 的 429：只记一次退避', () async {
      final _HeldOnA held = heldOnA();
      final AiChatClient client = AiChatClient(
        client: held.client,
        rateLimiter: fakeLimiter(),
        healthStore: store,
        clock: () => now,
      );
      final Future<String> first = ask(client, twoKeys);
      final Future<String> second = ask(client, twoKeys);
      await held.bothOnA;
      for (final Completer<http.Response> reply in held.replies) {
        reply.complete(http.Response('{}', 429));
      }
      expect(await first, 'ok');
      expect(await second, 'ok');
      final AiKeyHealth health = healthOf('sk-a')!;
      expect(health.failures, 1);
      expect(health.cooldownUntil, now.add(kAiKeyBaseCooldown));
    });

    test('成功与失败交错：两种落账顺序都留下同一条冷却', () async {
      for (final bool failureFirst in <bool>[true, false]) {
        store = InMemoryAiKeyHealthStore();
        final _HeldOnA held = heldOnA();
        final AiChatClient client = AiChatClient(
          client: held.client,
          rateLimiter: fakeLimiter(),
          healthStore: store,
          clock: () => now,
        );
        final Future<String> first = ask(client, twoKeys);
        final Future<String> second = ask(client, twoKeys);
        await held.bothOnA;
        held.replies[0].complete(
          failureFirst ? http.Response('{}', 429) : _ok(),
        );
        expect(await first, 'ok');
        held.replies[1].complete(
          failureFirst ? _ok() : http.Response('{}', 429),
        );
        expect(await second, 'ok');
        // 失败先落账：按旧视图（发出时没有冷却）发出的成功不能把它清掉；
        // 成功先落账：之后回来的失败照常记一次。
        final AiKeyHealth health = healthOf('sk-a')!;
        expect(health.failures, 1, reason: 'failureFirst=$failureFirst');
        expect(health.reason, 'rate_limited');
      }
    });

    test('测试连接逐把真打（冷却中的也打），通过即清冷却', () async {
      // sk-a 余额不足被退避到几小时后；用户充值后服务端已恢复。
      store.update(
        aiKeyFingerprint('p1', 'sk-a'),
        (_) => AiKeyHealth(
          cooldownUntil: now.add(const Duration(hours: 6)),
          failures: 9,
          reason: 'quota_exhausted',
        ),
      );
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': _ok,
        'sk-b': _ok,
      });
      await clientFor(server).ping(twoKeys);
      expect(server.calls, <String>['sk-a', 'sk-b']);
      expect(healthOf('sk-a'), isNull);
    });

    test('测试连接：有一把通过即成功，失败的那把照常记冷却；全挂抛最后一个真实错误', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': () => http.Response('{}', 401),
        'sk-b': _ok,
      });
      await clientFor(server).ping(twoKeys);
      expect(server.calls, <String>['sk-a', 'sk-b']);
      expect(healthOf('sk-a')!.reason, 'unauthorized');
      expect(healthOf('sk-b'), isNull);

      server.responses['sk-b'] = () => http.Response('{}', 402);
      server.calls.clear();
      await expectLater(
        clientFor(server).ping(twoKeys),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure f) => f.message,
            'message',
            'quota_exhausted',
          ),
        ),
      );
      expect(server.calls, <String>['sk-a', 'sk-b']);
    });

    test('测试连接遇到与 key 无关的失败立即抛出，不再打后面的 key', () async {
      final _FakeServer server = _FakeServer(<String, http.Response Function()>{
        'sk-a': () => http.Response('{}', 404),
        'sk-b': _ok,
      });
      await expectLater(
        clientFor(server).ping(twoKeys),
        throwsA(
          isA<AiChatFailure>().having(
            (AiChatFailure f) => f.message,
            'message',
            'http_404',
          ),
        ),
      );
      expect(server.calls, <String>['sk-a']);
      expect(healthOf('sk-a'), isNull);
    });
  });
}
