// BUG-1619（根因层）：被动焦点修复在**主窗不在前台**时不得请求焦点。
//
// 真机链路（Windows，已抓到 NtUserSetFocus 调用栈实证）：拖剪贴板查词面板顶栏
// 结束 → windowMoved → setClipboardPanelRect → PreferencesRepository
// .notifyListeners() → 首页重建 → 焦点目标重新 register → scheduleRepair →
// ensureFocus() → requestFocus → Flutter 引擎 SetFocus(FlutterView) → Win32
// 语义下 SetFocus(子窗) 连带激活其顶层窗口 → 主界面盖住用户正在用的游戏 /
// 浏览器。
//
// 判据必须是**窗口级**的：真机日志里被挡下的那些 ensureFocus，前台窗口是
// FushiGlobalLookupWindow 且**属于本进程**——沿用既有的进程级判据会直接放行。
//
// 挡下之后要记账，主窗回到前台再补一次，否则用户切回来整页没有焦点、键盘 /
// 手柄快捷键全死（TODO-900 当初要修的正是这个症状）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';

Widget _app() {
  return MaterialApp(
    home: Scaffold(
      body: FushiFocusRoot(
        child: Column(
          children: <Widget>[
            for (int i = 0; i < 3; i++)
              FushiFocusTarget(
                id: FushiFocusId('row-$i'),
                child: TextButton(onPressed: () {}, child: Text('Row $i')),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 用控制器自己的「当前焦点目标」判定，而不是 Focus.of(...)——后者拿到的是
/// TextButton 内部那个 Focus，不是 FushiFocusTarget 注册的节点。
bool _anyRowFocused(WidgetTester tester) =>
    _controller(tester).activeId != null;

FushiFocusController _controller(WidgetTester tester) =>
    FushiFocusRoot.controllerOf(tester.element(find.text('Row 0')));

/// 制造「没有可用 primary focus」——这正是被动修复真正会 requestFocus 的场景
/// （[FushiFocusController.ensureFocus] 在已有可用 primary 时只是重算状态）。
Future<void> _dropFocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

void main() {
  tearDown(() {
    DesktopForegroundGuard.debugMainWindowForeground = null;
  });

  testWidgets('主窗不在前台时被动修复不抢焦点', (WidgetTester tester) async {
    DesktopForegroundGuard.debugMainWindowForeground = false;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _dropFocus(tester);
    _controller(tester).ensureFocus();
    await tester.pumpAndSettle();

    expect(_anyRowFocused(tester), isFalse,
        reason: '主窗不在前台，被动修复不该请求焦点 —— 真机上这一步等于把主界面'
            '抢到用户的游戏 / 浏览器前面（BUG-1619）');
  });

  testWidgets('主窗在前台时被动修复照常落焦点', (WidgetTester tester) async {
    DesktopForegroundGuard.debugMainWindowForeground = true;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _dropFocus(tester);
    _controller(tester).ensureFocus();
    await tester.pumpAndSettle();

    expect(_anyRowFocused(tester), isTrue,
        reason: '主窗自己在前台时被动修复必须照旧 home 焦点，否则键盘 / 手柄'
            '导航进不去（TODO-900 回归）');
  });

  testWidgets('后台期间被挡下的修复，在主窗回到前台后补上', (WidgetTester tester) async {
    DesktopForegroundGuard.debugMainWindowForeground = false;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _dropFocus(tester);
    _controller(tester).ensureFocus();
    await tester.pumpAndSettle();
    expect(_anyRowFocused(tester), isFalse);

    // 主窗回到前台：FlutterView 重新拿到 OS 焦点会驱动 FocusManager 通知，
    // 控制器在那条监听里补上欠下的那次修复。
    DesktopForegroundGuard.debugMainWindowForeground = true;
    FocusManager.instance.rootScope.requestFocus(FocusNode());
    await tester.pumpAndSettle();

    expect(_anyRowFocused(tester), isTrue,
        reason: '欠下的修复没补上 = 用户切回主窗后整页没有焦点、快捷键全死');
  });
}
