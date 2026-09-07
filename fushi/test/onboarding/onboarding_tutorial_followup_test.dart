import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';

void main() {
  test('startup retires old setup before the prompt can consume its receipt',
      () {
    final String source =
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();
    final int pending = source.indexOf('if (await tutorialState.shouldPrompt)');
    final int completed = source.indexOf(
        'await appModelNoUpdate.setOnboardingCompleted(value: true)', pending);
    final int prompt =
        source.indexOf('await showRecommendedPackTutorialPrompt(', pending);
    expect(pending, greaterThanOrEqualTo(0));
    expect(completed, greaterThan(pending));
    expect(prompt, greaterThan(completed));
  });
  test(
      'follow-up begins with lookup and never replays setup or unverified Anki',
      () {
    expect(
        onboardingTutorialStepSequence(globalLookupAvailable: false),
        <OnboardingStepId>[
          OnboardingStepId.clickLookup,
          OnboardingStepId.finish
        ]);
    expect(
        onboardingTutorialStepSequence(globalLookupAvailable: true),
        <OnboardingStepId>[
          OnboardingStepId.clickLookup,
          OnboardingStepId.globalLookup,
          OnboardingStepId.finish
        ]);
  });

  test('only finishing after all tutorial pages records completion', () {
    final List<OnboardingStepId> steps =
        onboardingTutorialStepSequence(globalLookupAvailable: true);
    final OnboardingTutorialProgress progress = OnboardingTutorialProgress();
    expect(
        progress.shouldMarkCompleted(steps: steps, finished: false), isFalse);
    progress.completeStep(OnboardingStepId.clickLookup);
    expect(progress.shouldMarkCompleted(steps: steps, finished: true), isFalse);
    progress.completeStep(OnboardingStepId.globalLookup);
    expect(
        progress.shouldMarkCompleted(steps: steps, finished: false), isFalse);
    expect(progress.shouldMarkCompleted(steps: steps, finished: true), isTrue);
  });

  test('full wizard must complete tutorial pages, including verified Anki', () {
    final List<OnboardingStepId> steps = onboardingStepSequence(
      selected: <OnboardingFeature>{
        OnboardingFeature.recommendedPack,
        OnboardingFeature.anki
      },
      browserExtensionAvailable: false,
      globalLookupAvailable: false,
      ankiReady: true,
    );
    final OnboardingTutorialProgress progress = OnboardingTutorialProgress();
    progress.completeStep(OnboardingStepId.features);
    expect(progress.shouldMarkCompleted(steps: steps, finished: true), isFalse);
    progress.completeStep(OnboardingStepId.clickLookup);
    expect(progress.shouldMarkCompleted(steps: steps, finished: true), isFalse);
    progress.completeStep(OnboardingStepId.firstAnkiCard);
    expect(progress.shouldMarkCompleted(steps: steps, finished: true), isTrue);
    expect(
        progress.shouldMarkCompleted(steps: steps, finished: false), isFalse);
  });

  test('finishing a wizard without tutorials is not tutorial completion', () {
    final OnboardingTutorialProgress progress = OnboardingTutorialProgress();
    expect(
        progress.shouldMarkCompleted(
            steps: onboardingStepSequence(
              selected: <OnboardingFeature>{},
              browserExtensionAvailable: false,
              globalLookupAvailable: false,
              ankiReady: false,
            ),
            finished: true),
        isFalse);
  });
}
