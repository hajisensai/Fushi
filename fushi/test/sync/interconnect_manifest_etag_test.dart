import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/http_etag.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/media_link_sync.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/tag_sync.dart';

/// BUG-5606 审查第 8 条：client 的三条清单 GET（合集 / 标签 / 作品图谱）带
/// `If-None-Match`，host 回 304 时复用上一次解析出的清单（不下载、不解析）；老 host
/// 不带 ETag 时每次全量；配对身份变了不带旧 ETag；失败清缓存；并发请求合并。
void main() {
  FushiDatabase memDb() {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  Future<InterconnectSyncBackend> connect(
    SyncRepository repo,
    String base,
    String token,
  ) async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, enabled: true),
    ]);
    await repo.setFushiClientToken(token);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
      (String url, String tok) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    return backend;
  }

  group('真实 FushiSyncServer', () {
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    const String token = 'manifest-etag-token';

    setUp(() async {
      hostDb = memDb();
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_etag_srv').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: LocalLibraryHostService(
          db: hostDb,
          dictionaryResourceRoot: Directory.systemTemp,
          packages: SyncAssetPackageService(db: hostDb),
          refreshDictionaryCache: () async {},
          runExclusive: (Future<void> Function() body) => body(),
        ),
      );
      await server.start();
    });

    tearDown(() async => server.stop());

    test('合集：没变 → 304 复用同一对象（不可变）；host 改了 → 200 新清单', () async {
      final int cid = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(cid, MediaKind.video, 'v1');
      final InterconnectSyncBackend backend = await connect(
        SyncRepository(memDb()),
        'http://127.0.0.1:${server.port}',
        token,
      );

      final CollectionManifest first = (await backend
          .getRemoteCollectionManifest())!;
      final CollectionManifest second = (await backend
          .getRemoteCollectionManifest())!;
      expect(identical(second, first), isTrue, reason: '304 复用已解析结果');
      // 调用方改不动缓存的那份：下一次 304 拿到的仍是原样。
      expect(
        () => second.collections.add(
          const CollectionManifestEntry(name: 'x', collectionType: 'playlist'),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => second.collections.first.members.clear(),
        throwsUnsupportedError,
      );

      await hostDb.addToCollection(cid, MediaKind.video, 'v2');
      final CollectionManifest third = (await backend
          .getRemoteCollectionManifest())!;
      expect(identical(third, first), isFalse);
      expect(
        third.collections
            .firstWhere((CollectionManifestEntry e) => e.name == 'S')
            .members
            .map((CollectionManifestMember m) => m.entryKey),
        <String>['v1', 'v2'],
      );
      final CollectionManifest fourth = (await backend
          .getRemoteCollectionManifest())!;
      expect(identical(fourth, third), isTrue, reason: '200 已更新缓存');
    });

    test('标签 / 作品图谱：同样 304 复用', () async {
      final InterconnectSyncBackend backend = await connect(
        SyncRepository(memDb()),
        'http://127.0.0.1:${server.port}',
        token,
      );
      final TagManifest tags = (await backend.getRemoteTagManifest())!;
      expect(identical(await backend.getRemoteTagManifest(), tags), isTrue);
      final MediaLinkManifest links = (await backend
          .getRemoteMediaLinkManifest())!;
      expect(
        identical(await backend.getRemoteMediaLinkManifest(), links),
        isTrue,
      );
    });
  });

  group('假 host（看请求头）', () {
    final List<HttpServer> servers = <HttpServer>[];
    tearDown(() async {
      for (final HttpServer s in servers) {
        await s.close(force: true);
      }
      servers.clear();
    });

    const String path = '/api/library/collections';
    final String body = const CollectionManifest().canonicalJson();
    final String etag = weakContentEtag(utf8.encode(body));

    /// 起一台假 host：清单路由按 [mode] 应答，记下每次请求的 `If-None-Match`
    /// （没带记 null）。其余路由 404。
    Future<(String base, List<String?> seen)> fakeHost(
      Future<void> Function(HttpRequest req, int n) respond,
    ) async {
      final HttpServer s = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      servers.add(s);
      final List<String?> seen = <String?>[];
      s.listen((HttpRequest req) async {
        if (req.uri.path != path) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        seen.add(req.headers.value(HttpHeaders.ifNoneMatchHeader));
        await respond(req, seen.length);
        await req.response.close();
      });
      return ('http://127.0.0.1:${s.port}', seen);
    }

    Future<void> etagHost(HttpRequest req, int n) async {
      req.response.headers.set(HttpHeaders.etagHeader, etag);
      if (ifNoneMatchHits(
        req.headers.value(HttpHeaders.ifNoneMatchHeader),
        etag,
      )) {
        req.response.statusCode = 304;
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
    }

    test('带 ETag 的 host：第二次带 If-None-Match，304 复用', () async {
      final (String base, List<String?> seen) = await fakeHost(etagHost);
      final InterconnectSyncBackend backend = await connect(
        SyncRepository(memDb()),
        base,
        't',
      );
      final CollectionManifest? a = await backend.getRemoteCollectionManifest();
      final CollectionManifest? b = await backend.getRemoteCollectionManifest();
      expect(seen, <String?>[null, etag]);
      expect(identical(a, b), isTrue);
    });

    test('老 host（不带 ETag）：每次全量、从不带 If-None-Match', () async {
      final (String base, List<String?> seen) = await fakeHost((
        HttpRequest req,
        int n,
      ) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(body);
      });
      final InterconnectSyncBackend backend = await connect(
        SyncRepository(memDb()),
        base,
        't',
      );
      final CollectionManifest? a = await backend.getRemoteCollectionManifest();
      final CollectionManifest? b = await backend.getRemoteCollectionManifest();
      expect(seen, <String?>[null, null]);
      expect(identical(a, b), isFalse);
    });

    test('换了 host（重新配对）：不带旧 ETag', () async {
      final (String baseA, List<String?> seenA) = await fakeHost(etagHost);
      final (String baseB, List<String?> seenB) = await fakeHost(etagHost);
      final SyncRepository repo = SyncRepository(memDb());
      final InterconnectSyncBackend backend = await connect(repo, baseA, 't');
      await backend.getRemoteCollectionManifest();
      await backend.getRemoteCollectionManifest();
      expect(seenA, <String?>[null, etag]);

      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: baseB, enabled: true),
      ]);
      await backend.restoreAuth(repo);
      await backend.getRemoteCollectionManifest();
      await backend.getRemoteCollectionManifest();
      expect(seenB, <String?>[null, etag]);
    });

    test('失败清缓存：500 之后下一次不带 If-None-Match', () async {
      final (String base, List<String?> seen) = await fakeHost((
        HttpRequest req,
        int n,
      ) async {
        if (n == 2) {
          req.response.statusCode = 500;
          return;
        }
        await etagHost(req, n);
      });
      final InterconnectSyncBackend backend = await connect(
        SyncRepository(memDb()),
        base,
        't',
      );
      await backend.getRemoteCollectionManifest();
      await expectLater(
        backend.getRemoteCollectionManifest(),
        throwsA(isA<Object>()),
      );
      await backend.getRemoteCollectionManifest();
      expect(seen, <String?>[null, etag, null]);
    });

    test('并发请求合并成一次', () async {
      final Completer<void> gate = Completer<void>();
      final (String base, List<String?> seen) = await fakeHost((
        HttpRequest req,
        int n,
      ) async {
        await gate.future;
        await etagHost(req, n);
      });
      final InterconnectSyncBackend backend = await connect(
        SyncRepository(memDb()),
        base,
        't',
      );
      final Future<CollectionManifest?> a = backend
          .getRemoteCollectionManifest();
      final Future<CollectionManifest?> b = backend
          .getRemoteCollectionManifest();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.complete();
      final List<CollectionManifest?> both = await Future.wait(
        <Future<CollectionManifest?>>[a, b],
      );
      expect(seen, <String?>[null]);
      expect(identical(both[0], both[1]), isTrue);
    });
  });
}
