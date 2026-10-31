import 'dart:io';

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
import 'package:path/path.dart' as p;

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
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Anime',
        mediaKind: 'video',
        rootPath: r'D:\anime',
        createdAt: 1,
      ),
    );
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
    final SourceLibraryRow source = await seedSource(
      providerOverride: providerOverride,
    );
    final _RecordingProvider mal = _RecordingProvider(
      VideoMetadataProviderKind.mal,
    );
    final _RecordingProvider tmdb = _RecordingProvider(
      VideoMetadataProviderKind.tmdb,
    );
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
          database: db,
          config: VideoSourceScrapeGlobalConfig(primaryProvider: globalPrimary),
          registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
            mal,
            tmdb,
          ]),
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
      candidates.map(
        (VideoSourceScrapeConfirmationCandidate c) => c.lookup.provider,
      ),
      everyElement(primary),
    );
    final _RecordingProvider other = primary == VideoMetadataProviderKind.mal
        ? tmdb
        : mal;
    expect(
      other.searchCalls,
      0,
      reason: 'the fallback source is only asked when the primary is empty',
    );
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
    final _RecordingProvider mal = _RecordingProvider(
      VideoMetadataProviderKind.mal,
    );
    final _RecordingProvider tmdb = _RecordingProvider(
      VideoMetadataProviderKind.tmdb,
    );
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
          database: db,
          config: const VideoSourceScrapeGlobalConfig(),
          registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
            mal,
            tmdb,
          ]),
        );
    addTearDown(coordinator.close);
    final List<VideoSourceScrapeConfirmationCandidate> byMal = await coordinator
        .searchManualCandidates(
          source: source,
          workTitle: 'Show',
          query: 'https://myanimelist.net/anime/52991',
        );
    expect(byMal.single.lookup.provider, VideoMetadataProviderKind.mal);
    expect(byMal.single.lookup.externalId, '52991');
    // AniDB 自 2026-09-20 起也是可选生产主源：其身份 URL 不再是格式错误，按
    // AniDB provider 直取；本 registry 没注册 AniDB → 空候选（不落到标题搜索）。
    expect(
      await coordinator.searchManualCandidates(
        source: source,
        workTitle: 'Show',
        query: 'https://anidb.net/anime/1',
      ),
      isEmpty,
    );
    expect(mal.searchCalls, 0);
    expect(tmdb.searchCalls, 0);
  });

  // CLI `video candidates --provider tmdb --type movie`：主源 MAL 明明有候选，
  // 显式指定的兜底源也必须真的被搜（旧实现只拿主源结果再按 provider 过滤，
  // 恒为空），且按指定形态搜而不是按来源计划猜的形态。
  test(
    'explicit provider and media kind search only that source and kind',
    () async {
      final SourceLibraryRow source = await seedSource();
      final _RecordingProvider mal = _RecordingProvider(
        VideoMetadataProviderKind.mal,
      );
      final _RecordingProvider tmdb = _RecordingProvider(
        VideoMetadataProviderKind.tmdb,
      );
      final VideoSourceScrapeCoordinator coordinator =
          VideoSourceScrapeCoordinator(
            database: db,
            config: const VideoSourceScrapeGlobalConfig(
              primaryProvider: VideoMetadataProviderKind.mal,
            ),
            registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
              mal,
              tmdb,
            ]),
          );
      addTearDown(coordinator.close);
      final List<VideoSourceScrapeConfirmationCandidate> candidates =
          await coordinator.searchManualCandidates(
            source: source,
            workTitle: 'Show',
            query: 'Show',
            provider: VideoMetadataProviderKind.tmdb,
            mediaKind: VideoMetadataMediaKind.movie,
          );
      expect(candidates, hasLength(1));
      expect(candidates.single.lookup.provider, VideoMetadataProviderKind.tmdb);
      expect(candidates.single.lookup.mediaKind, VideoMetadataMediaKind.movie);
      expect(mal.searchCalls, 0);
      expect(tmdb.searchedKinds, <VideoMetadataMediaKind>[
        VideoMetadataMediaKind.movie,
      ]);
    },
  );

  // 单文件剧场版 `Doraemon Movie 01 (1980)`：`01` 是剧场版序号不是集号。旧判据
  // 只看「解出了集号」就按剧搜，「Doraemon」于是唯一命中 TMDB 的 TV 本体并被自动
  // 绑上；文件名带电影关键词时必须按电影搜。
  test(
    'single-file work with a movie keyword is searched as a movie',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'fushi_movie_hint_',
      );
      addTearDown(() => root.delete(recursive: true));
      final Directory folder = Directory(
        p.join(root.path, '[Fabre-RAW] Doraemon Movie 01 (1980) [1080p]'),
      );
      await folder.create();
      final File file = File(
        p.join(folder.path, '[Fabre-RAW] Doraemon Movie 01 (1980) [1080p].mkv'),
      );
      await file.writeAsBytes(const <int>[0]);
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Movies',
          mediaKind: 'video',
          rootPath: root.path,
          createdAt: 1,
        ),
      );
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value<String>('movie01'),
          title: const Value<String>(
            '[Fabre-RAW] Doraemon Movie 01 (1980) [1080p]',
          ),
          videoPath: Value<String>(file.path),
          sourceId: Value<int?>(sourceId),
        ),
      );
      final SourceLibraryRow source = (await db.getMediaSourceById(sourceId))!;
      final _RecordingProvider tmdb = _RecordingProvider(
        VideoMetadataProviderKind.tmdb,
      );
      final VideoSourceScrapeCoordinator coordinator =
          VideoSourceScrapeCoordinator(
            database: db,
            config: const VideoSourceScrapeGlobalConfig(
              primaryProvider: VideoMetadataProviderKind.tmdb,
            ),
            registry: VideoMetadataProviderRegistry(<VideoMetadataProvider>[
              tmdb,
            ]),
          );
      addTearDown(coordinator.close);
      await coordinator.searchManualCandidates(
        source: source,
        workTitle: '[Fabre-RAW] Doraemon Movie 01 (1980) [1080p]',
        workStableKey: 'book:movie01',
        query: 'Doraemon',
      );
      expect(tmdb.searchedKinds, <VideoMetadataMediaKind>[
        VideoMetadataMediaKind.movie,
      ]);
    },
  );

  test('config parses the primary provider preference safely', () {
    expect(
      parseSelectableVideoMetadataProvider('tmdb'),
      VideoMetadataProviderKind.tmdb,
    );
    expect(
      parseSelectableVideoMetadataProvider(' mal '),
      VideoMetadataProviderKind.mal,
    );
    // 2026-09-20 起 AniDB 是可选主源（且为默认）；退役源仍不可选。
    expect(
      parseSelectableVideoMetadataProvider('anidb'),
      VideoMetadataProviderKind.anidb,
    );
    expect(parseSelectableVideoMetadataProvider('bangumi'), isNull);
    expect(parseSelectableVideoMetadataProvider(''), isNull);
    expect(parseSelectableVideoMetadataProvider(null), isNull);
    expect(
      kDefaultVideoMetadataPrimaryProvider,
      VideoMetadataProviderKind.anidb,
    );
    expect(
      const VideoSourceScrapeGlobalConfig().primaryProvider,
      VideoMetadataProviderKind.anidb,
    );
    expect(
      videoMetadataFallbackProvider(VideoMetadataProviderKind.mal),
      VideoMetadataProviderKind.tmdb,
    );
    expect(
      videoMetadataFallbackProvider(VideoMetadataProviderKind.tmdb),
      VideoMetadataProviderKind.mal,
    );
    // Shoko 形态：TMDB 恒为 AniDB 的补充 / 兜底；AniDB 主源下 MAL 只是交叉引用。
    expect(
      videoMetadataFallbackProvider(VideoMetadataProviderKind.anidb),
      VideoMetadataProviderKind.tmdb,
    );
    expect(
      videoMetadataFallbackProvider(VideoMetadataProviderKind.bangumi),
      isNull,
    );
  });
}

class _RecordingProvider implements VideoMetadataProvider {
  _RecordingProvider(this.providerKind);

  @override
  final VideoMetadataProviderKind providerKind;
  int searchCalls = 0;
  final List<VideoMetadataMediaKind> searchedKinds = <VideoMetadataMediaKind>[];

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
    VideoMetadataSearchRequest request,
  ) async {
    searchCalls++;
    searchedKinds.add(request.mediaKind);
    return <VideoMetadataWork>[_work('42', request.mediaKind)];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      _work(lookup.externalId, lookup.mediaKind);

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
