import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';

/// TODO-698 (BUG-397) 守卫：设置 tab + app-open 同步同时进行时按系统返回键，**不得**
/// 弹「同步进行中」告警。
///
/// 根因：home 同一路由挂两个 [PopScope]——顶层同步 `PopScope(canPop:!syncing)` 在
/// syncing 时回调弹 `_SyncExitWarningDialog`；内层设置 tab `PopScope(canPop:false)`
/// 拦截返回切回来源 tab（BUG-236）。Flutter 同 route 多 PopScope 的 popDisposition 按
/// OR 聚合（任一 canPop:false 即 route 不 pop），但 dispatch 时**所有** PopScope 的
/// onPopInvokedWithResult 都被遍历调用（didPop=false）。故设置 tab 同步进行时按返回：
/// route 被内层 doNotPop（正确），但顶层回调也触发 → 误弹同步告警。
///
/// 修复：顶层 onPopInvokedWithResult 在 `if(didPop) return;` 之后，按当前 tab 自我收窄
/// `if (_visibleTab == settings) return;`，等价于纯函数 [shouldWarnOnExit]。
///
/// BUG-3305：顶层拦截抽成生产组件 [HomeSyncExitScope]，widget 测试直接挂它（不再用
/// 同构镜像树——镜像判了 syncing 而生产没判，镜像测试恒绿、bug 照样上线）。
void main() {
  group('shouldWarnOnExit 纯函数', () {
    test('未同步：任何 tab 都不告警', () {
      expect(shouldWarnOnExit(syncing: false, isSettingsTab: false), isFalse);
      expect(shouldWarnOnExit(syncing: false, isSettingsTab: true), isFalse);
    });

    test('同步中 + 非设置 tab：告警', () {
      expect(shouldWarnOnExit(syncing: true, isSettingsTab: false), isTrue);
    });

    test('同步中 + 设置 tab：不告警（设置 tab 返回归内层 PopScope）', () {
      expect(shouldWarnOnExit(syncing: true, isSettingsTab: true), isFalse);
    });
  });

  group('HomeSyncExitScope（生产组件）同步告警收窄', () {
    // 直接挂生产的 [HomeSyncExitScope]（原来这里是一棵「与生产同构」的镜像树，
    // 镜像里判了 syncing、生产里却没判——镜像测试全绿，BUG-3305 照样上线）。
    // [inner] 模拟同 route 上的内层 PopScope：设置 tab（切回来源 tab）或查词页
    // （有查询时先清查询）。
    late ValueNotifier<bool> syncing;
    late int innerBackCount;

    setUp(() {
      LocaleSettings.setLocale(AppLocale.en);
      syncing = ValueNotifier<bool>(false);
      innerBackCount = 0;
    });
    tearDown(() => syncing.dispose());

    Widget build({required bool isSettingsTab, required bool innerBlocks}) {
      Widget body = const Center(child: Text('home-body'));
      if (innerBlocks) {
        body = PopScope(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop) innerBackCount++;
          },
          child: body,
        );
      }
      return MaterialApp(
        home: Scaffold(
          body: HomeSyncExitScope(
            syncing: syncing,
            isSettingsTab: () => isSettingsTab,
            child: body,
          ),
        ),
      );
    }

    final Finder warning = find.text(t.sync_exit_warning_title);

    testWidgets('BUG-3305：同步没在跑 + 查词页有查询拦下返回 → 不弹同步告警', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(build(isSettingsTab: false, innerBlocks: true));
      await tester.pumpAndSettle();

      final bool handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: '内层拦下返回（清查询），route 不 pop');
      expect(innerBackCount, 1, reason: '返回由查词页消费（清掉查询）');
      expect(
        warning,
        findsNothing,
        reason:
            '同 route 多 PopScope 回调全部遍历：别人拦返回时这里也会被调，'
            '必须按 syncing 当前值判，不能无条件弹「同步进行中」',
      );
    });

    testWidgets('设置 tab + 同步中 按返回 → 不弹同步告警（TODO-698）', (
      WidgetTester tester,
    ) async {
      syncing.value = true;
      await tester.pumpWidget(build(isSettingsTab: true, innerBlocks: true));
      await tester.pumpAndSettle();

      final bool handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue);
      expect(warning, findsNothing);
    });

    testWidgets('回归保护：非设置 tab + 同步中 按返回 → 仍弹同步告警', (WidgetTester tester) async {
      syncing.value = true;
      await tester.pumpWidget(build(isSettingsTab: false, innerBlocks: false));
      await tester.pumpAndSettle();

      final bool handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: '同步中返回必须被拦下，不能直接退出');
      expect(warning, findsOneWidget, reason: '修复不能伤及真正的同步中退出拦截');
    });

    testWidgets('同步在回调前已结束 → 不弹告警（读实时值，不是 build 快照）', (
      WidgetTester tester,
    ) async {
      syncing.value = true;
      await tester.pumpWidget(build(isSettingsTab: false, innerBlocks: true));
      await tester.pumpAndSettle();
      // 不 pump：PopScope 仍是 canPop:false 的那一版，但同步已经结束。
      syncing.value = false;

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(warning, findsNothing);
    });
  });

  test('源码守卫：首页顶层退出拦截走的就是 HomeSyncExitScope', () {
    // 上面的 widget 测试只证明组件对；这里钉住首页真的挂它，而不是又手写一份
    // PopScope（那份手写正是 BUG-3305 的来源）。
    final String src = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();
    final int buildAt = src.indexOf('final Widget home = ');
    expect(buildAt, isNonNegative);
    expect(
      src.substring(buildAt, buildAt + 120),
      contains('HomeSyncExitScope('),
    );
    expect(
      'valueListenable: syncInProgress,'.allMatches(src).length,
      0,
      reason: '顶层同步告警只能在 HomeSyncExitScope 内读在飞标志',
    );
  });
}
