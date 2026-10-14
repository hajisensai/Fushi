import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 反馈 YupByu8gxD 回归守卫：新手引导页头不再挂返回箭头。
///
/// 页头左上角的返回箭头会被用户当成「回到上一步」，点了却是整个向导被关掉，
/// 与底栏左侧的「暂时跳过」重复、又和底栏的「返回」（上一步）语义冲突。向导只保留
/// 底栏一组控件：跳过 / 返回（上一步）/ 下一步。
void main() {
  const String wizardPath =
      'lib/src/pages/implementations/onboarding_wizard_page.dart';

  test('向导页头没有返回箭头，离开入口只有底栏的「暂时跳过」', () {
    final String code = maskCommentsAndStrings(
      File(wizardPath).readAsStringSync(),
    );
    final int buildAt = code.indexOf('Widget build(BuildContext context)');
    expect(buildAt, isNonNegative);
    final int scaffoldAt = code.indexOf('FushiPageScaffold(', buildAt);
    expect(scaffoldAt, isNonNegative);
    final int bodyAt = code.indexOf('body:', scaffoldAt);
    expect(bodyAt, greaterThan(scaffoldAt));
    final String header = code.substring(scaffoldAt, bodyAt);
    expect(header, isNot(contains('leading:')));
    expect(header, isNot(contains('FushiIcons.back')));
    expect(header, contains('automaticallyImplyLeading: false'));
    // 底栏仍提供跳过与上一步。
    expect(code, contains('onSkip: isLast ? null :'));
    expect(code, contains('onBack: _stepIndex > 0 ? _goBack : null'));
  });
}
