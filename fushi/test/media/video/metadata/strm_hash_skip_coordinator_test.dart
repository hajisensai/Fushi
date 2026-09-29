// STRM 与 M3U/IPTV 视频来源：`.strm` 流指针（一行地址）、`.m3u` / `.m3u8` 清单
// （文本）与网络流地址（rtsp 频道等）都没有媒体字节。ED2K 哈希它们只会拿文本的
// 哈希去撞 AniDB（浪费 UDP 限流配额、每个文件留一条「未登记」的误导日志），所以
// 来源刮削协调器的两处哈希入口（单文件合并预处理 + 逐成员识别）都必须跳过它们，
// 让这些成员照常走标题识别。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('strm-hash-skip-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  VideoSourceScrapeCoordinator coordinator({
    required List<VideoMetadataProvider> providers,
    required _RecordingHashService hash,
  }) {
    addTearDown(hash.close);
    final VideoSourceScrapeCoordinator runner = VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      hashIdentityService: hash,
      registry: VideoMetadataProviderRegistry(providers),
    );
    addTearDown(runner.close);
    return runner;
  }

  Future<SourceScrapeReport> scrape(
          VideoSourceScrapeCoordinator runner, SourceLibraryRow source) =>
      runner.scrapeSource(source,
          cancellationToken: VideoSourceScrapeCancellationToken(),
          onProgress: (_) {});

  Future<List<String>> identities(String bookUid) async {
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook(bookUid))!;
    return (await db.getVideoMetadataProviderIdentities(workId: work.id))
        .map((VideoMetadataProviderIdentityRow id) =>
            '${id.provider}:${id.externalId}:${id.isPrimary}')
        .toList();
  }

  test('a standalone .strm is never hashed and is identified by title',
      () async {
    final SourceLibraryRow source = await _source(db, directory,
        files: <String, String>{'Show.strm': 'https://example.com/live.m3u8'});
    final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    // 若真去哈希，这条结果会让 aid 100 成为作品身份——断言它没被用上。
    final _RecordingHashService hash =
        _RecordingHashService(<String, AnidbHashIdentityResult>{
      'Show.strm': _matched(aid: 100),
    });
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, tmdb], hash: hash),
        source);

    expect(hash.calls, isEmpty, reason: '.strm 是一行地址文本，不能拿去哈希');
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(anidb.searchCalls, greaterThan(0), reason: '没有哈希证据，照常按标题识别');
    expect(anidb.fetchedIds, isNot(contains('100')));
    expect(await identities('book-0'), contains('anidb:42:true'));
    expect(report.warnings.map((SourceScrapeIssue issue) => issue.message),
        everyElement(isNot(contains('Show.strm'))),
        reason: '跳过的成员不留识别日志');
  });

  test('collection members: only the real media file is hashed', () async {
    final SourceLibraryRow source = await _source(db, directory,
        files: <String, String>{
          'Show S01E01.mkv': 'VIDEO',
          'Show S01E02.strm': 'https://example.com/e2.m3u8',
          'Show S01E03.m3u8': '#EXTM3U\nhttps://example.com/e3.ts\n',
        },
        collection: 'Show');
    final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final _RecordingHashService hash =
        _RecordingHashService(const <String, AnidbHashIdentityResult>{});
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, tmdb], hash: hash),
        source);

    expect(hash.calls, <String>['Show S01E01.mkv']);
    final Iterable<String> messages =
        report.warnings.map((SourceScrapeIssue issue) => issue.message);
    expect(messages, everyElement(isNot(contains('Show S01E02.strm'))));
    expect(messages, everyElement(isNot(contains('Show S01E03.m3u8'))));
  });

  test(
      'a unit of IPTV channels has no hash evidence and no hash notices, '
      'even with hashing disabled', () async {
    final SourceLibraryRow source = await _source(db, directory,
        urls: <String>['rtsp://10.0.0.1:554/live/1']);
    final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final _RecordingHashService hash = _RecordingHashService(
        const <String, AnidbHashIdentityResult>{},
        enabled: false);
    final SourceScrapeReport report = await scrape(
        coordinator(
            providers: <VideoMetadataProvider>[anidb, tmdb], hash: hash),
        source);

    expect(hash.calls, isEmpty);
    expect(report.warnings.map((SourceScrapeIssue issue) => issue.message),
        everyElement(isNot(contains('AniDB 哈希识别'))),
        reason: '单元里没有可哈希的文件，「已关闭 / 未配置」提示与它无关');
    expect(anidb.searchCalls, greaterThan(0));
  });
}

/// 建一个视频来源：[files] 是「文件名 → 内容」（落在来源根目录下），[urls] 是
/// 直接写进 `videoPath` 的网络流地址。[collection] 非空时全部成员进同名播放列表
/// 合集。bookUid 按插入顺序 `book-0`、`book-1` …。
Future<SourceLibraryRow> _source(
  FushiDatabase db,
  Directory root, {
  Map<String, String> files = const <String, String>{},
  List<String> urls = const <String>[],
  String? collection,
}) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Source', mediaKind: 'video', rootPath: root.path, createdAt: 1));
  final int? collectionId = collection == null
      ? null
      : await db.createMediaCollection(collection, collectionType: 'playlist');
  final List<String> paths = <String>[
    for (final MapEntry<String, String> entry in files.entries)
      p.join(root.path, entry.key),
    ...urls,
  ];
  for (final MapEntry<String, String> entry in files.entries) {
    await File(p.join(root.path, entry.key)).writeAsString(entry.value);
  }
  for (int index = 0; index < paths.length; index++) {
    await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>('book-$index'),
        title: const Value<String>('Show'),
        videoPath: Value<String>(paths[index]),
        sourceId: Value<int?>(sourceId)));
    if (collectionId != null) {
      await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
    }
  }
  await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          writeNfo: const Value<bool>(false),
          writeImages: const Value<bool>(false),
          fanartEnabled: const Value<bool>(false),
          updatedAt: 1));
  return (await db.getMediaSourceById(sourceId))!;
}

AnidbHashIdentityResult _matched({required int aid}) => AnidbHashIdentityResult(
      status: AnidbHashIdentityStatus.matched,
      hash: AnidbEd2kHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          size: 1,
          modifiedAt: DateTime(2026),
          changedAt: DateTime(2026)),
      identity: AnidbFileIdentity(
          fileId: 500,
          animeId: aid,
          episodeId: 300,
          episodeNumber: '1',
          romajiTitle: 'Show',
          kanjiTitle: '',
          englishTitle: '',
          episodeTitle: '',
          episodeRomajiTitle: '',
          episodeKanjiTitle: '',
          animeType: 'TV Series'),
      mapping: AnimeIdentityMappingResult(anidbId: aid, malIds: const <int>{}),
    );

/// 记下每次 [identifyFile] 的文件名；结果按文件名查表，缺省「未登记」。
class _RecordingHashService extends AnidbHashIdentityService {
  _RecordingHashService(this.results, {bool enabled = true})
      : super(
            enabled: enabled,
            config: const AnidbUdpConfig(
                username: 'user',
                password: 'test',
                clientName: 'testclient',
                clientVersion: 1));
  final Map<String, AnidbHashIdentityResult> results;
  final List<String> calls = <String>[];
  @override
  bool get isConfigured => true;
  @override
  Future<AnidbHashIdentityResult> identifyFile(String path,
      {bool Function()? isCancelled,
      void Function(int, int)? onProgress}) async {
    calls.add(p.basename(path));
    onProgress?.call(1, 1);
    return results[p.basename(path)] ??
        const AnidbHashIdentityResult(status: AnidbHashIdentityStatus.notFound);
  }
}

class _Provider implements VideoMetadataProvider {
  _Provider(this.providerKind);
  @override
  final VideoMetadataProviderKind providerKind;
  int searchCalls = 0;
  final List<String> fetchedIds = <String>[];
  @override
  bool get isAvailable => true;

  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      VideoMetadataWork(
        provider: providerKind,
        kind: kind,
        title: 'Show',
        plot: '${providerKind.name} plot',
        ids: <VideoMetadataId>[
          VideoMetadataId(type: providerKind.name, value: id, isDefault: true)
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    return <VideoMetadataWork>[_work('42', request.mediaKind)];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    return _work(lookup.externalId, lookup.mediaKind);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      <VideoMetadataSeason>[];
  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      <VideoMetadataEpisode>[];
  @override
  void close() {}
}
