import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/utils.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app starts and initializes without crash',
      (WidgetTester tester) async {
    // 必须在 app.main() 之前置位：启动期自动更新检查是真实网络竞速，检查成功会
    // 弹「发现新版本」DialogRoute，其 ModalScope 抢走 primary focus，下方主导航
    // 的焦点断言随机失败（iOS 模拟器实测复现；home 首帧后再 cancelActiveCheck
    // 有不可消除的竞态窗口——scheduleCheck 经 post-frame 才登记中断令牌）。
    UpdateChecker.disableAutoCheckForTesting = true;
    // Capture FlutterError instead of letting it fail the test.
    // WebView renderer crashes on emulator trigger spurious errors.
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[test] FlutterError caught: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      // Wait for app initialization (up to 90s).
      // Look for Scaffold as the most basic sign of a rendered app.
      bool rendered = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byType(Scaffold).evaluate().isNotEmpty) {
          rendered = true;
          break;
        }
      }

      expect(rendered, isTrue,
          reason: 'App should render at least one Scaffold within 90 seconds');

      // ── 测试隔离（与 game_management_ui_itest 同范式）────────────────────
      // 等 home 真正就绪（主导航挂载）后打开「键盘/手柄焦点导航」实验开关——
      // 关闭（默认）时 Tab/Shift+Tab 被全局中和为 DoNothingIntent（TODO-112：
      // 用户裁定不开导航时按 Tab 不该有动作），焦点驱动断言只有开了开关才是
      // 真实可达性检验。更新检查已在 app.main() 之前整轮禁用（见文件头）。
      final bool homeReady = await waitForHome(tester);
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      await appModel.setExperimentalFocusNavigationEnabled(true);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final FocusDriver driver = FocusDriver(tester);

      // 焦点导航开关翻转后树已重建，此时再取导航目标。
      final List<Finder> navTargets = findPrimaryNavigationTargets();
      final HomeTab initialTab = homeShellTabNotifier.value;

      if (homeReady && navTargets.length >= 2) {
        final bool focusedTab1 = await driver.focusWidget(navTargets[1]);
        expect(focusedTab1, isTrue,
            reason: 'Second nav tab must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(seconds: 3));
        // 焦点驱动必须真的切走 tab——否则「可达」只是断言了个寂寞（此前
        // _focusOwns 对整页 key-sink 的误报正是这样把断言变成恒真的）。
        expect(homeShellTabNotifier.value, isNot(initialTab),
            reason: 'Activating the second nav tab must switch the home tab');

        final bool focusedTab0 = await driver.focusWidget(navTargets[0]);
        expect(focusedTab0, isTrue,
            reason: 'First nav tab must be reachable by focus');
        await driver.activate();
        await tester.pump(const Duration(seconds: 3));
        expect(homeShellTabNotifier.value, initialTab,
            reason: 'Activating the first nav tab must switch back');
      }

      // App survived without fatal crash
      expect(find.byType(Scaffold), findsWidgets);

      // Filter out known emulator-only errors (WebView renderer, chromium,
      // network timeouts) and fail on unexpected app-level errors.
      final List<FlutterErrorDetails> unexpectedErrors = errors.where((e) {
        final String msg = e.exceptionAsString().toLowerCase();
        if (msg.contains('webview') || msg.contains('chromium')) return false;
        if (msg.contains('renderer') && msg.contains('crash')) return false;
        if (msg.contains('socketexception')) return false;
        if (msg.contains('tls') || msg.contains('timeout')) return false;
        // 启动期其余网络调用（同步探测等）在离线/证书异常环境下的纯网络层
        // 失败属环境噪声（与 itest_startup_guard 同口径），不是 app 缺陷。
        if (msg.contains('httpexception') || msg.contains('clientexception')) {
          return false;
        }
        if (msg.contains('handshakeexception') || msg.contains('certificate')) {
          return false;
        }
        return true;
      }).toList();

      expect(unexpectedErrors, isEmpty,
          reason: 'App produced unexpected FlutterErrors: '
              '${unexpectedErrors.map((e) => e.exceptionAsString()).join('; ')}');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
