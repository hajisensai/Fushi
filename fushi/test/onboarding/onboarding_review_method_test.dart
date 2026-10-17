// 新手引导「复习方式」一步的选择区（所有者 2026-10-16）：
// - Fushi 复习是主路径、直接呈现、默认选中；
// - Anki 收在「改用 Anki…」折叠里，展开前它的说明与选项都不在树上；
// - 两项都不挂「推荐」徽标、文案里没有比较用语；FSRS-7 的说法与内核默认算法一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show SrsAlgorithm, srsDefaultAlgorithm;
import 'package:material_ui/material_ui.dart';

/// 有状态宿主：与向导页同一套状态流转（点选 → 回调 → 重建）。
class _Host extends StatefulWidget {
  const _Host({required this.onSelect});

  final ValueChanged<OnboardingReviewMethod> onSelect;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  OnboardingReviewMethod _method = OnboardingReviewMethod.fushi;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: OnboardingReviewMethodChooser(
          method: _method,
          ankiExpanded: _expanded,
          onSelect: (OnboardingReviewMethod m) {
            widget.onSelect(m);
            setState(() => _method = m);
          },
          onToggleAnki: () => setState(() => _expanded = !_expanded),
        ),
      ),
    ),
  );
}

void main() {
  for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
    testWidgets('Fushi 复习直接呈现且默认选中，Anki 在折叠里（${locale.name}）', (
      WidgetTester tester,
    ) async {
      LocaleSettings.setLocale(locale);
      final List<OnboardingReviewMethod> picks = <OnboardingReviewMethod>[];
      await tester.pumpWidget(_Host(onSelect: picks.add));
      await tester.pumpAndSettle();

      final Finder fushi = find.byKey(
        const ValueKey<String>('onboarding_review_fushi'),
      );
      final Finder anki = find.byKey(
        const ValueKey<String>('onboarding_review_anki'),
      );
      expect(fushi, findsOneWidget);
      expect(find.text(t.onboarding_review_fushi_desc), findsOneWidget);
      expect(
        tester.widget<OnboardingFeatureTile>(fushi).selected,
        isTrue,
        reason: '主路径默认选中',
      );
      // Anki 收起：选项与说明都不在树上，只露出「改用 Anki…」一行。
      expect(anki, findsNothing);
      expect(find.text(t.onboarding_review_anki_desc), findsNothing);
      expect(find.text(t.onboarding_review_anki_toggle), findsOneWidget);
      // 没有「推荐」一说。
      expect(find.text(t.onboarding_action_badge_recommended), findsNothing);

      await tester.tap(find.text(t.onboarding_review_anki_toggle));
      await tester.pumpAndSettle();
      expect(anki, findsOneWidget);
      expect(find.text(t.onboarding_review_anki_desc), findsOneWidget);
      expect(tester.widget<OnboardingFeatureTile>(anki).selected, isFalse);

      await tester.tap(anki);
      await tester.pumpAndSettle();
      expect(picks, <OnboardingReviewMethod>[OnboardingReviewMethod.anki]);
      expect(tester.widget<OnboardingFeatureTile>(anki).selected, isTrue);
      expect(tester.widget<OnboardingFeatureTile>(fushi).selected, isFalse);

      await tester.tap(fushi);
      await tester.pumpAndSettle();
      expect(picks.last, OnboardingReviewMethod.fushi);
      expect(tester.widget<OnboardingFeatureTile>(fushi).selected, isTrue);
    });
  }

  test('文案：写 FSRS-7（= 内核默认算法）、不写比较用语', () {
    expect(srsDefaultAlgorithm, SrsAlgorithm.fsrs7);
    for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
      LocaleSettings.setLocale(locale);
      expect(t.onboarding_review_fushi_desc, contains('FSRS-7'));
      for (final String text in <String>[
        t.onboarding_review_fushi_title,
        t.onboarding_review_fushi_desc,
        t.onboarding_review_anki_desc,
        t.onboarding_review_method_body,
      ]) {
        for (final String banned in <String>[
          '推荐',
          '更好',
          'recommend',
          'Recommend',
          'better',
        ]) {
          expect(text, isNot(contains(banned)), reason: '「$text」');
        }
      }
    }
    LocaleSettings.setLocale(AppLocale.en);
  });
}
