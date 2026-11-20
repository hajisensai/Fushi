// BUG-4906（gap-remote-7）：Plex 当前连接请求没到达服务器时，在已存连接里按
// 优先级重新探测（核对 machineIdentifier），切到可达的那条、写回配置并失效清单
// 缓存。假服务器走 MockClient：按 host 决定「连不上 / 答话 / 答成别的服务器」。

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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _lan = 'http://192.168.1.10:32400';
const String _wan = 'https://203.0.113.5:32400';
const String _relay = 'https://relay.plex.direct:8443';

class _RecordingCache extends RemoteLibraryCache {
  final List<String> invalidated = <String>[];

  @override
  void invalidateSource(String sourceId) {
    invalidated.add(sourceId);
    super.invalidateSource(sourceId);
  }
}

/// [answers]：host → 该地址 `/identity` 答的 machineIdentifier；缺项 = 连不上。
http.Client _fakeServers(Map<String, String> answers, List<String> requested) =>
    MockClient((http.Request req) async {
      final String origin = '${req.url.scheme}://${req.url.authority}';
      requested.add(origin);
      final String? mid = answers[origin];
      if (mid == null) {
        throw http.ClientException('Connection refused', req.url);
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'MediaContainer': <String, Object?>{'machineIdentifier': mid},
          }),
        ),
        200,
      );
    });

PlexServerConfig _config({String active = ''}) => const PlexServerConfig(
  machineIdentifier: 'mid-home',
  token: 'server-token',
  clientIdentifier: 'client-uuid',
  connections: <String>[_lan, _wan, _relay],
  serverName: 'Home',
  accountId: '42',
  accountName: 'carol',
).withActiveRoute(active);

void main() {
  late FushiDatabase db;
  late SyncRepository repo;
  late _RecordingCache cache;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    cache = _RecordingCache();
  });

  tearDown(() => db.close());

  test('PlexApi 连不上抛 PlexTransportException（文案不变），服务器答非 2xx 仍是 '
      'PlexApiException', () async {
    final PlexApi down = PlexApi(
      serverUrl: _lan,
      token: 't',
      clientInfo: const PlexClientInfo(clientIdentifier: 'c'),
      client: _fakeServers(const <String, String>{}, <String>[]),
    );
    addTearDown(down.close);
    Object? error;
    try {
      await down.identity();
    } catch (e) {
      error = e;
    }
    expect(error, isA<PlexTransportException>());
    expect(isPlexTransportFailure(error!), isTrue);
    expect(error.toString(), startsWith('Exception: '));
    expect(isPlexTransportFailure(const PlexApiException(404, '/x')), isFalse);
    expect(isPlexTransportFailure(StateError('not found')), isFalse);
  });

  test('局域网连不上、公网是同一台：切到公网，写回配置并失效清单缓存', () async {
    final PlexServerConfig config = _config();
    await repo.upsertMediaServer(config);
    expect(config.effectiveServerUrl, _lan);
    final List<String> requested = <String>[];

    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const PlexTransportException('Connection refused'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, String>{
        _wan: 'mid-home',
        _relay: 'mid-home',
      }, requested),
    );

    expect(rerouted, isA<PlexServerConfig>());
    expect(rerouted!.effectiveServerUrl, _wan);
    expect(rerouted.sourceId, config.sourceId);
    expect(requested.toSet(), <String>{_lan, _wan, _relay});
    final List<MediaServerConfig> stored = await repo.getMediaServers();
    expect(stored, hasLength(1));
    expect(stored.single.effectiveServerUrl, _wan);
    // 只换当前线路：token、连接清单不变。
    final PlexServerConfig saved = stored.single as PlexServerConfig;
    expect(saved.token, 'server-token');
    expect(saved.connections, <String>[_lan, _wan, _relay]);
    expect(cache.invalidated, <String>[config.sourceId]);
  });

  test('在外面走公网时公网断了、回家后局域网可达：切回排名最靠前的局域网', () async {
    final PlexServerConfig config = _config(active: _wan);
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const PlexTransportException('Connection reset'),
      repo: repo,
      cache: cache,
      httpClientFactory: () =>
          _fakeServers(const <String, String>{_lan: 'mid-home'}, <String>[]),
    );
    expect(rerouted?.effectiveServerUrl, _lan);
    expect((await repo.getMediaServers()).single.effectiveServerUrl, _lan);
  });

  test('旧局域网地址被别的 Plex 服务器占了（machineIdentifier 对不上）：不切过去', () async {
    final PlexServerConfig config = _config(active: _wan);
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const PlexTransportException('Connection reset'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, String>{
        _lan: 'mid-neighbour',
      }, <String>[]),
    );
    expect(rerouted, isNull);
    expect((await repo.getMediaServers()).single.effectiveServerUrl, _wan);
    expect(cache.invalidated, isEmpty);
  });

  test('服务器答了话（非 2xx / 条目不存在）不探测、不切换', () async {
    final PlexServerConfig config = _config();
    await repo.upsertMediaServer(config);
    final List<String> requested = <String>[];
    for (final Object error in <Object>[
      const PlexApiException(404, '/library/metadata/1'),
      StateError('Plex item 1 not found'),
    ]) {
      final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
        config,
        error,
        repo: repo,
        cache: cache,
        httpClientFactory: () =>
            _fakeServers(const <String, String>{_wan: 'mid-home'}, requested),
      );
      expect(rerouted, isNull);
    }
    expect(requested, isEmpty);
    expect(cache.invalidated, isEmpty);
  });

  test('最靠前的可达线路就是当前这条（刚才只是抖动）：不写回', () async {
    final PlexServerConfig config = _config(active: _wan);
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const PlexTransportException('Connection reset'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, String>{
        _wan: 'mid-home',
        _relay: 'mid-home',
      }, <String>[]),
    );
    expect(rerouted, isNull);
    expect(cache.invalidated, isEmpty);
  });

  test('全部连不上：返回 null，配置不动', () async {
    final PlexServerConfig config = _config();
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const PlexTransportException('Network is unreachable'),
      repo: repo,
      cache: cache,
      httpClientFactory: () =>
          _fakeServers(const <String, String>{}, <String>[]),
    );
    expect(rerouted, isNull);
    expect((await repo.getMediaServers()).single.effectiveServerUrl, _lan);
  });
}
