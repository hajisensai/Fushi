// BUG-4273：新路由显式声明的 autofocus 必须赢过被动焦点修复。
//
// 真机（Windows 集成探针，词典管理改名）：键盘焦点在「改名」按钮上按回车 →
// 改名对话框弹出 → 焦点落在输入框后缀的屏幕键盘按钮（FushiIconButton）上，
// 输入框从未拿到焦点，键盘用户必须先按 Tab 才能打字。
//
// 触发链：推路由那一帧，下层页面里依赖 ModalRoute 的子树重建 → 其中的
// FushiFocusTarget 重新 register → scheduleRepair（帧后回调）。这条帧后回调
// 排在 EditableText 排 autofocus 与对话框目标登记之后、FocusManager 应用挂起
// 请求的微任务之前——被动修复看到的主焦点仍是下层失去「当前」身份的按钮，
// 于是替对话框选了第一个登记目标，写进对话框 scope 的 focusedChild，框架随即
// 以「scope 已有焦点」丢弃输入框的 autofocus。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/pages/implementations/name_input_dialog.dart';

Widget _app(FocusNode trigger) {
  return MaterialApp(
    // 桌面平台：输入框带屏幕键盘后缀按钮（真机里抢走焦点的那个目标）。
    theme: ThemeData(platform: TargetPlatform.windows),
    // 与 main.dart 一致：焦点控制器在 Navigator 之上，对话框里的目标也登记。
    builder: (BuildContext context, Widget? child) =>
        FushiFocusRoot(child: child!),
    home: Scaffold(
      body: Builder(
        builder: (BuildContext context) => Column(
          children: <Widget>[
            FilledButton(
              focusNode: trigger,
              onPressed: () => showNameInputDialog(
                context: context,
                title: 'Rename',
                labelText: 'Name',
                initialName: 'Test KO',
              ),
              child: const Text('Rename'),
            ),
            // 下层页面里依赖 ModalRoute 的子树：推路由时 isCurrent 变化使其重建，
            // 内部受管目标重新 register（真 app 里顶栏 / PopScope 等都依赖它）。
            Builder(
              builder: (BuildContext context) {
                ModalRoute.of(context);
                // 刻意非 const：const 不触发 didUpdateWidget，也就不会重新 register。
                // ignore: prefer_const_constructors
                return FushiFocusTarget(
                  id: const FushiFocusId('page-row'),
                  child: const SizedBox(width: 200, height: 40),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('回车打开改名对话框：焦点落在输入框，而不是被动修复选的后缀按钮', (WidgetTester tester) async {
    final FocusNode trigger = FocusNode(debugLabel: 'rename-trigger');
    addTearDown(trigger.dispose);
    await tester.pumpWidget(_app(trigger));
    await tester.pumpAndSettle();
    trigger.requestFocus();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(trigger));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final EditableText editable = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(
      FocusManager.instance.primaryFocus,
      same(editable.focusNode),
      reason:
          '对话框输入框声明了 autofocus，被动修复不得抢先替新路由选第一个'
          '登记目标（实际落在：${FocusManager.instance.primaryFocus}）',
    );

    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(editable.focusNode));
  });

  testWidgets('新路由没有 autofocus 时被动修复仍照常把焦点落到其登记目标', (
    WidgetTester tester,
  ) async {
    final FocusNode trigger = FocusNode(debugLabel: 'open-trigger');
    addTearDown(trigger.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            FushiFocusRoot(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => FilledButton(
              focusNode: trigger,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: FushiFocusTarget(
                      id: FushiFocusId('next-page-row'),
                      child: SizedBox(width: 200, height: 40),
                    ),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    trigger.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final FushiFocusController controller = FushiFocusRoot.controllerOf(
      tester.element(find.byType(FushiFocusTarget)),
    );
    expect(controller.activeId, const FushiFocusId('next-page-row'));
    expect(controller.primaryFocusIsManagedTarget, isTrue);
  });
}
