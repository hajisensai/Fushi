import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_continue_watching.dart';
import 'package:fushi/src/pages/implementations/home_nav_peek.dart'
    show VideoNavPeekItem, planVideoNavPeek;
import 'package:fushi_core/fushi_core.dart'
    show
        CollectionScrapeMetaCompanion,
        FushiDatabase,
        MediaCollectionRow,
        MediaKind,
        VideoBookRow,
        VideoBooksCompanion,
        VideoMetadataWorksCompanion;
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

/// BUG-5330：侧栏视频速览说「还没有可继续的」，同屏视频首页首屏却有
/// 「☁ 下一集 · 第 1 集」（目标集只在互联 host 上）。两处现在都走
/// [selectVideoContinueCandidates]，速览编排走 [planVideoNavPeek]。
MediaCollectionRow _collection(int id, String name) => MediaCollectionRow(
  origin: 'user',
  organizeAliases: '',
  id: id,
  name: name,
  collectionType: 'collection',
  sortOrder: 0,
  coverSource: null,
  createdAt: 0,
  orderUpdatedAt: 0,
);

VideoBookRow _local(
  String uid, {
  int positionMs = 0,
  int? lastPlayedAt,
  DateTime? completedAt,
}) => VideoBookRow(
  bookUid: uid,
  title: uid,
  videoPath: '/videos/$uid.mkv',
  lastPositionMs: positionMs,
  currentEpisode: 0,
  delayMs: 0,
  lastPlayedAt: lastPlayedAt,
  completedAt: completedAt,
);

RemoteVideoInfo _remote(
  String id, {
  int positionMs = 0,
  int updatedAtMs = 0,
  int? completedAt,
  int? durationMs,
}) => RemoteVideoInfo(
  id: id,
  title: id,
  positionMs: positionMs,
  positionUpdatedAtMs: updatedAtMs,
  completedAt: completedAt,
  durationMs: durationMs,
);

VideoContinueInputs _inputs({
  Map<String, int> collectionIdByUid = const <String, int>{},
  Map<int, MediaCollectionRow> collectionsById =
      const <int, MediaCollectionRow>{},
  Map<String, int> sortIndexByUid = const <String, int>{},
  Set<String> excludedUids = const <String>{},
}) => VideoContinueInputs(
  collectionIdByUid: collectionIdByUid,
  collectionsById: collectionsById,
  sortIndexByUid: sortIndexByUid,
  watchAtByUid: const <String, DateTime>{},
  legacyWatchAtByTitle: const <String, DateTime>{},
  durationMsOf: (String _) => null,
  excludedUids: excludedUids,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('只在 host 上的合集：第 1 集打开过、进度 0 → 选中第 1 集，文案「Next · Episode 1」', () {
    final MediaCollectionRow show = _collection(7, 'Frieren');
    final List<VideoContinueCandidate> candidates =
        selectVideoContinueCandidates(
          local: const <VideoBookRow>[],
          remote: <RemoteVideoInfo>[
            _remote('host/ep2'),
            _remote('host/ep1', updatedAtMs: 5000),
          ],
          inputs: _inputs(
            collectionIdByUid: const <String, int>{
              'host/ep1': 7,
              'host/ep2': 7,
            },
            collectionsById: <int, MediaCollectionRow>{7: show},
            sortIndexByUid: const <String, int>{'host/ep1': 0, 'host/ep2': 1},
          ),
        );
    expect(candidates, hasLength(1));
    final VideoContinueSeriesCandidate series =
        candidates.single as VideoContinueSeriesCandidate;
    expect(series.collection.id, 7);
    expect(series.targetIndex, 0);
    expect(series.target.remote?.id, 'host/ep1');
    expect(series.target.local, isNull);
    expect(series.completedCount, 0);
    expect(series.recentMs, 5000);
    expect(videoContinueSeriesSubtitle(series), 'Next · Episode 1');

    // 速览：「继续」就是这一项（此前速览只读本机行，这里是空的）。
    final ({VideoContinueCandidate? resume, List<VideoNavPeekItem> recent})
    plan = planVideoNavPeek(
      candidates: candidates,
      recentlyPlayed: const <VideoBookRow>[],
      primaryCollectionIdByEntry: const <String, int>{},
      collectionsById: <int, MediaCollectionRow>{7: show},
    );
    expect(plan.resume, same(series));
    expect(plan.recent, isEmpty);
  });

  test('本地合集：最近播放的那集已看完 → 选下一集', () {
    final MediaCollectionRow show = _collection(3, 'Mushishi');
    final DateTime done = DateTime.fromMillisecondsSinceEpoch(9000);
    final List<VideoContinueCandidate> candidates =
        selectVideoContinueCandidates(
          local: <VideoBookRow>[
            _local('ep1', positionMs: 100, lastPlayedAt: 1000),
            _local(
              'ep2',
              positionMs: 1400000,
              lastPlayedAt: 9000,
              completedAt: done,
            ),
            _local('ep3'),
          ],
          remote: const <RemoteVideoInfo>[],
          inputs: _inputs(
            collectionIdByUid: const <String, int>{
              'ep1': 3,
              'ep2': 3,
              'ep3': 3,
            },
            collectionsById: <int, MediaCollectionRow>{3: show},
            sortIndexByUid: const <String, int>{'ep1': 0, 'ep2': 1, 'ep3': 2},
          ),
        );
    final VideoContinueSeriesCandidate series =
        candidates.single as VideoContinueSeriesCandidate;
    // 不退回更早的未完成集（第 1 集），落到第 2 集之后的第 3 集。
    expect(series.target.local?.bookUid, 'ep3');
    expect(series.targetIndex, 2);
    expect(series.completedCount, 1);
    expect(series.recentMs, 9000);
    expect(videoContinueSeriesSubtitle(series), 'Next · Episode 3');
  });

  test('看完的散片（本地打勾 / 远端打勾）不进；在看的按最近倒序；特典跳过', () {
    final List<VideoContinueCandidate> candidates =
        selectVideoContinueCandidates(
          local: <VideoBookRow>[
            _local(
              'done',
              positionMs: 500,
              lastPlayedAt: 99999,
              completedAt: DateTime.fromMillisecondsSinceEpoch(99999),
            ),
            _local('watching', positionMs: 500, lastPlayedAt: 10),
            _local('extra', positionMs: 500, lastPlayedAt: 20),
            _local('never'),
          ],
          remote: <RemoteVideoInfo>[
            _remote(
              'r-done',
              positionMs: 100,
              updatedAtMs: 88888,
              completedAt: 88888,
            ),
            _remote('r-watching', positionMs: 100, updatedAtMs: 4000),
            // 进度到片尾区也算看完。
            _remote(
              'r-tail',
              positionMs: 59 * 60000,
              updatedAtMs: 77777,
              durationMs: 60 * 60000,
            ),
          ],
          inputs: _inputs(excludedUids: const <String>{'extra'}),
        );
    expect(
      <String>[
        for (final VideoContinueCandidate c in candidates)
          switch (c) {
            VideoContinueLocalCandidate(:final VideoBookRow book) =>
              book.bookUid,
            VideoContinueRemoteCandidate(:final RemoteVideoInfo video) =>
              video.id,
            VideoContinueSeriesCandidate() => 'series',
          },
      ],
      // 本地散片的排序键只认播放统计时刻（与改动前同口径），没有统计行 → 0。
      <String>['r-watching', 'watching'],
    );
  });

  test('速览「最近」：其余候选在前，再接最近播放的其它条目，已在继续观看里的合集不重复', () {
    final MediaCollectionRow a = _collection(1, 'A');
    final MediaCollectionRow b = _collection(2, 'B');
    final VideoContinueSeriesCandidate first = VideoContinueSeriesCandidate(
      recentMs: 300,
      collection: a,
      title: 'A',
      members: <VideoHomeSlot>[VideoHomeSlot(remote: _remote('a1'))],
      targetIndex: 0,
      completedCount: 0,
    );
    final VideoContinueLocalCandidate second = VideoContinueLocalCandidate(
      recentMs: 200,
      book: _local('loose', positionMs: 5),
    );
    final ({VideoContinueCandidate? resume, List<VideoNavPeekItem> recent})
    plan = planVideoNavPeek(
      candidates: <VideoContinueCandidate>[first, second],
      recentlyPlayed: <VideoBookRow>[
        _local('a-local', lastPlayedAt: 900),
        _local('loose', lastPlayedAt: 800),
        _local('b1', lastPlayedAt: 700),
        _local('b2', lastPlayedAt: 600),
        _local('solo', lastPlayedAt: 500),
      ],
      primaryCollectionIdByEntry: <String, int>{
        MediaKind.video.compositeKey('a-local'): 1,
        MediaKind.video.compositeKey('b1'): 2,
        MediaKind.video.compositeKey('b2'): 2,
      },
      collectionsById: <int, MediaCollectionRow>{1: a, 2: b},
    );
    expect(plan.resume, same(first));
    expect(plan.recent.first.candidate, same(second));
    expect(
      <String?>[
        for (final VideoNavPeekItem item in plan.recent.skip(1))
          item.played?.collectionName ?? item.played?.item.bookUid,
      ],
      <String?>['B', 'solo'],
    );
  });

  test('VideoContinueShare：页面 dispose 只清自己发布的那份', () {
    final VideoContinueShare share = VideoContinueShare();
    final Object pageA = Object();
    final Object pageB = Object();
    share.publishRemote(pageA, <RemoteVideoInfo>[_remote('x')], null);
    // 别的页面 dispose 不清 A 发布的清单。
    share.clearOwner(pageB);
    expect(share.remoteVideos, isNotNull);
    share.clearOwner(pageA);
    expect(share.remoteVideos, isNull);
  });

  group('作品名：首页 hero 与速览同一条回落链（刮削作品 → 合集刮削 → 合集名）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<int> playedSeries(String name, String uid) async {
      final int id = await db.createMediaCollection(
        name,
        collectionType: 'playlist',
      );
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(uid),
          videoPath: Value<String>('/videos/$uid.mkv'),
          lastPositionMs: const Value<int>(1000),
          lastPlayedAt: const Value<int?>(5000),
        ),
      );
      await db.addToCollection(id, MediaKind.video, uid);
      return id;
    }

    test('没开过视频页时速览现读同一批表：合集卡用刮削标题，不是合集名', () async {
      final int scraped = await playedSeries('[Group] sousou_no_frieren', 'a');
      await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          collectionId: Value<int?>(scraped),
          mediaType: 'tv',
          title: 'Frieren: Beyond Journey\'s End',
          updatedAt: 1,
        ),
      );
      final int metaOnly = await playedSeries('mushishi_bd', 'b');
      await db.upsertCollectionScrapeMeta(
        CollectionScrapeMetaCompanion.insert(
          collectionId: Value<int>(metaOnly),
          source: 'tmdb',
          subjectId: '1',
          title: 'Mushishi',
          scrapedAt: DateTime(2026),
        ),
      );
      final int plain = await playedSeries('Plain Show', 'c');

      final VideoContinueLibrary library = await loadVideoContinueLibrary(
        db,
        listBooks: db.allVideoBooks,
      );
      final VideoContinueInputs inputs = library.inputs(
        durationMsOf: (String _) => null,
      );
      final List<VideoContinueCandidate> candidates =
          selectVideoContinueCandidates(
            local: library.books,
            remote: const <RemoteVideoInfo>[],
            inputs: inputs,
          );
      final Map<int, String> titles = <int, String>{
        for (final VideoContinueCandidate c in candidates)
          if (c is VideoContinueSeriesCandidate) c.collection.id: c.title,
      };
      expect(titles, <int, String>{
        scraped: 'Frieren: Beyond Journey\'s End',
        metaOnly: 'Mushishi',
        plain: 'Plain Show',
      });
      // 速览「继续」项的标题就是候选标题（home_nav_peek candidateEntry 用 c.title）。
      final ({VideoContinueCandidate? resume, List<VideoNavPeekItem> recent})
      plan = planVideoNavPeek(
        candidates: candidates,
        recentlyPlayed: const <VideoBookRow>[],
        primaryCollectionIdByEntry: library.primaryCollectionByEntry,
        collectionsById: library.collectionsById,
      );
      expect(
        <String>[
          for (final VideoContinueCandidate? c in <VideoContinueCandidate?>[
            plan.resume,
            for (final VideoNavPeekItem i in plan.recent) i.candidate,
          ])
            if (c is VideoContinueSeriesCandidate) c.title,
        ]..sort(),
        <String>['Frieren: Beyond Journey\'s End', 'Mushishi', 'Plain Show'],
      );
      // 速览把合集候选画成条目时取的就是这份标题，不另拼合集名。
      final String peekSource = File(
        'lib/src/pages/implementations/home_nav_peek.dart',
      ).readAsStringSync();
      expect(peekSource, contains('title: c.title,'));
      expect(peekSource, isNot(contains('c.collection.name')));
    });
  });
}
