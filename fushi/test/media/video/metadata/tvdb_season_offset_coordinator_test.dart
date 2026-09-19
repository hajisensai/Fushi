import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anime_identity_mapping.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// BUG-2593：Sonarr / Plex 式 `Season NN` 目录用的是 TVDB 季号，一个 TVDB 季常
/// 装着多个 MAL cour。数据形状照 Bleach 千年血战篇真实条目（Fribb）：四个 cour
/// 都是 tvdb S17（tmdb S2），偏移 0 / 13 / 26 / 40；末 cour（MAL 60636）播出中，
/// Jikan 既没给集数也没给分集。旧逻辑把「同剧条目序号」当本地季号，`S17E41`
/// 报「第 17 季超出该剧已知的 5 季」，8 个文件一集都挂不上。
const String _fribb = '['
    '{"anidb_id":2369,"mal_id":269,"themoviedb_id":{"tv":30984},'
    '"season":{"tmdb":1},"type":"TV"},'
    '{"anidb_id":15449,"mal_id":41467,"themoviedb_id":{"tv":30984},'
    '"season":{"tvdb":17,"tmdb":2},"type":"TV"},'
    '{"anidb_id":17765,"mal_id":53998,"themoviedb_id":{"tv":30984},'
    '"season":{"tvdb":17,"tmdb":2},"episode_offset":{"tvdb":13,"tmdb":13},'
    '"type":"TV"},'
    '{"anidb_id":18220,"mal_id":56784,"themoviedb_id":{"tv":30984},'
    '"season":{"tvdb":17,"tmdb":2},"episode_offset":{"tvdb":26,"tmdb":26},'
    '"type":"TV"},'
    '{"anidb_id":19079,"mal_id":60636,"themoviedb_id":{"tv":30984},'
    '"season":{"tvdb":17,"tmdb":2},"episode_offset":{"tvdb":40,"tmdb":40},'
    '"type":"TV"}'
    ']';

void main() {
  late FushiDatabase db;
  late Directory directory;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('bleach-lib-');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<SourceScrapeReport> scrape(
    _MalProvider mal,
    _TmdbProvider tmdb, {
    required List<String> fileNames,
    String fribb = _fribb,
    _HashService? hash,
  }) async {
    final SourceLibraryRow source = await _source(db, directory, fileNames);
    if (hash != null) addTearDown(hash.close);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      hashIdentityService: hash,
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
      identityMapping: AnimeIdentityMapping(
        httpClient: VideoMetadataHttpClient(
          client: MockClient((_) async => http.Response(fribb, 200)),
        ),
      ),
    );
    addTearDown(coordinator.close);
    return coordinator.scrapeSource(
      source,
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
  }

  Future<Map<(int, int), (String?, String?)>> boundEpisodes() async {
    final MediaCollectionRow collection =
        (await db.getMediaCollectionByNaturalKey('Bleach', 'playlist'))!;
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collection.id))!;
    final Map<(int, int), (String?, String?)> result =
        <(int, int), (String?, String?)>{};
    for (final VideoMetadataSeasonRow season
        in await db.getVideoMetadataSeasons(work.id)) {
      for (final VideoMetadataEpisodeRow episode
          in await db.getVideoMetadataEpisodes(season.id)) {
        result[(season.seasonNumber, episode.episodeNumber)] =
            (episode.bookUid, episode.title);
      }
    }
    return result;
  }

  test(
      'TVDB season + episode offset resolve a shared season into its MAL cour '
      'and TMDB fills the cour that MAL has no episodes for', () async {
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final SourceScrapeReport report =
        await scrape(mal, tmdb, fileNames: <String>[
      'Bleach S17E41.mkv',
      'Bleach S17E42.mkv',
      'Bleach S17E14.mkv',
    ]);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(
      report.warnings.map((SourceScrapeIssue issue) => issue.message),
      isNot(contains(contains('超出该剧已知'))),
    );
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    // 末 cour 是第 5 个条目 → 卡片第 5 季；S17E41 = 该 cour 第 1 集。
    expect(bound[(5, 1)]?.$1, 'book-0');
    expect(bound[(5, 2)]?.$1, 'book-1');
    // MAL 没给分集，分集行来自 TMDB 第 2 季第 41/42 集的切片。
    expect(bound[(5, 1)]?.$2, 'The Calamity');
    expect(bound[(5, 2)]?.$2, 'Ashes of the Quincy');
    // S17E14 = 第二个 cour（偏移 13）的第 1 集，该 cour 自己的 MAL 分集优先。
    expect(bound[(3, 1)]?.$1, 'book-2');
    expect(bound[(3, 1)]?.$2, 'Bleach TYBW 2 #1');
    expect(bound.keys.where(((int, int) key) => key.$1 == 3), hasLength(13),
        reason: 'cour 2 只有自己的 13 集，不吞 TMDB 第 2 季其余的集');
    expect(bound.keys.where(((int, int) key) => key.$1 == 5), hasLength(8),
        reason: '末 cour 到季末为止：TMDB 第 2 季共 48 集，切出 41–48');
    expect(bound[(17, 41)], isNull, reason: '不再按本地季号 17 落一季');
  });

  test(
      'an episode past every known cour of that TVDB season is left for '
      'manual confirmation, not mapped by entry index', () async {
    final _MalProvider mal = _MalProvider(lastCourEpisodes: 8);
    final _TmdbProvider tmdb = _TmdbProvider();
    final SourceScrapeReport report =
        await scrape(mal, tmdb, fileNames: <String>[
      'Bleach S17E41.mkv',
      'Bleach S17E60.mkv',
    ]);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    expect(bound[(5, 1)]?.$1, 'book-0');
    expect(bound.values.map(((String?, String?) v) => v.$1),
        isNot(contains('book-1')));
    expect(
      report.warnings.any((SourceScrapeIssue issue) =>
          issue.message.contains('第 17 季第 60 集不在跨站映射表')),
      isTrue,
      reason: '${report.warnings.map((SourceScrapeIssue i) => i.message)}',
    );
  });

  // Shoko 主路径（`MatchAnidbToTmdbEpisodes`）：映射表没给季/偏移、MAL 又一集
  // 都没有时，用本地文件 AniDB 身份里的集标题在 TMDB 里逐集核对，核对通过的
  // 按 AniDB 集号落集。
  test(
      'without mapping offsets, AniDB episode titles verify against TMDB '
      'episodes and land under the AniDB episode number (Shoko path)',
      () async {
    const String fribbNoSeason = '['
        '{"anidb_id":19079,"mal_id":60636,"themoviedb_id":{"tv":30984},'
        '"type":"TV"}'
        ']';
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final _HashService hash = _HashService(<AnidbHashIdentityResult>[
      _identity(1, 'The Calamity', 'Kashin', '禍進'),
      _identity(2, 'Ashes of the Quincy', '', ''),
      _identity(3, 'Totally Unrelated Title', '', ''),
    ]);
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>[
        'Bleach S01E01.mkv',
        'Bleach S01E02.mkv',
        'Bleach S01E03.mkv',
      ],
      fribb: fribbNoSeason,
      hash: hash,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    expect(bound[(1, 1)]?.$1, 'book-0');
    expect(bound[(1, 1)]?.$2, 'The Calamity', reason: '标题核对 → TMDB S2E41');
    expect(bound[(1, 2)]?.$1, 'book-1');
    expect(bound[(1, 2)]?.$2, 'Ashes of the Quincy');
    // 第 3 集标题对不上：季已被前两集锁到 S2，顺序兜底到 S2E43。
    expect(bound[(1, 3)]?.$1, 'book-2');
    expect(bound[(1, 3)]?.$2, 'TYBW #43');
    expect(
      report.warnings.any((SourceScrapeIssue issue) =>
          issue.message.contains('按 AniDB 文件身份的集标题') &&
          issue.message.contains('对上 3 集')),
      isTrue,
      reason: '${report.warnings.map((SourceScrapeIssue i) => i.message)}',
    );
  });
}

AnidbHashIdentityResult _identity(
        int epno, String english, String romaji, String kanji) =>
    AnidbHashIdentityResult(
      status: AnidbHashIdentityStatus.matched,
      hash: AnidbEd2kHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          size: epno,
          modifiedAt: DateTime(2026),
          changedAt: DateTime(2026)),
      identity: AnidbFileIdentity(
          fileId: 4000 + epno,
          animeId: 19079,
          episodeId: 300 + epno,
          episodeNumber: '0$epno',
          romajiTitle: 'Bleach: Sennen Kessen-hen - Kashin-tan',
          kanjiTitle: 'BLEACH 千年血戦篇-禍進譚-',
          englishTitle: '',
          episodeTitle: english,
          episodeRomajiTitle: romaji,
          episodeKanjiTitle: kanji),
      mapping: AnimeIdentityMappingResult(anidbId: 19079, malIds: <int>{60636}),
    );

class _HashService extends AnidbHashIdentityService {
  _HashService(this.results)
      : super(
            enabled: true,
            config: const AnidbUdpConfig(
                username: 'user',
                password: 'test',
                clientName: 'testclient',
                clientVersion: 1));
  final List<AnidbHashIdentityResult> results;
  int calls = 0;
  @override
  bool get isConfigured => true;
  @override
  Future<AnidbHashIdentityResult> identifyFile(String path,
      {bool Function()? isCancelled,
      void Function(int, int)? onProgress}) async {
    final int index = calls++;
    return index < results.length
        ? results[index]
        : const AnidbHashIdentityResult(
            status: AnidbHashIdentityStatus.notFound);
  }
}

Future<SourceLibraryRow> _source(
  FushiDatabase db,
  Directory root,
  List<String> fileNames,
) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
    label: 'Source',
    mediaKind: 'video',
    rootPath: root.path,
    createdAt: 1,
  ));
  final int collectionId =
      await db.createMediaCollection('Bleach', collectionType: 'playlist');
  for (int index = 0; index < fileNames.length; index++) {
    final File file = File(p.join(root.path, fileNames[index]));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value<String>('book-$index'),
      title: const Value<String>('Bleach'),
      videoPath: Value<String>(file.path),
      sourceId: Value<int?>(sourceId),
    ));
    await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
  }
  await db.upsertVideoSourceScrapeSettings(
    VideoSourceScrapeSettingsCompanion.insert(
      sourceId: Value<int>(sourceId),
      writeNfo: const Value<bool>(false),
      writeImages: const Value<bool>(false),
      updatedAt: 1,
    ),
  );
  return (await db.getMediaSourceById(sourceId))!;
}

/// MAL 假源：末 cour 60636 播出中——集数 [lastCourEpisodes]（默认 null =
/// Jikan 还没给）且分集为空；标题搜索直接回末 cour（本地标题就是它）。
class _MalProvider implements VideoMetadataProvider {
  _MalProvider({this.lastCourEpisodes});
  final int? lastCourEpisodes;
  final List<String> fetchedIds = <String>[];

  static const Map<String, (String, int?)> _entries = <String, (String, int?)>{
    '269': ('Bleach', 366),
    '41467': ('Bleach TYBW 1', 13),
    '53998': ('Bleach TYBW 2', 13),
    '56784': ('Bleach TYBW 3', 14),
  };

  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.mal;

  @override
  bool get isAvailable => true;

  (String, int?)? _entry(String id) =>
      id == '60636' ? ('Bleach TYBW 4', lastCourEpisodes) : _entries[id];

  VideoMetadataWork? _work(String id) {
    final (String, int?)? entry = _entry(id);
    if (entry == null) return null;
    return VideoMetadataWork(
      provider: providerKind,
      kind: VideoMetadataMediaKind.tv,
      title: entry.$1,
      aliases: const <String>['Bleach'],
      episodeCount: entry.$2,
      ids: <VideoMetadataId>[
        VideoMetadataId(type: 'mal', value: id, isDefault: true),
      ],
    );
  }

  @override
  Future<List<VideoMetadataWork>> search(
      VideoMetadataSearchRequest request) async {
    return <VideoMetadataWork>[_work('60636')!];
  }

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async {
    fetchedIds.add(lookup.externalId);
    return _work(lookup.externalId);
  }

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
      VideoMetadataLookup lookup) async {
    final VideoMetadataWork? work = _work(lookup.externalId);
    if (work == null) return const <VideoMetadataSeason>[];
    return <VideoMetadataSeason>[
      VideoMetadataSeason(
        seasonNumber: 1,
        title: work.title,
        episodeCount: work.episodeCount,
        ids: work.ids,
      ),
    ];
  }

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
      {required int seasonNumber}) async {
    final (String, int?)? entry = _entry(lookup.externalId);
    if (entry == null || seasonNumber != 1 || lookup.externalId == '60636') {
      return const <VideoMetadataEpisode>[];
    }
    return <VideoMetadataEpisode>[
      for (int number = 1; number <= entry.$2!; number++)
        VideoMetadataEpisode(
          seasonNumber: 1,
          episodeNumber: number,
          absoluteNumber: number,
          title: '${entry.$1} #$number',
        ),
    ];
  }

  @override
  void close() {}
}

/// TMDB 假源：30984 = 第 0 季 2 集特典、第 1 季 366 集（不展开）、第 2 季
/// 千年血战篇 48 集。
class _TmdbProvider implements VideoMetadataProvider {
  @override
  VideoMetadataProviderKind get providerKind => VideoMetadataProviderKind.tmdb;

  @override
  bool get isAvailable => true;

  static const List<(int, String, int)> _seasons = <(int, String, int)>[
    (0, 'Specials', 2),
    (1, 'Bleach', 366),
    (2, 'Thousand-Year Blood War', 48),
  ];

  VideoMetadataWork get _work => VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.tv,
        title: 'Bleach',
        plot: 'TMDB overview',
        ids: const <VideoMetadataId>[
          VideoMetadataId(type: 'tmdb', value: '30984', isDefault: true),
        ],
        seasons: <VideoMetadataSeason>[
          for (final (int number, String title, int count) in _seasons)
            VideoMetadataSeason(
              seasonNumber: number,
              title: title,
              episodeCount: count,
            ),
        ],
      );

  @override
  Future<List<VideoMetadataWork>> search(
          VideoMetadataSearchRequest request) async =>
      <VideoMetadataWork>[_work];

  @override
  Future<VideoMetadataWork?> fetchWork(VideoMetadataLookup lookup) async =>
      lookup.externalId == '30984' ? _work : null;

  @override
  Future<List<VideoMetadataSeason>> fetchSeasons(
          VideoMetadataLookup lookup) async =>
      _work.seasons;

  @override
  Future<List<VideoMetadataEpisode>> fetchEpisodes(VideoMetadataLookup lookup,
      {required int seasonNumber}) async {
    // 第 1 季 366 集不展开：本测试只关心第 2 季切片。
    if (seasonNumber == 1) return const <VideoMetadataEpisode>[];
    final int count =
        _seasons.firstWhere(((int, String, int) s) => s.$1 == seasonNumber).$3;
    return <VideoMetadataEpisode>[
      for (int number = 1; number <= count; number++)
        VideoMetadataEpisode(
          seasonNumber: seasonNumber,
          episodeNumber: number,
          title: switch ((seasonNumber, number)) {
            (2, 41) => 'The Calamity',
            (2, 42) => 'Ashes of the Quincy',
            (2, _) => 'TYBW #$number',
            _ => 'Special #$number',
          },
        ),
    ];
  }

  @override
  void close() {}
}
