import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/downloads/download_execution_target.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:path/path.dart' as p;

class _DownloadHost implements HostDownloadHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'backend': 'embedded',
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 记录 [close] 次数的代下载 client（判自建 client 是否在交回前关掉）。
class _CountingClient extends InterconnectDownloadClient {
  _CountingClient({required super.repo});

  int closed = 0;

  @override
  void close() {
    closed++;
    super.close();
  }
}

/// 「下载执行设备」偏好按 URL 存。某个地址改归另一台 host 后，偏好若还指着它，
/// 就会把下载静默投给新 host——改写为旧 host 剩余的代表地址，没剩的就回本机。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });

  tearDown(() => db.close());

  const String moved = 'http://10.0.0.5:38765';

  test('偏好指向被改归的地址 → 改写为旧 host 剩余的代表地址', () async {
    await prefs.setDownloadExecutionHostUrl(moved);
    await reconcileDownloadExecutionHostAfterReassign(
      prefs,
      const <FushiClientUrl>[
        FushiClientUrl(url: moved, hostId: 'B'),
        FushiClientUrl(
          url: 'https://10.0.0.9:38765',
          hostId: 'A',
          learned: true,
        ),
        FushiClientUrl(url: 'https://a.example', hostId: 'A'),
      ],
      url: moved,
      previousHostId: 'A',
    );
    expect(prefs.downloadExecutionHostUrl, 'https://a.example');
  });

  test('旧 host 一条地址都不剩 → 清空（回本机）', () async {
    await prefs.setDownloadExecutionHostUrl(moved);
    await reconcileDownloadExecutionHostAfterReassign(
      prefs,
      const <FushiClientUrl>[FushiClientUrl(url: moved, hostId: 'B')],
      url: moved,
      previousHostId: 'A',
    );
    expect(prefs.downloadExecutionHostUrl, isEmpty);
  });

  test('偏好指向别的地址 → 不动', () async {
    await prefs.setDownloadExecutionHostUrl('https://a.example');
    await reconcileDownloadExecutionHostAfterReassign(
      prefs,
      const <FushiClientUrl>[FushiClientUrl(url: moved, hostId: 'B')],
      url: moved,
      previousHostId: 'A',
    );
    expect(prefs.downloadExecutionHostUrl, 'https://a.example');
  });

  group('resolveDownloadExecutionFor 带失败原因（R9）', () {
    late Directory tmp;
    late SyncRepository repo;
    late String url;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('fushi-dl-exec-');
      repo = SyncRepository(db);
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: p.join(tmp.path, 'sync'),
        port: 0,
        token: 'host-token',
        downloads: _DownloadHost(),
        deviceName: 'PC',
      )..hostId = 'H-exec';
      await server.start();
      addTearDown(server.stop);
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      url = 'http://127.0.0.1:${server.port}';
    });

    Future<void> pair(String token) => repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(
        url: url,
        deviceName: 'PC',
        hostId: 'H-exec',
        token: token,
      ),
    ]);

    test('配对凭据被 host 拒绝 → Unreachable(failure: authRejected)，'
        '自建 client 交回前已关闭', () async {
      await pair('stale-token');
      final List<_CountingClient> built = <_CountingClient>[];
      final DownloadExecutionResolution r = await resolveDownloadExecutionFor(
        url: url,
        repo: repo,
        createClient: (SyncRepository repo) {
          final _CountingClient c = _CountingClient(repo: repo);
          built.add(c);
          return c;
        },
      );
      expect(r, isA<DownloadExecutionUnreachable>());
      final DownloadExecutionUnreachable u = r as DownloadExecutionUnreachable;
      expect(u.failure, InterconnectHostFailure.authRejected);
      expect(u.label, 'PC');
      expect(built, hasLength(1));
      expect(built.single.closed, 1, reason: '走 Unreachable 前关掉自建 client');
    });

    test('凭据正确 → Remote，自建 client 归结果所有、release 时关', () async {
      await pair('host-token');
      final List<_CountingClient> built = <_CountingClient>[];
      final DownloadExecutionResolution r = await resolveDownloadExecutionFor(
        url: url,
        repo: repo,
        createClient: (SyncRepository repo) {
          final _CountingClient c = _CountingClient(repo: repo);
          built.add(c);
          return c;
        },
      );
      expect(r, isA<DownloadExecutionRemote>());
      expect(built.single.closed, 0);
      (r as DownloadExecutionRemote).release();
      expect(built.single.closed, 1);
    });

    test('调用方传入的 client 归调用方：Unreachable 时不关', () async {
      await pair('stale-token');
      final _CountingClient mine = _CountingClient(repo: repo);
      addTearDown(mine.close);
      final DownloadExecutionResolution r = await resolveDownloadExecutionFor(
        url: url,
        repo: repo,
        client: mine,
      );
      expect(
        (r as DownloadExecutionUnreachable).failure,
        InterconnectHostFailure.authRejected,
      );
      expect(mine.closed, 0);
    });
  });
}
