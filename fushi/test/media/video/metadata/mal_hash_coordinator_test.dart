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
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_transport.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
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
      // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
      primaryProvider: VideoMetadataProviderKind.mal,
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
    // 哈希关着不再静默：一批只提一条「已关闭」，让排障分得清没开与没配好。
    expect(report.warnings.map((SourceScrapeIssue w) => w.message),
        <String>['AniDB 哈希识别已关闭（设置 → 在线服务 → AniDB），本批只按标题识别。']);
  });

  // 2026-09-20 起 AniDB 是可选的生产主源（且为默认）：库里 / NFO 里既有的
  // AniDB 主身份不再是「退役源、需按 MAL 重识别」，而是有效的规范绑定——来源
  // 选 MAL 也不换源（「手动指定的身份不得静默换源」），由仍注册的 AniDB provider
  // 续刮；它带的 TMDB 交叉引用按 TMDB 补充路径取，不升格为主身份。
  for (final String legacy in <String>['database', 'nfo', 'both']) {
    test(
        'existing AniDB primary in $legacy stays canonical under a MAL source and keeps TMDB as supplement',
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
              plot: 'Old plot',
            ));
      }
      final File nfo = File(p.join(directory.path, 'Show.nfo'));
      const String legacyNfo =
          '<movie><title>Old work</title><plot>Old plot</plot>'
          '<uniqueid type="anidb" default="true">100</uniqueid>'
          '<uniqueid type="tmdb">99</uniqueid></movie>';
      if (legacy != 'database') await nfo.writeAsString(legacyNfo);
      final _Provider anidb = _Provider(VideoMetadataProviderKind.anidb);
      final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
      final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
      final VideoSourceScrapeCoordinator runner = VideoSourceScrapeCoordinator(
        primaryProvider: VideoMetadataProviderKind.mal,
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
        hashIdentityService: _HashService(enabled: false),
        registry: VideoMetadataProviderRegistry(
            <VideoMetadataProvider>[anidb, mal, tmdb]),
      );
      final SourceScrapeReport report = await scrape(runner, source);
      expect(report.succeededWorks, 1, reason: '${report.errors}');
      expect(mal.searchCalls, 0, reason: '已有身份不重识别');
      expect(mal.fetchedIds, isEmpty);
      expect(anidb.fetchedIds, <String>['100']);
      expect(await _primaryProvider(db), 'anidb');
      final VideoMetadataWorkRow stored =
          (await db.getVideoMetadataWorkByBook('book-0'))!;
      final List<VideoMetadataProviderIdentityRow> ids =
          await db.getVideoMetadataProviderIdentities(workId: stored.id);
      expect(
          ids.any((VideoMetadataProviderIdentityRow id) =>
              id.provider == 'tmdb' && id.isPrimary),
          isFalse,
          reason: 'TMDB 交叉引用不升格为主身份');
      if (legacy != 'database') {
        expect(await nfo.readAsString(), legacyNfo);
        expect(
            report.warnings
                .map((SourceScrapeIssue issue) => issue.message)
                .join(),
            isNot(contains('旧资料源')));
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
      // 本用例测的是 MAL 主源形态（2026-09-20 起默认主源是 AniDB，MAL 仍可选）。
      primaryProvider: VideoMetadataProviderKind.mal,
      database: db,
      // 资料语言显式写死 zh-CN：本用例测的是「简介语言感知」，它**只在资料语言
      // 不是英语时**才有可观察行为（MAL 简介恒英文）。以前这里吃全局默认值，
      // 而那个默认值恰好是 zh-CN——语言默认值改成跟随界面语言后，这种隐式依赖
      // 会让用例静默失去意义（英语下 MAL 简介本就匹配首选语言，不会被替换）。
      config: const VideoSourceScrapeGlobalConfig(locale: 'zh-CN'),
      hashIdentityService: hash,
      registry:
          VideoMetadataProviderRegistry(<VideoMetadataProvider>[mal, tmdb]),
      onWorkScraped: (VideoScrapedWorkNotice notice) async {
        applied = notice.metadata;
      },
    );
    expect((await scrape(runner, source)).succeededWorks, 1);
    expect(applied?.provider, VideoMetadataProviderKind.mal);
    // 简介语言感知（设计稿 A3）：本用例刮削语言 zh-CN，MAL 简介恒英文、TMDB 简介
    // 按 zh-CN 返回 → 简介取 TMDB；评分等其它标量仍是主源 MAL 独占。
    expect(applied?.plot, 'tmdb plot');
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

  // 对齐 Shoko（BUG-2586）：文件哈希已经百分百确定作品是 AniDB 100，这个身份
  // 由哈希直接成立、照样落库；缺的只是 MAL 映射，走原生标题搜索去补 MAL 资料。
  test(
      'positive hash without MAL mapping uses native titles and still records the AniDB identity',
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
    final VideoMetadataProviderIdentityRow anidb = ids.singleWhere(
        (VideoMetadataProviderIdentityRow id) => id.provider == 'anidb');
    expect(anidb.externalId, '100');
    expect(anidb.isPrimary, isFalse, reason: '作品资料源仍是 MAL，AniDB 只是交叉引用');
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

  test('hash different anime splits the playlist per AniDB work (Shoko)',
      () async {
    // 第六轮对齐 Shoko 多 series：成员分属不同 AniDB 作品不再整合集挂起等人工，
    // 而是按作品拆成各自的播放列表合集分别刮削（`_splitByAnidbWork`）。
    final SourceLibraryRow source = await _source(db, directory, count: 2);
    final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
      _matched(malIds: <int>{42}),
      _matched(aid: 101),
    ]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report =
        await scrape(coordinator(mal, tmdb, hash), source);
    // 原合集 2 个成员各问一次，拆出的两个单元各再问一次（真实服务由
    // `anidb_file_identities` 持久层命中，不重算哈希不重发 FILE）。
    expect(hash.calls, 4);
    expect(report.pendingConfirmations, 0);
    expect(report.failedWorks, 0, reason: '${report.errors}');
    expect(report.succeededWorks, 2, reason: '两部作品各自成合集刮削');
    expect(report.warnings.map((SourceScrapeIssue w) => w.message).join(),
        contains('拆开各自刮削'));
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.map((MediaCollectionRow c) => c.name),
        unorderedEquals(<String>['Show', 'Show（AniDB 101）']));
    // aid 100 的成员留在原合集，aid 101 的成员进新合集。
    final MediaCollectionRow split = collections
        .singleWhere((MediaCollectionRow c) => c.name == 'Show（AniDB 101）');
    expect(
        (await db.getCollectionItems(split.id))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-1']);
  });

  // 身份优先级：已确认 / 已落库 / NFO / 路径显式 id 在哈希之前。成员分属多个
  // AniDB 作品时只有「哈希决定身份」才拆；用户手动指定了作品（物语系列 / 多
  // cour 番天然多 aid）就保持该身份、不删合集、不拆分，只报一条说明。
  test(
      'hash different anime keeps a confirmed identity and never splits the playlist',
      () async {
    final SourceLibraryRow source = await _source(db, directory, count: 2);
    final int collectionId = (await db.getAllMediaCollections()).single.id;
    final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
      _matched(malIds: <int>{42}),
      _matched(aid: 101),
    ]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report =
        await coordinator(mal, tmdb, hash).rescrapeWorkWithLookup(
      source: source,
      workTitle: 'Show',
      workStableKey: 'collection:$collectionId',
      lookup: const VideoMetadataLookup(
          provider: VideoMetadataProviderKind.mal,
          externalId: '42',
          mediaKind: VideoMetadataMediaKind.tv),
      cancellationToken: VideoSourceScrapeCancellationToken(),
      onProgress: (_) {},
    );
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(report.pendingConfirmations, 0);
    expect(mal.fetchedIds, <String>['42'], reason: '手动指定的身份不得被哈希换掉');
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.map((MediaCollectionRow c) => c.name), <String>['Show'],
        reason: '不拆分、不删用户的合集');
    expect(
        (await db.getCollectionItems(collectionId))
            .map((MediaCollectionItemRow i) => i.entryKey),
        <String>['book-0', 'book-1']);
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(collectionId))!;
    final Map<String, String> ids = <String, String>{
      for (final VideoMetadataProviderIdentityRow id
          in await db.getVideoMetadataProviderIdentities(workId: work.id))
        id.provider: id.externalId,
    };
    expect(ids['mal'], '42');
    expect(ids.containsKey('anidb'), isFalse, reason: '冲突时不写 AniDB 交叉引用');
    expect(report.warnings.map((SourceScrapeIssue w) => w.message),
        anyElement(allOf(contains('分属多部 AniDB 作品'), contains('未拆分'))));
    expect(report.warnings.map((SourceScrapeIssue w) => w.message),
        isNot(anyElement(contains('拆开各自刮削'))));
  });

  // 对齐 Shoko（BUG-2586）：anime-lists 一对多不是「作品悬空」——AniDB 身份已
  // 成立，只是 MAL 要选。候选按 id 拉出来交人工，没有确认回调就留待确认。
  test('hash mapping ambiguity offers the mapped MAL entries as candidates',
      () async {
    final SourceLibraryRow source = await _source(db, directory, count: 2);
    final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
      _matched(malIds: <int>{42, 43}),
      _matched(malIds: <int>{42, 43}),
    ]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final _Provider tmdb = _Provider(VideoMetadataProviderKind.tmdb);
    final SourceScrapeReport report =
        await scrape(coordinator(mal, tmdb, hash), source);
    expect(report.pendingConfirmations, 1);
    expect(report.succeededWorks, 0);
    expect(hash.calls, 2);
    expect(mal.searchCalls, 0, reason: '候选来自映射 id，不发标题搜索');
    expect(mal.fetchedIds, <String>['42', '43']);
    expect(tmdb.searchCalls, 0);
    expect(report.warnings.map((SourceScrapeIssue w) => w.message),
        anyElement(contains('映射到多个 MAL 条目')));
  });

  test('hash mapping ambiguity resolved by confirmation keeps the AniDB id',
      () async {
    final SourceLibraryRow source = await _source(db, directory, count: 2);
    final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
      _matched(malIds: <int>{42, 43}),
      _matched(malIds: <int>{42, 43}),
    ]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final List<String> offered = <String>[];
    final SourceScrapeReport report = await coordinator(mal, null, hash)
        .scrapeSource(source,
            cancellationToken: VideoSourceScrapeCancellationToken(),
            onProgress: (_) {},
            onConfirmation: (VideoSourceScrapeConfirmation confirmation) async {
      offered.addAll(confirmation.candidates.map(
          (VideoSourceScrapeConfirmationCandidate c) => c.lookup.externalId));
      return confirmation.candidates.last;
    });
    expect(offered, <String>['42', '43']);
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByCollection(
            (await db.getAllMediaCollections()).single.id))!;
    final Map<String, String> ids = <String, String>{
      for (final VideoMetadataProviderIdentityRow id
          in await db.getVideoMetadataProviderIdentities(workId: work.id))
        id.provider: id.externalId,
    };
    expect(ids['mal'], '43');
    expect(ids['anidb'], '100');
  });

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

  // 对齐 Shoko（BUG-2586）：哈希是文件级第一步，用户确认了 MAL id 也照样认
  // 文件（落文件身份）；但作品身份由确认值决定，MAL 挂了也不退 TMDB。
  test(
      'confirmed user MAL ID still hashes the file but never changes identity or falls back on outage',
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
    expect(hash.calls, 1);
    expect(tmdb.searchCalls, 0);
  });

  test(
      'hash that contradicts a confirmed MAL identity is reported, not applied',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    // 文件哈希指向 AniDB 100 → MAL 99；用户确认的是 MAL 42。
    final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
      _matched(malIds: <int>{99}),
    ]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final SourceScrapeReport report =
        await coordinator(mal, null, hash).rescrapeWorkWithLookup(
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
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    expect(hash.calls, 1);
    expect(mal.fetchedIds, <String>['42'], reason: '不得静默换成哈希映射的 99');
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final Map<String, String> ids = <String, String>{
      for (final VideoMetadataProviderIdentityRow id
          in await db.getVideoMetadataProviderIdentities(workId: work.id))
        id.provider: id.externalId,
    };
    expect(ids['mal'], '42');
    expect(ids.containsKey('anidb'), isFalse, reason: '冲突时不写 AniDB 交叉引用');
    expect(report.warnings.map((SourceScrapeIssue w) => w.message),
        anyElement(contains('与当前已确认身份 MAL 42 不一致')));
  });

  test(
      'hash consistent with a confirmed MAL identity adds the AniDB cross-reference',
      () async {
    final SourceLibraryRow source = await _source(db, directory);
    final _HashService hash = _HashService(results: <AnidbHashIdentityResult>[
      _matched(malIds: <int>{42}),
    ]);
    final _Provider mal = _Provider(VideoMetadataProviderKind.mal);
    final SourceScrapeReport report =
        await coordinator(mal, null, hash).rescrapeWorkWithLookup(
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
    expect(report.succeededWorks, 1, reason: '${report.errors}');
    final VideoMetadataWorkRow work =
        (await db.getVideoMetadataWorkByBook('book-0'))!;
    final Map<String, String> ids = <String, String>{
      for (final VideoMetadataProviderIdentityRow id
          in await db.getVideoMetadataProviderIdentities(workId: work.id))
        id.provider: id.externalId,
    };
    expect(ids['mal'], '42');
    expect(ids['anidb'], '100');
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
          // 显式 MAL：2026-09-20 起 `anidb` 不再是回落全局默认的历史值，而是
          // 真正的 AniDB 主源。
          providerOverride: const Value<String?>('mal'),
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
