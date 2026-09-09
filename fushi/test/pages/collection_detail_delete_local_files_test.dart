import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-2389：合集详情页「删除合集」的二级勾选「同时删除本地文件」。
///
/// 此前这里只有一级勾选「同时删除其中的视频」，而它删的是 DB 行 + app 自己的
/// 封面/字幕副本——用户磁盘上的原始视频**一个都不会少**。二级勾选把这一维补上，
/// 决定经 `onDeleteMembersMedia(..., deleteLocalFiles:)` 交给注入方执行。
///
/// 两个方向都钉：有本机文件的成员才摆出勾选（远端流摆了也兑现不了），以及勾选
/// 状态必须真的传到回调（丢了这一位就退回本 BUG 的原始症状）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;

  /// [videoPath] 传 http URL = 远端流，本机没有文件可删。
  Future<void> seed({required String videoPath}) async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    LocaleSettings.setLocale(AppLocale.zhCn);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/e1'),
      title: const Value('E1'),
      videoPath: Value<String>(videoPath),
    ));
    collectionId = await db.createMediaCollection('Show');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
  }

  Widget buildApp({
    required void Function(bool deleteLocalFiles) onDelete,
  }) =>
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
              for (final VideoBookRow row in await db.allVideoBooks())
                CollectionEpisodeSlot.local(row),
            ],
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
            onDeleteMembersMedia: (
              List<VideoBookRow> members, {
              required bool deleteLocalFiles,
            }) async =>
                onDelete(deleteLocalFiles),
          ),
        ),
      );

  Future<void> openDeleteDialog(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection).last);
    await tester.pumpAndSettle();
  }

  testWidgets('本机有文件的成员：勾一级后出现二级，勾上后回调收到 true', (WidgetTester tester) async {
    await seed(videoPath: '/abs/e1.mkv');
    bool? received;
    await tester.pumpWidget(buildApp(onDelete: (bool v) => received = v));
    await openDeleteDialog(tester);

    expect(find.text(t.delete_local_files), findsNothing,
        reason: '一级没勾时二级不该在场——不删条目就无从谈删它的文件');

    await tester.tap(find.text(t.delete_collection_also_videos));
    await tester.pumpAndSettle();
    expect(find.text(t.delete_local_files), findsOneWidget);

    await tester.tap(find.text(t.delete_local_files));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection).last);
    await tester.pumpAndSettle();

    expect(received, isTrue, reason: '丢了这一位，删除就只剩库记录、磁盘原件一个不少（BUG-2389）');
  });

  testWidgets('只勾一级不勾二级：回调收到 false（原件保留是默认）', (WidgetTester tester) async {
    await seed(videoPath: '/abs/e1.mkv');
    bool? received;
    await tester.pumpWidget(buildApp(onDelete: (bool v) => received = v));
    await openDeleteDialog(tester);

    await tester.tap(find.text(t.delete_collection_also_videos));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.delete_collection).last);
    await tester.pumpAndSettle();

    expect(received, isFalse);
  });

  testWidgets('成员全是远端流：不摆二级勾选（本机没有文件可删）', (WidgetTester tester) async {
    await seed(videoPath: 'https://example.com/e1.m3u8');
    await tester.pumpWidget(buildApp(onDelete: (bool _) {}));
    await openDeleteDialog(tester);

    await tester.tap(find.text(t.delete_collection_also_videos));
    await tester.pumpAndSettle();

    expect(find.text(t.delete_local_files), findsNothing,
        reason: '远端流在本机没有文件，摆出勾选就是兑现不了的承诺');
  });
}
