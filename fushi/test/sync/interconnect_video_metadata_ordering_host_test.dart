import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_locked_fields.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/video_metadata_manifest.dart';
import 'package:path/path.dart' as p;

/// 互联 host 端「TMDB 备选排序」（Shoko `PreferredAlternateOrderingID` 的互联面）：
/// `POST /api/library/metadata/episode-groups` 列分组 + 当前选定，
/// `POST /api/library/metadata/episode-group` 由 host 写行 + 上锁 + 按分组重刮。
/// 真 HTTP + 真 `LocalLibraryHostService` + 内存 DB + 假刮削 runner。
class _OrderingRunner
    implements
        VideoSourceScrapeRunner,
        VideoSourceScrapeManualBinding,
        VideoSourceScrapeEpisodeOrdering {
  final List<VideoMetadataLookup> listed = <VideoMetadataLookup>[];
  final List<VideoMetadataLookup> rescraped = <VideoMetadataLookup>[];
  List<VideoMetadataEpisodeGroupSummary> groups =
      const <VideoMetadataEpisodeGroupSummary>[];

  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async => SourceScrapeReport(sourceIds: <int>[source.id]);

  @override
  Future<List<VideoSourceScrapeConfirmationCandidate>> searchManualCandidates({
    SourceLibraryRow? source,
    required String workTitle,
    String? workStableKey,
    required String query,
  }) async => const <VideoSourceScrapeConfirmationCandidate>[];

  @override
  Future<VideoMetadataWork?> fetchWorkForLookup(VideoMetadataLookup lookup) =>
      Future<VideoMetadataWork?>.value(null);

  @override
  Future<SourceScrapeReport> rescrapeWorkWithLookup({
    required SourceLibraryRow source,
    required String workTitle,
    String? workStableKey,
    required VideoMetadataLookup lookup,
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
  }) async {
    rescraped.add(lookup);
    return SourceScrapeReport(
      sourceIds: <int>[source.id],
      totalWorks: 1,
      succeededWorks: 1,
    );
  }

  @override
  Future<List<VideoMetadataEpisodeGroupSummary>> listEpisodeGroups(
    VideoMetadataLookup lookup,
  ) async {
    listed.add(lookup);
    return groups;
  }
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late FushiSyncServer server;
  late String base;
  late MediaCollectionRow collection;
  late VideoSourceScrapeWork localWork;
  late _OrderingRunner runner;
  late VideoSourceScrapeTaskController controller;
  const String token = 'test-token-ordering';
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  Future<({int status, Object? json})> post(
    String path,
    Map<String, Object?> body,
  ) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.openUrl(
        'POST',
        Uri.parse('$base$path'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, authHeader());
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      Object? decoded;
      try {
        decoded = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        decoded = text;
      }
      return (status: res.statusCode, json: decoded);
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> key() => VideoMetadataWorkKey.collection(
    name: collection.name,
    collectionType: collection.collectionType,
  ).toJson();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hbk_meta_ordering');
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
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(stem),
          title: Value<String>(stem),
          videoPath: Value<String>('D:/Shows/Show/$stem.mkv'),
          sourceId: Value<int?>(sourceId),
        ),
      );
      members.add((await db.getVideoBookByBookUid(stem))!);
    }
    final int collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
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
    runner = _OrderingRunner();
    controller = VideoSourceScrapeTaskController(runner);
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
        scrapeController: () async => controller,
      ),
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    controller.dispose();
    await db.close();
  });

  VideoMetadataWork tmdbShow() => VideoMetadataWork(
    provider: VideoMetadataProviderKind.tmdb,
    kind: VideoMetadataMediaKind.tv,
    title: 'Show',
    ids: <VideoMetadataId>[VideoMetadataId(type: 'tmdb', value: '65942')],
  );

  test('capabilities.liveLibrary.videoMetadataOrdering == true', () async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.openUrl(
        'GET',
        Uri.parse('$base/api/capabilities'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, authHeader());
      final HttpClientResponse res = await req.close();
      final Map<dynamic, dynamic> json =
          jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect((json['liveLibrary'] as Map)['videoMetadataOrdering'], true);
    } finally {
      client.close(force: true);
    }
  });

  test('episode-groups lists host groups + current; episode-group sets, locks '
      'and rescrapes with the grouped lookup', () async {
    await VideoMetadataDatabaseStore(db).apply(localWork, tmdbShow());
    runner.groups = const <VideoMetadataEpisodeGroupSummary>[
      VideoMetadataEpisodeGroupSummary(
        id: 'seasons',
        name: 'Seasons',
        type: 6,
        groupCount: 3,
      ),
    ];

    final ({int status, Object? json}) listed = await post(
      '/api/library/metadata/episode-groups',
      {'key': key()},
    );
    expect(listed.status, 200);
    final VideoMetadataEpisodeGroupListing listing =
        VideoMetadataEpisodeGroupListing.fromJson(listed.json);
    expect(listing.groups.map((g) => g.id), <String>['seasons']);
    expect(listing.groups.single.groupCount, 3);
    expect(listing.current, isNull);
    expect(runner.listed.single.externalId, '65942');
    expect(
      runner.listed.single.episodeGroupId,
      isNull,
      reason: '列分组用的是不带分组的剧 lookup',
    );

    final ({int status, Object? json}) set = await post(
      '/api/library/metadata/episode-group',
      {'key': key(), 'groupId': 'seasons'},
    );
    expect(set.status, 200, reason: '${set.json}');
    final VideoMetadataWriteResult result = VideoMetadataWriteResult.fromJson(
      set.json,
    );
    expect(result.isOk, isTrue);
    expect(result.entry?.work.episodeGroupId, 'seasons');
    expect(result.entry?.lockedFields, contains('episodeGroup'));
    final VideoMetadataWorkRow row = (await db.getVideoMetadataWorkByCollection(
      collection.id,
    ))!;
    expect(row.episodeGroupId, 'seasons');
    expect(
      parseLockedFields(row.lockedFields),
      contains(VideoMetadataLockableField.episodeGroup),
    );
    expect(runner.rescraped.single.episodeGroupId, 'seasons');
    expect(runner.rescraped.single.externalId, '65942');

    // 再列：current 跟着行走；选回默认写 null。
    final ({int status, Object? json}) again = await post(
      '/api/library/metadata/episode-groups',
      {'key': key()},
    );
    expect(
      VideoMetadataEpisodeGroupListing.fromJson(again.json).current,
      'seasons',
    );
    final ({int status, Object? json}) reset = await post(
      '/api/library/metadata/episode-group',
      {'key': key(), 'groupId': null},
    );
    expect(reset.status, 200);
    expect(
      (await db.getVideoMetadataWorkByCollection(
        collection.id,
      ))!.episodeGroupId,
      isNull,
    );
  });

  test('works without a TMDB show identity list no groups; unknown key → '
      '409 notPlanned on set', () async {
    await VideoMetadataDatabaseStore(db).apply(
      localWork,
      VideoMetadataWork(
        provider: VideoMetadataProviderKind.mal,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show',
        ids: <VideoMetadataId>[VideoMetadataId(type: 'mal', value: '100')],
      ),
    );
    final ({int status, Object? json}) listed = await post(
      '/api/library/metadata/episode-groups',
      {'key': key()},
    );
    expect(listed.status, 200);
    expect(
      VideoMetadataEpisodeGroupListing.fromJson(listed.json).groups,
      isEmpty,
    );
    expect(runner.listed, isEmpty, reason: '没有 TMDB 身份不问 provider');

    final ({int status, Object? json}) unknown =
        await post('/api/library/metadata/episode-group', {
          'key': VideoMetadataWorkKey.collection(name: 'Nope', collectionType: 'playlist').toJson(),
          'groupId': 'x',
        });
    expect(unknown.status, 409);
    expect(
      VideoMetadataWriteResult.fromJson(unknown.json).conflict,
      VideoMetadataConflict.notPlanned,
    );
    final ({int status, Object? json}) bad = await post(
      '/api/library/metadata/episode-group',
      {'key': key(), 'groupId': 7},
    );
    expect(bad.status, 400);
  });
}
