import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';

/// 焦点确认不走空格：[wrapWithGlobalNavigation] 把裸空格中和，使焦点落在控件上时空格
/// 不再触发激活；Enter（与手柄 A，由框架默认提供）仍激活。这条行为不受实验性焦点导航
/// 开关影响——开/关都成立。
///
/// BUG-962：中和必须只在「没有文本框聚焦」时生效。以前无条件 `space → DoNothingIntent`
/// 连文本框里的空格也吞掉，导致重命名等对话框物理键盘打不出空格（只有屏幕键盘的 IME
/// text-input 通道能绕过快捷键层）。文本框聚焦时空格必须放行冒泡到 text-input。
void main() {
  Future<int> pumpAndCountTaps(
    WidgetTester tester, {
    required bool focusNavigationEnabled,
    required LogicalKeyboardKey key,
  }) async {
    int taps = 0;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: wrapWithGlobalNavigation(
          navigatorKey: navKey,
          focusNavigationEnabled: focusNavigationEnabled,
          child: Scaffold(
            body: Center(
              child: TextButton(
                focusNode: focusNode,
                onPressed: () => taps++,
                child: const Text('确认'),
              ),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(key);
    await tester.pump();
    return taps;
  }

  /// 用「哨兵祖先 Focus」判定空格是否被 [wrapWithGlobalNavigation] 吞掉：哨兵包在其
  /// 外层，是祖先，故事件冒泡顺序为 焦点控件 → 全局导航 → 哨兵。全局导航消费（返回
  /// handled）→ 哨兵收不到；全局导航放行（ignored）→ 哨兵能收到。返回哨兵是否见到空格
  /// 按下沿。[editable] 为 true 时聚焦一个 [TextField]，否则聚焦一个 [TextButton]。
  Future<bool> pumpAndSpaceReachesSentinel(
    WidgetTester tester, {
    required bool editable,
    required bool focusNavigationEnabled,
  }) async {
    bool sentinelSawSpace = false;
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.space) {
              sentinelSawSpace = true;
            }
            return KeyEventResult.ignored;
          },
          child: wrapWithGlobalNavigation(
            navigatorKey: navKey,
            focusNavigationEnabled: focusNavigationEnabled,
            child: Scaffold(
              body: Center(
                child: editable
                    ? TextField(focusNode: focusNode)
                    : TextButton(
                        focusNode: focusNode,
                        onPressed: () {},
                        child: const Text('确认'),
                      ),
              ),
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    return sentinelSawSpace;
  }

  testWidgets('裸空格不激活焦点控件（焦点导航开/关都成立）', (WidgetTester tester) async {
    expect(
      await pumpAndCountTaps(
        tester,
        focusNavigationEnabled: false,
        key: LogicalKeyboardKey.space,
      ),
      0,
      reason: '焦点导航关闭时，空格也不应确认焦点控件',
    );
    expect(
      await pumpAndCountTaps(
        tester,
        focusNavigationEnabled: true,
        key: LogicalKeyboardKey.space,
      ),
      0,
      reason: '焦点导航开启时，空格同样不应确认焦点控件',
    );
  });

  testWidgets('Enter 仍激活焦点控件', (WidgetTester tester) async {
    expect(
      await pumpAndCountTaps(
        tester,
        focusNavigationEnabled: false,
        key: LogicalKeyboardKey.enter,
      ),
      1,
      reason: '确认键 Enter 必须仍能激活焦点控件',
    );
  });

  testWidgets('BUG-962：焦点在控件上时，空格被全局导航消费（不冒泡到祖先）', (WidgetTester tester) async {
    for (final bool nav in <bool>[false, true]) {
      expect(
        await pumpAndSpaceReachesSentinel(
          tester,
          editable: false,
          focusNavigationEnabled: nav,
        ),
        isFalse,
        reason: '控件聚焦时，裸空格必须被中和（消费），不得冒泡激活（nav=$nav）',
      );
    }
  });

  testWidgets('BUG-962：焦点在文本框上时，空格放行冒泡（可落到 text-input）',
      (WidgetTester tester) async {
    for (final bool nav in <bool>[false, true]) {
      expect(
        await pumpAndSpaceReachesSentinel(
          tester,
          editable: true,
          focusNavigationEnabled: nav,
        ),
        isTrue,
        reason: '文本框聚焦时，空格必须放行到 text-input，否则打不出空格（nav=$nav）',
      );
    }
  });
}
