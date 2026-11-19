// 首页「复习」入口条（HomeDashboardPanel.srsReview）：显示判据、计数口径、点击接线、
// 「今日已完成」状态，MD3 与 Apple 两套设计系统各跑一遍。
//
// 真实首页（HomeDashboardPage）+ 内存库上的真 SrsDbStore；DB 读写一律放
// tester.runAsync（fake zone 里 await 真异步会挂死）。
//
// 真实像素预览：设环境变量 FUSHI_PREVIEW_DIR=<目录> 时额外输出手机竖屏 / 宽屏两张
// PNG（不设时跳过，CI 不写文件）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
import 'package:fushi/src/pages/implementations/home_srs_panel.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_deck_list_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_ui.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart'
    show FushiShellTheme, ShellContentLayout;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import '../srs/srs_test_support.dart' show SrsTestEngine, openSrsTestStorage;
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/fushi_icon_fonts.dart';
import '../helpers/test_platform_services.dart';

const String _kProfile = '01928c3e-0000-7000-8000-0000000000bb';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // ── 纯判据 ──────────────────────────────────────────────────────────────

  group('homeSrsAutoDefault（旧自动档判据，只用于迁移）', () {
    test('Anki 制卡、没有复习卡的存量用户：自动档不放', () {
      expect(homeSrsAutoDefault(miningToReview: false, totalCards: 0), isFalse);
      // 卡数还在加载：同样不放。
      expect(
        homeSrsAutoDefault(miningToReview: false, totalCards: null),
        isFalse,
      );
    });

    test('在用复习：挖词目标 = 复习，或已有复习卡', () {
      expect(homeSrsAutoDefault(miningToReview: true, totalCards: 0), isTrue);
      expect(
        homeSrsAutoDefault(miningToReview: true, totalCards: null),
        isTrue,
      );
      expect(homeSrsAutoDefault(miningToReview: false, totalCards: 3), isTrue);
    });
  });

  group('migrateHomeWidgetLayout · 复习组件', () {
    bool placed(
      HomeGridKind grid, {
      HomeDashboardPanelMode mode = HomeDashboardPanelMode.auto,
      bool auto = false,
    }) => migrateHomeWidgetLayout(
      grid: grid,
      modes: <HomeDashboardPanel, HomeDashboardPanelMode>{
        HomeDashboardPanel.srsReview: mode,
      },
      auto: HomeWidgetAutoFacts(srsReview: auto),
    ).any((HomeWidgetItem e) => e.kind == HomeWidgetKind.srsReview);

    for (final HomeGridKind grid in HomeGridKind.values) {
      test('${grid.wire} · 自动档跟判据走；钉的档位优先于自动判据', () {
        expect(placed(grid), isFalse);
        expect(placed(grid, auto: true), isTrue);
        expect(placed(grid, mode: HomeDashboardPanelMode.shown), isTrue);
        expect(
          placed(grid, mode: HomeDashboardPanelMode.hidden, auto: true),
          isFalse,
        );
      });
    }

    test('默认模板里复习是 1×1（窄、宽同档）；窄网格半栏个数为奇数时末位放宽成 2×1', () {
      HomeWidgetSize srsIn(HomeGridKind grid, {required bool tracking}) =>
          migrateHomeWidgetLayout(
                grid: grid,
                modes: const <HomeDashboardPanel, HomeDashboardPanelMode>{},
                auto: HomeWidgetAutoFacts(srsReview: true, tracking: tracking),
              )
              .singleWhere(
                (HomeWidgetItem e) => e.kind == HomeWidgetKind.srsReview,
              )
              .size;
      for (final HomeGridKind grid in HomeGridKind.values) {
        expect(srsIn(grid, tracking: true), const HomeWidgetSize(1, 1));
      }
      expect(
        srsIn(HomeGridKind.wide, tracking: false),
        const HomeWidgetSize(1, 1),
      );
      // 窄：今日 / 近 7 天 / 复习三块半栏，复习落单就占满一行，不留半格空洞。
      expect(
        srsIn(HomeGridKind.compact, tracking: false),
        const HomeWidgetSize(2, 1),
      );
    });

    test('复习模块关着：组件不可用（布局里保留，不渲染）', () {
      bool available({required bool srs}) => homeWidgetAvailable(
        HomeWidgetKind.srsReview,
        reading: true,
        watching: true,
        playing: true,
        srs: srs,
        tracking: true,
        ai: true,
      );
      expect(available(srs: false), isFalse);
      expect(available(srs: true), isTrue);
    });
  });

  group('HomeDashboardPanel 旧偏好只读解码', () {
    test('未知 / 坏值回落 auto（不进 map）', () {
      expect(
        decodeHomeDashboardPanelModes(
          '{"srs_review":"hidden"}',
        )[HomeDashboardPanel.srsReview],
        HomeDashboardPanelMode.hidden,
      );
      expect(decodeHomeDashboardPanelModes('{"srs_review":"auto"}'), isEmpty);
      expect(decodeHomeDashboardPanelModes(''), isEmpty);
      expect(decodeHomeDashboardPanelModes('not json'), isEmpty);
      expect(decodeHomeDashboardPanelModes('{"srs_review":"x"}'), isEmpty);
    });
  });

  // ── 真实首页 ────────────────────────────────────────────────────────────

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_srs_home_pp');
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
  late AppModel appModel;
  late Directory storeDir;
  late SrsDbStore store;
  late PreferencesRepository prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    homeShellTabNotifier.value = HomeTab.home;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    // 空库首页会在最上面挂新手引导卡，窄列下把复习条挤出首屏；本文件只测复习条。
    await prefs.setOnboardingHomeCardDismissed(value: true);
    storeDir = Directory.systemTemp.createTempSync('fushi_srs_home');
    platformServices = testPlatformServices();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    final SrsStorage srs = await openSrsTestStorage();
    store = await SrsDbStore.open(
      core: srs.core,
      profileUid: _kProfile,
      deviceId: 'test-device',
      // 「今日」一行的用例要真的答卡（测试 FSRS 引擎，与其它 SRS 页测试同一份）。
      engine: const SrsTestEngine(),
    );
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  Future<void> addNote(String expression, {String? deckId}) => store
      .createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: deckId,
        fieldsById: <String, String>{
          srsLapisFieldId(_kProfile, 'Expression'): expression,
          srsLapisFieldId(_kProfile, 'MainDefinition'): 'meaning',
        },
      )
      .then((_) {});

  /// 复习模块开 + 挖词目标（默认 Anki）。
  Future<void> useSrs({required SrsMiningTarget target}) async {
    await appModel.setModuleEnabled(ModuleId.srs, true);
    await appModel.setSrsMiningTarget(target);
  }

  /// 往偏好 `home_widget_layout` 写一份布局（= 用户编辑过首页）。
  Future<void> storeLayout({
    List<HomeWidgetItem>? compact,
    List<HomeWidgetItem>? wide,
  }) => appModel.setHomeWidgetLayout(
    HomeWidgetLayout(compact: compact, wide: wide),
  );

  /// 只有一块复习组件（[size]）的布局，窄、宽两份都写。
  Future<void> storeSrsOnly(HomeWidgetSize size) => storeLayout(
    compact: <HomeWidgetItem>[HomeWidgetItem(HomeWidgetKind.srsReview, size)],
    wide: <HomeWidgetItem>[HomeWidgetItem(HomeWidgetKind.srsReview, size)],
  );

  void useSize(WidgetTester tester, Size logical, {double dpr = 1}) {
    tester.view.physicalSize = logical * dpr;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  List<Override> overrides() => <Override>[
    platformServicesProvider.overrideWithValue(platformServices),
    ankiRepositoryProvider.overrideWithValue(FakeAnkiRepository()),
    appProvider.overrideWith((Ref ref) => appModel),
    srsStoreProvider.overrideWith((Ref ref) async => store),
    srsCardFaceBuilderProvider.overrideWithValue(
      (BuildContext context, SrsCardFace face) => SrsPlainCardFace(face: face),
    ),
    fushiBooksProvider.overrideWith((ref, language) async => <MediaItem>[]),
    bookLastReadAtProvider.overrideWith((ref) async => <String, int>{}),
    epubBookUidByKeyProvider.overrideWith((ref) async => <String, String>{}),
    leaderboardServiceProvider.overrideWith(
      (Ref _) => LeaderboardService(
        database: () => db,
        supportRoot: () async => storeDir,
        profileId: () async => 1,
        httpClientFactory: () async => throw StateError('no network'),
      ),
    ),
  ];

  final GlobalKey boundaryKey = GlobalKey();

  /// [layout] 为 null = 主题默认（重设计外壳下是拼贴：首页复习块画成海报色块
  /// `_HomeSrsPoster`）；[ShellContentLayout.grid] 钉回封面网格（原一行条面板）。
  Widget app(Widget home, {required bool apple, ShellContentLayout? layout}) =>
      ProviderScope(
        overrides: overrides(),
        child: TranslationProvider(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: layout == null
                ? theme(apple: apple)
                : theme(apple: apple).copyWith(
                    // 展开进显式 `<ThemeExtension<dynamic>>[...]` 时 CFE 报元素类型不匹配
                    // （analyzer 不报），改成 toList + add。
                    extensions: theme(apple: apple).extensions.values.toList()
                      ..add(FushiShellTheme(contentLayout: layout)),
                  ),
            builder: (BuildContext context, Widget? child) => RepaintBoundary(
              key: boundaryKey,
              child: FushiGlassScope(child: child!),
            ),
            home: home,
          ),
        ),
      );

  Widget dashboard() =>
      Scaffold(body: HomeDashboardPage(videoRepo: VideoBookRepository(db)));

  /// 让真实 drift 读与帧都推进（不用 pumpAndSettle：DB + FutureProvider 不会 settle）。
  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  final Finder panel = find.byType(HomeSrsPanel);
  final Finder start = find.byKey(
    const ValueKey<String>('home-srs-panel-start'),
  );

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds · Anki 制卡、没有复习卡的用户：首页没有复习条', (WidgetTester tester) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() => useSrs(target: SrsMiningTarget.anki));
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(panel, findsNothing);
      expect(find.text(t.home_srs_panel_start), findsNothing);
      await unmount(tester);
    });

    testWidgets('$ds · 复习模块关着（默认）：首页没有复习条', (WidgetTester tester) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() => addNote('食べる'));
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(panel, findsNothing);
      await unmount(tester);
    });

    testWidgets('$ds · 已有复习卡（目标仍是 Anki）：自动显示', (WidgetTester tester) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() async {
        await useSrs(target: SrsMiningTarget.anki);
        await addNote('食べる');
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(panel, findsOneWidget);
      await unmount(tester);
    });

    testWidgets('$ds · 旧面板设置钉成隐藏：迁移出的首个布局不放复习，在用复习也不显示', (
      WidgetTester tester,
    ) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() async {
        await useSrs(target: SrsMiningTarget.srs);
        await addNote('食べる');
        await prefs.setHomeDashboardPanels(
          '{"${HomeDashboardPanel.srsReview.id}":"${HomeDashboardPanelMode.hidden.wire}"}',
        );
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(panel, findsNothing);
      await unmount(tester);
    });

    testWidgets('$ds · 复习放上首页后：复习模块关掉整块不渲染，重新打开就回来', (
      WidgetTester tester,
    ) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() async {
        await addNote('食べる');
        await storeSrsOnly(const HomeWidgetSize(1, 1));
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(panel, findsNothing, reason: '复习模块默认关着');
      expect(
        find.byKey(const ValueKey<String>('home-widget/srs_review')),
        findsNothing,
      );

      await tester.runAsync(() => useSrs(target: SrsMiningTarget.anki));
      await settle(tester);
      expect(panel, findsOneWidget, reason: '布局里保留着，模块打开就回来');

      await tester.runAsync(
        () => appModel.setModuleEnabled(ModuleId.srs, false),
      );
      await settle(tester);
      expect(panel, findsNothing);
      expect(
        appModel.homeWidgetLayout.compact!.single.kind,
        HomeWidgetKind.srsReview,
        reason: '不可用不改布局',
      );
      await unmount(tester);
    });

    for (final ShellContentLayout layout in ShellContentLayout.values) {
      testWidgets('$ds · ${layout.name} · 计数与牌组列表顶层行之和一致（含子牌组）', (
        WidgetTester tester,
      ) async {
        useSize(tester, const Size(420, 900));
        await tester.runAsync(() async {
          await useSrs(target: SrsMiningTarget.srs);
          await addNote('食べる');
          await addNote('飲む');
          final String parent = await store.createDeck('漫画');
          final String child = await store.createDeck('一巻', parentId: parent);
          await addNote('走る', deckId: child);
          // 三色计数挂在 2×1 档。
          await storeSrsOnly(const HomeWidgetSize(2, 1));
        });
        // 首页与牌组列表挂在同一个 ProviderScope 里换页：两个 scope 都覆盖成同一个
        // [appModel] 时，各自卸载都会 dispose 它一次（ChangeNotifierProvider 拥有它）。
        final ValueNotifier<Widget> page = ValueNotifier<Widget>(dashboard());
        addTearDown(page.dispose);
        await tester.pumpWidget(
          app(
            ValueListenableBuilder<Widget>(
              valueListenable: page,
              builder: (BuildContext context, Widget current, Widget? _) =>
                  current,
            ),
            apple: apple,
            layout: layout,
          ),
        );
        await settle(tester);
        // 封面网格（卡片外观）与拼贴（海报色块）的 2×1 复习块都挂同一个三色计数
        // `home-srs-panel-counts`（SrsCountTriple）。
        final SrsCountTriple home = tester.widget<SrsCountTriple>(
          find.descendant(
            of: panel,
            matching: find.byKey(
              const ValueKey<String>('home-srs-panel-counts'),
            ),
          ),
        );

        // 牌组列表：顶层行上的三色计数（顶层已含子牌组）。
        final List<SrsDeckSummary> decks = (await tester.runAsync(
          store.deckSummaries,
        ))!;
        page.value = const SrsDeckListPage();
        await settle(tester);
        int sumNew = 0, sumLearn = 0, sumReview = 0;
        for (final SrsDeckSummary d in decks.where(
          (SrsDeckSummary d) => d.depth == 0,
        )) {
          final SrsDeckCountChips row = tester.widget<SrsDeckCountChips>(
            find.descendant(
              of: find.byKey(ValueKey<String>('srs-deck-${d.deck.id}')),
              matching: find.byType(SrsDeckCountChips),
            ),
          );
          sumNew += row.newCount;
          sumLearn += row.learnCount;
          sumReview += row.reviewCount;
        }
        expect(sumNew, 3, reason: '三张新卡（其中一张在子牌组）');
        expect(home.newCount, sumNew);
        expect(home.learnCount, sumLearn);
        expect(home.reviewCount, sumReview);
        await unmount(tester);
      });
    }

    testWidgets('$ds · 点「开始复习」直接进复习页；点条目进牌组列表 tab', (
      WidgetTester tester,
    ) async {
      // 「开始复习」只挂在不矮的格子里（宽网格；窄网格一行高的格子只放大字）。
      useSize(tester, const Size(1280, 900));
      await tester.runAsync(() async {
        await useSrs(target: SrsMiningTarget.srs);
        await addNote('食べる');
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(start, findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('home-srs-panel-open')),
      );
      await tester.pump();
      expect(homeShellTabNotifier.value, HomeTab.srs);
      homeShellTabNotifier.value = HomeTab.home;

      await tester.tap(start);
      await settle(tester);
      final SrsReviewPage review = tester.widget<SrsReviewPage>(
        find.byType(SrsReviewPage),
      );
      expect(review.deckId, store.defaultDeckId);
      await unmount(tester);
    });

    testWidgets('$ds · 今天没有待复习的卡：显示「今日已完成」，没有开始按钮', (
      WidgetTester tester,
    ) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() => useSrs(target: SrsMiningTarget.srs));
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(panel, findsOneWidget);
      expect(find.text(t.home_srs_panel_done), findsOneWidget);
      expect(start, findsNothing);
      await unmount(tester);
    });

    testWidgets('$ds · 「今日」一行：今天已复习张数 · 用时 · 正确率，与统计口径同一数据源', (
      WidgetTester tester,
    ) async {
      // 「今日」一行挂在宽网格的 2×1 档。
      useSize(tester, const Size(1280, 900));
      final List<String> cards = <String>[];
      await tester.runAsync(() async {
        await useSrs(target: SrsMiningTarget.srs);
        await storeSrsOnly(const HomeWidgetSize(2, 1));
        for (final String w in <String>['食べる', '飲む', '走る']) {
          final String note = await store.createNote(
            noteTypeId: store.lapisNoteTypeId,
            fieldsById: <String, String>{
              srsLapisFieldId(_kProfile, 'Expression'): w,
              srsLapisFieldId(_kProfile, 'MainDefinition'): 'meaning',
            },
          );
          cards.add((await store.cardsOfNote(note)).first.id);
        }
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      final Finder today = find.descendant(
        of: panel,
        matching: find.byKey(const ValueKey<String>('home-srs-panel-today')),
      );
      // 还没复习：0 张、没有正确率。
      expect(
        tester.widget<Text>(today).data,
        homeSrsTodayLine(SrsTodayReviewSummary.empty),
      );
      expect(tester.widget<Text>(today).data, isNot(contains('%')));

      await tester.runAsync(() async {
        await store.answer(cards[0], 3, durationMs: 70000);
        await store.answer(cards[1], 1, durationMs: 5000);
      });
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(panel),
      );
      container.read(srsRevisionProvider.notifier).state++;
      await settle(tester);
      final SrsTodayReviewSummary summary = (await tester.runAsync(
        store.todayReviewSummary,
      ))!;
      expect(summary.count, 2);
      expect(summary.again, 1);
      final String line = tester.widget<Text>(today).data!;
      expect(line, homeSrsTodayLine(summary));
      expect(line, contains('2'));
      expect(line, contains('50%'));
      expect(tester.takeException(), isNull);
      await unmount(tester);
    });

    // 网格格子定高：封面网格（卡片外观）与拼贴（海报色块）都是骨架与加载完、
    // 有卡与没卡同一高度。宽网格 2×1 档（计数 + 开始按钮都挂）。
    for (final ShellContentLayout layout in ShellContentLayout.values) {
      testWidgets('$ds · ${layout.name} · 计数加载中挂骨架，行高与加载完一致；制卡刷新信号后计数更新', (
        WidgetTester tester,
      ) async {
        useSize(tester, const Size(1280, 900));
        await tester.runAsync(() async {
          await useSrs(target: SrsMiningTarget.srs);
          await storeSrsOnly(const HomeWidgetSize(2, 1));
        });
        await tester.pumpWidget(app(dashboard(), apple: apple, layout: layout));
        // 首帧：数据还没回来，挂骨架。
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('home-srs-panel-skeleton')),
          findsOneWidget,
        );
        final double loadingHeight = tester.getSize(panel).height;
        await settle(tester);
        expect(tester.getSize(panel).height, loadingHeight);
        expect(find.text(t.home_srs_panel_done), findsOneWidget);

        // 制卡写进复习 → 刷新信号（与 SrsMiningAnkiRepository.onCardsAdded 同一个）。
        await tester.runAsync(() => addNote('食べる'));
        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(panel),
        );
        container.read(srsRevisionProvider.notifier).state++;
        await settle(tester);
        expect(start, findsOneWidget);
        expect(
          tester
              .widget<SrsCountTriple>(
                find.descendant(
                  of: panel,
                  matching: find.byKey(
                    const ValueKey<String>('home-srs-panel-counts'),
                  ),
                ),
              )
              .newCount,
          1,
        );
        expect(find.text(t.home_srs_panel_done), findsNothing);
        expect(tester.getSize(panel).height, loadingHeight);
        await unmount(tester);
      });
    }

    // 最矮的格子：宽网格行高夹到下限 104（刚过断点的横屏窗口 / 840 宽窗口）、窄网格
    // 一行高；1×1 与 2×1 各一遍。骨架与「大字 + 计数 + 开始」按可用尺寸收，不溢出；
    // 放不下按钮的 1×1 只放大字（spec：格子不矮时才挂「开始复习」）。
    for (final (Size, HomeWidgetSize) c in const <(Size, HomeWidgetSize)>[
      (Size(620, 420), HomeWidgetSize(1, 1)),
      (Size(620, 420), HomeWidgetSize(2, 1)),
      (Size(840, 1000), HomeWidgetSize(1, 1)),
      (Size(240, 900), HomeWidgetSize(1, 1)),
      (Size(240, 900), HomeWidgetSize(2, 1)),
    ]) {
      testWidgets('$ds · 最矮格 ${c.$1.width.toInt()}×${c.$1.height.toInt()} '
          '${c.$2}：骨架与「大字 + 开始」按可用尺寸收窄，不溢出', (WidgetTester tester) async {
        useSize(tester, c.$1);
        await tester.runAsync(() async {
          await useSrs(target: SrsMiningTarget.srs);
          await addNote('食べる');
          await storeSrsOnly(c.$2);
        });
        await tester.pumpWidget(app(dashboard(), apple: apple));
        await tester.pump();
        expect(
          find.byKey(const ValueKey<String>('home-srs-panel-skeleton')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: '骨架溢出');
        await settle(tester);
        expect(
          find.byKey(const ValueKey<String>('home-srs-panel-remaining')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull, reason: '大字 / 计数 / 开始按钮溢出');
        if (start.evaluate().isNotEmpty) {
          final Rect cell = tester.getRect(panel);
          final Rect button = tester.getRect(start);
          expect(button.bottom, lessThanOrEqualTo(cell.bottom + 0.5));
          expect(button.right, lessThanOrEqualTo(cell.right + 0.5));
        }
        await unmount(tester);
      });
    }
  }

  // ── 真实像素预览（FUSHI_PREVIEW_DIR 设了才跑） ──────────────────────────

  final String? previewDir = Platform.environment['FUSHI_PREVIEW_DIR'];
  for (final (String name, Size size) shot in <(String, Size)>[
    ('phone_portrait', const Size(392, 820)),
    ('wide', const Size(1366, 820)),
  ]) {
    for (final bool apple in <bool>[false, true]) {
      testWidgets(
        '预览 ${shot.$1} · ${apple ? 'apple' : 'md3'}',
        skip: previewDir == null,
        (WidgetTester tester) async {
          await tester.runAsync(() async {
            await loadFushiIconFonts();
            for (final String family in <String>[
              'Roboto',
              '.SF UI Text',
              '.SF Pro Text',
            ]) {
              final Uint8List bytes = await File(
                r'C:\Windows\Fonts\Deng.ttf',
              ).readAsBytes();
              await (FontLoader(family)..addFont(
                    Future<ByteData>.value(ByteData.sublistView(bytes)),
                  ))
                  .load();
            }
            await useSrs(target: SrsMiningTarget.srs);
            for (final String w in <String>['食べる', '飲む', '走る', '読む']) {
              await addNote(w);
            }
          });
          useSize(tester, shot.$2, dpr: 2);
          await tester.pumpWidget(app(dashboard(), apple: apple));
          await settle(tester, rounds: 20);
          expect(panel, findsOneWidget);
          await tester.runAsync(() async {
            final RenderRepaintBoundary boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final ui.Image image = await boundary.toImage(pixelRatio: 2);
            final ByteData? png = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final File out = File(
              '$previewDir/home_srs_${shot.$1}_${apple ? 'apple' : 'md3'}.png',
            );
            await out.parent.create(recursive: true);
            await out.writeAsBytes(png!.buffer.asUint8List());
          });
          await unmount(tester);
        },
      );
    }
  }
}
