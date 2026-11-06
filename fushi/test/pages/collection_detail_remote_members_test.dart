import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_download_progress.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
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
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
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
    origin: 'user',
    organizeAliases: '',
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
    InterconnectDownloadManager? downloads,
    Future<bool> Function(VideoBookRow row)? deleteLocalCopy,
  }) => TranslationProvider(
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
          openEpisode:
              onOpenRemote ??
              (RemoteVideoInfo _, List<RemoteVideoInfo> __, int ___) {},
          downloads: downloads,
          deleteLocalCopy: deleteLocalCopy,
        ),
        onChanged: () {},
      ),
    ),
  );

  test('只在对端的成员不被丢弃，且保持落盘序', () async {
    // 本地只有第 2 集；第 1、3 集只在 host 上（成员行照样在本地 items 表里）。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/e2'),
        title: const Value('Show 02'),
        videoPath: const Value('/v/Show 02.mkv'),
      ),
    );
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
    expect(slots.map((CollectionEpisodeSlot s) => s.isRemote).toList(), <bool>[
      true,
      false,
      true,
    ]);
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
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/e2'),
        title: const Value('Show 02'),
        videoPath: const Value('/v/Show 02.mkv'),
      ),
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');

    final List<CollectionEpisodeSlot> slots = await loadCollectionEpisodeSlots(
      repository: repo,
      collectionId: collectionId,
      loadRemoteVideos: () async => throw Exception('offline'),
    );

    expect(
      slots.map((CollectionEpisodeSlot s) => s.entryKey).toList(),
      <String>['video/e2'],
    );
  });

  testWidgets('全员只在对端：详情页不显示「合集为空」，而是列出各集', (WidgetTester tester) async {
    for (final String uid in <String>['video/e1', 'video/e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    useTallSurface(tester);
    await tester.pumpWidget(
      detailPage(
        remoteVideos: <RemoteVideoInfo>[
          remoteEpisode('video/e1', 'Show 01', 0),
          remoteEpisode('video/e2', 'Show 02', 1),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.collection_empty), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('collection-episode-row-video/e1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('collection-episode-row-video/e2')),
      findsOneWidget,
    );
  });

  testWidgets('只在对端的集仍给「下载本集」，不给「打开文件位置」', (WidgetTester tester) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/e2'),
        title: const Value('Show 02'),
        videoPath: const Value('/v/Show 02.mkv'),
      ),
    );
    for (final String uid in <String>['video/e1', 'video/e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }

    useTallSurface(tester);
    await tester.pumpWidget(
      detailPage(
        remoteVideos: <RemoteVideoInfo>[
          remoteEpisode('video/e1', 'Show 01', 0),
        ],
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openMenu(String uid) async {
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(ValueKey<String>('collection-episode-row-$uid')),
        ),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await openMenu('video/e1');
    expect(
      find.text(t.collection_episode_download),
      findsOneWidget,
      reason: '本机没有文件的集才需要下载',
    );
    expect(find.text(t.media_file_location_open), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await openMenu('video/e2');
    expect(find.text(t.collection_episode_download), findsNothing);
    expect(find.text(t.media_file_location_open), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  // 用户报告 2026-09-22：互联下载远端合集时，合集详情页里每一集都没有进度。
  // 各集任务本来就在 app 级 InterconnectDownloadManager 里（键 = 远端集 id =
  // entryKey），集卡此前根本没去查。注入管理器后：进行中 → 进度环盖住云角标，
  // 完成后角标撤掉、云角标回来（下载完成 = 本地有了，重新解析后就不再是远端集）。
  testWidgets('远端集正在下载：集卡画进度环；完成后撤掉', (WidgetTester tester) async {
    for (final String uid in <String>['video/e1', 'video/e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    final InterconnectDownloadManager manager = InterconnectDownloadManager();
    addTearDown(manager.dispose);
    final Directory dir = Directory.systemTemp.createTempSync('fushi_coll_dl');
    addTearDown(() => dir.deleteSync(recursive: true));
    final Completer<void> gate = Completer<void>();
    void Function(double)? report;
    final Future<InterconnectDownloadTask> task = manager.startVideoDownload(
      id: 'video/e1',
      title: 'Show 01',
      dest: File('${dir.path}/e1.mp4'),
      run:
          (
            File target, {
            void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal,
          }) async {
            report = onProgress;
            await gate.future;
          },
    );

    useTallSurface(tester);
    await tester.pumpWidget(
      detailPage(
        remoteVideos: <RemoteVideoInfo>[
          remoteEpisode('video/e1', 'Show 01', 0),
          remoteEpisode('video/e2', 'Show 02', 1),
        ],
        downloads: manager,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final Finder badge = find.byKey(
      const ValueKey<String>('collection_episode_downloading_video/e1'),
    );
    expect(badge, findsOneWidget, reason: '正在下载的那一集必须画进度环');
    expect(
      find.byKey(
        const ValueKey<String>('collection_episode_downloading_video/e2'),
      ),
      findsNothing,
      reason: '没在下载的集不画',
    );
    report!(0.5);
    await tester.pump();
    expect(
      tester
          .widget<FushiDownloadProgressRing>(
            find.descendant(
              of: badge,
              matching: find.byType(FushiDownloadProgressRing),
            ),
          )
          .value,
      0.5,
      reason: '进度环跟着管理器的进度回报走',
    );

    gate.complete();
    await task;
    await tester.pump();
    expect(badge, findsNothing, reason: '下载完成后进度环撤掉');
  });

  testWidgets('点远端集卡：走远端流播入口，带全部远端成员与起播下标', (WidgetTester tester) async {
    for (final String uid in <String>['video/e1', 'video/e2']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    RemoteVideoInfo? opened;
    List<RemoteVideoInfo>? passedMembers;
    int? passedIndex;

    useTallSurface(tester);
    await tester.pumpWidget(
      detailPage(
        remoteVideos: <RemoteVideoInfo>[
          remoteEpisode('video/e1', 'Show 01', 0),
          remoteEpisode('video/e2', 'Show 02', 1),
        ],
        onOpenRemote:
            (
              RemoteVideoInfo episode,
              List<RemoteVideoInfo> members,
              int index,
            ) {
              opened = episode;
              passedMembers = members;
              passedIndex = index;
            },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('collection-episode-row-video/e2')),
    );
    await tester.pumpAndSettle();

    expect(opened?.id, 'video/e2');
    expect(passedMembers?.map((RemoteVideoInfo v) => v.id).toList(), <String>[
      'video/e1',
      'video/e2',
    ]);
    expect(passedIndex, 1);
  });

  // 反馈 _sZllpFQWm / BUG-3698：iPad 上「下载远端集」后没有地方能停、也找不到删
  // 下载副本的地方（任务列表只在 iOS 缺席的「浏览 → 下载」里）。合集详情页的集卡
  // 菜单就地给出互联下载的暂停 / 继续 / 取消，以及「删除本机副本」——后者只给
  // id 仍在对端清单里的本机成员，用户自己导入的本机原件不给。
  testWidgets('集卡菜单：远端集给继续 / 取消下载；下载副本给「删除本机副本」，本机原件不给', (
    WidgetTester tester,
  ) async {
    // e1：从对端下载来的副本（本机有行，id 也在对端清单里）；e2：用户自己的本机
    // 文件（对端没有）；e3：只在对端、上次下到一半被暂停。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/e1'),
        title: const Value('Show 01'),
        videoPath: const Value('/remote_videos/Show 01.mkv'),
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/e2'),
        title: const Value('Show 02'),
        videoPath: const Value('/v/Show 02.mkv'),
      ),
    );
    for (final String uid in <String>['video/e1', 'video/e2', 'video/e3']) {
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
    final InterconnectDownloadManager manager = InterconnectDownloadManager();
    addTearDown(manager.dispose);
    final Directory dir = Directory.systemTemp.createTempSync('fushi_coll_ic');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File dest = File('${dir.path}/e3.mp4');
    File('${dest.path}.part').writeAsBytesSync(List<int>.filled(10, 1));
    manager.registerPausedVideoDownload(
      id: 'video/e3',
      title: 'Show 03',
      dest: dest,
      run:
          (
            File target, {
            void Function(double progress)? onProgress,
            void Function(int received, int? total)? onBytes,
            Future<void>? cancelSignal,
          }) async {},
      receivedBytes: 10,
      totalBytes: 100,
    );
    final List<String> deletedCopies = <String>[];

    useTallSurface(tester);
    await tester.pumpWidget(
      detailPage(
        remoteVideos: <RemoteVideoInfo>[
          remoteEpisode('video/e1', 'Show 01', 0),
          remoteEpisode('video/e3', 'Show 03', 2),
        ],
        downloads: manager,
        deleteLocalCopy: (VideoBookRow row) async {
          deletedCopies.add(row.bookUid);
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openMenu(String uid) async {
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(ValueKey<String>('collection-episode-row-$uid')),
        ),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    Future<void> closeMenu() async {
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    await openMenu('video/e2');
    expect(
      find.text(t.collection_episode_local_copy_delete),
      findsNothing,
      reason: '对端没有这一集：是本机原件，不是下载副本',
    );
    await closeMenu();

    await openMenu('video/e3');
    expect(find.text(t.download_task_resume), findsOneWidget);
    expect(find.text(t.interconnect_download_cancel), findsOneWidget);
    expect(
      find.text(t.download_task_pause),
      findsNothing,
      reason: '暂停中的任务不再给暂停',
    );
    await tester.tap(find.text(t.interconnect_download_cancel));
    // 取消里有真实文件 IO（删 part / 清单）：交替让出真实时间与冲刷 fake zone。
    for (
      int i = 0;
      i < 200 &&
          (manager.taskFor('video/e3') != null ||
              File('${dest.path}.part').existsSync());
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(manager.taskFor('video/e3'), isNull, reason: '取消后任务移出');
    expect(
      File('${dest.path}.part').existsSync(),
      isFalse,
      reason: '取消删掉半成品，重开 app 不会再被自动续传',
    );

    await openMenu('video/e1');
    expect(find.text(t.collection_episode_local_copy_delete), findsOneWidget);
    await tester.tap(find.text(t.collection_episode_local_copy_delete));
    await tester.pumpAndSettle();
    expect(deletedCopies, <String>['video/e1']);
  });
}
