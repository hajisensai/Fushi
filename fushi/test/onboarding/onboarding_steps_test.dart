import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';

List<OnboardingStepId> _steps(
  Set<OnboardingFeature> selected, {
  bool browserExtensionAvailable = false,
  bool globalLookupAvailable = false,
  bool ankiReady = false,
}) =>
    onboardingStepSequence(
      selected: selected,
      browserExtensionAvailable: browserExtensionAvailable,
      globalLookupAvailable: globalLookupAvailable,
      ankiReady: ankiReady,
    );

void main() {
  group('onboardingStepSequence', () {
    test('resource preparation stays exactly one-of-two', () {
      final Set<OnboardingFeature> manual = toggleOnboardingFeature(
        selected: <OnboardingFeature>{
          OnboardingFeature.recommendedPack,
          OnboardingFeature.anki,
        },
        feature: OnboardingFeature.manualResources,
      );
      expect(manual, contains(OnboardingFeature.manualResources));
      expect(manual, isNot(contains(OnboardingFeature.recommendedPack)));
      expect(manual, contains(OnboardingFeature.anki));

      final Set<OnboardingFeature> stillManual = toggleOnboardingFeature(
        selected: manual,
        feature: OnboardingFeature.manualResources,
      );
      expect(
        stillManual.intersection(kOnboardingResourceFeatures),
        <OnboardingFeature>{OnboardingFeature.manualResources},
      );
    });

    test('first card readiness rejects cached or stale Anki selections', () {
      expect(
        onboardingAnkiSelectionReady(
          connectionVerified: false,
          selectedDeckId: 1,
          selectedNoteTypeId: 2,
          availableDeckIds: <int>[1],
          availableNoteTypeIds: <int>[2],
        ),
        isFalse,
      );
      expect(
        onboardingAnkiSelectionReady(
          connectionVerified: true,
          selectedDeckId: 999,
          selectedNoteTypeId: 2,
          availableDeckIds: <int>[1],
          availableNoteTypeIds: <int>[2],
        ),
        isFalse,
      );
      expect(
        onboardingAnkiSelectionReady(
          connectionVerified: true,
          selectedDeckId: 1,
          selectedNoteTypeId: 2,
          availableDeckIds: <int>[1],
          availableNoteTypeIds: <int>[2],
        ),
        isTrue,
      );
    });

    test('empty selection yields fixed skeleton without lookup tutorials', () {
      expect(
        _steps(<OnboardingFeature>{}),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.fonts,
          OnboardingStepId.finish,
        ],
      );
    });

    test('extension guide needs both desktop capability and selection', () {
      final Set<OnboardingFeature> selected = <OnboardingFeature>{
        OnboardingFeature.browserExtension,
      };
      expect(
        _steps(selected, browserExtensionAvailable: true),
        contains(OnboardingStepId.browserExtension),
      );
      expect(
        _steps(selected),
        isNot(contains(OnboardingStepId.browserExtension)),
      );
    });

    test('recommended pack unlocks lookup tutorials', () {
      final List<OnboardingStepId> result = _steps(
        <OnboardingFeature>{OnboardingFeature.recommendedPack},
        globalLookupAvailable: true,
      );
      expect(
        result,
        containsAllInOrder(<OnboardingStepId>[
          OnboardingStepId.recommendedPack,
          OnboardingStepId.fonts,
          OnboardingStepId.clickLookup,
          OnboardingStepId.globalLookup,
        ]),
      );
    });

    test('manual resources replace the pack and unlock lookup tutorials', () {
      final List<OnboardingStepId> result = _steps(
        <OnboardingFeature>{OnboardingFeature.manualResources},
        globalLookupAvailable: true,
      );
      expect(result, contains(OnboardingStepId.manualResources));
      expect(result, isNot(contains(OnboardingStepId.recommendedPack)));
      expect(result, contains(OnboardingStepId.clickLookup));
      expect(result, contains(OnboardingStepId.globalLookup));
    });

    test('global tutorial still follows its platform capability gate', () {
      final Set<OnboardingFeature> selected = <OnboardingFeature>{
        OnboardingFeature.manualResources,
      };
      expect(_steps(selected), contains(OnboardingStepId.clickLookup));
      expect(
        _steps(selected),
        isNot(contains(OnboardingStepId.globalLookup)),
      );
    });

    test('first Anki card needs resources, Anki selection, and live readiness',
        () {
      final Set<OnboardingFeature> complete = <OnboardingFeature>{
        OnboardingFeature.manualResources,
        OnboardingFeature.anki,
      };
      expect(
        _steps(complete),
        isNot(contains(OnboardingStepId.firstAnkiCard)),
      );
      expect(
        _steps(complete, ankiReady: true),
        containsAllInOrder(<OnboardingStepId>[
          OnboardingStepId.anki,
          OnboardingStepId.clickLookup,
          OnboardingStepId.firstAnkiCard,
        ]),
      );
      expect(
        _steps(
          <OnboardingFeature>{OnboardingFeature.anki},
          ankiReady: true,
        ),
        isNot(contains(OnboardingStepId.firstAnkiCard)),
      );
      expect(
        _steps(
          <OnboardingFeature>{OnboardingFeature.manualResources},
          ankiReady: true,
        ),
        isNot(contains(OnboardingStepId.firstAnkiCard)),
      );
    });

    test('full selection yields all steps in stable order', () {
      expect(
        _steps(
          OnboardingFeature.values.toSet(),
          browserExtensionAvailable: true,
          globalLookupAvailable: true,
          ankiReady: true,
        ),
        <OnboardingStepId>[
          OnboardingStepId.welcome,
          OnboardingStepId.features,
          OnboardingStepId.recommendedPack,
          OnboardingStepId.manualResources,
          OnboardingStepId.anki,
          OnboardingStepId.backup,
          OnboardingStepId.interconnect,
          OnboardingStepId.browserExtension,
          OnboardingStepId.fonts,
          OnboardingStepId.clickLookup,
          OnboardingStepId.globalLookup,
          OnboardingStepId.firstAnkiCard,
          OnboardingStepId.finish,
        ],
      );
    });

    test('tab-only module features never add steps', () {
      final List<OnboardingStepId> withModules = _steps(
        <OnboardingFeature>{
          OnboardingFeature.books,
          OnboardingFeature.manga,
          OnboardingFeature.video,
          OnboardingFeature.games,
        },
      );
      expect(withModules, _steps(<OnboardingFeature>{}));
    });

    test('non-resource capabilities map to their own steps', () {
      const Map<OnboardingFeature, OnboardingStepId> capabilitySteps =
          <OnboardingFeature, OnboardingStepId>{
        OnboardingFeature.anki: OnboardingStepId.anki,
        OnboardingFeature.backup: OnboardingStepId.backup,
        OnboardingFeature.interconnect: OnboardingStepId.interconnect,
      };
      capabilitySteps
          .forEach((OnboardingFeature feature, OnboardingStepId step) {
        final List<OnboardingStepId> result =
            _steps(<OnboardingFeature>{feature});
        expect(result, contains(step), reason: '$feature 应产生 $step');
        expect(result, hasLength(5), reason: '$feature 应只追加一个配置步骤');
      });
    });
  });
}
