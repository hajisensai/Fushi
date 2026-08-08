import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_models.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_asset_downloader.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_provider.dart';
import 'package:hibiki/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late HibikiDatabase db;
  late Directory root;

  setUp(() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('hibiki-source-scrape-');
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('按作品抓取一次并写规范表、兼容投影和安全 TV NFO', () async {
    final Directory seasonDir =
        Directory(p.join(root.path, 'Show', 'Season 01'));
    await seasonDir.create(recursive: true);
    final File episode1 = File(p.join(seasonDir.path, 'Show S01E01.mkv'));
    final File episode2 = File(p.join(seasonDir.path, 'Show S01E02.mkv'));
    final File ncop = File(p.join(root.path, 'Show NCOP.mkv'));
    await episode1.writeAsBytes(const <int>[0]);
    await episode2.writeAsBytes(const <int>[0]);
    await ncop.writeAsBytes(const <int>[0]);

    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Show source',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('e1'),
      title: const Value<String>('Show S01E01'),
      videoPath: Value<String>(episode1.path),
      sourceId: Value<int?>(sourceId),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('ncop'),
      title: const Value<String>('Show NCOP'),
      videoPath: Value<String>(ncop.path),
      sourceId: Value<int?>(sourceId),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('e2'),
      title: const Value<String>('Show S01E02'),
      videoPath: Value<String>(episode2.path),
      sourceId: Value<int?>(sourceId),
    ));
    final int collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 'e1');
    await db.addToCollection(collectionId, MediaKind.video, 'e2');
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        providerOverride: const Value<String?>('tmdb'),
        writeImages: const Value<bool>(false),
        updatedAt: 1,
      ),
    );

    final _FakeTmdbProvider provider = _FakeTmdbProvider();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]),
      fanartProvider: const _NoImages(),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final SourceScrapeReport report = await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(
      report.succeededWorks,
      1,
      reason: report.errors
          .map((SourceScrapeIssue issue) => issue.message)
          .join('\n'),
    );
    expect(report.failedWorks, 0);
    expect(report.totalWorks, 1, reason: 'NCOP/NCED 是作品附件，不应作为独立作品制造刮削失败');
    expect(provider.searchCount, 1);
    expect(report.nfoWritten, 4);
    expect(File(p.join(root.path, 'Show', 'tvshow.nfo')).existsSync(), isTrue);
    expect(File(p.join(seasonDir.path, 'season.nfo')).existsSync(), isTrue);
    final String episodeXml =
        await File(p.join(seasonDir.path, 'Show S01E01.nfo')).readAsString();
    expect(episodeXml, contains('<episodedetails>'));
    expect(episodeXml, contains('<title>Episode One</title>'));

    final VideoMetadataWorkRow? work =
        await db.getVideoMetadataWorkByCollection(collectionId);
    expect(work?.title, 'Show');
    final List<VideoMetadataSeasonRow> seasons =
        await db.getVideoMetadataSeasons(work!.id);
    expect(seasons, hasLength(1));
    final List<VideoMetadataEpisodeRow> episodes =
        await db.getVideoMetadataEpisodes(seasons.single.id);
    expect(episodes.map((VideoMetadataEpisodeRow row) => row.bookUid),
        <String?>['e1', 'e2']);
    expect(await db.getCollectionScrapeMeta(collectionId), isNotNull);
    expect((await db.getVideoScrapeMeta('e1'))?.title, 'Episode One');
    expect((await db.getVideoBookByBookUid('e1'))?.title, 'Episode One',
        reason: '只改应用内展示标题，不重命名磁盘视频文件');
    expect(episode1.path, endsWith('Show S01E01.mkv'));
    expect(await db.getVideoSidecarArtifacts(sourceId: sourceId), hasLength(4));
    final List<VideoMetadataCreditRow> episodeCredits =
        await db.getVideoMetadataCredits(episodeId: episodes.first.id);
    expect(episodeCredits.single.creditKind, 'voice_actor');
  });

  test('已有 TMDB id 的补充请求失败时仍落地主源资料', () async {
    final SourceLibraryRow source = await _createMovieSource(
      db,
      root,
      provider: VideoMetadataProviderKind.bangumi,
    );
    final _PrimaryMovieProvider primary = _PrimaryMovieProvider();
    final _ThrowingTmdbProvider tmdb = _ThrowingTmdbProvider();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.bangumi,
      ),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        primary,
        tmdb,
      ]),
      fanartProvider: const _NoImages(),
    );

    final SourceScrapeReport report = await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(report.failedWorks, 0);
    expect(tmdb.fetchCount, 1);
    expect(
      report.warnings.map((SourceScrapeIssue issue) => issue.message).join(),
      contains('TMDB 规范身份补充失败'),
    );
    final VideoMetadataWorkRow? stored =
        await db.getVideoMetadataWorkByBook('movie-book');
    expect(stored?.title, '主源电影');
  });

  test('续季主源先映射本地季号且后续 TMDB 失败不删除旧完整骨架', () async {
    final Directory seasonDir =
        Directory(p.join(root.path, 'Show', 'Season 02'));
    await seasonDir.create(recursive: true);
    for (final String name in <String>[
      'Show S02E01.mkv',
      'Show S02E02.mkv',
    ]) {
      await File(p.join(seasonDir.path, name)).writeAsBytes(const <int>[0]);
    }
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Continuation source',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('s2e1'),
      title: const Value<String>('Show S02E01'),
      videoPath: Value<String>(p.join(seasonDir.path, 'Show S02E01.mkv')),
      sourceId: Value<int?>(sourceId),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('s2e2'),
      title: const Value<String>('Show S02E02'),
      videoPath: Value<String>(p.join(seasonDir.path, 'Show S02E02.mkv')),
      sourceId: Value<int?>(sourceId),
    ));
    final int collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 's2e1');
    await db.addToCollection(collectionId, MediaKind.video, 's2e2');
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        providerOverride: const Value<String?>('bangumi'),
        writeNfo: const Value<bool>(false),
        writeImages: const Value<bool>(false),
        fanartEnabled: const Value<bool>(false),
        updatedAt: 1,
      ),
    );
    final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
    final _PrimaryContinuationProvider primary = _PrimaryContinuationProvider();
    final VideoSourceScrapeCoordinator firstCoordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.bangumi,
      ),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        primary,
        _ContinuationTmdbProvider(),
      ]),
      fanartProvider: const _NoImages(),
    );
    final SourceScrapeReport first = await firstCoordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(first.succeededWorks, 1, reason: '${first.errors}');

    final VideoMetadataWorkRow stored =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    List<VideoMetadataSeasonRow> seasons =
        await db.getVideoMetadataSeasons(stored.id);
    expect(
      seasons.map((VideoMetadataSeasonRow row) => row.seasonNumber),
      <int>[1, 2],
    );
    expect(
      (await db.getVideoMetadataEpisodes(seasons.first.id)).single.title,
      'TMDB S01E01',
      reason: '续季主源 E01 不得覆盖 TMDB 的 S01E01',
    );
    List<VideoMetadataEpisodeRow> season2 =
        await db.getVideoMetadataEpisodes(seasons.last.id);
    expect(season2.first.title, '主源续季第一集');
    expect(season2.last.title, 'TMDB S02E02');

    final _ThrowingTmdbProvider failingTmdb = _ThrowingTmdbProvider();
    final VideoSourceScrapeCoordinator secondCoordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.bangumi,
      ),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        primary,
        failingTmdb,
      ]),
      fanartProvider: const _NoImages(),
    );
    final SourceScrapeReport second = await secondCoordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(second.succeededWorks, 1, reason: '${second.errors}');
    expect(failingTmdb.fetchCount, 1);

    seasons = await db.getVideoMetadataSeasons(stored.id);
    expect(
      seasons.map((VideoMetadataSeasonRow row) => row.seasonNumber),
      <int>[1, 2],
    );
    season2 = await db.getVideoMetadataEpisodes(seasons.last.id);
    expect(
      season2.map((VideoMetadataEpisodeRow row) => row.episodeNumber),
      <int>[1, 2],
      reason: 'TMDB supplement 失败时不得删除旧 S02E02',
    );
  });

  test('年份识别不读取父与祖父之外的绝对路径片段', () async {
    final Directory movieDir =
        Directory(p.join(root.path, '1999', 'Library', 'Movie Folder'));
    await movieDir.create(recursive: true);
    final File video = File(p.join(movieDir.path, 'Movie.mkv'));
    await video.writeAsBytes(const <int>[0]);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Movie source',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('year-boundary-movie'),
      title: const Value<String>('Movie'),
      videoPath: Value<String>(video.path),
      sourceId: Value<int?>(sourceId),
    ));
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        providerOverride: const Value<String?>('tmdb'),
        writeNfo: const Value<bool>(false),
        writeImages: const Value<bool>(false),
        fanartEnabled: const Value<bool>(false),
        updatedAt: 1,
      ),
    );
    final _YearCapturingTmdbProvider provider = _YearCapturingTmdbProvider();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]),
      fanartProvider: const _NoImages(),
    );

    final SourceScrapeReport report = await coordinator.scrapeSource(
      (await db.getMediaSourceById(sourceId))!,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(provider.searchYears, isNotEmpty);
    expect(provider.searchYears, everyElement(isNull));
  });

  test('Himouto 发布名的 1920x1080 不会被当成年份拒绝正确候选', () async {
    final Directory showDir = Directory(p.join(root.path, 'Himouto'));
    await showDir.create(recursive: true);
    final List<String> names = <String>[
      '[Kamigami] Himouto! Umaru-chan - 08 '
          '[1920x1080 x264 AAC Sub(Chs,Cht,Jap)].mkv',
      '[Kamigami] Himouto! Umaru-chan - 09 '
          '[1920x1080 x264 AAC Sub(Chs,Cht,Jap)].mkv',
    ];
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Himouto source',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    for (int index = 0; index < names.length; index++) {
      final File video = File(p.join(showDir.path, names[index]));
      await video.writeAsBytes(const <int>[0]);
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>('himouto-${index + 8}'),
        title: Value<String>(p.basenameWithoutExtension(names[index])),
        videoPath: Value<String>(video.path),
        sourceId: Value<int?>(sourceId),
      ));
    }
    final int collectionId = await db.createMediaCollection(
      'Himouto! Umaru-chan',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'himouto-8');
    await db.addToCollection(collectionId, MediaKind.video, 'himouto-9');
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        providerOverride: const Value<String?>('tmdb'),
        writeNfo: const Value<bool>(false),
        writeImages: const Value<bool>(false),
        fanartEnabled: const Value<bool>(false),
        updatedAt: 1,
      ),
    );
    final _HimoutoTmdbProvider provider = _HimoutoTmdbProvider();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]),
      fanartProvider: const _NoImages(),
    );

    final SourceScrapeReport report = await coordinator.scrapeSource(
      (await db.getMediaSourceById(sourceId))!,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(provider.searchYears, isNotEmpty);
    expect(provider.searchYears, everyElement(isNull));
    expect(
      (await db.getVideoMetadataWorkByCollection(collectionId))?.year,
      2015,
    );
  });

  test('re0 使用清洗后的父目录标题和第三季约束识别主剧', () async {
    final Directory showDir = Directory(p.join(
      root.path,
      '[DBD-Raws][Re：从零开始的异世界生活 第三季]'
      '[01-16TV全集+SP][1080P][BDRip]',
    ));
    await showDir.create(recursive: true);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 're0',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    for (final int episode in <int>[1, 2]) {
      final String uid = 're0-main-$episode';
      final File video = File(p.join(
        showDir.path,
        '[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
        '[${episode.toString().padLeft(2, '0')}][1080P][BDRip].mkv',
      ));
      await video.writeAsBytes(const <int>[0]);
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(p.basenameWithoutExtension(video.path)),
        videoPath: Value<String>(video.path),
        sourceId: Value<int?>(sourceId),
      ));
    }
    final Directory pvDir = Directory(p.join(showDir.path, 'PV'));
    await pvDir.create(recursive: true);
    final File pv = File(p.join(
      pvDir.path,
      '[DBD-Raws][Re Zero kara Hajimeru Isekai Seikatsu S3]'
      '[PV][01][1080P][BDRip].mkv',
    ));
    await pv.writeAsBytes(const <int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('re0-pv-1'),
      title: Value<String>(p.basenameWithoutExtension(pv.path)),
      videoPath: Value<String>(pv.path),
      sourceId: Value<int?>(sourceId),
    ));
    final int collectionId = await db.createMediaCollection(
      'Re Zero kara Hajimeru Isekai Seikatsu',
      collectionType: 'playlist',
    );
    for (final String uid in <String>[
      're0-main-1',
      're0-main-2',
      're0-pv-1',
    ]) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        providerOverride: const Value<String?>('tmdb'),
        writeNfo: const Value<bool>(false),
        writeImages: const Value<bool>(false),
        fanartEnabled: const Value<bool>(false),
        updatedAt: 1,
      ),
    );
    final _ReZeroTmdbProvider provider = _ReZeroTmdbProvider();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]),
      fanartProvider: const _NoImages(),
    );

    final SourceScrapeReport report = await coordinator.scrapeSource(
      (await db.getMediaSourceById(sourceId))!,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(report.totalWorks, 1,
        reason: '${report.warnings}\n${report.errors}');
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(provider.searchTitles, contains('Re：从零开始的异世界生活'));
    expect(provider.searchSeasons, everyElement(3));
    expect(
      (await db.getVideoMetadataWorkByCollection(collectionId))?.title,
      'Re：从零开始的异世界生活',
    );
  });

  test('缺少真实分集资料时生成的 episode NFO 不伪造文件名标题', () async {
    final Directory seasonDir =
        Directory(p.join(root.path, 'Unknown Show', 'Season 01'));
    await seasonDir.create(recursive: true);
    for (final String name in <String>[
      'Unknown Show S01E01.mkv',
      'Unknown Show S01E02.mkv',
    ]) {
      await File(p.join(seasonDir.path, name)).writeAsBytes(const <int>[0]);
    }
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Unknown show source',
        mediaKind: 'video',
        rootPath: root.path,
        createdAt: 1,
      ),
    );
    for (final (int number, String uid) in <(int, String)>[
      (1, 'unknown-e1'),
      (2, 'unknown-e2'),
    ]) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>('Unknown Show E$number'),
        videoPath: Value<String>(
            p.join(seasonDir.path, 'Unknown Show S01E0$number.mkv')),
        sourceId: Value<int?>(sourceId),
      ));
    }
    final int collectionId = await db.createMediaCollection(
      'Unknown Show',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'unknown-e1');
    await db.addToCollection(collectionId, MediaKind.video, 'unknown-e2');
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(sourceId),
        providerOverride: const Value<String?>('tmdb'),
        writeNfo: const Value<bool>(true),
        writeImages: const Value<bool>(false),
        fanartEnabled: const Value<bool>(false),
        updatedAt: 1,
      ),
    );
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        _NoEpisodeTmdbProvider(),
      ]),
      fanartProvider: const _NoImages(),
    );

    final SourceScrapeReport report = await coordinator.scrapeSource(
      (await db.getMediaSourceById(sourceId))!,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final String xml = await File(
      p.join(seasonDir.path, 'Unknown Show S01E01.nfo'),
    ).readAsString();
    expect(xml, contains('<season>1</season>'));
    expect(xml, contains('<episode>1</episode>'));
    expect(xml, isNot(contains('<title>')));
    expect(xml, isNot(contains('Unknown Show S01E01')));
  });

  test('同一 coordinator 的下一次 scrapeSource 会重新抓取而不复用旧批次缓存', () async {
    final SourceLibraryRow source = await _createMovieSource(
      db,
      root,
      provider: VideoMetadataProviderKind.tmdb,
    );
    final _RefreshingTmdbProvider provider = _RefreshingTmdbProvider();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]),
      fanartProvider: const _NoImages(),
    );

    final SourceScrapeReport first = await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(first.succeededWorks, 1, reason: '${first.errors}');
    expect(
      (await db.getVideoMetadataWorkByBook('movie-book'))?.title,
      'Movie metadata 1',
    );

    final SourceScrapeReport second = await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(second.succeededWorks, 1, reason: '${second.errors}');
    expect(provider.fetchCount, 2);
    expect(
      (await db.getVideoMetadataWorkByBook('movie-book'))?.title,
      'Movie metadata 2',
    );
  });

  test('同层级同图种只把排序后的首选图片写入 sidecar', () async {
    final SourceLibraryRow source = await _createMovieSource(
      db,
      root,
      provider: VideoMetadataProviderKind.tmdb,
    );
    await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
        sourceId: Value<int>(source.id),
        providerOverride: const Value<String?>('tmdb'),
        writeNfo: const Value<bool>(false),
        writeImages: const Value<bool>(true),
        fanartEnabled: const Value<bool>(false),
        updatedAt: 2,
      ),
    );
    final _TwoBackdropTmdbProvider provider = _TwoBackdropTmdbProvider();
    final _RecordingAssetDownloader downloader = _RecordingAssetDownloader();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(
        primaryProvider: VideoMetadataProviderKind.tmdb,
      ),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[provider]),
      fanartProvider: const _NoImages(),
      assetDownloader: downloader,
    );

    final SourceScrapeReport report = await coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );

    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(downloader.urls, <String>['https://images.test/best.jpg']);
    final Uint8List expected = downloader.bytesForBest;
    expect(
      await File(p.join(root.path, 'Movie (2024)-backdrop.jpg')).readAsBytes(),
      expected,
    );
    expect(
      await File(p.join(root.path, 'Movie (2024)-fanart.jpg')).readAsBytes(),
      expected,
    );
  });
}

Future<SourceLibraryRow> _createMovieSource(
  HibikiDatabase db,
  Directory root, {
  required VideoMetadataProviderKind provider,
}) async {
  final File video = File(p.join(root.path, 'Movie (2024).mkv'));
  await video.writeAsBytes(const <int>[0]);
  final int sourceId = await db.insertMediaSource(
    MediaSourcesCompanion.insert(
      label: 'Movie source',
      mediaKind: 'video',
      rootPath: root.path,
      createdAt: 1,
    ),
  );
  await db.upsertVideoBook(VideoBooksCompanion(
    bookUid: const Value<String>('movie-book'),
    title: const Value<String>('Movie'),
    videoPath: Value<String>(video.path),
    sourceId: Value<int?>(sourceId),
  ));
  await db.upsertVideoSourceScrapeSettings(
    VideoSourceScrapeSettingsCompanion.insert(
      sourceId: Value<int>(sourceId),
      providerOverride: Value<String?>(provider.name),
      writeNfo: const Value<bool>(false),
      writeImages: const Value<bool>(false),
      fanartEnabled: const Value<bool>(false),
      updatedAt: 1,
    ),
  );
  return (await db.getMediaSourceById(sourceId))!;
}

class _FakeTmdbProvider implements VideoMetadataProvider {
  int searchCount = 0;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show',
        year: 2025,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '42', isDefault: true),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(
            seasonNumber: 1,
            title: 'Season 1',
            episodeCount: 2,
          ),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchCount++;
    return <VideoMetadataWork>[work];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      <VideoMetadataEpisode>[
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: 1,
          title: 'Episode One',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tmdb', value: '4201'),
          ],
          credits: <VideoMetadataCredit>[
            VideoMetadataCredit(
              kind: VideoMetadataCreditKind.voiceActor,
              person: VideoMetadataPerson(
                id: '7',
                name: 'Voice Actor',
                ids: const <VideoMetadataId>[
                  VideoMetadataId(type: 'tmdb', value: '7'),
                ],
              ),
              character: VideoMetadataCharacter(name: 'Hero'),
            ),
          ],
        ),
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: 2,
          title: 'Episode Two',
          ids: const <VideoMetadataId>[
            VideoMetadataId(type: 'tmdb', value: '4202'),
          ],
        ),
      ];

  @override
  void close() {}
}

class _PrimaryContinuationProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.bangumi;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show Season 2',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '200'),
          VideoMetadataId(type: 'tmdb', value: '100'),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 1, title: '主源当前季'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[work];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      <VideoMetadataEpisode>[
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: 1,
          title: '主源续季第一集',
        ),
      ];

  @override
  void close() {}
}

class _ContinuationTmdbProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Show',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '100'),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 1, title: 'TMDB Season 1'),
          VideoMetadataSeason(seasonNumber: 2, title: 'TMDB Season 2'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[work];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      seasonNumber == 1
          ? <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 1,
                episodeNumber: 1,
                title: 'TMDB S01E01',
              ),
            ]
          : <VideoMetadataEpisode>[
              VideoMetadataEpisode(
                seasonNumber: 2,
                episodeNumber: 1,
                title: 'TMDB S02E01',
              ),
              VideoMetadataEpisode(
                seasonNumber: 2,
                episodeNumber: 2,
                title: 'TMDB S02E02',
              ),
            ];

  @override
  void close() {}
}

class _YearCapturingTmdbProvider implements VideoMetadataProvider {
  final List<int?> searchYears = <int?>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.movie,
        title: 'Movie',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '500'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchYears.add(request.year);
    return <VideoMetadataWork>[work];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

class _HimoutoTmdbProvider implements VideoMetadataProvider {
  final List<int?> searchYears = <int?>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Himouto! Umaru-chan',
        originalTitle: '干物妹！うまるちゃん',
        year: 2015,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '67126'),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 1, title: 'Season 1'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchYears.add(request.year);
    return <VideoMetadataWork>[work];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      <VideoMetadataEpisode>[
        for (final int number in <int>[8, 9])
          VideoMetadataEpisode(
            seasonNumber: 1,
            episodeNumber: number,
            title: 'Episode $number',
          ),
      ];

  @override
  void close() {}
}

class _ReZeroTmdbProvider implements VideoMetadataProvider {
  final List<String> searchTitles = <String>[];
  final List<int?> searchSeasons = <int?>[];

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Re：从零开始的异世界生活',
        originalTitle: 'Re:ゼロから始める異世界生活',
        year: 2016,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '65942'),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 3, title: 'Season 3'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async {
    searchTitles.add(request.title);
    searchSeasons.add(request.seasonNumber);
    return request.title == 'Re：从零开始的异世界生活'
        ? <VideoMetadataWork>[work]
        : const <VideoMetadataWork>[];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      <VideoMetadataEpisode>[
        for (final int number in <int>[1, 2])
          VideoMetadataEpisode(
            seasonNumber: 3,
            episodeNumber: number,
            title: 'Episode $number',
          ),
      ];

  @override
  void close() {}
}

class _NoEpisodeTmdbProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Unknown Show',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '600'),
        ],
        seasons: <VideoMetadataSeason>[
          VideoMetadataSeason(seasonNumber: 1, title: 'Season 1'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[work];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

class _PrimaryMovieProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind =>
      VideoMetadataProviderKind.bangumi;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get _searchWork => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.movie,
        title: 'Movie',
        year: 2024,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '1', isDefault: true),
        ],
      );

  VideoMetadataWork get _details => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.movie,
        title: '主源电影',
        year: 2024,
        plot: '主源简介',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'bangumi', value: '1', isDefault: true),
          VideoMetadataId(type: 'tmdb', value: '99'),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[_searchWork];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      _details;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

class _ThrowingTmdbProvider implements VideoMetadataProvider {
  int fetchCount = 0;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      throw StateError('TMDB search should not run when id is already bound');

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchCount++;
    throw StateError('TMDB unavailable');
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

class _RefreshingTmdbProvider implements VideoMetadataProvider {
  int fetchCount = 0;

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork _work(String title) => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.movie,
        title: title,
        year: 2024,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '42', isDefault: true),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[_work('Movie')];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchCount++;
    return _work('Movie metadata $fetchCount');
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

class _NoImages implements VideoMetadataImageProvider {
  const _NoImages();

  @override
  bool get isAvailable => false;

  @override
  Future<List<VideoMetadataImage>> fetchImages(VideoMetadataWork work) async =>
      const <VideoMetadataImage>[];

  @override
  void close() {}
}

class _TwoBackdropTmdbProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  VideoMetadataWork get work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.movie,
        title: 'Movie',
        year: 2024,
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '700', isDefault: true),
        ],
        images: const <VideoMetadataImage>[
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: 'https://images.test/best.jpg',
            provider: VideoMetadataProviderKind.tmdb,
            voteAverage: 9,
            voteCount: 100,
          ),
          VideoMetadataImage(
            kind: VideoMetadataImageKind.backdrop,
            url: 'https://images.test/secondary.jpg',
            provider: VideoMetadataProviderKind.tmdb,
            voteAverage: 8,
            voteCount: 200,
          ),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
    VideoMetadataSearchRequest request,
  ) async =>
      <VideoMetadataWork>[work];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      work;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
    VideoMetadataLookup lookup,
  ) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(
    VideoMetadataLookup lookup, {
    required int seasonNumber,
  }) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}

class _RecordingAssetDownloader extends VideoMetadataAssetDownloader {
  final List<String> urls = <String>[];
  final Uint8List bytesForBest = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 1]);

  @override
  Future<VideoMetadataDownloadedAsset> download(String url) async {
    urls.add(url);
    return VideoMetadataDownloadedAsset(
      bytes: bytesForBest,
      extension: '.jpg',
      contentType: 'image/jpeg',
    );
  }

  @override
  void close() {}
}
