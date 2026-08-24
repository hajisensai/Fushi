import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart'
    show OnboardingWizardPage;
import 'package:fushi/utils.dart' show t;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'clean install auto-opens onboarding and Skip persists completion',
    (WidgetTester tester) async {
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
        expect(
          find.byType(OnboardingWizardPage),
          findsOneWidget,
          reason: 'a real clean install must automatically push onboarding',
        );

        final appModel = await readyAppModel(tester);
        expect(
          appModel.onboardingCompleted,
          isFalse,
          reason:
              'first-install setup must persist the pending state before '
              'the wizard is shown',
        );
        await appModel.setExperimentalFocusNavigationEnabled(true);
        await tester.pump(const Duration(milliseconds: 500));

        final Finder skip = find.text(t.onboarding_action_skip);
        expect(skip, findsOneWidget);
        final FocusDriver driver = FocusDriver(tester);
        expect(
          await driver.focusWidget(skip, maxSteps: 80),
          isTrue,
          reason: 'Skip must be reachable through the real focus path',
        );
        await driver.activate();

        for (
          int i = 0;
          i < 80 && find.byType(OnboardingWizardPage).evaluate().isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(
          find.byType(OnboardingWizardPage),
          findsNothing,
          reason: 'Skip must close the startup wizard',
        );
        expect(
          appModel.onboardingCompleted,
          isTrue,
          reason: 'Skip must persist completion so the next launch stays home',
        );
        expect(find.byType(MaterialApp), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}
