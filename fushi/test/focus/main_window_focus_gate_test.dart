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
  // 闸门的平台判据是 Platform.isWindows。不覆盖它的话，CI（Linux）上 build 直接
  // 返回 child、initState 也不订阅，于是「关门」什么都没做：下面的断言不是被满足，
  // 而是压根没被执行到。本机 Windows 全绿、CI 两条红就是这么来的（run 32656498068）。
  setUp(() => debugMainWindowFocusGateAppliesOverride = true);
  tearDown(() {
    debugMainWindowFocusGateAppliesOverride = null;
    mainWindowForegroundNotifier.value = true;
  });

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

  testWidgets('判据不适用的平台上闸门完全透传（不改变既有语义）',
      (WidgetTester tester) async {
    // 反向用例：锁住「非 Windows 恒 true」这条设计承诺。没有它，上面三条全靠覆盖
    // 开关跑，谁把判据改成恒真都不会有人发现——而恒真意味着 Android / iOS 上凭空
    // 多出一个会吃掉 requestFocus 的闸门。
    debugMainWindowFocusGateAppliesOverride = false;
    final FocusNode probe = FocusNode(debugLabel: 'probe');
    addTearDown(probe.dispose);
    await tester.pumpWidget(_app(probe));
    await tester.pumpAndSettle();

    mainWindowForegroundNotifier.value = false;
    await tester.pumpAndSettle();

    probe.requestFocus();
    await tester.pumpAndSettle();
    expect(probe.hasFocus, isTrue,
        reason: '判据不适用时前台真值不该影响焦点，闸门必须是纯透传');
  });
}
