import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/interconnect_sync_backend.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// `InterconnectSyncBackend._listRemote` 的**降级边界**守卫（TODO-2120）。
///
/// 五个域的列清单骨架收敛成一份泛型 `_listRemote` 之后，`degradeOn404` 与 `timeout`
/// 变成了两个可选形参。省事地给所有域统一打开降级，是这次收敛最容易犯、也最难发现
/// 的错误——它把「host 把库服务关了」（404 Library service off）从一个**可见错误**
/// 变成**静默空列表**：用户看到的是「对端一本书都没有」，而不是「连不上」。
///
/// 所以这里锁的是逐域的降级口径，而不是「能列出清单」：
/// - 词典 / 书 / 本地音频 / 有声书是最老的端点，假定必然存在 → 404 必须**抛**。
/// - videos 是后加的端点，老 host 根本没有 → 404 **降级**成空表，不崩不转圈。
///
/// 少了这条，给 `listRemoteBooks()` 补一个 `degradeOn404: true` 全套测试照绿。
void main() {
  late HttpServer server;
  late String base;
  const String token = 'degradation-token';
  final List<String> hitPaths = <String>[];

  setUp(() async {
    hitPaths.clear();
    // 一台「认证通过、但所有库端点都 404」的 host——等价于对端把库服务关了，
    // 或者对端是个还没有该端点的老版本。
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((HttpRequest req) async {
      hitPaths.add(req.uri.path);
      if (req.uri.path == '/api/ping' || req.uri.path == '/api/capabilities') {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(<String, Object?>{'ok': true}));
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 404
        ..write('Library service off');
      await req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  Future<InterconnectSyncBackend> buildBackend() async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    addTearDown(() async => db.close());
    final SyncRepository repo = SyncRepository(db);
    await repo.setHibikiClientUrls(<HibikiClientUrl>[
      HibikiClientUrl(url: base, enabled: true),
    ]);
    await repo.setHibikiClientToken(token);
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String u, String t) async => true);
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    return backend;
  }

  test('四个老域：404 必须抛错，绝不静默降级成空表', () async {
    final InterconnectSyncBackend backend = await buildBackend();

    final Map<String, Future<List<Object?>> Function()> oldDomains =
        <String, Future<List<Object?>> Function()>{
      '/api/library/dictionaries': backend.listRemoteDictionaries,
      '/api/library/books': backend.listRemoteBooks,
      '/api/library/localaudio': backend.listRemoteLocalAudio,
      '/api/library/audiobooks': backend.listRemoteAudiobooks,
    };

    for (final MapEntry<String, Future<List<Object?>> Function()> e
        in oldDomains.entries) {
      await expectLater(
        e.value(),
        throwsA(isA<SyncBackendError>()),
        reason: '${e.key} 是最老的端点：404 意味着 host 把库服务关了，'
            '必须作为可见错误抛出，不能降级成空表',
      );
      expect(hitPaths, contains(e.key), reason: '必须真的打过 ${e.key}，不能没发请求就抛');
    }
  });

  test('videos：404 降级成空表（老 host 无此端点，不崩不转圈）', () async {
    final InterconnectSyncBackend backend = await buildBackend();

    final List<RemoteVideoInfo> videos = await backend.listRemoteVideos();

    expect(videos, isEmpty, reason: 'videos 是后加的端点，老 host 没有它——降级空表是刻意设计');
    expect(hitPaths, contains('/api/library/videos'));
  });
}
