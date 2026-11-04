import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';

import '../helpers/source_guard.dart';

/// 守卫：正式版新手引导启用并优先 Fushi 复习（用户 2026-11-05 要求
/// 「正式版新手引导启用并优先 Fushi 复习」）。
///
/// 历史：main 上曾有热修 e104123bfe（正式版跳过复习方式步骤），develop 没有；
/// develop 已撤掉「正式版隐藏 SRS 模块」（50af55cb68）。本文件钉住这个终态，
/// 防止再有人按构建通道把复习或复习方式步骤藏起来。
void main() {
  test('onboarding 默认复习方式是 Fushi', () {
    expect(kOnboardingDefaultReviewMethod, OnboardingReviewMethod.fushi);
  });

  test('复习方式选择器里 Fushi 选项排在 Anki 前（产品代码判据）', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/onboarding_wizard_page.dart',
      ).readAsStringSync(),
    );
    final int start = src.indexOf('class OnboardingReviewMethodChooser');
    expect(start, greaterThanOrEqualTo(0));
    final String body = src.substring(start);
    final int fushi = body.indexOf("'onboarding_review_fushi'");
    final int ankiToggle = body.indexOf("'onboarding_review_anki_toggle'");
    final int anki = body.indexOf("'onboarding_review_anki'");
    expect(fushi, greaterThanOrEqualTo(0));
    expect(ankiToggle, greaterThanOrEqualTo(0));
    expect(anki, greaterThanOrEqualTo(0));
    expect(fushi, lessThan(ankiToggle), reason: 'Fushi 选项必须在 Anki 折叠入口之前');
    expect(fushi, lessThan(anki), reason: 'Fushi 选项必须在 Anki 选项之前');
  });

  test('勾选制卡 + anki 时含复习方式与 Fushi 复习介绍步、不含 Anki 配置步', () {
    final List<OnboardingStepId> steps = onboardingStepSequence(
      selected: <OnboardingFeature>{
        OnboardingFeature.cardCreation,
        OnboardingFeature.anki,
      },
      browserExtensionAvailable: false,
      globalLookupAvailable: false,
      ankiReady: false,
      reviewMethod: kOnboardingDefaultReviewMethod,
    );
    expect(steps, contains(OnboardingStepId.reviewMethod));
    expect(steps, contains(OnboardingStepId.srs));
    expect(steps, isNot(contains(OnboardingStepId.anki)));
  });

  test('ModuleId.srs 五端可用且出厂默认开（API 无构建版本参数，不按通道门控）', () {
    for (final ({bool w, bool d, bool i, bool a}) p
        in <({bool w, bool d, bool i, bool a})>[
          (w: true, d: true, i: false, a: false),
          (w: false, d: true, i: false, a: false),
          (w: false, d: false, i: true, a: false),
          (w: false, d: false, i: false, a: true),
        ]) {
      expect(
        ModuleId.srs.availableOn(
          isWindows: p.w,
          isDesktop: p.d,
          isIOS: p.i,
          isAndroid: p.a,
        ),
        isTrue,
        reason: 'srs 在 $p 上必须可用',
      );
    }
    expect(ModuleId.srs.defaultEnabled, isTrue);
  });

  test('lib 里没有按正式版 / 预发布构建门控 srs 的代码（源码扫描）', () {
    final RegExp gate = RegExp(
      r'isFormalRelease\w*|isFormalBuild\w*|PrereleaseOnly\w*|'
      r'prereleaseOnly\w*|formalBuild\w*',
    );
    final List<String> hits = <String>[];
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String src = maskComments(e.readAsStringSync());
      if (gate.hasMatch(src)) hits.add(e.path);
    }
    expect(hits, isEmpty, reason: '发现按构建通道门控的标识符：$hits');
  });
}
