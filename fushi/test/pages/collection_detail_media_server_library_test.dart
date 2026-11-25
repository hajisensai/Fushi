import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/media/video/media_server/media_server_library.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server_video_path.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:material_ui/material_ui.dart';

import 'media_server/fake_media_server_browser.dart';

/// 剧集带剧名合集归属（与 Jellyfin / Plex 实现同口径），入库时收养进同一个合集。
class _SeriesBrowser extends FakeMediaServerBrowser {
  _SeriesBrowser() : super(serverId: 'jellyfin:http://srv|u1');

  @override
  RemoteVideoInfo toRemoteVideoInfo(MediaServerItem item) => RemoteVideoInfo(
    id: item.id,
    title: item.name,
    collection: mediaServerCollectionOf(item),
  );
}

MediaServerItem _episode(String id, int number) => MediaServerItem(
  id: id,
  name: 'Ep $number',
  type: MediaServerItemType.episode,
  seriesId: 'show',
  seriesName: 'The Show',
  seasonNumber: 1,
  episodeNumber: number,
);

/// BUG-5459 · 视频合集详情页：剧集只在媒体服务器上（本机没有入库行）时，hero 次按钮
/// 没有「加入媒体库」，只有入库之后才出现的「移出媒体库」。
///
/// 守卫：远端来源是媒体服务器、合集有只在服务器上的集 → 出「加入媒体库」（与「移出」
/// 同一组件）；点了走 `MediaServerVideoLibrary` 把整部剧入库，页面随之换成「移出」；
/// 远端来源不是媒体服务器（互联 host / 云盘）不出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late int collectionId;
  late _SeriesBrowser browser;

  const ValueKey<String> addKey = ValueKey<String>(
    'collection-hero-library-add',
  );
  const ValueKey<String> removeKey = ValueKey<String>(
    'collection-hero-library-remove',
  );

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    collectionId = await db.createMediaCollection(
      'The Show',
      collectionType: 'playlist',
    );
    browser = _SeriesBrowser();
    final List<MediaServerItem> episodes = <MediaServerItem>[
      _episode('e1', 1),
      _episode('e2', 2),
    ];
    browser.episodes['show|'] = episodes;
    for (final MediaServerItem e in episodes) {
      browser.details[e.id] = e;
    }
    browser.details['show'] = const MediaServerItem(
      id: 'show',
      name: 'The Show',
      type: MediaServerItemType.series,
    );
  });

  tearDown(() => db.close());

  List<RemoteVideoInfo> remoteVideos() => <RemoteVideoInfo>[
    for (final MediaServerItem e in browser.episodes['show|']!)
      browser.toRemoteVideoInfo(e),
  ];

  MediaCollectionRow collectionRow() => MediaCollectionRow(
    origin: 'user',
    organizeAliases: '',
    id: collectionId,
    name: 'The Show',
    collectionType: 'playlist',
    coverSource: null,
    sortOrder: 0,
    createdAt: 0,
    orderUpdatedAt: 0,
  );

  Future<void> pumpDetail(
    WidgetTester tester, {
    required MediaServerBrowser? mediaServer,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: MediaCollectionDetailPage(
            database: db,
            collection: collectionRow(),
            loadEpisodes: () => loadCollectionEpisodeSlots(
              repository: repo,
              collectionId: collectionId,
              loadRemoteVideos: () async => remoteVideos(),
            ),
            onOpenEpisode: (VideoBookRow _) {},
            remote: CollectionRemoteContext(
              loadRemoteVideos: () async => remoteVideos(),
              openEpisode:
                  (RemoteVideoInfo _, List<RemoteVideoInfo> __, int ___) {},
              mediaServer: mediaServer,
            ),
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    await tester.pumpAndSettle();
    for (int i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> seedRemoteMembers() async {
    for (final String uid in <String>['e1', 'e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
  }

  testWidgets('只在服务器上的集：出「加入媒体库」；点了整部剧入库、换成「移出媒体库」', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navigator;
    await seedRemoteMembers();
    await pumpDetail(tester, mediaServer: browser, navigatorKey: navigator);

    expect(find.byKey(addKey), findsOneWidget);
    expect(find.byKey(removeKey), findsNothing);
    expect(find.text(t.video_online_library_add), findsOneWidget);

    await tester.tap(find.byKey(addKey));
    await settleUntil(
      tester,
      () => find.byKey(removeKey).evaluate().isNotEmpty,
    );

    final List<VideoBookRow> rows = (await tester.runAsync(db.allVideoBooks))!;
    expect(rows.map((VideoBookRow r) => r.bookUid).toSet(), <String>{
      'e1',
      'e2',
    });
    expect(
      rows.every((VideoBookRow r) => isMediaServerVideoPath(r.videoPath)),
      isTrue,
    );
    expect(rows.map(mediaServerWorkOfRow).toSet(), <MediaServerLibraryWork>{
      (serverId: browser.serverId, workId: 'show'),
    });
    expect(find.text(t.video_online_library_added(n: 2)), findsOneWidget);
    expect(find.byKey(addKey), findsNothing);
    expect(find.byKey(removeKey), findsOneWidget);
    // 让 toast 的消失计时器走完。
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('剧部分在库（服务器上出了新集）：「加入」与「移出」并列', (WidgetTester tester) async {
    await seedRemoteMembers();
    await tester.runAsync(
      () => MediaServerVideoLibrary(
        database: db,
      ).addToLibrary(browser, browser.details['show']!),
    );
    final MediaServerItem fresh = _episode('e3', 3);
    browser.episodes['show|'] = <MediaServerItem>[
      ...browser.episodes['show|']!,
      fresh,
    ];
    browser.details['e3'] = fresh;
    await tester.runAsync(
      () => db.addToCollection(collectionId, MediaKind.video, 'e3'),
    );

    await pumpDetail(tester, mediaServer: browser);

    expect(find.byKey(addKey), findsOneWidget);
    expect(find.byKey(removeKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('远端来源不是媒体服务器（互联 host / 云盘）：不出「加入媒体库」', (
    WidgetTester tester,
  ) async {
    await seedRemoteMembers();
    await pumpDetail(tester, mediaServer: null);

    expect(find.byKey(addKey), findsNothing);
    expect(find.byKey(removeKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
