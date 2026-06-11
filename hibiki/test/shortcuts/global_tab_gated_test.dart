import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';

/// TODO-112 / BUG-196：键盘焦点导航开关关闭时，Tab/Shift+Tab 不应在控件间移动焦点。
///
/// 此前 Tab 走 Flutter [WidgetsApp] 内建的 NextFocusIntent/PreviousFocusIntent，
/// 与实验性「键盘/手柄焦点导航」开关 [AppModel.experimentalFocusNavigationEnabled]
/// 完全解耦——关掉开关，按 Tab 焦点照样跳。用户裁定：关闭时 Tab 不该有动作。
///
/// 修复：[wrapWithGlobalNavigation] 在 `focusNavigationEnabled == false` 时把
/// Tab / Shift+Tab 中和成 [DoNothingIntent]（与裸空格同范式），它的 Shortcuts 比
/// WidgetsApp 默认 shortcuts 更靠近焦点节点，故先匹配、阻断内建 Tab 遍历。开启时
/// 不中和，Flutter 原生 Tab 遍历照常。
void main() {
  /// 渲染上下两个按钮，[first] 自动获焦；发一个 Tab（带可选 shift），返回当前
  /// 持主焦点的按钮文本（'first' / 'second' / null）。
  Future<String?> pumpThenTab(
    WidgetTester tester, {
    required bool focusNavigationEnabled,
    bool shift = false,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode first = FocusNode(debugLabel: 'first');
    final FocusNode second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: wrapWithGlobalNavigation(
          navigatorKey: navKey,
          focusNavigationEnabled: focusNavigationEnabled,
          child: Scaffold(
            body: Column(
              children: <Widget>[
                TextButton(
                  focusNode: first,
                  onPressed: () {},
                  child: const Text('first'),
                ),
                TextButton(
                  focusNode: second,
                  onPressed: () {},
                  child: const Text('second'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    first.requestFocus();
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue, reason: '前置条件：第一个按钮必须先持有焦点');

    if (shift) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    if (shift) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await tester.pump();

    if (first.hasPrimaryFocus) return 'first';
    if (second.hasPrimaryFocus) return 'second';
    return null;
  }

  testWidgets('焦点导航关闭：Tab 不移动焦点（停在原控件）', (WidgetTester tester) async {
    final String? focused =
        await pumpThenTab(tester, focusNavigationEnabled: false);
    expect(focused, 'first', reason: '关闭键盘/手柄焦点导航后，Tab 不应在控件间跳焦点');
  });

  testWidgets('焦点导航关闭：Shift+Tab 不移动焦点', (WidgetTester tester) async {
    final String? focused =
        await pumpThenTab(tester, focusNavigationEnabled: false, shift: true);
    expect(focused, 'first', reason: '关闭键盘/手柄焦点导航后，Shift+Tab 同样不应移动焦点');
  });

  testWidgets('焦点导航开启：Tab 照常移动焦点（不回归原生遍历）', (WidgetTester tester) async {
    final String? focused =
        await pumpThenTab(tester, focusNavigationEnabled: true);
    expect(focused, 'second', reason: '开启键盘/手柄焦点导航时，Flutter 原生 Tab 遍历必须照常工作');
  });
}
