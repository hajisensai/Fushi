import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart'
    show kRecommendedPackSizeLabel;
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_prompt.dart';
import 'package:fushi/src/onboarding/recommended_pack_tutorial_state.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/utils.dart' show t;

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'helpers/library_fixture.dart' show readyAppModel;

/// PR1276 follow-up: real Windows app, controller, disk receipts and prompt.
/// Only the download body is replaced. No archive parsing, backup restore,
/// dictionary import or process restart is performed.
///
/// Run from fushi/ using tool/run_windows_itest.ps1 with this target. A fresh
/// isolated runner is mandatory; the existing background-download test retains
/// coverage of completing the download after the initial wizard is disposed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('下载完成不打断仍挂载的向导；导入后提示可跳过或直达查词教程', (WidgetTester tester) async {
    const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
    expect(Platform.isWindows, isTrue, reason: '请使用 Windows 隔离 runner');
    expect(testRoot, isNotEmpty, reason: '禁止在用户真实 app 数据目录运行');
    expect(
      Platform.environment['FUSHI_TEST_ROOT'],
      testRoot,
      reason: '需要 run_windows_itest.ps1 的运行时与构建时隔离配置',
    );

    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    RecommendedPackDownloadController? downloadController;
    File? fixturePack;
    Directory? skipFixture;
    try {
      app.main();
      await _waitFor(
        tester,
        () => find.byType(OnboardingWizardPage).evaluate().isNotEmpty,
      );
      expect(find.byType(OnboardingWizardPage), findsOneWidget);
      final AppModel appModel = await readyAppModel(tester);
      expect(
        p.isWithin(
          p.normalize(testRoot),
          p.normalize(appModel.appDirectory.absolute.path),
        ),
        isTrue,
        reason: '所有偏好、包文件和教程收据必须位于 runner 隔离根内',
      );
      await appModel.setExperimentalFocusNavigationEnabled(true);
      await tester.pump(const Duration(milliseconds: 500));
      final FocusDriver driver = FocusDriver(tester);
      final RecommendedPackDownloadController controller =
          appModel.recommendedPackDownloadController;
      downloadController = controller;
      final RecommendedPackTutorialState tutorialState =
          RecommendedPackTutorialState(appModel.appDirectory);
      expect(await tutorialState.shouldPrompt, isFalse);

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

      final Finder downloadAction = find.text(
        '${t.onboarding_step_pack_download_action}'
        ' ($kRecommendedPackSizeLabel)',
      );
      for (
        int step = 0;
        step < 12 && downloadAction.evaluate().isEmpty;
        step++
      ) {
        await _activate(driver, find.text(t.onboarding_action_next));
      }
      expect(downloadAction, findsOneWidget);
      await _activate(driver, downloadAction);
      await _waitFor(tester, () => controller.isDownloading);
      expect(controller.isDownloading, isTrue);
      await _activate(driver, find.text(t.onboarding_action_next));
      expect(downloadAction, findsNothing);
      final Element mountedWizard = tester.element(
        find.byType(OnboardingWizardPage),
      );
      final ModalRoute<dynamic> laterStepRoute = ModalRoute.of(mountedWizard)!;
      expect(laterStepRoute.isCurrent, isTrue);
      expect(find.byType(Dialog), findsNothing);

      // Complete while the original awaiting download handler is still mounted,
      // but the user is already on a later step. A fake file is deliberately not
      // a usable backup: this test never activates an import action.
      expect(controller.packFile.existsSync(), isFalse);
      controller.packDir.createSync(recursive: true);
      fixturePack = controller.packFile;
      fixturePack.writeAsStringSync('integration-test download body');
      finishDownload.complete(fixturePack);
      await _waitFor(tester, () => controller.hasPendingImport);
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.hasPendingImport, isTrue);
      expect(cancelledByApp, isFalse);
      expect(
        find.text(t.onboarding_pack_download_ready_notice),
        findsOneWidget,
      );
      expect(tester.element(find.byType(OnboardingWizardPage)), mountedWizard);
      expect(laterStepRoute.isCurrent, isTrue, reason: '下载完成不得自动打开备份导入流程');
      expect(find.byType(Dialog), findsNothing);
      expect(find.text(t.backup_import_confirm_title), findsNothing);
      expect(
        await tutorialState.shouldPrompt,
        isFalse,
        reason: '仅下载成功不能当作导入成功',
      );
      expect(tester.takeException(), isNull);

      // Leave through a real button without completing the operation tutorials.
      await _activate(driver, find.text(t.onboarding_action_skip));
      await _waitFor(
        tester,
        () => find.byType(OnboardingWizardPage).evaluate().isEmpty,
      );
      expect(find.byType(OnboardingWizardPage), findsNothing);
      expect(appModel.onboardingCompleted, isTrue);
      expect(controller.hasPendingImport, isTrue);
      final Finder importAction = find.text(t.onboarding_pack_import_now);
      expect(importAction, findsOneWidget);
      expect(
        await driver.focusWidget(importAction, maxSteps: 160),
        isTrue,
        reason: '完成提示必须留下键盘可达的显式导入入口',
      );
      expect(find.byType(Dialog), findsNothing);

      // Seed only the durable success receipt, via the production API. This is
      // the boundary after a successful restore, not a simulated full restore.
      await tutorialState.markImportSucceeded();
      expect(
        await RecommendedPackTutorialState(appModel.appDirectory).shouldPrompt,
        isTrue,
      );
      final NavigatorState navigator = appModel.navigatorKey.currentState!;
      Future<void> startTutorial() async {
        await navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const OnboardingWizardPage(tutorialOnly: true),
          ),
        );
      }

      if (!navigator.mounted) {
        throw TestFailure('教程开始提示前 Navigator 已卸载');
      }
      final Future<bool> offered = showRecommendedPackTutorialPrompt(
        context: navigator.context,
        state: tutorialState,
        onStart: startTutorial,
      );
      await _waitFor(
        tester,
        () => find
            .byKey(const ValueKey<String>('pack_tutorial_start'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text(t.onboarding_pack_tutorial_ready), findsOneWidget);
      final ObserveShot readyShot = await captureFlutterFrame(
        tester,
        'observe-pack-tutorial-ready',
      );
      expect(readyShot.saved && readyShot.nonBlank, isTrue);
      await _activate(
        driver,
        find.byKey(const ValueKey<String>('pack_tutorial_start')),
      );
      await _waitFor(
        tester,
        () => find.byType(OnboardingWizardPage).evaluate().isNotEmpty,
      );
      expect(
        tester
            .widget<OnboardingWizardPage>(find.byType(OnboardingWizardPage))
            .tutorialOnly,
        isTrue,
      );
      expect(find.text(t.onboarding_step_click_lookup_title), findsOneWidget);
      final ObserveShot tutorialShot = await captureFlutterFrame(
        tester,
        'observe-pack-lookup-tutorial',
      );
      expect(tutorialShot.saved && tutorialShot.nonBlank, isTrue);
      expect(downloadAction, findsNothing);

      // Complete only explanatory tutorial steps, without opening lookup/Anki.
      for (
        int step = 0;
        step < 5 && find.byType(OnboardingWizardPage).evaluate().isNotEmpty;
        step++
      ) {
        final Finder next = find.text(t.onboarding_action_next);
        await _activate(
          driver,
          next.evaluate().isNotEmpty
              ? next
              : find.text(t.onboarding_action_start),
        );
      }
      expect(find.byType(OnboardingWizardPage), findsNothing);
      expect(await offered, isTrue);
      await tutorialState.markImportSucceeded();
      expect(
        await RecommendedPackTutorialState(appModel.appDirectory).shouldPrompt,
        isFalse,
      );

      // A separate receipt directory represents a user who chooses Skip. The
      // helper, dialog and focus actions remain the real production ones.
      skipFixture = await Directory(testRoot).createTemp('pack-tutorial-skip-');
      final RecommendedPackTutorialState skipState =
          RecommendedPackTutorialState(skipFixture);
      await skipState.markImportSucceeded();
      if (!navigator.mounted) {
        throw TestFailure('教程跳过提示前 Navigator 已卸载');
      }
      final Future<bool> skipped = showRecommendedPackTutorialPrompt(
        context: navigator.context,
        state: skipState,
        onStart: startTutorial,
      );
      await _waitFor(
        tester,
        () => find
            .byKey(const ValueKey<String>('pack_tutorial_skip'))
            .evaluate()
            .isNotEmpty,
      );
      await _activate(
        driver,
        find.byKey(const ValueKey<String>('pack_tutorial_skip')),
      );
      expect(await skipped, isTrue);
      expect(find.byType(OnboardingWizardPage), findsNothing);
      await skipState.markImportSucceeded();
      final RecommendedPackTutorialState reopenedSkipState =
          RecommendedPackTutorialState(skipFixture);
      expect(await reopenedSkipState.shouldPrompt, isFalse);
      if (!navigator.mounted) {
        throw TestFailure('验证教程不重复提示前 Navigator 已卸载');
      }
      expect(
        await showRecommendedPackTutorialPrompt(
          context: navigator.context,
          state: reopenedSkipState,
          onStart: startTutorial,
        ),
        isFalse,
      );
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      downloadController?.runner = null;
      if (fixturePack?.existsSync() ?? false) fixturePack!.deleteSync();
      downloadController?.syncStageWithDisk();
      if (skipFixture != null && skipFixture.existsSync()) {
        skipFixture.deleteSync(recursive: true);
      }
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _activate(FocusDriver driver, Finder target) async {
  expect(target, findsOneWidget);
  expect(await driver.focusWidget(target, maxSteps: 160), isTrue);
  await driver.activate();
  await driver.tester.pump(const Duration(milliseconds: 600));
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (int frame = 0; frame < 120 && !ready(); frame++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(ready(), isTrue, reason: '等待真实 app 状态超时');
}
