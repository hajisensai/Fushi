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
    bool grouped = true,
  }) async {
    final SourceLibraryRow source =
        await _source(db, directory, fileNames, grouped: grouped);
    if (hash != null) addTearDown(hash.close);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
      primaryProvider: VideoMetadataProviderKind.mal,
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

  /// 分集行上的 AniDB 交叉引用：(季, 集) → (eid, 原生集号, 评级)。
  Future<Map<(int, int), (int?, String?, String?)>> episodeXrefs() async {
    final MediaCollectionRow collection =
        (await db.getMediaCollectionByNaturalKey('Bleach', 'playlist'))!;
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collection.id))!;
    final Map<(int, int), (int?, String?, String?)> result =
        <(int, int), (int?, String?, String?)>{};
    for (final VideoMetadataSeasonRow season
        in await db.getVideoMetadataSeasons(work.id)) {
      for (final VideoMetadataEpisodeRow episode
          in await db.getVideoMetadataEpisodes(season.id)) {
        if (episode.anidbEpisodeId == null) continue;
        result[(season.seasonNumber, episode.episodeNumber)] = (
          episode.anidbEpisodeId,
          episode.anidbEpisodeNumber,
          episode.anidbMatchRating,
        );
      }
    }
    return result;
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
  // 都没有时，本地文件的 AniDB 集标题在 TMDB 里逐集核对，核对通过的文件直接
  // 落到对上的 TMDB 集（卡片里 TMDB 第 2 季是补充源整季并进来的）；文件名的
  // `S01E0x` 不算数。
  test(
      'without mapping offsets, AniDB episode titles verify against TMDB '
      'episodes and the files land on those TMDB episodes (Shoko path)',
      () async {
    const String fribbNoSeason = '['
        '{"anidb_id":19079,"mal_id":60636,"themoviedb_id":{"tv":30984},'
        '"type":"TV"}'
        ']';
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Bleach S01E01.mkv': _identity(1, 'The Calamity', 'Kashin', '禍進'),
      'Bleach S01E02.mkv': _identity(2, 'Ashes of the Quincy', '', ''),
      'Bleach S01E03.mkv': _identity(3, 'Totally Unrelated Title', '', ''),
    });
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
    expect(bound[(2, 41)]?.$1, 'book-0', reason: '标题核对 → TMDB S2E41');
    expect(bound[(2, 41)]?.$2, 'The Calamity');
    expect(bound[(2, 42)]?.$1, 'book-1');
    expect(bound[(2, 42)]?.$2, 'Ashes of the Quincy');
    expect(bound[(1, 1)]?.$1, isNull, reason: '文件名的 S01E01 不算数');
    // 第 3 集标题对不上：季被前两集锁到 S2，Shoko 第四遍把剩下的集按顺序落进
    // 锁定季里第一条还没被占的 TMDB 集（firstAvailable）并照样成链——本仓同样
    // 成链，但评级随行落库、说明里标「顺序兜底」，用户能看出这一集是猜的。
    expect(bound[(2, 43)]?.$1, 'book-2', reason: '顺序兜底 → TMDB S2E43');
    final Map<(int, int), (int?, String?, String?)> xrefs =
        await episodeXrefs();
    expect(xrefs[(2, 43)], (303, '03', 'firstAvailable'));
    expect(xrefs[(2, 41)], (301, '01', 'title'));
    expect(
      report.warnings.any((SourceScrapeIssue issue) =>
          issue.message.contains('AniDB 文件身份 → TMDB 集逐集链接') &&
          issue.message.contains('3 个文件对上') &&
          issue.message.contains('顺序兜底 1')),
      isTrue,
      reason: '${report.warnings.map((SourceScrapeIssue i) => i.message)}',
    );
  });

  test('adult content ratings (MAL Rx / AniDB R18+) open TMDB include_adult',
      () {
    expect(VideoSourceScrapeCoordinator.isAdultContentRating('Rx - Hentai'),
        isTrue);
    expect(VideoSourceScrapeCoordinator.isAdultContentRating('R18+'), isTrue);
    expect(
        VideoSourceScrapeCoordinator.isAdultContentRating('R+ - Mild Nudity'),
        isFalse);
    expect(
        VideoSourceScrapeCoordinator.isAdultContentRating(
            'R - 17+ (violence & profanity)'),
        isFalse);
    expect(VideoSourceScrapeCoordinator.isAdultContentRating(null), isFalse);
  });

  // Shoko 的识别链里文件名从不参与：文件落到哪一集由 AniDB 集（播出日 + 集
  // 标题）在 TMDB 剧里逐集对出来决定。文件名对的照旧，文件名错的按身份归位。
  test(
      'AniDB file identity (air date + title) decides the card episode over '
      'the filename, Shoko style', () async {
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    DateTime aired(int tmdbEpisode) =>
        DateTime.parse('${_TmdbProvider.tybwAirDate(tmdbEpisode)}T00:00:00Z');
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      // 文件名 S17E41 = cour 4 第 1 集，身份也是第 1 集：一致。
      'Bleach S17E41.mkv':
          _identity(1, 'The Calamity', 'Kashin', '禍進', airedAt: aired(41)),
      // 文件名写成 S17E12（cour 1 第 12 集），身份却是 cour 4 第 2 集
      //（标题 + 播出日都对 TMDB S2E42）：按身份归位到卡片第 5 季第 2 集。
      'Bleach S17E12.mkv':
          _identity(2, 'Ashes of the Quincy', '', '', airedAt: aired(42)),
      // 文件名 S17E44 = cour 4 第 4 集，身份第 4 集但只有日文集名（TMDB 只有
      // 英文）：靠播出日对上 S2E44（date 评级），一致。
      'Bleach S17E44.mkv': _identity(4, '', '', '灰の残響', airedAt: aired(44)),
      // 文件名写成 S00E02，身份是 AniDB 特典 S1「Special #1」：特典只在 TMDB
      // 第 0 季池里按标题对，落卡片 (0, 1) 而不是文件名的 (0, 2)。
      'Bleach S00E02.mkv': _special(1, 'Special #1'),
    });
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>[
        'Bleach S17E41.mkv',
        'Bleach S17E12.mkv',
        'Bleach S17E44.mkv',
        'Bleach S00E02.mkv',
      ],
      hash: hash,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    expect(bound[(5, 1)]?.$1, 'book-0');
    expect(bound[(5, 2)]?.$1, 'book-1', reason: '身份胜过文件名');
    expect(bound[(2, 12)]?.$1, isNull, reason: '不再按文件名落到 cour 1');
    expect(bound[(5, 4)]?.$1, 'book-2', reason: '仅播出日对上也够');
    expect(bound[(0, 1)]?.$1, 'book-3', reason: 'AniDB S1 → TMDB S0E1');
    expect(bound[(0, 2)]?.$1, isNull, reason: '文件名的 S00E02 不算数');
    // Shoko CrossRef_AniDB_TMDB_Episode 的落点：分集行带 AniDB eid / 原生集号 /
    // 链接评级，两套编号并存。
    final Map<(int, int), (int?, String?, String?)> xrefs =
        await episodeXrefs();
    expect(xrefs[(5, 1)], (301, '01', 'dateAndTitle'));
    expect(xrefs[(5, 2)], (302, '02', 'dateAndTitle'));
    expect(xrefs[(5, 4)], (304, '04', 'date'));
    expect(xrefs[(0, 1)], (391, 'S1', 'title'));
    expect(xrefs.containsKey((5, 3)), isFalse, reason: '没绑文件的集没有身份');
    final Iterable<String> messages =
        report.warnings.map((SourceScrapeIssue i) => i.message);
    expect(
      messages.any((String m) =>
          m.contains('Bleach S17E12.mkv') &&
          m.contains('第 2 季第 12 集') &&
          m.contains('第 5 季第 2 集') &&
          m.contains('按身份归位')),
      isTrue,
      reason: '$messages',
    );
    expect(
      messages.any((String m) =>
          m.contains('AniDB 文件身份 → TMDB 集逐集链接') &&
          m.contains('4 个文件对上') &&
          m.contains('2 个与文件名不符')),
      isTrue,
      reason: '$messages',
    );
    expect(
      messages.any((String m) => m.contains('aired=${_TmdbProvider.tybwAirDate(41)}')),
      isTrue,
      reason: '识别日志带播出日',
    );
  });

  // Shoko `CrossRef_AniDB_TMDB_Movie`：一个目录里两部剧场版，文件名带序号被计划
  // 器当成一个剧集单元；哈希说它们是两个不同的 AniDB 电影作品 → 拆成两部电影各
  // 自刮，而不是「成员分属不同作品，请拆分合集」悬着。
  test(
      'members hashed to different AniDB movie works split into one movie '
      'work per file (Shoko movie cross-reference)', () async {
    const String fribbMovies = '['
        '{"anidb_id":4835,"mal_id":9001,"themoviedb_id":{"movie":[31112]},'
        '"type":"MOVIE"},'
        '{"anidb_id":5586,"mal_id":9002,"themoviedb_id":{"movie":[31113]},'
        '"type":"MOVIE"}'
        ']';
    AnidbHashIdentityResult movie(int animeId, int malId, String title) =>
        AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: animeId,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: animeId * 10,
              animeId: animeId,
              episodeId: animeId * 100,
              episodeNumber: '1',
              romajiTitle: title,
              kanjiTitle: '',
              englishTitle: title,
              episodeTitle: 'Complete Movie',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping:
              AnimeIdentityMappingResult(anidbId: animeId, malIds: <int>{malId}),
        );
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Bleach Movie 01.mkv': movie(4835, 9001, 'Bleach: Memories of Nobody'),
      'Bleach Movie 02.mkv':
          movie(5586, 9002, 'Bleach: The DiamondDust Rebellion'),
    });
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>['Bleach Movie 01.mkv', 'Bleach Movie 02.mkv'],
      fribb: fribbMovies,
      hash: hash,
    );
    expect(report.pendingConfirmations, 0,
        reason: '不再是待确认：${report.warnings.map((i) => i.message)}');
    expect(report.succeededWorks, 2, reason: '${report.errors}');
    expect(await db.getMediaCollectionByNaturalKey('Bleach', 'playlist'), isNull,
        reason: '视频成员全被拆走 → 原播放列表整个删除（带墓碑，重扫不再按文件名重建）');
    expect(await db.hasCollectionDeletionTombstone('Bleach', 'playlist'), isTrue);
    final VideoMetadataWorkRow first =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final VideoMetadataWorkRow second =
        (await db.getVideoMetadataWorkByBook('book-1'))!;
    expect(first.mediaType, 'movie');
    expect(second.mediaType, 'movie');
    expect(first.title, 'Bleach: Memories of Nobody');
    expect(second.title, 'Bleach: The DiamondDust Rebellion');
    Future<Map<String, String>> identitiesOf(int workId) async => <String, String>{
          for (final VideoMetadataProviderIdentityRow row
              in await db.getVideoMetadataProviderIdentities(workId: workId))
            row.provider: row.externalId,
        };
    expect(await identitiesOf(first.id),
        containsPair('mal', '9001'));
    expect(await identitiesOf(first.id),
        containsPair('anidb', '4835'),
        reason: 'AniDB 作品 id 由哈希直接落库');
    expect(await identitiesOf(second.id), containsPair('mal', '9002'));
    expect(await identitiesOf(second.id), containsPair('anidb', '5586'));
    expect(
      report.warnings.any((SourceScrapeIssue i) =>
          i.message.contains('2 部不同作品') && i.message.contains('2 部电影')),
      isTrue,
      reason: '${report.warnings.map((i) => i.message)}',
    );
  });

  // Shoko `MatchRating.UserVerified`：用户手动钉死的季集最高优先级，AniDB 集级
  // 链接与文件名都不再动它，评级写 userVerified。
  test('a user-pinned episode binding wins over the AniDB episode link',
      () async {
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    DateTime aired(int tmdbEpisode) =>
        DateTime.parse('${_TmdbProvider.tybwAirDate(tmdbEpisode)}T00:00:00Z');
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Bleach S17E41.mkv':
          _identity(1, 'The Calamity', 'Kashin', '禍進', airedAt: aired(41)),
      // 身份说是第 2 集（会链到 S2E42 → 卡片 (5, 2)），用户钉死为第 5 季第 3 集。
      'Bleach S17E42.mkv':
          _identity(2, 'Ashes of the Quincy', '', '', airedAt: aired(42)),
    });
    // 先把成员书种出来，才能挂手动指定（FK）。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('book-1'),
      title: const Value<String>('Bleach'),
      videoPath: Value<String>(p.join(directory.path, 'Bleach S17E42.mkv')),
    ));
    await db.setVideoEpisodeBindingOverride('book-1',
        seasonNumber: 5, episodeNumber: 3);
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>['Bleach S17E41.mkv', 'Bleach S17E42.mkv'],
      hash: hash,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    expect(bound[(5, 1)]?.$1, 'book-0');
    expect(bound[(5, 3)]?.$1, 'book-1', reason: '手动指定胜过身份链接');
    expect(bound[(5, 2)]?.$1, isNull);
    final Map<(int, int), (int?, String?, String?)> xrefs =
        await episodeXrefs();
    expect(xrefs[(5, 3)], (302, '02', 'userVerified'),
        reason: 'AniDB 身份仍随文件记录，评级标 UserVerified');
    expect(
      report.warnings.any((SourceScrapeIssue i) =>
          i.message.contains('UserVerified') &&
          i.message.contains('Bleach S17E42.mkv') &&
          i.message.contains('第 5 季第 3 集')),
      isTrue,
      reason: '${report.warnings.map((i) => i.message)}',
    );
    expect(
      report.warnings.any((SourceScrapeIssue i) =>
          i.message.contains('Bleach S17E42.mkv') && i.message.contains('按身份归位')),
      isFalse,
      reason: '钉死的成员不再被自动链接归位',
    );
  });

  // Shoko 对 UserVerified：钉死成员的 AniDB 集退出来源池、钉到的 TMDB 集退出
  // 候选池——否则同单元里更靠前的自动链接成员照样链到用户钉死的那一格，落库
  // 先到先得时钉死静默丢失（警告里却写着「本轮不改」）。
  test('a user-pinned binding is not stolen by an earlier auto-linked member',
      () async {
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    DateTime aired(int tmdbEpisode) =>
        DateTime.parse('${_TmdbProvider.tybwAirDate(tmdbEpisode)}T00:00:00Z');
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      // 成员顺序在前，身份说是第 1 集 → 自动链接会落到 S2E41 → 卡片 (5, 1)。
      'Bleach S17E41.mkv':
          _identity(1, 'The Calamity', 'Kashin', '禍進', airedAt: aired(41)),
      // 用户把这个文件钉死为第 5 季第 1 集——正是上面那一格。
      'Bleach S17E42.mkv':
          _identity(2, 'Ashes of the Quincy', '', '', airedAt: aired(42)),
    });
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('book-1'),
      title: const Value<String>('Bleach'),
      videoPath: Value<String>(p.join(directory.path, 'Bleach S17E42.mkv')),
    ));
    await db.setVideoEpisodeBindingOverride('book-1',
        seasonNumber: 5, episodeNumber: 1);
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>['Bleach S17E41.mkv', 'Bleach S17E42.mkv'],
      hash: hash,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    expect(bound[(5, 1)]?.$1, 'book-1', reason: '钉死的格归钉死的文件');
    expect(
        bound.entries
            .where((MapEntry<(int, int), (String?, String?)> e) =>
                e.value.$1 == 'book-0')
            .map((MapEntry<(int, int), (String?, String?)> e) => e.key),
        isNot(contains((5, 1))),
        reason: '自动链接成员不得抢钉死的格');
    final Map<(int, int), (int?, String?, String?)> xrefs =
        await episodeXrefs();
    expect(xrefs[(5, 1)], (302, '02', 'userVerified'));
  });

  // Shoko 按 AniDB 作品建多个 series：同一播放列表里两部不同的电视剧（这里是
  // TYBW 第 1、2 cour，各自是独立 AniDB 作品）→ 拆成两个合集各自刮，原合集删除。
  test(
      'members hashed to different AniDB TV works split into one collection '
      'per work (Shoko multi-series)', () async {
    AnidbHashIdentityResult show(int animeId, int malId, String title, int epno) =>
        AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: animeId * 10 + epno,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: animeId * 10 + epno,
              animeId: animeId,
              episodeId: animeId * 100 + epno,
              episodeNumber: '0$epno',
              romajiTitle: title,
              kanjiTitle: '',
              englishTitle: title,
              animeType: 'TV Series',
              episodeTitle: '',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping:
              AnimeIdentityMappingResult(anidbId: animeId, malIds: <int>{malId}),
        );
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Bleach S17E01.mkv': show(15449, 41467, 'Bleach TYBW 1', 1),
      'Bleach S17E02.mkv': show(15449, 41467, 'Bleach TYBW 1', 2),
      'Bleach S17E14.mkv': show(17765, 53998, 'Bleach TYBW 2', 1),
    });
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>[
        'Bleach S17E01.mkv',
        'Bleach S17E02.mkv',
        'Bleach S17E14.mkv',
      ],
      hash: hash,
    );
    expect(report.pendingConfirmations, 0,
        reason: '${report.warnings.map((i) => i.message)}');
    expect(report.succeededWorks, 2, reason: '${report.errors}');
    expect(await db.getMediaCollectionByNaturalKey('Bleach', 'playlist'), isNull,
        reason: '原播放列表整删');
    final MediaCollectionRow first =
        (await db.getMediaCollectionByNaturalKey('Bleach TYBW 1', 'playlist'))!;
    final MediaCollectionRow second =
        (await db.getMediaCollectionByNaturalKey('Bleach TYBW 2', 'playlist'))!;
    expect(
        (await db.getCollectionItems(first.id))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-0', 'book-1']);
    expect(
        (await db.getCollectionItems(second.id))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-2']);
    final VideoMetadataWorkRow firstWork =
        (await db.getVideoMetadataWorkByCollection(first.id))!;
    final VideoMetadataWorkRow secondWork =
        (await db.getVideoMetadataWorkByCollection(second.id))!;
    expect(firstWork.mediaType, 'tv');
    expect(firstWork.title, 'Bleach TYBW 1');
    expect(secondWork.title, 'Bleach TYBW 2');
    Future<Map<String, String>> identitiesOf(int workId) async => <String, String>{
          for (final VideoMetadataProviderIdentityRow row
              in await db.getVideoMetadataProviderIdentities(workId: workId))
            row.provider: row.externalId,
        };
    expect(await identitiesOf(firstWork.id), containsPair('mal', '41467'));
    expect(await identitiesOf(firstWork.id), containsPair('anidb', '15449'));
    expect(await identitiesOf(secondWork.id), containsPair('mal', '53998'));
    expect(
      report.warnings.any((SourceScrapeIssue i) =>
          i.message.contains('2 部不同作品') && i.message.contains('2 个剧集合集')),
      isTrue,
      reason: '${report.warnings.map((i) => i.message)}',
    );
  });

  // BUG-2624 / Shoko `AnimeSeriesRepository.GetByAnimeID`：series 只按 aid 建一次、
  // 多文件复用。散在合集外的三个单文件单元哈希全指向同一部剧 → 合成一个播放列表
  // 合集剧集单元再刮，而不是三部「一集的电视剧」。
  test(
      'standalone files hashed to the same AniDB TV work merge into one '
      'collection unit (Shoko series by anime id)', () async {
    AnidbHashIdentityResult show(int epno) => AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: 154490 + epno,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: 154490 + epno,
              animeId: 15449,
              episodeId: 1544900 + epno,
              episodeNumber: '0$epno',
              romajiTitle: 'Bleach TYBW 1',
              kanjiTitle: '',
              englishTitle: 'Bleach TYBW 1',
              animeType: 'TV Series',
              episodeTitle: '',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping: AnimeIdentityMappingResult(
              anidbId: 15449, malIds: <int>{41467}),
        );
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      '[Group] Bleach TYBW [01][1080p].mkv': show(1),
      '[Group] Bleach TYBW [02][1080p].mkv': show(2),
      '[Group] Bleach TYBW [03][1080p].mkv': show(3),
    });
    expect(await db.getAllMediaCollections(), isEmpty);
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>[
        '[Group] Bleach TYBW [01][1080p].mkv',
        '[Group] Bleach TYBW [02][1080p].mkv',
        '[Group] Bleach TYBW [03][1080p].mkv',
      ],
      hash: hash,
      grouped: false,
    );
    expect(report.pendingConfirmations, 0,
        reason: '${report.warnings.map((i) => i.message)}');
    expect(report.succeededWorks, 1,
        reason: '三个文件是一部剧、一个单元：${report.errors}');
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.map((MediaCollectionRow c) => c.name),
        <String>['Bleach TYBW 1']);
    final MediaCollectionRow merged = collections.single;
    expect(merged.collectionType, 'playlist');
    expect(
        (await db.getCollectionItems(merged.id))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-0', 'book-1', 'book-2']);
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(merged.id))!;
    expect(work.mediaType, 'tv');
    expect(work.title, 'Bleach TYBW 1');
    final Map<String, String> identities = <String, String>{
      for (final VideoMetadataProviderIdentityRow row
          in await db.getVideoMetadataProviderIdentities(workId: work.id))
        row.provider: row.externalId,
    };
    expect(identities, containsPair('mal', '41467'));
    expect(identities, containsPair('anidb', '15449'));
    // 三个文件各自绑到 (季, 集)，而不是三份「一集的作品」。
    final Set<String> boundBooks = <String>{};
    for (final VideoMetadataSeasonRow season
        in await db.getVideoMetadataSeasons(work.id)) {
      for (final VideoMetadataEpisodeRow episode
          in await db.getVideoMetadataEpisodes(season.id)) {
        if (episode.bookUid case final String uid) boundBooks.add(uid);
      }
    }
    expect(boundBooks, <String>{'book-0', 'book-1', 'book-2'});
    expect(
      report.warnings.any((SourceScrapeIssue i) =>
          i.message.contains('3 个独立文件识别为同一部作品') &&
          i.message.contains('aid 15449')),
      isTrue,
      reason: '${report.warnings.map((i) => i.message)}',
    );
  });

  // 合并预处理与主循环同一优先级：已落库 / NFO / 路径显式 id 在哈希之前。用户手动
  // 确认过的散文件若被按哈希合进新合集，落库时 book 级作品行连同确认一起被删——
  // 哈希静默换掉手动指定的身份（PR #1594 审查）。
  test('a standalone file carrying an explicit path id is left out of the merge',
      () async {
    AnidbHashIdentityResult show(int epno) => AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: 154490 + epno,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: 154490 + epno,
              animeId: 15449,
              episodeId: 1544900 + epno,
              episodeNumber: '0$epno',
              romajiTitle: 'Bleach TYBW 1',
              kanjiTitle: '',
              englishTitle: 'Bleach TYBW 1',
              animeType: 'TV Series',
              episodeTitle: '',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping: AnimeIdentityMappingResult(
              anidbId: 15449, malIds: <int>{41467}),
        );
    // 第二个文件名里用户写死了另一部作品的 id（`[anidb-99999]`）。
    const String pinned = '[Group] Bleach TYBW [02][1080p] [anidb-99999].mkv';
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      '[Group] Bleach TYBW [01][1080p].mkv': show(1),
      pinned: show(2),
      '[Group] Bleach TYBW [03][1080p].mkv': show(3),
    });
    await scrape(
      _MalProvider(),
      _TmdbProvider(),
      fileNames: <String>[
        '[Group] Bleach TYBW [01][1080p].mkv',
        pinned,
        '[Group] Bleach TYBW [03][1080p].mkv',
      ],
      hash: hash,
      grouped: false,
    );
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.map((MediaCollectionRow c) => c.name),
        <String>['Bleach TYBW 1'],
        reason: '其余两个仍按哈希合并');
    expect(
        (await db.getCollectionItems(collections.single.id))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-0', 'book-2'],
        reason: '带显式 id 的文件不得被哈希拖进合集');
  });

  test('a standalone file with a stored primary identity is left out of the '
      'merge and keeps its work row', () async {
    AnidbHashIdentityResult show(int epno) => AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: 154490 + epno,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: 154490 + epno,
              animeId: 15449,
              episodeId: 1544900 + epno,
              episodeNumber: '0$epno',
              romajiTitle: 'Bleach TYBW 1',
              kanjiTitle: '',
              englishTitle: 'Bleach TYBW 1',
              animeType: 'TV Series',
              episodeTitle: '',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping: AnimeIdentityMappingResult(
              anidbId: 15449, malIds: <int>{41467}),
        );
    // book-1 此前被用户手动确认成另一部作品（MAL 999，isPrimary）。
    final int seededWorkId = await db.into(db.videoMetadataWorks).insert(
          VideoMetadataWorksCompanion.insert(
            bookUid: const Value<String?>('book-1'),
            mediaType: 'tv',
            title: 'User confirmed show',
            updatedAt: 1,
          ),
        );
    await db.into(db.videoMetadataProviderIdentities).insert(
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$seededWorkId:mal',
            workId: Value<int?>(seededWorkId),
            provider: 'mal',
            externalId: '999',
            isPrimary: const Value<bool>(true),
            updatedAt: 1,
          ),
        );
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      '[Group] Bleach TYBW [01][1080p].mkv': show(1),
      '[Group] Bleach TYBW [02][1080p].mkv': show(2),
      '[Group] Bleach TYBW [03][1080p].mkv': show(3),
    });
    await scrape(
      _MalProvider(),
      _TmdbProvider(),
      fileNames: <String>[
        '[Group] Bleach TYBW [01][1080p].mkv',
        '[Group] Bleach TYBW [02][1080p].mkv',
        '[Group] Bleach TYBW [03][1080p].mkv',
      ],
      hash: hash,
      grouped: false,
    );
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.map((MediaCollectionRow c) => c.name),
        <String>['Bleach TYBW 1']);
    expect(
        (await db.getCollectionItems(collections.single.id))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-0', 'book-2'],
        reason: '已有主身份的文件不得被哈希拖进合集');
    final VideoMetadataWorkRow? kept =
        await db.getVideoMetadataWorkByBook('book-1');
    expect(kept, isNotNull,
        reason: '用户确认过的 book 级作品行不得随合并被删');
    final Map<String, String> identities = <String, String>{
      for (final VideoMetadataProviderIdentityRow row
          in await db.getVideoMetadataProviderIdentities(workId: kept!.id))
        row.provider: row.externalId,
    };
    expect(identities, containsPair('mal', '999'));
  });

  // BUG-1739 的规矩：非用户显式的合集创建路径都要问删除墓碑。合并预处理每趟刮削
  // 都跑，不问墓碑就是「删除合集（保留条目）→ 下一趟又建回来」的死循环。
  test('a deleted (tombstoned) playlist of the same name is not rebuilt by '
      'the merge', () async {
    AnidbHashIdentityResult show(int epno) => AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: 154490 + epno,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: 154490 + epno,
              animeId: 15449,
              episodeId: 1544900 + epno,
              episodeNumber: '0$epno',
              romajiTitle: 'Bleach TYBW 1',
              kanjiTitle: '',
              englishTitle: 'Bleach TYBW 1',
              animeType: 'TV Series',
              episodeTitle: '',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping: AnimeIdentityMappingResult(
              anidbId: 15449, malIds: <int>{41467}),
        );
    await db.upsertCollectionMemberTombstone(
      collectionName: 'Bleach TYBW 1',
      collectionType: 'playlist',
      mediaType: FushiDatabase.collectionTombstoneSentinel,
      entryKey: FushiDatabase.collectionTombstoneSentinel,
      deletedAt: 1,
    );
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      '[Group] Bleach TYBW [01][1080p].mkv': show(1),
      '[Group] Bleach TYBW [02][1080p].mkv': show(2),
      '[Group] Bleach TYBW [03][1080p].mkv': show(3),
    });
    final SourceScrapeReport report = await scrape(
      _MalProvider(),
      _TmdbProvider(),
      fileNames: <String>[
        '[Group] Bleach TYBW [01][1080p].mkv',
        '[Group] Bleach TYBW [02][1080p].mkv',
        '[Group] Bleach TYBW [03][1080p].mkv',
      ],
      hash: hash,
      grouped: false,
    );
    expect(await db.getAllMediaCollections(), isEmpty,
        reason: '用户删过的合集不得被自动重建');
    expect(await db.hasCollectionDeletionTombstone('Bleach TYBW 1', 'playlist'),
        isTrue, reason: '墓碑不得被合并路径清掉');
    expect(
      report.warnings.any((SourceScrapeIssue i) =>
          i.message.contains('已被删除过') && i.message.contains('aid 15449')),
      isTrue,
      reason: '${report.warnings.map((i) => i.message)}',
    );
  });

  // 镜像的边界：电影一文件一作品（Shoko `CrossRef_AniDB_TMDB_Movie`），哪怕两个
  // 文件哈希同属一部 AniDB 电影（两个版本 / 重复文件）也不合成合集。
  test('standalone files hashed to the same AniDB movie work stay separate',
      () async {
    const String fribbMovie = '['
        '{"anidb_id":4835,"mal_id":9001,"themoviedb_id":{"movie":[31112]},'
        '"type":"MOVIE"}'
        ']';
    AnidbHashIdentityResult movie(int fileId) => AnidbHashIdentityResult(
          status: AnidbHashIdentityStatus.matched,
          hash: AnidbEd2kHash(
              ed2k: 'abcdef0123456789abcdef0123456789',
              size: fileId,
              modifiedAt: DateTime(2026),
              changedAt: DateTime(2026)),
          identity: AnidbFileIdentity(
              fileId: fileId,
              animeId: 4835,
              episodeId: 483500,
              episodeNumber: '1',
              romajiTitle: 'Bleach: Memories of Nobody',
              kanjiTitle: '',
              englishTitle: 'Bleach: Memories of Nobody',
              animeType: 'Movie',
              episodeTitle: 'Complete Movie',
              episodeRomajiTitle: '',
              episodeKanjiTitle: ''),
          mapping: AnimeIdentityMappingResult(
              anidbId: 4835, malIds: <int>{9001}),
        );
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      'Bleach Movie 01 [BD].mkv': movie(48351),
      'Bleach Movie 01 [WEB].mkv': movie(48352),
    });
    final SourceScrapeReport report = await scrape(
      _MalProvider(),
      _TmdbProvider(),
      fileNames: <String>['Bleach Movie 01 [BD].mkv', 'Bleach Movie 01 [WEB].mkv'],
      fribb: fribbMovie,
      hash: hash,
      grouped: false,
    );
    expect(report.succeededWorks, 2, reason: '${report.errors}');
    expect(await db.getAllMediaCollections(), isEmpty,
        reason: '电影不合成合集');
    expect((await db.getVideoMetadataWorkByBook('book-0'))!.mediaType, 'movie');
    expect((await db.getVideoMetadataWorkByBook('book-1'))!.mediaType, 'movie');
    expect(
      report.warnings.any(
          (SourceScrapeIssue i) => i.message.contains('识别为同一部作品')),
      isFalse,
    );
  });

  // Shoko `CrossRef_File_Episode`：一个文件覆盖两集（AniDB FILE other episodes）
  // → 两条分集行都绑到这一个文件，各带自己的 AniDB 身份与链接评级。
  test(
      'a multi-episode file (AniDB other episodes) binds to every linked '
      'card episode with its own xref', () async {
    final _MalProvider mal = _MalProvider();
    final _TmdbProvider tmdb = _TmdbProvider();
    DateTime aired(int tmdbEpisode) =>
        DateTime.parse('${_TmdbProvider.tybwAirDate(tmdbEpisode)}T00:00:00Z');
    final AnidbHashIdentityResult double =
        _identity(1, 'The Calamity', 'Kashin', '禍進', airedAt: aired(41));
    final _HashService hash = _HashService(<String, AnidbHashIdentityResult>{
      // 文件名只说 E41；FILE 说它还覆盖第 2 集（EPISODE 已答：集号 / 集名 /
      // 播出日），第 3 集只有 eid（EPISODE 没答）。
      'Bleach S17E41.mkv': AnidbHashIdentityResult(
        status: double.status,
        hash: double.hash,
        identity: double.identity!.copyWith(otherEpisodes: <AnidbEpisodeShare>[
          AnidbEpisodeShare(
              episodeId: 302,
              percentage: 40,
              episodeNumber: '02',
              airedAt: aired(42),
              englishTitle: 'Ashes of the Quincy'),
          const AnidbEpisodeShare(episodeId: 303, percentage: 20),
        ]),
        mapping: double.mapping,
      ),
      'Bleach S17E44.mkv': _identity(4, '', '', '灰の残響', airedAt: aired(44)),
    });
    final SourceScrapeReport report = await scrape(
      mal,
      tmdb,
      fileNames: <String>['Bleach S17E41.mkv', 'Bleach S17E44.mkv'],
      hash: hash,
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final Map<(int, int), (String?, String?)> bound = await boundEpisodes();
    expect(bound[(5, 1)]?.$1, 'book-0');
    expect(bound[(5, 2)]?.$1, 'book-0', reason: '同一文件再绑第 2 集');
    expect(bound[(5, 3)]?.$1, isNull, reason: 'EPISODE 没答的集不猜');
    expect(bound[(5, 4)]?.$1, 'book-1');
    final Map<(int, int), (int?, String?, String?)> xrefs =
        await episodeXrefs();
    expect(xrefs[(5, 1)], (301, '01', 'dateAndTitle'));
    expect(xrefs[(5, 2)], (302, '02', 'dateAndTitle'),
        reason: '额外绑定带的是那一集自己的 eid，不是主集的');
    expect(await db.getVideoMetadataEpisodesByBook('book-0'),
        hasLength(2));
    final Iterable<String> messages =
        report.warnings.map((SourceScrapeIssue i) => i.message);
    expect(
      messages.any((String m) =>
          m.contains('Bleach S17E41.mkv') &&
          m.contains('本文件还覆盖 AniDB 集 02') &&
          m.contains('第 5 季第 2 集') &&
          m.contains('同一文件再绑一集')),
      isTrue,
      reason: '$messages',
    );
    expect(
      messages.any((String m) =>
          m.contains('AniDB 文件身份 → TMDB 集逐集链接') &&
          m.contains('一文件多集额外绑定 1 条')),
      isTrue,
      reason: '$messages',
    );
  });
}

AnidbHashIdentityResult _identity(
        int epno, String english, String romaji, String kanji,
        {DateTime? airedAt}) =>
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
          episodeKanjiTitle: kanji,
          episodeAiredAt: airedAt),
      mapping: AnimeIdentityMappingResult(anidbId: 19079, malIds: <int>{60636}),
    );

/// 按文件名给身份（协调器按路径顺序哈希，不能靠调用次序对号）。
/// AniDB `S` 型特典身份（epno `S<n>`），只有英文集名、无播出日。
AnidbHashIdentityResult _special(int number, String english) =>
    AnidbHashIdentityResult(
      status: AnidbHashIdentityStatus.matched,
      hash: AnidbEd2kHash(
          ed2k: '0123456789abcdef0123456789abcdef',
          size: 900 + number,
          modifiedAt: DateTime(2026),
          changedAt: DateTime(2026)),
      identity: AnidbFileIdentity(
          fileId: 4900 + number,
          animeId: 19079,
          episodeId: 390 + number,
          episodeNumber: 'S$number',
          romajiTitle: 'Bleach: Sennen Kessen-hen - Kashin-tan',
          kanjiTitle: 'BLEACH 千年血戦篇-禍進譚-',
          englishTitle: '',
          episodeTitle: english,
          episodeRomajiTitle: '',
          episodeKanjiTitle: ''),
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
  final Map<String, AnidbHashIdentityResult> results;
  @override
  bool get isConfigured => true;
  @override
  Future<AnidbHashIdentityResult> identifyFile(String path,
      {bool Function()? isCancelled,
      void Function(int, int)? onProgress}) async =>
      results[p.basename(path)] ??
      const AnidbHashIdentityResult(status: AnidbHashIdentityStatus.notFound);
}

/// [grouped] = false：文件只入库、不进任何合集（每个文件是独立的 `book:` 单元，
/// 计划器不会把它们当剧集）——合并用例要的就是这种散文件形态。
Future<SourceLibraryRow> _source(
  FushiDatabase db,
  Directory root,
  List<String> fileNames, {
  bool grouped = true,
}) async {
  final int sourceId = await db.insertMediaSource(MediaSourcesCompanion.insert(
    label: 'Source',
    mediaKind: 'video',
    rootPath: root.path,
    createdAt: 1,
  ));
  final int? collectionId = grouped
      ? await db.createMediaCollection('Bleach', collectionType: 'playlist')
      : null;
  for (int index = 0; index < fileNames.length; index++) {
    final File file = File(p.join(root.path, fileNames[index]));
    await file.writeAsBytes(<int>[0]);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value<String>('book-$index'),
      title: Value<String>(
          grouped ? 'Bleach' : p.basenameWithoutExtension(fileNames[index])),
      videoPath: Value<String>(file.path),
      sourceId: Value<int?>(sourceId),
    ));
    if (collectionId != null) {
      await db.addToCollection(collectionId, MediaKind.video, 'book-$index');
    }
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

  /// 两部剧场版（电影型作品拆分测试用）。
  static const Map<String, String> _movies = <String, String>{
    '9001': 'Bleach: Memories of Nobody',
    '9002': 'Bleach: The DiamondDust Rebellion',
  };

  VideoMetadataWork? _work(String id) {
    if (_movies[id] case final String movieTitle) {
      return VideoMetadataWork(
        provider: providerKind,
        kind: VideoMetadataMediaKind.movie,
        title: movieTitle,
        ids: <VideoMetadataId>[
          VideoMetadataId(type: 'mal', value: id, isDefault: true),
        ],
      );
    }
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
          airDate: seasonNumber == 2 ? tybwAirDate(number) : null,
          ids: <VideoMetadataId>[
            VideoMetadataId(
                type: 'tmdb', value: '${seasonNumber * 1000 + number}'),
          ],
        ),
    ];
  }

  /// 第 2 季逐周播出：第 n 集 = 2025-10-04 起第 n−1 周（`yyyy-MM-dd`）。
  static String tybwAirDate(int number) {
    final DateTime date =
        DateTime.utc(2025, 10, 4).add(Duration(days: 7 * (number - 1)));
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  @override
  void close() {}
}
