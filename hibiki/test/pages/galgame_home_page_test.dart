import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/galgame_home_page.dart';
import 'package:hibiki/utils.dart';

import '../helpers/test_platform_services.dart';

/// 游戏首页（仪表盘）widget 测试：KPI 渲染 / 空态 / 有游戏时 Focus 卡渲染。
///
/// 数据经 in-memory Drift DB 注入 [AppModel]（与 game_module_focus_test 同款测试
/// 接线），首页读仓储 + 会话聚合现算，不建投影表。
void main() {
  late Directory tmpDir;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// 构造一个接好 in-memory DB + 偏好的 [AppModel]。
  Future<AppModel> buildAppModel(WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    tmpDir = Directory.systemTemp.createTempSync('hibiki_game_home_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    return AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      ..wireDatabaseForTesting(db);
  }

  Future<void> pumpHome(WidgetTester tester, AppModel appModel) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: GalgameHomePage(
                onShowLibrary: () {},
                onShowMonitor: () {},
                onShowDiagnostics: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty library shows the empty state',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    expect(find.text(t.game_empty), findsOneWidget);
  });

  testWidgets('KPI strip renders total games and labels',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'First Game',
        exePath: r'Z:\games\g1.exe',
        workdir: r'Z:\games',
        addedAt: DateTime(2026, 7, 20),
      ),
      GalgameEntry(
        id: 'g2',
        name: 'Second Game',
        exePath: r'Z:\games\g2.exe',
        workdir: r'Z:\games',
        addedAt: DateTime(2026, 7, 21),
      ),
    ]);

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    // KPI 标签四格。
    expect(find.text(t.game_kpi_total_games), findsOneWidget);
    expect(find.text(t.game_stat_total_time), findsOneWidget);
    expect(find.text(t.game_stat_today), findsOneWidget);
    expect(find.text(t.game_kpi_week), findsOneWidget);
    // 总游戏数值。
    expect(find.text('2'), findsWidgets);
  });

  testWidgets('Focus card renders for the most recently played game',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AppModel appModel = await buildAppModel(tester);
    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'Recent Game',
        exePath: r'Z:\games\g1.exe',
        workdir: r'Z:\games',
        addedAt: DateTime(2026, 7, 20),
      ),
    ]);
    // 一段游玩会话 → getGalgamePlayTotals 给出 lastPlayedMs>0，Focus 卡「继续游戏」。
    final DateTime now = DateTime.now();
    await appModel.database.insertGalgameSession(
      GalgameSessionsCompanion.insert(
        gameId: 'g1',
        startMs: now.millisecondsSinceEpoch - 600000,
        endMs: now.millisecondsSinceEpoch,
        durationSeconds: 600,
        dateKey: HibikiTimeFormat.dayKey(now),
      ),
    );

    await pumpHome(tester, appModel);

    expect(tester.takeException(), isNull);
    // Focus 卡标题（游戏名，出现在卡片 + 时间线）。
    expect(find.text('Recent Game'), findsWidgets);
    // 已游玩过 → 状态胶囊「继续游戏」，启动按钮「启动」。
    expect(find.text(t.game_focus_continue), findsOneWidget);
    expect(find.text(t.game_launch), findsWidgets);
    // 时间线区块标题。
    expect(find.text(t.home_activity), findsOneWidget);
  });
}
