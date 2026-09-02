import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart'
    show OnboardingProgressBar, OnboardingWizardPage;
import 'package:fushi/utils.dart' show t;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel;

/// 全新安装里把新手引导**从头走到尾**：每一步只按「下一步」（焦点驱动，不点坐标），
/// 断言步数计数器逐步递增、进度条段数与总步数一致、没有任何异常，最后一页的
/// 「开始使用」关闭向导并把 `onboarding_completed` 写穿。
///
/// 每页停留一段时间，让 Windows 运行器（tool/run_windows_itest.ps1）的定时截图
/// 能拍到每一页的真实渲染——这是重写 UI 后唯一的真机像素证据来源。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('clean install: Next walks every onboarding step to the end', (
    WidgetTester tester,
  ) async {
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

      final appModel = await readyAppModel(tester);
      expect(appModel.onboardingCompleted, isFalse);
      await appModel.setExperimentalFocusNavigationEnabled(true);
      await tester.pump(const Duration(milliseconds: 500));

      final FocusDriver driver = FocusDriver(tester);
      final RegExp counter = RegExp(r'^(\d+) / (\d+)$');

      int lastIndex = 0;
      int? total;
      for (int guard = 0; guard < 20; guard++) {
        // 计数器是页脚那行「n / N」；它是步骤身份的可见真值。
        final Iterable<Text> texts = tester
            .widgetList<Text>(find.byType(Text))
            .where((Text w) => w.data != null && counter.hasMatch(w.data!));
        expect(texts, isNotEmpty, reason: 'step counter must be visible');
        final RegExpMatch m = counter.firstMatch(texts.first.data!)!;
        final int index = int.parse(m.group(1)!);
        final int count = int.parse(m.group(2)!);
        if (guard == 0) {
          expect(index, 1);
        } else {
          expect(index, lastIndex + 1, reason: 'Next must advance one step');
        }
        // 总步数只在功能选择页离开后可能变化（勾选决定序列）；其后必须恒定。
        if (index > 2) {
          total ??= count;
          expect(count, total);
        }
        final OnboardingProgressBar bar = tester.widget<OnboardingProgressBar>(
          find.byType(OnboardingProgressBar),
        );
        expect(bar.total, count);
        expect(bar.current, index - 1);
        expect(tester.takeException(), isNull, reason: 'step $index rendered');

        // 停留给运行器拍照。
        await tester.pump(const Duration(milliseconds: 1500));

        final bool isLast = index == count;
        final Finder next = find.text(
          isLast ? t.onboarding_action_start : t.onboarding_action_next,
        );
        expect(next, findsOneWidget);
        expect(
          await driver.focusWidget(next, maxSteps: 120),
          isTrue,
          reason: 'primary button must be reachable via focus on step $index',
        );
        await driver.activate();
        await tester.pump(const Duration(milliseconds: 400));
        lastIndex = index;
        if (isLast) break;
      }

      for (
        int i = 0;
        i < 80 && find.byType(OnboardingWizardPage).evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(OnboardingWizardPage), findsNothing);
      expect(appModel.onboardingCompleted, isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
