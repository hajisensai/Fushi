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
/// isolate 里现算，合集清单按数据源表的写入作废缓存（下载任务 / 订阅表只在投影变了
/// 时作废），GET 带弱 ETag（gzip 与明文共用）、`If-None-Match` 弱比较命中回 304。
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

    Future<
      ({int status, Uint8List body, String? etag, String? vary, bool gzipped})
    >
    call(
      String method,
      String path, {
      String? ifNoneMatch,
      String? acceptEncoding,
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
      if (acceptEncoding != null) {
        req.headers.set(HttpHeaders.acceptEncodingHeader, acceptEncoding);
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
        vary: res.headers.value(HttpHeaders.varyHeader),
        gzipped:
            res.compressionState !=
            HttpClientResponseCompressionState.notCompressed,
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

    test('ETag 是弱的、gzip 与明文共用一个（RFC 9110 §8.8.3），声明 Vary；'
        '跨编码回传照样 304', () async {
      final int c = await hostDb.createMediaCollection('S');
      await hostDb.addToCollection(c, MediaKind.video, 'v1');

      final plain = await call(
        'GET',
        '/api/library/collections',
        acceptEncoding: 'identity',
      );
      final zipped = await call(
        'GET',
        '/api/library/collections',
        acceptEncoding: 'gzip',
      );
      expect(plain.gzipped, isFalse);
      expect(zipped.gzipped, isTrue);
      expect(plain.etag, startsWith('W/"'));
      expect(zipped.etag, plain.etag);
      expect(zipped.body, plain.body, reason: '解压后同一份清单');
      expect(plain.vary, 'Accept-Encoding');
      expect(zipped.vary, 'Accept-Encoding');

      expect(
        (await call(
          'GET',
          '/api/library/collections',
          acceptEncoding: 'identity',
          ifNoneMatch: zipped.etag,
        )).status,
        304,
      );
      // 不带 W/ 的同一串（弱比较忽略前缀）也命中；老 client 不发 If-None-Match
      // 照旧 200 全量（上面 plain / zipped 两次即是）。
      expect(
        (await call(
          'GET',
          '/api/library/collections',
          acceptEncoding: 'gzip',
          ifNoneMatch: plain.etag!.substring(2),
        )).status,
        304,
      );
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
          ifNoneMatch: r3.etag!.substring(2),
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

  test('loadLocalCollectionManifest 读的每张表都登记在 collectionManifestSourceTables '
      '或 collectionManifestProjectedTables 里（缓存作废的表清单与 loader 同步），'
      '且不读 galgames', () async {
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
      for (final t in collectionManifestProjectedTables(db)) t.actualTableName,
    };
    expect(declared, isNot(contains('galgames')));
    expect(recorder.tables, isNot(contains('galgames')));
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

    test('投影依赖：投影表写入不改投影就不重算；投影变了才重算', () async {
      final StreamController<Object?> updates =
          StreamController<Object?>.broadcast();
      final StreamController<Object?> projected =
          StreamController<Object?>.broadcast();
      String state = 'a';
      int computes = 0;
      int projections = 0;
      final HostManifestBodyCache cache = HostManifestBodyCache(
        invalidations: () => updates.stream,
        compute: () async {
          computes++;
          return body('v$computes:$state');
        },
        projectedUpdates: () => projected.stream,
        projection: () async {
          projections++;
          return state;
        },
      );
      final HostManifestBody b1 = await cache.get();
      expect(computes, 1);
      expect(identical(await cache.get(), b1), isTrue);
      expect(projections, 1, reason: '没有投影表写入时不必核对');

      projected.add(null); // 例如下载租约续期：投影不变
      await Future<void>.delayed(Duration.zero);
      expect(identical(await cache.get(), b1), isTrue);
      expect(computes, 1);
      expect(projections, 2);
      expect(identical(await cache.get(), b1), isTrue);
      expect(projections, 2, reason: '核对过就不再核对');

      state = 'b';
      projected.add(null); // 新下载任务挂到另一个合集：投影变了
      await Future<void>.delayed(Duration.zero);
      final HostManifestBody b2 = await cache.get();
      expect(computes, 2);
      expect(utf8.decode(b2.bytes), 'v2:b');
      expect(identical(await cache.get(), b2), isTrue);

      updates.add(null); // 主表写入照旧直接作废
      await Future<void>.delayed(Duration.zero);
      expect(utf8.decode((await cache.get()).bytes), 'v3:b');
      await updates.close();
      await projected.close();
    });

    test('投影依赖：读投影到重算结束之间来了投影表写入，结果不进缓存', () async {
      final StreamController<Object?> updates =
          StreamController<Object?>.broadcast();
      final StreamController<Object?> projected =
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
        projectedUpdates: () => projected.stream,
        projection: () async => 'same',
      );
      final Future<HostManifestBody> first = cache.get();
      await Future<void>.delayed(Duration.zero);
      // 投影可能先变后变回（ABA）：记下的投影不再能代表这次算出的报文体。
      projected.add(null);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      expect(utf8.decode((await first).bytes), 'v1');
      expect(utf8.decode((await cache.get()).bytes), 'v2');
      expect(computes, 2);
      await updates.close();
      await projected.close();
    });

    test('真库：下载任务的非合集列写入（租约续期）不作废合集清单缓存；'
        '任务挂到新合集才作废，且结果与 loader 逐字节相同', () async {
      final FushiDatabase db = memDb();
      final LocalLibraryHostService svc = buildSvc(db);
      final int c1 = await db.createMediaCollection('S1');
      final int c2 = await db.createMediaCollection('S2');
      await db.addToCollection(c1, MediaKind.video, 'v1');
      await db.addToCollection(c2, MediaKind.video, 'v2');
      VideoDownloadJobsCompanion job(String id, int collectionId) =>
          VideoDownloadJobsCompanion.insert(
            jobId: id,
            resourceProvider: 'nyaa',
            selectedResourceId: 'resource-$id',
            mediaKind: 'tv',
            title: 'Job $id',
            backendKind: 'embedded',
            fingerprint: 'embedded/default',
            collectionId: Value<int?>(collectionId),
            createdAt: 10,
            updatedAt: 10,
          );
      await db.into(db.videoDownloadJobs).insert(job('j1', c1));

      Future<String> fresh() async =>
          (await loadLocalCollectionManifest(db)).canonicalJson();

      final HostManifestBody b1 = await svc.getManifestBody(
        HostManifestKind.collections,
      );
      expect(utf8.decode(b1.bytes), await fresh());

      await (db.update(
        db.videoDownloadJobs,
      )..where(($VideoDownloadJobsTable t) => t.jobId.equals('j1'))).write(
        const VideoDownloadJobsCompanion(
          claimedBy: Value<String?>('worker'),
          claimExpiresAt: Value<int?>(120000),
          updatedAt: Value<int>(99),
        ),
      );
      await settle();
      final HostManifestBody b2 = await svc.getManifestBody(
        HostManifestKind.collections,
      );
      expect(identical(b2, b1), isTrue, reason: '投影没变，不重算');
      expect(utf8.decode(b2.bytes), await fresh());

      await db.into(db.videoDownloadJobs).insert(job('j2', c2));
      await settle();
      final HostManifestBody b3 = await svc.getManifestBody(
        HostManifestKind.collections,
      );
      expect(identical(b3, b1), isFalse);
      expect(b3.etag, isNot(b1.etag));
      expect(utf8.decode(b3.bytes), await fresh());
    });
  });

  test('ifNoneMatchHits：列表、W/ 前缀、* 都按 RFC 9110 弱比较', () {
    expect(hostManifestEtag(utf8.encode('{}')), matches(r'^W/"[0-9a-f]{32}"$'));
    expect(ifNoneMatchHits('W/"abc"', 'W/"abc"'), isTrue);
    expect(ifNoneMatchHits('"abc"', 'W/"abc"'), isTrue);
    expect(ifNoneMatchHits('W/"abd"', 'W/"abc"'), isFalse);
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
