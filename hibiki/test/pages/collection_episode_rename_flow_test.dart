import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2491：「按刮削重命名各集」确认流程。
/// ① dryRun 对照表上弹窗（旧名/新名逐行可勾选）；② 确认后只对勾选子集写穿
/// `video_books.title`；③ 无可改（未刮集级资料）→ 直接提示，零弹窗零写入。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'raw_file_01'),
      ('video/e2', 'raw_file_02'),
    ]) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/v/$title.mkv'),
      ));
    }
    collectionId =
        await db.createMediaCollection('Show', collectionType: 'playlist');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/e2');
  });

  tearDown(() => db.close());

  Future<void> seedEpisodeMeta() async {
    await db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
      bookUid: 'video/e1',
      source: 'bangumi',
      subjectId: '100',
      title: '出会い',
      episodeNumber: const Value<int?>(1),
      scrapedAt: DateTime(2026),
    ));
    await db.upsertVideoScrapeMeta(VideoScrapeMetaCompanion.insert(
      bookUid: 'video/e2',
      source: 'bangumi',
      subjectId: '100',
      title: '別れ',
      episodeNumber: const Value<int?>(2),
      scrapedAt: DateTime(2026),
    ));
  }

  Future<List<VideoBookRow>> loadMembers() async {
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    final List<VideoBookRow> all = await db.allVideoBooks();
    final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
      for (final VideoBookRow r in all) r.bookUid: r,
    };
    return <VideoBookRow>[
      for (final MediaCollectionItemRow it in items)
        if (byUid[it.entryKey] case final VideoBookRow row) row,
    ];
  }

  Widget buildApp() => TranslationProvider(
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
            loadMembers: loadMembers,
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
          ),
        ),
      );

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Future<String?> titleOf(String uid) async => (await db.allVideoBooks())
      .firstWhere((VideoBookRow r) => r.bookUid == uid)
      .title;

  testWidgets('确认全部 → 两集集名都写穿 E01/E02 格式', (WidgetTester tester) async {
    await seedEpisodeMeta();
    await pumpWide(tester);

    await tester.tap(find.byIcon(Icons.format_list_numbered));
    await tester.pumpAndSettle();

    expect(find.text('raw_file_01'), findsWidgets, reason: '弹窗逐行显示旧名');
    expect(find.text('E01 出会い'), findsOneWidget, reason: '弹窗逐行显示新名');
    expect(find.text('E02 別れ'), findsOneWidget);

    await tester.tap(find.text(t.collection_episode_rename_apply(n: 2)));
    await tester.pumpAndSettle();

    expect(await titleOf('video/e1'), 'E01 出会い');
    expect(await titleOf('video/e2'), 'E02 別れ');
  });

  testWidgets('取消勾选一集 → 只重命名勾选子集', (WidgetTester tester) async {
    await seedEpisodeMeta();
    await pumpWide(tester);

    await tester.tap(find.byIcon(Icons.format_list_numbered));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(
      const ValueKey<String>('episode-rename-row-video/e2'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.collection_episode_rename_apply(n: 1)));
    await tester.pumpAndSettle();

    expect(await titleOf('video/e1'), 'E01 出会い');
    expect(await titleOf('video/e2'), 'raw_file_02', reason: '未勾选的集一字不改');
  });

  testWidgets('未刮集级资料 → 无对照，直接提示零弹窗零写入', (WidgetTester tester) async {
    await pumpWide(tester);

    await tester.tap(find.byIcon(Icons.format_list_numbered));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing, reason: '空对照不该弹确认框');
    expect(await titleOf('video/e1'), 'raw_file_01');
    expect(await titleOf('video/e2'), 'raw_file_02');
  });
}
