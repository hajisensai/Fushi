// gap-remote-7 的 Jellyfin 家族版：起播时当前线路不通，在用户手填的线路（登录地址 +
// 备用线路）里自动换一条可达的。假服务器走 MockClient：按 origin 决定「连不上 / 令牌
// 有效 / 令牌无效（别家服务器回 401）」。

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _login = 'http://192.168.1.20:8096';
const String _wan = 'https://jf.example.org';
const String _tunnel = 'https://tunnel.example.net';

class _RecordingCache extends RemoteLibraryCache {
  final List<String> invalidated = <String>[];

  @override
  void invalidateSource(String sourceId) {
    invalidated.add(sourceId);
    super.invalidateSource(sourceId);
  }
}

enum _Answer { ok, unauthorized }

/// [answers]：origin → 那条线路怎么答；缺项 = 连不上。
http.Client _fakeServers(
  Map<String, _Answer> answers,
  List<String> requested,
) => MockClient((http.Request req) async {
  final String origin = '${req.url.scheme}://${req.url.authority}';
  requested.add(origin);
  final _Answer? answer = answers[origin];
  if (answer == null) {
    throw http.ClientException('Connection refused', req.url);
  }
  if (answer == _Answer.unauthorized) return http.Response('', 401);
  return http.Response.bytes(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'Items': <Object?>[],
        'TotalRecordCount': 0,
      }),
    ),
    200,
  );
});

JellyfinServerConfig _config({String active = ''}) =>
    const JellyfinServerConfig(
      serverUrl: _login,
      username: 'carol',
      userId: 'u1',
      accessToken: 'jf-token',
      alternateUrls: <String>[_wan, _tunnel],
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

  test('JellyfinApi 连不上抛 JellyfinTransportException（文案不变），401 仍是 '
      'JellyfinApiException', () async {
    final JellyfinApi down = JellyfinApi(
      serverUrl: _login,
      accessToken: 't',
      client: _fakeServers(const <String, _Answer>{}, <String>[]),
    );
    addTearDown(down.close);
    Object? error;
    try {
      await down.views('u1');
    } catch (e) {
      error = e;
    }
    expect(error, isA<JellyfinTransportException>());
    expect(isJellyfinTransportFailure(error!), isTrue);
    expect(error.toString(), startsWith('Exception: '));
    expect(
      isJellyfinTransportFailure(const JellyfinApiException(401, '/x')),
      isFalse,
    );
  });

  test('登录地址连不上、公网线路可达：切到公网，写回并失效清单缓存', () async {
    final JellyfinServerConfig config = _config();
    await repo.upsertMediaServer(config);
    final List<String> requested = <String>[];

    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const JellyfinTransportException('Connection refused'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, _Answer>{
        _wan: _Answer.ok,
        _tunnel: _Answer.ok,
      }, requested),
    );

    expect(rerouted, isA<JellyfinServerConfig>());
    expect(rerouted!.effectiveServerUrl, _wan);
    expect(rerouted.sourceId, config.sourceId);
    // 全部线路（含当前这条）一起探，取顺序最靠前的可达那条。
    expect(requested.toSet(), <String>{_login, _wan, _tunnel});
    final JellyfinServerConfig saved =
        (await repo.getMediaServers()).single as JellyfinServerConfig;
    expect(saved.effectiveServerUrl, _wan);
    expect(saved.accessToken, 'jf-token');
    expect(saved.alternateUrls, <String>[_wan, _tunnel]);
    expect(cache.invalidated, <String>[config.sourceId]);
  });

  test('在外面走公网、公网断了：按线路顺序切回登录地址', () async {
    final JellyfinServerConfig config = _config(active: _wan);
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const JellyfinTransportException('Connection reset'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, _Answer>{
        _login: _Answer.ok,
        _tunnel: _Answer.ok,
      }, <String>[]),
    );
    expect(rerouted?.effectiveServerUrl, _login);
  });

  test('可达的线路令牌不认（别家服务器 / 令牌过期）：不切过去', () async {
    final JellyfinServerConfig config = _config();
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const JellyfinTransportException('Connection refused'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, _Answer>{
        _wan: _Answer.unauthorized,
      }, <String>[]),
    );
    expect(rerouted, isNull);
    expect((await repo.getMediaServers()).single.effectiveServerUrl, _login);
    expect(cache.invalidated, isEmpty);
  });

  test('当前线路其实可达（刚才只是抖动 / 流断另有原因）：不切换、不写回', () async {
    final JellyfinServerConfig config = _config(active: _wan);
    await repo.upsertMediaServer(config);
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const JellyfinTransportException('Connection reset'),
      repo: repo,
      cache: cache,
      httpClientFactory: () => _fakeServers(const <String, _Answer>{
        _wan: _Answer.ok,
        _tunnel: _Answer.ok,
      }, <String>[]),
    );
    expect(rerouted, isNull);
    expect((await repo.getMediaServers()).single.effectiveServerUrl, _wan);
    expect(cache.invalidated, isEmpty);
  });

  test('服务器答了话（非 2xx）不探测、不切换', () async {
    final JellyfinServerConfig config = _config();
    await repo.upsertMediaServer(config);
    final List<String> requested = <String>[];
    final MediaServerConfig? rerouted = await rerouteMediaServerAfterFailure(
      config,
      const JellyfinApiException(404, '/Users/u1/Items/x'),
      repo: repo,
      cache: cache,
      httpClientFactory: () =>
          _fakeServers(const <String, _Answer>{_wan: _Answer.ok}, requested),
    );
    expect(rerouted, isNull);
    expect(requested, isEmpty);
  });
}
