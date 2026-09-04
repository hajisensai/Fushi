import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_import_overlay_view.dart';
import 'package:fushi/src/sync/backup_validating_overlay_route.dart';

/// BUG-2106 行为测试：「正在读取备份…」遮罩必须**压在调用方页面之上**，而不是把整棵
/// app 树换掉。
///
/// 原实现让 `main.dart` 根 build 在校验期返回另一个根 widget（不同 runtimeType）→ 整棵
/// MaterialApp/Navigator unmount → 调用方页面（新手引导向导）与其全部 State 当场蒸发，
/// `await Navigator.push(向导)` 的 future 永不完成。这里用真 Navigator 把不变式钉死：
/// 遮罩在栈上时调用方页面仍在树里、其 State 未被销毁，摘掉遮罩后原页面原样回来。
void main() {
  Widget host({
    required GlobalKey<NavigatorState> navigatorKey,
    required Widget caller,
  }) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      home: caller,
    );
  }

  testWidgets('遮罩路由压在调用方页面之上：调用方 State 不被销毁', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final _CallerProbeState probe = _CallerProbeState();
    await tester.pumpWidget(
      host(navigatorKey: navKey, caller: _CallerProbe(state: probe)),
    );
    expect(find.text('caller'), findsOneWidget);
    expect(probe.disposed, isFalse);
    // 调用方在自己的 State 里存了进度（向导的 _stepIndex 同理）。
    probe.step = 7;

    final Route<void> route = buildBackupValidatingOverlayRoute(
      onCancel: () {},
    );
    navKey.currentState!.push<void>(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(BackupImportOverlayView), findsOneWidget,
        reason: '校验遮罩应已在栈顶');
    expect(
      probe.disposed,
      isFalse,
      reason: 'BUG-2106：调用方页面（引导向导）不得随遮罩上屏而被销毁',
    );
    expect(find.text('caller', skipOffstage: false), findsOneWidget,
        reason: '调用方页面仍在树里（只是被不透明遮罩盖住）');

    // 摘除必须走 removeRoute：路由带 PopScope(canPop:false)，pop 摘不掉。
    navKey.currentState!.removeRoute<void>(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(BackupImportOverlayView), findsNothing);
    expect(find.text('caller'), findsOneWidget);
    expect(probe.disposed, isFalse);
    expect(probe.step, 7, reason: '调用方 State 的进度必须原样还在（没被重建过）');
  });

  testWidgets('系统返回不得穿过遮罩把调用方页面 pop 掉', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final _CallerProbeState probe = _CallerProbeState();
    await tester.pumpWidget(
      host(navigatorKey: navKey, caller: _CallerProbe(state: probe)),
    );
    // 调用方页面之上再压一层「向导页」，模拟真实栈：home → 向导 → 遮罩。
    navKey.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Text('wizard')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('wizard'), findsOneWidget);

    final Route<void> route = buildBackupValidatingOverlayRoute(
      onCancel: () {},
    );
    navKey.currentState!.push<void>(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // 安卓系统返回 / 手势返回：事件走 WidgetsApp → Navigator.maybePop，栈顶是遮罩。
    final bool popped = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(popped, isTrue, reason: '返回事件应被栈顶的遮罩路由消费（而不是冒泡到 app 退出）');
    expect(find.byType(BackupImportOverlayView), findsOneWidget,
        reason: 'PopScope(canPop:false)：遮罩自身也不该被返回键弹掉');
    expect(find.text('wizard', skipOffstage: false), findsOneWidget,
        reason: 'BUG-2106：返回键绝不能把遮罩底下的向导页 pop 掉');

    navKey.currentState!.removeRoute<void>(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('wizard'), findsOneWidget);
  });

  testWidgets('取消按钮接线到调用方注入的回调', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    int cancelled = 0;
    await tester.pumpWidget(
      host(navigatorKey: navKey, caller: const Text('caller')),
    );
    final Route<void> route = buildBackupValidatingOverlayRoute(
      onCancel: () => cancelled++,
    );
    navKey.currentState!.push<void>(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final Finder cancel = find.byType(OutlinedButton);
    expect(cancel, findsOneWidget, reason: 'validating 相位必须有取消出口');
    await tester.tap(cancel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(cancelled, 1);
  });
}

/// 调用方页面的存活探针：`dispose` 被调用即说明整棵树被换掉了（BUG-2106 的病征）。
class _CallerProbeState {
  bool disposed = false;
  int step = 0;
}

class _CallerProbe extends StatefulWidget {
  const _CallerProbe({required this.state});

  final _CallerProbeState state;

  @override
  State<_CallerProbe> createState() => _CallerProbeStateWidget();
}

class _CallerProbeStateWidget extends State<_CallerProbe> {
  @override
  void dispose() {
    widget.state.disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('caller');
}
