import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-2491 hayase 式集列表宽卡：
/// ① 集级刮削集名/简介上卡（无刮削回落文件名标题）；
/// ② 宽屏（可用宽 ≥ 900）两列、窄屏一列；
/// ③ 集卡右键菜单提供「移出合集」（管理能力收进菜单后不得丢失）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    for (final (String uid, String title) in const <(String, String)>[
      ('video/e1', 'Show 01'),
      ('video/e2', 'Show 02'),
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
      summary: const Value<String?>('主角与伙伴初次相遇的一集。'),
      episodeNumber: const Value<int?>(1),
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
            loadEpisodes: () async => <CollectionEpisodeSlot>[
              for (final VideoBookRow row in await (loadMembers)())
                CollectionEpisodeSlot.local(row),
            ],
            onOpenEpisode: (VideoBookRow _) {},
            onChanged: () {},
          ),
        ),
      );

  void useSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder cardOf(String uid) =>
      find.byKey(ValueKey<String>('collection-episode-row-$uid'));

  testWidgets('集级刮削集名/简介上卡；未刮削的集回落文件名标题', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    await seedEpisodeMeta();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('出会い'), findsWidgets, reason: 'e1 有集级刮削 → 集名上卡');
    expect(find.textContaining('主角与伙伴初次相遇'), findsOneWidget, reason: '集简介上卡');
    expect(
      find.descendant(
        of: find.byType(FushiReorderableGrid),
        matching: find.textContaining('Show 02'),
      ),
      findsOneWidget,
      reason: 'e2 无集级刮削 → 回落文件名标题',
    );
  });

  testWidgets('BUG-1546：超长文件名标题两行换行显示，不再单行截断', (WidgetTester tester) async {
    useSurface(tester, const Size(700, 1600));
    const String longTitle =
        '[VCB-Studio] Gekijouban Hibike! Euphonium Todoketai Melody '
        '[IV][Ma10p_1080p][x265_flac] 特典映像';
    // 覆写第 1 集标题（首卡必在视口内；追加第 3 集会落在懒加载网格视口外）。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/e1'),
      title: const Value(longTitle),
      videoPath: const Value('/v/Show 01.mkv'),
    ));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 限定在集卡内找标题——页面 hero（继续看行等）也会渲染同一条目标题。
    final RenderParagraph title = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: cardOf('video/e1'),
        matching: find.textContaining('Todoketai Melody'),
      ),
    );
    final TextStyle style = title.text.style!;
    final double lineHeight = (style.fontSize ?? 14) * (style.height ?? 1.5);
    expect(
      title.size.height,
      greaterThan(lineHeight * 1.5),
      reason: '窄单列下这条发布名必然超过一行；只有一行高说明集卡标题又被 '
          'maxLines:1 单行截断（BUG-1546 回归），集号/规格被省略号吃掉',
    );
    expect(tester.takeException(), isNull,
        reason: '两行标题 + 状态行必须仍在 128 卡高内，不得 RenderFlex 溢出');
  });

  testWidgets('宽屏（≥900）两列：两张集卡同一行', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Offset c1 = tester.getTopLeft(cardOf('video/e1'));
    final Offset c2 = tester.getTopLeft(cardOf('video/e2'));
    expect(c1.dy, c2.dy, reason: '宽屏两列：第 1、2 集应并排同一行');
    expect(c2.dx, greaterThan(c1.dx));
  });

  testWidgets('窄屏（<900）一列：集卡纵向堆叠', (WidgetTester tester) async {
    useSurface(tester, const Size(700, 1600));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final Offset c1 = tester.getTopLeft(cardOf('video/e1'));
    final Offset c2 = tester.getTopLeft(cardOf('video/e2'));
    expect(c1.dx, c2.dx, reason: '窄屏一列：集卡左缘对齐');
    expect(c2.dy, greaterThan(c1.dy));
  });

  testWidgets('「在 Bangumi 打开本集」菜单项：仅 Bangumi 绑定的合集出现',
      (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    await db.upsertCollectionScrapeMeta(CollectionScrapeMetaCompanion.insert(
      collectionId: Value<int>(collectionId),
      source: 'bangumi',
      subjectId: '100',
      title: 'Show',
      scrapedAt: DateTime(2026),
    ));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cardOf('video/e1')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(t.collection_episode_open_bangumi), findsOneWidget,
        reason: 'Bangumi 绑定合集的集卡菜单必须有外链项（TODO-2488 降级实现）');
  });

  testWidgets('未刮削合集：集卡菜单不出现 Bangumi 外链项', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cardOf('video/e1')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(t.collection_episode_open_bangumi), findsNothing);
    expect(find.text(t.collection_episode_download), findsOneWidget,
        reason: '下载本集不依赖刮削绑定，恒在');
    // 关掉菜单，别把打开的菜单留给下一个用例。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  });

  testWidgets('集卡右键菜单「移出合集」真移出（管理能力收进菜单不丢失）', (WidgetTester tester) async {
    useSurface(tester, const Size(1280, 1600));
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(cardOf('video/e2')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text(t.collection_remove_member), findsOneWidget,
        reason: '右键集卡必须弹出上下文菜单');
    await tester.tap(find.text(t.collection_remove_member));
    await tester.pumpAndSettle();
    // 确认框（FushiDestructiveConfirmDialog）→ 确认移出。
    await tester.tap(find.text(t.collection_remove_member).last);
    await tester.pumpAndSettle();

    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collectionId);
    expect(
      items.map((MediaCollectionItemRow it) => it.entryKey).toList(),
      <String>['video/e1'],
      reason: '菜单移出必须真写穿 DB',
    );
  });
}
