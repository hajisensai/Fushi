import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;
import 'package:fushi_core/fushi_core.dart';

/// BUG-1704 · 互联客户端打开合集详情显示「合集为空」。
///
/// 合集清单是**跨端 union**（`applyCollectionLocalChanges` 无条件把对端成员写进本地
/// `media_collection_items`，entryKey 是 host 侧 bookUid），所以客户端本地必然存在
/// 「合集行有成员、但一行本地视频都没有」的合集。详情页此前把成员窄化成
/// `VideoBookRow`，解析不到的成员**直接丢弃**——整页判空。
///
/// 守卫三件事：
/// ① 成员解析（[loadCollectionEpisodeSlots]）不丢弃只在对端的成员，且保落盘序；
/// ② 全员在对端时详情页不显示「合集为空」，而是列出各集；
/// ③ 点远端集卡走远端流播入口，并带上全部远端成员 + 起播下标（跨成员连播）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late int collectionId;

  RemoteVideoInfo remoteEpisode(String id, String title, int sortIndex) =>
      RemoteVideoInfo(
        id: id,
        title: title,
        collection: RemoteCollectionMembership(
          collectionName: 'Show',
          collectionType: 'playlist',
          sortIndex: sortIndex,
        ),
      );

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
  });

  tearDown(() => db.close());

  /// 集列表在 hero 之下：默认 800x600 视口里它整段落在视口外、懒加载不建卡。
  /// 与既有详情页 widget 测试同一手法，用够高的离屏视口把整页一次渲染出来。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  MediaCollectionRow collectionRow() => MediaCollectionRow(
        id: collectionId,
        name: 'Show',
        collectionType: 'playlist',
        coverSource: null,
        sortOrder: 0,
        createdAt: 0,
        orderUpdatedAt: 0,
      );

  Widget detailPage({
    required List<RemoteVideoInfo> remoteVideos,
    void Function(RemoteVideoInfo, List<RemoteVideoInfo>, int)? onOpenRemote,
  }) =>
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: collectionRow(),
            loadEpisodes: () => loadCollectionEpisodeSlots(
              repository: repo,
              collectionId: collectionId,
              loadRemoteVideos: () async => remoteVideos,
            ),
            onOpenEpisode: (VideoBookRow _) {},
            remote: CollectionRemoteContext(
              loadRemoteVideos: () async => remoteVideos,
              openEpisode: onOpenRemote ??
                  (RemoteVideoInfo _, List<RemoteVideoInfo> __, int ___) {},
            ),
            onChanged: () {},
          ),
        ),
      );

  test('只在对端的成员不被丢弃，且保持落盘序', () async {
    // 本地只有第 2 集；第 1、3 集只在 host 上（成员行照样在本地 items 表里）。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/e2'),
      title: const Value('Show 02'),
      videoPath: const Value('/v/Show 02.mkv'),
    ));
    for (final String uid in <String>['video/e1', 'video/e2', 'video/e3']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    final List<CollectionEpisodeSlot> slots = await loadCollectionEpisodeSlots(
      repository: repo,
      collectionId: collectionId,
      loadRemoteVideos: () async => <RemoteVideoInfo>[
        remoteEpisode('video/e1', 'Show 01', 0),
        remoteEpisode('video/e3', 'Show 03', 2),
      ],
    );

    expect(
      slots.map((CollectionEpisodeSlot s) => s.entryKey).toList(),
      <String>['video/e1', 'video/e2', 'video/e3'],
    );
    expect(
      slots.map((CollectionEpisodeSlot s) => s.isRemote).toList(),
      <bool>[true, false, true],
    );
  });

  test('没有远端上下文时行为不变：解析不到本地行的成员照旧丢弃', () async {
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');

    final List<CollectionEpisodeSlot> slots = await loadCollectionEpisodeSlots(
      repository: repo,
      collectionId: collectionId,
    );

    expect(slots, isEmpty);
  });

  test('远端清单拉取失败时退化成纯本地视图，不抛', () async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/e2'),
      title: const Value('Show 02'),
      videoPath: const Value('/v/Show 02.mkv'),
    ));
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');

    final List<CollectionEpisodeSlot> slots = await loadCollectionEpisodeSlots(
      repository: repo,
      collectionId: collectionId,
      loadRemoteVideos: () async => throw Exception('offline'),
    );

    expect(slots.map((CollectionEpisodeSlot s) => s.entryKey).toList(),
        <String>['video/e2']);
  });

  testWidgets('全员只在对端：详情页不显示「合集为空」，而是列出各集', (WidgetTester tester) async {
    for (final String uid in <String>['video/e1', 'video/e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    useTallSurface(tester);
    await tester.pumpWidget(detailPage(remoteVideos: <RemoteVideoInfo>[
      remoteEpisode('video/e1', 'Show 01', 0),
      remoteEpisode('video/e2', 'Show 02', 1),
    ]));
    await tester.pumpAndSettle();

    expect(find.text(t.collection_empty), findsNothing);
    expect(
        find.byKey(const ValueKey<String>('collection-episode-row-video/e1')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('collection-episode-row-video/e2')),
        findsOneWidget);
  });

  testWidgets('点远端集卡：走远端流播入口，带全部远端成员与起播下标', (WidgetTester tester) async {
    for (final String uid in <String>['video/e1', 'video/e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    RemoteVideoInfo? opened;
    List<RemoteVideoInfo>? passedMembers;
    int? passedIndex;

    useTallSurface(tester);
    await tester.pumpWidget(detailPage(
      remoteVideos: <RemoteVideoInfo>[
        remoteEpisode('video/e1', 'Show 01', 0),
        remoteEpisode('video/e2', 'Show 02', 1),
      ],
      onOpenRemote: (
        RemoteVideoInfo episode,
        List<RemoteVideoInfo> members,
        int index,
      ) {
        opened = episode;
        passedMembers = members;
        passedIndex = index;
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-episode-row-video/e2')),
    );
    await tester.pumpAndSettle();

    expect(opened?.id, 'video/e2');
    expect(passedMembers?.map((RemoteVideoInfo v) => v.id).toList(),
        <String>['video/e1', 'video/e2']);
    expect(passedIndex, 1);
  });
}
