import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../helpers/source_guard.dart';

/// 新手引导 Anki 步里的「制卡后自动按词频重排」开关。
///
/// 这项功能此前只藏在制卡设置里且默认关，手机端用户几乎不会发现；引导里把它
/// 摆出来并默认开，同时讲清楚只有电脑版 Anki + AnkiConnect 能用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('引导里默认开，而设置本身仍默认关（不是升级送的）', () {
    expect(kOnboardingAutoRepositionDefault, isTrue);
    expect(const AnkiSettings().autoRepositionEnabled, isFalse);
    expect(
      AnkiSettings.fromJson(const <String, dynamic>{}).autoRepositionEnabled,
      isFalse,
    );
  });

  test('说明文字讲清楚要电脑版 AnkiConnect', () {
    LocaleSettings.setLocale(AppLocale.en);
    expect(t.onboarding_anki_auto_reposition_hint, contains('AnkiConnect'));
    LocaleSettings.setLocale(AppLocale.zhCn);
    final String zh = t.onboarding_anki_auto_reposition_hint;
    expect(zh, contains('AnkiConnect'));
    expect(zh, contains('电脑'));
    LocaleSettings.setLocale(AppLocale.en);
  });

  // `_buildAnkiStep` / `_goNextAsync` 是 ConsumerState 的私有方法，pump 整个向导要
  // 起 AnkiViewModel + Riverpod 容器；这里钉住两处接线：开关真的渲染在 Anki 步里，
  // 并且离开 Anki 步时真的写进设置——只渲染不写回，用户看到「开」实际却是关。
  test('开关挂在 Anki 步里，离开 Anki 步时写回设置（产品代码判据）', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/onboarding_wizard_page.dart',
      ).readAsStringSync(),
    );
    final String build = methodBody(src, 'Widget _buildAnkiStep() {');
    for (final String needle in <String>[
      't.anki_reposition_auto_title',
      't.onboarding_anki_auto_reposition_hint',
      'value: _autoReposition',
    ]) {
      expect(
        build.contains(needle),
        isTrue,
        reason: '_buildAnkiStep 里没有 `$needle`：引导里看不到自动重排开关',
      );
    }
    expect(
      src.contains('bool _autoReposition = kOnboardingAutoRepositionDefault;'),
      isTrue,
      reason: '向导内初值必须取 kOnboardingAutoRepositionDefault',
    );

    final String next = methodBody(src, 'Future<void> _goNextAsync() async {');
    final int ankiBranch = next.indexOf(
      'if (_steps[_stepIndex] == OnboardingStepId.anki) {',
    );
    final int write = next.indexOf(
      '.setAutoRepositionEnabled(_autoReposition)',
    );
    expect(ankiBranch, isNonNegative);
    expect(
      write,
      greaterThan(ankiBranch),
      reason: '离开 Anki 步时没把开关写进 AnkiSettings.autoRepositionEnabled',
    );
  });

  // 所有者 2026-10-20：「制卡后自动重排 走新手教程那步的时候默认开启」——Fushi 复习
  // 路径不经过 Anki 步，开关必须摆在复习方式一步里，并在离开那一步时写回。
  test('Fushi 复习路径：开关挂在复习方式一步，离开时写回（产品代码判据）', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/onboarding_wizard_page.dart',
      ).readAsStringSync(),
    );
    final int stepCase = src.indexOf('case OnboardingStepId.reviewMethod:');
    final int nextCase = src.indexOf('case OnboardingStepId.anki:', stepCase);
    expect(stepCase, isNonNegative);
    final String step = src.substring(stepCase, nextCase);
    for (final String needle in <String>[
      't.onboarding_review_fushi_auto_reposition_hint',
      'value: _autoReposition',
    ]) {
      expect(
        step.contains(needle),
        isTrue,
        reason: '复习方式一步里没有 `$needle`：Fushi 路径看不到自动重排开关',
      );
    }

    final String next = methodBody(src, 'Future<void> _goNextAsync() async {');
    final int reviewBranch = next.indexOf(
      'if (_steps[_stepIndex] == OnboardingStepId.reviewMethod) {',
    );
    expect(reviewBranch, isNonNegative);
    final String branch = next.substring(reviewBranch);
    expect(
      branch.contains('_applyReviewMethod(_reviewMethod)'),
      isTrue,
      reason: '照着默认按下一步时没把复习方式写进偏好',
    );
    expect(
      branch.contains('.setAutoRepositionEnabled(_autoReposition)'),
      isTrue,
      reason: '离开复习方式一步时没把开关写进 AnkiSettings.autoRepositionEnabled',
    );
  });
}
