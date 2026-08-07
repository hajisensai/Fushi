import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/galgame_home_page.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// 巡检 PR-1 焦点接线守卫：
/// 1. 游戏卡走 HibikiCard 注册 `game-card-<id>` 焦点站点，可被 requestById 聚焦、
///    Enter（ActivateIntent）触发启动路径（G1 根因修复回归守卫）；
/// 2. texthooker 线程选择器换共享手柄可进下拉后，`game-text-thread-selector`
///    focusId 在焦点系统注册（G3）；四页共用 GameSectionTabs 后分段条的单一
///    focusId 前缀不冲突且可聚焦。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TexthookerService.instance.clear();
  });
  tearDown(() => TexthookerService.instance.clear());

  testWidgets('game card registers focus target and Enter activates launch',
      (WidgetTester tester) async {
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_game_focus_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      // v54：游戏库真相源是 Drift 表，仓储绑 AppModel.database，测试必须注入。
      ..wireDatabaseForTesting(db);
    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'テスト永遠',
        exePath: r'Z:\definitely\missing\game.exe',
        workdir: r'Z:\definitely\missing',
        addedAt: DateTime(2026),
      ),
    ]);

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const HibikiFocusRoot(child: GamesLibraryPage()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('テスト永遠'), findsOneWidget);

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(GamesLibraryPage)),
    );
    expect(
      controller.requestById(const HibikiFocusId('game-card-g1')),
      isTrue,
      reason: '游戏卡必须注册 game-card-<id> 焦点站点（手柄/键盘可选中）',
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // Enter 触发 onTap → _launchGame：Windows 宿主上 exe 不存在提示缺文件，
    // 非 Windows 宿主提示平台不支持——两者都证明激活路径已接通。
    final Finder launchFeedback = find.byWidgetPredicate(
      (Widget w) =>
          w is Text &&
          (w.data == t.game_exe_missing || w.data == t.game_launch_unsupported),
    );
    expect(launchFeedback, findsOneWidget, reason: 'ActivateIntent 必须触发游戏启动路径');

    // 放掉桌面 toast 的自动消失计时器，避免测试尾部 pending timer。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'recent-played thumb registers focus target and Enter activates launch',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final HibikiDatabase db = HibikiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(db.close);
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_recent_focus_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      ..wireDatabaseForTesting(db);
    await appModel.setGalgames(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'Recent Game',
        exePath: r'Z:\definitely\missing\game.exe',
        workdir: r'Z:\definitely\missing',
        addedAt: DateTime(2026),
      ),
    ]);
    // 一段游玩会话 → lastPlayedMs>0 → Focus 卡渲染「最近玩过」缩略图条。
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

    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    HibikiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: Scaffold(
              body: HibikiFocusRoot(
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

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(GalgameHomePage)),
    );
    expect(
      controller.requestById(const HibikiFocusId('game-recent-g1')),
      isTrue,
      reason: '最近玩过缩略图必须注册 game-recent-<id> 焦点站点（TODO-1946 焦点缺口）',
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // Enter 触发 onTap → _launchGame：Windows 宿主提示缺 exe，非 Windows 宿主
    // 提示平台不支持——两者都证明 ActivateIntent 激活路径与点按一致。
    final Finder launchFeedback = find.byWidgetPredicate(
      (Widget w) =>
          w is Text &&
          (w.data == t.game_exe_missing || w.data == t.game_launch_unsupported),
    );
    expect(launchFeedback, findsOneWidget,
        reason: 'ActivateIntent 必须触发最近玩过缩略图的启动路径');

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('texthooker thread selector and section tabs register focus ids',
      (WidgetTester tester) async {
    TexthookerService.instance.appendLine(
      'テスト台詞',
      textThreadKey: 'luna:clean',
      textThreadLabel: 'SiglusEngine 0x2000',
      textHookCode: 'HS932@2000',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            // 线程选择器的焦点注册走 polled 平台（桌面）分支——Android 用引擎
            // 原生键事件的 stock DropdownMenu，不经 HibikiFocusRegistration。
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: HibikiFocusRoot(
                child: TexthookerPage(
                  embedded: true,
                  onShowLibrary: () {},
                  onShowDiagnostics: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(TexthookerPage)),
    );
    expect(
      controller.requestById(const HibikiFocusId('game-text-thread-selector')),
      isTrue,
      reason: '线程选择器换 GamepadMenuDropdown 后必须注册 focusId',
    );
    const String id = 'game-capture-tab-sections';
    expect(
      controller.requestById(const HibikiFocusId(id)),
      isTrue,
      reason: 'GameSectionTabs 收敛后 $id 必须保持注册',
    );
  });
}
