import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

/// BUG-236 守卫：安卓大屏（以及任意尺寸）在设置 tab 按系统返回键时，必须被设置 tab
/// 自己的 [PopScope] 拦截并切回来源 tab，而不是冒泡到 home 顶层 PopScope 退出 app。
///
/// 设置是 home 的一个内容 tab（无独立路由层级），返回键过去直接冒泡到顶层
/// `PopScope(canPop: !syncing)` → 非同步时 pop 掉 home 路由 = 退出 app。修复给设置
/// 内容包了 `PopScope(canPop: false, onPopInvokedWithResult: 切回来源 tab)`。
///
/// 这里直接构造 [HomeSettingsTabContent]（home 两个渲染分支共用的真实外壳），注入轻量
/// 占位 child 以独立验证 PopScope 拦截行为，避开构造完整 HomePage 所需的 AppModel/DB。
void main() {
  /// 把内容包进有 root Navigator 的 MaterialApp，使 `handlePopRoute()` 能驱动
  /// PopScope（模拟 Android 系统返回键 / 手势返回）。
  Future<bool> sendSystemBack(WidgetTester tester) async {
    // handlePopRoute 返回 true 表示返回事件被某层 PopScope 消费（未退出 app）。
    return tester.binding.handlePopRoute();
  }

  testWidgets('FIX: 设置 tab 系统返回键被拦截并切回来源 tab（大屏不退出 app）',
      (WidgetTester tester) async {
    // 大屏约束，覆盖 TODO-285 报告的安卓大屏场景。
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    int returnCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: HomeSettingsTabContent(
        onReturnToPreviousTab: () => returnCalls++,
        child: const Text('settings-body'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('settings-body'), findsOneWidget);

    final bool handled = await sendSystemBack(tester);
    await tester.pump();

    // 返回事件被设置 tab 的 PopScope 消费（未冒泡出去 = 不退出 app）。
    expect(handled, isTrue, reason: '系统返回必须被设置 tab 的 PopScope 消费，而非退出 app');
    // 拦截后切回来源 tab。
    expect(returnCalls, 1, reason: '拦截后应回调 onReturnToPreviousTab 切回来源 tab');
  });

  testWidgets('PopScope canPop 为 false 阻止设置 tab 上的返回冒泡退出',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeSettingsTabContent(
        onReturnToPreviousTab: () {},
        child: const Text('settings-body'),
      ),
    ));
    await tester.pumpAndSettle();

    final Finder popScopeFinder = find.byWidgetPredicate(
      (Widget w) => w is PopScope,
    );
    expect(popScopeFinder, findsOneWidget,
        reason: '设置 tab 外壳必须含一个 PopScope 拦截层');
    final PopScope<Object?> popScope =
        tester.widget(popScopeFinder) as PopScope<Object?>;
    expect(popScope.canPop, isFalse,
        reason: '设置 tab 必须 canPop:false 才能拦截系统返回键');
  });

  testWidgets('showBackButton 为 false 时不显示页头返回箭头（移动底栏 / 宽屏侧栏在侧）',
      (WidgetTester tester) async {
    int returnCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: HomeSettingsTabContent(
        showBackButton: false,
        onReturnToPreviousTab: () => returnCalls++,
        child: const Text('settings-body'),
      ),
    ));
    await tester.pumpAndSettle();

    // 注入了 child，HibikiSettingsContent 不渲染，无箭头；但 PopScope 仍生效。
    final bool handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue);
    expect(returnCalls, 1);
  });
}
