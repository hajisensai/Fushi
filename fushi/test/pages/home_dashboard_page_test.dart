import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:fushi/src/pages/implementations/home_floating_toolbar.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show CoverProgressStrip;
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
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_dashboard_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_dashboard');
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
  }) =>
      <Override>[
        fushiBooksProvider.overrideWith((ref, language) async => books),
        bookLastReadAtProvider.overrideWith((ref) async => lastReadAt),
        // 空表 ⇒ `lastReadByKey[epubUidByKey[bookKey] ?? bookKey]` 走 bookKey 回退，
        // 与上面 lastReadAt 的键域（bookKey）一致。
        epubBookUidByKeyProvider
            .overrideWith((ref) async => <String, String>{}),
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
    )? openVideoOverride,
  }) =>
      ProviderScope(
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

  /// v92 起阅读只写 `study_segments`，`reading_statistics` 冻结为 legacy 只读投影
  /// （历史数据仍要进首页热力图 / 今日目标）。这里按 legacy 形状直插（OVERWRITE 版
  /// `setReadingStatistic`），语义与旧 `addReadingStatistic` 累加版在空表上等价。
  Future<void> seedLegacyReading({
    required String title,
    required String dateKey,
    required int charsRead,
    required int timeMs,
  }) =>
      db.setReadingStatistic(ReadingStatisticsCompanion.insert(
        title: title,
        dateKey: dateKey,
        charactersRead: charsRead,
        readingTimeMs: timeMs,
        lastStatisticModified: DateTime.now().millisecondsSinceEpoch,
      ));

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
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/keep-watching'),
      title: Value('继续看的视频'),
      videoPath: Value('/abs/keep.mp4'),
      lastPositionMs: Value(754000),
    ));
  }

  void useSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 书侧装配（「继续」区的书来自 provider，测试直接喂 MediaItem）。
  Widget buildAppWithBooks(List<MediaItem> books, Map<String, int> lastReadAt) =>
      ProviderScope(
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
  }) =>
      MediaItem(
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

  // 只数「继续」行里的卡：宽屏下方还有一行「最近添加」，用的是同一个卡组件。
  Finder coverCards() => find.descendant(
        of: find.byKey(const ValueKey<String>('home-continue-row')),
        matching: find.byType(HomeContinueCoverCard),
      );
  Finder recentCards() => find.descendant(
        of: find.byKey(const ValueKey<String>('home-recent-row')),
        matching: find.byType(HomeContinueCoverCard),
      );
  HomeContinueCoverCard onlyCard(WidgetTester tester) =>
      tester.widget<HomeContinueCoverCard>(coverCards());

  // ── 2026-10 首页精简（用户反馈 PDF「1.首页」） ─────────────────────────────

  for (final Size size in const <Size>[Size(1280, 900), Size(420, 900)]) {
    testWidgets(
        '精简 · ${size.width.toInt()} 宽：一张主卡（学习头部行 + 封面行），'
        '「继续」/「学习活动」标题、四类筛选、学习日历、最近添加、活动全部删除',
        (WidgetTester tester) async {
      useSize(tester, size);
      await seedSampleData();
      // 只导入、没看过：旧版会进「最近添加」大栏；现在手机宽度没有这一栏，宽屏
      // 只在主卡下方补一行无标题的精简封面（见下方宽屏专项测试）。
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: const Value('recent-only'),
        title: const Value('刚导入的视频'),
        videoPath: const Value('/abs/recent-only.mp4'),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(HomeStudyHeader), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('home-continue-row')),
          findsOneWidget);
      expect(coverCards(), findsOneWidget);
      // 被删掉的字样 / 控件。
      for (final String gone in <String>[
        t.home_continue,
        t.reading_activity,
        t.home_recently_added,
        t.home_activity,
        t.home_filter_all,
        t.home_filter_read,
        t.home_filter_watch,
        t.home_filter_game,
        t.stat_goal_daily,
        if (size.width < 900) '刚导入的视频',
      ]) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.byType(StatContributionHeatmap), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('home-recent-row')),
        size.width < 900 ? findsNothing : findsOneWidget,
      );
      // 学习头部行在封面行之上（原第 2 栏移到原第 1 栏上面）。
      expect(
        tester.getTopLeft(find.byType(HomeStudyHeader)).dy,
        lessThan(tester.getTopLeft(coverCards()).dy),
      );
    });
  }

  test('宽屏封面高度随内容宽放大并夹在 176…260', () {
    expect(dashboardWideCoverHeight(900), 180);
    expect(dashboardWideCoverHeight(1024), closeTo(204.8, 0.01));
    expect(dashboardWideCoverHeight(1440), 260);
    expect(dashboardWideCoverHeight(2560), 260);
    expect(dashboardWideCoverHeight(800), 176);
  });

  testWidgets(
      '宽屏补内容：主卡下方一行「最近添加」精简封面（无标题行、挂「新」角标、'
      '按导入时间倒序、与「继续」去重）；封面随宽度放大', (WidgetTester tester) async {
    useSize(tester, const Size(1440, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final (String, int) b in <(String, int)>[
      ('新书A', 3000),
      ('在读书', 2000),
      ('新书B', 1000),
    ]) {
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: b.$1,
        title: b.$1,
        epubPath: '/abs/${b.$1}.epub',
        extractDir: '/abs/${b.$1}',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: now - b.$2,
      ));
    }
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('fresh-video'),
      title: const Value('刚导入的视频'),
      videoPath: const Value('/abs/fresh.mp4'),
      importedAt: Value(now - 1500),
    ));
    await tester.pumpWidget(buildAppWithBooks(
      <MediaItem>[
        readingBook('新书A', '新书A', position: 0),
        readingBook('在读书', '在读书', position: 40),
        readingBook('新书B', '新书B', position: 0),
      ],
      const <String, int>{'在读书': 1},
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 「继续」只有在读的那本，封面按 1440 宽放大到 260。
    expect(tester.widgetList<HomeContinueCoverCard>(coverCards()).map(
        (HomeContinueCoverCard c) => c.title), <String>['在读书']);
    expect(tester.widget<HomeContinueCoverCard>(coverCards()).height, 260);
    // 「最近添加」：导入时间倒序、在读书已在「继续」里不重复出现、角标「新」、
    // 比「继续」小一号；没有任何标题字样。
    final List<HomeContinueCoverCard> recent =
        tester.widgetList<HomeContinueCoverCard>(recentCards()).toList();
    expect(recent.map((HomeContinueCoverCard c) => c.title),
        <String>['新书B', '刚导入的视频', '新书A']);
    for (final HomeContinueCoverCard c in recent) {
      expect(c.badgeLabel, t.home_recent_badge);
      expect(c.progress, isNull);
      expect(c.height, closeTo(260 * 0.82, 0.01));
    }
    // 「新」挂左上角、缩小（右上角是竖排书名起笔处，不压字）；「继续」的进度
    // 角标仍在右上角。
    for (final HomeContinueCoverCard c in recent) {
      expect(c.badgeAtStart, isTrue);
      expect(c.badgeScale, lessThan(1));
    }
    expect(tester.widget<HomeContinueCoverCard>(coverCards()).badgeAtStart,
        isFalse);
    final Finder recentBadge = find.descendant(
      of: recentCards().first,
      matching: find.byType(CoverBadge),
    );
    final Rect recentCard = tester.getRect(recentCards().first);
    expect(tester.getRect(recentBadge).center.dx, lessThan(recentCard.center.dx));
    expect(tester.getTopLeft(recentBadge).dx - recentCard.left, lessThan(12));
    expect(find.text(t.home_recently_added), findsNothing);
    expect(
      tester.getTopLeft(recentCards().first).dy,
      greaterThan(tester.getBottomLeft(coverCards()).dy),
    );
  });

  testWidgets('宽屏补内容只在宽屏：手机宽度不出「最近添加」行、封面仍是 148',
      (WidgetTester tester) async {
    useSize(tester, const Size(412, 900));
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: '新书A',
      title: '新书A',
      epubPath: '/abs/a.epub',
      extractDir: '/abs/a',
      chapterCount: 1,
      chaptersJson: '[]',
      importedAt: now,
    ));
    await tester.pumpWidget(buildAppWithBooks(
      <MediaItem>[
        readingBook('新书A', '新书A', position: 0),
        readingBook('在读书', '在读书', position: 40),
      ],
      const <String, int>{'在读书': 1},
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('home-recent-row')), findsNothing);
    expect(tester.widget<HomeContinueCoverCard>(coverCards()).height, 148);
  });

  testWidgets('精简 · 学习头部行：今日字数 + 同一行右侧今日时长（不挂小字标签）',
      (WidgetTester tester) async {
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
    expect(
      find.bySemanticsLabel('${t.stat_today} · $time'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  for (final double width in <double>[320, 360, 420]) {
    testWidgets('精简 · $width 宽手机：学习统计完整显示，不省略号截断、不溢出',
        (WidgetTester tester) async {
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
      final String value =
          t.stat_goal_progress(read: 123456, goal: 30000);
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

  testWidgets('精简 · 封面行只有封面：有封面的书不再挂标题文字，角标 = 阅读进度',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final File cover = File('${storeDir.path}/book_cover.png')
      ..writeAsBytesSync(_kOnePixelPng);
    final MediaItem a = readingBook('书A', '有封面的书',
        position: 30, imageUrl: Uri.file(cover.path).toString());
    final MediaItem b = readingBook('书B', '另一本书',
        position: 50, imageUrl: Uri.file(cover.path).toString());
    await tester.pumpWidget(buildAppWithBooks(
      <MediaItem>[a, b],
      const <String, int>{'书A': 2, '书B': 1},
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final List<HomeContinueCoverCard> cards =
        tester.widgetList<HomeContinueCoverCard>(coverCards()).toList();
    // 最近读的在前；没有「主角卡」了，所有条目同一行。
    expect(cards.map((HomeContinueCoverCard c) => c.title),
        <String>['有封面的书', '另一本书']);
    expect(cards.map((HomeContinueCoverCard c) => c.badgeLabel),
        <String?>['30%', '50%']);
    expect(cards.first.progress, 0.3);
    // 标题只进读屏 / 悬停提示，屏上不画。
    expect(find.text('有封面的书'), findsNothing);
    expect(find.text('另一本书'), findsNothing);
    expect(find.text('30%'), findsOneWidget);
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pump();
    expect(find.bySemanticsLabel('有封面的书 · 30%'), findsOneWidget);
    semantics.dispose();
    expect(find.byType(CoverProgressStrip), findsNWidgets(2));
  });

  testWidgets('精简 · 没有封面的条目兜底显示标题（BUG-1018：用 override 书名）',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final MediaItem book = readingBook('测试书key', '原书名', position: 50);
    await ReaderFushiSource.instance.setOverrideTitleFromMediaItem(
      item: book,
      title: '改后的书名',
    );
    addTearDown(() => ReaderFushiSource.instance
        .setOverrideTitleFromMediaItem(item: book, title: null));
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
    expect(find.text('原书名'), findsNothing);
  });

  testWidgets('精简 · 无封面的视频：封面槽是类型图标 + 标题，不是空黑块',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData(); // 「继续看的视频」无 coverPath
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final Finder fallback =
        find.byKey(const ValueKey<String>('home-continue-cover-fallback'));
    expect(
      find.descendant(
        of: fallback,
        matching: find.byWidgetPredicate((Widget w) =>
            w is FushiIcon && w.icon == mediaCoverFallbackIcon(MediaKind.video)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: fallback, matching: find.text('继续看的视频')),
      findsOneWidget,
    );
  });

  testWidgets('精简 · 视频也显示进度：知道总时长 → 进度条 + 百分比；不知道 → 看到的时间点',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('v-known'),
      title: Value('知道时长的视频'),
      videoPath: Value('/abs/known.mp4'),
      lastPositionMs: Value(600000),
      lastPlayedAt: Value(2),
    ));
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('v-unknown'),
      title: Value('不知道时长的视频'),
      videoPath: Value('/abs/unknown.mp4'),
      lastPositionMs: Value(754000),
      lastPlayedAt: Value(1),
    ));
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoFileSpec(VideoFileSpecsCompanion.insert(
      filePath: '/abs/known.mp4',
      fileSizeBytes: 1,
      fileModifiedAt: now,
      probedAt: now,
      probeVersion: 1,
      durationMs: const Value(2400000),
    ));
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final Map<String, HomeContinueCoverCard> byTitle =
        <String, HomeContinueCoverCard>{
      for (final HomeContinueCoverCard c
          in tester.widgetList<HomeContinueCoverCard>(coverCards()))
        c.title: c,
    };
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

  testWidgets('精简 · 封面卡悬停抬升：绘制超出卡片原始边界但不被横滚行视口截平',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final MediaItem a = readingBook('书A', '书A', position: 30);
    final MediaItem b = readingBook('书B', '书B', position: 50);
    await tester.pumpWidget(buildAppWithBooks(
      <MediaItem>[a, b],
      const <String, int>{'书A': 2, '书B': 1},
    ));
    await pumpDashboard(tester);

    // 悬停放大是 FushiHoverLift 内层的绘制变换：量卡体（ClipRRect），不量外壳。
    final Finder card = find
        .descendant(of: coverCards().last, matching: find.byType(ClipRRect))
        .first;
    final Rect viewport =
        tester.getRect(find.byKey(const ValueKey<String>('home-continue-row')));
    final Rect originalRect = tester.getRect(card);
    final TestGesture mouse =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(card));
    await pumpDashboard(tester);
    final Rect liftedRect = tester.getRect(card);
    expect(liftedRect.top, lessThan(originalRect.top));
    expect(liftedRect.top, greaterThanOrEqualTo(viewport.top - 0.01));
    expect(liftedRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.01));
    await mouse.removePointer();
    await pumpDashboard(tester);
    expect(tester.getRect(card), originalRect);
  });

  testWidgets('精简 · 整排统一 2:3 竖卡：横版截帧的视频也裁进竖卡（不再横竖混排）',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    final File cover = File('${storeDir.path}/landscape_cover.png')
      ..writeAsBytesSync(_kLandscapePng);
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('continue-landscape'),
      title: const Value('在看的横版视频'),
      videoPath: const Value('/abs/continue-landscape.mp4'),
      coverPath: Value(cover.path),
      lastPositionMs: const Value(60000),
    ));
    final MediaItem book = readingBook('书A', '书A', position: 30);
    // 卡片是数据回填后才建的、解码是真异步 I/O：两段都必须在同一个 runAsync 里。
    await tester.runAsync(() async {
      await tester.pumpWidget(buildAppWithBooks(
        <MediaItem>[book],
        const <String, int>{'书A': 1},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    final List<HomeContinueCoverCard> cards =
        tester.widgetList<HomeContinueCoverCard>(coverCards()).toList();
    expect(cards, hasLength(2));
    for (final HomeContinueCoverCard c in cards) {
      expect(c.width, closeTo(c.height * 2 / 3, 0.01), reason: c.title);
    }
    expect(tester.getSize(coverCards().first), tester.getSize(coverCards().last));
    // 横版截帧裁进竖卡：直接 cover 铺满，不走模糊垫底 + contain。
    final Image frame = tester.widget<Image>(find.descendant(
      of: find.byWidgetPredicate((Widget w) =>
          w is HomeContinueCoverCard && w.title == '在看的横版视频'),
      matching: find.byType(Image),
    ).first);
    expect(frame.fit, BoxFit.cover);
  });

  testWidgets('精简 · 视频竖卡优先用作品海报（合集主封面），不用集的横版截帧',
      (WidgetTester tester) async {
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

    expect(tester.takeException(), isNull);
    final Iterable<Image> images = tester.widgetList<Image>(
      find.descendant(of: coverCards(), matching: find.byType(Image)),
    );
    String pathOf(Image i) {
      ImageProvider p = i.image;
      if (p is ResizeImage) p = p.imageProvider;
      return (p as FileImage).file.path;
    }

    expect(images.map(pathOf), everyElement(poster.path));
  });

  testWidgets('精简 · 窄卡上的集数角标完整显示，不被卡边裁掉', (WidgetTester tester) async {
    useSize(tester, const Size(320, 700));
    final int cid = await db.createMediaCollection('很长的作品名');
    for (int i = 1; i <= 12; i++) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value('ep$i'),
        title: Value('E$i'),
        videoPath: Value('/abs/ep$i.mp4'),
        lastPositionMs: Value(i == 12 ? 60000 : 1400000),
        completedAt: i < 12 ? Value(DateTime.now()) : const Value(null),
      ));
      await db.addToCollection(cid, MediaKind.video, 'ep$i');
    }
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(onlyCard(tester).badgeLabel, t.home_continue_episode(n: 12));
    final Rect card = tester.getRect(coverCards());
    final Rect badge = tester.getRect(find.descendant(
      of: coverCards(),
      matching: find.byType(CoverBadge),
    ));
    expect(badge.left, greaterThanOrEqualTo(card.left));
    expect(badge.right, lessThanOrEqualTo(card.right));
    expect(find.text(t.home_continue_episode(n: 12)), findsOneWidget);
  });

  testWidgets('点继续区视频卡直接续播（带主合集 id），不再只是切视频 tab；合集卡角标 = 集数',
      (WidgetTester tester) async {
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
    await tester.pumpWidget(buildApp(
      openVideoOverride: (
        BuildContext _,
        VideoBookRepository __,
        String bookUid,
        int? playlistCollectionId,
      ) async {
        opened.add((bookUid, playlistCollectionId));
      },
    ));
    await pumpDashboard(tester);

    final HomeTab tabBefore = homeShellTabNotifier.value;
    // 合集成员：显示名 = 合集名，角标 = 在看中的 E1 是第 1 集。
    final HomeContinueCoverCard c = onlyCard(tester);
    expect(c.title, '进击的巨人');
    expect(c.badgeLabel, t.home_continue_episode(n: 1));
    await tester.tap(coverCards());
    await tester.pump();
    expect(opened, <(String, int?)>[('e1', cid)]);
    expect(homeShellTabNotifier.value, tabBefore);
    expect(tester.takeException(), isNull);
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
    await db.upsertGalgame(GalgamesCompanion(
      id: Value(id),
      name: Value(name),
      exePath: Value('/abs/$id.exe'),
      workdir: const Value('/abs'),
      addedAt: Value(addedAt.millisecondsSinceEpoch),
      coverPath: Value(coverPath),
    ));
    if (playedAt != null) {
      await db.insertGalgameSession(GalgameSessionsCompanion(
        gameId: Value(id),
        startMs: Value(playedAt.millisecondsSinceEpoch - 60000),
        endMs: Value(playedAt.millisecondsSinceEpoch),
        durationSeconds: const Value(60),
        dateKey: Value(FushiTimeFormat.dayKey(playedAt)),
      ));
    }
  }

  testWidgets('BUG-1111：玩过的游戏进「继续」区（游戏无完成度，不画角标）',
      (WidgetTester tester) async {
    useWindowsPlatform();
    useSize(tester, const Size(1280, 900));
    final DateTime now = DateTime.now();
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('v-1'),
      title: Value('某视频'),
      videoPath: Value('/abs/v1.mp4'),
      lastPositionMs: Value(5000),
    ));
    await seedGame(
      id: 'g-1',
      name: '某游戏',
      addedAt: now.subtract(const Duration(days: 3)),
      playedAt: now,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final List<HomeContinueCoverCard> cards =
        tester.widgetList<HomeContinueCoverCard>(coverCards()).toList();
    expect(
      cards.map((HomeContinueCoverCard c) => c.title),
      containsAll(<String>['某游戏', '某视频']),
    );
    final HomeContinueCoverCard game =
        cards.singleWhere((HomeContinueCoverCard c) => c.title == '某游戏');
    expect(game.badgeLabel, isNull);
    expect(game.progress, isNull);
  });

  testWidgets('BUG-1111：同合集的多个游戏在「继续」区收敛成一张卡（与视频侧同口径）',
      (WidgetTester tester) async {
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
    expect(
      tester
          .widgetList<HomeContinueCoverCard>(coverCards())
          .map((HomeContinueCoverCard c) => c.title),
      <String>['某系列'],
    );
  });

  testWidgets('继续区合集 Next-Up：看完 E1 后合集卡推进为 E2（角标第 2 集），点击直接打开 E2',
      (WidgetTester tester) async {
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
    await tester.pumpWidget(buildApp(
      openVideoOverride: (
        BuildContext _,
        VideoBookRepository __,
        String bookUid,
        int? playlistCollectionId,
      ) async {
        opened.add((bookUid, playlistCollectionId));
      },
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final HomeContinueCoverCard c = onlyCard(tester);
    expect(c.title, '进击的巨人');
    expect(c.badgeLabel, t.home_continue_episode(n: 2));
    await tester.tap(coverCards());
    await tester.pump();
    expect(opened, <(String, int?)>[('e2', cid)]);
  });

  testWidgets('继续区合集 Next-Up：整个合集全部看完 → 不出卡（自然滚出继续区）',
      (WidgetTester tester) async {
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
    expect(coverCards(), findsNothing);
    expect(find.byType(HomeEmptyState), findsOneWidget);
  });

  testWidgets('精简 · 新用户空库：不是一片空白——头部行 + 空态说明 + 去书架 / 去媒体库',
      (WidgetTester tester) async {
    useSize(tester, const Size(420, 900));
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(HomeStudyHeader), findsOneWidget);
    expect(find.text(t.stat_goal_set), findsOneWidget);
    expect(find.text(t.home_continue_empty), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('home-empty-go-books')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('home-empty-go-video')),
        findsOneWidget);
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

    await pumpDashboard(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HomeContinueRowSkeleton), findsNothing);
    expect(coverCards(), findsOneWidget);
  });

  testWidgets('BUG-3034 · 切回首页（页面重建）首帧直接用上一轮快照，不再挂骨架等整批',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    final ValueNotifier<bool> showPage = ValueNotifier<bool>(true);
    addTearDown(showPage.dispose);
    await tester.pumpWidget(ProviderScope(
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
    ));
    await pumpDashboard(tester);
    expect(coverCards(), findsOneWidget);

    showPage.value = false;
    await tester.pump();
    expect(find.byType(HomeDashboardPage), findsNothing);

    showPage.value = true;
    await tester.pump();
    // 重建后的**第一帧**：快照已上屏，没有骨架。
    expect(find.byType(HomeContinueRowSkeleton), findsNothing);
    expect(find.byType(HomeGoalSkeleton), findsNothing);
    expect(onlyCard(tester).title, '继续看的视频');
    await pumpDashboard(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('今日目标：未设目标只显示设定入口；对话框设 1000 后进度行 = 800/1000',
      (WidgetTester tester) async {
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
      '连接按钮组预设（选中态随输入联动）+ 实心保存按钮',
      (WidgetTester tester) async {
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
        find.byKey(const ValueKey<String>('stat-goal-daily-field')));
    expect(tester.widget<TextField>(dailyFinder).decoration?.filled, isTrue);

    // 近 7 日日均是一颗可点的建议 chip：点一下就填进去。
    final Finder average =
        find.byKey(const ValueKey<String>('stat-goal-average-chip'));
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
    final Finder presets =
        find.byKey(const ValueKey<String>('stat-goal-presets'));
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

  testWidgets('精简 · 焦点可遍历：Tab 能落到「继续」封面卡', (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final Finder card = coverCards();
    bool focusedOnCard() {
      final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return false;
      final Element cardEl = tester.element(card);
      bool hit = false;
      ctx.visitAncestorElements((Element e) {
        if (identical(e, cardEl)) hit = true;
        return !hit;
      });
      return hit;
    }

    bool reached = false;
    for (int i = 0; i < 40 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached = focusedOnCard();
    }
    expect(reached, isTrue, reason: '封面卡必须是 Tab 可达的焦点停靠点');
  });

  // ── 2026-10 首页统一浮动工具栏 ────────────────────────────────────────────

  Finder dashboardList() => find.byWidgetPredicate(
      (Widget w) => w is ListView && w.scrollDirection == Axis.vertical);
  HomeFloatingToolbar toolbar(WidgetTester tester) =>
      tester.widget<HomeFloatingToolbar>(find.byType(HomeFloatingToolbar));
  HomeResumeFab resumeFab(WidgetTester tester) =>
      tester.widget<HomeResumeFab>(find.byType(HomeResumeFab));
  bool excludedFromFocus(WidgetTester tester, Finder target) => tester
      .widgetList<ExcludeFocus>(
          find.ancestor(of: target, matching: find.byType(ExcludeFocus)))
      .any((ExcludeFocus w) => w.excluding);

  /// 滚动后跑完弹簧（default spatial 约 0.5 s 收敛）。
  Future<void> settleSpring(WidgetTester tester) async {
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('浮动工具栏：左上角是头像（不再是「首页」标题胶囊），右侧更新/统计/排行榜/反馈',
      (WidgetTester tester) async {
    useSize(tester, const Size(1280, 900));
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final Finder avatar =
        find.byKey(const ValueKey<String>('home-toolbar-avatar'));
    expect(avatar, findsOneWidget);
    expect(find.byKey(const ValueKey<String>('fushi_floating_top_bar_title')),
        findsNothing);
    final double cardTop = tester.getTopLeft(find.byType(HomeStudyHeader)).dy;
    expect(tester.getTopLeft(avatar).dy, lessThan(cardTop));
    expect(tester.getTopLeft(avatar).dx, lessThan(100));
    for (final String key in <String>[
      'home-toolbar-updates',
      'home-toolbar-stats',
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

  testWidgets('BUG-3249 头像跟随 Profile 改名与切换（不止 initState 读一次）',
      (WidgetTester tester) async {
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

  testWidgets('浮动工具栏：Tab 可达四颗动作按钮（焦点可遍历）', (WidgetTester tester) async {
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
        skipOffstage: false);
    expect(excludedFromFocus(tester, stats), isFalse);

    await tester.drag(dashboardList(), const Offset(0, -150));
    await settleSpring(tester);
    expect(toolbar(tester).visible, isFalse);
    expect(excludedFromFocus(tester, stats), isTrue,
        reason: '退场中的栏不能还被 Tab 到');

    await tester.drag(dashboardList(), const Offset(0, 60));
    await settleSpring(tester);
    expect(toolbar(tester).visible, isTrue);
    expect(excludedFromFocus(tester, stats), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HomeToolbarScrollState：只认主列表纵向滚动，带回差切换显隐', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final BuildContext scrollContext = tester.element(find.byType(Scaffold));
    final HomeToolbarScrollState state = HomeToolbarScrollState();
    addTearDown(state.dispose);
    ScrollUpdateNotification update({
      required double pixels,
      required double delta,
      Axis axis = Axis.vertical,
    }) =>
        ScrollUpdateNotification(
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
  group('Bangumi 同步卡（BUG-1220）',
      skip: kMediaTrackingEnabled
          ? false
          : 'Bangumi 同步临时下线（kMediaTrackingEnabled=false）', () {
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
          find.textContaining(t.media_tracking_never_synced), findsOneWidget);
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

    testWidgets('已关联条目列出本地标题 + Bangumi 条目名，并给出打开入口',
        (WidgetTester tester) async {
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
