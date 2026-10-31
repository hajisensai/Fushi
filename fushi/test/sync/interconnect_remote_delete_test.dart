/// 反馈 R8duEiqRuy：库页上来自互联 host 的条目「同时从远端删除」——这里钉住它依赖的
/// 网络 / host 侧契约（UI 侧见 `test/pages/reader_remote_book_remove_test.dart`）。
///
/// 1. [InterconnectSyncBackend.probeHostReachability]：在线 / 离线 / 配对被拒三态，且
///    **不信**已解析的旧会话（对端在会话解析后才掉线也要判离线）——菜单项的可用性
///    就由它决定（所有者 2026-10-31：只在对端在线、可达时可用）。
/// 2. host 删除接口 `DELETE /api/library/books/<id>` 必须鉴权：没带配对凭据的请求
///    401，书和墓碑都不动。
/// 3. 删除走墓碑同步：client 经 [InterconnectSyncBackend.deleteRemoteBook] 删掉后，
///    host 写自己的同步删除墓碑，第三台设备经 `/api/tombstones` 拉得到——不是只删
///    host 上的文件。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart'
    show RemoteSourceReachability;
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 与生产默认探针同一做法（短超时 WebDAV 连接测试；401 → [SyncAuthError]，连不上 →
/// false），真打本地 server，不是恒 true 的假探针。
Future<bool> _realProbe(String url, String token) async {
  final WebDavOps ops = WebDavOps(
    baseUrl: WebDavOps.normalizeUrl(url),
    username: 'hibiki',
    password: token,
    connectionTimeout: InterconnectSyncBackend.probeTimeout,
    unauthorizedKind: SyncAuthFailureKind.pairingRejected,
  );
  try {
    await ops.testConnection().timeout(InterconnectSyncBackend.probeTimeout);
    return true;
  } on SyncAuthError {
    rethrow;
  } catch (_) {
    return false;
  } finally {
    ops.close(force: true);
  }
}

void main() {
  late Directory work;
  late FushiSyncServer server;
  late FushiDatabase hostDb;
  late String base;
  bool serverStopped = false;
  const String token = 'remote-delete-token';

  setUp(() async {
    serverStopped = false;
    work = await Directory.systemTemp.createTemp('remote_delete_');
    hostDb = _memDb();
    final LocalLibraryHostService libSvc = LocalLibraryHostService(
      db: hostDb,
      dictionaryResourceRoot: Directory(work.path),
      packages: SyncAssetPackageService(db: hostDb),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
    server = FushiSyncServer(
      syncDataDir: p.join(work.path, 'server_data'),
      port: 0,
      token: token,
      allowLan: false,
      libraryService: libSvc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    if (!serverStopped) await server.stop();
    await hostDb.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  /// 已配对 client 的互联后端（探针真打本地 server）。
  Future<InterconnectSyncBackend> pairedClient({
    String useToken = token,
    FushiProbe probe = _realProbe,
  }) async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(useToken);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      probe,
    );
    expect(await backend.restoreAuth(repo), isTrue);
    return backend;
  }

  Future<void> insertHostBook(String bookKey) async {
    final String extractDir = p.join(work.path, 'host_books', bookKey);
    Directory(extractDir).createSync(recursive: true);
    File(p.join(extractDir, 'chapter.xhtml')).writeAsStringSync('<p>x</p>');
    await hostDb.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Title $bookKey',
        epubPath: p.join(extractDir, 'original.epub'),
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ),
    );
  }

  Future<int> hostBookTombstones(String bookKey) async =>
      (await hostDb.getSyncDeletionTombstones())
          .where(
            (SyncDeletionTombstoneRow r) =>
                r.mediaType == SyncTombstoneKind.book.dbValue &&
                r.itemKey == bookKey,
          )
          .length;

  group('probeHostReachability', () {
    test('host 在线且接受凭据 → reachable', () async {
      final InterconnectSyncBackend client = await pairedClient();
      expect(
        await client.probeHostReachability(),
        RemoteSourceReachability.reachable,
      );
    });

    test('host 拒绝配对凭据 → credentialRejected（不是「离线」）', () async {
      final InterconnectSyncBackend client = await pairedClient(
        useToken: 'revoked-token',
      );
      expect(
        await client.probeHostReachability(),
        RemoteSourceReachability.credentialRejected,
      );
    });

    test('会话已解析后 host 才下线 → 重探判 unreachable，不信旧会话', () async {
      final InterconnectSyncBackend client = await pairedClient();
      // 先跑一次真实请求让会话「已解析」。
      expect(
        await client.probeHostReachability(),
        RemoteSourceReachability.reachable,
      );
      await server.stop();
      serverStopped = true;
      expect(
        await client.probeHostReachability(),
        RemoteSourceReachability.unreachable,
        reason: '菜单打开时必须重新探测：对端已离线却放行删除，用户确认后才收到失败',
      );
    });

    test('会话已解析：只原地复核已选地址，探测期间不置脏会话（并发请求不重跑选路）', () async {
      int probeCalls = 0;
      Completer<void>? gate;
      Future<bool> countingProbe(String url, String tok) async {
        probeCalls++;
        final Completer<void>? hold = gate;
        gate = null;
        if (hold != null) await hold.future;
        return _realProbe(url, tok);
      }

      final InterconnectSyncBackend client = await pairedClient(
        probe: countingProbe,
      );
      await client.ensureResolved();
      expect(probeCalls, 1);
      final String? resolvedBase = client.activeBaseUrl;

      // 菜单打开：复核卡在探针里的这段时间，别的操作照常发请求。
      final Completer<void> hold = Completer<void>();
      gate = hold;
      final Future<RemoteSourceReachability> probing = client
          .probeHostReachability();
      await Future<void>.delayed(Duration.zero);
      expect(probeCalls, 2, reason: '复核已选地址：发出一次探测');

      // 探测窗口里的并发请求不能被逼着重跑选路（旧实现先置脏会话，这里会再探一次）。
      await client.ensureResolved();
      expect(probeCalls, 2, reason: '会话没被置脏，并发请求直接沿用已解析地址');

      hold.complete();
      expect(await probing, RemoteSourceReachability.reachable);
      expect(probeCalls, 2);
      expect(client.activeBaseUrl, resolvedBase, reason: '地址没变，连接句柄原样保留');
    });
  });

  test('DELETE /api/library/books/<id> 必须鉴权：无凭据 401，书与墓碑都不动', () async {
    await insertHostBook('bk-auth');
    final HttpClient http = HttpClient();
    addTearDown(() => http.close(force: true));

    final HttpClientRequest anon = await http.deleteUrl(
      Uri.parse('$base/api/library/books/bk-auth'),
    );
    final HttpClientResponse anonRes = await anon.close();
    await anonRes.drain<void>();
    expect(anonRes.statusCode, 401);

    final HttpClientRequest wrong = await http.deleteUrl(
      Uri.parse('$base/api/library/books/bk-auth'),
    );
    wrong.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('hibiki:not-the-token'))}',
    );
    final HttpClientResponse wrongRes = await wrong.close();
    await wrongRes.drain<void>();
    expect(wrongRes.statusCode, 401);

    expect(await hostDb.getAllEpubBooks(), hasLength(1));
    expect(await hostBookTombstones('bk-auth'), 0);
  });

  test('client 从远端删除 → host 删行、写同步墓碑，第三台设备经 /api/tombstones 拉得到', () async {
    await insertHostBook('bk-del');
    final String extractDir = p.join(work.path, 'host_books', 'bk-del');
    final InterconnectSyncBackend client = await pairedClient();

    await client.deleteRemoteBook('bk-del');

    expect(await hostDb.getAllEpubBooks(), isEmpty);
    expect(Directory(extractDir).existsSync(), isFalse);
    expect(
      await hostBookTombstones('bk-del'),
      1,
      reason: '只删 host 文件不记墓碑，其它已下载这本书的设备永远不知道它被删了',
    );

    // 第三台设备（另一个已配对 peer）拉 host 墓碑清单。
    final List<({String mediaType, String itemKey, int deletedAt})>? pulled =
        await client.getRemoteDeletionTombstones();
    expect(pulled, isNotNull);
    expect(
      pulled!.where(
        (({String mediaType, String itemKey, int deletedAt}) r) =>
            r.mediaType == SyncTombstoneKind.book.dbValue &&
            r.itemKey == 'bk-del' &&
            r.deletedAt > 0,
      ),
      hasLength(1),
    );
  });
}
