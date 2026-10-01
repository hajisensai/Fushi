import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端扫描进来的视频要能被刮削（设计文档第 0 期：扫描器「视频经
/// `VideoBookRepository` upsert + ffmpeg 封面 + 刮削协调器」）。
///
/// 以前两处断链：① 扫描器写行不带 `sourceId`、也不把分集归成合集，刮削计划器
/// （只认「sourceId + 合集成员」）对服务端的库永远规划出零个作品；② 刮削协调器只在
/// 下载管线里建、且没有 torrent 后端时不建，扫描后从来没有人去刮。
void main() {
  late Directory tmp;
  late Directory libraryRoot;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_scrape_');
    libraryRoot = Directory(p.join(tmp.path, 'library'))..createSync();
    final ServerPaths paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
    enginePaths = paths;
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (db) => db.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  LibraryRootConfig root() =>
      LibraryRootConfig(id: 'anime', path: libraryRoot.path, kind: 'video');

  Future<ScanSummary> scan() => LibraryScanner(
    db: db,
    subtitleLanguage: 'ja',
    extractCovers: false,
  ).scanAll(<LibraryRootConfig>[root()]);

  void writeSeries(String series, int episodes) {
    final Directory dir = Directory(p.join(libraryRoot.path, series))
      ..createSync(recursive: true);
    for (int i = 1; i <= episodes; i++) {
      final String ep = i.toString().padLeft(2, '0');
      File(
        p.join(dir.path, '[Grp] $series - $ep [1080p].mkv'),
      ).writeAsStringSync('x');
    }
  }

  Future<SourceLibraryRow> onlySource() async {
    final List<SourceLibraryRow> sources = await db.getMediaSourcesByKind(
      'video',
    );
    expect(sources, hasLength(1));
    return sources.single;
  }

  test('视频根登记为本地来源，入库行带 sourceId，分集归成一部作品', () async {
    writeSeries('Frieren', 3);

    await scan();

    final SourceLibraryRow source = await onlySource();
    expect(source.transport, 'local');
    expect(
      p.equals(source.rootPath, p.normalize(libraryRoot.absolute.path)),
      isTrue,
    );
    expect(source.label, 'anime');
    final List<VideoBookRow> rows = await VideoBookRepository(db).listAll();
    expect(rows, hasLength(3));
    expect(rows.every((VideoBookRow r) => r.sourceId == source.id), isTrue);

    final List<VideoSourceScrapeWork> works = await VideoSourceWorkPlanner(
      db,
    ).plan(source);
    expect(works, hasLength(1), reason: '三集应归成一部作品，而不是三个独立作品');
    expect(works.single.isEpisodic, isTrue);
    expect(works.single.members, hasLength(3));
  });

  test('重扫复用同一行来源，不重复登记', () async {
    writeSeries('Frieren', 2);
    await scan();
    await scan();

    await onlySource();
  });

  test('存量行（旧版本扫描进来、没有 sourceId）重扫时回填并归组', () async {
    writeSeries('Frieren', 2);
    // 模拟旧版本扫描的产物：只有行，没有来源、没有合集。
    final VideoBookRepository repo = VideoBookRepository(db);
    final Directory dir = Directory(p.join(libraryRoot.path, 'Frieren'));
    for (final FileSystemEntity f in dir.listSync()) {
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value('legacy/${p.basename(f.path)}'),
          title: Value(p.basenameWithoutExtension(f.path)),
          videoPath: Value(f.path),
          importedAt: const Value(1),
        ),
      );
    }

    final ScanSummary summary = await scan();

    expect(summary.videosAdded, 0, reason: '存量行按路径去重，不重复入库');
    final SourceLibraryRow source = await onlySource();
    final List<VideoBookRow> rows = await repo.listAll();
    expect(rows.every((VideoBookRow r) => r.sourceId == source.id), isTrue);
    expect(await VideoSourceWorkPlanner(db).plan(source), hasLength(1));
  });

  group('扫描后补刮', () {
    late _RecordingProvider provider;
    late ServerConfig config;

    ServerVideoScrape build() => ServerVideoScrape(
      db: db,
      prefs: ServerPrefs(db),
      config: () => config,
      ledger: VideoScrapeSweepLedger(),
      coordinatorFactory: (scrapeConfig) => VideoSourceScrapeCoordinator(
        database: db,
        config: scrapeConfig,
        primaryProvider: VideoMetadataProviderKind.anidb,
        registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
          provider,
        ]),
      ),
    );

    setUp(() {
      provider = _RecordingProvider();
      config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data'));
    });

    test('扫描进来的作品交给刮削器（带作品标题问资料源）', () async {
      writeSeries('Frieren', 3);
      await scan();
      final ServerVideoScrape scrape = build();
      addTearDown(scrape.close);

      await scrape.sweep();

      expect(provider.searchedTitles, isNotEmpty);
      expect(
        provider.searchedTitles.any((String t) => t.contains('Frieren')),
        isTrue,
        reason: '搜到的是作品名，不是某一集的文件名：${provider.searchedTitles}',
      );
      // 查无结果 → 留在待确认队列里（客户端可经互联手动指定）。
      expect(await scrape.pendingCount(), 1);
    });

    test('scan_scrape: false → 不发任何资料源请求', () async {
      writeSeries('Frieren', 2);
      await scan();
      config = config.copyWith(scanScrape: false);
      final ServerVideoScrape scrape = build();
      addTearDown(scrape.close);

      await scrape.sweep();

      expect(provider.searchedTitles, isEmpty);
      expect(scrape.status()['enabled'], isFalse);
    });

    test('TMDB key：配置文件优先，其次偏好表；都没有就是空（服务端没有内置 key）', () async {
      final ServerPrefs prefs = ServerPrefs(db);
      expect(resolveServerTmdbApiKey(config, prefs), isEmpty);
      await prefs.setPref('video_scraper_tmdb_api_key', 'from-prefs');
      expect(resolveServerTmdbApiKey(config, prefs), 'from-prefs');
      expect(
        resolveServerTmdbApiKey(
          config.copyWith(tmdbApiKey: ' from-yaml '),
          prefs,
        ),
        'from-yaml',
      );
    });
  });

  test('配置往返：scan_scrape / tmdb_api_key', () {
    final ServerConfig written = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(scanScrape: false, tmdbApiKey: 'k123');
    final ServerConfig read = ServerConfig.parse(
      written.toYaml(),
      configDir: tmp.path,
    );
    expect(read.scanScrape, isFalse);
    expect(read.tmdbApiKey, 'k123');
    final ServerConfig defaults = ServerConfig.parse('', configDir: tmp.path);
    expect(defaults.scanScrape, isTrue);
    expect(defaults.tmdbApiKey, isNull);
  });
}

/// 只记录被问了什么标题的资料源：查无结果，不依赖解析器的命中细节。
class _RecordingProvider implements VideoMetadataProvider {
  final List<String> searchedTitles = <String>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.anidb;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchedTitles.add(request.title);
    return const <VideoMetadataWork>[];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      null;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async => const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async => const <VideoMetadataEpisode>[];

  @override
  void close() {}
}
