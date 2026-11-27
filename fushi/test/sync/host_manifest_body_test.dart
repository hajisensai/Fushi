import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/collection_manifest.dart';
import 'package:fushi_engine/sync/collection_sync_engine.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_manifest_bodies.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/media_link_sync.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/tag_sync.dart';

/// BUG-5606：互联 host 的清单端点（合集 / 标签 / 作品图谱）在后台
/// isolate 里现算，合集清单按数据源表的写入作废缓存，GET 带强 ETag、`If-None-Match`
/// 命中回 304。
///
/// 端到端的合并语义（成员并集、墓碑防复活、手动序 LWW、稳态零 POST……）由
/// `fushi_library_collections_test.dart` 经真实 server + client 全链路钉住——那些用例
/// 现在走的就是这里的后台报文体路径。本文件钉新增的契约。
void main() {
  FushiDatabase memDb([QueryExecutor? executor]) {
    final FushiDatabase db = FushiDatabase.forTesting(
      executor ?? DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    return db;
  }

  LocalLibraryHostService buildSvc(FushiDatabase db) => LocalLibraryHostService(
    db: db,
    dictionaryResourceRoot: Directory.systemTemp,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
  );

  /// 让 drift 的表更新通知（异步广播）落地。
  Future<void> settle() async {
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('清单端点（后台报文体 + ETag）', () {
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    const String token = 'manifest-body-token';
    late HttpClient http;

    setUp(() async {
      hostDb = memDb();
      server = FushiSyncServer(
        syncDataDir: Directory.systemTemp.createTempSync('hbk_mbody_srv').path,
        port: 0,
        token: token,
        allowLan: false,
        libraryService: buildSvc(hostDb),
      );
      await server.start();
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await server.stop();
    });

    Future<({int status, Uint8List body, String? etag})> call(
      String method,
      String path, {
      String? ifNoneMatch,
      List<int>? body,
    }) async {
      final HttpClientRequest req = await http.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64.encode(utf8.encode('fushi:$token'))}',
      );
      if (ifNoneMatch != null) {
        req.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(body);
      }
      final HttpClientResponse res = await req.close();
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await res.forEach(bytes.add);
      return (
        status: res.statusCode,
        body: bytes.takeBytes(),
        etag: res.headers.value(HttpHeaders.etagHeader),
      );
    }

    test('合集 GET：报文体与 loadLocalCollectionManifest 字节相同，带 ETag；'
        'If-None-Match 命中回 304；数据变了换代回 200', () async {
      final int c = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(c, MediaKind.video, 'v1');

      final r1 = await call('GET', '/api/library/collections');
      expect(r1.status, 200);
      expect(
        utf8.decode(r1.body),
        (await loadLocalCollectionManifest(hostDb)).canonicalJson(),
      );
      expect(r1.etag, hostManifestEtag(r1.body));

      final r2 = await call(
        'GET',
        '/api/library/collections',
        ifNoneMatch: r1.etag,
      );
      expect(r2.status, 304);
      expect(r2.body, isEmpty);
      expect(r2.etag, r1.etag);

      await hostDb.addToCollection(c, MediaKind.video, 'v2');
      await settle();
      final r3 = await call(
        'GET',
        '/api/library/collections',
        ifNoneMatch: r1.etag,
      );
      expect(r3.status, 200, reason: '成员表写入必须让缓存作废');
      expect(r3.etag, isNot(r1.etag));
      expect(utf8.decode(r3.body), contains('v2'));
    });

    test('合集标签与成员墓碑的写入同样让合集清单缓存作废', () async {
      final int c = await hostDb.createMediaCollection(
        'S',
        collectionType: 'playlist',
      );
      await hostDb.addToCollection(c, MediaKind.video, 'v1');
      await hostDb.addToCollection(c, MediaKind.video, 'v2');
      final r1 = await call('GET', '/api/library/collections');

      await hostDb.addTagToCollection(
        c,
        await hostDb.createTag('追番', 0xFF000000),
      );
      await settle();
      final r2 = await call('GET', '/api/library/collections');
      expect(utf8.decode(r2.body), contains('追番'));
      expect(r2.etag, isNot(r1.etag));

      await hostDb.removeFromCollection(c, MediaKind.video, 'v2');
      await settle();
      final r3 = await call('GET', '/api/library/collections');
      final CollectionManifestEntry entry = CollectionManifest.fromJson(
        jsonDecode(utf8.decode(r3.body)),
      ).collections.single;
      expect(
        entry.memberTombstones.map((CollectionMemberTombstone t) => t.entryKey),
        <String>['v2'],
      );
    });

    test('合集 POST：并入后回合并清单；坏 JSON / 非法清单 400 且不写库', () async {
      final r1 = await call(
        'POST',
        '/api/library/collections',
        body: utf8.encode(
          const CollectionManifest(
            collections: <CollectionManifestEntry>[
              CollectionManifestEntry(
                name: 'T',
                collectionType: 'collection',
                members: <CollectionManifestMember>[
                  CollectionManifestMember(
                    mediaType: 'epub',
                    entryKey: 't1',
                    sortIndex: 0,
                  ),
                ],
              ),
            ],
          ).canonicalJson(),
        ),
      );
      expect(r1.status, 200);
      expect(
        await hostDb.getMediaCollectionByNaturalKey('T', 'collection'),
        isNotNull,
      );
      final CollectionManifest merged = CollectionManifest.fromJson(
        jsonDecode(utf8.decode(r1.body)),
      );
      expect(
        merged.collections.single.members.map(
          (CollectionManifestMember m) => m.entryKey,
        ),
        <String>['t1'],
        reason: '回的是合并后清单',
      );

      final r2 = await call(
        'POST',
        '/api/library/collections',
        body: utf8.encode('{not json'),
      );
      expect(r2.status, 400);
      expect(utf8.decode(r2.body), 'Invalid JSON');

      final r3 = await call(
        'POST',
        '/api/library/collections',
        body: utf8.encode('{"version": 999, "collections": []}'),
      );
      expect(r3.status, 400);
      expect(utf8.decode(r3.body), startsWith('Invalid manifest'));
      expect((await hostDb.getAllMediaCollections()).length, 1);
    });

    test('标签 / 作品图谱 GET 带 ETag 可 304，POST 照旧回并入后清单', () async {
      final r1 = await call('GET', '/api/library/tags');
      expect(r1.status, 200);
      expect(
        utf8.decode(r1.body),
        (await loadLocalTagManifest(hostDb)).canonicalJson(),
      );
      expect(
        (await call('GET', '/api/library/tags', ifNoneMatch: r1.etag)).status,
        304,
      );
      final r2 = await call('POST', '/api/library/tags', body: r1.body);
      expect(r2.status, 200);
      expect(r2.body, r1.body);

      final r3 = await call('GET', '/api/library/media-links');
      expect(r3.status, 200);
      expect(
        utf8.decode(r3.body),
        (await loadLocalMediaLinkManifest(hostDb)).canonicalJson(),
      );
      expect(
        (await call(
          'GET',
          '/api/library/media-links',
          ifNoneMatch: 'W/${r3.etag}',
        )).status,
        304,
        reason: '弱比较：W/ 前缀忽略',
      );
      expect(
        (await call(
          'POST',
          '/api/library/media-links',
          body: utf8.encode('[]'),
        )).status,
        400,
      );
    });
  });

  test('loadLocalCollectionManifest 读的每张表都在 collectionManifestSourceTables 里'
      '（缓存作废的表清单与 loader 同步）', () async {
    final _TableRecorder recorder = _TableRecorder();
    final FushiDatabase db = memDb(
      NativeDatabase.memory().interceptWith(recorder),
    );
    final int c = await db.createMediaCollection('S');
    await db.addToCollection(c, MediaKind.video, 'v1');
    await db.addTagToCollection(c, await db.createTag('t', 0));
    recorder.recording = true;
    await loadLocalCollectionManifest(db);
    recorder.recording = false;
    final Set<String> declared = <String>{
      for (final t in collectionManifestSourceTables(db)) t.actualTableName,
    };
    expect(recorder.tables, isNotEmpty);
    expect(
      recorder.tables.difference(declared),
      isEmpty,
      reason: 'loader 多读的表没登记：那张表变了，host 会继续交出旧清单',
    );
  });

  group('HostManifestBodyCache', () {
    HostManifestBody body(String s) => HostManifestBody(
      bytes: Uint8List.fromList(utf8.encode(s)),
      etag: hostManifestEtag(utf8.encode(s)),
    );

    test('命中不重算；并发读者共用一次重算；作废后退订并重算', () async {
      final StreamController<Object?> updates =
          StreamController<Object?>.broadcast();
      int computes = 0;
      final HostManifestBodyCache cache = HostManifestBodyCache(
        invalidations: () => updates.stream,
        compute: () async {
          computes++;
          await Future<void>.delayed(Duration.zero);
          return body('v$computes');
        },
      );
      final List<HostManifestBody> both = await Future.wait(
        <Future<HostManifestBody>>[cache.get(), cache.get()],
      );
      expect(computes, 1);
      expect(identical(both[0], both[1]), isTrue);
      expect(utf8.decode((await cache.get()).bytes), 'v1');
      expect(computes, 1);
      expect(updates.hasListener, isTrue);

      updates.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(updates.hasListener, isFalse, reason: '作废即退订');
      expect(utf8.decode((await cache.get()).bytes), 'v2');
      expect(computes, 2);
      await updates.close();
    });

    test('重算途中来了作废：结果交给这批读者，但不进缓存', () async {
      final StreamController<Object?> updates =
          StreamController<Object?>.broadcast();
      final Completer<void> gate = Completer<void>();
      int computes = 0;
      final HostManifestBodyCache cache = HostManifestBodyCache(
        invalidations: () => updates.stream,
        compute: () async {
          computes++;
          if (computes == 1) await gate.future;
          return body('v$computes');
        },
      );
      final Future<HostManifestBody> first = cache.get();
      await Future<void>.delayed(Duration.zero);
      updates.add(null);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect(utf8.decode((await first).bytes), 'v1');
      expect(utf8.decode((await cache.get()).bytes), 'v2');
      expect(computes, 2);
      await updates.close();
    });
  });

  test('ifNoneMatchHits：列表、W/ 前缀、* 都按 RFC 9110 弱比较', () {
    const String etag = '"abc"';
    expect(ifNoneMatchHits(null, etag), isFalse);
    expect(ifNoneMatchHits('', etag), isFalse);
    expect(ifNoneMatchHits('"abc"', etag), isTrue);
    expect(ifNoneMatchHits('W/"abc"', etag), isTrue);
    expect(ifNoneMatchHits('"x", "abc"', etag), isTrue);
    expect(ifNoneMatchHits('*', etag), isTrue);
    expect(ifNoneMatchHits('"abcd"', etag), isFalse);
  });
}

/// 录下 SELECT 语句里 FROM / JOIN 的表名。
class _TableRecorder extends QueryInterceptor {
  bool recording = false;
  final Set<String> tables = <String>{};
  final RegExp _from = RegExp(
    r'\b(?:FROM|JOIN)\s+"?([A-Za-z_][A-Za-z0-9_]*)"?',
    caseSensitive: false,
  );

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (recording) {
      for (final RegExpMatch m in _from.allMatches(statement)) {
        tables.add(m.group(1)!);
      }
    }
    return super.runSelect(executor, statement, args);
  }
}
