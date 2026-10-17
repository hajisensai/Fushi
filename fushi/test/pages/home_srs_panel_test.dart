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
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/models/home_dashboard_panel.dart';
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
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
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

  group('resolveHomeSrsPanelVisible', () {
    bool resolve({
      bool module = true,
      HomeDashboardPanelMode mode = HomeDashboardPanelMode.auto,
      bool toReview = false,
      int? cards = 0,
    }) => resolveHomeSrsPanelVisible(
      moduleEnabled: module,
      mode: mode,
      miningToReview: toReview,
      totalCards: cards,
    );

    test('Anki 制卡、没有复习卡的存量用户：自动档不显示', () {
      expect(resolve(), isFalse);
      // 卡数还在加载：同样不显示（不闪出一栏）。
      expect(resolve(cards: null), isFalse);
    });

    test('在用复习：挖词目标 = 复习，或已有复习卡', () {
      expect(resolve(toReview: true), isTrue);
      expect(resolve(toReview: true, cards: null), isTrue);
      expect(resolve(cards: 3), isTrue);
    });

    test('复习模块关着：任何档位都不显示', () {
      for (final HomeDashboardPanelMode m in HomeDashboardPanelMode.values) {
        expect(
          resolve(module: false, mode: m, toReview: true, cards: 9),
          isFalse,
        );
      }
    });

    test('用户钉的档位优先于自动判据', () {
      expect(resolve(mode: HomeDashboardPanelMode.shown), isTrue);
      expect(
        resolve(mode: HomeDashboardPanelMode.hidden, toReview: true, cards: 9),
        isFalse,
      );
    });
  });

  group('HomeDashboardPanel 注册表持久化', () {
    test('auto 不落盘；未知 / 坏值回落 auto', () {
      expect(
        encodeHomeDashboardPanelModes(
          <HomeDashboardPanel, HomeDashboardPanelMode>{
            HomeDashboardPanel.srsReview: HomeDashboardPanelMode.auto,
          },
        ),
        '',
      );
      final String json = encodeHomeDashboardPanelModes(
        <HomeDashboardPanel, HomeDashboardPanelMode>{
          HomeDashboardPanel.srsReview: HomeDashboardPanelMode.hidden,
        },
      );
      expect(json, '{"srs_review":"hidden"}');
      expect(
        decodeHomeDashboardPanelModes(json)[HomeDashboardPanel.srsReview],
        HomeDashboardPanelMode.hidden,
      );
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

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    homeShellTabNotifier.value = HomeTab.home;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_srs_home');
    platformServices = testPlatformServices();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    store = await SrsDbStore.open(
      db: db,
      profileUid: _kProfile,
      deviceId: 'test-device',
      engine: null,
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

  Widget app(Widget home, {required bool apple}) => ProviderScope(
    overrides: overrides(),
    child: TranslationProvider(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme(apple: apple),
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

    testWidgets('$ds · 面板设置钉成隐藏：在用复习也不显示', (WidgetTester tester) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() async {
        await useSrs(target: SrsMiningTarget.srs);
        await addNote('食べる');
        await appModel.setHomeDashboardPanelMode(
          HomeDashboardPanel.srsReview,
          HomeDashboardPanelMode.hidden,
        );
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      expect(panel, findsNothing);
      await unmount(tester);
    });

    testWidgets('$ds · 计数与牌组列表顶层行之和一致（含子牌组）', (WidgetTester tester) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() async {
        await useSrs(target: SrsMiningTarget.srs);
        await addNote('食べる');
        await addNote('飲む');
        final String parent = await store.createDeck('漫画');
        final String child = await store.createDeck('一巻', parentId: parent);
        await addNote('走る', deckId: child);
      });
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await settle(tester);
      final SrsCountTriple home = tester.widget<SrsCountTriple>(
        find.descendant(of: panel, matching: find.byType(SrsCountTriple)),
      );

      // 牌组列表：顶层行上的三色计数（顶层已含子牌组）。
      final List<SrsDeckSummary> decks = (await tester.runAsync(
        store.deckSummaries,
      ))!;
      await unmount(tester);
      await tester.pumpWidget(app(const SrsDeckListPage(), apple: apple));
      await settle(tester);
      int sumNew = 0, sumLearn = 0, sumReview = 0;
      for (final SrsDeckSummary d in decks.where(
        (SrsDeckSummary d) => d.depth == 0,
      )) {
        final SrsCountTriple row = tester.widget<SrsCountTriple>(
          find.descendant(
            of: find.byKey(ValueKey<String>('srs-deck-${d.deck.id}')),
            matching: find.byType(SrsCountTriple),
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

    testWidgets('$ds · 点「开始复习」直接进复习页；点条目进牌组列表 tab', (
      WidgetTester tester,
    ) async {
      useSize(tester, const Size(420, 900));
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

    testWidgets('$ds · 计数加载中挂骨架，行高与加载完一致；制卡刷新信号后计数更新', (
      WidgetTester tester,
    ) async {
      useSize(tester, const Size(420, 900));
      await tester.runAsync(() => useSrs(target: SrsMiningTarget.srs));
      await tester.pumpWidget(app(dashboard(), apple: apple));
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
              find.descendant(of: panel, matching: find.byType(SrsCountTriple)),
            )
            .newCount,
        1,
      );
      expect(tester.getSize(panel).height, loadingHeight);
      await unmount(tester);
    });

    testWidgets('$ds · 窄列：骨架与「计数 + 开始」按可用宽度收窄，不溢出', (
      WidgetTester tester,
    ) async {
      // 计数位可用宽度远小于骨架两块的 84 + 88（首页窄列 / 小屏手机）。
      useSize(tester, const Size(240, 900));
      await tester.runAsync(() => useSrs(target: SrsMiningTarget.srs));
      await tester.runAsync(() => addNote('食べる'));
      await tester.pumpWidget(app(dashboard(), apple: apple));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('home-srs-panel-skeleton')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: '骨架溢出');
      await settle(tester);
      expect(start, findsOneWidget);
      expect(tester.takeException(), isNull, reason: '计数 + 开始按钮溢出');
      await unmount(tester);
    });
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
