import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart'
    show kRecommendedPackFileName, kRecommendedPackSizeLabel;
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart'
    show OnboardingWizardPage;
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_system.dart'
    show buildSystemDestination;
import 'package:fushi/utils.dart' show t;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel;

/// BUG-2097 真机回归：**在真 app 里**走用户报的那条路——新手引导里点下载推荐包，
/// 不等它下完就走下一步、直到走完整个引导——然后断言下载还活着。
///
/// 修复前这里必然红：下载器与 `CancelToken` 活在向导页的 State 上，向导一 pop
/// 就 `cancel()`，9.5 GB 静默断流且没有任何地方还看得见它。
///
/// 整条路径都是真的（真 `app.main()`、真向导、焦点驱动真按钮、真 controller、真
/// dispose），只有最外层的下载体换成替身——不然这条测试要真下 9.5 GB。
///
/// 运行（PowerShell，在 fushi/ 下）：
///   .\tool\run_windows_itest.ps1
///     integration_test\onboarding_pack_background_download_itest.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('推荐包下载不随新手引导关闭而被取消，且有常驻进度入口', (WidgetTester tester) async {
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    try {
      app.main();

      for (
        int i = 0;
        i < 120 && find.byType(OnboardingWizardPage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(OnboardingWizardPage), findsOneWidget);

      final AppModel appModel = await readyAppModel(tester);
      await appModel.setExperimentalFocusNavigationEnabled(true);
      await tester.pump(const Duration(milliseconds: 500));

      final RecommendedPackDownloadController controller =
          appModel.recommendedPackDownloadController;
      final Completer<File> finishDownload = Completer<File>();
      bool cancelledByApp = false;
      controller.runner =
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) {
            unawaited(
              cancelToken.whenCancel.then((DioError _) {
                cancelledByApp = true;
              }),
            );
            progress.value = 0.42;
            receivedBytes.value = 4 * 1024 * 1024 * 1024;
            return finishDownload.future;
          };

      final FocusDriver driver = FocusDriver(tester);
      final Finder downloadAction = find.text(
        '${t.onboarding_step_pack_download_action}'
        ' ($kRecommendedPackSizeLabel)',
      );

      // 1) 一路「下一步」走到推荐包那一步。
      bool reachedPackStep = false;
      for (int guard = 0; guard < 12 && !reachedPackStep; guard++) {
        if (downloadAction.evaluate().isNotEmpty) {
          reachedPackStep = true;
          break;
        }
        final Finder next = find.text(t.onboarding_action_next);
        expect(next, findsOneWidget, reason: '每一步都该有「下一步」');
        expect(await driver.focusWidget(next, maxSteps: 120), isTrue);
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(reachedPackStep, isTrue, reason: '走不到推荐包步骤');

      // 2) 焦点驱动点下「下载并导入」。
      expect(await driver.focusWidget(downloadAction, maxSteps: 160), isTrue);
      await driver.activate();
      for (int i = 0; i < 40 && !controller.isDownloading; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(controller.isDownloading, isTrue, reason: '下载没起来');

      // 进度与「可以走开」的说明都在这一步上可见。
      expect(find.textContaining('4.0 GB (42%)'), findsOneWidget);
      expect(
        find.text(t.onboarding_pack_download_background_hint),
        findsOneWidget,
      );

      // 3) 用户报的第一步：不等下完就走下一步。
      final Finder nextAfterDownload = find.text(t.onboarding_action_next);
      expect(nextAfterDownload, findsOneWidget);
      expect(
        await driver.focusWidget(nextAfterDownload, maxSteps: 160),
        isTrue,
      );
      await driver.activate();
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        controller.isDownloading,
        isTrue,
        reason: '走下一步就把下载掐了 —— BUG-2097 的一半',
      );

      // 4) 用户报的第二步：把整个引导走完（向导 pop → State dispose）。
      for (
        int guard = 0;
        guard < 20 && find.byType(OnboardingWizardPage).evaluate().isNotEmpty;
        guard++
      ) {
        final bool hasNext = find
            .text(t.onboarding_action_next)
            .evaluate()
            .isNotEmpty;
        final Finder primary = hasNext
            ? find.text(t.onboarding_action_next)
            : find.text(t.onboarding_action_start);
        if (primary.evaluate().isEmpty) break;
        expect(await driver.focusWidget(primary, maxSteps: 160), isTrue);
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 600));
      }
      for (
        int i = 0;
        i < 40 && find.byType(OnboardingWizardPage).evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(OnboardingWizardPage), findsNothing);
      expect(appModel.onboardingCompleted, isTrue);

      expect(
        cancelledByApp,
        isFalse,
        reason: '向导 dispose 取消了下载 —— 这正是 BUG-2097 的根因',
      );
      expect(
        controller.isDownloading,
        isTrue,
        reason: '走完引导后下载必须还活着（文案承诺的「后台下载」）',
      );

      // 5) 「后台在下」必须看得见：设置 → 系统里那一行报同一个任务的进度。
      final NavigatorState navigator = appModel.navigatorKey.currentState!;
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                SettingsDetailPage(destination: buildSystemDestination()),
          ),
        ),
      );
      for (
        int i = 0;
        i < 40 && find.byType(SettingsDetailPage).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(SettingsDetailPage), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text(t.onboarding_pack_status_downloading),
        findsOneWidget,
        reason: '设置里看不到它 = 「在后台跑」等于没跑',
      );
      expect(find.text('4.0 GB (42%)'), findsOneWidget);

      // 6) 下完之后停在「待导入」（导入要用户确认并重启进程，不自动按下去）。
      controller.packDir.createSync(recursive: true);
      final File packFile = File(
        '${controller.packDir.path}${Platform.pathSeparator}'
        '$kRecommendedPackFileName',
      );
      packFile.writeAsStringSync('pack');
      finishDownload.complete(packFile);
      for (int i = 0; i < 40 && !controller.hasPendingImport; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(controller.hasPendingImport, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(t.onboarding_pack_status_ready), findsOneWidget);
      expect(find.text(t.onboarding_pack_import_now), findsOneWidget);

      expect(tester.takeException(), isNull);

      // 收尾：别把测试用的假包留在磁盘上。
      if (packFile.existsSync()) packFile.deleteSync();
      controller.syncStageWithDisk();
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
