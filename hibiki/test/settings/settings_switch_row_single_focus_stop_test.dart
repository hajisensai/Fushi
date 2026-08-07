// 单焦点站点契约：焦点根存在时，设置行（含开关行）在 Tab/手柄遍历里只出现
// 一个停靠点（_SettingsRowFocusTarget）。此前 InkWell + trailing Switch 也各占
// 一个站点，同一行最多 3 停且激活语义相同——长设置页遍历冗长（巡检 C2，
// docs/reviews/2026-07-22-ui-ux-survey.md）。滑条/步进行本就用 ExcludeFocus
// 收成单站点，这里锁住开关行与之对齐后不再回归。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

void main() {
  testWidgets('开关行在焦点根下只有一个 Tab 停靠点，整行点击仍可切换', (WidgetTester tester) async {
    bool value = false;
    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRoot(
        child: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return AdaptiveSettingsSwitchRow(
                title: '测试开关',
                value: value,
                onChanged: (bool v) => setState(() => value = v),
              );
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    final Element row = tester.element(find.byType(AdaptiveSettingsSwitchRow));
    final FocusScopeNode scope = FocusScope.of(row);
    expect(scope.traversalDescendants.length, 1,
        reason: '开关行应只贡献 1 个焦点停靠点（此前 InkWell/Switch 额外各占一个）');

    // 整行 tap 仍切换（ExcludeFocus 只挡焦点遍历，不挡指针）。
    await tester.tap(find.byType(AdaptiveSettingsSwitchRow));
    await tester.pump();
    expect(value, isTrue);

    // 键盘路径：Tab 落到唯一停靠点，Enter 激活切回。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final BuildContext? focusedContext =
        FocusManager.instance.primaryFocus?.context;
    expect(focusedContext, isNotNull, reason: 'Tab 应落到行的焦点停靠点');
    Actions.maybeInvoke<ActivateIntent>(
      focusedContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(value, isFalse, reason: 'Enter/Activate 应切换开关');
  });
}
