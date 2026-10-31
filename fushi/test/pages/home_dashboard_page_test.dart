import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/media_cover_source.dart'
    show mediaCoverFallbackIcon;
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/pages/implementations/home_floating_toolbar.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show CoverProgressStrip, ShelfCoverFrame, ShelfTitleOverflowTooltip;
import 'package:fushi/src/utils/components/shelf_cover_material.dart'
    show ShelfCardMeta, ShelfMaterialSurface;
import 'package:fushi/src/utils/components/cover_badge.dart' show CoverBadge;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogHeroIcon;
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiConnectedButtonGroup;
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatChars, formatStatTime;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';
import '../helpers/glass_unwrap.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 首页仪表盘布局回归：**宽屏（PC/横屏）曾因把 stretch/Expanded 的 Row 直接放进纵向
/// ListView（高度无界）而在 layout 阶段抛「BoxConstraints forces an infinite height」，
/// 导致整页空白**。本测试锁死宽/窄两分支渲染都不抛异常、各区块结构可见。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_dashboard_pp');
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
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  /// 提到外层：Bangumi 同步卡的状态全部来自偏好（令牌/账号名/上次同步），测试要能写。
  late PreferencesRepository prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_dashboard');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  /// **书侧 provider 的 drift `.watch()` 隔离清单——全文件只此一份。**
  ///
  /// `reader_fushi_source.dart` 里的 `_epubBookKeysProvider` 是个 drift `.watch()`
  /// StreamProvider；凡直接或间接 `ref.watch` 到它的 provider（`fushiBooksProvider` /
  /// `bookLastReadAtProvider` / `epubBookUidByKeyProvider`）都必须在这里被打桩。
  ///
  /// 不打桩就必红（BUG-1495 实测）：widget 测试结束时 flutter_test 用
  /// `runApp(Container())` 卸载整棵树 → `ProviderContainer.dispose` →
  /// `QueryStream._onCancelOrPause` → drift `StreamQueryStore.markAsClosed` 里的
  /// `Timer.run(...)` 排了个**零延时 timer**；而 `_verifyInvariants` 紧接着就检查
  /// `timersPending`，中间没有任何一帧能让它跑掉 ⇒「A Timer is still pending even
  /// after the widget tree was disposed」必现，随后整条用例挂到 10 分钟超时。
  /// 用例体里补 pump 没用——卸载发生在用例体**之后**。
  ///
  /// 为什么收成一个函数：以前三处 `ProviderScope` 各抄了一份两条的清单，于是 P3
  /// Stage 1b/2（7a3505ca7a / 2ceccf8bda）给首页新增 `epubBookUidByKeyProvider`
  /// 消费方时，三处得同时被想起来——一处都没被想起来，红就那样进了 develop。
  /// 清单只有一份，新增消费方就只有一个地方要改。
  List<Override> bookStreamOverrides({
    List<MediaItem> books = const <MediaItem>[],
    Map<String, int> lastReadAt = const <String, int>{},
  }) => <Override>[
    fushiBooksProvider.overrideWith((ref, language) async => books),
    bookLastReadAtProvider.overrideWith((ref) async => lastReadAt),
    // 空表 ⇒ `lastReadByKey[epubUidByKey[bookKey] ?? bookKey]` 走 bookKey 回退，
    // 与上面 lastReadAt 的键域（bookKey）一致。
    epubBookUidByKeyProvider.overrideWith((ref) async => <String, String>{}),
    // 左上角头像读排行榜服务；真 provider 会连带建 ProfileViewModel，它在空测试
    // 库上「应用默认 Profile」会把按 Profile 存的模块开关（游戏等）改写掉。
    // 首页测试只要一个没开账户的服务（不 load、不联网）。
    leaderboardServiceProvider.overrideWith(
      (Ref _) => LeaderboardService(
        database: () => db,
        supportRoot: () async => storeDir,
        profileId: () async => 1,
        httpClientFactory: () async =>
            throw StateError('no network in dashboard tests'),
      ),
    ),
  ];

  Widget buildApp({
    Future<void> Function(
      BuildContext context,
      VideoBookRepository repo,
      String bookUid,
      int? playlistCollectionId,
    )?
    openVideoOverride,
    Future<List<ServerContinueCandidate>> Function()? serverContinueLoader,
  }) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
      // 本测试聚焦布局不崩 + 视频继续/热力图/活动渲染，书侧数据用空值即可。
      ...bookStreamOverrides(),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeDashboardPage(
            videoRepo: VideoBookRepository(db),
            openVideoOverride: openVideoOverride,
            serverContinueLoader:
                serverContinueLoader ??
                () async => const <ServerContinueCandidate>[],
          ),
        ),
      ),
    ),
  );

  // 有界 pump：不用 pumpAndSettle（真实 DB isolate + FutureProvider 在 fakeAsync 下
  // 不会 settle，会挂起）。三帧足够跑完 build + initState 异步载入回填。
  Future<void> pumpDashboard(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// BUG-3756：「继续」视频卡的封面存在性是 async 文件探测（build 里不再同步 stat），
  /// 真实 IO 在 fakeAsync 下不会完成。回退链每探一个候选是一次真实 IO + 一次
  /// fakeAsync 续体（下一帧才跑），按候选个数各给一轮 runAsync + pump。
  Future<void> settleCoverProbes(WidgetTester tester, {int probes = 3}) async {
    for (int i = 0; i < probes; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    // 最后一帧起了真实的封面文件读取（FileImage）：让它在真实事件循环里读完、
    // 关掉文件句柄，否则 tearDown 删临时目录会撞「文件被占用」（Windows）。
    // 按条件等而不是固定睡一段：读文件的续体排在 fakeAsync 里，要 runAsync 让 IO
    // 回话、再 pump 跑续体；`readAsBytes` 先关文件再完成，缓存里没有在途图片时句柄
    // 必然已关。机器忙（CI 四路并发）时固定 200 ms 不够。只看指向真实文件的图：
    // 探测未决时的占位图（kPendingCoverImage）按设计永不完成，不能拿缓存总数判。
    final ImageCache cache = PaintingBinding.instance.imageCache;
    Future<bool> fileImagePending() async {
      for (final Image image in tester.widgetList<Image>(find.byType(Image))) {
        final ImageProvider<Object> provider = image.image;
        final ImageProvider<Object> inner = provider is ResizeImage
            ? provider.imageProvider
            : provider;
        if (inner is! FileImage) continue;
        final Object key = await provider.obtainKey(ImageConfiguration.empty);
        if (cache.statusForKey(key).pending) return true;
      }
      return false;
    }

    for (int i = 0; i < 200 && await fileImagePending(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(await fileImagePending(), isFalse, reason: '封面读取没有收尾');
  }

  /// v92 起阅读只写 `study_segments`，`reading_statistics` 冻结为 legacy 只读投影
  /// （历史数据仍要进首页热力图 / 今日目标）。这里按 legacy 形状直插（OVERWRITE 版
  /// `setReadingStatistic`），语义与旧 `addReadingStatistic` 累加版在空表上等价。
  Future<void> seedLegacyReading({
    required String title,
    required String dateKey,
    required int charsRead,
    required int timeMs,
  }) => db.setReadingStatistic(
    ReadingStatisticsCompanion.insert(
      title: title,
      dateKey: dateKey,
      charactersRead: charsRead,
      readingTimeMs: timeMs,
      lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  Future<void> seedSampleData() async {
    final DateTime now = DateTime.now();
    final String todayKey = FushiTimeFormat.dayKey(now);
    await seedLegacyReading(
      title: '吾輩は猫である',
      dateKey: todayKey,
      charsRead: 800,
      timeMs: 600000,
    );
    await db.addActivityEvent(
      eventType: kActivityRead,
      mediaType: kActivityMediaBook,
      title: '活动书名',
      dateKey: todayKey,
      timestampMs: now.millisecondsSinceEpoch,
      durationMs: 600000,
      charsDelta: 800,
    );
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('video/keep-watching'),
        title: Value('继续看的视频'),
        videoPath: Value('/abs/keep.mp4'),
        lastPositionMs: Value(754000),
      ),
    );
  }

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 书侧装配（「继续」区的书来自 provider，测试直接喂 MediaItem）。
  Widget buildAppWithBooks(
    List<MediaItem> books,
    Map<String, int> lastReadAt,
  ) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
      ...bookStreamOverrides(books: books, lastReadAt: lastReadAt),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeDashboardPage(videoRepo: VideoBookRepository(db)),
        ),
      ),
    ),
  );

  MediaItem readingBook(
    String key,
    String title, {
    required int position,
    String? imageUrl,
  }) => MediaItem(
    mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(key),
    title: title,
    mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
    mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
    imageUrl: imageUrl,
    position: position,
    duration: 100,
    canDelete: false,
    canEdit: true,
  );

  /// 合集 Next-Up 三态的公共装配：合集「进击的巨人」+ 两集独立行 E1/E2。
  Future<int> seedCollectionTwoEpisodes({
    required VideoBooksCompanion e1,
    required VideoBooksCompanion e2,
  }) async {
    await db.upsertVideoBook(e1);
    await db.upsertVideoBook(e2);
    final int cid = await db.createMediaCollection('进击的巨人');
    await db.addToCollection(cid, MediaKind.video, 'e1');
    await db.addToCollection(cid, MediaKind.video, 'e2');
    return cid;
  }

  // 2026-10-31：「继续」区是各库页共用的 FushiContinueSpotlight——第一条是主卡
  // （竖封面时皮是 FushiContinueHero），其余在 `home-continue-row` 封面行里
  // （FushiContinueSideTile，封面下挂库页同款文字块）。
  const ValueKey<String> studyCardKey = ValueKey<String>('home-study-card');
  const ValueKey<String> continueCardKey = ValueKey<String>(
    'home-continue-card',
  );
  const ValueKey<String> recentCardKey = ValueKey<String>('home-recent-card');
  Finder hero() => find.byType(FushiContinueHero);
  // 2026-10-28：主角卡不再有主按钮，整卡（FushiCard，key = home-continue-hero）
  // 点按 = 继续，也是唯一的焦点停靠点。
  Finder heroCard() => find.byKey(const ValueKey<String>('home-continue-hero'));
  FushiContinueSpotlight spotlight(WidgetTester tester) => tester
      .widget<FushiContinueSpotlight>(find.byType(FushiContinueSpotlight));

  /// 主卡的数据（标题 / 进度文案 / 眉标 / 封面高 / 元信息）。
  _HeroView heroView(WidgetTester tester) {
    final FushiContinueSpotlight s = spotlight(tester);
    final FushiContinueEntry m = s.main;
    return (
      title: m.title,
      progressLabel: m.progressLabel,
      progress: m.progress,
      eyebrow: m.eyebrow,
      coverHeight: s.soloCoverHeight,
      subtitle: m.metaLines.join(' · '),
    );
  }

  /// 主角卡信息列的标题（[ShelfTitleOverflowTooltip] 里的 Text；无图封面占位
  /// 也会画一份标题，不能只按文字找）。
  Finder heroTitle(String title) => find.descendant(
    of: find.descendant(
      of: hero(),
      matching: find.byType(ShelfTitleOverflowTooltip),
    ),
    matching: find.text(title),
  );

  /// 主角卡内渲染出的眉标文字（相对时间，没有时是动作词）。
  Finder heroEyebrow(WidgetTester tester) => find.descendant(
    of: hero(),
    matching: find.text(heroView(tester).eyebrow!),
  );

  Finder rowCards() => find.descendant(
    of: find.byKey(const ValueKey<String>('home-continue-row')),
    matching: find.byType(FushiContinueSideTile),
  );
  Finder recentTiles() => find.descendant(
    of: find.byKey(const ValueKey<String>('home-recent-list')),
    matching: find.byType(HomeRecentTile),
  );

  /// 分区标题：限定在该分区卡内找，免得和别处同字样的文字混淆。
  Finder sectionTitle(ValueKey<String> card, String title) =>
      find.descendant(of: find.byKey(card), matching: find.text(title));

  /// 「继续」条目按屏上顺序：主角卡在前（角标文案 = progressLabel），封面行
  /// 随后（副行文案 = subtitle）。
  List<_ContinueItem> continueItems(WidgetTester tester) => <_ContinueItem>[
    if (find.byType(FushiContinueSpotlight).evaluate().isNotEmpty)
      (
        title: heroView(tester).title,
        badgeLabel: heroView(tester).progressLabel,
        progress: heroView(tester).progress,
        badgeIcon: null,
      ),
    for (final FushiContinueSideTile c
        in tester.widgetList<FushiContinueSideTile>(rowCards()))
      (
        title: c.entry.title,
        badgeLabel: c.entry.subtitle,
        progress: c.entry.progress,
        badgeIcon: c.entry.subtitleIcon,
      ),
  ];
  _HeroView onlyHero(WidgetTester tester) {
    expect(rowCards(), findsNothing, reason: '只有一条时不该出横滑行');
    return heroView(tester);
  }

  // ── 2026-10 首页精简（用户反馈 PDF「1.首页」）→ 10-10 加回分区标题 ─────────────

  for (final Size size in const <Size>[Size(1280, 900), Size(420, 900)]) {
    testWidgets('分区标题 · ${size.width.toInt()} 宽：「今日」「继续」各成一张带标题的卡，'
        '「学习活动」标题、四类筛选、学习日历、活动仍然删除', (WidgetTester tester) async {
      useSize(tester, size);
      await seedSampleData();
      // 只导入、没看过：竖屏单栏不出「最近添加」，双栏版式在侧栏列出（见下方
      // 双栏专项测试）。
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value('recent-only'),
          title: const Value('刚导入的视频'),
          videoPath: const Value('/abs/recent-only.mp4'),
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
      );
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      final bool twoColumn = size.width >= 840;
      expect(tester.takeException(), isNull);
      expect(find.byType(HomeStudyHeader), findsOneWidget);
      expect(sectionTitle(studyCardKey, t.stat_today), findsOneWidget);
      expect(sectionTitle(continueCardKey, t.home_continue), findsOneWidget);
      // 只有一条可继续：主角卡，没有横滑行。
      expect(onlyHero(tester).title, '继续看的视频');
      // 被删掉的字样 / 控件（「阅读 / 观看 / 游戏」现在是主角卡副标题的类型
      // 标签，不再代表筛选，故只查「全部」）。
      for (final String gone in <String>[
        t.reading_activity,
        t.home_activity,
        t.home_filter_all,
        t.stat_goal_daily,
        if (!twoColumn) '刚导入的视频',
        if (!twoColumn) t.home_recently_added,
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.byType(StatContributionHeatmap), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('home-two-column')),
        twoColumn ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(recentCardKey),
        twoColumn ? findsOneWidget : findsNothing,
      );
      final Rect study = tester.getRect(find.byKey(studyCardKey));
      final Rect continueCard = tester.getRect(find.byKey(continueCardKey));
      if (twoColumn) {
        // 宽屏（2026-10-31 方案 A）：「继续」满宽在上；下面面板自适应分列——
        // 「今日」与「最近添加」两块并排各占一列，铺满整行。
        expect(
          sectionTitle(recentCardKey, t.home_recently_added),
          findsOneWidget,
        );
        expect(continueCard.bottom, lessThanOrEqualTo(study.top));
        final Rect recent = tester.getRect(find.byKey(recentCardKey));
        expect(recent.top, closeTo(study.top, 0.5));
        expect(recent.left, greaterThan(study.right));
        expect(study.width, closeTo(recent.width, 0.5));
      } else {
        // 单栏：「今日」在「继续」之上。
        expect(study.bottom, lessThanOrEqualTo(continueCard.top));
      }
    });
  }

  test('版式与封面尺寸纯函数：双栏判据 + 主角卡 / 横滑行封面高度随主列宽放大', () {
    // 竖屏手机 / 平板竖屏：单栏。
    expect(dashboardUsesTwoColumns(const Size(420, 900)), isFalse);
    expect(dashboardUsesTwoColumns(const Size(700, 1000)), isFalse);
    // 不到 600 宽的横屏也不分栏；正方形不算横屏。
    expect(dashboardUsesTwoColumns(const Size(599, 300)), isFalse);
    expect(dashboardUsesTwoColumns(const Size(600, 600)), isFalse);
    // 横屏手机 / 平板横屏：双栏。
    expect(dashboardUsesTwoColumns(const Size(600, 400)), isTrue);
    expect(dashboardUsesTwoColumns(const Size(844, 390)), isTrue);
    // ≥ 840 宽：无论横竖都双栏。
    expect(dashboardUsesTwoColumns(const Size(840, 1200)), isTrue);
    expect(dashboardUsesTwoColumns(const Size(1280, 900)), isTrue);

    expect(dashboardHeroCoverHeight(400), 150);
    expect(dashboardHeroCoverHeight(600), closeTo(180, 0.01));
    expect(dashboardHeroCoverHeight(800), 240);
    expect(dashboardHeroCoverHeight(1600), 240);

    expect(dashboardRowCoverHeight(500), 132);
    expect(dashboardRowCoverHeight(800), closeTo(160, 0.01));
    expect(dashboardRowCoverHeight(1000), 200);
    expect(dashboardRowCoverHeight(1600), 200);
  });

  for (final Size size in const <Size>[Size(420, 900), Size(844, 390)]) {
    testWidgets('版式 · ${size.width.toInt()}×${size.height.toInt()}：'
        '${size.width > size.height ? '横屏手机走双栏' : '竖屏手机走单栏'}', (
      WidgetTester tester,
    ) async {
      useSize(tester, size);
      await seedSampleData();
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      final bool twoColumn = size.width > size.height;
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('home-two-column')),
        twoColumn ? findsOneWidget : findsNothing,
      );
      final Rect study = tester.getRect(find.byKey(studyCardKey));
      final Rect continueCard = tester.getRect(find.byKey(continueCardKey));
      if (twoColumn) {
        // 横屏高度紧：主卡封面按视口高封顶，「今日」仍在首屏露头。
        expect(continueCard.bottom, lessThanOrEqualTo(study.top));
        expect(study.top, lessThan(size.height));
      } else {
        expect(study.bottom, lessThanOrEqualTo(continueCard.top));
        // 单栏主角卡封面高 150。
        expect(onlyHero(tester).coverHeight, 150);
      }
    });
  }

  testWidgets('宽屏「最近添加」：面板区带标题的紧凑列表（「类型 · 相对时间」副标题、'
      '按导入时间倒序、与「继续」去重）；主角卡封面按「继续」区宽放大', (WidgetTester tester) async {
    useSize(tester, const Size(1440, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final (String, int) b in <(String, int)>[
      ('新书A', 3000),
      ('在读书', 2000),
      ('新书B', 1000),
    ]) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: b.$1,
          title: b.$1,
          epubPath: '/abs/${b.$1}.epub',
          extractDir: '/abs/${b.$1}',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - b.$2,
          localAddedAt: Value<int?>(now - b.$2),
        ),
      );
    }
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('fresh-video'),
        title: const Value('刚导入的视频'),
        videoPath: const Value('/abs/fresh.mp4'),
        importedAt: Value(now - 1500),
        localAddedAt: Value<int?>(now - 1500),
      ),
    );
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[
          readingBook('新书A', '新书A', position: 0),
          readingBook('在读书', '在读书', position: 40),
          readingBook('新书B', '新书B', position: 0),
        ],
        const <String, int>{'在读书': 1},
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 「继续」只有在读的那本：主角卡，封面高度按「继续」区（满宽）放大。
    final _HeroView h = onlyHero(tester);
    expect(h.title, '在读书');
    final double mainWidth = tester.getSize(find.byKey(continueCardKey)).width;
    expect(h.coverHeight, dashboardHeroCoverHeight(mainWidth));
    expect(h.coverHeight, greaterThan(150));
    // 「最近添加」：导入时间倒序、在读书已在「继续」里不重复出现、副标题是
    // 「类型 · 相对时间」；有分区标题。
    expect(sectionTitle(recentCardKey, t.home_recently_added), findsOneWidget);
    final List<HomeRecentTile> recent = tester
        .widgetList<HomeRecentTile>(recentTiles())
        .toList();
    expect(recent.map((HomeRecentTile r) => r.title), <String>[
      '新书B',
      '刚导入的视频',
      '新书A',
    ]);
    expect(recent[0].subtitle, startsWith('${t.home_filter_read} · '));
    expect(recent[1].subtitle, startsWith('${t.home_filter_watch} · '));
    expect(recent[2].subtitle, startsWith('${t.home_filter_read} · '));
    for (final HomeRecentTile r in recent) {
      expect(
        find.descendant(of: recentTiles(), matching: find.text(r.title)),
        findsOneWidget,
        reason: '紧凑行把标题画在屏上：${r.title}',
      );
    }
    // 方案 A：「继续」满宽在上，「最近添加」进下方自适应面板区。
    expect(
      tester.getTopLeft(find.byKey(recentCardKey)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byKey(continueCardKey)).dy,
      ),
    );
  });

  testWidgets('双栏「最近添加」最多 4 条（取导入最新的）', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MediaItem> books = <MediaItem>[];
    for (int i = 1; i <= 6; i++) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: '新书$i',
          title: '新书$i',
          epubPath: '/abs/$i.epub',
          extractDir: '/abs/$i',
          chapterCount: 1,
          chaptersJson: '[]',
          // 新书6 最新。
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      books.add(readingBook('新书$i', '新书$i', position: 0));
    }
    await tester.pumpWidget(buildAppWithBooks(books, const <String, int>{}));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(
      tester
          .widgetList<HomeRecentTile>(recentTiles())
          .map((HomeRecentTile r) => r.title),
      <String>['新书6', '新书5', '新书4', '新书3'],
    );
  });

  testWidgets('双栏「最近添加」按本机拥有时刻排：刚从对端下载的旧书 / 旧视频排最前，'
      '不按它们在对端多年前的入库时刻沉底', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    const int yearsAgo = 1000;
    final List<MediaItem> books = <MediaItem>[];
    // 本机最近导入的四本（入库时刻 = 拥有时刻）。
    for (int i = 1; i <= 4; i++) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: '本地$i',
          title: '本地$i',
          epubPath: '/abs/local$i.epub',
          extractDir: '/abs/local$i',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      books.add(readingBook('本地$i', '本地$i', position: 0));
    }
    // 刚从互联对端下载：importedAt 沿用对端多年前的入库时刻（BUG-3452 /
    // BUG-2463），本机拥有时刻是刚才——与生产落地路径一样经写入单点补齐。
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: '对端旧书',
        title: '对端旧书',
        epubPath: '/abs/peer.epub',
        extractDir: '/abs/peer',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: yearsAgo,
      ),
    );
    books.add(readingBook('对端旧书', '对端旧书', position: 0));
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('peer-video'),
        title: Value('对端旧视频'),
        videoPath: Value('/abs/peer.mp4'),
        importedAt: Value(yearsAgo),
      ),
    );
    await tester.pumpWidget(buildAppWithBooks(books, const <String, int>{}));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final List<String> titles = tester
        .widgetList<HomeRecentTile>(recentTiles())
        .map((HomeRecentTile r) => r.title)
        .toList();
    expect(titles, hasLength(4));
    expect(titles.take(2).toSet(), <String>{
      '对端旧书',
      '对端旧视频',
    }, reason: '按 importedAt 排它们会沉到最后、被 4 条上限截掉');
    expect(titles.skip(2), <String>['本地4', '本地3']);
  });

  testWidgets('「最近添加」只在双栏：竖屏单栏不出；单栏主角卡封面 150、横滑行封面 132', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(412, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: '新书A',
        title: '新书A',
        epubPath: '/abs/a.epub',
        extractDir: '/abs/a',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: now,
      ),
    );
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[
          readingBook('新书A', '新书A', position: 0),
          readingBook('在读书', '在读书', position: 40),
          readingBook('在读书2', '在读书2', position: 20),
        ],
        const <String, int>{'在读书': 2, '在读书2': 1},
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('home-two-column')), findsNothing);
    expect(find.byKey(recentCardKey), findsNothing);
    expect(find.text('新书A'), findsNothing);
    expect(heroView(tester).coverHeight, 150);
    expect(spotlight(tester).narrowSideCoverHeight, 132);
    expect(
      tester
          .getSize(
            find.descendant(
              of: rowCards(),
              matching: find.byType(ShelfCoverFrame),
            ),
          )
          .height,
      closeTo(132, 0.5),
    );
  });

  testWidgets('精简 · 学习头部行：今日字数 + 同一行右侧今日时长（不挂小字标签）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    // 今天读 800 字 / 10 分钟（seedSampleData）。
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final String time = formatStatTime(600000);
    expect(find.text(time), findsOneWidget);
    expect(find.text(formatStatChars(800)), findsOneWidget);
    // 同一行：时长与字数垂直居中对齐、在右侧。
    final Rect value = tester.getRect(find.text(formatStatChars(800)));
    final Rect timeRect = tester.getRect(find.text(time));
    expect((value.center.dy - timeRect.center.dy).abs(), lessThan(8));
    expect(timeRect.left, greaterThan(value.right));
    // 读屏仍能听到这是「今日」时长（屏上只有图标 + 数字）。
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('${t.stat_today} · $time'), findsOneWidget);
    semantics.dispose();
  });

  for (final double width in <double>[320, 360, 420]) {
    testWidgets('精简 · $width 宽手机：学习统计完整显示，不省略号截断、不溢出', (
      WidgetTester tester,
    ) async {
      useSize(tester, Size(width, 800));
      await appModel.setReadingGoalDailyChars(30000);
      // 大数 + 长时长：最容易把一行挤爆的组合。
      final String todayKey = FushiTimeFormat.dayKey(DateTime.now());
      await seedLegacyReading(
        title: '长时间阅读',
        dateKey: todayKey,
        charsRead: 123456,
        timeMs: (12 * 60 + 34) * 60000,
      );
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      final String value = t.stat_goal_progress(read: 123456, goal: 30000);
      final String time = formatStatTime((12 * 60 + 34) * 60000);
      final Rect header = tester.getRect(find.byType(HomeStudyHeader));
      for (final String text in <String>[value, time]) {
        final Finder f = find.text(text);
        expect(f, findsOneWidget, reason: text);
        final RenderParagraph p = tester.renderObject<RenderParagraph>(f);
        expect(p.didExceedMaxLines, isFalse, reason: text);
        // 段落按自然宽度排版（没被压窄、没被裁掉一截）。
        expect(
          p.size.width,
          greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5),
          reason: '$text 被截断',
        );
        final Rect r = tester.getRect(f);
        expect(r.left, greaterThanOrEqualTo(header.left - 0.5), reason: text);
        expect(r.right, lessThanOrEqualTo(header.right + 0.5), reason: text);
      }
    });
  }

  for (final double width in <double>[320, 360, 420]) {
    testWidgets('$width 宽手机：主角卡（长标题 + 进度行）与带标题的横滑行不溢出', (
      WidgetTester tester,
    ) async {
      useSize(tester, Size(width, 800));
      await tester.pumpWidget(
        buildAppWithBooks(
          <MediaItem>[
            readingBook('长', '很长很长很长很长很长很长很长很长很长很长的书名第一卷', position: 30),
            readingBook('长2', '另一本同样很长很长很长很长很长很长的书名', position: 60),
            readingBook('短', '短', position: 10),
          ],
          const <String, int>{'长': 3, '长2': 2, '短': 1},
        ),
      );
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      expect(heroCard(), findsOneWidget);
      final Finder progress = find.byKey(
        const ValueKey<String>('home-continue-hero-progress'),
      );
      expect(progress, findsOneWidget);
      expect(rowCards(), findsNWidgets(2));
      final Rect heroRect = tester.getRect(heroCard());
      expect(heroRect.right, lessThanOrEqualTo(width + 0.5));
      // 卡内文字与进度行都收在卡内（长标题不把信息列挤出卡外）。
      expect(
        tester.getRect(progress).right,
        lessThanOrEqualTo(heroRect.right + 0.5),
      );
      final Finder progressLabel = find.descendant(
        of: hero(),
        matching: find.text('30%'),
      );
      expect(progressLabel, findsOneWidget);
      expect(
        tester.getRect(progressLabel).right,
        lessThanOrEqualTo(heroRect.right + 0.5),
      );
      final Finder title = heroTitle('很长很长很长很长很长很长很长很长很长很长的书名第一卷');
      expect(title, findsOneWidget);
      expect(
        tester.getRect(title).right,
        lessThanOrEqualTo(heroRect.right + 0.5),
      );
      expect(
        tester.getRect(heroEyebrow(tester)).right,
        lessThanOrEqualTo(heroRect.right + 0.5),
      );
    });
  }

  testWidgets('「继续」主角卡 + 带标题的横滑行：最近读的放大成主角卡（波浪进度 + '
      '「继续阅读」），其余卡封面下挂标题，副行 = 阅读进度（封面不压角标）', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final File cover = File('${storeDir.path}/book_cover.png')
      ..writeAsBytesSync(_kOnePixelPng);
    final MediaItem a = readingBook(
      '书A',
      '有封面的书',
      position: 30,
      imageUrl: Uri.file(cover.path).toString(),
    );
    final MediaItem b = readingBook(
      '书B',
      '另一本书',
      position: 50,
      imageUrl: Uri.file(cover.path).toString(),
    );
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[a, b],
        const <String, int>{'书A': 2, '书B': 1},
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final List<_ContinueItem> items = continueItems(tester);
    // 最近读的是主角卡，其余进横滑行。
    expect(items.map((_ContinueItem c) => c.title), <String>['有封面的书', '另一本书']);
    expect(items.map((_ContinueItem c) => c.badgeLabel), <String?>[
      '30%',
      '50%',
    ]);
    expect(items.first.progress, 0.3);
    // 主角卡：眉标、标题、M3E 波浪进度条 + 进度文案；卡上不放按钮，整卡点按 =
    // 继续阅读。
    expect(heroTitle('有封面的书'), findsOneWidget);
    expect(heroCard(), findsOneWidget);
    expect(
      find.descendant(
        of: hero(),
        matching: find.byWidgetPredicate(
          (Widget w) => w is ButtonStyleButton || w is IconButton,
        ),
      ),
      findsNothing,
      reason: '主角卡上不放任何按钮（2026-10-28）',
    );
    expect(
      find.byKey(const ValueKey<String>('home-continue-hero-progress')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: hero(), matching: find.text('30%')),
      findsOneWidget,
    );
    expect(heroEyebrow(tester), findsOneWidget);
    // 横滑卡：封面下方是库页同款文字块（标题 + 副行进度文案 + 进度条），
    // 封面上不压任何角标、不贴进度条。
    final Finder rowMeta = find.descendant(
      of: find.descendant(
        of: rowCards(),
        matching: find.byKey(
          const ValueKey<String>('fushi-continue-tile-meta'),
        ),
      ),
      matching: find.byType(ShelfCardMeta),
    );
    expect(rowMeta, findsOneWidget);
    expect(
      find.descendant(of: rowMeta, matching: find.text('另一本书')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rowMeta, matching: find.text('50%')),
      findsOneWidget,
      reason: '阅读进度文案进副行',
    );
    expect(
      tester.widget<ShelfCardMeta>(rowMeta).progress,
      0.5,
      reason: '进度条进文字块',
    );
    final Finder rowCover = find.descendant(
      of: rowCards(),
      matching: find.byType(ShelfCoverFrame),
    );
    expect(rowCover, findsOneWidget);
    expect(
      find.descendant(of: rowCover, matching: find.text('50%')),
      findsNothing,
      reason: '封面上不压进度角标',
    );
    expect(find.byType(CoverBadge), findsNothing);
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('另一本书 · 50%'), findsOneWidget);
    semantics.dispose();
    // 带标题时进度条在副行下面：封面底边不再贴 CoverProgressStrip（主角卡用
    // 波浪进度条）。
    expect(find.byType(CoverProgressStrip), findsNothing);
  });

  testWidgets('精简 · 没有封面的条目兜底显示标题（BUG-1018：用 override 书名）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    final MediaItem book = readingBook('测试书key', '原书名', position: 50);
    await ReaderFushiSource.instance.setOverrideTitleFromMediaItem(
      item: book,
      title: '改后的书名',
    );
    addTearDown(
      () => ReaderFushiSource.instance.setOverrideTitleFromMediaItem(
        item: book,
        title: null,
      ),
    );
    await tester.pumpWidget(
      buildAppWithBooks(<MediaItem>[book], const <String, int>{'测试书key': 1}),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-continue-cover-fallback')),
        matching: find.text('改后的书名'),
      ),
      findsOneWidget,
    );
    // 主角卡标题同样走 override 书名（与封面兜底同名，屏上出现两次是预期）。
    expect(onlyHero(tester).title, '改后的书名');
    expect(find.text('改后的书名'), findsNWidgets(2));
    expect(find.text('原书名'), findsNothing);
  });

  testWidgets('精简 · 无封面的视频：封面槽是类型图标 + 标题，不是空黑块', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData(); // 「继续看的视频」无 coverPath
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final Finder fallback = find.byKey(
      const ValueKey<String>('home-continue-cover-fallback'),
    );
    expect(
      find.descendant(
        of: fallback,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is FushiIcon &&
              w.icon == mediaCoverFallbackIcon(MediaKind.video),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: fallback, matching: find.text('继续看的视频')),
      findsOneWidget,
    );
  });

  testWidgets('精简 · 视频也显示进度：知道总时长 → 进度条 + 百分比；不知道 → 看到的时间点', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('v-known'),
        title: Value('知道时长的视频'),
        videoPath: Value('/abs/known.mp4'),
        lastPositionMs: Value(600000),
        lastPlayedAt: Value(2),
      ),
    );
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('v-unknown'),
        title: Value('不知道时长的视频'),
        videoPath: Value('/abs/unknown.mp4'),
        lastPositionMs: Value(754000),
        lastPlayedAt: Value(1),
      ),
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoFileSpec(
      VideoFileSpecsCompanion.insert(
        filePath: '/abs/known.mp4',
        fileSizeBytes: 1,
        fileModifiedAt: now,
        probedAt: now,
        probeVersion: 1,
        durationMs: const Value(2400000),
      ),
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 「知道时长的视频」最近看 → 主角卡；另一条在横滑行（带播放图标角标）。
    final Map<String, _ContinueItem> byTitle = <String, _ContinueItem>{
      for (final _ContinueItem c in continueItems(tester)) c.title: c,
    };
    expect(heroView(tester).title, '知道时长的视频');
    expect(byTitle['知道时长的视频']!.progress, 0.25);
    expect(byTitle['知道时长的视频']!.badgeLabel, '25%');
    expect(byTitle['不知道时长的视频']!.progress, isNull);
    expect(byTitle['不知道时长的视频']!.badgeLabel, '12:34');
    expect(byTitle['不知道时长的视频']!.badgeIcon, FushiIcons.play);
  });

  group('dashboardVideoContinueProgress', () {
    test('单行多集播放列表：集数角标 + 集粒度进度', () {
      final DashboardVideoProgress p = dashboardVideoContinueProgress(
        completed: false,
        positionMs: 1000,
        durationMs: null,
        currentEpisode: 2,
        playlistEpisodeCount: 12,
      );
      expect(p.episode, 3);
      expect(p.fraction, 2 / 12);
      expect(p.percent, isNull);
    });

    test('合集里的一集：集数角标 + 本集看到哪（知道时长时）', () {
      final DashboardVideoProgress p = dashboardVideoContinueProgress(
        completed: false,
        positionMs: 300000,
        durationMs: 1200000,
        currentEpisode: 0,
        playlistEpisodeCount: 0,
        collectionEpisode: 5,
        collectionEpisodeCount: 12,
      );
      expect(p.episode, 5);
      expect(p.fraction, 0.25);
    });

    test('只有一集的合集按单视频处理（不标「第 1 集」）', () {
      final DashboardVideoProgress p = dashboardVideoContinueProgress(
        completed: false,
        positionMs: 300000,
        durationMs: 1200000,
        currentEpisode: 0,
        playlistEpisodeCount: 0,
        collectionEpisode: 1,
        collectionEpisodeCount: 1,
      );
      expect(p.episode, isNull);
      expect(p.percent, 25);
    });

    test('单视频不知道时长：退回看到的时间点', () {
      final DashboardVideoProgress p = dashboardVideoContinueProgress(
        completed: false,
        positionMs: 754000,
        durationMs: null,
        currentEpisode: 0,
        playlistEpisodeCount: 0,
      );
      expect(p.fraction, isNull);
      expect(p.percent, isNull);
      expect(p.positionMs, 754000);
    });
  });

  testWidgets('精简 · 封面卡悬停抬升：绘制超出卡片原始边界但不被横滚行视口截平', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    // 第一本是主角卡，书B / 书C 进横滑行。
    final MediaItem a = readingBook('书A', '书A', position: 30);
    final MediaItem b = readingBook('书B', '书B', position: 50);
    final MediaItem c = readingBook('书C', '书C', position: 70);
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[a, b, c],
        const <String, int>{'书A': 3, '书B': 2, '书C': 1},
      ),
    );
    await pumpDashboard(tester);

    // 悬停放大是 FushiHoverLift 内层的绘制变换，材质封面悬停时还会再整体上抬
    //（书皮 / 卡盒）：量真正画出来的封面面（单本 = 唯一一块
    // ShelfMaterialSurface，含两层位移），不量外壳；卡体下方还挂着标题块，放大后
    // 同样不能被行视口截掉。
    final Finder card = find.descendant(
      of: rowCards().last,
      matching: find.byType(ShelfMaterialSurface),
    );
    expect(card, findsOneWidget);
    final Finder title = find.descendant(
      of: rowCards().last,
      matching: find.byKey(const ValueKey<String>('fushi-continue-tile-meta')),
    );
    final Rect viewport = tester.getRect(
      find.byKey(const ValueKey<String>('home-continue-row')),
    );
    final Rect originalRect = tester.getRect(card);
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(card));
    await pumpDashboard(tester);
    final Rect liftedRect = tester.getRect(card);
    expect(liftedRect.top, lessThan(originalRect.top));
    expect(liftedRect.top, greaterThanOrEqualTo(viewport.top - 0.01));
    expect(liftedRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.01));
    expect(
      tester.getRect(title).bottom,
      lessThanOrEqualTo(viewport.bottom + 0.01),
    );
    await mouse.removePointer();
    await pumpDashboard(tester);
    // 材质面的上抬走 FushiMotion.long（450 ms），比 pumpDashboard 推进的 400 ms
    // 长：再推满一段，等它落回原位再比。
    await tester.pump(FushiMotion.long);
    expect(tester.getRect(card), originalRect);
  });

  testWidgets('宽屏方案 A：其余条目的封面行排在主卡旁边、与主卡等高；窄屏仍排在主卡下面', (
    WidgetTester tester,
  ) async {
    final MediaItem a = readingBook('书A', '书A', position: 30);
    final MediaItem b = readingBook('书B', '书B', position: 50);
    final MediaItem c = readingBook('书C', '书C', position: 70);
    Future<void> pumpAt(Size size) async {
      useSize(tester, size);
      await tester.pumpWidget(
        buildAppWithBooks(
          <MediaItem>[a, b, c],
          const <String, int>{'书A': 3, '书B': 2, '书C': 1},
        ),
      );
      await pumpDashboard(tester);
      expect(tester.takeException(), isNull);
    }

    await pumpAt(const Size(1280, 900));
    Rect heroRect = tester.getRect(heroCard());
    Rect rowRect = tester.getRect(
      find.byKey(const ValueKey<String>('home-continue-row')),
    );
    expect(rowRect.left, greaterThan(heroRect.right));
    // 行高含悬停放大余量，按主卡高反推封面高：两者等高（允许 1px 取整）。
    expect(rowRect.height, closeTo(heroRect.height, 1));
    expect(rowRect.top, closeTo(heroRect.top, 1));

    await pumpAt(const Size(420, 900));
    heroRect = tester.getRect(heroCard());
    rowRect = tester.getRect(
      find.byKey(const ValueKey<String>('home-continue-row')),
    );
    expect(rowRect.top, greaterThanOrEqualTo(heroRect.bottom));
  });

  test('面板自适应分列：按最小列宽放得下几列，且不超过面板数与 3 列', () {
    int cols(double width, int count) =>
        HomePanelFlow.columnsFor(width: width, count: count, gap: 16);
    expect(cols(1300, 1), 1);
    // 面板少：列数 = 面板数，每列更宽、铺满整行。
    expect(cols(1300, 2), 2);
    expect(cols(1300, 5), 3);
    expect(cols(660, 5), 2);
    expect(cols(500, 5), 1);
  });

  testWidgets('卡片比例跟着实际用到的图走：只有横版截帧的视频在横滑行是 16:9 横卡（反馈 5CTpiVJ7-v）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    final File cover = File('${storeDir.path}/landscape_cover.png')
      ..writeAsBytesSync(_kLandscapePng);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('continue-landscape'),
        title: const Value('在看的横版视频'),
        videoPath: const Value('/abs/continue-landscape.mp4'),
        coverPath: Value(cover.path),
        lastPositionMs: const Value(60000),
      ),
    );
    // 书A 最近读 → 主角卡；横版视频与书B 进横滑行。
    final MediaItem book = readingBook('书A', '书A', position: 30);
    final MediaItem other = readingBook('书B', '书B', position: 60);
    // 卡片是数据回填后才建的、解码是真异步 I/O：两段都必须在同一个 runAsync 里。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        buildAppWithBooks(
          <MediaItem>[book, other],
          const <String, int>{'书A': 2},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      // BUG-3756：封面存在性改为 async 探测（不在 build 里同步 stat），解码前多一跳。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    final List<FushiContinueSideTile> cards = tester
        .widgetList<FushiContinueSideTile>(rowCards())
        .toList();
    expect(
      cards.map((FushiContinueSideTile c) => c.entry.title),
      unorderedEquals(<String>['在看的横版视频', '书B']),
    );
    Finder tileOf(String title) => find.byWidgetPredicate(
      (Widget w) => w is FushiContinueSideTile && w.entry.title == title,
    );
    // 封面面 = 条目卡键那张卡（剧照 / 竖封面都是）。
    Rect coverOf(String title) => tester.getRect(
      find.byKey(tester.widget<FushiContinueSideTile>(tileOf(title)).entry.key),
    );
    final Rect video = coverOf('在看的横版视频');
    final Rect bookB = coverOf('书B');
    // 书照旧 2:3 竖卡；横版截帧的视频是与竖卡同高的 16:9 剧照。
    expect(bookB.width, closeTo(bookB.height * 2 / 3, 0.5));
    expect(video.width, closeTo(video.height * 16 / 9, 0.5));
    expect(video.height, closeTo(bookB.height, 0.5));
    // 横竖卡同高：两张卡的顶边与底边（标题块底）都对齐。
    expect(video.top, closeTo(bookB.top, 0.5));
    expect(
      tester.getRect(tileOf('在看的横版视频')).bottom,
      closeTo(tester.getRect(tileOf('书B')).bottom, 0.5),
    );
    // 视频卡画的是截图本身，不是占位（书没有封面才画占位，不在此列）。
    expect(
      find.descendant(
        of: tileOf('在看的横版视频'),
        matching: find.byKey(
          const ValueKey<String>('home-continue-cover-fallback'),
        ),
      ),
      findsNothing,
    );
    // 横槽里的 16:9 截图直接 cover 铺满 = 完整显示，不再裁进竖卡。
    final Image frame = tester.widget<Image>(
      find
          .descendant(of: tileOf('在看的横版视频'), matching: find.byType(Image))
          .first,
    );
    expect(frame.fit, BoxFit.cover);
  });

  testWidgets('精简 · 视频竖卡优先用作品海报（合集主封面），不用集的横版截帧', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final File poster = File('${storeDir.path}/poster.png')
      ..writeAsBytesSync(_kOnePixelPng);
    final File frame = File('${storeDir.path}/frame.png')
      ..writeAsBytesSync(_kLandscapePng);
    final int cid = await seedCollectionTwoEpisodes(
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        coverPath: Value(frame.path),
        lastPositionMs: const Value(60000),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );
    await db.updateMediaCollectionCoverPath(cid, poster.path);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    await settleCoverProbes(tester);

    expect(tester.takeException(), isNull);
    final Iterable<Image> images = tester.widgetList<Image>(
      find.descendant(
        of: find.byKey(continueCardKey),
        matching: find.byType(Image),
      ),
    );
    expect(images, isNotEmpty);
    String pathOf(Image i) {
      ImageProvider p = i.image;
      if (p is ResizeImage) p = p.imageProvider;
      return (p as FileImage).file.path;
    }

    expect(images.map(pathOf), everyElement(poster.path));
  });

  // 反馈 5CTpiVJ7-v：合集主封面指向的文件不在时，主角卡掉成「图标 + 名字」占位，
  // 而视频页同一部作品照样有封面——要回落到这一集 / 同合集其它集的封面。
  testWidgets('精简 · 作品海报文件不在时回落到集封面，不画占位', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final File frame = File('${storeDir.path}/frame.png')
      ..writeAsBytesSync(_kLandscapePng);
    final int cid = await seedCollectionTwoEpisodes(
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        coverPath: Value(frame.path),
        lastPositionMs: const Value(60000),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );
    await db.updateMediaCollectionCoverPath(
      cid,
      '${storeDir.path}/gone/poster.png',
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    await settleCoverProbes(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(continueCardKey),
        matching: find.byKey(
          const ValueKey<String>('home-continue-cover-fallback'),
        ),
      ),
      findsNothing,
    );
    final Iterable<Image> images = tester.widgetList<Image>(
      find.descendant(
        of: find.byKey(continueCardKey),
        matching: find.byType(Image),
      ),
    );
    expect(images, isNotEmpty);
    String pathOf(Image i) {
      ImageProvider p = i.image;
      if (p is ResizeImage) p = p.imageProvider;
      return (p as FileImage).file.path;
    }

    expect(images.map(pathOf), everyElement(frame.path));
  });

  Future<void> pumpDecoded(WidgetTester tester, Widget app) async {
    // 卡片是数据回填后才建的、解码是真异步 I/O：两段都必须在同一个 runAsync 里。
    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      // BUG-3756：封面存在性改为 async 探测（不在 build 里同步 stat），解码前多一跳。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });
    await tester.pump(const Duration(seconds: 1));
  }

  /// 主角卡的封面槽：FushiContinueHero 把封面按槽比例装进 SizedBox 再套
  /// [ShelfCoverFrame]（紧约束，框尺寸 = 槽尺寸）；取卡内第一个（最外层）框。
  Size heroCoverSize(WidgetTester tester) => tester.getSize(
    find.descendant(of: hero(), matching: find.byType(ShelfCoverFrame)).first,
  );

  testWidgets('主角卡：只有横版截帧 → 16:9 剧照主卡（反馈 5CTpiVJ7-v）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    final File frame = File('${storeDir.path}/hero_frame.png')
      ..writeAsBytesSync(_kLandscapePng);
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('hero-landscape'),
        title: const Value('横版主角'),
        videoPath: const Value('/abs/hero-landscape.mp4'),
        coverPath: Value(frame.path),
        lastPositionMs: const Value(60000),
      ),
    );
    await pumpDecoded(tester, buildApp());

    expect(tester.takeException(), isNull);
    // 2026-10-31 合一：横图主卡走共享组件的剧照叠层皮——整卡就是 16:9 截图，
    // 不再是「封面 + 信息列」卡里塞一个横槽。
    expect(hero(), findsNothing);
    final Size card = tester.getSize(heroCard());
    expect(card.width / card.height, closeTo(16 / 9, 0.01));
    expect(
      find.byKey(const ValueKey<String>('home-continue-cover-fallback')),
      findsNothing,
    );
  });

  testWidgets('主角卡：作品竖版海报 → 2:3 竖封面槽，横卡不出现', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final File poster = File('${storeDir.path}/hero_poster.png')
      ..writeAsBytesSync(_kOnePixelPng);
    final File frame = File('${storeDir.path}/hero_frame2.png')
      ..writeAsBytesSync(_kLandscapePng);
    final int cid = await seedCollectionTwoEpisodes(
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        coverPath: Value(frame.path),
        lastPositionMs: const Value(60000),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );
    await db.updateMediaCollectionCoverPath(cid, poster.path);
    await pumpDecoded(tester, buildApp());

    expect(tester.takeException(), isNull);
    final Size cover = heroCoverSize(tester);
    expect(cover.width / cover.height, closeTo(2 / 3, 0.01));
  });

  testWidgets('BUG-3756：网络盘上的作品海报不在 build 里同步 stat（读有声书时首页每几秒重建）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    // 作品海报落在「网络盘」：rclone / SMB 挂载目录缓存过期时一次同步 stat 要数秒，
    // 旧实现在 build 里 existsSync，统计表每写一次首页就重建一次 → 主 isolate
    // （含同 isolate 的互联 host 端点）一起冻结。这里任何同步文件 API 都记账。
    final String netPoster = '${storeDir.path}/__fushi_net_mount__/poster.jpg';
    final List<String> syncCalls = <String>[];
    final List<String> asyncProbes = <String>[];
    final int cid = await seedCollectionTwoEpisodes(
      e1: const VideoBooksCompanion(
        bookUid: Value('e1'),
        title: Value('S01E01'),
        videoPath: Value('/abs/e1.mp4'),
        lastPositionMs: Value(60000),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );
    await db.updateMediaCollectionCoverPath(cid, netPoster);

    final Zone outer = Zone.current;
    await IOOverrides.runZoned<Future<void>>(
      () async {
        await pumpDecoded(tester, buildApp());
        // 再触发几次重建（模拟统计表高频写入后的首页重绘）。
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
      },
      createFile: (String path) => path.contains('__fushi_net_mount__')
          ? _NetMountFile(path, syncCalls, asyncProbes)
          : outer.run(() => File(path)),
    );

    expect(tester.takeException(), isNull);
    expect(syncCalls, isEmpty, reason: 'build 路径不得对封面做同步文件调用');
    // 海报确实经 async 探测过（不在 → 退回占位），而且候选不变时只探一次。
    expect(asyncProbes, <String>[netPoster]);
    expect(
      find.byKey(const ValueKey<String>('home-continue-cover-fallback')),
      findsWidgets,
    );
  });

  group('dashboardVideoCoverPath', () {
    Future<bool> existsIn(Set<String> files, String path) async =>
        files.contains(path);

    test('海报存在优先用海报', () async {
      expect(
        await dashboardVideoCoverPath(
          collectionCovers: <String>['poster'],
          ownCover: 'frame',
          exists: (String p) => existsIn(<String>{'poster', 'frame'}, p),
        ),
        'poster',
      );
    });

    test('自有封面文件不在 → 原盘竖版盘面图（自有层第二候选）', () async {
      expect(
        await dashboardVideoCoverPath(
          collectionCovers: <String>['own', 'disc'],
          ownCover: 'frame',
          exists: (String p) => existsIn(<String>{'disc', 'frame'}, p),
        ),
        'disc',
      );
    });

    test('海报文件不在 → 这一集封面', () async {
      expect(
        await dashboardVideoCoverPath(
          collectionCovers: <String>['poster'],
          ownCover: 'frame',
          exists: (String p) => existsIn(<String>{'frame'}, p),
        ),
        'frame',
      );
    });

    test('这一集也没封面 → 借同合集其它集的第一张存在的封面，找到就停', () async {
      final List<String> probed = <String>[];
      expect(
        await dashboardVideoCoverPath(
          collectionCovers: const <String>[],
          ownCover: '',
          memberCovers: <String?>[null, 'm1', 'm2', 'm3'],
          exists: (String p) async {
            probed.add(p);
            return p == 'm2' || p == 'm3';
          },
        ),
        'm2',
      );
      expect(probed, <String>['m1', 'm2']);
    });

    test('全不存在 → null', () async {
      expect(
        await dashboardVideoCoverPath(
          collectionCovers: <String>['a'],
          ownCover: 'b',
          memberCovers: <String?>['c'],
          exists: (String _) async => false,
        ),
        isNull,
      );
    });
  });

  testWidgets('精简 · 窄屏横滑卡副行的集数完整显示，不被卡边裁掉或省略号截断；主角卡进度文案同样完整', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(320, 700));
    final int cid = await db.createMediaCollection('很长的作品名');
    for (int i = 1; i <= 12; i++) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value('ep$i'),
          title: Value('E$i'),
          videoPath: Value('/abs/ep$i.mp4'),
          lastPositionMs: Value(i == 12 ? 60000 : 1400000),
          completedAt: i < 12 ? Value(DateTime.now()) : const Value(null),
        ),
      );
      await db.addToCollection(cid, MediaKind.video, 'ep$i');
    }
    // 一本刚读过的书占主角卡，把合集挤进横滑行（窄卡角标是本用例的对象）。
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[readingBook('书A', '书A', position: 30)],
        <String, int>{'书A': DateTime.now().millisecondsSinceEpoch},
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(
      continueItems(tester).map((_ContinueItem c) => c.badgeLabel),
      <String?>['30%', t.home_continue_episode(n: 12)],
    );
    // 集数不再压在封面上，进封面下的副行：副行在卡宽内、单行不被省略号截断。
    expect(
      find.descendant(of: rowCards(), matching: find.byType(CoverBadge)),
      findsNothing,
    );
    final Rect card = tester.getRect(rowCards());
    final Finder episode = find.descendant(
      of: find.descendant(of: rowCards(), matching: find.byType(ShelfCardMeta)),
      matching: find.text(t.home_continue_episode(n: 12)),
    );
    expect(episode, findsOneWidget);
    expect(find.text(t.home_continue_episode(n: 12)), findsOneWidget);
    final Rect episodeRect = tester.getRect(episode);
    expect(episodeRect.left, greaterThanOrEqualTo(card.left));
    expect(episodeRect.right, lessThanOrEqualTo(card.right));
    final RenderParagraph episodeText = tester.renderObject<RenderParagraph>(
      episode,
    );
    expect(episodeText.didExceedMaxLines, isFalse, reason: '集数文案完整显示，不被省略号截断');
    // 主角卡进度文案在卡内完整显示。
    final Rect heroRect = tester.getRect(hero());
    final Rect label = tester.getRect(
      find.descendant(of: hero(), matching: find.text('30%')),
    );
    expect(label.right, lessThanOrEqualTo(heroRect.right));
  });

  testWidgets('点继续区视频卡直接续播（带主合集 id），不再只是切视频 tab；合集卡角标 = 集数', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    final int cid = await seedCollectionTwoEpisodes(
      e1: const VideoBooksCompanion(
        bookUid: Value('e1'),
        title: Value('S01E01'),
        videoPath: Value('/abs/e1.mp4'),
        lastPositionMs: Value(60000),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );
    final List<(String, int?)> opened = <(String, int?)>[];
    await tester.pumpWidget(
      buildApp(
        openVideoOverride:
            (
              BuildContext _,
              VideoBookRepository __,
              String bookUid,
              int? playlistCollectionId,
            ) async {
              opened.add((bookUid, playlistCollectionId));
            },
      ),
    );
    await pumpDashboard(tester);

    final HomeTab tabBefore = homeShellTabNotifier.value;
    // 合集成员：显示名 = 合集名，进度文案 = 在看中的 E1 是第 1 集；副标题带出
    // 这一集的标题。
    final _HeroView c = onlyHero(tester);
    expect(c.title, '进击的巨人');
    expect(c.progressLabel, t.home_continue_episode(n: 1));
    expect(c.subtitle, '${t.home_filter_watch} · S01E01');
    // 卡上不放按钮：「继续观看」是动作语义（眉标兜底文案），整卡点按 = 续播。
    expect(heroEyebrow(tester), findsOneWidget);
    await tester.tap(heroCard());
    await tester.pump();
    expect(opened, <(String, int?)>[('e1', cid)]);
    expect(homeShellTabNotifier.value, tabBefore);
    expect(tester.takeException(), isNull);
  });

  group('服务器「继续」（Jellyfin / Emby / Plex、Audiobookshelf）', () {
    final int now = DateTime.now().millisecondsSinceEpoch;
    // 混排是显式 opt-in（默认关）：本组除门控用例外都按用户已打开两个开关来测。
    setUp(() async {
      await prefs.setJellyfinShowInLibrary(true);
      await prefs.setAudiobookshelfShowInHome(true);
    });
    ServerContinueCandidate candidate(
      ServerContinueSource source,
      String id,
      String title,
      int recentMs,
      List<String> opened,
    ) => ServerContinueCandidate(
      source: source,
      serverId: 'srv',
      serverName: 'MyServer',
      itemId: id,
      title: title,
      recentMs: recentMs,
      progress: 0.4,
      badgeLabel: '40%',
      open: (BuildContext _) async {
        opened.add(id);
      },
    );

    testWidgets('与本地条目同一行按最近播放时刻混排；点卡走各自的打开出口', (WidgetTester tester) async {
      useSize(tester, const Size(1280, 900));
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: const Value('local'),
          title: const Value('本地视频'),
          videoPath: const Value('/abs/local.mp4'),
          lastPositionMs: const Value(1000),
          importedAt: Value(now - 100000),
        ),
      );
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        buildApp(
          serverContinueLoader: () async => <ServerContinueCandidate>[
            candidate(
              ServerContinueSource.audiobookshelf,
              'abs-book',
              '有声书',
              now - 1000,
              opened,
            ),
            candidate(
              ServerContinueSource.mediaServer,
              'jf-movie',
              '服务器电影',
              now - 5000,
              opened,
            ),
          ],
        ),
      );
      await pumpDashboard(tester);

      expect(
        continueItems(tester).map((_ContinueItem i) => i.title).toList(),
        <String>['有声书', '服务器电影 · MyServer', '本地视频'],
      );
      final _HeroView h = heroView(tester);
      expect(h.subtitle, contains('MyServer'));
      expect(h.progressLabel, '40%');

      await tester.tap(heroCard());
      await tester.pump();
      expect(opened, <String>['abs-book']);

      // 横滑行：第二张是服务器电影，点开走媒体服务器出口。
      await tester.tap(rowCards().first);
      await tester.pump();
      expect(opened, <String>['abs-book', 'jf-movie']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opt-in 关着：不问服务器、不混排；打开后立即混进来', (WidgetTester tester) async {
      useSize(tester, const Size(1280, 900));
      await prefs.setJellyfinShowInLibrary(false);
      await prefs.setAudiobookshelfShowInHome(false);
      int calls = 0;
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        buildApp(
          serverContinueLoader: () async {
            calls++;
            return <ServerContinueCandidate>[
              candidate(
                ServerContinueSource.mediaServer,
                'jf-movie',
                '服务器电影',
                now - 100,
                opened,
              ),
              candidate(
                ServerContinueSource.audiobookshelf,
                'abs-book',
                '有声书',
                now - 200,
                opened,
              ),
            ];
          },
        ),
      );
      await pumpDashboard(tester);
      expect(calls, 0, reason: 'both opt-ins off: no server is asked');
      expect(hero(), findsNothing);

      // 只开 ABS：媒体服务器条目仍不混排。
      await prefs.setAudiobookshelfShowInHome(true);
      await pumpDashboard(tester);
      expect(calls, 1);
      expect(
        continueItems(tester).map((_ContinueItem i) => i.title).toList(),
        <String>['有声书'],
      );

      // 再关掉：已上屏的条目立即消失。
      await prefs.setAudiobookshelfShowInHome(false);
      await pumpDashboard(tester);
      expect(hero(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('节流：短时间内来回切回首页不重复请求服务器', (WidgetTester tester) async {
      useSize(tester, const Size(1280, 900));
      int calls = 0;
      final List<String> opened = <String>[];
      Future<List<ServerContinueCandidate>> loader() async {
        calls++;
        return <ServerContinueCandidate>[
          candidate(
            ServerContinueSource.mediaServer,
            'jf-movie',
            '服务器电影',
            now - 100,
            opened,
          ),
        ];
      }

      final HomeTab tabBefore = homeShellTabNotifier.value;
      addTearDown(() => homeShellTabNotifier.value = tabBefore);
      homeShellTabNotifier.value = HomeTab.home;
      await tester.pumpWidget(buildApp(serverContinueLoader: loader));
      await pumpDashboard(tester);
      expect(calls, 1);
      // 来回切 tab：切回首页触发 onTabActivated，节流期内不重发请求。
      for (int i = 0; i < 3; i++) {
        homeShellTabNotifier.value = HomeTab.video;
        await tester.pump();
        homeShellTabNotifier.value = HomeTab.home;
        await pumpDashboard(tester);
      }
      expect(calls, 1, reason: 'fresh result reused inside the TTL');
      expect(
        continueItems(tester).map((_ContinueItem i) => i.title).toList(),
        <String>['服务器电影'],
      );
      // 从服务器条目回来 = 进度确实变了：强制重取。
      await tester.tap(heroCard());
      await tester.pump();
      await pumpDashboard(tester);
      expect(opened, <String>['jf-movie']);
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('取数失败：静默不贡献条目，首页照常渲染', (WidgetTester tester) async {
      useSize(tester, const Size(1280, 900));
      await tester.pumpWidget(
        buildApp(
          serverContinueLoader: () async => throw StateError('server offline'),
        ),
      );
      await pumpDashboard(tester);

      expect(hero(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('模块门控：视频模块关着不出服务器视频，书模块的 ABS 条目照出', (
      WidgetTester tester,
    ) async {
      useSize(tester, const Size(1280, 900));
      await appModel.setModuleEnabled(ModuleId.video, false);
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        buildApp(
          serverContinueLoader: () async => <ServerContinueCandidate>[
            candidate(
              ServerContinueSource.mediaServer,
              'jf-movie',
              '服务器电影',
              now - 100,
              opened,
            ),
            candidate(
              ServerContinueSource.audiobookshelf,
              'abs-book',
              '有声书',
              now - 9000,
              opened,
            ),
          ],
        ),
      );
      await pumpDashboard(tester);

      expect(
        continueItems(tester).map((_ContinueItem i) => i.title).toList(),
        <String>['有声书'],
      );
      expect(tester.takeException(), isNull);
    });
  });

  /// BUG-1111/BUG-1112 公共装配：让本用例以 **Windows** 语义组装 [AppModel]。
  ///
  /// galgame 只做 Windows 端，判据收在 [ModuleId.availableOn]（`games => isWindows`），
  /// 而仪表盘会按 [ModuleVisibility] 过滤条目种类。凡是喂了游戏数据的用例一律显式
  /// 声明平台，不靠宿主平台碰运气（Linux CI 上游戏整块不渲染，否定断言恒真）。
  void useWindowsPlatform() {
    platformServices = testPlatformServices(isWindows: true, isDesktop: true);
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  }

  Future<void> seedGame({
    required String id,
    required String name,
    required DateTime addedAt,
    DateTime? playedAt,
    String? coverPath,
  }) async {
    await db.upsertGalgame(
      GalgamesCompanion(
        id: Value(id),
        name: Value(name),
        exePath: Value('/abs/$id.exe'),
        workdir: const Value('/abs'),
        addedAt: Value(addedAt.millisecondsSinceEpoch),
        coverPath: Value(coverPath),
      ),
    );
    if (playedAt != null) {
      await db.insertGalgameSession(
        GalgameSessionsCompanion(
          gameId: Value(id),
          startMs: Value(playedAt.millisecondsSinceEpoch - 60000),
          endMs: Value(playedAt.millisecondsSinceEpoch),
          durationSeconds: const Value(60),
          dateKey: Value(FushiTimeFormat.dayKey(playedAt)),
        ),
      );
    }
  }

  testWidgets('BUG-1111：玩过的游戏进「继续」区（游戏无完成度，不画角标）', (WidgetTester tester) async {
    useWindowsPlatform();
    useSize(tester, const Size(1280, 900));
    final DateTime now = DateTime.now();
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('v-1'),
        title: Value('某视频'),
        videoPath: Value('/abs/v1.mp4'),
        lastPositionMs: Value(5000),
      ),
    );
    await seedGame(
      id: 'g-1',
      name: '某游戏',
      addedAt: now.subtract(const Duration(days: 3)),
      playedAt: now,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final List<_ContinueItem> cards = continueItems(tester);
    expect(
      cards.map((_ContinueItem c) => c.title),
      containsAll(<String>['某游戏', '某视频']),
    );
    final _ContinueItem game = cards.singleWhere(
      (_ContinueItem c) => c.title == '某游戏',
    );
    expect(game.badgeLabel, isNull);
    expect(game.progress, isNull);
  });

  testWidgets('BUG-1111：同合集的多个游戏在「继续」区收敛成一张卡（与视频侧同口径）', (
    WidgetTester tester,
  ) async {
    useWindowsPlatform();
    useSize(tester, const Size(1280, 900));
    final DateTime now = DateTime.now();
    await seedGame(
      id: 'gc-1',
      name: '游戏A',
      addedAt: now.subtract(const Duration(days: 9)),
      playedAt: now.subtract(const Duration(days: 2)),
    );
    await seedGame(
      id: 'gc-2',
      name: '游戏B',
      addedAt: now.subtract(const Duration(days: 8)),
      playedAt: now,
    );
    final int cid = await db.createMediaCollection('某系列');
    await db.addToCollection(cid, MediaKind.game, 'gc-1');
    await db.addToCollection(cid, MediaKind.game, 'gc-2');

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(continueItems(tester).map((_ContinueItem c) => c.title), <String>[
      '某系列',
    ]);
  });

  testWidgets('继续区合集 Next-Up：看完 E1 后合集卡推进为 E2（角标第 2 集），点击直接打开 E2', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    final int cid = await seedCollectionTwoEpisodes(
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        lastPositionMs: const Value(1200000),
        completedAt: Value(DateTime.now()),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );

    final List<(String, int?)> opened = <(String, int?)>[];
    await tester.pumpWidget(
      buildApp(
        openVideoOverride:
            (
              BuildContext _,
              VideoBookRepository __,
              String bookUid,
              int? playlistCollectionId,
            ) async {
              opened.add((bookUid, playlistCollectionId));
            },
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final _HeroView c = onlyHero(tester);
    expect(c.title, '进击的巨人');
    expect(c.progressLabel, t.home_continue_episode(n: 2));
    // 主角卡整卡可点：点卡内标题文字同样打开 Next-Up 那一集。
    final Finder title = heroTitle('进击的巨人');
    expect(title, findsOneWidget);
    await tester.tap(title);
    await tester.pump();
    expect(opened, <(String, int?)>[('e2', cid)]);
  });

  /// 书合集：卷 1..n 按给定顺序加进同一合集（sortIndex 即加入顺序）。成员行
  /// 必须真有对应 `epub_books` 行——首页合集归属查询只认库里还在的书。成员键
  /// 默认 `epub_books.uid`（v83 起的生产形态）；[legacyBookKey] 模拟 v83 前写入
  /// 的 bookKey 键旧行。
  Future<int> seedBookCollection(
    String name,
    List<String> keys, {
    bool legacyBookKey = false,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int cid = await db.createMediaCollection(name);
    for (final String k in keys) {
      final String uid = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: k,
          title: k,
          epubPath: '/abs/$k.epub',
          extractDir: '/abs/$k',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - 60000,
        ),
      );
      await db.addToCollection(cid, MediaKind.epub, legacyBookKey ? k : uid);
    }
    return cid;
  }

  MediaItem bookAt(String key, {required int position}) =>
      readingBook(key, key, position: position);

  testWidgets('书合集续读：读完第 1 卷后「继续」推进到第 2 卷（不再整套消失）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedBookCollection('某轻小说', <String>['卷1', '卷2', '卷3']);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[
          // 卷 1 读到末尾（position == duration → finished），卷 2/3 没开读。
          bookAt('卷1', position: 100),
          bookAt('卷2', position: 0),
          bookAt('卷3', position: 0),
        ],
        <String, int>{'卷1': now},
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final _HeroView h = onlyHero(tester);
    expect(h.title, '某轻小说');
    expect(h.progressLabel, t.home_continue_volume(n: 2));
    expect(rowCards(), findsNothing);
  });

  testWidgets('书合集续读：整套读完 → 不出卡；同合集两卷在读只出一张最近读的', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedBookCollection('读完的系列', <String>['完1', '完2']);
    await seedBookCollection('在读的系列', <String>['读1', '读2', '读3']);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[
          bookAt('完1', position: 100),
          bookAt('完2', position: 100),
          // 读3 是刚才读的那卷（时刻最新），读1 是更早留下的半截。
          bookAt('读1', position: 30),
          bookAt('读2', position: 0),
          bookAt('读3', position: 60),
        ],
        <String, int>{
          '完1': now - 9000,
          '完2': now - 8000,
          '读1': now - 5000,
          '读3': now,
        },
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final _HeroView h = onlyHero(tester);
    expect(h.title, '在读的系列');
    expect(h.progressLabel, t.home_continue_volume(n: 3));
    expect(rowCards(), findsNothing);
  });

  testWidgets('书合集续读：v83 前 bookKey 键的旧成员行同样推进到下一卷', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedBookCollection('旧合集', <String>['旧1', '旧2'], legacyBookKey: true);
    await tester.pumpWidget(
      buildAppWithBooks(
        <MediaItem>[bookAt('旧1', position: 100), bookAt('旧2', position: 0)],
        <String, int>{'旧1': DateTime.now().millisecondsSinceEpoch},
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final _HeroView h = onlyHero(tester);
    expect(h.title, '旧合集');
    expect(h.progressLabel, t.home_continue_volume(n: 2));
  });

  testWidgets('继续区合集 Next-Up：整个合集全部看完 → 不出卡（自然滚出继续区）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedCollectionTwoEpisodes(
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        lastPositionMs: const Value(1200000),
        completedAt: Value(DateTime.now()),
      ),
      e2: VideoBooksCompanion(
        bookUid: const Value('e2'),
        title: const Value('S01E02'),
        videoPath: const Value('/abs/e2.mp4'),
        lastPositionMs: const Value(1300000),
        completedAt: Value(DateTime.now()),
      ),
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(hero(), findsNothing);
    expect(rowCards(), findsNothing);
    expect(find.byType(HomeEmptyState), findsOneWidget);
  });

  testWidgets('精简 · 新用户空库：不是一片空白——头部行 + 空态说明 + 去书架 / 去媒体库', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(420, 900));
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(HomeStudyHeader), findsOneWidget);
    // 空库也照样挂分区标题，空态说明落在「继续」卡里。
    expect(sectionTitle(studyCardKey, t.stat_today), findsOneWidget);
    expect(sectionTitle(continueCardKey, t.home_continue), findsOneWidget);
    expect(find.text(t.stat_goal_set), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(continueCardKey),
        matching: find.text(t.home_continue_empty),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-empty-go-books')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-empty-go-video')),
      findsOneWidget,
    );
    expect(find.byType(HomeContinueRowSkeleton), findsNothing);

    // 引导按钮切到对应 tab。
    final HomeTab tabBefore = homeShellTabNotifier.value;
    addTearDown(() => homeShellTabNotifier.value = tabBefore);
    await tester.tap(find.byKey(const ValueKey<String>('home-empty-go-books')));
    await tester.pump();
    expect(homeShellTabNotifier.value, HomeTab.books);
  });

  testWidgets('精简 · 首载未完成：头部行与封面行挂同轮廓骨架，不先闪空态', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());

    expect(find.byType(HomeContinueRowSkeleton), findsOneWidget);
    expect(find.byType(HomeGoalSkeleton), findsOneWidget);
    expect(find.byType(HomeEmptyState), findsNothing);
    // 骨架期间分区标题已在位（数据到达后不跳版），「最近添加」不出骨架。
    expect(sectionTitle(studyCardKey, t.stat_today), findsOneWidget);
    expect(sectionTitle(continueCardKey, t.home_continue), findsOneWidget);
    expect(find.byKey(recentCardKey), findsNothing);

    await pumpDashboard(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HomeContinueRowSkeleton), findsNothing);
    expect(hero(), findsOneWidget);
  });

  testWidgets('BUG-3034 · 切回首页（页面重建）首帧直接用上一轮快照，不再挂骨架等整批', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    final ValueNotifier<bool> showPage = ValueNotifier<bool>(true);
    addTearDown(showPage.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
          ...bookStreamOverrides(),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: showPage,
                builder: (BuildContext context, bool show, Widget? _) => show
                    ? HomeDashboardPage(videoRepo: VideoBookRepository(db))
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
    await pumpDashboard(tester);
    expect(hero(), findsOneWidget);

    showPage.value = false;
    await tester.pump();
    expect(find.byType(HomeDashboardPage), findsNothing);

    showPage.value = true;
    await tester.pump();
    // 重建后的**第一帧**：快照已上屏，没有骨架。
    expect(find.byType(HomeContinueRowSkeleton), findsNothing);
    expect(find.byType(HomeGoalSkeleton), findsNothing);
    expect(onlyHero(tester).title, '继续看的视频');
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('今日目标：未设目标只显示设定入口；对话框设 1000 后进度行 = 800/1000', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(find.text(t.stat_goal_set), findsOneWidget);
    expect(
      tester.widget<HomeGoalRing>(find.byType(HomeGoalRing)).fraction,
      isNull,
    );

    await tester.tap(find.text(t.stat_goal_set));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 2026-10-10：每周目标已删（只能设、不显示进度），对话框只剩每日一个框。
    expect(
      find.byKey(const ValueKey<String>('stat-goal-weekly-field')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('stat-goal-daily-field')),
      '1000',
    );
    await tester.tap(find.byKey(const ValueKey<String>('stat-goal-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(
      find.text(t.stat_goal_progress(read: 800, goal: 1000)),
      findsOneWidget,
    );
    expect(
      tester.widget<HomeGoalRing>(find.byType(HomeGoalRing)).fraction,
      0.8,
    );
    expect(find.text(t.stat_goal_set), findsNothing);
  });

  testWidgets('设定目标弹窗（M3E 重做）：hero 图标 + 大号填充输入 + 近 7 日日均建议 chip + '
      '连接按钮组预设（选中态随输入联动）+ 实心保存按钮', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    // 今天读了 800 字（seedSampleData）→ 近 7 日日均 = 800 ~/ 7 = 114。
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    await tester.tap(find.text(t.stat_goal_set));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final Finder dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(FushiDialogHeroIcon)),
      findsOneWidget,
    );
    // 只剩每日一个输入框（每周目标 2026-10-10 删除），单位后缀一个。
    expect(
      find.descendant(of: dialog, matching: find.text(t.stat_goal_unit_chars)),
      findsOneWidget,
    );
    final Finder dailyFinder = glassUnwrap<TextField>(
      find.byKey(const ValueKey<String>('stat-goal-daily-field')),
    );
    expect(tester.widget<TextField>(dailyFinder).decoration?.filled, isTrue);

    // 近 7 日日均是一颗可点的建议 chip：点一下就填进去。
    final Finder average = find.byKey(
      const ValueKey<String>('stat-goal-average-chip'),
    );
    expect(
      find.descendant(
        of: average,
        matching: find.text(t.stat_goal_recent_average(n: 114)),
      ),
      findsOneWidget,
    );
    await tester.tap(average);
    await tester.pump();
    expect(tester.widget<TextField>(dailyFinder).controller?.text, '114');

    // 预设：连接按钮组，点「5000」填入且该格变成选中态。
    final Finder presets = find.byKey(
      const ValueKey<String>('stat-goal-presets'),
    );
    await tester.tap(find.descendant(of: presets, matching: find.text('5000')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TextField>(dailyFinder).controller?.text, '5000');
    expect(
      tester.widget<FushiConnectedButtonGroup<int>>(presets).selected,
      <int>{5000},
    );
    // 手输一个非预设值：选中态清空。
    await tester.enterText(dailyFinder, '4321');
    await tester.pump();
    expect(
      tester.widget<FushiConnectedButtonGroup<int>>(presets).selected,
      isEmpty,
    );
    await tester.enterText(dailyFinder, '5000');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('stat-goal-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(
      find.text(t.stat_goal_progress(read: 800, goal: 5000)),
      findsOneWidget,
    );
  });

  testWidgets('焦点可遍历：Tab 能落到主角卡（整卡是唯一停靠点）与横滑行封面卡', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('video/second'),
        title: Value('第二个在看的视频'),
        videoPath: Value('/abs/second.mp4'),
        lastPositionMs: Value(30000),
      ),
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(rowCards(), findsOneWidget);

    bool focusedIn(Finder target) {
      final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      final Element el = tester.element(target);
      if (identical(ctx, el)) return true;
      bool hit = false;
      ctx.visitAncestorElements((Element e) {
        if (identical(e, el)) hit = true;
        return !hit;
      });
      return hit;
    }

    bool reachedHero = false;
    bool reachedRowCard = false;
    // 一轮遍历里落在主角卡内的焦点节点：卡上没有按钮，整卡是唯一停靠点。
    final Set<FocusNode> heroStops = <FocusNode>{};
    // 不提前退出：走满一整轮，主角卡内若有第二个停靠点也会被记到。
    for (int i = 0; i < 60; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (focusedIn(heroCard())) {
        reachedHero = true;
        heroStops.add(FocusManager.instance.primaryFocus!);
      }
      reachedRowCard |= focusedIn(rowCards());
    }
    expect(reachedHero, isTrue, reason: '主角卡整卡必须是 Tab 可达的焦点停靠点');
    expect(reachedRowCard, isTrue, reason: '横滑行封面卡必须是 Tab 可达的焦点停靠点');
    expect(heroStops, hasLength(1), reason: '主角卡只占一个 Tab 停靠点（整卡 = 继续）');
  });

  // ── 2026-10 首页统一浮动工具栏 ────────────────────────────────────────────

  Finder dashboardList() => find.byWidgetPredicate(
    (Widget w) => w is ListView && w.scrollDirection == Axis.vertical,
  );
  HomeFloatingToolbar toolbar(WidgetTester tester) =>
      tester.widget<HomeFloatingToolbar>(find.byType(HomeFloatingToolbar));
  HomeResumeFab resumeFab(WidgetTester tester) =>
      tester.widget<HomeResumeFab>(find.byType(HomeResumeFab));
  bool excludedFromFocus(WidgetTester tester, Finder target) => tester
      .widgetList<ExcludeFocus>(
        find.ancestor(of: target, matching: find.byType(ExcludeFocus)),
      )
      .any((ExcludeFocus w) => w.excluding);

  /// 滚动后跑完弹簧（default spatial 约 0.5 s 收敛）。
  Future<void> settleSpring(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('浮动工具栏：左上角是头像（不再是「首页」标题胶囊），右侧更新/统计/收藏夹/排行榜/反馈', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final Finder avatar = find.byKey(
      const ValueKey<String>('home-toolbar-avatar'),
    );
    expect(avatar, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi_floating_top_bar_title')),
      findsNothing,
    );
    final double cardTop = tester.getTopLeft(find.byType(HomeStudyHeader)).dy;
    expect(tester.getTopLeft(avatar).dy, lessThan(cardTop));
    expect(tester.getTopLeft(avatar).dx, lessThan(100));
    for (final String key in <String>[
      'home-toolbar-updates',
      'home-toolbar-stats',
      'home-toolbar-collections',
      'home-toolbar-leaderboard',
      'home-toolbar-feedback',
    ]) {
      final Finder button = find.byKey(ValueKey<String>(key));
      expect(button, findsOneWidget, reason: key);
      expect(tester.getTopLeft(button).dy, lessThan(cardTop));
    }
    // 首屏封面行在视野里：FAB 不出现。
    expect(resumeFab(tester).visible, isFalse);
  });

  testWidgets('浮动工具栏：收藏夹按钮是收藏夹唯一入口，按下打开 CollectionsPage', (
    WidgetTester tester,
  ) async {
    // 用户 2026-10-14 定案：库页页头的收藏夹按钮全部撤掉（收藏夹不按模块隔离，
    // 每个模块各挂一个只会误导），统一从首页进——同统计中心 2026-09-01 的收敛。
    useSize(tester, const Size(1280, 900));
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final Finder button = find.byKey(
      const ValueKey<String>('home-toolbar-collections'),
    );
    expect(button, findsOneWidget);
    expect(find.byTooltip(t.collections), findsOneWidget);
    expect(find.byType(CollectionsPage), findsNothing);

    await tester.tap(button);
    await pumpDashboard(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CollectionsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('BUG-3249 头像跟随 Profile 改名与切换（不止 initState 读一次）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    final int alice = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Alice', createdAt: 0, updatedAt: 0),
    );
    final int bob = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Bob', createdAt: 0, updatedAt: 0),
    );
    await db.setPref('active_profile_id', '$alice');
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    String avatarLabel() => tester
        .widget<Semantics>(
          find.byKey(const ValueKey<String>('home-toolbar-avatar')),
        )
        .properties
        .label!;
    expect(avatarLabel(), 'Alice');

    await db.updateProfileName(alice, 'Alicia');
    await pumpDashboard(tester);
    expect(avatarLabel(), 'Alicia', reason: '改名后头像要跟着变');

    await db.setPref('active_profile_id', '$bob');
    await pumpDashboard(tester);
    expect(avatarLabel(), 'Bob', reason: '切换激活 Profile 后头像要跟着变');
  });

  testWidgets('浮动工具栏：Tab 可达五颗动作按钮（焦点可遍历）', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    bool focusedIn(Finder target) {
      final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      final Element el = tester.element(target);
      if (identical(ctx, el)) return true;
      bool hit = false;
      ctx.visitAncestorElements((Element e) {
        if (identical(e, el)) hit = true;
        return !hit;
      });
      return hit;
    }

    final Set<String> reached = <String>{};
    const List<String> keys = <String>[
      'home-toolbar-updates',
      'home-toolbar-stats',
      'home-toolbar-collections',
      'home-toolbar-leaderboard',
      'home-toolbar-feedback',
    ];
    for (int i = 0; i < 40 && reached.length < keys.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (final String key in keys) {
        if (focusedIn(find.byKey(ValueKey<String>(key)))) reached.add(key);
      }
    }
    expect(reached, keys.toSet());
  });

  testWidgets('浮动工具栏随滚动：下滚退场（不可聚焦），回滚弹回', (WidgetTester tester) async {
    // 首页精简后内容只剩一张卡，矮视口才滚得动。
    useSize(tester, const Size(420, 260));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(toolbar(tester).visible, isTrue);
    final Finder stats = find.byKey(
      const ValueKey<String>('home-toolbar-stats'),
      skipOffstage: false,
    );
    expect(excludedFromFocus(tester, stats), isFalse);

    await tester.drag(dashboardList(), const Offset(0, -150));
    await settleSpring(tester);
    expect(toolbar(tester).visible, isFalse);
    expect(excludedFromFocus(tester, stats), isTrue, reason: '退场中的栏不能还被 Tab 到');

    await tester.drag(dashboardList(), const Offset(0, 60));
    await settleSpring(tester);
    expect(toolbar(tester).visible, isTrue);
    expect(excludedFromFocus(tester, stats), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HomeToolbarScrollState：只认主列表纵向滚动，带回差切换显隐', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final BuildContext scrollContext = tester.element(find.byType(Scaffold));
    final HomeToolbarScrollState state = HomeToolbarScrollState();
    addTearDown(state.dispose);
    ScrollUpdateNotification update({
      required double pixels,
      required double delta,
      Axis axis = Axis.vertical,
    }) => ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 5000,
        pixels: pixels,
        viewportDimension: 800,
        axisDirection: axis == Axis.vertical
            ? AxisDirection.down
            : AxisDirection.right,
        devicePixelRatio: 1,
      ),
      context: scrollContext,
      scrollDelta: delta,
    );

    // 横滑行（卡片里的横向列表）：不影响。
    state.handle(update(pixels: 900, delta: 200, axis: Axis.horizontal));
    expect(state.visible, isTrue);
    expect(state.pastHero, isFalse);
    // 主列表下滚一段（超过回差）→ 退场。
    state.handle(update(pixels: 400, delta: 40));
    expect(state.visible, isFalse);
    expect(state.pastHero, isTrue);
    // 小幅回滚（未过回差）→ 仍隐藏；继续回滚 → 出现。
    state.handle(update(pixels: 390, delta: -10));
    expect(state.visible, isFalse);
    state.handle(update(pixels: 360, delta: -30));
    expect(state.visible, isTrue);
    // 顶部一屏栏高之内恒显示，FAB 条件解除。
    state.handle(update(pixels: 60, delta: 40));
    expect(state.visible, isTrue);
    expect(state.pastHero, isFalse);
  });

  // BUG-1220：追踪链路原本零可观测（成功即删 outbox 行、失败只进错误日志并退避、
  // 没建映射就静默返回），用户「看完了没反应」时无处可看。这张卡是唯一出口，
  // 三种断裂状态各自必须说得出话。
  //
  // 2026-08-19 Bangumi 同步临时下线（kMediaTrackingEnabled=false）：卡不再挂载，
  // 整组随功能一起停用；恢复开关时删掉 skip 原样启用。
  group(
    'Bangumi 同步卡（BUG-1220）',
    skip: kMediaTrackingEnabled
        ? false
        : 'Bangumi 同步临时下线（kMediaTrackingEnabled=false）',
    () {
      void useWideSurface(WidgetTester tester) {
        tester.view.physicalSize = const Size(1400, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      Future<void> connect({String account = 'Alice'}) async {
        await prefs.setPref(kBangumiAccessTokenPref, 'token');
        await prefs.setPref(kBangumiAccountNamePref, account);
      }

      testWidgets('未连接：明说未连接并给出连接入口', (WidgetTester tester) async {
        useWideSurface(tester);
        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        expect(tester.takeException(), isNull);
        expect(find.text(t.media_tracking_card_title), findsOneWidget);
        expect(find.text(t.media_tracking_not_connected), findsOneWidget);
        expect(
          find.widgetWithText(FilledButton, t.media_tracking_connect),
          findsOneWidget,
        );
      });

      testWidgets('已连接但没有本地历史：不再显示泛化的零关联警告', (WidgetTester tester) async {
        useWideSurface(tester);
        await connect();
        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        expect(tester.takeException(), isNull);
        // 账号名从偏好读回（不只是本次会话的连接结果）。
        expect(find.text('Alice'), findsOneWidget);
        // 从未同步必须与「同步过零待办」区分：成功即删 outbox 行，两者否则同形。
        expect(
          find.textContaining(t.media_tracking_never_synced),
          findsOneWidget,
        );
        expect(find.text(t.media_tracking_no_local_history), findsOneWidget);
        expect(find.text(t.media_tracking_watched_show), findsOneWidget);
      });

      testWidgets('以前看完但未映射的视频会明确列为需要手动关联', (WidgetTester tester) async {
        useWideSurface(tester);
        await connect();
        await db.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: 'old-video',
            title: '以前看过的番剧',
            videoPath: 'C:/video/old.mkv',
            completedAt: Value<DateTime?>(DateTime.now()),
          ),
        );

        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('以前看过的番剧'), findsOneWidget);
        expect(
          find.text(
            '${t.media_tracking_anime} · '
            '${t.media_tracking_manual_required}',
          ),
          findsOneWidget,
        );
        expect(
          find.text(t.media_tracking_manual_required_count(n: 1)),
          findsOneWidget,
        );
      });

      testWidgets('已关联条目列出本地标题 + Bangumi 条目名，并给出打开入口', (
        WidgetTester tester,
      ) async {
        useWideSurface(tester);
        await connect();
        await MediaTrackingRepository(db).saveMapping(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: '8',
          mediaTitle: '本地动画合集',
          kind: TrackingKind.anime,
          subjectId: 88,
          subjectName: 'Remote anime',
          progressMode: TrackingProgressMode.episode,
          progressOffset: 1,
        );

        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('本地动画合集'), findsOneWidget);
        expect(find.textContaining('Remote anime'), findsOneWidget);
        expect(find.byIcon(FushiIcons.openInNew), findsOneWidget);
        expect(
          find.textContaining(t.media_tracking_linked_count(n: 1)),
          findsOneWidget,
        );
        expect(find.text(t.media_tracking_no_local_history), findsNothing);
      });

      testWidgets('上报失败：退避窗口内也照说失败原因', (WidgetTester tester) async {
        useWideSurface(tester);
        await connect();
        final MediaTrackingRepository repository = MediaTrackingRepository(db);
        await repository.saveMapping(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: '8',
          mediaTitle: '失败的动画',
          kind: TrackingKind.anime,
          subjectId: 88,
          subjectName: 'Remote anime',
          progressMode: TrackingProgressMode.episode,
          progressOffset: 1,
        );
        await repository.enqueueProgress(
          mediaType: TrackingMediaType.videoCollection,
          mediaKey: '8',
          localProgress: 1,
          completed: false,
        );
        final List<PendingTrackingUpdate> due = await repository.dueUpdates();
        await repository.markFailed(
          due.single.outbox,
          const BangumiApiException(statusCode: 500, message: 'boom'),
        );
        // 退避后发送侧已看不到这一行——展示侧仍必须说得出原因。
        expect(await repository.dueUpdates(), isEmpty);

        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        expect(tester.takeException(), isNull);
        // 失败原因挂在条目行上，标题只出现一次（不另开「失败」段重复一遍）。
        expect(find.text('失败的动画'), findsOneWidget);
        expect(
          find.textContaining('${t.media_tracking_last_error}: '),
          findsOneWidget,
        );
        expect(find.textContaining('500'), findsOneWidget);
        expect(find.byIcon(FushiIcons.syncProblem), findsOneWidget);
        expect(
          find.textContaining(t.media_tracking_pending_count(n: 1)),
          findsOneWidget,
        );
      });

      testWidgets('令牌被拒：给出「重新连接」提示', (WidgetTester tester) async {
        useWideSurface(tester);
        await connect();
        await prefs.setPref(kMediaTrackingLastSyncUnauthorizedPref, true);
        await prefs.setPref(
          kMediaTrackingLastSyncAtPref,
          DateTime.now().millisecondsSinceEpoch,
        );

        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        expect(tester.takeException(), isNull);
        expect(find.text(t.media_tracking_unauthorized), findsOneWidget);
      });

      testWidgets('自动关联 miss 后显示真实重试入口并回显结果', (WidgetTester tester) async {
        useWideSurface(tester);
        await connect();
        // 不存在的本地游戏会形成一次可重试 miss，且不访问真实网络。
        await appModel.mediaTrackingService.recordGameStatus(
          gameId: 'missing-game',
          status: 3,
        );

        await tester.pumpWidget(buildApp());
        await pumpDashboard(tester);

        final Finder retryButton = find.widgetWithText(
          FilledButton,
          t.media_tracking_retry_mapping,
        );
        expect(retryButton, findsOneWidget);

        await tester.tap(retryButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));

        expect(
          find.text(t.media_tracking_retry_no_match),
          findsOneWidget,
          reason: '重试不能被 10 分钟退避无声吞掉，匹配结果必须回显',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );
}

/// 16x9 横版 PNG：朝向探测（`CoverOrientationBuilder`）读的是**解码出来的固有
/// 宽高比**，1x1 方图会被判成竖卡，测不出横卡分流，故另备一张真横图。
const List<int> _kLandscapePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x09,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x3B, 0x2A, 0xAC,
  0x32, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41,
  0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x9F, 0x12, 0xCC, 0x30, 0x6A, 0xC0, 0xA8, 0x01,
  0x40, 0x0C, 0x00, 0xDC, 0x62, 0x1E, 0xF0, 0xA7,
  0x42, 0xC0, 0xCB, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// 1x1 透明 PNG：BUG-1112 需要一个**真实可解码**的封面文件（`Image.file` 对不存在
/// 或损坏的文件走 errorBuilder，断言不到 FileImage）。
const List<int> _kOnePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// 「继续」条目的统一视图：主角卡（角标文案取 progressLabel，无角标图标）与横滑
/// 行封面卡归一，便于按屏上顺序断言排序 / 去重 / 进度。
typedef _HeroView = ({
  String title,
  String? progressLabel,
  double? progress,
  String? eyebrow,
  double? coverHeight,
  String subtitle,
});

typedef _ContinueItem = ({
  String title,
  String? badgeLabel,
  double? progress,
  IconData? badgeIcon,
});

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
