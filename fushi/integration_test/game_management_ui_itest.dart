import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/test_app_launcher.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/pages/implementations/home_game_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi/utils.dart';
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
    await runFushiItest(
      label: 'game-management-ui',
      collectedErrors: errors,
      body: () async {
        TexthookerService.instance.clear();
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final appModel = await readyAppModel(tester);
        UpdateChecker.cancelActiveCheck();
        await appModel.setUpdateNeverRemind(true);
        await appModel.setExperimentalFocusNavigationEnabled(true);
        for (int i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(find.byType(FushiFocusRoot), findsOneWidget);
        await windowManager.setSize(const Size(1440, 900));
        await tester.pump(const Duration(seconds: 2));

        expect(HomePage.debugSelectTab, isNotNull);
        HomePage.debugSelectTab!(HomeTab.games);
        await tester.pump(const Duration(seconds: 2));

        expect(find.byType(HomeGamePage), findsOneWidget);
        expect(find.byKey(HomeGamePage.libraryKey), findsOneWidget);
        // 顶部两张总览大卡已收敛为一条紧凑会话状态带（整条可点进入捕获工作台）。
        expect(
          find.byKey(HomeGamePage.captureStatusKey),
          findsOneWidget,
          reason: '库页顶部应是紧凑会话状态带',
        );
        await _capture(tester, 'game-library');

        final FocusDriver driver = FocusDriver(tester);
        // 2026-10-30 起两级页签：一级「游戏库 / 发现」，「游戏库」组内的首页 /
        // 全部游戏 / 工作台 / 串流在顶栏下方的二级胶囊里（焦点前缀
        // game-subsection-tab）。
        expect(
          find.byType(FushiAdjustableSegmented<GameSection>),
          findsNWidgets(2),
          reason: '停在游戏库组：一级 + 二级各一份',
        );
        final Finder gameSections = _gameSubSections();
        expect(gameSections, findsOneWidget);
        expect(
          find.descendant(
            of: gameSections,
            matching: find.byType(FushiFocusTarget),
          ),
          findsOneWidget,
          reason: '游戏二级分段导航应在真 app 中注册单一 Fushi 焦点目标',
        );
        expect(
          await _focusThroughFushi(
            driver,
            gameSections,
            const FushiFocusId('game-subsection-tab-sections'),
          ),
          isTrue,
          reason: '游戏分段导航必须可由 Fushi 焦点系统聚焦',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
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
        final Finder lineCard = find.byKey(
          ValueKey<String>('game-line-${line.id}'),
        );
        expect(lineCard, findsOneWidget);
        expect(
          await _activateFushiTarget(
            driver,
            lineCard,
            FushiFocusId('game-line-${line.id}'),
          ),
          isTrue,
          reason: '一整条台词应只有一个稳定确认目标',
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.text('統合テスト台詞'),
          findsOneWidget,
          reason: 'Enter 选择台词后，右侧句音详情应显示完整句子',
        );
        await _capture(tester, 'game-capture-line-selected');

        HomePage.debugSelectTab!(HomeTab.books);
        await tester.pump(const Duration(seconds: 1));
        HomePage.debugSelectTab!(HomeTab.games);
        await tester.pump(const Duration(seconds: 1));
        expect(
          find.byType(TexthookerPage),
          findsOneWidget,
          reason: '切换 Fushi 一级模块后捕获工作台不应被销毁',
        );
        expect(
          TexthookerService.instance.entries.single.id,
          line.id,
          reason: '捕获台词必须跨一级模块切换保活',
        );
        await _capture(tester, 'game-capture-after-tab-switch');

        final Finder captureSections = _gameSubSections();
        expect(captureSections, findsOneWidget);
        expect(
          await _focusThroughFushi(
            driver,
            captureSections,
            const FushiFocusId('game-subsection-tab-sections'),
          ),
          isTrue,
          reason: '捕获页分段导航必须可由 Fushi 焦点系统聚焦',
        );
        // 诊断不设页签（从捕获工作台 / 全局设置进入）：二级胶囊里工作台的下一段
        // 是「串流」。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(seconds: 1));
        expect(gameSectionNotifier.value, GameSection.stream);
        expect(find.byKey(HomeGamePage.streamKey), findsOneWidget);
        await _capture(tester, 'game-stream');
      },
    );
  });
}

/// 「游戏库」组的二级胶囊（首页 / 全部游戏 / 工作台 / 串流）。
Finder _gameSubSections() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is FushiAdjustableSegmented<GameSection> &&
      widget.focusIdPrefix == 'game-subsection-tab',
);

Future<bool> _activateFushiTarget(
  FocusDriver driver,
  Finder target,
  FushiFocusId focusId,
) async {
  if (await _focusThroughFushi(driver, target, focusId)) {
    await driver.activate();
    return true;
  }
  final Finder managedTarget = find.descendant(
    of: target,
    matching: find.byType(FushiFocusTarget),
  );
  if (!_invokeActivateIntent(driver.tester, managedTarget)) return false;
  await driver.tester.pump(const Duration(milliseconds: 250));
  return true;
}

bool _invokeActivateIntent(WidgetTester tester, Finder managedTarget) {
  if (managedTarget.evaluate().length != 1) return false;
  const ActivateIntent intent = ActivateIntent();
  final BuildContext context = tester.element(managedTarget);
  final Action<ActivateIntent>? action = Actions.maybeFind<ActivateIntent>(
    context,
    intent: intent,
  );
  if (action == null || !action.isEnabled(intent)) return false;
  Actions.invoke<ActivateIntent>(context, intent);
  return true;
}

Future<bool> _focusThroughFushi(
  FocusDriver driver,
  Finder target,
  FushiFocusId focusId,
) async {
  final FushiFocusController controller = FushiFocusRoot.controllerOf(
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
  expect(
    shot.nonBlank,
    isTrue,
    reason: '$name 不应是空白帧（${shot.path}, ${shot.bytes}B）',
  );
  debugPrint('[game-management-ui] $name -> ${shot.path} (${shot.bytes}B)');
}
