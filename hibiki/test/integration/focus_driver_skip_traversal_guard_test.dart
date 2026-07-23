import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/helpers/focus_driver.dart';

/// BUG 守卫：`FocusDriver._focusOwns` 不得把「skipTraversal 的键事件 sink 焦点」
/// 误判为已聚焦某个 target。
///
/// HomePage 用一个 autofocus + skipTraversal 的整页 [Focus]（`_keyboardFocusNode`）
/// 做全局快捷键 sink——它开机即持有 primary focus，且是页内一切控件的祖先。旧的
/// `_focusOwns` 只排除 [FocusScopeNode]，于是「焦点还停在 sink 上」会对页内所有
/// target 立即误报命中：`focusWidget` 一步 Tab 都没走就返回 true，焦点可达性断言
/// 全部变成恒真（iOS smoke 失败排查中实锤：更新弹窗把焦点抢到 ModalScope 后，
/// 断言才第一次真的开始检验，随即暴露 Tab 从未真正工作）。
void main() {
  testWidgets('skipTraversal key-sink 持焦时不得误报拥有 target，Tab 仍能真实到达',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            // 模拟 HomePage 的整页快捷键 sink：开机自动持焦、不参与遍历。
            autofocus: true,
            skipTraversal: true,
            onKeyEvent: (FocusNode node, KeyEvent event) =>
                KeyEventResult.ignored,
            child: Center(
              child: ElevatedButton(
                onPressed: () {},
                child: const Icon(Icons.home),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final FocusDriver driver = FocusDriver(tester);
    final Finder target = find.byIcon(Icons.home);

    // 前置：primary focus 确实落在 skipTraversal sink 上。
    final FocusNode? initial = FocusManager.instance.primaryFocus;
    expect(initial, isNotNull);
    expect(initial!.skipTraversal, isTrue,
        reason: 'autofocus 的整页 sink 应持有初始焦点（复现 HomePage 场景）');

    // maxSteps: 0 = 不按 Tab 只判定现状：sink 持焦不得算「已拥有」按钮。
    expect(await driver.focusWidget(target, maxSteps: 0), isFalse,
        reason: 'skipTraversal sink 持焦时 focusWidget 不得误报命中');

    // 真实 Tab 遍历必须能到达按钮（排除 sink 后判定仍对真控件成立）。
    expect(await driver.focusWidget(target, maxSteps: 5), isTrue,
        reason: 'Tab 遍历应真实到达按钮并被判定命中');
  });
}
