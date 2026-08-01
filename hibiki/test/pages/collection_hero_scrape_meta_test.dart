import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:hibiki/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:hibiki/src/media/video/scraper/scraper_types.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-1310 守卫：合集详情页 hero 展示刮削回来的作品资料。
///
/// 用户报「还少了数据」——刮完封面后详情页除了标题和进度什么都没有。根因不在展示层
/// 而在数据模型：元数据此前只有 `video_scrape_meta`（主键 bookUid）这一个宿主，
/// 承载的是**单集**资料；简介/评分/放送/标签属于「一部作品」= 合集，而合集没有宿主，
/// 于是合集刮削只能下一张海报就结束，资料根本没被请求过。
///
/// 本文件锁三件事：
///  1. 有资料 → hero 渲染年份/话数/评分/评分人数/标签/简介/原名；
///  2. 无资料 → 回落到「标题 + 进度 + 播放」的旧形态，且**不出现**任何空占位；
///  3. 背景槽向：有横版 backdrop 用它（正确槽向），无则回落 [LandscapeCoverImage]，
///     且两种情况下海报卡的出现与否互斥（同一张图不得在同屏出现两次）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/e1'),
      title: const Value('S01E01'),
      videoPath: const Value('/abs/e1.mp4'),
      importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
    ));
    collectionId = await db.createMediaCollection(
      'Tensei Oujo v2 播放列表',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
  });

  tearDown(() => db.close());

  Future<List<VideoBookRow>> loadMembers() async => <VideoBookRow>[
        for (final MediaCollectionItemRow it
            in await db.getCollectionItems(collectionId))
          (await db.allVideoBooks())
              .firstWhere((VideoBookRow r) => r.bookUid == it.entryKey),
      ];

  Future<void> saveMeta({
    String? backdropPath,
    String coverPath = '/covers/collections/1.jpg',
    // 改名只在用户于确认弹窗点了确认时发生（BUG-1310 复议）；hero 资料本身与改名
    // 无关，故默认不改名，只有专测标题回写的用例才传。
    String? confirmedTitle,
  }) =>
      applyCollectionScrape(
        db,
        collectionId,
        CollectionScrapeResult(
          coverPath: coverPath,
          backdropPath: backdropPath,
          metadata: const ScrapeMetadata(
            source: ScrapeSource.tmdb,
            subjectId: '100',
            title: '转生王女与天才令嬢的魔法革命',
            originalTitle: '転生王女と天才令嬢の魔法革命',
            summary: '公主与令嬢携手掀起魔法革命的故事。',
            airDate: '2023-01-04',
            rating: 8.2,
            ratingCount: 1234,
            episodeCount: 12,
            tags: <ScrapeTag>[
              ScrapeTag(name: '奇幻', count: 900),
              ScrapeTag(name: '百合', count: 800),
            ],
          ),
        ),
        confirmedTitle: confirmedTitle,
      );

  Widget buildApp() => TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: db,
            collection: MediaCollectionRow(
              id: collectionId,
              name: 'Tensei Oujo v2 播放列表',
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

  /// 屏够宽才会出海报卡（窄屏刻意不出，见 `_buildHero` 的 LayoutBuilder）。
  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  testWidgets('有刮削资料 → hero 渲染年份/话数/评分/标签/简介/原名', (WidgetTester tester) async {
    await saveMeta();
    await pumpWide(tester);

    // 元数据行是一条拼起来的文本，逐段断言其成分。
    final String metaLine = tester
        .widgetList<Text>(find.byType(Text))
        .map((Text w) => w.data ?? '')
        .firstWhere((String s) => s.contains('★'), orElse: () => '');
    expect(metaLine, contains('2023'), reason: '年份取自 airDate 前 4 位');
    expect(metaLine, contains('全 12 话'));
    expect(metaLine, contains('★ 8.2'));
    expect(metaLine, contains('1234 人评分'));
    expect(metaLine, contains('已看完 0/1'), reason: '观看进度不依赖刮削，恒在');

    expect(find.textContaining('公主与令嬢携手掀起魔法革命'), findsOneWidget,
        reason: '简介必须出现在 hero');
    // 作品标签是 chips（每个标签一个 Text），不是拼起来的一行文字。
    expect(find.text('奇幻'), findsOneWidget, reason: '作品标签按热度降序成 chip');
    expect(find.text('百合'), findsOneWidget);
    expect(find.text('転生王女と天才令嬢の魔法革命'), findsOneWidget, reason: '原名作副标题');
  });

  testWidgets('用户确认改名 → hero 标题用条目正名，不再是文件夹名', (WidgetTester tester) async {
    await saveMeta(confirmedTitle: '转生王女与天才令嬢的魔法革命');
    await pumpWide(tester);

    expect(find.text('转生王女与天才令嬢的魔法革命'), findsOneWidget);
    expect(
      find.text('Tensei Oujo v2 播放列表'),
      findsNothing,
      reason: '合集名已被刮削回写；详情页只认进页快照的话会停在旧文件夹名',
    );
  });

  testWidgets('用户未确认改名 → hero 资料照常显示，标题仍是原合集名', (WidgetTester tester) async {
    await saveMeta();
    await pumpWide(tester);

    // 拒绝改名不等于拒绝整次刮削：简介 / 评分 / 原名照常落地并显示。
    expect(find.textContaining('公主与令嬢携手掀起魔法革命'), findsOneWidget);
    expect(find.text('転生王女と天才令嬢の魔法革命'), findsOneWidget, reason: '原名作副标题');
    // 但标题一字不动。
    expect(find.text('Tensei Oujo v2 播放列表'), findsOneWidget);
    expect(
      find.text('转生王女与天才令嬢的魔法革命'),
      findsNothing,
      reason: '用户没确认就把标题换成刮到的正名 = 静默覆盖（BUG-1310 复议口径）',
    );
  });

  testWidgets('未刮削 → 回落旧形态：只有标题 + 进度 + 播放，无空占位', (WidgetTester tester) async {
    await pumpWide(tester);

    expect(find.text('Tensei Oujo v2 播放列表'), findsOneWidget);
    expect(find.textContaining('已看完'), findsWidgets);
    expect(find.textContaining('★'), findsNothing, reason: '没有评分就不该出现评分符号');
    expect(find.textContaining('全 '), findsNothing, reason: '没有话数就不该出现「全 N 话」');
    expect(
      find.byKey(const ValueKey<String>('collection-hero-poster')),
      findsNothing,
      reason: '没有横版背景就不出海报卡（海报由 LandscapeCoverImage 显示）',
    );
  });

  testWidgets('有横版 backdrop → 背景用 backdrop + 左侧独立海报卡',
      (WidgetTester tester) async {
    await saveMeta(backdropPath: '/covers/collections/1_backdrop.jpg');
    await pumpWide(tester);

    expect(
      find.byKey(const ValueKey<String>('collection-hero-backdrop')),
      findsOneWidget,
      reason: '有横图就该直接喂给宽幅槽——这是 BUG-1298 的正解，而非把海报硬塞进去',
    );
    expect(
      find.byKey(const ValueKey<String>('collection-hero-poster')),
      findsOneWidget,
      reason: '海报回到它自己的 2:3 卡槽',
    );
    expect(
      find.byType(LandscapeCoverImage),
      findsNothing,
      reason: '有真横图时不需要模糊垫底那套补救',
    );
  });

  testWidgets('无横版 backdrop → 回落 LandscapeCoverImage，且不重复出海报卡',
      (WidgetTester tester) async {
    await saveMeta();
    await pumpWide(tester);

    expect(
      find.byType(LandscapeCoverImage),
      findsOneWidget,
      reason: 'Bangumi / 离线库没有横版图，这是它们的常态路径',
    );
    expect(
      find.byKey(const ValueKey<String>('collection-hero-backdrop')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('collection-hero-poster')),
      findsNothing,
      reason: '此时海报已由 LandscapeCoverImage 清晰显示，再放一张卡就是同图两现',
    );
  });
}
