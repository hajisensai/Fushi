import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// 把视频文件拖进合集详情页 = 导入并直接归入本合集（此前只能在视频库首页拖入，
/// 再手动「加入合集」）。
///
/// 驱动的是页面上真实挂着的 [FushiFileDropTarget]（经 `runDrop`，与 desktop_drop
/// 落地后走的是同一个咽喉），断言落在 DB 的合集成员表上，而不是某个回调被调用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;
  late int changedCalls;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    changedCalls = 0;
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
      // 已在库、但还不在本合集：拖进来应直接复用这一行，不弹导入框。
      ('video/e3', 'Show 03'),
    ]) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value(title),
          videoPath: Value('/v/$title.mkv'),
        ),
      );
    }
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<List<String>> memberUids() async => <String>[
    for (final MediaCollectionItemRow it in await db.getCollectionItems(
      collectionId,
    ))
      it.entryKey,
  ];

  Future<List<VideoBookRow>> loadMembers() async {
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in await db.allVideoBooks()) r.bookUid: r,
    };
    return <VideoBookRow>[
      for (final String uid in await memberUids())
        if (byUid[uid] case final VideoBookRow row) row,
    ];
  }

  Future<void> pumpDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: MediaCollectionRow(
              id: collectionId,
              name: 'Show',
              collectionType: 'playlist',
              coverSource: null,
              sortOrder: 0,
              createdAt: 0,
              orderUpdatedAt: 0,
            ),
            loadEpisodes: () async => <CollectionEpisodeSlot>[
              for (final VideoBookRow row in await loadMembers())
                CollectionEpisodeSlot.local(row),
            ],
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () => changedCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> drop(WidgetTester tester, List<String> paths) async {
    final FushiFileDropTarget target = tester.widget<FushiFileDropTarget>(
      find.descendant(
        of: find.byType(MaterialApp),
        matching: find.byType(FushiFileDropTarget),
      ),
    );
    final Future<void> done = target.runDrop(paths, Offset.zero);
    await tester.pumpAndSettle();
    await done;
    await tester.pumpAndSettle();
  }

  testWidgets('拖入已在库的视频：直接归入本合集末尾、不弹导入框、刷新库页', (WidgetTester tester) async {
    await pumpDetail(tester);
    expect(find.text('Show 03'), findsNothing, reason: '前置：第 3 集还不在合集里');

    await drop(tester, <String>['/v/Show 03.mkv']);

    expect(
      find.byType(VideoImportDialog),
      findsNothing,
      reason: '已在库的同一文件必须复用那一行，不能再走导入派生第二身份',
    );
    expect(await memberUids(), <String>[
      'video/e1',
      'video/e2',
      'video/e3',
    ], reason: '拖进来的视频落到合集成员表末尾');
    expect(changedCalls, 1, reason: '成员变了要通知库页刷新');
  });

  testWidgets('拖入已是成员的视频：不重复加入、不通知刷新', (WidgetTester tester) async {
    await pumpDetail(tester);

    await drop(tester, <String>['/v/Show 01.mkv']);

    expect(await memberUids(), <String>['video/e1', 'video/e2']);
    expect(changedCalls, 0);
  });

  testWidgets('拖入非视频文件：成员不变', (WidgetTester tester) async {
    await pumpDetail(tester);

    await drop(tester, <String>['/v/notes.txt', '/v/show.torrent']);

    expect(await memberUids(), <String>['video/e1', 'video/e2']);
    expect(changedCalls, 0);
  });

  testWidgets('拖入未入库的视频：弹出预填的视频导入框，取消则不改成员', (WidgetTester tester) async {
    await pumpDetail(tester);

    final FushiFileDropTarget target = tester.widget<FushiFileDropTarget>(
      find.byType(FushiFileDropTarget),
    );
    final Future<void> done = target.runDrop(<String>[
      '/v/Show 04.mkv',
    ], Offset.zero);
    await tester.pumpAndSettle();

    final Finder dialog = find.byType(VideoImportDialog);
    expect(dialog, findsOneWidget, reason: '未入库的文件走与首页同一个导入框');
    expect(
      tester.widget<VideoImportDialog>(dialog).initialVideoPath,
      '/v/Show 04.mkv',
    );

    Navigator.of(tester.element(dialog)).pop();
    await tester.pumpAndSettle();
    await done;

    expect(await memberUids(), <String>['video/e1', 'video/e2']);
    expect(changedCalls, 0);
  });
}
