import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';

void main() {
  group('onboardingStepSequence', () {
    test('empty selection yields fixed skeleton (desktop)', () {
      expect(
        onboardingStepSequence(
          selected: <OnboardingFeature>{},
          browserExtensionAvailable: true,
        ),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.browserExtension,
          OnboardingStepId.fonts,
          OnboardingStepId.finish,
        ],
      );
    });

    test('mobile skeleton drops the browser-extension step', () {
      expect(
        onboardingStepSequence(
          selected: <OnboardingFeature>{},
          browserExtensionAvailable: false,
        ),
        isNot(contains(OnboardingStepId.browserExtension)),
      );
    });

    test('full capability selection yields all steps in fixed order', () {
      expect(
        onboardingStepSequence(
          selected: OnboardingFeature.values.toSet(),
          browserExtensionAvailable: true,
        ),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.recommendedPack,
          OnboardingStepId.anki,
          OnboardingStepId.backup,
          OnboardingStepId.interconnect,
          OnboardingStepId.browserExtension,
          OnboardingStepId.fonts,
          OnboardingStepId.finish,
        ],
      );
    });

    test('module features (manga/video/games) never add steps', () {
      final List<OnboardingStepId> withModules = onboardingStepSequence(
        selected: kOnboardingModuleFeatures,
        browserExtensionAvailable: false,
      );
      final List<OnboardingStepId> without = onboardingStepSequence(
        selected: <OnboardingFeature>{},
        browserExtensionAvailable: false,
      );
      expect(withModules, without);
    });

    test('each capability maps to exactly its own step', () {
      const Map<OnboardingFeature, OnboardingStepId> capabilitySteps =
          <OnboardingFeature, OnboardingStepId>{
        OnboardingFeature.recommendedPack: OnboardingStepId.recommendedPack,
        OnboardingFeature.anki: OnboardingStepId.anki,
        OnboardingFeature.backup: OnboardingStepId.backup,
        OnboardingFeature.interconnect: OnboardingStepId.interconnect,
      };
      capabilitySteps
          .forEach((OnboardingFeature feature, OnboardingStepId step) {
        final List<OnboardingStepId> steps = onboardingStepSequence(
          selected: <OnboardingFeature>{feature},
          browserExtensionAvailable: false,
        );
        expect(steps, contains(step), reason: '$feature 应产生 $step');
        expect(steps, hasLength(5), reason: '$feature 应只追加一个配置步骤');
      });
    });
  });
}
