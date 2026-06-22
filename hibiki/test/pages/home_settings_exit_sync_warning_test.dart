import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';

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
/// 这里无法直接构造 `_HomePageState`（私有 + 需 AppModel/DB），故用与生产同构的两层
/// PopScope 树复现 OR-veto 遍历行为：外层同步 PopScope 套用 [shouldWarnOnExit] 收窄、
/// 内层设置 PopScope canPop:false 拦截，告警换成可被 finder 探测的占位 dialog。撤掉
/// 修复（外层不收窄、syncing 时无条件弹）则此测试转红。
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

  group('两层 PopScope 同步告警收窄（widget 行为）', () {
    // 由内层 Builder 捕获的页面级 context，供顶层 PopScope 回调里 showDialog 使用，
    // 与生产中 _HomePageState 的 context 角色一致。
    late BuildContext pageContext;

    // 与生产同构的两层 PopScope 外壳：外层同步态、内层设置 tab。
    // [isSettingsTab] 控制是否构造内层（生产里设置 tab 才挂 HomeSettingsTabContent）。
    Widget buildLayered({
      required bool syncing,
      required bool isSettingsTab,
    }) {
      Widget inner = Builder(builder: (BuildContext ctx) {
        pageContext = ctx;
        return const Center(child: Text('home-body'));
      });
      if (isSettingsTab) {
        // 内层设置 PopScope：拦截返回（canPop:false），不弹任何告警。
        inner = PopScope(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? result) {},
          child: inner,
        );
      }
      // 外层同步 PopScope：与生产一致地用 shouldWarnOnExit 收窄到非设置 tab 才弹告警。
      return MaterialApp(
        home: PopScope(
          canPop: !syncing,
          onPopInvokedWithResult: (bool didPop, Object? result) async {
            if (didPop) return;
            if (!shouldWarnOnExit(
              syncing: syncing,
              isSettingsTab: isSettingsTab,
            )) {
              return;
            }
            await showDialog<void>(
              context: pageContext,
              builder: (BuildContext ctx) =>
                  const AlertDialog(content: Text('sync-warning-dialog')),
            );
          },
          child: inner,
        ),
      );
    }

    testWidgets('FIX: 设置 tab + 同步中 按返回 → 不弹同步告警（OR-veto 遍历仍被收窄拦下）',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildLayered(
        syncing: true,
        isSettingsTab: true,
      ));
      await tester.pumpAndSettle();

      // 系统返回：route 被内层 canPop:false 否决（不 pop），但所有 PopScope 回调遍历。
      final bool handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: 'OR-veto：任一 canPop:false → 返回被消费、不退出');
      expect(find.text('sync-warning-dialog'), findsNothing,
          reason: '设置 tab 上即使同步中，顶层也不得弹同步告警（TODO-698 根因）');
    });

    testWidgets('回归保护：非设置 tab + 同步中 按返回 → 仍弹同步告警', (WidgetTester tester) async {
      await tester.pumpWidget(buildLayered(
        syncing: true,
        isSettingsTab: false,
      ));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('sync-warning-dialog'), findsOneWidget,
          reason: '非设置 tab 同步中按返回必须仍弹同步告警，修复不能伤及正常退出拦截');
    });

    testWidgets('回归保护：未同步 时按返回不弹告警', (WidgetTester tester) async {
      await tester.pumpWidget(buildLayered(
        syncing: false,
        isSettingsTab: false,
      ));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('sync-warning-dialog'), findsNothing);
    });
  });
}
