import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_logo_title.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/utils/misc/dashboard_server_continue.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart'
    show FushiMotion;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/media/media_cover_source.dart'
    show mediaCoverFallbackIcon;
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/stats/study_goal_language.dart'
    show StudyGoalUnitChoice;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/pages/implementations/home_widget_grid.dart';
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
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart'
    show FushiConnectedButtonGroup;
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatChars, formatStatTime;
import 'package:fushi/src/pages/implementations/stat_charts.dart'
    show formatStatCharsAxis;
import 'package:fushi/src/stats/study_goal_record.dart';
import 'package:fushi/src/pages/implementations/study_goal_visuals.dart'
    show StudyGoalDayStrip, StudyGoalProgressBar, StudyGoalRing;
import 'package:fushi/src/platform/widget_snapshot.dart'
    show StudyGoalDay, StudyGoalState;
import 'package:fushi/src/stats/study_goals.dart'
    show
        formatStudyGoalDuration,
        studyGoalCompactPair,
        studyGoalLanguageLabel,
        studyGoalReviewsHiddenNote,
        studyGoalShortLabel;
import 'package:fushi/src/pages/implementations/reading_statistics_page.dart'
    show ReadingStatisticsPage;
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show FushiShellTheme, ShellContentLayout;
import 'package:flutter/rendering.dart'
    show RenderClipPath, RenderClipRRect, RenderClipRect, RenderParagraph;
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';
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

  /// 本用例钉的库页布局（PR #3397 外壳改版）：默认钉封面网格——网格下首页走原
  /// 版式正文（主角卡 + 横滑行 + 今日 / 最近添加面板），下面多数用例守的是那套
  /// 版式；拼贴（色块，产品默认）路径的同一批数据行为由各用例里
  /// `dashboardLayout = ShellContentLayout.collage` 的分支 / 专门用例另行断言。
  ShellContentLayout dashboardLayout = ShellContentLayout.grid;
  ThemeData shellTheme() => ThemeData(
    extensions: <ThemeExtension<dynamic>>[
      FushiShellTheme(contentLayout: dashboardLayout),
    ],
  );
  late Directory storeDir;

  /// 提到外层：Bangumi 同步卡的状态全部来自偏好（令牌/账号名/上次同步），测试要能写。
  late PreferencesRepository prefs;

  setUp(() async {
    dashboardLayout = ShellContentLayout.grid;
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
        theme: shellTheme(),
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
    // 艺术字（[FushiLogoTitle]）先经 ImageStream 量宽高比、量出来才建 [Image]：
    // 这段读取期间树上没有 Image，只看 Image 会漏掉它的文件句柄。
    Iterable<ImageProvider<Object>> providers() sync* {
      for (final Image image in tester.widgetList<Image>(find.byType(Image))) {
        yield image.image;
      }
      for (final FushiLogoTitle title in tester.widgetList<FushiLogoTitle>(
        find.byType(FushiLogoTitle),
      )) {
        yield title.logo;
      }
    }

    Future<bool> fileImagePending() async {
      for (final ImageProvider<Object> provider in providers()) {
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

  /// 往偏好 `home_widget_layout` 写一份布局（= 用户编辑过首页；没写的那份网格
  /// 仍按默认模板迁移）。
  Future<void> storeHomeLayout({
    List<HomeWidgetItem>? compact,
    List<HomeWidgetItem>? wide,
  }) => appModel.setHomeWidgetLayout(
    HomeWidgetLayout(compact: compact, wide: wide),
  );

  /// 窄网格里「继续」放 2×3（主卡在上、其余条目横滑在下）的布局。
  Future<void> storeCompactContinueTall() => storeHomeLayout(
    compact: const <HomeWidgetItem>[
      HomeWidgetItem(HomeWidgetKind.continueHero, HomeWidgetSize(2, 3)),
      HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(1, 1)),
    ],
  );

  /// 带读屏标签 [label] 的 Semantics 节点（不开语义树也能找）。
  Finder semanticsLabeled(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  /// 首页此刻用的是哪份网格（窄 2 列 / 宽 6 列）。
  HomeGridKind gridKind(WidgetTester tester) =>
      tester.widget<HomeWidgetGrid>(find.byType(HomeWidgetGrid)).grid;

  /// 书侧装配（「继续」区的书来自 provider，测试直接喂 MediaItem）。
  Widget buildAppWithBooks(
    List<MediaItem> books,
    Map<String, int> lastReadAt, {
    void Function(int collectionId, {required bool manga})?
    openBookCollectionOverride,
  }) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
      ...bookStreamOverrides(books: books, lastReadAt: lastReadAt),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: shellTheme(),
        home: Scaffold(
          body: HomeDashboardPage(
            videoRepo: VideoBookRepository(db),
            openBookCollectionOverride: openBookCollectionOverride,
          ),
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

  /// 窄网格「继续」2×3 主卡下面的条目小行（`home-continue-item/<i>`）：格子太矮放
  /// 不下库页同款封面卡，那段改成小封面 + 标题 + 进度文案的横滑小行。
  Finder miniRowItems() => find.descendant(
    of: find.byKey(const ValueKey<String>('home-continue-row')),
    matching: find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('home-continue-item/'),
    ),
  );

  /// 「最近添加」条目小行（`home-recent-item/<i>`）按屏上顺序。标题 / 副标题取自
  /// 整行的读屏标签「标题 · 副标题」（副标题自己也含「 · 」，按第一个切）。
  List<({String title, String subtitle})> recentRows(WidgetTester tester) {
    final List<({String title, String subtitle})> rows =
        <({String title, String subtitle})>[];
    for (int i = 0; ; i++) {
      final Finder item = find.byKey(ValueKey<String>('home-recent-item/$i'));
      if (item.evaluate().isEmpty) break;
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('home-recent-list')),
          matching: item,
        ),
        findsOneWidget,
      );
      final String label =
          tester
              .widget<Semantics>(
                find.ancestor(of: item, matching: find.byType(Semantics)).first,
              )
              .properties
              .label ??
          '';
      final int cut = label.indexOf(' · ');
      rows.add(
        cut < 0
            ? (title: label, subtitle: '')
            : (
                title: label.substring(0, cut),
                subtitle: label.substring(cut + 3),
              ),
      );
    }
    return rows;
  }

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
      // 只导入、没看过：窄网格默认模板里没有「最近添加」，宽网格默认模板里有（见
      // 下方双栏专项测试）。
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
      // 「今日」2×1（宽网格默认）沿用学习头部行；1×1（窄网格默认）是今日字数大字。
      expect(
        find.byType(HomeStudyHeader),
        twoColumn ? findsOneWidget : findsNothing,
      );
      if (!twoColumn) {
        expect(
          find.descendant(
            of: find.byKey(studyCardKey),
            matching: semanticsLabeled(formatStatChars(800)),
          ),
          findsOneWidget,
        );
      }
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
        if (!twoColumn) '刚导入的视频',
        if (!twoColumn) t.home_recently_added,
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.byType(StatContributionHeatmap), findsNothing);
      expect(
        gridKind(tester),
        twoColumn ? HomeGridKind.wide : HomeGridKind.compact,
      );
      expect(
        find.byKey(recentCardKey),
        twoColumn ? findsOneWidget : findsNothing,
      );
      final Rect study = tester.getRect(find.byKey(studyCardKey));
      final Rect continueCard = tester.getRect(find.byKey(continueCardKey));
      if (twoColumn) {
        // 宽网格默认模板（6 列）：「继续」4×2 在起始侧，「今日」2×1 在它旁边同一行
        // 顶齐；「最近添加」4×2 排在「继续」下面、与它同宽。
        expect(
          sectionTitle(recentCardKey, t.home_recently_added),
          findsOneWidget,
        );
        expect(study.left, greaterThan(continueCard.right));
        expect(study.top, closeTo(continueCard.top, 0.5));
        final Rect recent = tester.getRect(find.byKey(recentCardKey));
        expect(recent.top, greaterThan(continueCard.bottom));
        expect(recent.left, closeTo(continueCard.left, 0.5));
        expect(recent.width, closeTo(continueCard.width, 0.5));
      } else {
        // 窄网格默认模板（2 列）：「继续」2×2 满宽在上，「今日」1×1 在它下面。
        expect(continueCard.bottom, lessThanOrEqualTo(study.top));
        expect(study.left, closeTo(continueCard.left, 0.5));
        expect(study.width, lessThan(continueCard.width / 2 + 0.5));
      }
    });
  }

  test('版式纯函数：宽 / 窄网格判据', () {
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
  });

  for (final Size size in const <Size>[Size(420, 900), Size(844, 390)]) {
    testWidgets('版式 · ${size.width.toInt()}×${size.height.toInt()}：'
        '${size.width > size.height ? '横屏手机走宽网格' : '竖屏手机走窄网格'}', (
      WidgetTester tester,
    ) async {
      useSize(tester, size);
      await seedSampleData();
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      final bool twoColumn = size.width > size.height;
      expect(tester.takeException(), isNull);
      expect(
        gridKind(tester),
        twoColumn ? HomeGridKind.wide : HomeGridKind.compact,
      );
      final Rect study = tester.getRect(find.byKey(studyCardKey));
      final Rect continueCard = tester.getRect(find.byKey(continueCardKey));
      if (twoColumn) {
        // 横屏高度紧：「今日」排在「继续」旁边同一行，整块在首屏。
        expect(study.left, greaterThan(continueCard.right));
        expect(study.top, closeTo(continueCard.top, 0.5));
        expect(study.bottom, lessThan(size.height));
      } else {
        expect(continueCard.bottom, lessThanOrEqualTo(study.top));
      }
      // 主角卡（含封面）收在「继续」格子里：封面高跟格子走。
      final Rect heroRect = tester.getRect(heroCard());
      expect(heroRect.top, greaterThanOrEqualTo(continueCard.top - 0.5));
      expect(heroRect.bottom, lessThanOrEqualTo(continueCard.bottom + 0.5));
      expect(heroRect.right, lessThanOrEqualTo(continueCard.right + 0.5));
      expect(onlyHero(tester).coverHeight, lessThan(continueCard.height));
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
    // 「继续」只有在读的那本：主角卡，封面高度跟「继续」格子（宽网格 4×2）走、
    // 整卡收在格子里。
    final _HeroView h = onlyHero(tester);
    expect(h.title, '在读书');
    final Rect continueRect = tester.getRect(find.byKey(continueCardKey));
    final Rect heroRect = tester.getRect(heroCard());
    expect(h.coverHeight, lessThan(continueRect.height));
    expect(heroRect.bottom, lessThanOrEqualTo(continueRect.bottom + 0.5));
    expect(heroRect.right, lessThanOrEqualTo(continueRect.right + 0.5));
    // 「最近添加」：导入时间倒序、在读书已在「继续」里不重复出现、副标题是
    // 「类型 · 相对时间」；有分区标题。
    expect(sectionTitle(recentCardKey, t.home_recently_added), findsOneWidget);
    final List<({String title, String subtitle})> recent = recentRows(tester);
    expect(
      recent.map((({String title, String subtitle}) r) => r.title),
      <String>['新书B', '刚导入的视频', '新书A'],
    );
    expect(recent[0].subtitle, startsWith('${t.home_filter_read} · '));
    expect(recent[1].subtitle, startsWith('${t.home_filter_watch} · '));
    expect(recent[2].subtitle, startsWith('${t.home_filter_read} · '));
    for (int i = 0; i < recent.length; i++) {
      final Finder row = find.byKey(ValueKey<String>('home-recent-item/$i'));
      expect(
        find.descendant(of: row, matching: find.text(recent[i].title)),
        findsWidgets,
        reason: '条目小行把标题画在屏上：${recent[i].title}',
      );
      expect(
        tester.getRect(row).bottom,
        lessThanOrEqualTo(tester.getRect(find.byKey(recentCardKey)).bottom),
        reason: '放不下的行不画（不溢出格子）：${recent[i].title}',
      );
    }
    // 宽网格默认模板：「继续」在上，「最近添加」在它下面。
    expect(
      tester.getTopLeft(find.byKey(recentCardKey)).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.byKey(continueCardKey)).dy,
      ),
    );
  });

  testWidgets('双栏「最近添加」按格子大小列满（取导入最新的，按加入时间倒序）', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MediaItem> books = <MediaItem>[];
    for (int i = 1; i <= 6; i++) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: '新书${_seriesFreeSuffix(i)}',
          title: '新书${_seriesFreeSuffix(i)}',
          epubPath: '/abs/$i.epub',
          extractDir: '/abs/$i',
          chapterCount: 1,
          chaptersJson: '[]',
          // 新书6 最新。
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      books.add(
        readingBook(
          '新书${_seriesFreeSuffix(i)}',
          '新书${_seriesFreeSuffix(i)}',
          position: 0,
        ),
      );
    }
    await tester.pumpWidget(buildAppWithBooks(books, const <String, int>{}));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(
      recentRows(tester).map((({String title, String subtitle}) r) => r.title),
      // 默认 4×2 放得下 6 条以上（连续尺寸：格子越大列得越多，不再固定 4 条）。
      <String>['新书F', '新书E', '新书D', '新书C', '新书B', '新书A'],
    );
  });

  // BUG-4861：色块外观「最近添加」的半高色块外面曾包一层 ClipRect，把块的投影
  // 齐格子边切成直角矩形（左上角 / 右缘能看到一条直边）。块到格子之间不许有
  // 任何裁切层，投影要伸进格间距（与「继续」的半高块同口径）。
  testWidgets('色块「最近添加」：半高色块到格子之间没有裁切层，投影不被切成直角矩形（BUG-4861）', (
    WidgetTester tester,
  ) async {
    dashboardLayout = ShellContentLayout.collage;
    useSize(tester, const Size(1280, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MediaItem> books = <MediaItem>[];
    for (int i = 1; i <= 6; i++) {
      final String key = '新书${_seriesFreeSuffix(i)}';
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/abs/$i.epub',
          extractDir: '/abs/$i',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      books.add(readingBook(key, key, position: 0));
    }
    await tester.pumpWidget(buildAppWithBooks(books, const <String, int>{}));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final RenderObject tile = tester.renderObject(
      find.byKey(homeWidgetTileKey(HomeWidgetKind.recentlyAdded)),
    );
    final Finder blocks = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('home-recent-block/'),
    );
    expect(blocks, findsAtLeastNWidgets(2));
    for (final Element block in blocks.evaluate()) {
      final List<String> clips = <String>[];
      RenderObject? node = block.renderObject?.parent;
      while (node != null && !identical(node, tile)) {
        if (node is RenderClipRect ||
            node is RenderClipRRect ||
            node is RenderClipPath) {
          clips.add(node.runtimeType.toString());
        }
        node = node.parent;
      }
      expect(node, same(tile), reason: '色块应在「最近添加」格子里');
      expect(clips, isEmpty, reason: '${block.widget.key} 外面有裁切层');
    }
  });

  // 用户 11-20：色块上已经印着作品名，悬停再弹一个同名 tooltip「太丑了」。
  // 带可见标题的首页色块（「继续」「最近添加」），从格子到块、块里面都不许有
  // tooltip；读屏标题仍在块的语义里。
  testWidgets('色块「继续」/「最近添加」：卡面已印标题，祖先与后代都没有 tooltip，语义仍带标题', (
    WidgetTester tester,
  ) async {
    dashboardLayout = ShellContentLayout.collage;
    useSize(tester, const Size(1280, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MediaItem> books = <MediaItem>[];
    for (int i = 1; i <= 6; i++) {
      final String key = '新书${_seriesFreeSuffix(i)}';
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/abs/$i.epub',
          extractDir: '/abs/$i',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      books.add(readingBook(key, key, position: 0));
    }
    await tester.pumpWidget(buildAppWithBooks(books, const <String, int>{}));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final SemanticsHandle semantics = tester.ensureSemantics();
    final Finder blocks = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          ((w.key! as ValueKey<String>).value.startsWith(
                'home-recent-block/',
              ) ||
              (w.key! as ValueKey<String>).value.startsWith(
                'home-continue-block/',
              )),
    );
    expect(blocks, findsAtLeastNWidgets(2));
    bool isTooltip(Widget w) => w is Tooltip || w is FushiTooltip;
    for (final Element block in blocks.evaluate()) {
      final Finder self = find.byElementPredicate((Element e) => e == block);
      final List<String> titles = find
          .descendant(of: self, matching: find.byType(Text))
          .evaluate()
          .map((Element e) => (e.widget as Text).data ?? '')
          .where((String s) => s.startsWith('新书'))
          .toList();
      expect(titles, isNotEmpty, reason: '${block.widget.key} 卡面上没有标题');
      expect(
        find.descendant(of: self, matching: find.byWidgetPredicate(isTooltip)),
        findsNothing,
        reason: '${block.widget.key} 里面还有 tooltip',
      );
      final List<String> above = <String>[];
      block.visitAncestorElements((Element e) {
        if (e.widget.key is ValueKey<String> &&
            (e.widget.key! as ValueKey<String>).value.startsWith(
              'home-widget',
            )) {
          return false;
        }
        if (isTooltip(e.widget)) above.add(e.widget.runtimeType.toString());
        return true;
      });
      expect(above, isEmpty, reason: '${block.widget.key} 外面包了 tooltip');
      expect(
        find.descendant(
          of: self,
          matching: find.bySemanticsLabel(RegExp(RegExp.escape(titles.first))),
        ),
        findsWidgets,
        reason: '${block.widget.key} 的语义里没有标题',
      );
    }
    semantics.dispose();
  });

  // 11-20 反馈 #11：首页「继续」色块对刮削过的作品画艺术字（与视频库系列卡同一个
  // fushiSeriesCoverBlock，元数据只为画出来的条目单查）。
  testWidgets('色块「继续」：合集刮削到 logo 时色块画 logo（反馈 #11）', (
    WidgetTester tester,
  ) async {
    dashboardLayout = ShellContentLayout.collage;
    useSize(tester, const Size(1280, 900));
    final File logo = File('${storeDir.path}/logo.png')
      ..writeAsBytesSync(_kLandscapePng);
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
    await db.replaceMediaImagesForCollection(cid, <MediaImagesCompanion>[
      MediaImagesCompanion.insert(
        collectionId: Value<int?>(cid),
        kind: MediaImageKind.logo.dbValue,
        path: logo.path,
      ),
    ]);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    final Finder block = find.byKey(
      const ValueKey<String>('home-continue-block/0'),
    );
    expect(block, findsOneWidget);
    final Finder logoTitle = find.descendant(
      of: block,
      matching: find.byType(FushiLogoTitle),
    );
    // 元数据是画到时后台单查（DB + 文件存在性），给真实事件循环几跳。
    for (int i = 0; i < 20 && logoTitle.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await settleCoverProbes(tester);
    expect(tester.takeException(), isNull);
    expect(logoTitle, findsOneWidget);
  });

  // 设计稿 H8：「最近添加」里同一合集新加的几卷合成一张卡，点开进合集详情页
  // （而不是只打开其中一卷）；不在合集里、仅按书名系列键归的组仍打开卷号最小的
  // 一卷（[recentBookGroupTarget] 纯函数测试）。
  testWidgets('双栏「最近添加」：同合集的系列合并卡点开 = 进该合集', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int cid = await db.createMediaCollection('某轻小说');
    final List<MediaItem> books = <MediaItem>[];
    for (int i = 1; i <= 3; i++) {
      final String key = '某轻小说 $i';
      final String uid = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/abs/v$i.epub',
          extractDir: '/abs/v$i',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      await db.addToCollection(cid, MediaKind.epub, uid);
      books.add(readingBook(key, key, position: 0));
    }
    final List<(int, bool)> opened = <(int, bool)>[];
    await tester.pumpWidget(
      buildAppWithBooks(
        books,
        const <String, int>{},
        openBookCollectionOverride: (int id, {required bool manga}) =>
            opened.add((id, manga)),
      ),
    );
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final List<({String title, String subtitle})> recent = recentRows(tester);
    expect(recent, hasLength(1), reason: '同合集三卷合成一张');
    expect(
      recent.single.subtitle,
      contains(t.home_widget_recent_volume_count(n: 3)),
    );
    // 直接调条目小行的点按回调（不用坐标点击）。
    tester
        .widget<InkWell>(
          find.byKey(const ValueKey<String>('home-recent-item/0')),
        )
        .onTap!();
    await tester.pump();
    expect(opened, <(int, bool)>[(cid, false)]);
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
          bookKey: '本地${_seriesFreeSuffix(i)}',
          title: '本地${_seriesFreeSuffix(i)}',
          epubPath: '/abs/local$i.epub',
          extractDir: '/abs/local$i',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - (10 - i) * 1000,
          localAddedAt: Value<int?>(now - (10 - i) * 1000),
        ),
      );
      books.add(
        readingBook(
          '本地${_seriesFreeSuffix(i)}',
          '本地${_seriesFreeSuffix(i)}',
          position: 0,
        ),
      );
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
    final List<String> titles = recentRows(
      tester,
    ).map((({String title, String subtitle}) r) => r.title).toList();
    expect(titles, hasLength(6));
    expect(titles.take(2).toSet(), <String>{
      '对端旧书',
      '对端旧视频',
    }, reason: '按 importedAt 排它们会沉到最后');
    expect(titles.skip(2), <String>['本地D', '本地C', '本地B', '本地A']);
  });

  testWidgets('「最近添加」不在窄网格默认模板里；窄网格「继续」2×2 只放主卡，2×3 才挂横滑行', (
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
    final Widget app = buildAppWithBooks(
      <MediaItem>[
        readingBook('新书A', '新书A', position: 0),
        readingBook('在读书', '在读书', position: 40),
        readingBook('在读书2', '在读书2', position: 20),
      ],
      const <String, int>{'在读书': 2, '在读书2': 1},
    );
    await tester.pumpWidget(app);
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(gridKind(tester), HomeGridKind.compact);
    expect(find.byKey(recentCardKey), findsNothing);
    expect(find.text('新书A'), findsNothing);
    // 默认 2×2：两本在读，只画主卡（最近读的），不挂横滑行。
    expect(heroView(tester).title, '在读书');
    expect(
      find.byKey(const ValueKey<String>('home-continue-row')),
      findsNothing,
    );

    // 换成 2×3：主卡在上、其余条目横滑在下（条目小行），收在格子里。
    await storeCompactContinueTall();
    await tester.pumpWidget(app);
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    expect(heroView(tester).title, '在读书');
    expect(miniRowItems(), findsOneWidget);
    final Rect cell = tester.getRect(find.byKey(continueCardKey));
    final Rect hero0 = tester.getRect(heroCard());
    final Rect row = tester.getRect(
      find.byKey(const ValueKey<String>('home-continue-row')),
    );
    expect(row.top, greaterThanOrEqualTo(hero0.bottom));
    expect(row.bottom, lessThanOrEqualTo(cell.bottom + 0.5));
    expect(
      tester.getRect(miniRowItems()).bottom,
      lessThanOrEqualTo(row.bottom + 0.5),
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
    testWidgets('精简 · $width 宽手机：学习统计（「今日」2×1）完整显示，不省略号截断、不溢出', (
      WidgetTester tester,
    ) async {
      useSize(tester, Size(width, 800));
      await appModel.setReadingGoalDailyChars(30000);
      // 窄网格里学习头部行挂在「今日」2×1（满宽一行高）。
      await storeHomeLayout(
        compact: const <HomeWidgetItem>[
          HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
          HomeWidgetItem(HomeWidgetKind.continueHero, HomeWidgetSize(2, 2)),
        ],
      );
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
      // 横滑行挂在窄网格「继续」2×3。
      await storeCompactContinueTall();
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
      expect(miniRowItems(), findsNWidgets(2));
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

    // 窄网格横滑行挂在「继续」2×3（默认 2×2 只放主卡）。
    await storeCompactContinueTall();
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
    // 不再是「封面 + 信息列」卡里塞一个横槽。小组件网格里按格子高定宽，整卡
    // （含底部片名 / 进度叠层）收在「继续」格子里。
    expect(hero(), findsNothing);
    final Size card = tester.getSize(heroCard());
    expect(card.width / card.height, closeTo(16 / 9, 0.01));
    final Rect cell = tester.getRect(find.byKey(continueCardKey));
    expect(
      tester.getRect(heroCard()).bottom,
      lessThanOrEqualTo(cell.bottom + 0.5),
    );
    expect(
      tester.getRect(heroCard()).right,
      lessThanOrEqualTo(cell.right + 0.5),
    );
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
    // 横滑行挂在窄网格「继续」2×3。
    await storeCompactContinueTall();
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
    // 主角卡进度 = 30%；合集进主卡下面的条目小行，副行 = 集数。
    expect(heroView(tester).progressLabel, '30%');
    expect(miniRowItems(), findsOneWidget);
    // 集数不压在封面上，在小行的副行里：副行在小行宽内、单行不被省略号截断。
    expect(
      find.descendant(of: miniRowItems(), matching: find.byType(CoverBadge)),
      findsNothing,
    );
    final Rect card = tester.getRect(miniRowItems());
    final Finder episode = find.descendant(
      of: miniRowItems(),
      matching: find.text(t.home_continue_episode(n: 12)),
    );
    expect(episode, findsOneWidget);
    expect(find.text(t.home_continue_episode(n: 12)), findsOneWidget);
    final Rect episodeRect = tester.getRect(episode);
    expect(episodeRect.left, greaterThanOrEqualTo(card.left));
    expect(episodeRect.right, lessThanOrEqualTo(card.right));
    expect(episodeRect.bottom, lessThanOrEqualTo(card.bottom));
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
    // 窄网格默认「今日」1×1：今日字数大字（0），整块点按设目标（`home-goal-row`）。
    expect(find.byKey(studyCardKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(studyCardKey),
        matching: semanticsLabeled(formatStatChars(0)),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('home-goal-row')), findsOneWidget);
    // 空库也照样挂分区标题，空态说明落在「继续」卡里。
    expect(sectionTitle(studyCardKey, t.stat_today), findsOneWidget);
    expect(sectionTitle(continueCardKey, t.home_continue), findsOneWidget);
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
    // 骨架期间分区标题已在位（数据到达后不跳版）；「最近添加」格子在位但不出
    // 骨架、也不先闪「还没有」空态（首载完成前是空白）。
    expect(sectionTitle(studyCardKey, t.stat_today), findsOneWidget);
    expect(sectionTitle(continueCardKey, t.home_continue), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(recentCardKey),
        matching: find.byType(HomeContinueRowSkeleton),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-recent-list')),
      findsNothing,
    );
    expect(find.text(t.home_widget_recent_empty), findsNothing);

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
            theme: shellTheme(),
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

  testWidgets('色块「今日」宽格设了目标：目标与今日时长同一行都显示（时长不被目标挤掉）', (
    WidgetTester tester,
  ) async {
    dashboardLayout = ShellContentLayout.collage;
    useSize(tester, const Size(1280, 900));
    await appModel.setReadingGoalDailyChars(1000);
    // 今天读 800 字 / 10 分钟（seedSampleData）。
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final Finder goal = find.descendant(
      of: find.byKey(studyCardKey),
      // 副行只写目标（设计稿 11-20 #12：不再重复大字已写的今日字数）。
      matching: find.text(t.home_today_goal_target(goal: '1000')),
    );
    expect(
      find.descendant(
        of: find.byKey(studyCardKey),
        matching: find.text(t.stat_goal_progress(read: 800, goal: 1000)),
      ),
      findsNothing,
    );
    final Finder time = find.descendant(
      of: find.byKey(const ValueKey<String>('home-today-time')),
      matching: find.text(formatStatTime(600000)),
    );
    expect(goal, findsOneWidget);
    expect(time, findsOneWidget);
    final RenderParagraph timeText = tester.renderObject<RenderParagraph>(time);
    expect(timeText.didExceedMaxLines, isFalse);
    final Rect g = tester.getRect(goal);
    final Rect tm = tester.getRect(time);
    expect((g.center.dy - tm.center.dy).abs(), lessThan(4));
    expect(tm.left, greaterThan(g.right));
  });

  /// 等目标面板（自适应底部面板）开 / 关的动画与它的异步数据加载。
  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pump();
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  StudyGoal goalRecord(
    String id,
    StudyGoalId metric,
    int target, {
    StudyGoalPeriod period = StudyGoalPeriod.daily,
    String? language,
  }) => StudyGoal(
    id: id,
    metric: metric,
    period: period,
    target: target,
    language: language,
  );

  /// 「数值 / 目标」的紧凑写法（与首页 / 小组件 / 设置行同一个格式化，随界面语言）。
  String pairText(int value, int target, {bool time = false}) {
    final ({String value, String target}) p = studyGoalCompactPair(
      value,
      target,
      isTime: time,
    );
    return '${p.value} / ${p.target}';
  }

  /// 今天不在其中的一个生效日（让每日目标今天是休息日）。
  Set<int> notToday() => <int>{DateTime.now().weekday % 7 + 1};

  Finder checkIn(Finder root) => find.descendant(
    of: root,
    matching: find.byWidgetPredicate(
      (Widget w) => w is FushiIcon && w.icon == FushiIcons.check,
    ),
  );

  testWidgets('今日格总览版式：列出全部目标（混了每周目标时标题是「目标」），完成 / 超出带对勾、休息日写明', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('t', StudyGoalId.total, 20),
      goalRecord('c', StudyGoalId.chars, 500),
      goalRecord('m', StudyGoalId.mined, 5),
      StudyGoal(
        id: 'r',
        metric: StudyGoalId.watching,
        period: StudyGoalPeriod.daily,
        target: 30,
        activeWeekdays: notToday(),
      ),
      goalRecord('w', StudyGoalId.chars, 5000, period: StudyGoalPeriod.weekly),
    ]);
    await appModel.setHomeTodayLayout(StudyGoalTodayLayout.overview);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 3)),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    final Finder card = find.byKey(const ValueKey<String>('home-study-card'));
    // 有一条每周目标 → 标题「目标」，不是「今日目标」。
    expect(
      find.descendant(
        of: card,
        matching: find.text(t.home_language_goals_mixed_title),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text(t.home_today_goals_title)),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-pager')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-today-overview')),
      findsOneWidget,
    );
    // 每日 + 每周都在（总览不按「左右滑动」只取每日），列表顺序。
    final List<double> tops = <double>[
      for (final String id in <String>['t', 'c', 'm', 'r', 'w'])
        tester
            .getTopLeft(
              find.byKey(ValueKey<String>('home-today-overview-row-$id')),
            )
            .dy,
    ];
    expect(tops, orderedEquals(<double>[...tops]..sort()));
    expect(
      find.byKey(const ValueKey<String>('home-today-overview-more')),
      findsNothing,
    );
    String label(String id) => tester
        .widget<Semantics>(
          find.byKey(ValueKey<String>('home-today-overview-row-$id')),
        )
        .properties
        .label!;
    // 进行中：10 / 20 分钟，还差 10 分钟（紧凑数值对 + 状态）。
    expect(label('t'), contains(pairText(600000, 1200000, time: true)));
    expect(
      label('t'),
      contains(
        t.study_goal_status_left(
          amount: formatStudyGoalDuration(600000, roundUp: true),
        ),
      ),
    );
    // 超出：800 / 500，「+300」，行里一个对勾。
    expect(label('c'), contains(pairText(800, 500)));
    expect(label('c'), contains('+300'));
    expect(
      checkIn(find.byKey(const ValueKey<String>('home-today-overview-row-c'))),
      findsOneWidget,
    );
    expect(
      checkIn(find.byKey(const ValueKey<String>('home-today-overview-row-t'))),
      findsNothing,
    );
    // 休息日：写「休息日」，不是失败。
    expect(label('r'), contains(t.study_goal_status_rest_day));
    // 带进度条（格子够高）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-today-overview')),
        matching: find.byType(StudyGoalProgressBar),
      ),
      findsNWidgets(5),
    );
  });

  testWidgets('今日格总览版式：格子矮时只列放得下的几条 + 「还有 N 个」', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      for (int i = 0; i < 6; i++)
        goalRecord('g$i', StudyGoalId.total, 20 + i * 10),
    ]);
    await appModel.setHomeTodayLayout(StudyGoalTodayLayout.overview);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    int rows = 0;
    for (int i = 0; i < 6; i++) {
      if (find
          .byKey(ValueKey<String>('home-today-overview-row-g$i'))
          .evaluate()
          .isNotEmpty) {
        rows++;
      }
    }
    expect(rows, inInclusiveRange(1, 5));
    // 前几条按顺序画，没画的数写在末行。
    expect(
      find.byKey(const ValueKey<String>('home-today-overview-row-g0')),
      findsOneWidget,
    );
    final Finder more = find.byKey(
      const ValueKey<String>('home-today-overview-more'),
    );
    expect(more, findsOneWidget);
    expect(
      tester.widget<Text>(more).data,
      t.widget_label_goals_more(n: 6 - rows),
    );
    // 行与「还有 N 个」都在格子里（不溢出）。
    final Rect cardRect = tester.getRect(
      find.byKey(const ValueKey<String>('home-study-card')),
    );
    expect(tester.getRect(more).bottom, lessThanOrEqualTo(cardRect.bottom));
  });

  testWidgets('今日格聚焦版式：标题行「语言 · 度量」、大字「数值 / 目标」、状态行；达成画对勾', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('c', StudyGoalId.chars, 500),
      goalRecord('t', StudyGoalId.total, 20),
    ]);
    await appModel.setHomeTodayMainGoal('c');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 2)),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    final Finder page = find.byKey(const ValueKey<String>('home-today-goal-c'));
    expect(page, findsOneWidget);
    expect(
      tester.widget<Text>(
        find.byKey(const ValueKey<String>('home-today-goal-status')),
      ),
      isA<Text>().having((Text w) => w.data, 'status', '+300'),
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('home-today-goal-title')),
          )
          .data,
      '${studyGoalLanguageLabel(null)} · ${t.widget_goal_chars}',
    );
    // 环是共用的目标环，超出 → 对勾、只画满一圈。
    final Finder ring = find.descendant(
      of: page,
      matching: find.byType(StudyGoalRing),
    );
    expect(ring, findsOneWidget);
    expect(tester.widget<StudyGoalRing>(ring).state, StudyGoalState.exceeded);
    expect(checkIn(ring), findsOneWidget);
    // 其余目标的小行：同一种行，写紧凑数值对。
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey<String>('home-today-goal-row-t')),
          )
          .properties
          .label,
      contains(pairText(600000, 1200000, time: true)),
    );
  });

  testWidgets('「语言目标」格：日 / 周 / 月三环度量不同时环下带度量名；达成的环画对勾', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await prefs.setDefaultContentLanguage('ja');
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('jd', StudyGoalId.chars, 500, language: 'ja'),
      goalRecord(
        'jw',
        StudyGoalId.watching,
        180,
        period: StudyGoalPeriod.weekly,
        language: 'ja',
      ),
    ]);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(3, 2),
          language: 'ja',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    final Finder ja = find.byKey(
      const ValueKey<String>('home-language-goals-card/ja'),
    );
    Finder slot(String key) => find.descendant(
      of: ja,
      matching: find.byKey(ValueKey<String>('home-language-goals-ring-$key')),
    );
    expect(
      find.descendant(
        of: slot('daily'),
        matching: find.text(
          '${t.study_goal_metric_short_chars} · ${t.study_goal_period_abbr_daily}',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: slot('weekly'),
        matching: find.textContaining(t.study_goal_period_abbr_weekly),
      ),
      findsOneWidget,
    );
    // 每日字数 800 / 500：超出 → 环心对勾；每周观看没做完 → 没有对勾。
    expect(checkIn(slot('daily')), findsOneWidget);
    expect(checkIn(slot('weekly')), findsNothing);
    // 每个环下面写自己的紧凑数值对（不再有一条只写第一条目标的底行）。
    expect(
      find.descendant(
        of: slot('daily'),
        matching: find.text(pairText(800, 500)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: ja,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-line'),
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('新装：没有任何目标（和改版前一样），今日格是经典外观、字数 + 设定入口', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    expect(appModel.studyGoals, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-pager')),
      findsNothing,
    );
    expect(find.text(formatStatChars(800)), findsOneWidget);
    expect(find.text(t.stat_goal_set), findsOneWidget);
  });

  testWidgets('今日目标：删光目标只显示设定入口；目标面板设 1000 后进度行 = 800/1000', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    // 删光目标 = 写入空表：与新装同一个空状态。
    await appModel.setStudyGoals(const <StudyGoal>[]);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(find.text(t.stat_goal_set), findsOneWidget);
    expect(
      tester.widget<HomeGoalRing>(find.byType(HomeGoalRing)).fraction,
      isNull,
    );

    await tester.tap(find.text(t.stat_goal_set));
    await pumpSheet(tester);
    // 新建预填：字数 · 每日 · 全部语言。
    expect(
      find.byKey(const ValueKey<String>('study-goal-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('study-goal-delete')),
      findsNothing,
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('study-goal-target-field')),
        matching: find.byType(EditableText),
      ),
      '1000',
    );
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('study-goal-save')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('study-goal-save')));
    await pumpSheet(tester);

    expect(tester.takeException(), isNull);
    final StudyGoal saved = appModel.studyGoals.single;
    expect(saved.metric, StudyGoalId.chars);
    expect(saved.period, StudyGoalPeriod.daily);
    expect(saved.language, isNull);
    expect(saved.target, 1000);
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

  testWidgets('今日格目标翻页：从主目标那页开始，其余目标列在下面；点圆点切页并记成主目标', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('t', StudyGoalId.total, 20),
      goalRecord('m', StudyGoalId.mined, 5),
      goalRecord('c', StudyGoalId.chars, 1000),
    ]);
    await appModel.setHomeTodayMainGoal('t');
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    Finder page(String id) =>
        find.byKey(ValueKey<String>('home-today-goal-$id'));
    // 页序 = 记录顺序（t, m, c）；起始页 = 主目标 t。
    expect(page('t'), findsOneWidget);
    // 今天读了 10 分钟（seedSampleData），目标 20 分钟。
    expect(
      tester.widget<Semantics>(page('t')).properties.label,
      contains(pairText(600000, 1200000, time: true)),
    );
    // 旧的「设定目标」入口不再出现。
    expect(find.text(t.stat_goal_set), findsNothing);
    // 三个目标 → 三个圆点。
    for (int i = 0; i < 3; i++) {
      expect(
        find.byKey(ValueKey<String>('home-today-goal-dot-$i')),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('home-today-goal-dot-1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(page('m'), findsOneWidget);
    expect(
      tester.widget<Semantics>(page('m')).properties.label,
      contains('0 / 5'),
    );
    expect(appModel.homeTodayMainGoal, 'm');
  });

  testWidgets('今日格「左右滑动」：缺省只翻每日目标，选「全部目标」后周目标也进来', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('d', StudyGoalId.total, 20),
      goalRecord('w', StudyGoalId.chars, 5000, period: StudyGoalPeriod.weekly),
    ]);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-d')),
      findsOneWidget,
    );
    // 只有一个每日目标：没有圆点，周目标不出现。
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-dot-0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-row-w')),
      findsNothing,
    );

    await appModel.setHomeTodaySwipeGoals(StudyGoalSwipeScope.all);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-dot-1')),
      findsOneWidget,
    );
  });

  testWidgets('HBK-AUDIT-021 今日格：「左右滑动」缺省每日时选了周主目标，主目标照样显示、与每日目标共存', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('d', StudyGoalId.total, 20),
      goalRecord('w', StudyGoalId.chars, 5000, period: StudyGoalPeriod.weekly),
      goalRecord(
        'm',
        StudyGoalId.chars,
        20000,
        period: StudyGoalPeriod.monthly,
      ),
    ]);
    await appModel.setHomeTodayMainGoal('w');
    expect(appModel.homeTodaySwipeGoals, StudyGoalSwipeScope.daily);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    Finder page(String id) =>
        find.byKey(ValueKey<String>('home-today-goal-$id'));
    // 起始页是用户选的周主目标，不是第一条每日目标。
    expect(page('w'), findsOneWidget);
    expect(page('d'), findsNothing);
    // 页 = 每日目标 d + 主目标 w（记录顺序）；没选作主目标的月目标不进来。
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-dot-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-dot-2')),
      findsNothing,
    );

    // 翻回每日目标那页：每日目标照常可翻到。
    await tester.tap(
      find.byKey(const ValueKey<String>('home-today-goal-dot-0')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(page('d'), findsOneWidget);
    expect(appModel.homeTodayMainGoal, 'd');
  });

  testWidgets('今日格目标翻页：点按格子进「目标」设置子页', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('r', StudyGoalId.reading, 20),
    ]);
    await appModel.setHomeTodayMainGoal('r');
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final Finder reading = find.byKey(
      const ValueKey<String>('home-today-goal-r'),
    );
    expect(reading, findsOneWidget);
    // 只有一个目标：不画圆点。
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-dot-0')),
      findsNothing,
    );
    await tester.tap(reading);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(t.settings_study_goals_title), findsWidgets);
    expect(find.text(t.settings_study_goals_section_today), findsWidgets);
    // 目标列表里有这条记录。
    expect(
      find.byKey(const ValueKey<String>('study-goal-row-r')),
      findsOneWidget,
    );
  });

  /// 今日格近 7 天柱条的读屏文案（卡片风格 = [HomeWeekBars]；色块风格 = 带键的
  /// Semantics），两种风格同一份数据。
  String todayBarsLabel(WidgetTester tester) {
    final Finder card = find.descendant(
      of: find.byKey(const ValueKey<String>('home-today-week')),
      matching: find.byType(HomeWeekBars),
    );
    if (card.evaluate().isNotEmpty) {
      return tester.widget<HomeWeekBars>(card).semanticLabel;
    }
    return tester
            .widget<Semantics>(
              find.byKey(const ValueKey<String>('home-today-week-bars')),
            )
            .properties
            .label ??
        '';
  }

  testWidgets('今日格柱条跟随当前目标：时长目标按分钟、切到字数目标按字数，参考线 = 每日份额', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    // 与真实 app 一样：偏好变更转发成 AppModel 通知（首页 ref.watch 靠它重建）。
    appModel.forwardPreferenceChangesForTesting();
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('t', StudyGoalId.total, 20),
      goalRecord('c', StudyGoalId.chars, 1000),
    ]);
    await appModel.setHomeTodayMainGoal('t');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 2)),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    // 时长目标页：今天 10 分钟（seedSampleData），柱条按时长写。
    final String timeLabel = todayBarsLabel(tester);
    expect(timeLabel, contains(formatStatTime(600000)));
    final Finder cardBars = find.descendant(
      of: find.byKey(const ValueKey<String>('home-today-week')),
      matching: find.byType(HomeWeekBars),
    );
    if (cardBars.evaluate().isNotEmpty) {
      final HomeWeekBars bars = tester.widget<HomeWeekBars>(cardBars);
      expect(bars.values.last, 600000);
      // 每日 20 分钟目标 → 参考线 20 分钟。
      expect(bars.reference, 1200000);
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('home-today-goal-dot-1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(appModel.homeTodayMainGoal, 'c');
    // 主目标写穿偏好（真 DB isolate）后才通知：真实事件循环里等写完，再走一帧
    // 让首页按新主目标重建。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final String charsLabel = todayBarsLabel(tester);
    expect(charsLabel, isNot(timeLabel));
    expect(charsLabel, contains(formatStatCharsAxis(800)));
    expect(charsLabel, isNot(contains(formatStatTime(600000))));
    if (cardBars.evaluate().isNotEmpty) {
      final HomeWeekBars bars = tester.widget<HomeWeekBars>(cardBars);
      expect(bars.values.last, 800);
      expect(bars.reference, 1000);
    }
  });

  testWidgets('今日格周目标（设计 A + B）：双环、大字是今天的份额、小字是本周一行；柱条是本周生效日 + 份额', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('w', StudyGoalId.chars, 5000, period: StudyGoalPeriod.weekly),
    ]);
    await appModel.setHomeTodayMainGoal('w');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 2)),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    final Finder card = find.byKey(const ValueKey<String>('home-study-card'));
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('home-today-goal-dual-ring'),
        ),
      ),
      findsOneWidget,
    );
    // 本周此前没有量：今天的份额 = 5000 摊给今天起剩下的天数；今天做了 800。
    final String today = FushiTimeFormat.dayKey(DateTime.now());
    final int daysLeft = studyGoalWindowDays(
      StudyGoalPeriod.weekly,
      today,
    ).where((String k) => k.compareTo(today) >= 0).length;
    final int share = (5000 + daysLeft - 1) ~/ daysLeft;
    final Text status = tester.widget<Text>(
      find.byKey(const ValueKey<String>('home-today-goal-status')),
    );
    expect(
      status.data,
      startsWith(t.study_goal_period_week_pair(pair: pairText(800, 5000))),
    );
    final Finder figure = find.descendant(
      of: card,
      matching: find.byType(HomeWidgetFigure),
    );
    final HomeWidgetFigure big = tester.widget<HomeWidgetFigure>(figure.first);
    final ({String value, String target}) todayPair = studyGoalCompactPair(
      800,
      share,
      isTime: false,
    );
    expect(big.value, todayPair.value);
    expect(big.unit, '/ ${todayPair.target} ${t.study_goal_today_word}');
    // 柱条换成本周生效日（7 格，今天那格有柱），不是近 7 天柱条。
    final Finder strip = find.byKey(
      const ValueKey<String>('home-today-day-strip'),
    );
    expect(strip, findsOneWidget);
    expect(find.byType(HomeWeekBars), findsNothing);
    final StudyGoalDayStrip w = tester.widget<StudyGoalDayStrip>(strip);
    expect(w.days, hasLength(7));
    final StudyGoalDay todayCell = w.days.singleWhere(
      (StudyGoalDay d) => d.isToday,
    );
    expect(todayCell.value, 800);
    expect(todayCell.share, share);
  });

  testWidgets('小格里的周目标：只画今天一圈；一行高的语言目标格大字写「x / y 今天」、小字是度量 + 进度', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord(
        'w',
        StudyGoalId.chars,
        5000,
        period: StudyGoalPeriod.weekly,
        language: 'ja',
      ),
    ]);
    await appModel.setHomeTodayMainGoal('w');
    await prefs.setDefaultContentLanguage('ja');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 1),
          language: 'ja',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    // 一行高的「今日」格：环小于双环下限，只剩今天那一圈。
    final Finder card = find.byKey(const ValueKey<String>('home-study-card'));
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('home-today-goal-today-ring'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(
          const ValueKey<String>('home-today-goal-dual-ring'),
        ),
      ),
      findsNothing,
    );

    // 语言目标格：大字「800 / 份额」+ 单位「今天」；小字不再重复「今天」。
    final Finder entry = find.byKey(
      const ValueKey<String>('home-language-goals-compact/w'),
    );
    final HomeWidgetFigure big = tester.widget<HomeWidgetFigure>(
      find.descendant(of: entry, matching: find.byType(HomeWidgetFigure)),
    );
    expect(big.unit, t.study_goal_today_word);
    final Iterable<String> lines = tester
        .widgetList<Text>(
          find.descendant(of: entry, matching: find.byType(Text)),
        )
        .map((Text w) => w.data ?? '');
    expect(
      lines.where((String l) => l.contains(' · ${t.study_goal_today_word} · ')),
      isEmpty,
    );
  });

  testWidgets('今日格周目标今天休息：内环淡下去写「休息日」，大字回到本周数值', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      StudyGoal(
        id: 'w',
        metric: StudyGoalId.chars,
        period: StudyGoalPeriod.weekly,
        target: 5000,
        activeWeekdays: notToday(),
      ),
    ]);
    await appModel.setHomeTodayMainGoal('w');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(3, 2)),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    final Text status = tester.widget<Text>(
      find.byKey(const ValueKey<String>('home-today-goal-status')),
    );
    expect(status.data, startsWith(t.study_goal_status_rest_day));
    final HomeWidgetFigure big = tester.widget<HomeWidgetFigure>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('home-study-card')),
            matching: find.byType(HomeWidgetFigure),
          )
          .first,
    );
    expect('${big.value} ${big.unit}', pairText(800, 5000));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-today-goal-dual-ring')),
        matching: find.byWidgetPredicate(
          (Widget w) => w is FushiIcon && w.icon == FushiIcons.darkMode,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('今日格翻页跟主目标走：设置里改主目标 / 删掉前面的目标后首页立刻跟上', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    // 与真实 app 一样：偏好变更转发成 AppModel 通知（首页 ref.watch 靠它重建）。
    appModel.forwardPreferenceChangesForTesting();
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('t', StudyGoalId.total, 20),
      goalRecord('m', StudyGoalId.mined, 5),
      goalRecord('c', StudyGoalId.chars, 1000),
    ]);
    await appModel.setHomeTodayMainGoal('t');
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    Finder page(String id) =>
        find.byKey(ValueKey<String>('home-today-goal-$id'));
    expect(page('t'), findsOneWidget);

    // 别处（设置页）改主目标：不重开首页，翻页直接跳过去。
    await appModel.setHomeTodayMainGoal('c');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(page('c'), findsOneWidget);
    expect(page('t'), findsNothing);

    // 删掉排在前面的目标：页号变了，显示的仍是同一条主目标。
    await appModel.removeStudyGoal('t');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(page('c'), findsOneWidget);
    expect(appModel.homeTodayMainGoal, 'c');
  });

  testWidgets('设置「你的目标」：删除立即生效，提示条「撤销」把目标放回原位', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    // 与真实 app 一样：偏好变更转发成 AppModel 通知（首页 ref.watch 靠它重建）。
    appModel.forwardPreferenceChangesForTesting();
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('t', StudyGoalId.total, 20),
      goalRecord('m', StudyGoalId.mined, 5),
      goalRecord('c', StudyGoalId.chars, 1000),
    ]);
    await appModel.setHomeTodayMainGoal('t');
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    await tester.tap(find.byKey(const ValueKey<String>('home-today-goal-t')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final Finder row = find.byKey(const ValueKey<String>('study-goal-row-m'));
    expect(row, findsOneWidget);
    // 行首是进度环（字数目标也有）。
    expect(
      find.byKey(const ValueKey<String>('study-goal-row-ring-c')),
      findsOneWidget,
    );

    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await pumpSheet(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('study-goal-delete')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('study-goal-delete')));
    await pumpSheet(tester);

    expect(tester.takeException(), isNull);
    expect(appModel.studyGoals.map((StudyGoal g) => g.id), <String>['t', 'c']);
    expect(
      find.byKey(const ValueKey<String>('study-goal-row-m')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('study-goal-deleted-snackbar')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('study-goal-undo-delete')),
    );
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    expect(appModel.studyGoals.map((StudyGoal g) => g.id), <String>[
      't',
      'm',
      'c',
    ]);
    expect(
      find.byKey(const ValueKey<String>('study-goal-row-m')),
      findsOneWidget,
    );
  });

  testWidgets('复习目标在首页不出现时：设置行与目标面板写明原因', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    appModel.forwardPreferenceChangesForTesting();
    await seedSampleData();
    await appModel.setSrsMiningTarget(SrsMiningTarget.anki);
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('t', StudyGoalId.total, 20),
      goalRecord('r', StudyGoalId.reviews, 50),
    ]);
    // 挖词目标是 Anki（测试环境里复习模块是否开着都一样：复习数给不出）。
    final StudyGoalReviewsHidden? reason = appModel.studyGoalReviewsHidden;
    expect(reason, isNotNull);
    final String note = studyGoalReviewsHiddenNote(reason!);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    // 首页没有复习那页（复习数给不出）。
    expect(
      find.byKey(const ValueKey<String>('home-today-goal-r')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('home-today-goal-t')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final Finder row = find.byKey(const ValueKey<String>('study-goal-row-r'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.textContaining(note)),
      findsOneWidget,
    );
    // 别的目标行没有这句。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('study-goal-row-t')),
        matching: find.textContaining(note),
      ),
      findsNothing,
    );

    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await pumpSheet(tester);
    expect(
      find.byKey(const ValueKey<String>('study-goal-reviews-hidden')),
      findsOneWidget,
    );
    // 换成别的度量，说明消失。
    await tester.tap(
      find.byKey(const ValueKey<String>('study-goal-metric-chars')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('study-goal-reviews-hidden')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  test('复习目标隐藏原因：复习模块关着优先，其次卡发往 Anki', () {
    expect(
      studyGoalReviewsHiddenFor(srsModuleEnabled: false, miningToAnki: false),
      StudyGoalReviewsHidden.srsModuleOff,
    );
    expect(
      studyGoalReviewsHiddenFor(srsModuleEnabled: false, miningToAnki: true),
      StudyGoalReviewsHidden.srsModuleOff,
    );
    expect(
      studyGoalReviewsHiddenFor(srsModuleEnabled: true, miningToAnki: true),
      StudyGoalReviewsHidden.cardsGoToAnki,
    );
    expect(
      studyGoalReviewsHiddenFor(srsModuleEnabled: true, miningToAnki: false),
      isNull,
    );
  });

  testWidgets('阅读统计页：点「今天」的字数目标环打开目标面板（编辑那条字数目标）', (WidgetTester tester) async {
    // 高窗口：趋势栏（含「分析」折叠区）整列都建出来。
    useSize(tester, const Size(1280, 3200));
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('c', StudyGoalId.chars, 1000),
    ]);
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    unawaited(
      Navigator.of(tester.element(find.byType(HomeDashboardPage))).push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => const ReadingStatisticsPage(),
        ),
      ),
    );
    await pumpSheet(tester);
    // 统计页经 DB isolate 载入：真实事件循环里等到「分析」折叠头出现。
    final Finder fold = find.text(t.stat_analysis);
    for (int i = 0; i < 30 && fold.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 「今天」面板在「分析」折叠区里，先展开。
    await tester.ensureVisible(fold);
    await tester.pump();
    await tester.tap(fold);
    await pumpSheet(tester);
    final Finder ring = find.byKey(
      const ValueKey<String>('reading-stats-goal-ring'),
    );
    await tester.ensureVisible(ring);
    await tester.pump();
    await tester.tap(ring);
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('study-goal-save')),
      findsOneWidget,
    );
    // 编辑已有的字数目标（有删除按钮），不是新建。
    expect(
      find.byKey(const ValueKey<String>('study-goal-delete')),
      findsOneWidget,
    );
  });

  testWidgets('目标面板：切「每周」→ 预设换成周量级，保存后今日格按本自然周字数显示', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    // 从没有目标开始（删光过）：经典外观的「设定目标」入口。
    await appModel.setStudyGoals(const <StudyGoal>[]);
    // 本周一（若今天不是周一）再读 500 字：周目标分子要把它算进去，日目标不算。
    final StatWindow w = StatWindow(DateTime.now());
    final int weekChars = w.weekFromKey == w.todayKey ? 800 : 800 + 500;
    if (w.weekFromKey != w.todayKey) {
      await seedLegacyReading(
        title: '吾輩は猫である',
        dateKey: w.weekFromKey,
        charsRead: 500,
        timeMs: 300000,
      );
    }
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    await tester.tap(find.text(t.stat_goal_set));
    await pumpSheet(tester);
    // 近 7 天日均提示（今天读了字）。
    expect(
      find.byKey(const ValueKey<String>('study-goal-recent')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('study-goal-period-weekly')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final Finder presets = find.byKey(
      const ValueKey<String>('study-goal-presets'),
    );
    expect(
      tester
          .widget<FushiConnectedButtonGroup<int>>(presets)
          .segments
          .map((ButtonSegment<int> s) => s.value),
      <int>[20000, 35000, 70000, 140000],
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('study-goal-target-field')),
        matching: find.byType(EditableText),
      ),
      '2000',
    );
    await tester.pump();
    expect(
      tester.widget<FushiConnectedButtonGroup<int>>(presets).selected,
      isEmpty,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('study-goal-save')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('study-goal-save')));
    await pumpSheet(tester);

    expect(tester.takeException(), isNull);
    final StudyGoal saved = appModel.studyGoals.single;
    expect(saved.period, StudyGoalPeriod.weekly);
    expect(saved.target, 2000);
    // 周目标不是经典外观 → 今日格换成目标页，进度按本周字数。
    final Finder page = find.byKey(
      ValueKey<String>('home-today-goal-${saved.id}'),
    );
    expect(page, findsOneWidget);
    expect(
      tester.widget<Semantics>(page).properties.label,
      contains(pairText(weekChars, 2000)),
    );
  });

  testWidgets('「语言目标」格：按记录顺序画该语言的目标环；没有该语言目标时是添加空态', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await prefs.setDefaultContentLanguage('ja');
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord(
        'jw',
        StudyGoalId.chars,
        5000,
        period: StudyGoalPeriod.weekly,
        language: 'ja',
      ),
      goalRecord('jd', StudyGoalId.chars, 1000, language: 'ja'),
      goalRecord('all', StudyGoalId.total, 30),
    ]);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'ja',
        ),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'ko',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    final Finder ja = find.byKey(
      const ValueKey<String>('home-language-goals-card/ja'),
    );
    expect(ja, findsOneWidget);
    // 固定「日 / 周 / 月」三个槽，日在左；不限语言的时长目标不进日语格；
    // 没有月目标的槽画淡出的空环（读屏「月 · —」）。
    Finder slot(String period) => find.descendant(
      of: ja,
      matching: find.byKey(
        ValueKey<String>('home-language-goals-ring-$period'),
      ),
    );
    final Finder dayRing = slot('daily');
    final Finder weekRing = slot('weekly');
    expect(dayRing, findsOneWidget);
    expect(weekRing, findsOneWidget);
    expect(slot('monthly'), findsOneWidget);
    expect(
      tester.widget<Semantics>(slot('monthly')).properties.label,
      endsWith('—'),
    );
    expect(
      tester.widget<Semantics>(weekRing).properties.label,
      contains(pairText(800, 5000)),
    );
    // 每个有目标的环下面一行「x / y」；空周期没有。
    expect(
      find.descendant(
        of: ja,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-pair-daily'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: ja,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-pair-monthly'),
        ),
      ),
      findsNothing,
    );
    expect(
      tester.getCenter(dayRing).dx,
      lessThan(tester.getCenter(weekRing).dx),
    );
    // 今天读的 800 字按默认内容语言（日语）计入。
    expect(
      tester.widget<Semantics>(dayRing).properties.label,
      contains(pairText(800, 1000)),
    );

    final Finder ko = find.byKey(
      const ValueKey<String>('home-language-goals-card/ko'),
    );
    expect(
      find.descendant(
        of: ko,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-empty'),
        ),
      ),
      findsOneWidget,
    );
    // 空态点按：新建目标面板，预填韩语。
    await tester.tap(
      find.byKey(const ValueKey<String>('home-language-goals-open/ko')),
    );
    await pumpSheet(tester);
    expect(
      find.byKey(const ValueKey<String>('study-goal-save')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('study-goal-language-ko')),
      findsOneWidget,
    );
  });

  testWidgets('「语言目标」格：同一周期几条目标 → 一条一环、环下度量短名；跨周期带周期缩写', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await prefs.setDefaultContentLanguage('ja');
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      // 日语：两条每日 + 一条每周 + 一条每月（多于三条只画前三条）。
      goalRecord(
        'jm',
        StudyGoalId.chars,
        90000,
        period: StudyGoalPeriod.monthly,
        language: 'ja',
      ),
      goalRecord(
        'jw',
        StudyGoalId.chars,
        5000,
        period: StudyGoalPeriod.weekly,
        language: 'ja',
      ),
      goalRecord('jd', StudyGoalId.chars, 1000, language: 'ja'),
      goalRecord('jl', StudyGoalId.listening, 30, language: 'ja'),
      // 中文：两条每日（同一周期 → 只写度量短名）。
      goalRecord('zd', StudyGoalId.chars, 2000, language: 'zh'),
      goalRecord('zw', StudyGoalId.watching, 20, language: 'zh'),
    ]);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'ja',
        ),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'zh',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    Finder ring(String card, String key) => find.descendant(
      of: find.byKey(ValueKey<String>('home-language-goals-card/$card')),
      matching: find.byKey(ValueKey<String>('home-language-goals-ring-$key')),
    );
    Finder caption(String card, String text) => find.descendant(
      of: find.byKey(ValueKey<String>('home-language-goals-card/$card')),
      matching: find.text(text),
    );
    final String day = t.study_goal_period_abbr_daily;
    final String week = t.study_goal_period_abbr_weekly;

    // 日语：每日 → 每周，同周期按列表顺序；第四条（每月）不画；没有日 / 周 / 月三格。
    expect(ring('ja', 'jd'), findsOneWidget);
    expect(ring('ja', 'jl'), findsOneWidget);
    expect(ring('ja', 'jw'), findsOneWidget);
    expect(ring('ja', 'jm'), findsNothing);
    expect(ring('ja', 'daily'), findsNothing);
    expect(
      tester.getCenter(ring('ja', 'jd')).dx,
      lessThan(tester.getCenter(ring('ja', 'jl')).dx),
    );
    expect(
      tester.getCenter(ring('ja', 'jl')).dx,
      lessThan(tester.getCenter(ring('ja', 'jw')).dx),
    );
    expect(
      caption('ja', '${t.study_goal_metric_short_chars} · $day'),
      findsOneWidget,
    );
    expect(caption('ja', '${t.widget_label_listening} · $day'), findsOneWidget);
    expect(
      caption('ja', '${t.study_goal_metric_short_chars} · $week'),
      findsOneWidget,
    );

    // 中文：两条每日 → 两个环，只写度量短名。
    expect(ring('zh', 'zd'), findsOneWidget);
    expect(ring('zh', 'zw'), findsOneWidget);
    expect(caption('zh', t.study_goal_metric_short_chars), findsOneWidget);
    expect(caption('zh', t.widget_label_watching), findsOneWidget);
    expect(caption('zh', t.study_goal_period_short_daily), findsNothing);
  });

  testWidgets('「语言目标」格一行高：旧「今日」格的紧凑样子（一个环 + 数值，没有日 / 周 / 月）', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await prefs.setDefaultContentLanguage('ja');
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('jd', StudyGoalId.chars, 1000, language: 'ja'),
      goalRecord('jl', StudyGoalId.listening, 60, language: 'ja'),
      goalRecord('zd', StudyGoalId.chars, 2000, language: 'zh'),
      goalRecord(
        'zw',
        StudyGoalId.chars,
        5000,
        period: StudyGoalPeriod.weekly,
        language: 'zh',
      ),
    ]);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 1),
          language: 'ja',
        ),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'zh',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);

    // 矮的那格（一行高）：紧凑样子，第一条目标（每日字数 800 / 1000）。
    final Finder short = find.byKey(
      const ValueKey<String>('home-language-goals-card/ja'),
    );
    final Finder tall = find.byKey(
      const ValueKey<String>('home-language-goals-card/zh'),
    );
    expect(tester.getSize(short).height, lessThan(tester.getSize(tall).height));
    final Finder compact = find.descendant(
      of: short,
      matching: find.byKey(
        const ValueKey<String>('home-language-goals-compact'),
      ),
    );
    expect(compact, findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find.byKey(
              const ValueKey<String>('home-language-goals-compact/jd'),
            ),
          )
          .properties
          .label,
      contains(pairText(800, 1000)),
    );
    // 自动挑的目标也全部并排（用户 2026-11-20：一行高的格子只显示了第一条）。
    expect(
      find.descendant(
        of: short,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-compact/jl'),
        ),
      ),
      findsOneWidget,
    );
    // 整点时长目标写「1h」（紧凑数值对，与小组件同一个格式化），不写「1h 0m」。
    expect(
      find.descendant(
        of: short,
        matching: find.textContaining(
          formatStudyGoalDuration(60 * 60000 + 1),
          findRichText: true,
        ),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: short,
        matching: find.textContaining(
          '${t.stat_axis_hours(n: 1)} ${t.stat_axis_minutes(n: 0)}',
          findRichText: true,
        ),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: short,
        matching: find.textContaining(
          pairText(0, 60 * 60000, time: true),
          findRichText: true,
        ),
      ),
      findsWidgets,
    );
    // 看得出是哪个目标、离目标多远：「已完成 / 目标」+ 度量。
    expect(
      find.descendant(
        of: short,
        matching: find.text(
          '${t.study_goal_metric_short_chars} · ${t.stat_today}',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: short,
        matching: find.text(t.study_goal_period_short_daily),
      ),
      findsNothing,
    );
    // 两行高：照旧日 / 周 / 月三环。
    expect(
      find.descendant(
        of: tall,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-ring-daily'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tall,
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-compact'),
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('语言表：中文只有一项「中文」，简体 / 繁体是它下面的「只算」两项', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    // 默认内容语言 zh-TW → 候选取整门中文。
    await prefs.setDefaultContentLanguage('zh-TW');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'ja',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    await tester.longPress(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'ja'),
      ),
    );
    await pumpDashboard(tester);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('home-widget-configure/language_goals:ja'),
      ),
    );
    await pumpSheet(tester);
    Finder pick(String tag) =>
        find.byKey(ValueKey<String>('study-goal-language-pick-$tag'));
    expect(pick('zh'), findsOneWidget);
    expect(pick('zh-Hans'), findsOneWidget);
    expect(pick('zh-Hant'), findsOneWidget);
    expect(pick('zh-TW'), findsNothing);
    expect(
      tester.getTopLeft(pick('zh')).dy,
      lessThan(tester.getTopLeft(pick('zh-Hans')).dy),
    );
    expect(
      find.descendant(
        of: pick('zh-Hant'),
        matching: find.text(t.study_goal_language_script_only_hint),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: pick('zh'),
        matching: find.text(t.study_goal_language_script_only_hint),
      ),
      findsNothing,
    );
    // 改已有格子时多一项「挑选目标…」。
    expect(pick('goals'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「语言目标」格挑目标：编辑态 → 挑选目标 → 按勾选顺序显示、混语言标题「目标」', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await prefs.setDefaultContentLanguage('ja');
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('jd', StudyGoalId.chars, 1000, language: 'ja'),
      goalRecord('jl', StudyGoalId.listening, 30, language: 'ja'),
      goalRecord('zd', StudyGoalId.chars, 2000, language: 'zh'),
    ]);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'ja',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    await tester.longPress(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'ja'),
      ),
    );
    await pumpDashboard(tester);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('home-widget-configure/language_goals:ja'),
      ),
    );
    await pumpSheet(tester);
    final Finder chooseGoals = find.byKey(
      const ValueKey<String>('study-goal-language-pick-goals'),
    );
    await tester.ensureVisible(chooseGoals);
    await tester.pump();
    await tester.tap(chooseGoals);
    await pumpSheet(tester);

    Finder item(String id) =>
        find.byKey(ValueKey<String>('home-tile-goals-item-$id'));
    // 先只列格子语言（日语）的目标；打开「显示全部语言」才有中文那条。
    expect(item('jd'), findsOneWidget);
    expect(item('zd'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-tile-goals-all-languages')),
    );
    await tester.pump();
    expect(item('zd'), findsOneWidget);
    // 勾选顺序：中文字数 → 日语听力。
    await tester.tap(item('zd'));
    await tester.pump();
    await tester.tap(item('jl'));
    await tester.pump();
    await tester.tap(find.text(t.dialog_done));
    await pumpSheet(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('home-widget-edit-done')),
    );
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    expect(appModel.homeWidgetLayout.wide!.single.goals, <String>['zd', 'jl']);

    final Finder card = find.byKey(
      const ValueKey<String>('home-language-goals-card/ja'),
    );
    Finder ring(String key) => find.descendant(
      of: card,
      matching: find.byKey(ValueKey<String>('home-language-goals-ring-$key')),
    );
    expect(ring('zd'), findsOneWidget);
    expect(ring('jl'), findsOneWidget);
    expect(ring('jd'), findsNothing);
    expect(
      tester.getCenter(ring('zd')).dx,
      lessThan(tester.getCenter(ring('jl')).dx),
    );
    // 混语言：标题「目标」，环下带语言名。
    expect(
      find.descendant(
        of: card,
        matching: find.text(t.home_language_goals_mixed_title),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(
          '${studyGoalLanguageLabel('zh')} · ${t.study_goal_metric_short_chars}',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('「语言目标」格挑了几条、一行高：宽的并排、窄的分页可滑；挑的都删了回到自动', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    await prefs.setDefaultContentLanguage('ja');
    await seedSampleData();
    await appModel.setStudyGoals(<StudyGoal>[
      goalRecord('jd', StudyGoalId.chars, 1000, language: 'ja'),
      goalRecord('jl', StudyGoalId.listening, 30, language: 'ja'),
    ]);
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(4, 1),
          language: 'ja',
          goals: <String>['jl', 'jd'],
        ),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(1, 1),
          language: 'zh',
          goals: <String>['jd', 'jl'],
        ),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 2),
          language: 'ko',
          goals: <String>['gone'],
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    // 宽的一行格：两条并排（听力在前），没有分页。
    final Finder wide = find.byKey(
      const ValueKey<String>('home-language-goals-card/ja'),
    );
    Finder entry(Finder card, String id) => find.descendant(
      of: card,
      matching: find.byKey(ValueKey<String>('home-language-goals-compact/$id')),
    );
    expect(entry(wide, 'jl'), findsOneWidget);
    expect(entry(wide, 'jd'), findsOneWidget);
    expect(
      tester.getCenter(entry(wide, 'jl')).dx,
      lessThan(tester.getCenter(entry(wide, 'jd')).dx),
    );
    expect(
      find.byKey(const ValueKey<String>('home-language-goals-pager/ja')),
      findsNothing,
    );
    // 窄的（1×1）放不下两条：分页可滑。
    expect(
      find.byKey(const ValueKey<String>('home-language-goals-pager/zh')),
      findsOneWidget,
    );
    // 挑的记录已删 → 自动：韩语没有目标，是「为韩语添加目标」。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('home-language-goals-card/ko')),
        matching: find.byKey(
          const ValueKey<String>('home-language-goals-empty'),
        ),
      ),
      findsOneWidget,
    );
  });

  test('小组件短标签：度量短名 + 「/ 周」「/ 月」，限定语言时前面带语言名', () {
    StudyGoal g(StudyGoalId m, StudyGoalPeriod p, [String? language]) =>
        StudyGoal(
          id: 'x',
          metric: m,
          period: p,
          target: 10,
          language: language,
        );
    const StudyGoalUnitChoice auto = StudyGoalUnitChoice.auto;
    expect(
      studyGoalShortLabel(
        g(StudyGoalId.chars, StudyGoalPeriod.weekly, 'ja'),
        unitChoice: auto,
      ),
      '${studyGoalLanguageLabel('ja')} · '
      '${t.study_goal_label_short_weekly(metric: t.study_goal_metric_short_chars)}',
    );
    expect(
      studyGoalShortLabel(
        g(StudyGoalId.listening, StudyGoalPeriod.monthly),
        unitChoice: auto,
      ),
      t.study_goal_label_short_monthly(metric: t.widget_label_listening),
    );
    expect(
      studyGoalShortLabel(
        g(StudyGoalId.chars, StudyGoalPeriod.daily, 'ja'),
        unitChoice: auto,
      ),
      '${studyGoalLanguageLabel('ja')} · ${t.study_goal_metric_short_chars}',
    );
  });

  testWidgets('编辑态改「语言目标」格的语言：角标 → 语言表 → 完成后布局里记住', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 900));
    // 韩语是默认内容语言 → 进候选表；日语已有格子 → 标「首页已有」不可选。
    await prefs.setDefaultContentLanguage('ko');
    await storeHomeLayout(
      wide: const <HomeWidgetItem>[
        HomeWidgetItem(HomeWidgetKind.today, HomeWidgetSize(2, 1)),
        HomeWidgetItem(
          HomeWidgetKind.languageGoals,
          HomeWidgetSize(2, 1),
          language: 'ja',
        ),
      ],
    );
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    await tester.longPress(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'ja'),
      ),
    );
    await pumpDashboard(tester);
    final Finder badge = find.byKey(
      const ValueKey<String>('home-widget-configure/language_goals:ja'),
    );
    expect(badge, findsOneWidget);
    // 「今日」不是可重复组件，没有配置角标。
    expect(
      find.byKey(const ValueKey<String>('home-widget-configure/today')),
      findsNothing,
    );
    await tester.tap(badge);
    await pumpSheet(tester);
    expect(
      find.byKey(const ValueKey<String>('study-goal-language-pick-other')),
      findsOneWidget,
    );
    final Finder korean = find.byKey(
      const ValueKey<String>('study-goal-language-pick-ko'),
    );
    await tester.ensureVisible(korean);
    await tester.pump();
    await tester.tap(korean);
    await pumpSheet(tester);
    expect(
      find.byKey(
        homeWidgetTileKey(HomeWidgetKind.languageGoals, language: 'ko'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('home-widget-edit-done')),
    );
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
    final List<HomeWidgetItem> wide = appModel.homeWidgetLayout.wide!;
    expect(
      wide
          .where((HomeWidgetItem e) => e.kind == HomeWidgetKind.languageGoals)
          .map((HomeWidgetItem e) => e.language),
      <String?>['ko'],
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

  HomeResumeFab resumeFab(WidgetTester tester) =>
      tester.widget<HomeResumeFab>(find.byType(HomeResumeFab));

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
    // 页头大字外壳（PR #3397）：起始侧是页名「首页」大字，头像坐在页头行的
    // 主按钮位（尾端，点开排行榜）。
    expect(find.text(t.nav_home), findsWidgets);
    expect(
      tester.getTopLeft(avatar).dx,
      greaterThan(tester.getTopRight(find.text(t.nav_home).first).dx),
    );
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

  testWidgets('切换激活 Profile 后首页统计立即换成新配置的（反馈 FH1toxJJxz）', (
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
    // 今天 800 字只属于 Alice（legacy 统计归属 Alice，Bob 看不见）。
    await db.setPref(kStatLegacyProfileIdPrefKey, '$alice');
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(find.text(formatStatChars(800)), findsOneWidget);

    // 只改激活 Profile（不碰任何统计表）：首页在屏上也要换成 Bob 的统计。
    await db.setPref('active_profile_id', '$bob');
    await pumpDashboard(tester);
    await pumpDashboard(tester);
    expect(
      find.text(formatStatChars(800)),
      findsNothing,
      reason: '切到 Bob 后不能还显示 Alice 的今日字数',
    );

    await db.setPref('active_profile_id', '$alice');
    await pumpDashboard(tester);
    await pumpDashboard(tester);
    expect(find.text(formatStatChars(800)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('BUG-4895 · 首页不在用户眼前时不在后台重载', () {
    /// 播放页 / 阅读器压上来、转场走完：首页所在路由被完全盖住。
    Future<NavigatorState> coverWithOpaquePage(WidgetTester tester) async {
      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('player')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('player'), findsOneWidget);
      return navigator;
    }

    /// 播放中的一次写库（断点每秒写 video_books、学习时钟每分钟写 study_segments）：
    /// 这里用今天再多 500 字代表——同一张表集、同一条失效通道，且首页上有数字可断言。
    Future<void> writeMoreStudyToday() => seedLegacyReading(
      title: '播放中记下的字数',
      dateKey: FushiTimeFormat.dayKey(DateTime.now()),
      charsRead: 500,
      timeMs: 60000,
    );

    testWidgets('被播放页盖住时到达的统计写入只记一笔；播放页弹走后补做一次重载', (WidgetTester tester) async {
      useSize(tester, const Size(1280, 900));
      final HomeTab tabBefore = homeShellTabNotifier.value;
      addTearDown(() => homeShellTabNotifier.value = tabBefore);
      homeShellTabNotifier.value = HomeTab.home;
      await seedSampleData();
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);
      expect(find.text(formatStatChars(800)), findsOneWidget);

      final NavigatorState navigator = await coverWithOpaquePage(tester);
      // 播放中断点每秒一笔：连着写几次，每次都等过 400 ms 防抖。
      for (int i = 0; i < 3; i++) {
        await writeMoreStudyToday();
        await pumpDashboard(tester);
        await pumpDashboard(tester);
      }
      expect(
        find.text(formatStatChars(800), skipOffstage: false),
        findsOneWidget,
        reason: '被盖住期间不重查聚合、不整页 setState，首页还是盖住前的数据',
      );
      expect(
        find.text(formatStatChars(1300), skipOffstage: false),
        findsNothing,
      );

      navigator.pop();
      await tester.pump();
      await pumpDashboard(tester);
      await pumpDashboard(tester);
      await pumpDashboard(tester);
      expect(
        find.text(formatStatChars(1300)),
        findsOneWidget,
        reason: '回到首页时补做被推迟的重载',
      );
      expect(find.text(formatStatChars(800)), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('上面只是对话框（首页还看得见）时照常重载', (WidgetTester tester) async {
      useSize(tester, const Size(1280, 900));
      final HomeTab tabBefore = homeShellTabNotifier.value;
      addTearDown(() => homeShellTabNotifier.value = tabBefore);
      homeShellTabNotifier.value = HomeTab.home;
      await seedSampleData();
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);
      expect(find.text(formatStatChars(800)), findsOneWidget);

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator),
      );
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(HomeDashboardPage)),
          builder: (_) => const Dialog(child: Text('dialog')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('dialog'), findsOneWidget);

      await writeMoreStudyToday();
      await pumpDashboard(tester);
      await pumpDashboard(tester);
      await pumpDashboard(tester);
      expect(
        find.text(formatStatChars(1300)),
        findsOneWidget,
        reason: '对话框不盖住首页，数据变了要当场更新',
      );

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });
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

  // 页头大字外壳（PR #3397，非墨水屏默认）：首页动作在页头大字一行
  // （[FushiFloatingChromeOverlay] masthead 层），随正文下滚移出视口；焦点
  // 落到移出的动作上（Tab / 手柄）时页头弹回（外壳顶栏同一条 Focus → show
  // 规则），不会出现焦点停在看不见的按钮上；回滚到顶同样弹回。
  testWidgets('页头随滚动：下滚移出视口，焦点进来或回滚都弹回', (WidgetTester tester) async {
    // 首页精简后内容只剩一张卡，矮视口才滚得动。
    useSize(tester, const Size(420, 260));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final Finder stats = find.byKey(
      const ValueKey<String>('home-toolbar-stats'),
      skipOffstage: false,
    );
    expect(stats.hitTestable(), findsOneWidget);
    // 重设计首页的主列表是 CustomScrollView（色块 sliver），不是 ListView。
    final Finder mainScroll = find
        .byWidgetPredicate(
          (Widget w) => w is ScrollView && w.scrollDirection == Axis.vertical,
        )
        .first;

    await tester.drag(mainScroll, const Offset(0, -150));
    await settleSpring(tester);
    expect(stats.hitTestable(), findsNothing, reason: '下滚后页头移出视口');

    // 焦点进到移出的页头动作：页头弹回，按钮看得见、点得到。
    Focus.of(
      tester.element(
        find.descendant(of: stats, matching: find.byType(Icon)).first,
      ),
    ).requestFocus();
    await settleSpring(tester);
    expect(stats.hitTestable(), findsOneWidget, reason: '焦点进来页头必须弹回');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await tester.drag(mainScroll, const Offset(0, -150));
    await settleSpring(tester);
    await tester.drag(mainScroll, const Offset(0, 300));
    await settleSpring(tester);
    expect(stats.hitTestable(), findsOneWidget);
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

  // Media tracking on the home page (the strip and the Continue marks that
  // replaced the Bangumi sync card of BUG-1220) is covered by
  // home_tracking_panel_test.dart; the watched list and "retry matching" moved
  // to the Media tracking settings page.

  // ── 连续尺寸：每种组件在最小 / 中间 / 最大尺寸都不溢出（spec「改尺寸」） ──────
  //
  // 一次把全部组件按同一档（下限 / 中间偏小 / 中间偏大 / 上限）放进一份布局，窄 / 宽
  // 两种网格 × 分区卡 / 色块两套外观各 pump 一遍；视口足够高，所有格子都真的排版。
  // 内容按格子实际宽高排版，任何允许的尺寸都不该抛溢出。
  HomeWidgetSize sizeAt(HomeWidgetKind kind, HomeGridKind grid, int step) {
    final HomeWidgetSize lo = kind.minFor(grid);
    final HomeWidgetSize hi = kind.maxFor(grid);
    int at(int a, int b) => switch (step) {
      0 => a,
      1 => a + (b - a) ~/ 2,
      2 => a + (b - a + 1) ~/ 2,
      _ => b,
    };
    return HomeWidgetSize(at(lo.cols, hi.cols), at(lo.rows, hi.rows));
  }

  for (final ShellContentLayout layout in const <ShellContentLayout>[
    ShellContentLayout.grid,
    ShellContentLayout.collage,
  ]) {
    for (final (HomeGridKind, Size) g in const <(HomeGridKind, Size)>[
      (HomeGridKind.compact, Size(412, 9000)),
      (HomeGridKind.wide, Size(1280, 12000)),
    ]) {
      for (int step = 0; step < 4; step++) {
        final String stepName = <String>['下限', '中间偏小', '中间偏大', '上限'][step];
        testWidgets('连续尺寸不溢出 · ${layout.name} · ${g.$1.wire} · $stepName', (
          WidgetTester tester,
        ) async {
          dashboardLayout = layout;
          useSize(tester, g.$2);
          await seedSampleData();
          final int now = DateTime.now().millisecondsSinceEpoch;
          final List<MediaItem> books = <MediaItem>[];
          final Map<String, int> lastRead = <String, int>{};
          for (int i = 1; i <= 6; i++) {
            books.add(readingBook('在读$i', '在读的书很长很长的书名第$i卷', position: 10 * i));
            lastRead['在读$i'] = now - i * 1000;
          }
          for (int i = 1; i <= 8; i++) {
            await db.insertEpubBook(
              EpubBooksCompanion.insert(
                bookKey: '新书$i',
                title: '新书$i',
                epubPath: '/abs/$i.epub',
                extractDir: '/abs/$i',
                chapterCount: 1,
                chaptersJson: '[]',
                importedAt: now - i * 1000,
                localAddedAt: Value<int?>(now - i * 1000),
              ),
            );
            books.add(readingBook('新书$i', '新书$i', position: 0));
          }
          final List<HomeWidgetItem> items = <HomeWidgetItem>[
            for (final HomeWidgetKind k in HomeWidgetKind.values)
              HomeWidgetItem(k, sizeAt(k, g.$1, step)),
          ];
          await storeHomeLayout(
            compact: g.$1 == HomeGridKind.compact ? items : null,
            wide: g.$1 == HomeGridKind.wide ? items : null,
          );
          await tester.pumpWidget(buildAppWithBooks(books, lastRead));
          await pumpDashboard(tester);

          expect(tester.takeException(), isNull);
          expect(gridKind(tester), g.$1);
          final List<HomeWidgetItem> shown = tester
              .widget<HomeWidgetGrid>(find.byType(HomeWidgetGrid))
              .items;
          // 不受模块门影响的组件一定在；每块都按存下的尺寸排、都真的排版了。
          for (final HomeWidgetKind k in <HomeWidgetKind>[
            HomeWidgetKind.continueHero,
            HomeWidgetKind.continueReading,
            HomeWidgetKind.today,
            HomeWidgetKind.week,
            HomeWidgetKind.recentlyAdded,
            HomeWidgetKind.panorama,
          ]) {
            expect(
              shown.map((HomeWidgetItem e) => e.kind),
              contains(k),
              reason: k.id,
            );
          }
          for (final HomeWidgetItem e in shown) {
            expect(e.size, sizeAt(e.kind, g.$1, step), reason: e.kind.id);
            expect(
              find.byKey(homeWidgetTileKey(e.kind)),
              findsOneWidget,
              reason: '${e.kind.id} 没有排版（视口不够高？）',
            );
          }
          if (step == 0) {
            // 下限 = 半栏：每块都只占 1 列（1×1，继续 / 最近添加 1×2）。
            for (final HomeWidgetItem e in shown) {
              expect(e.size.cols, 1, reason: e.kind.id);
              expect(
                tester.getSize(find.byKey(homeWidgetTileKey(e.kind))).width,
                lessThan(kHomeWidgetWideWidth),
                reason: e.kind.id,
              );
            }
            // 半栏的「继续」主角改排条目小行一列，不画放不下的主卡。
            expect(
              find.byKey(const ValueKey<String>('home-continue-list')),
              findsOneWidget,
            );
          }
        });
      }
    }
  }

  testWidgets('连续尺寸 · 格子越大放得越多：最近添加 / 继续阅读条目数随格子增大', (
    WidgetTester tester,
  ) async {
    useSize(tester, const Size(1280, 4000));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<MediaItem> books = <MediaItem>[];
    final Map<String, int> lastRead = <String, int>{};
    for (int i = 1; i <= 10; i++) {
      books.add(readingBook('在读$i', '在读$i', position: 10 + i));
      lastRead['在读$i'] = now - i * 1000;
    }
    for (int i = 1; i <= 16; i++) {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: '新书${_seriesFreeSuffix(i)}',
          title: '新书${_seriesFreeSuffix(i)}',
          epubPath: '/abs/$i.epub',
          extractDir: '/abs/$i',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: now - i * 1000,
          localAddedAt: Value<int?>(now - i * 1000),
        ),
      );
      books.add(
        readingBook(
          '新书${_seriesFreeSuffix(i)}',
          '新书${_seriesFreeSuffix(i)}',
          position: 0,
        ),
      );
    }
    int count(String prefix) {
      int n = 0;
      while (find.byKey(ValueKey<String>('$prefix/$n')).evaluate().isNotEmpty) {
        n++;
      }
      return n;
    }

    Future<(int, int)> countsAt(HomeWidgetSize size) async {
      await storeHomeLayout(
        wide: <HomeWidgetItem>[
          HomeWidgetItem(HomeWidgetKind.recentlyAdded, size),
          HomeWidgetItem(HomeWidgetKind.continueReading, size),
        ],
      );
      await tester.pumpWidget(buildAppWithBooks(books, lastRead));
      await pumpDashboard(tester);
      expect(tester.takeException(), isNull);
      return (count('home-recent-item'), count('home-continue_reading-item'));
    }

    final (int, int) small = await countsAt(const HomeWidgetSize(2, 2));
    final (int, int) big = await countsAt(const HomeWidgetSize(6, 3));
    expect(small.$1, greaterThan(0));
    expect(big.$1, greaterThan(small.$1));
    expect(big.$2, greaterThan(small.$2));
  });
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

/// 测试书名的后缀 A、B、C…：「最近添加」把同一系列新加的几卷合成一张卡（拼贴设计稿
/// H8，按 `parseBookSeriesKey` 认卷号），书名尾巴是数字（「新书1」「新书2」）会被认成
/// 同一系列的不同卷而合并；只测排序 / 条数的用例用字母后缀，每本各成一张。
String _seriesFreeSuffix(int i) => String.fromCharCode(0x40 + i);
