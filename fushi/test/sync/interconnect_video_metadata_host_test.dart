import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_wire.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/video_metadata_manifest.dart';
import 'package:path/path.dart' as p;

/// 互联视频刮削元数据 host 端（7c 列出 / 7a 无刮削链降级 / 7b 回写与覆盖保护），
/// 走真 HTTP + 真 `LocalLibraryHostService` + 内存 DB。
/// `docs/specs/2026-09-12-interconnect-scrape-metadata.md`。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late FushiSyncServer server;
  late String base;
  late MediaCollectionRow collection;
  late VideoSourceScrapeWork localWork;
  const String token = 'test-token-meta';
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  Future<({int status, Object? json})> call(
    String method,
    String path, {
    Object? body,
  }) async {
    final HttpClient c = HttpClient();
    try {
      final HttpClientRequest req =
          await c.openUrl(method, Uri.parse('$base$path'));
      req.headers.set('authorization', authHeader());
      if (body != null) {
        req.headers.set('content-type', 'application/json; charset=utf-8');
        req.add(utf8.encode(jsonEncode(body)));
      }
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      // 400 的 body 是纯文本错误说明，不是 JSON。
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        json = text;
      }
      return (status: res.statusCode, json: json);
    } finally {
      c.close();
    }
  }

  VideoMetadataWork work({
    String title = 'Show',
    String plot = 'plot',
    String externalId = '100',
    VideoMetadataProviderKind provider = VideoMetadataProviderKind.mal,
  }) =>
      VideoMetadataWork(
        provider: provider,
        kind: VideoMetadataMediaKind.tv,
        title: title,
        plot: plot,
        year: 2020,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: provider.name, value: externalId),
        ],
      );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hbk_meta_host');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Shows',
        mediaKind: 'video',
        rootPath: 'D:/Shows',
        createdAt: 1,
      ),
    );
    final List<VideoBookRow> members = <VideoBookRow>[];
    for (final String stem in <String>['Show S01E01', 'Show S01E02']) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(stem),
        title: Value<String>(stem),
        videoPath: Value<String>('D:/Shows/Show/$stem.mkv'),
        sourceId: Value<int?>(sourceId),
      ));
      members.add((await db.getVideoBookByBookUid(stem))!);
    }
    final int collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    for (final VideoBookRow m in members) {
      await db.addToCollection(collectionId, MediaKind.video, m.bookUid);
    }
    collection = (await db.getMediaCollectionById(collectionId))!;
    localWork = VideoSourceScrapeWork(
      source: (await db.getMediaSourceById(sourceId))!,
      collection: collection,
      title: collection.name,
      members: members,
    );
    final Directory dictRoot = Directory(p.join(tmp.path, 'dicts'))
      ..createSync(recursive: true);
    server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        // 无刮削控制器：7a 端点必须降级而不是 500。
        scrapeController: () async => null,
      ),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('capabilities.liveLibrary.videoMetadata == true', () async {
    final ({int status, Object? json}) res =
        await call('GET', '/api/capabilities');
    expect(res.status, 200);
    final Map<dynamic, dynamic> live =
        (res.json as Map<dynamic, dynamic>)['liveLibrary'] as Map;
    expect(live['videoMetadata'], true);
  });

  test('7c GET /api/library/metadata 列出 host 作品（自然键 + 模型 + 主身份）', () async {
    final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
    await store.apply(localWork, work(plot: 'from host'));

    final ({int status, Object? json}) res =
        await call('GET', '/api/library/metadata');
    expect(res.status, 200);
    final List<Object?> works =
        (res.json as Map<dynamic, dynamic>)['works'] as List<Object?>;
    expect(works, hasLength(1));
    final VideoMetadataWorkEntry entry =
        VideoMetadataWorkEntry.fromJson(works.single);
    expect(entry.key.isCollection, isTrue);
    expect(entry.key.collectionName, 'Show');
    expect(entry.key.collectionType, 'playlist');
    expect(entry.work.plot, 'from host');
    expect(entry.lookup?.provider, VideoMetadataProviderKind.mal);
    expect(entry.lookup?.externalId, '100');
    expect(entry.updatedAt, greaterThan(0));

    // since 过滤：晚于 updatedAt 的 since 什么都不回。
    final ({int status, Object? json}) later = await call(
      'GET',
      '/api/library/metadata?since=${entry.updatedAt}',
    );
    expect(
      ((later.json as Map<dynamic, dynamic>)['works'] as List<Object?>),
      isEmpty,
    );
  });

  test('7a 无刮削控制器：candidates 回空、scrape 回 409 notPlanned', () async {
    final Map<String, Object?> key = const VideoMetadataWorkKey.collection(
      name: 'Show',
      collectionType: 'playlist',
    ).toJson();
    final ({int status, Object? json}) cands = await call(
      'POST',
      '/api/library/metadata/candidates',
      body: <String, Object?>{'key': key, 'query': 'Show'},
    );
    expect(cands.status, 200);
    expect(
      (cands.json as Map<dynamic, dynamic>)['candidates'],
      isEmpty,
    );
    final ({int status, Object? json}) scrape = await call(
      'POST',
      '/api/library/metadata/scrape',
      body: <String, Object?>{
        'key': key,
        'lookup': encodeVideoMetadataLookup(const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '100',
          mediaKind: VideoMetadataMediaKind.tv,
        )),
      },
    );
    expect(scrape.status, 409);
    expect(
      VideoMetadataWriteResult.fromJson(scrape.json).conflict,
      VideoMetadataConflict.notPlanned,
    );
  });

  test('7b PUT 落库；host 已绑不同身份时 409 identity，replaceIdentity 才换', () async {
    final Map<String, Object?> key = const VideoMetadataWorkKey.collection(
      name: 'Show',
      collectionType: 'playlist',
    ).toJson();
    Map<String, Object?> body(String externalId, {bool replace = false}) =>
        <String, Object?>{
          'key': key,
          'lookup': encodeVideoMetadataLookup(VideoMetadataLookup(
            provider: VideoMetadataProviderKind.mal,
            externalId: externalId,
            mediaKind: VideoMetadataMediaKind.tv,
          )),
          'work': encodeVideoMetadataWork(
            work(plot: 'from client $externalId', externalId: externalId),
          ),
          'replaceIdentity': replace,
        };

    final ({int status, Object? json}) first =
        await call('PUT', '/api/library/metadata', body: body('100'));
    expect(first.status, 200);
    final VideoMetadataWorkRow row =
        (await db.getVideoMetadataWorkByCollection(collection.id))!;
    expect(row.overview, 'from client 100');

    // 同身份重写：不冲突。
    final ({int status, Object? json}) same =
        await call('PUT', '/api/library/metadata', body: body('100'));
    expect(same.status, 200);

    // 换身份且未显式确认：409 + 现身份。
    final ({int status, Object? json}) conflict =
        await call('PUT', '/api/library/metadata', body: body('200'));
    expect(conflict.status, 409);
    final VideoMetadataWriteResult result =
        VideoMetadataWriteResult.fromJson(conflict.json);
    expect(result.conflict, VideoMetadataConflict.identity);
    expect(result.currentLookup?.externalId, '100');
    expect(
      (await db.getVideoMetadataWorkByCollection(collection.id))!.overview,
      'from client 100',
      reason: '被拒的写入不得动库',
    );

    // 显式替换。
    final ({int status, Object? json}) replaced = await call(
      'PUT',
      '/api/library/metadata',
      body: body('200', replace: true),
    );
    expect(replaced.status, 200);
    expect(
      (await db.getVideoMetadataWorkByCollection(collection.id))!.overview,
      'from client 200',
    );
    final VideoMetadataWorkEntry entry = VideoMetadataWriteResult.fromJson(
      replaced.json,
    ).entry!;
    expect(entry.lookup?.externalId, '200');
  });

  test('7b PUT 尊重 host 字段锁（锁住的 overview 保留旧值）', () async {
    final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
    final PersistedVideoMetadata persisted =
        await store.apply(localWork, work(plot: 'host locked'));
    await db.setVideoMetadataWorkLockedFields(
      persisted.workId,
      encodeLockedFields(<VideoMetadataLockableField>{
        VideoMetadataLockableField.overview,
      }),
    );
    final ({int status, Object? json}) res = await call(
      'PUT',
      '/api/library/metadata',
      body: <String, Object?>{
        'key': const VideoMetadataWorkKey.collection(
          name: 'Show',
          collectionType: 'playlist',
        ).toJson(),
        'lookup': encodeVideoMetadataLookup(const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '100',
          mediaKind: VideoMetadataMediaKind.tv,
        )),
        'work': encodeVideoMetadataWork(
          work(title: 'Show (client)', plot: 'client overwrite'),
        ),
      },
    );
    expect(res.status, 200);
    final VideoMetadataWorkRow row =
        (await db.getVideoMetadataWorkByCollection(collection.id))!;
    expect(row.overview, 'host locked', reason: '锁住的字段不被客户端覆盖');
    expect(row.title, 'Show (client)', reason: '未锁字段照常更新');
    expect(
      VideoMetadataWriteResult.fromJson(res.json).entry!.lockedFields,
      <String>['overview'],
    );
  });

  // 审查 PR#1431 #2：合集在计划器里是 N 个成员级作品（无集号的电影合集）时，
  // 7b 不得按合集单元 apply——那会新建合集级作品并物理删掉全部成员作品行。
  test('7b PUT 到多作品单元的合集 → 409 ambiguousWork，成员作品行一条不少', () async {
    final int sourceId = (await db.getMediaSourcesByKind('video')).single.id;
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final List<VideoBookRow> films = <VideoBookRow>[];
    for (final String stem in <String>['Movie A', 'Movie B']) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(stem),
        title: Value<String>(stem),
        videoPath: Value<String>('D:/Shows/Films/$stem.mkv'),
        sourceId: Value<int?>(sourceId),
      ));
      films.add((await db.getVideoBookByBookUid(stem))!);
    }
    final int filmsId =
        await db.createMediaCollection('Films', collectionType: 'collection');
    for (final VideoBookRow m in films) {
      await db.addToCollection(filmsId, MediaKind.video, m.bookUid);
    }
    final VideoMetadataDatabaseStore store = VideoMetadataDatabaseStore(db);
    for (final VideoBookRow m in films) {
      await store.apply(
        VideoSourceScrapeWork(
          source: source,
          title: m.title,
          members: <VideoBookRow>[m],
        ),
        work(title: m.title, externalId: m.bookUid.hashCode.toString())
            .copyWith(kind: VideoMetadataMediaKind.movie),
      );
    }
    expect(await db.getVideoMetadataWorkByBook('Movie A'), isNotNull);

    final ({int status, Object? json}) res = await call(
      'PUT',
      '/api/library/metadata',
      body: <String, Object?>{
        'key': const VideoMetadataWorkKey.collection(
          name: 'Films',
          collectionType: 'collection',
        ).toJson(),
        'lookup': encodeVideoMetadataLookup(const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '9',
          mediaKind: VideoMetadataMediaKind.movie,
        )),
        'work': encodeVideoMetadataWork(work(title: 'Films', externalId: '9')),
      },
    );
    expect(res.status, 409);
    final VideoMetadataWriteResult result =
        VideoMetadataWriteResult.fromJson(res.json);
    expect(result.conflict, VideoMetadataConflict.ambiguousWork);
    expect(
      result.ambiguousWorks.map((VideoMetadataWorkKey k) => k.bookUid),
      unorderedEquals(<String>['Movie A', 'Movie B']),
    );
    expect(await db.getVideoMetadataWorkByBook('Movie A'), isNotNull,
        reason: '成员作品行不得被合集级 apply 删掉');
    expect(await db.getVideoMetadataWorkByBook('Movie B'), isNotNull);
    expect(await db.getVideoMetadataWorkByCollection(filmsId), isNull);

    // 客户端按 ambiguousWorks 用 bookUid 重发 → 只动那一部。
    final ({int status, Object? json}) one = await call(
      'PUT',
      '/api/library/metadata',
      body: <String, Object?>{
        'key': const VideoMetadataWorkKey.book('Movie A').toJson(),
        'lookup': encodeVideoMetadataLookup(const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '9',
          mediaKind: VideoMetadataMediaKind.movie,
        )),
        'work': encodeVideoMetadataWork(
          work(title: 'Movie A', plot: 'client', externalId: '9')
              .copyWith(kind: VideoMetadataMediaKind.movie),
        ),
        'replaceIdentity': true,
      },
    );
    expect(one.status, 200);
    expect(
        (await db.getVideoMetadataWorkByBook('Movie A'))!.overview, 'client');
    expect((await db.getVideoMetadataWorkByBook('Movie B'))!.overview, 'plot');
  });

  test('坏请求：缺 key / 缺 lookup → 400；未知作品 → 409 notPlanned', () async {
    expect(
      (await call('PUT', '/api/library/metadata', body: <String, Object?>{}))
          .status,
      400,
    );
    final ({int status, Object? json}) unknown = await call(
      'PUT',
      '/api/library/metadata',
      body: <String, Object?>{
        'key': const VideoMetadataWorkKey.book('nope').toJson(),
        'lookup': encodeVideoMetadataLookup(const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '1',
          mediaKind: VideoMetadataMediaKind.tv,
        )),
        'work': encodeVideoMetadataWork(work()),
      },
    );
    expect(unknown.status, 409);
    expect(
      VideoMetadataWriteResult.fromJson(unknown.json).conflict,
      VideoMetadataConflict.notPlanned,
    );
  });
}
