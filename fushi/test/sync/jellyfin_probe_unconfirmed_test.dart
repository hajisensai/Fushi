// BUG-3662（反馈 WMxpfrPXJp）：部分 Emby 部署的网关只放行客户端业务路由，
// `/System/Info/Public` 与 `/System/Ping`（根路径与 `/emby` 前缀）全部 404，
// 但登录与读媒体库正常，Emby 官方客户端 / SenPlayer 能用。添加服务器时公开端点
// 全 404 不能判「连不上」，要由真正的认证请求在候选根地址间定案。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200);

bool _isPublicProbe(String path) =>
    path.endsWith('/System/Info/Public') || path.endsWith('/System/Ping');

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  group('probeServer 公开端点全 404', () {
    test('不抛错，返回未确认的探测（候选根地址：填的在前，/emby 在后）', () async {
      final JellyfinApi api = JellyfinApi(
        serverUrl: 'https://emby.example.com',
        client: MockClient((http.Request req) async => http.Response('', 404)),
      );
      final JellyfinServerProbe probe = await api.probeServer();
      expect(probe.confirmed, isFalse);
      expect(probe.unconfirmedBy?.statusCode, 404);
      expect(probe.unconfirmedBy?.endpoint, '/System/Info/Public');
      expect(probe.baseCandidates, <String>[
        'https://emby.example.com',
        'https://emby.example.com/emby',
      ]);
    });

    test('已确认的探测只有一个候选根地址', () async {
      final JellyfinApi api = JellyfinApi(
        serverUrl: 'http://nas:8096',
        client: MockClient(
          (http.Request req) async =>
              _json(<String, Object?>{'ServerName': 'N'}),
        ),
      );
      final JellyfinServerProbe probe = await api.probeServer();
      expect(probe.confirmed, isTrue);
      expect(probe.baseCandidates, <String>['http://nas:8096']);
    });
  });

  group('signInJellyfinServer 在未确认探测下由登录定案', () {
    test('根路径登录成功 → 存根地址', () async {
      final List<String> seen = <String>[];
      final JellyfinServerConfig saved = await signInJellyfinServer(
        repo,
        url: 'https://emby.example.com',
        username: 'u',
        password: 'p',
        httpClientFactory: () => MockClient((http.Request req) async {
          seen.add('${req.method} ${req.url.path}');
          if (_isPublicProbe(req.url.path)) return http.Response('', 404);
          if (req.url.path == '/Users/AuthenticateByName') {
            return _json(<String, Object?>{
              'AccessToken': 'tok',
              'User': <String, Object?>{'Id': 'uid', 'ServerName': 'Box'},
            });
          }
          return http.Response('', 404);
        }),
      );
      expect(saved.serverUrl, 'https://emby.example.com');
      expect(saved.accessToken, 'tok');
      expect(saved.serverName, 'Box');
      expect(seen.last, 'POST /Users/AuthenticateByName');
      expect((await repo.getJellyfinServers()).single.userId, 'uid');
    });

    test('根路径登录 404、/emby 前缀登录成功 → 存带前缀的根地址', () async {
      final JellyfinServerConfig saved = await signInJellyfinServer(
        repo,
        url: 'https://emby.example.com',
        username: 'u',
        password: 'p',
        httpClientFactory: () => MockClient((http.Request req) async {
          if (req.url.path == '/emby/Users/AuthenticateByName') {
            return _json(<String, Object?>{
              'AccessToken': 'tok',
              'User': <String, Object?>{'Id': 'uid'},
            });
          }
          return http.Response('', 404);
        }),
      );
      expect(saved.serverUrl, 'https://emby.example.com/emby');
    });

    test('登录回 401（账号错）原样抛出，不当成连不上', () async {
      await expectLater(
        signInJellyfinServer(
          repo,
          url: 'https://emby.example.com',
          username: 'u',
          password: 'bad',
          httpClientFactory: () => MockClient((http.Request req) async {
            if (req.url.path == '/Users/AuthenticateByName') {
              return http.Response('Invalid username or password', 401);
            }
            return http.Response('', 404);
          }),
        ),
        throwsA(
          isA<JellyfinApiException>().having(
            (JellyfinApiException e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(await repo.getJellyfinServers(), isEmpty);
    });

    test('所有根地址上登录也 404 → 连不上，报探测时的 404', () async {
      await expectLater(
        signInJellyfinServer(
          repo,
          url: 'https://not-a-media-server.example.com',
          username: 'u',
          password: 'p',
          httpClientFactory: () =>
              MockClient((http.Request req) async => http.Response('', 404)),
        ),
        throwsA(
          isA<JellyfinConnectFailure>().having(
            (JellyfinConnectFailure e) => e.cause,
            'cause',
            isA<JellyfinApiException>().having(
              (JellyfinApiException e) => e.endpoint,
              'endpoint',
              '/System/Info/Public',
            ),
          ),
        ),
      );
      expect(await repo.getJellyfinServers(), isEmpty);
    });
  });

  group('addJellyfinRoute 在未确认探测下由读媒体库定案', () {
    JellyfinServerConfig existing() => const JellyfinServerConfig(
      serverUrl: 'http://192.168.1.10:8096',
      username: 'u',
      userId: 'uid',
      accessToken: 'tok',
    );

    test('/emby 前缀下读媒体库成功 → 追加带前缀的线路', () async {
      final JellyfinServerConfig next = await addJellyfinRoute(
        repo,
        existing(),
        'https://emby.example.com',
        httpClientFactory: () => MockClient((http.Request req) async {
          if (req.url.path == '/emby/Users/uid/Views') {
            return _json(<String, Object?>{'Items': <Object?>[]});
          }
          return http.Response('', 404);
        }),
      );
      expect(next.alternateUrls, <String>['https://emby.example.com/emby']);
    });

    test('读媒体库 401（令牌不属于这台）→ 线路校验失败', () async {
      await expectLater(
        addJellyfinRoute(
          repo,
          existing(),
          'https://other.example.com',
          httpClientFactory: () => MockClient((http.Request req) async {
            if (req.url.path == '/Users/uid/Views') {
              return http.Response('', 401);
            }
            return http.Response('', 404);
          }),
        ),
        throwsA(isA<JellyfinRouteVerifyFailure>()),
      );
    });
  });
}
