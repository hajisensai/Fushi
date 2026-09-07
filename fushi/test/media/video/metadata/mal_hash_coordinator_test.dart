import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi/src/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi/src/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi/src/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi/src/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('mal-hash-coordinator-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  VideoSourceScrapeCoordinator coordinator(
      _Provider? mal, _Provider? tmdb, _HashService hash) {
    addTearDown(hash.close);
    return VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      hashIdentityService: hash,
      registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
        if (mal != null) mal,
        if (tmdb != null) tmdb,
      ]),
    );
  }

  Future<SourceScrapeReport> scrape(
          VideoSourceScrapeCoordinator runner, SourceLibraryRow source,
          {VideoSourceScrapeCancellationToken? token,
          VideoSourceScrapeProgressCallback? progress}) =>
      runner.scrapeSource(source,
          cancellationToken: token ?? VideoSourceScrapeCancellationToken(),
          onProgress: progress ?? (_) {});

  test(
      'hash authentication failure gives recovery without blocking MAL metadata',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final SourceScrapeReport report = await scrape(
        coordinator(
          _Provider(VideoMetadataProviderKind.mal),
          null,
          _HashService(results: const <AnidbHashIdentityResult>[
            AnidbHashIdentityResult(
              status: AnidbHashIdentityStatus.failed,
              error: AnidbUdpException(AnidbUdpFailure.authentication),
            ),
          ]),
        ),
        source);
    expect(report.succeededWorks, 1);
    expect(
        report.warnings.any((issue) => issue.message.contains('登录失败')), isTrue);
    expect(report.warnings.any((issue) => issue.message.contains('用户名和密码')),
        isTrue);
  });

  test(
      'default MAL identity ignores retired source override; complete MAL does not supplement',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final _HashService hash = _HashService(enabled: false);
    final SourceScrapeReport report =
        await scrape(coordinator(mal, tmdb, hash), source);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(await _primaryProvider(db), 'mal');
    expect(tmdb.searchCalls, 0);
    expect(hash.calls, 0);
    expect(report.warnings, isEmpty);
  });

  for (final String legacy in <String>['database', 'nfo', 'both']) {
    test(
        'retired AniDB primary in $legacy never promotes its TMDB cross-reference',
        () async {
      final SourceLibraryRow source = await _source(db, directory);
      if (legacy != 'nfo') {
        final VideoSourceScrapeWork local =
            (await VideoSourceWorkPlanner(db).plan(source)).single;
        await VideoMetadataDatabaseStore(db).apply(
            local,
            _Provider(VideoMetadataProviderKind.anidb)
                ._work('100', VideoMetadataMediaKind.movie)
                .copyWith(
              ids: <VideoMetadataId>[
                const VideoMetadataId(
                    type: 'anidb', value: '100', isDefault: true),
                const VideoMetadataId(type: 'tmdb', value: '99'),
              ],
              plot: 'Old wrong plot',
            ));
      }
      final File nfo = File(p.join(directory.path, 'Show.nfo'));
      const String legacyNfo =
          '<movie><title>Old wrong work</title><plot>Old wrong plot</plot>'
          '<uniqueid type="anidb" default="true">100</uniqueid>'
          '<uniqueid type="tmdb">99</uniqueid></movie>';
      if (legacy != 'database') await nfo.writeAsString(legacyNfo);
      final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
      final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
      final SourceScrapeReport report = await scrape(
          coordinator(mal, tmdb, _HashService(enabled: false)), source);
      expect(report.succeededWorks, 1, reason: '${report.errors}');
      expect(mal.searchCalls, greaterThan(0));
      expect(await _primaryProvider(db), 'mal');
      expect(tmdb.fetchedIds, isNot(contains('99')));
      final VideoMetadataWorkRow stored =
          (await db.getVideoMetadataWorkByBook('book-0'))!;
      expect(stored.overview, 'mal plot');
      final List<VideoMetadataProviderIdentityRow> ids =
          await db.getVideoMetadataProviderIdentities(workId: stored.id);
      expect(
          ids.any((VideoMetadataProviderIdentityRow id) =>
              id.provider == 'tmdb' && id.externalId == '99'),
          isFalse);
      if (legacy != 'database') {
        expect(await nfo.readAsString(), legacyNfo);
        expect(
            report.warnings
                .map((SourceScrapeIssue issue) => issue.message)
                .join(),
            contains('旧资料源'));
      }
    });
  }

  for (final bool unavailable in <bool>[false, true]) {
    test(
        'MAL ${unavailable ? 'unregistered' : 'empty'} uses TMDB canonical identity',
        () async {
      final SourceLibraryRow source = await _source(db, directory);
      final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
      final SourceScrapeReport report = await scrape(
          coordinator(
              unavailable
                  ? null
                  : _Provider(VideoMetadataProviderKind.mal, empty: true),
              tmdb,
              _HashService(enabled: false)),
          source);
      expect(report.succeededWorks, 1,
          reason:
              'errors=${report.errors.map((SourceScrapeIssue issue) => issue.message).toList()} warnings=${report.warnings.map((SourceScrapeIssue issue) => issue.message).toList()}');
      expect(await _primaryProvider(db), 'tmdb');
      expect(tmdb.searchCalls, greaterThan(0));
    });
  }

  test(
      'missing MAL fields use strict TMDB supplement without replacing plot or rating',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _Provider mal =
        _Provider(VideoMetadataProviderKind.mal, missingBackdrop: true);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    VideoMetadataWork? applied;
    final _HashService hash = _HashService(enabled: false);
    addTearDown(hash.close);
    final VideoSourceScrapeCoordinator runner = VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      hashIdentityService: hash,
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
      onWorkScraped: (VideoScrapedWorkNotice notice) async {
        applied = notice.metadata;
      },
    );
    expect((await scrape(runner, source)).succeededWorks, 1);
    expect(applied?.provider, VideoMetadataProviderKind.mal);
    expect(applied?.plot, 'mal plot');
    expect(applied?.rating, 8);
    expect(
        applied?.images.any((VideoMetadataImage image) =>
            image.kind == VideoMetadataImageKind.backdrop),
        isTrue);
    expect(tmdb.searchCalls, greaterThan(0));
  });

  for (final String incomplete in <String>[
    'empty seasons',
    'empty episodes',
    'partial episodes'
  ]) {
    test('MAL $incomplete keeps previously supplemented TMDB episode rows',
        () async {
      final SourceLibraryRow source = await _source(db, directory, count: 2);
      final SourceScrapeReport first = await scrape(
          coordinator(
              _EpisodeProvider(VideoMetadataProviderKind.mal, numbers: <int>[]),
              _EpisodeProvider(VideoMetadataProviderKind.tmdb,
                  numbers: <int>[1, 2, 3]),
              _HashService(enabled: false)),
          source);
      expect(first.succeededWorks, 1, reason: '${first.errors}');
      final int collectionId = (await db.getAllMediaCollections()).single.id;
      final VideoMetadataWorkRow stored =
          (await db.getVideoMetadataWorkByCollection(collectionId))!;
      final VideoMetadataSeasonRow initialSeason =
          (await db.getVideoMetadataSeasons(stored.id)).single;
      final List<VideoMetadataEpisodeRow> before =
          await db.getVideoMetadataEpisodes(initialSeason.id);
      expect(before.map((VideoMetadataEpisodeRow row) => row.episodeNumber),
          <int>[1, 2, 3]);
      expect(before.last.title, 'tmdb episode 3');

      final _EpisodeProvider mal = _EpisodeProvider(
          VideoMetadataProviderKind.mal,
          numbers: incomplete == 'partial episodes' ? <int>[1] : <int>[],
          emptySeasons: incomplete == 'empty seasons');
      final SourceScrapeReport second = await scrape(
          coordinator(mal, null, _HashService(enabled: false)), source);
      expect(second.succeededWorks, 1, reason: '${second.errors}');
      expect(
          second.warnings
              .map((SourceScrapeIssue issue) => issue.message)
              .join(),
          contains('MAL 季集资料不完整'));
      final VideoMetadataSeasonRow afterSeason =
          (await db.getVideoMetadataSeasons(stored.id)).single;
      final List<VideoMetadataEpisodeRow> after =
          await db.getVideoMetadataEpisodes(afterSeason.id);
      expect(after.map((VideoMetadataEpisodeRow row) => row.episodeNumber),
          <int>[1, 2, 3]);
      expect(after.last.id, before.last.id,
          reason:
              'The existing TMDB episode was retained, not deleted and reconstructed');
      expect(after.last.title, 'tmdb episode 3');
      if (incomplete == 'partial episodes') {
        expect(after.first.title, 'mal episode 1');
      }
    });
  }

  test(
      'manual MAL preview normalizes actual TV type despite unnumbered filename',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: 'Unknown');
    final List<VideoSourceScrapeConfirmationCandidate> results =
        await coordinator(
      _TvEpisodeProvider(),
      null,
      _HashService(enabled: false),
    ).searchManualCandidates(
            source: source, workTitle: 'Unknown', query: 'mal=42');
    expect(results.single.lookup.mediaKind, VideoMetadataMediaKind.tv);
    expect(results.single.work.kind, VideoMetadataMediaKind.tv);
  });

  test(
      'hash MAL TV mapping persists actual type without inventing file episode mapping',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: 'Unknown');
    final SourceScrapeReport report = await scrape(
        coordinator(_TvEpisodeProvider(), null,
            _HashService(results: <AnidbHashIdentityResult>[_matched()])),
        source);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    expect(work.mediaType, 'tv');
    final VideoMetadataSeasonRow season =
        (await db.getVideoMetadataSeasons(work.id)).single;
    final List<VideoMetadataEpisodeRow> episodes =
        await db.getVideoMetadataEpisodes(season.id);
    expect(
        episodes
            .map((VideoMetadataEpisodeRow episode) => episode.episodeNumber),
        <int>[1, 2]);
    expect(
        episodes.every(
            (VideoMetadataEpisodeRow episode) => episode.bookUid == null),
        isTrue,
        reason:
            'A filename without an episode number must not use the AniDB native S1 as a MAL episode mapping');
    expect(
        report.warnings.map((SourceScrapeIssue issue) => issue.message).join(),
        contains('episodeId=300; episodeNumber=S1'));
  });

  test(
      'hash mapping selects exact MAL ID despite unrelated filename and audits native episode',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: 'Unrelated filename');
    final _HashService hash =
        _HashService(results: <AnidbHashIdentityResult>[_matched()]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final List<String?> messages = <String?>[];
    final SourceScrapeReport report = await scrape(
        coordinator(mal, null, hash), source,
        progress: (VideoSourceScrapeProgress progress) =>
            messages.add(progress.message));
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(mal.searchCalls, 0);
    expect(mal.fetchedIds, contains('42'));
    expect(hash.calls, 1);
    expect(messages.whereType<String>().join(), contains('1 / 1 字节'));
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final List<VideoMetadataProviderIdentityRow> ids =
        await db.getVideoMetadataProviderIdentities(workId: work.id);
    expect(
        ids.any((VideoMetadataProviderIdentityRow id) =>
            id.provider == 'anidb' && id.externalId == '100' && !id.isPrimary),
        isTrue);
    final String audit =
        (await db.getVideoSourceScrapeRuns(sourceId: source.id))
            .single
            .summaryJson!;
    expect(audit, contains('fileId=200'));
    expect(audit, contains('animeId=100'));
    expect(audit, contains('episodeId=300'));
    expect(audit, contains('episodeNumber=S1'));
    expect(audit, contains('0123456789abcdef0123456789abcdef'));
  });

  test('hash audit records the actual alternate ED2K lookup that matched',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final SourceScrapeReport report = await scrape(
        coordinator(
            _Provider(VideoMetadataProviderKind.mal),
            null,
            _HashService(results: <AnidbHashIdentityResult>[
              _matched(matchedEd2k: 'ffffffffffffffffffffffffffffffff'),
            ])),
        source);
    expect(report.succeededWorks, 1);
    expect(report.warnings.single.message,
        contains('hash=ffffffffffffffffffffffffffffffff'));
    expect(report.warnings.single.message,
        isNot(contains('hash=0123456789abcdef')));
  });

  test(
      'positive hash without MAL mapping uses native titles without inventing cross-reference',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: 'Wrong filename');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final SourceScrapeReport report = await scrape(
        coordinator(
            mal,
            null,
            _HashService(
                results: <AnidbHashIdentityResult>[_matched(malIds: <int>{})])),
        source);
    expect(report.succeededWorks, 1);
    expect(mal.searchedTitles, contains('Show'));
    expect(mal.searchedTitles, isNot(contains('Wrong filename')));
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final List<VideoMetadataProviderIdentityRow> ids =
        await db.getVideoMetadataProviderIdentities(workId: work.id);
    expect(
        ids.any(
            (VideoMetadataProviderIdentityRow id) => id.provider == 'anidb'),
        isFalse);
    expect(report.warnings.single.message, contains('文件身份已确定，MAL 元数据映射未确定'));
  });

  test('hash mapping MAL outage falls back to strict native titles only',
      () async {
    final SourceLibraryRow source =
        await _source(db, directory, title: 'Wrong');
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal,
        failure: const VideoMetadataNetworkException('offline'));
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report = await scrape(
        coordinator(mal, tmdb,
            _HashService(results: <AnidbHashIdentityResult>[_matched()])),
        source);
    expect(report.succeededWorks, 1);
    expect(await _primaryProvider(db), 'tmdb');
    expect(tmdb.searchedTitles, contains('Show'));
    expect(tmdb.searchedTitles, isNot(contains('Wrong')));
  });

  test(
      'enabled hash without credentials does not hash and reports configuration gap',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _HashService hash = _HashService(configured: false);
    final SourceScrapeReport report = await scrape(
        coordinator(_Provider(VideoMetadataProviderKind.mal), null, hash),
        source);
    expect(report.succeededWorks, 1);
    expect(hash.calls, 0);
    expect(report.warnings.single.message, contains('哈希识别未执行'));
  });

  for (final bool mappingConflict in <bool>[false, true]) {
    test(
        'hash ${mappingConflict ? 'mapping ambiguity' : 'different anime'} requires confirmation',
        () async {
      final SourceLibraryRow source = await _source(db, directory, count: 2);
      final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
        _matched(malIds: mappingConflict ? <int>{42, 43} : <int>{42}),
        _matched(aid: mappingConflict ? 100 : 101),
      ]);
      final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
      final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
      final SourceScrapeReport report =
          await scrape(coordinator(mal, tmdb, hash), source);
      expect(report.pendingConfirmations, 1);
      expect(report.succeededWorks, 0);
      expect(hash.calls, 2);
      expect(mal.searchCalls, 0);
      expect(mal.fetchedIds, isEmpty);
      expect(tmdb.searchCalls, 0);
    });
  }

  test('hash cancellation terminates run before metadata lookup', () async {
    final SourceLibraryRow source = await _source(db, directory);
    final VideoSourceScrapeCancellationToken token =
        VideoSourceScrapeCancellationToken();
    final _HashService hash = _HashService(onIdentify: token.cancel);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    await expectLater(
        scrape(coordinator(mal, null, hash), source, token: token),
        throwsA(isA<VideoSourceScrapeCancelled>()));
    expect(mal.searchCalls, 0);
    expect(
        (await db.getVideoSourceScrapeRuns(sourceId: source.id)).single.status,
        'cancelled');
  });

  test('confirmed user MAL ID bypasses hash and never falls back on outage',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _HashService hash = _HashService();
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal,
        failure: const VideoMetadataNetworkException('offline'));
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report =
        await coordinator(mal, tmdb, hash).rescrapeWorkWithLookup(
      source: source,
      workTitle: 'Show',
      workStableKey: 'book:book-0',
      lookup: const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '42',
          mediaKind: VideoMetadataMediaKind.movie),
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(report.failedWorks, 1);
    expect(hash.calls, 0);
    expect(tmdb.searchCalls, 0);
  });

  test(
      'manual search uses typed TMDB identity and leaves numeric titles as search',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal, empty: true);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final VideoSourceScrapeCoordinator runner =
        coordinator(mal, tmdb, _HashService(enabled: false));
    final List<VideoSourceScrapeConfirmationCandidate> exact =
        await runner.searchManualCandidates(
            source: source, workTitle: 'Show', query: 'tmdb:movie=42');
    expect(exact.single.lookup.provider, VideoMetadataProviderKind.tmdb);
    expect(exact.single.lookup.mediaKind, VideoMetadataMediaKind.movie);
    expect(mal.searchCalls, 0);
    final List<VideoSourceScrapeConfirmationCandidate> searched = await runner
        .searchManualCandidates(source: source, workTitle: 'Show', query: '86');
    expect(searched.single.lookup.provider, VideoMetadataProviderKind.tmdb);
    expect(mal.searchedTitles, contains('86'));
    expect(tmdb.searchedTitles, contains('86'));
  });
}

Future<SourceLibraryRow> _source(FushiDatabase db, Directory root,
    {String title = 'Show', int count = 1}) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Source', mediaKind: 'video', rootPath: root.path, createdAt: 1));
  final int? collectionId = count > 1
      ? await db.createMediaCollection(title, collectionType: 'playlist')
      : null;
  for (int index = 0; index < count; index++) {
    final String name =
        count == 1 ? '$title.mkv' : '$title S01E0${index + 1}.mkv';
    final File file = File(p.join(root.path, name));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>('book-$index'),
        title: Value<String>(title),
        videoPath: Value<String>(file.path),
        sourceId: Value<int?>(sourceId)));
    if (collectionId != null) {
      await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
    }
  }
  await db.upsertVideoSourceScrapeSettings(
      VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          providerOverride: const Value<String?>('anidb'),
          writeNfo: const Value<bool>(false),
          writeImages: const Value<bool>(false),
          updatedAt: 1));
  return (await db.getMediaSourceById(sourceId))!;
}

AnidbHashIdentityResult _matched(
        {int aid = 100,
        Set<int> malIds = const <int>{42},
        String? matchedEd2k}) =>
    AnidbHashIdentityResult(
      status: AnidbHashIdentityStatus.matched,
      matchedEd2k: matchedEd2k,
      hash: AnidbEd2kHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          size: 1,
          modifiedAt: DateTime(2026),
          changedAt: DateTime(2026)),
      identity: AnidbFileIdentity(
          fileId: 200,
          animeId: aid,
          episodeId: 300,
          episodeNumber: 'S1',
          romajiTitle: 'Show',
          kanjiTitle: '',
          englishTitle: '',
          episodeTitle: 'Native special',
          episodeRomajiTitle: '',
          episodeKanjiTitle: ''),
      mapping: AnimeIdentityMappingResult(anidbId: aid, malIds: malIds),
    );

class _HashService extends AnidbHashIdentityService {
  _HashService(
      {bool enabled = true,
      this.configured = true,
      this.results = const <AnidbHashIdentityResult>[],
      this.onIdentify})
      : super(
            enabled: enabled,
            config: const AnidbUdpConfig(
                username: 'user',
                password: 'test',
                clientName: 'testclient',
                clientVersion: 1));
  final bool configured;
  final List<AnidbHashIdentityResult> results;
  final void Function()? onIdentify;
  int calls = 0;
  @override
  bool get isConfigured => configured;
  @override
  Future<AnidbHashIdentityResult> identifyFile(String path,
      {bool Function()? isCancelled,
      void Function(int, int)? onProgress}) async {
    final int index = calls++;
    onProgress?.call(1, 1);
    onIdentify?.call();
    return index < results.length
        ? results[index]
        : const AnidbHashIdentityResult(
            status: AnidbHashIdentityStatus.notFound);
  }
}

class _Provider implements VideoMetadataProvider {
  _Provider(this.providerKind,
      {this.empty = false, this.failure, this.missingBackdrop = false});
  @override
  final VideoMetadataProviderKind providerKind;
  final bool empty;
  final Exception? failure;
  final bool missingBackdrop;
  int searchCalls = 0;
  final List<String> searchedTitles = <String>[];
  final List<String> fetchedIds = <String>[];
  @override
  bool get isAvailable => true;
  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      VideoMetadataWork(
        provider: providerKind,
        kind: kind,
        title: 'Show',
        plot: '${providerKind.name} plot',
        rating: providerKind == VideoMetadataProviderKind.mal ? 8 : 6,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: providerKind.name, value: id, isDefault: true)
        ],
        credits: <VideoMetadataCredit>[
          VideoMetadataCredit(
              kind: VideoMetadataCreditKind.director,
              person: VideoMetadataPerson(name: 'Director')),
        ],
        images: <VideoMetadataImage>[
          VideoMetadataImage(
              kind: VideoMetadataImageKind.cover,
              url: 'https://example.com/poster.jpg',
              provider: providerKind),
          if (!missingBackdrop)
            VideoMetadataImage(
                kind: VideoMetadataImageKind.backdrop,
                url: 'https://example.com/backdrop.jpg',
                provider: providerKind),
        ],
      );
  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    searchedTitles.add(request.title);
    if (failure != null) throw failure!;
    return empty
        ? <VideoMetadataWork>[]
        : <VideoMetadataWork>[_work('42', request.mediaKind)];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    if (failure != null) throw failure!;
    return empty ? null : _work(lookup.externalId, lookup.mediaKind);
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

Future<String> _primaryProvider(FushiDatabase db) async {
  final VideoMetadataWorkRow work =
      (await db.getVideoMetadataWorkByBook('book-0'))!;
  return (await db.getVideoMetadataProviderIdentities(workId: work.id))
      .singleWhere((VideoMetadataProviderIdentityRow id) => id.isPrimary)
      .provider;
}

class _EpisodeProvider extends _Provider {
  _EpisodeProvider(super.providerKind,
      {required this.numbers, this.emptySeasons = false});
  final List<int> numbers;
  final bool emptySeasons;

  @override
  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      super._work(id, kind).copyWith(
          episodeCount: 3,
          seasons: emptySeasons
              ? <VideoMetadataSeason>[]
              : <VideoMetadataSeason>[
                  VideoMetadataSeason(
                      seasonNumber: 1, title: 'Show', episodeCount: 3),
                ]);

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      _work(lookup.externalId, lookup.mediaKind).seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      <VideoMetadataEpisode>[
        for (final int number in numbers)
          VideoMetadataEpisode(
              seasonNumber: seasonNumber,
              episodeNumber: number,
              title: '${providerKind.name} episode $number'),
      ];
}

class _TvEpisodeProvider extends _EpisodeProvider {
  _TvEpisodeProvider()
      : super(VideoMetadataProviderKind.mal, numbers: <int>[1, 2]);
  @override
  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      super._work(id, VideoMetadataMediaKind.tv);
}
