import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';

import '../helpers/source_guard.dart';

/// 新手引导 Anki 步骤里的「开启 FSRS」教程。
///
/// Anki 默认排程仍是 SM-2，FSRS 开关只能用户自己去 Anki 里打开，所以这段教程是
/// 唯一的出口——步骤说错了用户就找不到那个开关。
void main() {
  test('三步齐全，标题和说明都不空', () {
    for (final bool mobile in <bool>[false, true]) {
      final List<OnboardingTutorialItem> steps = ankiFsrsTutorialSteps(
        mobile: mobile,
      );
      expect(steps, hasLength(3), reason: 'mobile=$mobile');
      for (final OnboardingTutorialItem step in steps) {
        expect(step.title, isNotEmpty, reason: 'mobile=$mobile');
        expect(step.description, isNotEmpty, reason: 'mobile=$mobile');
      }
      // 竖向 stepper 三格并排，图标重复会让三步看起来是同一件事。
      expect(
        steps.map((OnboardingTutorialItem step) => step.icon).toSet(),
        hasLength(3),
        reason: 'mobile=$mobile',
      );
    }
  });

  test('只有第一步的入口分平台，后两步两端一致', () {
    final List<OnboardingTutorialItem> desktop = ankiFsrsTutorialSteps(
      mobile: false,
    );
    final List<OnboardingTutorialItem> mobile = ankiFsrsTutorialSteps(
      mobile: true,
    );

    // 桌面从牌组齿轮进选项，移动端是长按牌组——写反了用户照着找不到。
    expect(desktop.first.description, isNot(mobile.first.description));
    expect(mobile.first.description, contains('AnkiDroid'));
    expect(desktop.first.description, isNot(contains('AnkiDroid')));

    for (int index = 1; index < desktop.length; index++) {
      expect(desktop[index].title, mobile[index].title);
      expect(desktop[index].description, mobile[index].description);
    }
  });

  testWidgets('三步真能渲染出编号和标题', (WidgetTester tester) async {
    final List<OnboardingTutorialItem> steps = ankiFsrsTutorialSteps(
      mobile: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                for (int index = 0; index < steps.length; index++)
                  OnboardingTutorialStep(
                    number: index + 1,
                    item: steps[index],
                    isLast: index == steps.length - 1,
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    for (int index = 0; index < steps.length; index++) {
      expect(find.text('${index + 1}'), findsOneWidget);
      expect(find.text(steps[index].title), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  // 上面几条测的都是纯函数 `ankiFsrsTutorialSteps` 与它渲染出来的样子——**它们不关心
  // 这段教程有没有真的挂进向导**。把 `_buildAnkiStep` 里那段 `OnboardingSectionLabel`
  // + for 循环整段删掉，上面每一条依旧全绿，而用户永远看不到这段教程；而 Anki 默认
  // 排程仍是 SM-2，这段教程是用户找到那个开关的唯一出口。
  //
  // 只能做到源码扫描这一层：`_buildAnkiStep` 是 `ConsumerState` 的私有方法，pump 它
  // 要起整个向导页 + AnkiViewModel + Riverpod 容器，代价与收益不成比例。
  test('FSRS 教程真的挂在向导的 Anki 步里（产品代码判据）', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/onboarding_wizard_page.dart',
      ).readAsStringSync(),
    );
    final String body = methodBody(src, 'Widget _buildAnkiStep() {');
    for (final String needle in <String>[
      'ankiFsrsTutorialSteps(',
      't.onboarding_anki_fsrs_title',
      'OnboardingTutorialStep(',
    ]) {
      expect(
        body.contains(needle),
        isTrue,
        reason: '_buildAnkiStep 里没有 `$needle`：FSRS 教程没挂进向导，'
            '用户看不到它，而这是打开 FSRS 开关的唯一指引',
      );
    }
  });
}
