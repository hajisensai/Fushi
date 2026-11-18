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
import 'package:fushi/src/pages/implementations/games/galgame_home_blocks.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';

import '../helpers/test_platform_services.dart';

/// 游戏首页（仪表盘）widget 测试。
///
/// 默认外壳（无 [FushiShellTheme] 扩展）的库页布局是拼贴：走 2026-11 拼贴版
/// （首块 / 本周时长 / 游玩状态 / 继续块 / 随机推荐 / 时间线）；显式封面网格时
/// 走旧版式（四张 KPI + 继续 Spotlight）。数据经 in-memory Drift DB 注入
/// [AppModel]，与 game_module_focus_test 同款接线。交互一律焦点驱动（Enter）。
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
    tmpDir = Directory.systemTemp.createTempSync('fushi_game_home_');
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

  Future<void> pumpHome(
    WidgetTester tester,
    AppModel appModel, {
    ShellContentLayout? layout,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            theme: layout == null
                ? null
                : ThemeData(
                    extensions: <ThemeExtension<dynamic>>[
                      FushiShellTheme(contentLayout: layout),
                    ],
                  ),
            home: Scaffold(
              body: FushiFocusRoot(
                child: GalgameHomePage(
                  onShowLibrary: () {},
                  onShowMonitor: () {},
                  onShowDiagnostics: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  GalgameEntry game(String id, String name, {DateTime? addedAt}) =>
      GalgameEntry(
        id: id,
        name: name,
        exePath: 'Z:\\games\\$id.exe',
        workdir: r'Z:\games',
        addedAt: addedAt ?? DateTime(2026, 7, 20),
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

  testWidgets('collage: empty library shows the guide block', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    expect(find.byType(GalgameHomeEmpty), findsOneWidget);
    expect(find.text(t.game_empty), findsOneWidget);
    expect(find.text(t.library_view_import), findsOneWidget);
  });

  testWidgets('collage: hero, stat blocks and timeline render; no KPI tiles', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      game('g1', 'Recent Game'),
      game('g2', 'Second Game'),
    ]);
    await addSession(appModel, 'g1', Duration.zero);

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    expect(find.byType(GalgameHomeHeroBlock), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('games_home_hero_g1')),
      findsOneWidget,
    );
    expect(find.byType(GalgameWeekStatBlock), findsOneWidget);
    expect(find.byType(GalgameStatusStatBlock), findsOneWidget);
    expect(find.byType(GalgameTimelineBlock), findsOneWidget);
    // 四张 KPI 已合进统计块与页头副行，不再单独出现。
    expect(find.text(t.game_kpi_total_games), findsNothing);
    // 时间线保留「全部 / 游戏 / 新增」筛选。
    expect(find.text(t.home_filter_all), findsWidgets);
    expect(find.text(t.home_filter_game), findsWidgets);
    expect(find.text(t.home_filter_added), findsWidgets);
  });

  testWidgets('collage: hero focus + Enter takes the launch path', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[game('g1', 'Recent Game')]);
    await addSession(appModel, 'g1', Duration.zero);

    await pumpHome(tester, appModel);

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(GalgameHomePage)),
    );
    expect(
      controller.requestById(const FushiFocusId('game-dashboard-hero-g1')),
      isTrue,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // 点按 = 启动（不是进详情）：Windows 宿主提示缺 exe，其它宿主提示不支持。
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

  testWidgets('collage: continue blocks follow the hero, "+N" for the rest', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      for (int i = 0; i < 6; i++) game('g$i', 'Game $i'),
    ]);
    for (int i = 0; i < 6; i++) {
      await addSession(appModel, 'g$i', Duration(hours: i));
    }

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    // 首块 = 最近玩的 g0；继续区 = 接下来 3 个；其余 2 个进「+N」。
    expect(
      find.byKey(const ValueKey<String>('games_home_hero_g0')),
      findsOneWidget,
    );
    for (int i = 1; i <= 3; i++) {
      expect(
        find.byKey(ValueKey<String>('games_home_continue_g$i')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey<String>('games_home_continue_g4')),
      findsNothing,
    );
    final GalgameHomeMoreBlock more = tester.widget(
      find.byType(GalgameHomeMoreBlock),
    );
    expect(more.remaining, 2);
    // 继续块注册了焦点站点（手柄 / 键盘可达）。
    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is FushiFocusTarget &&
            w.id == const FushiFocusId('game-recent-g1'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('collage: hideNsfw keeps adult titles off the home page', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'adult',
        name: 'Adult Game',
        exePath: r'Z:\games\adult.exe',
        workdir: r'Z:\games',
        addedAt: DateTime(2026, 7, 20),
        // 成人向标记走用户覆盖层（`galgames.customDataJson`）：`setGalgames` 只写
        // galgames 自己的列，`metadata`（源快照合并结果，属 galgame_sources）不会
        // 落库，用它造夹具时重载后 isNsfw 恒为 false，测的就不是隐藏逻辑。
        customData: const GalgameCustomData(nsfw: true),
      ),
      game('safe', 'Safe Game'),
    ]);
    // 成人向条目是最近玩的：不隐藏时它会成为首块。
    await addSession(appModel, 'adult', Duration.zero);
    await addSession(appModel, 'safe', const Duration(hours: 2));
    await appModel.setGalgameLibraryView(
      const GalgameLibraryView(hideNsfw: true).encode(),
    );

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey<String>('games_home_hero_safe')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('games_home_hero_adult')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('games_home_random_adult')),
      findsNothing,
    );
    expect(find.text('Adult Game'), findsNothing);
  });

  testWidgets('grid layout keeps the classic KPI strip', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      game('g1', 'First Game'),
      game('g2', 'Second Game', addedAt: DateTime(2026, 7, 21)),
    ]);

    await pumpHome(tester, appModel, layout: ShellContentLayout.grid);

    expect(tester.takeException(), isNull);
    expect(find.text(t.game_kpi_total_games), findsOneWidget);
    expect(find.text(t.game_stat_total_time), findsOneWidget);
    expect(find.text(t.game_stat_today), findsOneWidget);
    expect(find.text(t.game_kpi_week), findsOneWidget);
    expect(find.byType(GalgameHomeHeroBlock), findsNothing);
  });
}
