import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_subscription.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';

NyaaTorrent _torrent({
  required String hash,
  required int episode,
  String group = 'SubsPlease',
  String resolution = '1080p',
  int seeders = 10,
  bool trusted = true,
  bool remake = false,
}) {
  return NyaaTorrent(
    title: '[$group] Example Show - ${episode.toString().padLeft(2, '0')} '
        '($resolution) [WEB-DL]',
    torrentUrl: 'https://nyaa.si/download/$hash.torrent',
    pageUrl: 'https://nyaa.si/view/$hash',
    infoHash: hash,
    seeders: seeders,
    leechers: 0,
    downloads: 0,
    sizeText: '1 GiB',
    sizeBytes: 1024 * 1024 * 1024,
    categoryId: '1_2',
    trusted: trusted,
    remake: remake,
    pubDate: DateTime.utc(2026, 7, episode),
  );
}

AnimeDownloadSubscription _subscription({
  Set<int> processed = const <int>{},
}) {
  return AnimeDownloadSubscription.fromSelection(
    anilistId: 42,
    seriesTitle: 'Example Show',
    nyaaQuery: 'Example Show',
    category: '1_2',
    releaseGroup: 'SubsPlease',
    resolution: '1080p',
    startAfterEpisode: 1,
    trustedOnly: true,
    now: DateTime.utc(2026, 7, 1),
  ).copyWith(processedEpisodes: processed);
}

class _FakeBackend implements TorrentBackend {
  final List<String> added = <String>[];
  bool addResult = true;
  bool reportExisting = false;
  bool closed = false;

  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async {
    added.add(magnetOrUrl);
    expect(category, 'hibiki');
    expect(sequential, isTrue);
    expect(firstLastPiecePrio, isTrue);
    return addResult;
  }

  @override
  void close() => closed = true;

  // TODO-1961-c：本 fake 不测改名/移动路径，给出明确的「未实现」结果而不是
  // 假装成功——真要测这条链路的用例应当显式覆盖它。
  @override
  Future<TorrentStorageResult> renameFile(
          String torrentId, int fileIndex, String newPath) async =>
      const TorrentStorageResult.failure('not supported by fake');

  @override
  Future<TorrentStorageResult> moveStorage(
          String torrentId, String newSavePath) async =>
      const TorrentStorageResult.failure('not supported by fake');

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      reportExisting
          ? const <TorrentSnapshot>[
              TorrentSnapshot(
                hash: 'abc123',
                name: 'Existing qB task',
                progress: 0.2,
                state: 'downloading',
                savePath: '',
                contentPath: '',
                amountLeft: 1,
              ),
            ]
          : const <TorrentSnapshot>[];

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'fake';
}

void main() {
  test('missing preference resolves to the same usable built-in defaults', () {
    final QbConnectionConfig config = effectiveTorrentConfig(null);
    expect(config.backend, QbConnectionConfig.backendAuto);
    expect(config.isConfigured, isTrue);
    expect(config.category, 'hibiki');
  });

  test('subscription identity is stable for the same combination', () {
    final AnimeDownloadSubscription first = _subscription();
    final AnimeDownloadSubscription second =
        AnimeDownloadSubscription.fromSelection(
      anilistId: 42,
      seriesTitle: 'Renamed display title',
      nyaaQuery: 'Different query',
      category: '1_2',
      releaseGroup: ' subsplease ',
      resolution: '1080P',
      startAfterEpisode: 8,
      now: DateTime.utc(2026, 7, 2),
    );
    expect(second.id, first.id);
  });

  test('subtitle source and language are part of subscription identity', () {
    AnimeDownloadSubscription create(int entryId, String language) =>
        AnimeDownloadSubscription.fromSelection(
          anilistId: 42,
          seriesTitle: 'Example Show',
          nyaaQuery: 'Example Show',
          category: '1_2',
          releaseGroup: 'SubsPlease',
          resolution: '1080p',
          jimakuEntryId: entryId,
          jimakuEntryName: 'Season pack',
          jimakuLanguage: language,
          startAfterEpisode: 1,
        );

    expect(create(11, 'ja').id, isNot(create(12, 'ja').id));
    expect(create(11, 'ja').id, isNot(create(11, 'zh').id));
  });

  test('subtitle selection remains round-trippable', () {
    final AnimeDownloadSubscription original =
        AnimeDownloadSubscription.fromSelection(
      anilistId: 42,
      seriesTitle: 'Example Show',
      nyaaQuery: 'Example Show',
      category: '1_2',
      releaseGroup: 'SubsPlease',
      startAfterEpisode: 1,
      jimakuEntryId: 77,
      jimakuEntryName: 'Complete series',
      jimakuLanguage: 'ja',
    );
    final AnimeDownloadSubscription decoded = decodeAnimeDownloadSubscription(
      encodeAnimeDownloadSubscription(original),
    )!;
    expect(decoded.jimakuEntryId, 77);
    expect(decoded.jimakuEntryName, 'Complete series');
    expect(decoded.jimakuLanguage, 'ja');
  });

  test('selection uses exact group and resolution and does not backfill', () {
    final List<NyaaTorrent> selected = selectSubscriptionReleases(
      _subscription(processed: <int>{3}),
      <NyaaTorrent>[
        _torrent(hash: 'old', episode: 1),
        _torrent(hash: 'processed', episode: 3),
        _torrent(hash: 'wrong-group', episode: 2, group: 'SubsPlease v2'),
        _torrent(hash: 'wrong-resolution', episode: 2, resolution: '720p'),
        _torrent(hash: 'remake', episode: 2, remake: true, seeders: 100),
        _torrent(hash: 'weak', episode: 2, seeders: 2),
        _torrent(hash: 'best', episode: 2, seeders: 20),
        _torrent(hash: 'next', episode: 4),
      ],
    );

    expect(selected.map((NyaaTorrent torrent) => torrent.infoHash),
        <String>['best', 'next']);
  });

  test('subscription JSON remains round-trippable', () {
    final AnimeDownloadSubscription original = _subscription(
      processed: <int>{2, 4},
    ).copyWith(
      enabled: false,
      lastCheckedAtMs: 123,
      lastMatchedAtMs: 120,
      lastError: 'offline',
    );
    final AnimeDownloadSubscription? decoded = decodeAnimeDownloadSubscription(
      encodeAnimeDownloadSubscription(original),
    );
    expect(decoded, isNotNull);
    expect(decoded!.id, original.id);
    expect(decoded.processedEpisodes, <int>{2, 4});
    expect(decoded.enabled, isFalse);
    expect(decoded.lastError, 'offline');
  });

  group('AnimeDownloadSubscriptionService', () {
    late Directory directory;
    late AnimeDownloadSubscriptionStore subscriptionStore;
    late AnimeDownloadPlanStore planStore;

    setUp(() async {
      directory =
          await Directory.systemTemp.createTemp('hibiki-subscription-test-');
      subscriptionStore = AnimeDownloadSubscriptionStore(baseDir: directory);
      planStore = AnimeDownloadPlanStore(baseDir: directory);
    });

    tearDown(() async {
      subscriptionStore.revision.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    test('queues a new release, creates a plan and marks episode processed',
        () async {
      final AnimeDownloadSubscription subscription = _subscription();
      await subscriptionStore.save(subscription);
      final _FakeBackend backend = _FakeBackend();
      final AnimeDownloadSubscriptionService service =
          AnimeDownloadSubscriptionService(
        store: subscriptionStore,
        planStore: planStore,
        configProvider: () => const QbConnectionConfig(),
        backendFactory: (_) => backend,
        search: (_) async => <NyaaTorrent>[
          _torrent(hash: 'abc123', episode: 2),
        ],
      );

      await service.checkSubscription(subscription.id);

      final List<AnimeDownloadPlan> plans = await planStore.loadAll();
      expect(plans, hasLength(1));
      expect(plans.single.id, 'abc123');
      expect(plans.single.seriesTitle, 'Example Show');
      expect(backend.added, hasLength(1));
      expect(backend.closed, isTrue);

      final AnimeDownloadSubscription updated =
          (await subscriptionStore.loadAll()).single;
      expect(updated.processedEpisodes, <int>{2});
      expect(updated.lastCheckedAtMs, isNotNull);
      expect(updated.lastMatchedAtMs, isNotNull);
      expect(updated.lastError, isNull);
      service.stop();
      service.checking.dispose();
    });

    test('failed backend add rolls back plan and keeps episode pending',
        () async {
      final AnimeDownloadSubscription subscription = _subscription();
      await subscriptionStore.save(subscription);
      final _FakeBackend backend = _FakeBackend()..addResult = false;
      final AnimeDownloadSubscriptionService service =
          AnimeDownloadSubscriptionService(
        store: subscriptionStore,
        planStore: planStore,
        configProvider: () => const QbConnectionConfig(),
        backendFactory: (_) => backend,
        search: (_) async => <NyaaTorrent>[
          _torrent(hash: 'abc123', episode: 2),
        ],
      );

      await service.checkSubscription(subscription.id);

      expect(await planStore.loadAll(), isEmpty);
      final AnimeDownloadSubscription updated =
          (await subscriptionStore.loadAll()).single;
      expect(updated.processedEpisodes, isEmpty);
      expect(updated.lastError, isNotNull);
      service.stop();
      service.checking.dispose();
    });

    test('qB duplicate add is accepted when the hash is already listed',
        () async {
      final AnimeDownloadSubscription subscription = _subscription();
      await subscriptionStore.save(subscription);
      final _FakeBackend backend = _FakeBackend()
        ..addResult = false
        ..reportExisting = true;
      final AnimeDownloadSubscriptionService service =
          AnimeDownloadSubscriptionService(
        store: subscriptionStore,
        planStore: planStore,
        configProvider: () => const QbConnectionConfig(),
        backendFactory: (_) => backend,
        search: (_) async => <NyaaTorrent>[
          _torrent(hash: 'abc123', episode: 2),
        ],
      );

      await service.checkSubscription(subscription.id);

      expect(await planStore.loadAll(), hasLength(1));
      final AnimeDownloadSubscription updated =
          (await subscriptionStore.loadAll()).single;
      expect(updated.processedEpisodes, <int>{2});
      expect(updated.lastError, isNull);
      service.stop();
      service.checking.dispose();
    });

    test('existing plan is treated as queued without adding a duplicate',
        () async {
      final AnimeDownloadSubscription subscription = _subscription();
      await subscriptionStore.save(subscription);
      await planStore.save(AnimeDownloadPlan(
        id: 'abc123',
        createdAtMs: 1,
        anilistId: 42,
        seriesTitle: 'Example Show',
        torrentTitle: 'Existing',
        magnet: 'magnet:?xt=urn:btih:abc123',
        qbCategory: 'hibiki',
      ));
      final _FakeBackend backend = _FakeBackend();
      final AnimeDownloadSubscriptionService service =
          AnimeDownloadSubscriptionService(
        store: subscriptionStore,
        planStore: planStore,
        configProvider: () => const QbConnectionConfig(),
        backendFactory: (_) => backend,
        search: (_) async => <NyaaTorrent>[
          _torrent(hash: 'abc123', episode: 2),
        ],
      );

      await service.checkSubscription(subscription.id);

      expect(backend.added, isEmpty);
      expect((await subscriptionStore.loadAll()).single.processedEpisodes,
          <int>{2});
      service.stop();
      service.checking.dispose();
    });

    test('selected Jimaku source is staged into each queued episode', () async {
      final AnimeDownloadSubscription subscription =
          AnimeDownloadSubscription.fromSelection(
        anilistId: 42,
        seriesTitle: 'Example Show',
        nyaaQuery: 'Example Show',
        category: '1_2',
        releaseGroup: 'SubsPlease',
        resolution: '1080p',
        startAfterEpisode: 1,
        jimakuEntryId: 77,
        jimakuEntryName: 'Complete series',
        jimakuLanguage: 'ja',
      );
      await subscriptionStore.save(subscription);
      final _FakeBackend backend = _FakeBackend();
      final AnimeDownloadSubscriptionService service =
          AnimeDownloadSubscriptionService(
        store: subscriptionStore,
        planStore: planStore,
        configProvider: () => const QbConnectionConfig(),
        backendFactory: (_) => backend,
        search: (_) async => <NyaaTorrent>[
          _torrent(hash: 'abc123', episode: 2),
        ],
        subtitleFetcher: (selected, torrent, destination) async {
          expect(selected.jimakuEntryId, 77);
          expect(selected.jimakuLanguage, 'ja');
          expect(torrent.episode, 2);
          return <PlanSubtitle>[
            PlanSubtitle(
              episode: 2,
              fileName: 'Example.Show.02.ja.srt',
              stagedPath: '${destination.path}/Example.Show.02.ja.srt',
              language: 'ja',
            ),
          ];
        },
      );

      await service.checkSubscription(subscription.id);

      final AnimeDownloadPlan plan = (await planStore.loadAll()).single;
      expect(plan.subtitles.single.episode, 2);
      expect(plan.subtitles.single.language, 'ja');
      expect(
        (await subscriptionStore.loadAll()).single.processedEpisodes,
        <int>{2},
      );
      service.stop();
      service.checking.dispose();
    });

    test('missing selected subtitle keeps the episode pending', () async {
      final AnimeDownloadSubscription subscription =
          AnimeDownloadSubscription.fromSelection(
        anilistId: 42,
        seriesTitle: 'Example Show',
        nyaaQuery: 'Example Show',
        category: '1_2',
        releaseGroup: 'SubsPlease',
        startAfterEpisode: 1,
        jimakuEntryId: 77,
      );
      await subscriptionStore.save(subscription);
      final AnimeDownloadSubscriptionService service =
          AnimeDownloadSubscriptionService(
        store: subscriptionStore,
        planStore: planStore,
        configProvider: () => const QbConnectionConfig(),
        backendFactory: (_) => _FakeBackend(),
        search: (_) async => <NyaaTorrent>[
          _torrent(hash: 'abc123', episode: 2),
        ],
        subtitleFetcher: (_, __, ___) async => const <PlanSubtitle>[],
      );
      await service.checkSubscription(subscription.id);
      final AnimeDownloadSubscription updated =
          (await subscriptionStore.loadAll()).single;
      expect(updated.processedEpisodes, isEmpty);
      expect(updated.lastError, contains('subtitle not available'));
      expect(await planStore.loadAll(), isEmpty);
      service.stop();
      service.checking.dispose();
    });
  });
}
