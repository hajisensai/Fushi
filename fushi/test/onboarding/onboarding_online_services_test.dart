import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/onboarding/online_services_onboarding_view.dart';

List<OnboardingStepId> _steps(Set<OnboardingFeature> selected) =>
    onboardingStepSequence(
      selected: selected,
      browserExtensionAvailable: true,
      globalLookupAvailable: true,
      ankiReady: false,
    );

void main() {
  test('catalog keeps public services separate from user credentials', () {
    final Map<String, OnlineServiceOnboardingItem> catalog =
        <String, OnlineServiceOnboardingItem>{
      for (final OnlineServiceOnboardingItem item
          in onlineServiceOnboardingItems())
        item.id: item,
    };
    expect(
        catalog['anidb']!.link.toString(), 'https://anidb.net/user/register');
    expect(catalog['jimaku']!.link.toString(), 'https://jimaku.cc/account');
    expect(catalog['opensubtitles']!.link.toString(),
        'https://www.opensubtitles.com/en/consumers');
    expect(catalog['mal_anilist']!.requirement,
        t.onboarding_online_services_ready);
    expect(catalog['mal_anilist']!.link, isNull);
    expect(catalog['dandanplay']!.link, isNull);
    expect(catalog['servers']!.link, isNull);
  });

  test(
      'Online services tutorial is opt-in and independent of video module selection',
      () {
    expect(kOnboardingDefaultCapabilities,
        isNot(contains(OnboardingFeature.onlineServices)));
    expect(_steps(kOnboardingDefaultCapabilities),
        isNot(contains(OnboardingStepId.onlineServices)));
    expect(_steps(<OnboardingFeature>{OnboardingFeature.video}),
        isNot(contains(OnboardingStepId.onlineServices)));
    final Set<OnboardingFeature> selected = <OnboardingFeature>{
      OnboardingFeature.onlineServices
    };
    expect(_steps(selected), <OnboardingStepId>[
      OnboardingStepId.welcome,
      OnboardingStepId.features,
      OnboardingStepId.onlineServices,
      OnboardingStepId.finish,
    ]);
    selected.clear();
    expect(_steps(selected), isNot(contains(OnboardingStepId.onlineServices)));
  });

  testWidgets('tutorial keeps account registration and setup explicit',
      (WidgetTester tester) async {
    int registrations = 0;
    int configurations = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: OnlineServicesOnboardingView(
        items: <OnlineServiceOnboardingItem>[
          OnlineServiceOnboardingItem(
              id: 'example',
              title: 'Example',
              requirement: 'Account',
              description: 'Optional account',
              link: Uri.parse('https://example.com/register'))
        ],
        onOpenLink: (Uri url) => registrations++,
        onConfigure: () => configurations++,
      ),
    ))));
    expect(registrations, 0);
    expect(configurations, 0);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.text(t.onboarding_online_services_link));
    expect(registrations, 1);
    expect(configurations, 0);
    await tester
        .ensureVisible(find.text(t.onboarding_online_services_configure));
    await tester.tap(find.text(t.onboarding_online_services_configure));
    expect(configurations, 1);
    expect(tester.takeException(), isNull);
  });
}
