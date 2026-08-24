import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

void main() {
  testWidgets(
    'production onboarding gate depends only on the persisted completion state',
    (WidgetTester tester) async {
      expect(
        startupOnboardingAutoLaunchAllowed(onboardingCompleted: false),
        isTrue,
      );
      expect(
        startupOnboardingAutoLaunchAllowed(onboardingCompleted: true),
        isFalse,
      );
    },
  );
}
