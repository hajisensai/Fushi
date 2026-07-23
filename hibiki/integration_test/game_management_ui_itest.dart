import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/pages/implementations/game_diagnostics_page.dart';
import 'package:hibiki/src/pages/implementations/home_game_page.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/pages/implementations/texthooker_page.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/utils.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('游戏库、捕获台与诊断页在真实 Windows 宿主中可达且会话保活', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    await runHibikiItest(
      label: 'game-management-ui',
      collectedErrors: errors,
      body: () async {
        TexthookerService.instance.clear();
        app.main();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final appModel = await readyAppModel(tester);
        UpdateChecker.cancelActiveCheck();
        await appModel.setUpdateNeverRemind(true);
        await appModel.setExperimentalFocusNavigationEnabled(true);
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(find.byType(HibikiFocusRoot), findsOneWidget);
        await windowManager.setSize(const Size(1440, 900));
        await tester.pump(const Duration(seconds: 2));

        expect(HomePage.debugSelectTab, isNotNull);
        HomePage.debugSelectTab!(HomeTab.games);
        await tester.pump(const Duration(seconds: 2));

        expect(find.byType(HomeGamePage), findsOneWidget);
        expect(find.byKey(HomeGamePage.libraryKey), findsOneWidget);
        // 顶部两张总览大卡已收敛为一条紧凑会话状态带（整条可点进入捕获工作台）。
        expect(find.byKey(HomeGamePage.captureStatusKey), findsOneWidget,
            reason: '库页顶部应是紧凑会话状态带');
        await _capture(tester, 'game-library');

        final FocusDriver driver = FocusDriver(tester);
        final Finder openCapture =
            find.widgetWithText(HibikiSelectableChip, t.game_capture_workbench);
        expect(openCapture, findsOneWidget);
        expect(
          find.descendant(
            of: openCapture,
            matching: find.byType(HibikiFocusTarget),
          ),
          findsOneWidget,
          reason: '游戏页签应在真 app 中注册 Hibiki 焦点目标',
        );
        expect(
          await _activateHibikiTarget(
            driver,
            openCapture,
            const HibikiFocusId('game-library-tab-capture'),
          ),
          isTrue,
          reason: '捕获工作台页头入口必须可由 Hibiki 确认动作激活',
        );
        await tester.pump(const Duration(seconds: 1));

        expect(find.byType(TexthookerPage), findsOneWidget);
        expect(find.byKey(HomeGamePage.monitorKey), findsOneWidget);
        await _capture(tester, 'game-capture-empty');

        final TexthookerLineEntry line = TexthookerService.instance.appendLine(
          '統合テスト台詞',
          source: TexthookerLineSource.websocket,
          sourceLabel: 'ws://localhost:6677',
        )!;
        await tester.pump(const Duration(seconds: 1));
        final Finder lineCard =
            find.byKey(ValueKey<String>('game-line-${line.id}'));
        expect(lineCard, findsOneWidget);
        expect(
          await _activateHibikiTarget(
            driver,
            lineCard,
            HibikiFocusId('game-line-${line.id}'),
          ),
          isTrue,
          reason: '一整条台词应只有一个稳定确认目标',
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('統合テスト台詞'), findsOneWidget,
            reason: 'Enter 选择台词后，右侧句音详情应显示完整句子');
        await _capture(tester, 'game-capture-line-selected');

        HomePage.debugSelectTab!(HomeTab.books);
        await tester.pump(const Duration(seconds: 1));
        HomePage.debugSelectTab!(HomeTab.games);
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(TexthookerPage), findsOneWidget,
            reason: '切换 Hibiki 一级模块后捕获工作台不应被销毁');
        expect(TexthookerService.instance.entries.single.id, line.id,
            reason: '捕获台词必须跨一级模块切换保活');
        await _capture(tester, 'game-capture-after-tab-switch');

        final Finder diagnosticsChip =
            find.widgetWithText(HibikiSelectableChip, t.game_diagnostics);
        expect(diagnosticsChip, findsOneWidget);
        expect(
          await _activateHibikiTarget(
            driver,
            diagnosticsChip,
            const HibikiFocusId('game-capture-tab-diagnostics'),
          ),
          isTrue,
          reason: '兼容性诊断入口必须可由 Hibiki 确认动作激活',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(GameDiagnosticsPage), findsOneWidget);
        expect(find.byKey(HomeGamePage.diagnosticsKey), findsOneWidget);
        await _capture(tester, 'game-diagnostics');
      },
    );
  });
}

Future<bool> _activateHibikiTarget(
  FocusDriver driver,
  Finder target,
  HibikiFocusId focusId,
) async {
  if (await _focusThroughHibiki(driver, target, focusId)) {
    await driver.activate();
    return true;
  }
  final Finder managedTarget = find.descendant(
    of: target,
    matching: find.byType(HibikiFocusTarget),
  );
  if (!_invokeActivateIntent(driver.tester, managedTarget)) return false;
  await driver.tester.pump(const Duration(milliseconds: 250));
  return true;
}

bool _invokeActivateIntent(WidgetTester tester, Finder managedTarget) {
  if (managedTarget.evaluate().length != 1) return false;
  const ActivateIntent intent = ActivateIntent();
  final BuildContext context = tester.element(managedTarget);
  final Action<ActivateIntent>? action =
      Actions.maybeFind<ActivateIntent>(context, intent: intent);
  if (action == null || !action.isEnabled(intent)) return false;
  Actions.invoke<ActivateIntent>(context, intent);
  return true;
}

Future<bool> _focusThroughHibiki(
  FocusDriver driver,
  Finder target,
  HibikiFocusId focusId,
) async {
  final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
    driver.tester.element(target),
  );
  if (controller.requestById(focusId)) {
    await driver.tester.pump(const Duration(milliseconds: 250));
    if (controller.activeId == focusId &&
        controller.primaryFocusIsManagedTarget) {
      return true;
    }
  }
  final Finder focusNodes = find.descendant(
    of: target,
    matching: find.byType(Focus),
  );
  for (final Element element in focusNodes.evaluate()) {
    final FocusNode? node = (element.widget as Focus).focusNode;
    if (node?.debugLabel != focusId.value) continue;
    node!.requestFocus();
    await driver.tester.pump(const Duration(milliseconds: 250));
    return FocusManager.instance.primaryFocus == node;
  }
  return false;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final ObserveShot shot = await captureFlutterFrame(tester, name);
  expect(shot.saved, isTrue, reason: '$name 应成功保存截图');
  expect(shot.nonBlank, isTrue,
      reason: '$name 不应是空白帧（${shot.path}, ${shot.bytes}B）');
  debugPrint('[game-management-ui] $name -> ${shot.path} (${shot.bytes}B)');
}
