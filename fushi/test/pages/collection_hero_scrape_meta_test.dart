import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1310 守卫：合集详情页 hero 展示刮削回来的作品资料。
///
/// 用户报「还少了数据」——刮完封面后详情页除了标题和进度什么都没有。根因不在展示层
/// 而在数据模型：元数据此前只有 `video_scrape_meta`（主键 bookUid）这一个宿主，
/// 承载的是**单集**资料；简介/评分/放送/标签属于「一部作品」= 合集，而合集没有宿主，
/// 于是合集刮削只能下一张海报就结束，资料根本没被请求过。
///
/// 本文件锁三件事：
///  1. 有资料 → hero 渲染年份/话数/评分/评分人数/标签/简介/原名；
///  2. 无资料 → 保留标题 + 进度 + 播放，并明确提示从来源重试刮削；
///  3. 背景槽向（2026-10 M3E 重做）：有横版 backdrop 用它轻模糊铺满，无则拿封面
///     重模糊垫底；2:3 封面恒在独立封面卡里清晰显示（[PortraitCoverImage] 按朝向
///     分流），不再把海报硬塞进宽幅槽（BUG-1298）。
///
/// 2026-11 重设计外壳（海报面板，[VideoPosterDetailHero]）：宽屏不再左右两栏，hero
/// 整宽在顶、自带背景带；放送日期收成年份胶囊；页头（[MediaPosterDetailChrome]）
/// 常驻一份作品名（滚过 hero 后淡入），所以标题断言限定在 hero 卡内。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // BUG-3756：封面存在性改为 async 探测后，测试要用 runAsync 让真实 IO 回话；同一
  // 窗口里远程封面（CachedNetworkImage）的磁盘缓存管理器也会真的起来，要
  // path_provider 应答。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'collection_hero_pp_',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  late FushiDatabase db;
  late int collectionId;
  late Directory coverDir;

  /// 合集自有封面必须是磁盘上真实存在的文件——详情页与库页同样只认存在的本地
  /// 封面，悬空路径按「没设过」处理（BUG-3638）。
  late String existingCoverPath;

  setUp(() async {
    coverDir = Directory.systemTemp.createTempSync('collection_hero_cover_');
    existingCoverPath = '${coverDir.path}${Platform.pathSeparator}1.jpg';
    File(existingCoverPath).writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ),
    );
    collectionId = await db.createMediaCollection(
      'Tensei Oujo v2 播放列表',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/e1');
  });

  tearDown(() async {
    await db.close();
    coverDir.deleteSync(recursive: true);
  });

  Future<List<VideoBookRow>> loadMembers() async => <VideoBookRow>[
    for (final MediaCollectionItemRow it in await db.getCollectionItems(
      collectionId,
    ))
      (await db.allVideoBooks()).firstWhere(
        (VideoBookRow r) => r.bookUid == it.entryKey,
      ),
  ];

  Future<void> saveMeta({
    String? backdropPath,
    String? coverPath,
    // 改名只在用户于确认弹窗点了确认时发生（BUG-1310 复议）；hero 资料本身与改名
    // 无关，故默认不改名，只有专测标题回写的用例才传。
    String? confirmedTitle,
  }) async {
    await db.updateMediaCollectionCoverPath(
      collectionId,
      coverPath ?? existingCoverPath,
    );
    await db.upsertCollectionScrapeMeta(
      CollectionScrapeMetaCompanion.insert(
        collectionId: Value<int>(collectionId),
        source: 'tmdb',
        subjectId: '100',
        title: '转生王女与天才令嬢的魔法革命',
        originalTitle: const Value<String?>('転生王女と天才令嬢の魔法革命'),
        summary: const Value<String?>('公主与令嬢携手掀起魔法革命的故事。'),
        airDate: const Value<String?>('2023-01-04'),
        rating: const Value<double?>(8.2),
        ratingCount: const Value<int?>(1234),
        episodeCount: const Value<int?>(12),
        tagsJson: const Value<String?>(
          '[{"name":"奇幻","count":900},{"name":"百合","count":800}]',
        ),
        scrapedAt: DateTime(2026, 1, 1),
      ),
    );
    await db
        .replaceMediaImagesForCollection(collectionId, <MediaImagesCompanion>[
          if (backdropPath != null)
            MediaImagesCompanion.insert(
              collectionId: Value<int?>(collectionId),
              kind: MediaImageKind.backdrop.dbValue,
              path: backdropPath,
            ),
        ]);
    if (confirmedTitle != null) {
      await db.renameMediaCollection(collectionId, confirmedTitle);
    }
  }

  Widget buildApp() => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          origin: 'user',
          organizeAliases: '',
          id: collectionId,
          name: 'Tensei Oujo v2 播放列表',
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

  /// 海报面板按封面取色（[MediaPosterDetailTheme] → 进程级 `coverColorSchemeCache`
  /// → `extractImageProviderSeedArgb` 给图片加载挂 10 秒超时）。远程封面在
  /// fakeAsync 里永远加载不完，这条取色请求属于进程级缓存、按设计不随页面销毁，
  /// 测试结束时把 10 秒走完（超时落 null），免得定时器挂到 widget 树销毁之后。
  Future<void> drainCoverTint(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 11));

  /// 限定在 hero 卡里找：页头（[MediaPosterDetailChrome]）常驻一份作品名（滚过
  /// hero 后才淡入），全页找同名文本会命中两处。
  Finder inHero(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey<String>('video-work-hero-card')),
    matching: matching,
  );

  /// BUG-3756：hero 封面链的存在性改为 async 探测（build 里不再同步 stat），真实
  /// IO 在 fakeAsync 下不会完成。链上每级一次探测 + 一次重建，按链深各给一轮。
  Future<void> settleCoverProbes(WidgetTester tester, {int rounds = 4}) async {
    // 封面链每级一次探测 + 一次重建；之后封面图源的真实文件读取（打开 → 读 → 关）
    // 每一步的续体都排在 fakeAsync 里，要 runAsync 让 IO 回话、再 pump 跑续体，多给
    // 几轮让句柄关掉，否则 tearDown 删临时目录会撞「文件被占用」（Windows）。
    for (int i = 0; i < rounds + 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  /// 宽屏：海报面板宽式，hero 整宽在顶；≥ 1300 时附栏（接着看 / 作品资料）单独
  /// 成右列。
  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await settleCoverProbes(tester);
  }

  /// 中等宽（≥ 720 走宽式、< 1300 附栏接在下段）：海报在左、文字在右，hero 自己
  /// 画大背景。
  Future<void> pumpSingleColumn(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await settleCoverProbes(tester);
  }

  testWidgets('宽屏海报面板：hero 整宽在顶、自带背景带，附栏单独成右列', (WidgetTester tester) async {
    await saveMeta(backdropPath: '/covers/collections/1_backdrop.jpg');
    await pumpWide(tester);

    final Finder hero = find.byKey(
      const ValueKey<String>('video-work-hero-card'),
    );
    expect(hero, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('media-detail-side-pane')),
      findsNothing,
      reason: '重设计外壳不再左右两栏：hero 整宽在顶，选集等区块接在下面',
    );
    final Rect heroRect = tester.getRect(hero);
    expect(heroRect.left, 0, reason: 'hero 背景带从内容区左边缘铺起');
    expect(heroRect.right, 1600, reason: 'hero 背景带铺到内容区右边缘');
    expect(
      find.descendant(
        of: hero,
        matching: find.byKey(
          const ValueKey<String>('collection-hero-backdrop'),
        ),
      ),
      findsOneWidget,
      reason: '有横版 backdrop 时 hero 自己画背景带',
    );
    expect(
      find.descendant(
        of: hero,
        matching: find.byKey(const ValueKey<String>('collection-hero-poster')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: hero,
        matching: find.byKey(
          const ValueKey<String>('media-poster-detail-aside'),
        ),
      ),
      findsOneWidget,
      reason: '宽 ≥ 1300 时「接着看」/ 作品资料附栏单独占右列',
    );
  });

  testWidgets('有刮削资料 → hero 渲染放送日期/话数/评分/标签/简介/原名', (
    WidgetTester tester,
  ) async {
    await saveMeta();
    await pumpWide(tester);

    // 海报面板：放送日期收成年份胶囊（旧刮削资料没有规范作品宿主时从放送日期
    // 取年份）；年份/话数/评分/评分人数/观看进度是信息胶囊，各自一个 Text。
    expect(find.text('2023'), findsOneWidget, reason: '放送年份进信息胶囊，不随版式改版丢失');
    expect(find.text('全 12 话'), findsOneWidget);
    expect(find.text('★ 8.2'), findsOneWidget);
    expect(find.text('1234 人评分'), findsOneWidget);
    expect(find.text('已看完 0/1'), findsOneWidget, reason: '观看进度不依赖刮削，恒在');

    expect(
      find.textContaining('公主与令嬢携手掀起魔法革命'),
      findsOneWidget,
      reason: '简介必须出现在 hero',
    );
    // 作品标签是 chips（每个标签一个 Text），不是拼起来的一行文字。
    expect(find.text('奇幻'), findsOneWidget, reason: '作品标签按热度降序成 chip');
    expect(find.text('百合'), findsOneWidget);
    expect(find.text('転生王女と天才令嬢の魔法革命'), findsOneWidget, reason: '原名作副标题');
  });

  testWidgets('用户确认改名 → hero 标题用条目正名，不再是文件夹名', (WidgetTester tester) async {
    await saveMeta(confirmedTitle: '转生王女与天才令嬢的魔法革命');
    await pumpWide(tester);

    expect(inHero(find.text('转生王女与天才令嬢的魔法革命')), findsOneWidget);
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
    expect(inHero(find.text('Tensei Oujo v2 播放列表')), findsOneWidget);
    expect(
      find.text('转生王女与天才令嬢的魔法革命'),
      findsNothing,
      reason: '用户没确认就把标题换成刮到的正名 = 静默覆盖（BUG-1310 复议口径）',
    );
  });

  testWidgets('未刮削 → 保留播放能力并明确显示资料待刮削状态', (WidgetTester tester) async {
    await pumpWide(tester);

    expect(
      find.byKey(const ValueKey<String>('video-work-hero-card')),
      findsOneWidget,
      reason: '合集详情必须使用作品级 hero',
    );
    expect(inHero(find.text('Tensei Oujo v2 播放列表')), findsOneWidget);
    expect(find.textContaining('已看完'), findsWidgets);
    // 旧锚点是「暂无详细资料」——那是 #792 引入时就断在半截的文案
    // （`暂无详细资料。请在`，介词悬空），断句处恰好在锚点之后，所以这条断言
    // 从来没能发现它。文案补全后锚点跟着走，仍只匹配待刮削态这一句。
    expect(find.textContaining('尚未刮削详细资料'), findsOneWidget);
    expect(find.textContaining('★'), findsNothing, reason: '没有评分就不该出现评分符号');
    expect(
      find.text('全 1 话'),
      findsOneWidget,
      reason: '本地作品索引会用确定的合集成员数补出话数，但不会伪造在线评分',
    );
    expect(
      find.byKey(const ValueKey<String>('collection-hero-poster')),
      findsNothing,
      reason: '没有任何封面就不出封面卡（不画空框）',
    );
  });

  testWidgets('有横版 backdrop → 背景用 backdrop + 左侧独立海报卡', (
    WidgetTester tester,
  ) async {
    await saveMeta(backdropPath: '/covers/collections/1_backdrop.jpg');
    await pumpSingleColumn(tester);

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
    final Rect hero = tester.getRect(
      find.byKey(const ValueKey<String>('video-work-hero-card')),
    );
    expect(hero.left, 0, reason: '大背景必须从内容区左边缘开始，不能居中留白');
    expect(hero.right, 1000, reason: '大背景必须平铺到内容区右边缘');
    // 海报面板宽式：海报列宽取 hero 宽的 17%（夹 150..220），高按封面固有比例
    // （测试封面解码不出 → 2:3）；压过背景带下沿，不缩成角落的小卡。
    final Size poster = tester.getSize(
      find.byKey(const ValueKey<String>('collection-hero-poster')),
    );
    expect(poster.width, inInclusiveRange(150, 220));
    expect(poster.height, closeTo(poster.width * 1.5, 1));
    expect(
      find.byType(LandscapeCoverImage),
      findsNothing,
      reason: '有真横图时不需要模糊垫底那套补救',
    );
  });

  testWidgets('作品目录无法安全落盘时仍用规范远程背景与大海报', (WidgetTester tester) async {
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Remote artwork series',
        updatedAt: 1,
      ),
    );
    await db.replaceVideoMetadataImages(
      workId: workId,
      images: <VideoMetadataImagesCompanion>[
        VideoMetadataImagesCompanion.insert(
          provider: 'tmdb',
          kind: 'cover',
          remoteUrl: 'https://image.example/poster.jpg',
          updatedAt: 1,
        ),
        VideoMetadataImagesCompanion.insert(
          provider: 'tmdb',
          kind: 'backdrop',
          remoteUrl: 'https://image.example/backdrop.jpg',
          updatedAt: 1,
        ),
      ],
    );

    await pumpSingleColumn(tester);

    expect(
      find.byKey(const ValueKey<String>('collection-hero-backdrop')),
      findsOneWidget,
    );
    final PortraitCoverImage poster = tester.widget<PortraitCoverImage>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('collection-hero-poster')),
        matching: find.byType(PortraitCoverImage),
      ),
    );
    expect(poster.image, isA<ResizeImage>());
    final ImageProvider<Object> remote =
        (poster.image as ResizeImage).imageProvider;
    // 远端封面统一走 CachedNetworkImageProvider（自带磁盘缓存，见
    // test/pages/video_remote_cover_disk_cache_guard_test.dart）；此前这里断言的
    // NetworkImage 只有内存缓存。本条守的不是 provider 品牌，而是**图源**：
    // 落盘被安全目录判定拦下时，海报必须仍指向刮削回来的规范远程 URL。
    expect(
      remote,
      isA<CachedNetworkImageProvider>(),
      reason: '远端封面必须用带磁盘缓存的 provider',
    );
    expect(
      (remote as CachedNetworkImageProvider).url,
      'https://image.example/poster.jpg',
      reason: '安全目录判定阻止作品根图落盘时，详情页不能退回分集截图',
    );
    // settleCoverProbes 给真实 IO 的 runAsync 窗口里远程封面的磁盘缓存也真的起来了，
    // 它排了一个 10 秒的清理定时器；海报面板取色也给远程封面挂了 10 秒加载超时。
    // 走完它们，免得测试结束时还有定时器挂着。
    await drainCoverTint(tester);
  });

  // BUG：剧集目录从 `D:\smb\<剧名>` 挪进 `D:\smb\动漫\<剧名>` 后，合集
  // `cover_path` 还指着旧位置的 poster.jpg。库页合集卡判了文件存在、会落到刮削
  // 封面；详情页只判非空，返回一张必坏的 FileImage，把刮削封面回退整个挡掉。
  testWidgets('合集封面路径悬空 → 详情页 hero 回落到刮削的规范封面', (WidgetTester tester) async {
    await db.updateMediaCollectionCoverPath(
      collectionId,
      '/moved-away/series/poster.jpg',
    );
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Moved series',
        updatedAt: 1,
      ),
    );
    await db.replaceVideoMetadataImages(
      workId: workId,
      images: <VideoMetadataImagesCompanion>[
        VideoMetadataImagesCompanion.insert(
          provider: 'tmdb',
          kind: 'cover',
          remoteUrl: 'https://image.example/moved-poster.jpg',
          localPath: const Value<String?>('/moved-away/cache/poster.jpg'),
          updatedAt: 1,
        ),
      ],
    );

    await pumpSingleColumn(tester);

    final PortraitCoverImage poster = tester.widget<PortraitCoverImage>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('collection-hero-poster')),
        matching: find.byType(PortraitCoverImage),
      ),
    );
    expect(poster.image, isA<ResizeImage>());
    final ImageProvider<Object> remote =
        (poster.image as ResizeImage).imageProvider;
    expect(
      remote,
      isA<CachedNetworkImageProvider>(),
      reason: '合集封面与刮削本地图都已不存在时，必须落到刮削的远程封面，而不是悬空的 FileImage',
    );
    expect(
      (remote as CachedNetworkImageProvider).url,
      'https://image.example/moved-poster.jpg',
    );
    await drainCoverTint(tester);
  });

  testWidgets('无横版 backdrop → 封面模糊垫底 + 封面卡清晰显示', (WidgetTester tester) async {
    await saveMeta();
    await pumpSingleColumn(tester);

    expect(
      find.byKey(const ValueKey<String>('collection-hero-cover')),
      findsOneWidget,
      reason: '历史资料没有横版图时拿本地封面模糊垫底',
    );
    expect(
      find.byKey(const ValueKey<String>('collection-hero-backdrop')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('collection-hero-poster')),
      findsOneWidget,
      reason: '封面恒在独立封面卡里清晰显示（背景只是模糊色彩）',
    );
    expect(
      find.byType(LandscapeCoverImage),
      findsNothing,
      reason: '不再把 2:3 海报铺进宽幅槽（BUG-1298）',
    );
  });

  testWidgets('BUG-3756：合集海报在网络盘上 → hero build 零同步文件调用', (
    WidgetTester tester,
  ) async {
    // 合集海报 / 刮削本地图落在「网络盘」（rclone / SMB 挂载）上：旧实现 hero getter
    // 逐级 existsSync，冷目录一次 stat 数秒，整页与同 isolate 的互联 host 一起冻结。
    // 网络盘上的同步文件 API 一律记账；两张图都已不在，探测落定后落到远程封面。
    final String netPoster = '${coverDir.path}/__fushi_net_mount__/poster.jpg';
    final String netCache = '${coverDir.path}/__fushi_net_mount__/cache.jpg';
    await db.updateMediaCollectionCoverPath(collectionId, netPoster);
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Net series',
        updatedAt: 1,
      ),
    );
    await db.replaceVideoMetadataImages(
      workId: workId,
      images: <VideoMetadataImagesCompanion>[
        VideoMetadataImagesCompanion.insert(
          provider: 'tmdb',
          kind: 'cover',
          remoteUrl: 'https://image.example/net-poster.jpg',
          localPath: Value<String?>(netCache),
          updatedAt: 1,
        ),
      ],
    );

    final List<String> syncCalls = <String>[];
    final List<String> asyncProbes = <String>[];
    final Zone outer = Zone.current;
    await IOOverrides.runZoned<Future<void>>(
      () async {
        await pumpSingleColumn(tester);
        await tester.pump(const Duration(milliseconds: 300));
      },
      createFile: (String path) => path.contains('__fushi_net_mount__')
          ? _NetMountFile(path, syncCalls, asyncProbes)
          : outer.run(() => File(path)),
    );

    expect(tester.takeException(), isNull);
    expect(syncCalls, isEmpty, reason: 'hero build 不得对网络盘封面做同步文件调用');
    expect(asyncProbes.toSet(), <String>{netPoster, netCache});
    expect(asyncProbes, hasLength(2), reason: '每张候选只 async 探一次，结果进缓存');
    final PortraitCoverImage poster = tester.widget<PortraitCoverImage>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('collection-hero-poster')),
        matching: find.byType(PortraitCoverImage),
      ),
    );
    final ImageProvider<Object> remote =
        (poster.image as ResizeImage).imageProvider;
    expect(remote, isA<CachedNetworkImageProvider>());
    expect(
      (remote as CachedNetworkImageProvider).url,
      'https://image.example/net-poster.jpg',
    );
    await drainCoverTint(tester);
  });
}

/// BUG-3756 用的「网络盘」假文件：同步 API 记账并抛错，`exists()` 记账后回 false。
class _NetMountFile implements File {
  _NetMountFile(this.path, this.syncCalls, this.asyncProbes);

  @override
  final String path;
  final List<String> syncCalls;
  final List<String> asyncProbes;

  @override
  Future<bool> exists() async {
    asyncProbes.add(path);
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    syncCalls.add('${invocation.memberName} $path');
    throw StateError('unexpected File.${invocation.memberName} on $path');
  }
}
