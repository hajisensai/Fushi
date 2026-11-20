// BUG-4997：Plex 连接探测（登录挑线路、请求失败后自动换线路）核对
// machineIdentifier 之前就把 X-Plex-Token 发给了被探测地址。修复后 `/identity`
// 不带凭据，核对通过、被选为当前线路的地址才会收到带 token 的请求。
// 假 PMS 走 MockClient：按 origin 决定「连不上 / 答成哪台服务器」，并记下每个
// 请求带没带 token。

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_api.dart';
import 'package:fushi_engine/media/video/media_server/plex/plex_tv_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _lan = 'http://192.168.1.10:32400';
const String _wan = 'https://203.0.113.5:32400';
const String _relay = 'https://relay.plex.direct:8443';

/// 一次打到假 PMS 的请求：origin、路径、带的 token（没带为 null）。
typedef _Hit = ({String origin, String path, String? token});

/// [answers]：origin → 该地址答的 machineIdentifier；缺项 = 连不上。
http.Client _fakePms(Map<String, String> answers, List<_Hit> hits) =>
    MockClient((http.Request req) async {
      final String origin = '${req.url.scheme}://${req.url.authority}';
      final String? token =
          req.headers['X-Plex-Token'] ??
          req.url.queryParameters['X-Plex-Token'];
      hits.add((origin: origin, path: req.url.path, token: token));
      final String? mid = answers[origin];
      if (mid == null) {
        throw http.ClientException('Connection refused', req.url);
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'MediaContainer': <String, Object?>{
              'machineIdentifier': mid,
              'Directory': <Object?>[],
            },
          }),
        ),
        200,
      );
    });

Iterable<_Hit> _withToken(List<_Hit> hits, String origin) => hits.where(
  (_Hit h) => h.origin == origin && h.token != null && h.token!.isNotEmpty,
);

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
  });

  tearDown(() => db.close());

  test('PlexApi.identity() 不带 token（其它请求照常带）', () async {
    final List<_Hit> hits = <_Hit>[];
    final PlexApi api = PlexApi(
      serverUrl: _lan,
      token: 'server-token',
      clientInfo: const PlexClientInfo(clientIdentifier: 'c'),
      client: _fakePms(const <String, String>{_lan: 'mid-home'}, hits),
    );
    addTearDown(api.close);
    expect(await api.identity(), 'mid-home');
    await api.sections();
    expect(hits.map((_Hit h) => (h.path, h.token)), <(String, String?)>[
      ('/identity', null),
      ('/library/sections', 'server-token'),
    ]);
  });

  test('自动换线路：旧局域网地址是别的服务器，它从未收到 token；切到公网后'
      '只有公网收到带 token 的请求', () async {
    final PlexServerConfig config = const PlexServerConfig(
      machineIdentifier: 'mid-home',
      token: 'server-token',
      clientIdentifier: 'client-uuid',
      connections: <String>[_lan, _wan, _relay],
      serverName: 'Home',
      accountId: '42',
      accountName: 'carol',
    ).withActiveRoute(_relay);
    await repo.upsertMediaServer(config);
    final List<_Hit> hits = <_Hit>[];
    const Map<String, String> answers = <String, String>{
      _lan: 'mid-neighbour',
      _wan: 'mid-home',
    };

    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const PlexTransportException('Connection refused'),
      repo: repo,
      cache: RemoteLibraryCache(),
      httpClientFactory: () => _fakePms(answers, hits),
    );
    expect(rerouted?.effectiveServerUrl, _wan);
    // 三条线路都探测过，探测请求一个都没带 token。
    expect(hits.map((_Hit h) => h.origin).toSet(), <String>{
      _lan,
      _wan,
      _relay,
    });
    expect(hits.where((_Hit h) => h.token != null), isEmpty);

    // 按新配置建客户端发鉴权请求：token 只去核对通过的公网。
    final PlexVideoClient client = (rerouted! as PlexServerConfig).buildClient(
      httpClient: _fakePms(answers, hits),
    );
    await client.listLibraries();
    expect(_withToken(hits, _wan), isNotEmpty);
    expect(_withToken(hits, _lan), isEmpty);
    expect(_withToken(hits, _relay), isEmpty);
  });

  test('账号登录挑线路：局域网地址是别的服务器，它从未收到 token，落库选公网', () async {
    const PlexClientInfo info = PlexClientInfo(clientIdentifier: 'client-uuid');
    final PlexTvApi tv = PlexTvApi(
      clientInfo: info,
      client: MockClient((http.Request req) async {
        if (req.url.host == 'clients.plex.tv') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(<Object?>[
                <String, Object?>{
                  'name': 'Home',
                  'provides': 'server',
                  'clientIdentifier': 'mid-home',
                  'accessToken': 'server-token',
                  'connections': <Object?>[
                    <String, Object?>{'uri': _wan, 'local': false},
                    <String, Object?>{'uri': _lan, 'local': true},
                  ],
                },
              ]),
            ),
            200,
          );
        }
        return http.Response('', 404);
      }),
    );
    addTearDown(tv.close);
    final List<_Hit> hits = <_Hit>[];

    final List<PlexServerConfig> saved = await savePlexAccountServers(
      repo,
      tv: tv,
      accountToken: 'acct-token',
      info: info,
      probe: (String uri, String machineIdentifier) => probePlexConnection(
        uri,
        machineIdentifier,
        info,
        timeout: const Duration(seconds: 2),
        httpClientFactory: () => _fakePms(const <String, String>{
          _lan: 'mid-neighbour',
          _wan: 'mid-home',
        }, hits),
      ),
    );

    expect(saved, hasLength(1));
    expect(saved.single.effectiveServerUrl, _wan);
    expect(saved.single.token, 'server-token');
    expect(hits.map((_Hit h) => h.origin).toSet(), <String>{_lan, _wan});
    expect(hits.where((_Hit h) => h.token != null), isEmpty);
  });

  test('期望的 machineIdentifier 为空：不发请求，判不通过', () async {
    final List<_Hit> hits = <_Hit>[];
    expect(
      await verifyPlexServerIdentity(
        _lan,
        '',
        const PlexClientInfo(clientIdentifier: 'c'),
        client: _fakePms(const <String, String>{_lan: ''}, hits),
      ),
      isFalse,
    );
    expect(hits, isEmpty);
  });
}
