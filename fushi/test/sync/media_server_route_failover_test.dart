// 拍板台 design-media-server-failover-transport：媒体服务器的换线路下沉到传输层。
// PlexApi / JellyfinApi 的请求漏斗在传输失败时问按服务器共享、单飞的
// MediaServerRouteFailover，换掉自己的根地址后重试这一次请求；浏览、浏览起播、起播
// 详情、播放期请求都走这一处。播放途中断流由播放页以 MediaServerStreamInterrupted
// 问一次（isInterruptedStreamEnd 判「流断了」）。

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/media/video/media_server/media_server_route_failover.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart'
    show rerouteMediaServerAfterFailure;
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server/media_server_route_failover.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _jfLogin = 'http://192.168.1.20:8096';
const String _jfWan = 'https://jf.example.org';
const String _plexLan = 'http://192.168.1.10:32400';
const String _plexWan = 'https://203.0.113.5:32400';

/// [up]：可达的 origin；其余一律连不上。可达的答一份 Jellyfin / Plex 都能解析的空 JSON。
http.Client _servers(Set<String> up, List<String> requested) => MockClient((
  http.Request req,
) async {
  final String origin = '${req.url.scheme}://${req.url.authority}';
  requested.add('${req.method} $origin${req.url.path}');
  if (!up.contains(origin)) {
    throw http.ClientException('Connection refused', req.url);
  }
  return http.Response.bytes(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'Items': <Object?>[],
        'TotalRecordCount': 0,
        'MediaContainer': <String, Object?>{'machineIdentifier': 'mid-home'},
      }),
    ),
    200,
  );
});

JellyfinServerConfig _jellyfin({String active = ''}) =>
    const JellyfinServerConfig(
      serverUrl: _jfLogin,
      username: 'carol',
      userId: 'u1',
      accessToken: 'jf-token',
      alternateUrls: <String>[_jfWan],
    ).withActiveRoute(active);

PlexServerConfig _plex() => const PlexServerConfig(
  machineIdentifier: 'mid-home',
  token: 'server-token',
  clientIdentifier: 'client-uuid',
  connections: <String>[_plexLan, _plexWan],
  accountId: '42',
);

void main() {
  tearDown(MediaServerRouteFailover.resetForTesting);

  group('MediaServerRouteState', () {
    test('传输失败 → 问钩子换线路、改根地址、重试一次；旧地址的 URL 改写到新地址', () async {
      final List<(String, Object)> asked = <(String, Object)>[];
      final MediaServerRouteState route = MediaServerRouteState(
        'http://old',
        hook: (String failed, Object error) async {
          asked.add((failed, error));
          return 'http://new';
        },
      );
      final List<String> bases = <String>[];
      final String result = await route.run(() async {
        bases.add(route.baseUrl);
        if (route.baseUrl == 'http://old') throw const _Transport();
        return 'ok';
      }, isTransportFailure: (Object e) => e is _Transport);
      expect(result, 'ok');
      expect(bases, <String>['http://old', 'http://new']);
      expect(asked.single.$1, 'http://old');
      expect(route.baseUrl, 'http://new');
      expect(route.rebase('http://old/Items/1?x=1'), 'http://new/Items/1?x=1');
      expect(route.rebase('http://oldhost/a'), 'http://oldhost/a');
      expect(route.rebase('http://other/a'), 'http://other/a');
    });

    test('不是传输失败 / 钩子说不换 / 钩子抛错：原样抛、不重试', () async {
      int calls = 0;
      final MediaServerRouteState noSwitch = MediaServerRouteState(
        'http://old',
        hook: (String failed, Object error) async => null,
      );
      await expectLater(
        noSwitch.run<void>(() async {
          calls++;
          throw const _Transport();
        }, isTransportFailure: (Object e) => e is _Transport),
        throwsA(isA<_Transport>()),
      );
      expect(calls, 1);

      final MediaServerRouteState throwing = MediaServerRouteState(
        'http://old',
        hook: (String failed, Object error) async => throw StateError('x'),
      );
      expect(await throwing.failover(const _Transport()), isFalse);
      expect(throwing.baseUrl, 'http://old');

      calls = 0;
      final MediaServerRouteState answered = MediaServerRouteState(
        'http://old',
        hook: (String failed, Object error) async => 'http://new',
      );
      await expectLater(
        answered.run<void>(() async {
          calls++;
          throw StateError('404');
        }, isTransportFailure: (Object e) => e is _Transport),
        throwsA(isA<StateError>()),
      );
      expect(calls, 1);
      expect(answered.baseUrl, 'http://old');
    });

    test('新线路上也失败：只重试一次，第二次的错误原样交出', () async {
      final MediaServerRouteState route = MediaServerRouteState(
        'http://old',
        hook: (String failed, Object error) async => 'http://new',
      );
      int calls = 0;
      await expectLater(
        route.run<void>(() async {
          calls++;
          throw const _Transport();
        }, isTransportFailure: (Object e) => e is _Transport),
        throwsA(isA<_Transport>()),
      );
      expect(calls, 2);
    });
  });

  group('协议层请求漏斗', () {
    test('JellyfinApi：取数在当前线路连不上 → 换线路重试成功，之后现拼的流 / 封面 URL 带'
        '新 host，旧 host 的封面 URL 改走新线路；服务器答 401 不换线路', () async {
      final List<String> requested = <String>[];
      final List<String> failed = <String>[];
      final JellyfinApi api = JellyfinApi(
        serverUrl: _jfLogin,
        accessToken: 'jf-token',
        client: _servers(<String>{_jfWan}, requested),
        onRouteFailure: (String base, Object error) async {
          failed.add(base);
          expect(isJellyfinTransportFailure(error), isTrue);
          return _jfWan;
        },
      );
      addTearDown(api.close);
      final String oldCover = api.imageUrl('i1');
      await api.views('u1');
      expect(failed, <String>[_jfLogin]);
      expect(api.serverUrl, _jfWan);
      expect(api.streamUrl('i1'), startsWith('$_jfWan/Videos/i1/stream'));
      await api.fetchBytes(oldCover);
      expect(requested.last, 'GET $_jfWan/Items/i1/Images/Primary');

      final JellyfinApi unauthorized = JellyfinApi(
        serverUrl: _jfLogin,
        accessToken: 'jf-token',
        client: MockClient((http.Request req) async => http.Response('', 401)),
        onRouteFailure: (String base, Object error) async {
          fail('服务器答了话，不该换线路');
        },
      );
      addTearDown(unauthorized.close);
      await expectLater(
        unauthorized.views('u1'),
        throwsA(isA<JellyfinApiException>()),
      );
    });

    test('PlexApi：带 token 的请求连不上 → 换线路重试；不带 token 的 /identity 不换'
        '（它正是换线路时核对身份用的）', () async {
      final List<String> requested = <String>[];
      final List<String> failed = <String>[];
      final PlexApi api = PlexApi(
        serverUrl: _plexLan,
        token: 'server-token',
        clientInfo: const PlexClientInfo(clientIdentifier: 'c'),
        client: _servers(<String>{_plexWan}, requested),
        onRouteFailure: (String base, Object error) async {
          failed.add(base);
          return _plexWan;
        },
      );
      addTearDown(api.close);
      await expectLater(api.identity(), throwsA(isA<PlexTransportException>()));
      expect(failed, isEmpty);
      await api.sections();
      expect(failed, <String>[_plexLan]);
      expect(api.serverUrl, _plexWan);
      expect(api.partUrl('/library/parts/1/file.mkv'), startsWith(_plexWan));
    });

    test('播放页问换线路：客户端实现 RemoteVideoRouteFailover，换成功后改走新线路', () async {
      final JellyfinVideoClient client = JellyfinVideoClient(
        api: JellyfinApi(
          serverUrl: _jfLogin,
          accessToken: 't',
          client: _servers(const <String>{}, <String>[]),
          onRouteFailure: (String base, Object error) async =>
              error is MediaServerStreamInterrupted ? _jfWan : null,
        ),
        userId: 'u1',
      );
      addTearDown(client.close);
      final Object asCapability = client;
      expect(asCapability, isA<RemoteVideoRouteFailover>());
      expect(
        await client.failoverRemoteVideoRoute(
          const MediaServerStreamInterrupted(),
        ),
        isTrue,
      );
      expect(client.serverUrl, _jfWan);
      expect(client.serverId, _jellyfin().sourceId);
    });
  });

  group('MediaServerRouteFailover', () {
    late List<MediaServerConfig> saved;
    late List<(String, Object)> reroutes;
    late Completer<MediaServerConfig?> gate;
    late DateTime now;

    MediaServerRouteFailover build() => MediaServerRouteFailover(
      loadConfigs: () async => saved,
      reroute: (MediaServerConfig config, Object error) {
        reroutes.add((config.effectiveServerUrl, error));
        return gate.future;
      },
      clock: () => now,
    );

    setUp(() {
      saved = <MediaServerConfig>[_jellyfin()];
      reroutes = <(String, Object)>[];
      gate = Completer<MediaServerConfig?>();
      now = DateTime(2026, 11, 21);
    });

    test('单飞：同一台服务器的一串失败只探一次，都拿到新线路', () async {
      final MediaServerRouteFailover failover = build();
      final String id = _jellyfin().sourceId;
      final Future<String?> a = failover.resolve(
        id,
        _jfLogin,
        const _Transport(),
      );
      final Future<String?> b = failover.resolve(
        id,
        _jfLogin,
        const _Transport(),
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete(_jellyfin(active: _jfWan));
      expect(await a, _jfWan);
      expect(await b, _jfWan);
      expect(reroutes, hasLength(1));
    });

    test('落库的当前线路已不是失败那条（别处先换好了）：直接给当前线路、不探测', () async {
      saved = <MediaServerConfig>[_jellyfin(active: _jfWan)];
      final MediaServerRouteFailover failover = build();
      expect(
        await failover.resolve(
          _jellyfin().sourceId,
          _jfLogin,
          const _Transport(),
        ),
        _jfWan,
      );
      expect(reroutes, isEmpty);
    });

    test('探不到可达线路：冷却期内同一条失败线路不再重探，过了冷却期再探', () async {
      final MediaServerRouteFailover failover = build();
      final String id = _jellyfin().sourceId;
      gate.complete(null);
      expect(await failover.resolve(id, _jfLogin, const _Transport()), isNull);
      expect(await failover.resolve(id, _jfLogin, const _Transport()), isNull);
      expect(reroutes, hasLength(1));
      now = now.add(failover.cooldown + const Duration(seconds: 1));
      expect(await failover.resolve(id, _jfLogin, const _Transport()), isNull);
      expect(reroutes, hasLength(2));
    });

    test('服务器已登出：不探测、不写回', () async {
      saved = <MediaServerConfig>[];
      final MediaServerRouteFailover failover = build();
      expect(
        await failover.resolve(
          _jellyfin().sourceId,
          _jfLogin,
          const _Transport(),
        ),
        isNull,
      );
      expect(reroutes, isEmpty);
    });

    test('没装故障转移器时钩子答「不换」', () async {
      expect(
        await MediaServerRouteFailover.hookFor('x')(
          'http://a',
          const _Transport(),
        ),
        isNull,
      );
    });
  });

  group('端到端：配置建的客户端经装好的故障转移器换线路', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = SyncRepository(db);
    });

    tearDown(() => db.close());

    test('Jellyfin：浏览请求在登录地址连不上 → 探到公网、写回、通知清单缓存失效，'
        '同一个客户端改走公网', () async {
      final JellyfinServerConfig config = _jellyfin();
      await repo.upsertMediaServer(config);
      final List<String> requested = <String>[];
      MediaServerRouteFailover.install(
        MediaServerRouteFailover.forRepository(
          () => repo,
          httpClientFactory: () => _servers(<String>{_jfWan}, requested),
        ),
      );
      final List<String> invalidated = <String>[];
      final StreamSubscription<String> sub = MediaServerRouteFailover
          .reroutedSources
          .listen(invalidated.add);
      addTearDown(sub.cancel);

      final JellyfinVideoClient client = config.buildClient(
        httpClient: _servers(<String>{_jfWan}, <String>[]),
      );
      addTearDown(client.close);
      await client.api.views('u1');

      expect(client.serverUrl, _jfWan);
      expect((await repo.getMediaServers()).single.effectiveServerUrl, _jfWan);
      expect(invalidated, <String>[config.sourceId]);
    });

    test('Plex：起播详情一类的请求在局域网连不上 → 无凭据核对公网身份后切过去，'
        '同一个客户端改走公网', () async {
      final PlexServerConfig config = _plex();
      await repo.upsertMediaServer(config);
      final List<String> probed = <String>[];
      MediaServerRouteFailover.install(
        MediaServerRouteFailover.forRepository(
          () => repo,
          httpClientFactory: () => _servers(<String>{_plexWan}, probed),
        ),
      );
      final PlexVideoClient client = config.buildClient(
        httpClient: _servers(<String>{_plexWan}, <String>[]),
      );
      addTearDown(client.close);
      await client.api.sections();

      expect(client.serverUrl, _plexWan);
      expect(
        (await repo.getMediaServers()).single.effectiveServerUrl,
        _plexWan,
      );
      // 探测只打 /identity（不带 token 的身份核对）。
      expect(
        probed.where((String r) => r.startsWith('GET $_plexWan')),
        everyElement(endsWith('/identity')),
      );
    });

    test('写回按落库时的配置：探测期间被登出就不写回、不加回去', () async {
      final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
        _jellyfin(),
        const JellyfinTransportException('Connection refused'),
        repo: repo,
        httpClientFactory: () => _servers(<String>{_jfWan}, <String>[]),
      );
      expect(rerouted, isNull);
      expect(await repo.getMediaServers(), isEmpty);
    });
  });

  test('isInterruptedStreamEnd：EOF 远在片尾之前才算流断了', () {
    expect(
      isInterruptedStreamEnd(positionMs: 600000, durationMs: 1440000),
      isTrue,
    );
    expect(
      isInterruptedStreamEnd(positionMs: 1439000, durationMs: 1440000),
      isFalse,
    );
    expect(
      isInterruptedStreamEnd(positionMs: null, durationMs: 1440000),
      isFalse,
    );
    expect(isInterruptedStreamEnd(positionMs: 1000, durationMs: null), isFalse);
    expect(isInterruptedStreamEnd(positionMs: 0, durationMs: 10000), isFalse);
  });
}

class _Transport implements Exception {
  const _Transport();
}
