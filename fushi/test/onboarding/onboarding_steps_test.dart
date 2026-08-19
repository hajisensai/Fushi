import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';

void main() {
  group('onboardingStepSequence', () {
    test('empty selection yields fixed skeleton (no capability steps)', () {
      expect(
        onboardingStepSequence(
          selected: <OnboardingFeature>{},
          browserExtensionAvailable: true,
        ),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.fonts,
          OnboardingStepId.finish,
        ],
      );
    });

    test('extension guide step needs BOTH desktop platform and selection', () {
      final Set<OnboardingFeature> withExtension = <OnboardingFeature>{
        OnboardingFeature.browserExtension,
      };
      // 桌面 + 勾选 → 有引导步骤。
      expect(
        onboardingStepSequence(
          selected: withExtension,
          browserExtensionAvailable: true,
        ),
        contains(OnboardingStepId.browserExtension),
      );
      // 移动端即便勾选（不可能出现，但语义上）也没有该步骤。
      expect(
        onboardingStepSequence(
          selected: withExtension,
          browserExtensionAvailable: false,
        ),
        isNot(contains(OnboardingStepId.browserExtension)),
      );
      // 桌面但用户关掉了扩展模块 → 不引导安装。
      expect(
        onboardingStepSequence(
          selected: <OnboardingFeature>{},
          browserExtensionAvailable: true,
        ),
        isNot(contains(OnboardingStepId.browserExtension)),
      );
    });

    test('full selection yields all steps in fixed order', () {
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

    test('tab-only module features (books/manga/video/games) never add steps',
        () {
      final List<OnboardingStepId> withModules = onboardingStepSequence(
        selected: <OnboardingFeature>{
          OnboardingFeature.books,
          OnboardingFeature.manga,
          OnboardingFeature.video,
          OnboardingFeature.games,
        },
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
