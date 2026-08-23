import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

void main() {
  testWidgets(
    'automated widget binding does not auto-push onboarding over feature tests',
    (WidgetTester tester) async {
      expect(
        startupOnboardingAutoLaunchAllowed(onboardingCompleted: false),
        isFalse,
      );
    },
  );
}
