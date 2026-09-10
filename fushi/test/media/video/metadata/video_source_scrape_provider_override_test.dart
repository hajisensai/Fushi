import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_core/fushi_core.dart';

/// 来源级 `provider_override` 与全局主源偏好决定手动搜索链的顺序；历史值回落全局。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<SourceLibraryRow> seedSource({String? providerOverride}) async {
    final int sourceId =
        await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Anime',
      mediaKind: 'video',
      rootPath: r'D:\anime',
      createdAt: 1,
    ));
    if (providerOverride != null) {
      await db.upsertVideoSourceScrapeSettings(
        VideoSourceScrapeSettingsCompanion.insert(
          sourceId: Value<int>(sourceId),
          providerOverride: Value<String?>(providerOverride),
          updatedAt: 1,
        ),
      );
    }
    return (await db.getMediaSourceById(sourceId))!;
  }

  /// 手动搜索是「主源有候选就不再问兜底源」；这里只看谁被当成主源问了。
  Future<VideoMetadataProviderKind> manualSearchPrimary({
    required VideoMetadataProviderKind globalPrimary,
    String? providerOverride,
  }) async {
    final SourceLibraryRow source =
        await seedSource(providerOverride: providerOverride);
    final _RecordingProvider mal =
        _RecordingProvider(VideoMetadataProviderKind.mal);
    final _RecordingProvider tmdb =
        _RecordingProvider(VideoMetadataProviderKind.tmdb);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: VideoSourceScrapeGlobalConfig(primaryProvider: globalPrimary),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
    );
    addTearDown(coordinator.close);
    final List<VideoSourceScrapeConfirmationCandidate> candidates =
        await coordinator.searchManualCandidates(
      source: source,
      workTitle: 'Show',
      query: 'Show',
    );
    expect(candidates, isNotEmpty);
    final VideoMetadataProviderKind primary = candidates.first.lookup.provider;
    expect(
      candidates
          .map((VideoSourceScrapeConfirmationCandidate c) => c.lookup.provider),
      everyElement(primary),
    );
    final _RecordingProvider other =
        primary == VideoMetadataProviderKind.mal ? tmdb : mal;
    expect(other.searchCalls, 0,
        reason: 'the fallback source is only asked when the primary is empty');
    return primary;
  }

  test('primary provider defaults to the global preference', () async {
    expect(
      await manualSearchPrimary(globalPrimary: VideoMetadataProviderKind.tmdb),
      VideoMetadataProviderKind.tmdb,
    );
  });

  test('source override beats the global preference', () async {
    expect(
      await manualSearchPrimary(
        globalPrimary: VideoMetadataProviderKind.mal,
        providerOverride: 'tmdb',
      ),
      VideoMetadataProviderKind.tmdb,
    );
  });

  test('legacy override values fall back to the global preference', () async {
    expect(
      await manualSearchPrimary(
        globalPrimary: VideoMetadataProviderKind.mal,
        providerOverride: 'bangumi',
      ),
      VideoMetadataProviderKind.mal,
    );
  });

  test('manual identity input accepts either provider of the chain', () async {
    final SourceLibraryRow source = await seedSource(providerOverride: 'tmdb');
    final _RecordingProvider mal =
        _RecordingProvider(VideoMetadataProviderKind.mal);
    final _RecordingProvider tmdb =
        _RecordingProvider(VideoMetadataProviderKind.tmdb);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
    );
    addTearDown(coordinator.close);
    final List<VideoSourceScrapeConfirmationCandidate> byMal =
        await coordinator.searchManualCandidates(
      source: source,
      workTitle: 'Show',
      query: 'https://myanimelist.net/anime/52991',
    );
    expect(byMal.single.lookup.provider, VideoMetadataProviderKind.mal);
    expect(byMal.single.lookup.externalId, '52991');
    await expectLater(
      coordinator.searchManualCandidates(
        source: source,
        workTitle: 'Show',
        query: 'https://anidb.net/anime/1',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('config parses the primary provider preference safely', () {
    expect(
      parseSelectableVideoMetadataProvider('tmdb'),
      VideoMetadataProviderKind.tmdb,
    );
    expect(parseSelectableVideoMetadataProvider(' mal '),
        VideoMetadataProviderKind.mal);
    expect(parseSelectableVideoMetadataProvider('anidb'), isNull);
    expect(parseSelectableVideoMetadataProvider(''), isNull);
    expect(parseSelectableVideoMetadataProvider(null), isNull);
    expect(videoMetadataFallbackProvider(VideoMetadataProviderKind.mal),
        VideoMetadataProviderKind.tmdb);
    expect(videoMetadataFallbackProvider(VideoMetadataProviderKind.tmdb),
        VideoMetadataProviderKind.mal);
    expect(
        videoMetadataFallbackProvider(VideoMetadataProviderKind.anidb), isNull);
  });
}

class _RecordingProvider implements VideoMetadataProvider {
  _RecordingProvider(this.providerKind);

  @override
  final VideoMetadataProviderKind providerKind;
  int searchCalls = 0;

  @override
  bool get isAvailable => true;

  VideoMetadataWork _work(String id, VideoMetadataMediaKind kind) =>
      VideoMetadataWork(
        provider: providerKind,
        kind: kind,
        title: 'Show',
        ids: <VideoMetadataId>[
          VideoMetadataId(type: providerKind.name, value: id),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    searchCalls++;
    return <VideoMetadataWork>[_work('42', request.mediaKind)];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      _work(lookup.externalId, lookup.mediaKind);

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      const <VideoMetadataSeason>[];

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
          {required int seasonNumber}) async =>
      const <VideoMetadataEpisode>[];

  @override
  void close() {}
}
