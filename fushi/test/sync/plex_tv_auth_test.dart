// plex.tv 账号侧协议（纯 Dart，引擎包）：PIN 建立 / 授权页 URL / 轮询状态机 /
// resources 解析 / 连接地址排序与可达探测。假 plex.tv 走 MockClient。

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_tv_auth.dart';

const PlexClientInfo _info = PlexClientInfo(
  clientIdentifier: 'client-uuid',
  platform: 'Android',
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  group('PIN', () {
    test('createPin：POST strong PIN，带身份头', () async {
      final List<http.Request> seen = <http.Request>[];
      final PlexTvApi tv = PlexTvApi(
        clientInfo: _info,
        client: MockClient((http.Request req) async {
          seen.add(req);
          return _json(<String, Object?>{
            'id': 555,
            'code': 'abcd1234',
            'authToken': null,
            'expiresAt': '2030-01-01T00:00:00Z',
          }, 201);
        }),
      );
      final PlexPin pin = await tv.createPin();
      expect(seen.single.method, 'POST');
      expect(
        seen.single.url.toString(),
        'https://plex.tv/api/v2/pins?strong=true',
      );
      expect(seen.single.headers['X-Plex-Client-Identifier'], 'client-uuid');
      expect(seen.single.headers['Accept'], 'application/json');
      expect(seen.single.headers.containsKey('X-Plex-Token'), isFalse);
      expect(pin.id, 555);
      expect(pin.code, 'abcd1234');
      expect(pin.isAuthorized, isFalse);
      expect(pin.isExpiredAt(DateTime.utc(2029)), isFalse);
      expect(pin.isExpiredAt(DateTime.utc(2031)), isTrue);
    });

    test('authUrl：参数在 # 片段里，含 clientID / code / 产品名', () {
      final String url = PlexTvApi(
        clientInfo: _info,
        client: MockClient((_) async => http.Response('', 500)),
      ).authUrl(const PlexPin(id: 1, code: 'c0de'));
      expect(url, startsWith('https://app.plex.tv/auth#?'));
      final Map<String, String> q = Uri.splitQueryString(url.split('#?').last);
      expect(q['clientID'], 'client-uuid');
      expect(q['code'], 'c0de');
      expect(q['context[device][product]'], PlexClientInfo.kPlexProduct);
    });

    test('checkPin：GET /api/v2/pins/{id}?code=，授权后带 token', () async {
      final List<http.Request> seen = <http.Request>[];
      final PlexTvApi tv = PlexTvApi(
        clientInfo: _info,
        client: MockClient((http.Request req) async {
          seen.add(req);
          return _json(<String, Object?>{
            'id': 7,
            'code': 'c',
            'authToken': 'acct-token',
          });
        }),
      );
      final PlexPin pin = await tv.checkPin(const PlexPin(id: 7, code: 'c'));
      expect(seen.single.url.path, '/api/v2/pins/7');
      expect(seen.single.url.queryParameters['code'], 'c');
      expect(pin.isAuthorized, isTrue);
      expect(pin.authToken, 'acct-token');
    });
  });

  group('pollPlexPin', () {
    Future<void> noWait(Duration _) async {}

    test('第三轮拿到 token → authorized；偶发网络错误不终止', () async {
      int calls = 0;
      final result = await pollPlexPin(
        check: () async {
          calls++;
          if (calls == 1) throw Exception('network blip');
          return PlexPin(
            id: 1,
            code: 'c',
            authToken: calls >= 3 ? 'tok' : null,
          );
        },
        isCancelled: () => false,
        delay: noWait,
      );
      expect(result.outcome, PlexPinPollOutcome.authorized);
      expect(result.token, 'tok');
      expect(calls, 3);
    });

    test('plex.tv 对过期 PIN 回 404 → expired', () async {
      final result = await pollPlexPin(
        check: () async => throw const PlexApiException(404, '/api/v2/pins/1'),
        isCancelled: () => false,
        delay: noWait,
      );
      expect(result.outcome, PlexPinPollOutcome.expired);
    });

    test('expiresAt 已过 → expired', () async {
      final DateTime now = DateTime.utc(2030);
      final result = await pollPlexPin(
        check: () async => PlexPin(
          id: 1,
          code: 'c',
          expiresAt: now.subtract(const Duration(seconds: 1)),
        ),
        isCancelled: () => false,
        delay: noWait,
        now: () => now,
      );
      expect(result.outcome, PlexPinPollOutcome.expired);
    });

    test('取消 → cancelled，不再查询', () async {
      int calls = 0;
      bool cancelled = false;
      final result = await pollPlexPin(
        check: () async {
          calls++;
          cancelled = true;
          return const PlexPin(id: 1, code: 'c');
        },
        isCancelled: () => cancelled,
        delay: noWait,
      );
      expect(result.outcome, PlexPinPollOutcome.cancelled);
      expect(calls, 1);
    });

    test('一直未授权 → 到 timeout 判 expired', () async {
      DateTime clock = DateTime.utc(2030);
      final result = await pollPlexPin(
        check: () async => const PlexPin(id: 1, code: 'c'),
        isCancelled: () => false,
        timeout: const Duration(seconds: 10),
        interval: const Duration(seconds: 2),
        delay: (Duration d) async => clock = clock.add(d),
        now: () => clock,
      );
      expect(result.outcome, PlexPinPollOutcome.expired);
    });
  });

  group('resources 与连接选择', () {
    test('只留 provides=server，连接地址归一化；分享服务器带自己的 token', () async {
      final List<http.Request> seen = <http.Request>[];
      final PlexTvApi tv = PlexTvApi(
        clientInfo: _info,
        client: MockClient((http.Request req) async {
          seen.add(req);
          return _json(<Object?>[
            <String, Object?>{
              'name': 'Phone',
              'provides': 'client,player',
              'clientIdentifier': 'phone-1',
            },
            <String, Object?>{
              'name': 'Home PMS',
              'provides': 'server',
              'clientIdentifier': 'mid-1',
              'accessToken': 'server-token',
              'owned': true,
              'connections': <Object?>[
                <String, Object?>{
                  'uri': 'https://1-2-3-4.abc.plex.direct:32400/',
                  'local': false,
                  'relay': false,
                },
              ],
            },
          ]);
        }),
      );
      final List<PlexResource> servers = await tv.resources('acct');
      expect(seen.single.url.host, 'clients.plex.tv');
      expect(seen.single.url.queryParameters['includeHttps'], '1');
      expect(seen.single.url.queryParameters['includeRelay'], '1');
      expect(seen.single.headers['X-Plex-Token'], 'acct');
      expect(servers, hasLength(1));
      expect(servers.single.clientIdentifier, 'mid-1');
      expect(servers.single.accessToken, 'server-token');
      expect(
        servers.single.connections.single.uri,
        'https://1-2-3-4.abc.plex.direct:32400',
      );
    });

    test('排序：局域网 → 公网 → relay；同档 IPv4 先于 IPv6；其余稳定', () {
      const List<PlexConnection> raw = <PlexConnection>[
        PlexConnection(uri: 'relay', relay: true),
        PlexConnection(uri: 'wan-a'),
        PlexConnection(uri: 'lan-v6', local: true, ipv6: true),
        PlexConnection(uri: 'lan-a', local: true),
        PlexConnection(uri: 'wan-b'),
        PlexConnection(uri: 'lan-b', local: true),
      ];
      expect(
        orderPlexConnections(raw).map((PlexConnection c) => c.uri),
        <String>['lan-a', 'lan-b', 'lan-v6', 'wan-a', 'wan-b', 'relay'],
      );
    });

    test('并发探测，返回排名最靠前的可达者；探测抛异常只算不可达', () async {
      final List<String> probed = <String>[];
      final String? chosen = await firstReachablePlexConnection(
        const <PlexConnection>[
          PlexConnection(uri: 'a'),
          PlexConnection(uri: 'b'),
          PlexConnection(uri: 'c'),
          PlexConnection(uri: 'd'),
        ],
        (String uri) async {
          probed.add(uri);
          if (uri == 'a') throw Exception('timeout');
          return uri == 'c';
        },
      );
      expect(chosen, 'c');
      // 各条同时发起：排在可达者后面的那条也已经探了。
      expect(probed, <String>['a', 'b', 'c', 'd']);
      expect(
        await firstReachablePlexConnection(const <PlexConnection>[
          PlexConnection(uri: 'x'),
        ], (_) async => false),
        isNull,
      );
    });

    test('前几条挂着不回时不逐条累加等待：只等到排在可达者前面的都出结果', () async {
      // gap-remote-6：不在家时局域网地址各自挂满探测超时。假探测用 Completer 模拟
      // 「挂着」——串行实现会卡在 lan-a 上，永远轮不到 wan。
      final Map<String, Completer<bool>> pending = <String, Completer<bool>>{
        for (final String uri in <String>['lan-a', 'lan-b', 'wan', 'relay'])
          uri: Completer<bool>(),
      };
      final List<String> probed = <String>[];
      String? chosen;
      bool done = false;
      final Future<void> run =
          firstReachablePlexConnection(
            const <PlexConnection>[
              PlexConnection(uri: 'lan-a', local: true),
              PlexConnection(uri: 'lan-b', local: true),
              PlexConnection(uri: 'wan'),
              PlexConnection(uri: 'relay', relay: true),
            ],
            (String uri) {
              probed.add(uri);
              return pending[uri]!.future;
            },
          ).then((String? uri) {
            chosen = uri;
            done = true;
          });
      await pumpEventQueue();
      expect(probed, <String>['lan-a', 'lan-b', 'wan', 'relay']);

      // 排在后面的先回（relay 最快）：不能抢在排名更靠前的前面定案。
      pending['relay']!.complete(true);
      pending['wan']!.complete(true);
      await pumpEventQueue();
      expect(done, isFalse, reason: '排在前面的 lan-a / lan-b 还没出结果');

      // 局域网两条到点超时（抛异常 / false 都算不可达）。
      pending['lan-a']!.completeError(TimeoutException('probe'));
      pending['lan-b']!.complete(false);
      await run;
      expect(chosen, 'wan', reason: '可达的两条里取排名靠前的 wan，不是先回的 relay');
    });

    test('排名最靠前的那条可达就定案，不等排在后面还挂着的', () async {
      final Completer<bool> never = Completer<bool>();
      final String? chosen = await firstReachablePlexConnection(
        const <PlexConnection>[
          PlexConnection(uri: 'lan', local: true),
          PlexConnection(uri: 'wan'),
        ],
        (String uri) => uri == 'lan' ? Future<bool>.value(true) : never.future,
      );
      expect(chosen, 'lan');
    });

    test('探测函数同步抛出也只算不可达', () async {
      final String? chosen = await firstReachablePlexConnection(
        const <PlexConnection>[
          PlexConnection(uri: 'bad'),
          PlexConnection(uri: 'ok'),
        ],
        (String uri) {
          if (uri == 'bad') throw StateError('sync');
          return Future<bool>.value(true);
        },
      );
      expect(chosen, 'ok');
    });

    test('user：id 字符串化，用户名缺省回落 title', () {
      final PlexTvUser u = PlexTvApi.parseUser(<String, Object?>{
        'id': 42,
        'title': 'alice',
      });
      expect(u.id, '42');
      expect(u.username, 'alice');
    });
  });
}
