// BUG-1619 根治层守卫：焦点闸门把「能持有焦点 ⟺ 主窗拥有 OS 焦点」变成结构性
// 不变量。逐点判据穷举不完（复制文本那条真机路径至今没在全仓 16 处 requestFocus
// 里定位到），所以这条不变量必须由根部保证，且必须配套开门补焦点。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/focus/main_window_focus_gate.dart';

FushiFocusController controllerOf(WidgetTester tester) =>
    FushiFocusRoot.controllerOf(tester.element(find.text('Row 0')));

Widget _app(FocusNode probe) {
  return MaterialApp(
    home: MainWindowFocusGate(
      child: Scaffold(
        body: FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiFocusTarget(
                id: const FushiFocusId('row-0'),
                child: TextButton(onPressed: () {}, child: const Text('Row 0')),
              ),
              Focus(focusNode: probe, child: const Text('probe')),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => mainWindowForegroundNotifier.value = true);

  testWidgets('门关着：任何 requestFocus 都拿不到焦点', (WidgetTester tester) async {
    final FocusNode probe = FocusNode(debugLabel: 'probe');
    addTearDown(probe.dispose);
    await tester.pumpWidget(_app(probe));
    await tester.pumpAndSettle();

    mainWindowForegroundNotifier.value = false;
    await tester.pumpAndSettle();

    probe.requestFocus();
    await tester.pumpAndSettle();
    expect(probe.hasFocus, isFalse,
        reason: '主窗不在前台时请求焦点 = 引擎 SetFocus(FlutterView) = 把主界面'
            '抢到用户的游戏 / 浏览器前面（BUG-1619）');
  });

  testWidgets('门开着：焦点照常工作（不改变正常使用）', (WidgetTester tester) async {
    final FocusNode probe = FocusNode(debugLabel: 'probe');
    addTearDown(probe.dispose);
    await tester.pumpWidget(_app(probe));
    await tester.pumpAndSettle();

    probe.requestFocus();
    await tester.pumpAndSettle();
    expect(probe.hasFocus, isTrue);
  });

  testWidgets('关门会让出既有焦点，开门后由焦点控制器补回内容焦点', (WidgetTester tester) async {
    final FocusNode probe = FocusNode(debugLabel: 'probe');
    addTearDown(probe.dispose);
    await tester.pumpWidget(_app(probe));
    await tester.pumpAndSettle();

    probe.requestFocus();
    await tester.pumpAndSettle();
    expect(probe.hasFocus, isTrue);

    mainWindowForegroundNotifier.value = false;
    await tester.pumpAndSettle();
    expect(probe.hasFocus, isFalse, reason: '关门必须让出焦点');
    expect(controllerOf(tester).primaryFocusIsManagedTarget, isFalse,
        reason: '关门期间焦点不该落在任何受管目标上');

    mainWindowForegroundNotifier.value = true;
    await tester.pumpAndSettle();

    final FushiFocusController controller =
        FushiFocusRoot.controllerOf(tester.element(find.text('Row 0')));
    // 断言**真实焦点归属**：activeId 只是缓存 id，关门不会清它，拿它断言恒真
    // （实测：把两条补票路径全删掉这条用例照样绿）。
    expect(controller.primaryFocusIsManagedTarget, isTrue,
        reason: '开门后必须补一次焦点修复，否则用户切回主窗整页没有焦点、'
            '键盘 / 手柄快捷键全不响应（TODO-900 的老症状）');
  });
}
