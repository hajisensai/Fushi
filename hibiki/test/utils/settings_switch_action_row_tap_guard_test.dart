import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// TODO-977 / BUG-464 —— 调色行点背景不应误关开关。
///
/// `AdaptiveSettingsSwitchActionRow` 过去整行 `onTap` 都会切换开关。带展开调色板
/// （`panel`）的行（自定义主题页/有声书快捷设置里的颜色选择器）因此一被点到 body /
/// 预览 / 面板附近就误把配置项关掉（用户反馈「经常点到背景把这个配置项给关掉了」）。
/// 修复：带 panel 时整行 onTap 不再切换开关，只有 switch 控件本身切换；无 panel 的
/// 普通开关行保持整行可点的旧行为。撤掉修复这些断言会红。
void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required bool value,
    required ValueChanged<bool> onChanged,
    Widget? panel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveSettingsSwitchActionRow(
            title: '音频高亮',
            value: value,
            onChanged: onChanged,
            body: const Text('BODY'),
            panel: panel,
          ),
        ),
      ),
    );
  }

  testWidgets('带 panel 时点 body 不切换开关（不误关）', (WidgetTester tester) async {
    int toggles = 0;
    await pumpRow(
      tester,
      value: true,
      onChanged: (_) => toggles++,
      panel: const SizedBox(height: 40, child: Text('PANEL')),
    );

    await tester.tap(find.text('BODY'));
    await tester.pump();
    expect(toggles, 0, reason: '带调色板的行点 body 不应切换/关闭开关（BUG-464）');

    // switch 控件本身仍可切换。
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(toggles, 1, reason: 'switch 控件本身仍应能切换');
  });

  testWidgets('无 panel 的普通开关行整行可点切换（旧行为保留）', (WidgetTester tester) async {
    int toggles = 0;
    await pumpRow(
      tester,
      value: false,
      onChanged: (_) => toggles++,
      panel: null,
    );

    await tester.tap(find.text('BODY'));
    await tester.pump();
    expect(toggles, 1, reason: '无展开面板的普通开关行应保持整行可点的旧行为');
  });
}
