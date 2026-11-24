import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_library_query.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_merge.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/galgame_home_page.dart';
import 'package:fushi/src/pages/implementations/games/apple/apple_galgame_home.dart';
import 'package:fushi/src/pages/implementations/games/apple/apple_galgame_home_widgets.dart';
import 'package:fushi/src/pages/implementations/games/galgame_home_blocks.dart';
import 'package:fushi/src/pages/implementations/stat_dashboard.dart'
    show StatKpiTile;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/apple/apple_bar_chart.dart'
    show AppleBarChart;
import 'package:fushi/src/utils/components/fushi_continue_hero.dart'
    show FushiContinueSpotlight;
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';

import '../../helpers/test_platform_services.dart';

/// 游戏首页 Apple（Cupertino，iOS 27 / macOS 27）版面（方案 A「货架式」）。
///
/// Apple 档只有一种版面（拼贴 / 封面网格偏好都落到 [AppleGalgameHome]），顺序
/// 副行 → 继续大卡 → 最近玩过 → 本周 → 游玩状态 → 今天玩这个？ → 动态；交互一律
/// 焦点驱动（requestById + Enter / 方向键）。
void main() {
  late Directory tmpDir;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppModel> buildAppModel(WidgetTester tester) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    tmpDir = Directory.systemTemp.createTempSync('fushi_game_home_apple_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    return AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..wireDatabaseForTesting(db);
  }

  Widget host(
    AppModel appModel, {
    ShellContentLayout? layout,
    VoidCallback? onShowLibrary,
  }) {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    return ProviderScope(
      overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          theme: ThemeData(
            extensions: <ThemeExtension<dynamic>>[
              if (layout != null) FushiShellTheme(contentLayout: layout),
              const FushiGlassTheme(FushiGlassMaterial.off, glassDesign: true),
            ],
          ),
          home: Scaffold(
            body: FushiFocusRoot(
              child: GalgameHomePage(
                onShowLibrary: onShowLibrary ?? () {},
                onShowMonitor: () {},
                onShowDiagnostics: () {},
              ),
            ),
          ),
        ),
      ),
    );
  }

  GalgameEntry game(String id, String name) => GalgameEntry(
    id: id,
    name: name,
    exePath: 'Z:\\games\\$id.exe',
    workdir: r'Z:\games',
    addedAt: DateTime(2026, 7, 20),
  );

  Future<void> addSession(AppModel appModel, String id, Duration ago) async {
    final DateTime end = DateTime.now().subtract(ago);
    await appModel.database.insertGalgameSession(
      GalgameSessionsCompanion.insert(
        gameId: id,
        startMs: end.millisecondsSinceEpoch - 600000,
        endMs: end.millisecondsSinceEpoch,
        durationSeconds: 600,
        dateKey: FushiTimeFormat.dayKey(end),
      ),
    );
  }

  Future<AppModel> seeded(WidgetTester tester, {int count = 4}) async {
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      for (int i = 0; i < count; i++) game('g$i', 'Game $i'),
    ]);
    for (int i = 0; i < count; i++) {
      await addSession(appModel, 'g$i', Duration(hours: i));
    }
    return appModel;
  }

  void expectNoCollageParts() {
    expect(find.byType(GalgameHomeHeroBlock), findsNothing);
    expect(find.byType(GalgameHomeGameBlock), findsNothing);
    expect(find.byType(GalgameWeekStatBlock), findsNothing);
    expect(find.byType(GalgameStatusStatBlock), findsNothing);
    expect(find.byType(GalgameHomeMoreBlock), findsNothing);
    expect(find.byType(GalgameTimelineBlock), findsNothing);
    expect(find.byType(GalgameHomeGrid), findsNothing);
    expect(find.byType(StatKpiTile), findsNothing);
    expect(find.byType(FushiContinueSpotlight), findsNothing);
  }

  testWidgets('iOS tier: sections run summary → hero → recent → week → '
      'status → random → activity', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await seeded(tester);

    await tester.pumpWidget(host(appModel));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AppleGalgameHome), findsOneWidget);
    final List<Key> order = <Key>[
      AppleGalgameHome.summaryKey,
      AppleGalgameHome.heroKey,
      AppleGalgameHome.recentKey,
      AppleGalgameHome.weekKey,
      AppleGalgameHome.statusKey,
      AppleGalgameHome.randomKey,
      AppleGalgameHome.activityKey,
    ];
    double last = double.negativeInfinity;
    for (final Key key in order) {
      expect(find.byKey(key), findsOneWidget, reason: '$key');
      final double top = tester.getTopLeft(find.byKey(key)).dy;
      expect(top, greaterThan(last), reason: '$key 不在上一段之下');
      last = top;
    }
    // 首卡 = 最近玩的 g0；货架是其余 3 个（不含首卡）。
    expect(
      find.byKey(const ValueKey<String>('games_home_hero_g0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('games_home_continue_g0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('games_home_continue_g1')),
      findsOneWidget,
    );
    // 首卡带「查看详情」与「⋯」；随机段头带「换一个」。
    expect(find.byKey(AppleGalgameHeroCard.detailKey), findsOneWidget);
    expect(find.byKey(AppleGalgameHeroCard.moreKey), findsOneWidget);
    expect(find.byKey(AppleGalgameHeroCard.launchKey), findsOneWidget);
    expect(find.byKey(AppleGalgameHome.rerollKey), findsOneWidget);
    // 本周有游玩：完整柱图卡（共享 AppleBarChart），不是紧凑形态。
    expect(find.byType(AppleGalgameWeekCard), findsOneWidget);
    expect(find.byType(AppleBarChart), findsOneWidget);
    expect(find.byKey(AppleGalgameWeekCard.compactKey), findsNothing);
    // 「游玩状态」只列有游戏的档：夹具全是「未设置」，只有一行。
    for (final GalgamePlayStatus s in GalgamePlayStatus.values) {
      expect(
        find.byKey(ValueKey<String>('apple-galgame-status-${s.name}')),
        s == GalgamePlayStatus.unset ? findsOneWidget : findsNothing,
      );
    }
    expect(find.byType(AppleGalgameTimelineRow), findsWidgets);
    expectNoCollageParts();
  });

  for (final ShellContentLayout? layout in <ShellContentLayout?>[
    null,
    ShellContentLayout.grid,
  ]) {
    testWidgets('one Apple layout regardless of the '
        '${layout == null ? 'collage' : 'grid'} preference', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final AppModel appModel = await seeded(tester);

      await tester.pumpWidget(host(appModel, layout: layout));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AppleGalgameHome), findsOneWidget);
      expect(find.byType(AppleGalgameHeroCard), findsOneWidget);
      expect(find.byKey(AppleGalgameHome.recentKey), findsOneWidget);
      expectNoCollageParts();
    });
  }

  testWidgets('first load shows the Apple skeleton, empty library the shared '
      'empty state', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);

    await tester.pumpWidget(host(appModel));
    // 仓储还没读完：骨架，不是空态。
    expect(find.byKey(AppleGalgameHomeSkeleton.skeletonKey), findsOneWidget);
    expect(find.byType(GalgameHomeEmpty), findsNothing);

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(AppleGalgameHomeSkeleton.skeletonKey), findsNothing);
    expect(find.byType(GalgameHomeEmpty), findsOneWidget);
    expect(find.byKey(GalgameHomeEmpty.importKey), findsOneWidget);
    expect(find.byType(AppleGalgameHome), findsNothing);
  });

  testWidgets('hero focus + Enter takes the launch path', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await seeded(tester, count: 1);

    await tester.pumpWidget(host(appModel));
    await tester.pumpAndSettle();

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(GalgameHomePage)),
    );
    expect(
      controller.requestById(const FushiFocusId('game-dashboard-hero-g0')),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // 点卡 = 启动（与 M3E 一致）：Windows 宿主提示缺 exe，其它宿主提示不支持。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Text &&
            (w.data == t.game_exe_missing ||
                w.data == t.game_launch_unsupported),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('shelf tiles are focus stops; arrow keys move between them and '
      'a status row + Enter opens the library', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int libraryOpened = 0;
    final AppModel appModel = await seeded(tester);

    await tester.pumpWidget(
      host(appModel, onShowLibrary: () => libraryOpened++),
    );
    await tester.pumpAndSettle();

    for (int i = 1; i <= 3; i++) {
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is FushiFocusTarget && w.id == FushiFocusId('game-recent-g$i'),
        ),
        findsOneWidget,
      );
    }
    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(GalgameHomePage)),
    );
    expect(
      controller.requestById(const FushiFocusId('game-recent-g1')),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(controller.activeId, const FushiFocusId('game-recent-g2'));

    expect(
      controller.requestById(const FushiFocusId('game-dashboard-status-unset')),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(libraryOpened, 1);
  });

  testWidgets('hideNsfw keeps adult titles off the Apple home page', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'adult',
        name: 'Adult Game',
        exePath: r'Z:\games\adult.exe',
        workdir: r'Z:\games',
        addedAt: DateTime(2026, 7, 20),
        customData: const GalgameCustomData(nsfw: true),
      ),
      game('safe', 'Safe Game'),
    ]);
    await addSession(appModel, 'adult', Duration.zero);
    await addSession(appModel, 'safe', const Duration(hours: 2));
    await appModel.setGalgameLibraryView(
      const GalgameLibraryView(hideNsfw: true).encode(),
    );

    await tester.pumpWidget(host(appModel));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('games_home_hero_safe')),
      findsOneWidget,
    );
    expect(find.text('Adult Game'), findsNothing);
  });

  testWidgets('sparse data: no play this week gives the compact week card; '
      'wide window caps and centres the content', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(2000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      game('g0', 'Game 0'),
      game('g1', 'Game 1'),
    ]);
    // 只有两周前的游玩：本周为 0。
    await addSession(appModel, 'g0', const Duration(days: 14));

    await tester.pumpWidget(host(appModel));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(AppleGalgameWeekCard.compactKey), findsOneWidget);
    expect(find.byType(AppleBarChart), findsNothing);
    // 限宽居中：首卡左缘离窗口左缘 ≥ (2000 − 1180) / 2。
    final Rect hero = tester.getRect(find.byKey(AppleGalgameHome.heroKey));
    expect(hero.left, greaterThanOrEqualTo((2000 - 1180) / 2 - 1));
    expect(hero.right, lessThan(2000 - (2000 - 1180) / 2 + 1));
  });
}
