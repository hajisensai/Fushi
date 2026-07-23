// 用户报「键盘/手柄焦点导航开关没有动画，其他的有」（2026-07-22）。
// 根因：旧 _wrapFocusNavigation 按开关插/拔 HibikiFocusRoot/Ring 两层——树结构
// 变化导致整棵 app 子树重挂载，被切的 Switch 以新状态直接 mount，滑块动画消失。
// 修复：焦点层恒定挂载（enabled 门控行为）+ 设置行结构恒定（ExcludeFocus.excluding
// / HibikiFocusTarget.enabled 门控而非换树）。本文件两个测试分别锁：
// 1) schema 式开关行本身动画健在（判别基线）；
// 2) 翻转 HibikiFocusRoot.enabled 同帧切换开关值时，Switch State 存活且动画运行
//    ——正是用户点「键盘/手柄焦点导航」开关的场景。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

void main() {
  testWidgets('schema 式开关行（异步 onChanged + setState）保有滑块动画',
      (WidgetTester tester) async {
    bool value = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AdaptiveSettingsSwitchRow(
              title: '探针开关',
              value: value,
              onChanged: (bool next) async {
                // 复刻 settings_schema_widgets._switch：先异步落库再刷新。
                await Future<void>.delayed(const Duration(milliseconds: 10));
                setState(() => value = next);
              },
            );
          },
        ),
      ),
    ));

    await tester.tap(find.byType(Switch));
    // 放异步写完成 + 触发 setState 回灌新值。
    await tester.pump(const Duration(milliseconds: 20));
    // value 变化帧：Switch didUpdateWidget 启动滑块动画 → 必有后续排帧。
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: '值翻转后应有进行中的滑块动画（还在排帧）；若无排帧说明 Switch '
            '被重挂载或动画被吞');
    // 动画自然结束后收敛。
    await tester.pumpAndSettle();
    expect(value, isTrue);
  });

  testWidgets('翻转 HibikiFocusRoot.enabled 时开关行 Element 存活、滑块动画运行',
      (WidgetTester tester) async {
    bool focusNav = false;
    Widget app() => MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                // 复刻真实壳结构：恒定挂载的焦点根，enabled 随开关值走——
                // 用户点「键盘/手柄焦点导航」= 同帧翻 enabled + 翻 Switch 值。
                return HibikiFocusRoot(
                  enabled: focusNav,
                  child: AdaptiveSettingsSwitchRow(
                    title: '键盘/手柄焦点导航',
                    value: focusNav,
                    onChanged: (bool next) async {
                      await Future<void>.delayed(
                          const Duration(milliseconds: 10));
                      setState(() => focusNav = next);
                    },
                  ),
                );
              },
            ),
          ),
        );
    await tester.pumpWidget(app());

    // Switch 是 StatelessWidget（内部 _MaterialSwitch 才持 State）——用 Element
    // 身份判定重挂载：Element 存活 = 子树未被重建，内部动画 State 必然同存活。
    final Element switchElementBefore = tester.element(find.byType(Switch));

    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    // 结构恒定 → 同一个 Switch Element 存活（旧实现这里是新实例，动画无从谈起）。
    expect(
      identical(tester.element(find.byType(Switch)), switchElementBefore),
      isTrue,
      reason: '翻转焦点导航开关不得重挂载设置行子树（结构恒定化契约）',
    );
    expect(tester.binding.hasScheduledFrame, isTrue,
        reason: '值翻转后滑块动画应在运行（有排帧）');
    await tester.pumpAndSettle();
    expect(focusNav, isTrue);

    // 反向再翻一次（enabled true→false 同样不得重挂载）。
    await tester.tap(find.byType(Switch));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(
      identical(tester.element(find.byType(Switch)), switchElementBefore),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(focusNav, isFalse);
  });
}
