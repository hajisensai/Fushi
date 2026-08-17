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
        actions: <Widget>[
          FilledButton.tonal(
            onPressed: () => pressed = true,
            child: const Text('打开备份设置'),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('配置备份'), findsOneWidget);
    expect(find.text('选择备份后端并登录。'), findsOneWidget);
    await tester.tap(find.text('打开备份设置'));
    expect(pressed, isTrue);
  });
}
