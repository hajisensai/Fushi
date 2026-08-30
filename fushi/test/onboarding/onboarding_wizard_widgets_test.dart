import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('OnboardingFeatureTile toggles via onToggle and shows check',
      (WidgetTester tester) async {
    bool toggled = false;
    await tester.pumpWidget(_host(
      OnboardingFeatureTile(
        icon: Icons.auto_stories_outlined,
        title: '词典查词',
        subtitle: '导入词典',
        selected: true,
        onToggle: () => toggled = true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('词典查词'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('词典查词'));
    expect(toggled, isTrue);
  });

  testWidgets('OnboardingFeatureTile unselected shows hollow marker',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      OnboardingFeatureTile(
        icon: Icons.style_outlined,
        title: 'Anki',
        subtitle: 'hint',
        selected: false,
        onToggle: () {},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('OnboardingStepView renders title, body and actions',
      (WidgetTester tester) async {
    bool pressed = false;
    await tester.pumpWidget(_host(
      OnboardingStepView(
        icon: Icons.cloud_sync_outlined,
        title: '配置备份',
        body: '选择备份后端并登录。',
        actions: <OnboardingAction>[
          OnboardingAction(
            icon: Icons.settings_backup_restore_outlined,
            label: '打开备份设置',
            description: '选备份后端并登录，换机器时库还在。',
            necessity: OnboardingActionNecessity.optional,
            onPressed: () => pressed = true,
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('配置备份'), findsOneWidget);
    expect(find.text('选择备份后端并登录。'), findsOneWidget);
    // 说明必须和标题一起渲染出来：动作只有标签就是「不知道点了干什么」。
    expect(find.text('选备份后端并登录，换机器时库还在。'), findsOneWidget);
    await tester.tap(find.text('打开备份设置'));
    expect(pressed, isTrue);
  });

  testWidgets(
      'OnboardingActionTile shows the description and a necessity badge',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const Column(
        children: <Widget>[
          OnboardingActionTile(
            action: OnboardingAction(
              icon: Icons.download_outlined,
              label: '下载并导入',
              description: '在后台下载整个推荐包，下完自动进入导入。',
              necessity: OnboardingActionNecessity.recommended,
              onPressed: null,
            ),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('下载并导入'), findsOneWidget);
    expect(find.text('在后台下载整个推荐包，下完自动进入导入。'), findsOneWidget);
    // 徽标是「要不要点」的唯一载体，不能被 OnboardingActionTile 悄悄漏掉。
    expect(
      find.descendant(
        of: find.byType(OnboardingActionTile),
        matching: find.byType(OnboardingNecessityBadge),
      ),
      findsOneWidget,
    );
  });

  testWidgets('OnboardingActionTile survives a long label on a narrow screen',
      (WidgetTester tester) async {
    // 标题行是「标签 + 必要性徽标」两件东西挤一行。窄机 + 长标签（下载按钮的标签
    // 还要拼上体积，是全场最长的一个）曾是这类 Row 溢出的经典形状——溢出会让
    // widget 测试直接抛异常，所以这条用例本身就是断言。
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(
      const Column(
        children: <Widget>[
          OnboardingActionTile(
            action: OnboardingAction(
              icon: Icons.download_outlined,
              label: '下载并导入推荐包（词典 + 日英发音音频库，9.5 GB）',
              description: '在后台下载整个推荐包，下完自动进入导入。'
                  '随时可以取消，下次从断点续传。',
              necessity: OnboardingActionNecessity.recommended,
              onPressed: null,
            ),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(OnboardingNecessityBadge), findsOneWidget);
  });

  testWidgets('OnboardingNecessityBadge label differs per necessity',
      (WidgetTester tester) async {
    final Set<String> labels = <String>{};
    for (final OnboardingActionNecessity necessity
        in OnboardingActionNecessity.values) {
      await tester.pumpWidget(
        _host(OnboardingNecessityBadge(necessity: necessity)),
      );
      await tester.pumpAndSettle();
      labels.add(
        (tester.widget(find.byType(Text).last) as Text).data!,
      );
    }
    // 三档必须是三个不同的词——否则徽标存在但什么都没说。
    expect(labels.length, OnboardingActionNecessity.values.length);
  });
}
