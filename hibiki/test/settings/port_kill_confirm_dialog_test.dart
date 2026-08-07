import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/port_kill_confirm.dart';
import 'package:fushi/src/sync/port_process_terminator.dart';
import 'package:fushi/src/utils/components/hibiki_destructive_confirm_dialog.dart';

/// 「一键结束占用端口进程」杀前确认弹窗（PR#420 审查红线修复）的 widget 测试。
///
/// 焦点驱动纪律：不使用 tester.tap；取消走 Esc（sendKeyEvent），确认直接调用
/// 按钮回调断言。[decidePortKill] 只做决策不做杀——未确认路径断言返回
/// cancelled 且 finder 只被调用一次（连杀前复核都没走，更到不了 terminate）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  const PortListenerInfo pythonListener = PortListenerInfo(
    pid: 188544,
    processName: 'python.exe',
    executablePath: r'C:\Tools\python\python.exe',
  );

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  testWidgets('确认弹窗展示占用者（进程名+PID+路径），Esc 取消 → cancelled 不杀',
      (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    int finderCalls = 0;
    final Future<PortKillDecision> decisionFuture = decidePortKill(
      context,
      port: 19633,
      findListener: (int port) async {
        finderCalls++;
        return pythonListener;
      },
      isSelfInstance: (PortListenerInfo _) => false,
    );
    await tester.pumpAndSettle();

    expect(find.byType(FushiDestructiveConfirmDialog), findsOneWidget);
    expect(
      find.text(t.yomitan_port_kill_confirm_title(port: 19633)),
      findsOneWidget,
    );
    expect(find.textContaining('python.exe (PID 188544)'), findsOneWidget);
    expect(find.textContaining(r'C:\Tools\python\python.exe'), findsOneWidget);
    // 非自身实例：不出现「本应用另一个实例」标注。
    expect(
      find.textContaining(t.yomitan_port_kill_self_instance),
      findsNothing,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final PortKillDecision decision = await decisionFuture;
    expect(decision.kind, PortKillDecisionKind.cancelled);
    // 未确认 → 不做杀前复核（finder 只调一次），terminate 更无从谈起。
    expect(finderCalls, 1);
    expect(find.byType(FushiDestructiveConfirmDialog), findsNothing);
  });

  testWidgets('占用者是 hibiki 自身旧实例 → 弹窗明确标注本应用另一实例', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<PortKillDecision> decisionFuture = decidePortKill(
      context,
      port: 19633,
      findListener: (int port) async => pythonListener,
      isSelfInstance: (PortListenerInfo _) => true,
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(t.yomitan_port_kill_self_instance),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect((await decisionFuture).kind, PortKillDecisionKind.cancelled);
  });

  testWidgets('占用者是系统进程（svchost）→ refusedProtected 且不弹确认框',
      (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<PortKillDecision> decisionFuture = decidePortKill(
      context,
      port: 19633,
      findListener: (int port) async => const PortListenerInfo(
        pid: 1544,
        processName: 'svchost.exe',
      ),
      isSelfInstance: (PortListenerInfo _) => false,
    );
    await tester.pumpAndSettle();

    expect(find.byType(FushiDestructiveConfirmDialog), findsNothing);
    final PortKillDecision decision = await decisionFuture;
    expect(decision.kind, PortKillDecisionKind.refusedProtected);
    expect(decision.listener!.processName, 'svchost.exe');
  });

  testWidgets('确认（直接调用确认按钮回调）→ 同 PID 复核通过 → confirmed',
      (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<PortKillDecision> decisionFuture = decidePortKill(
      context,
      port: 19633,
      findListener: (int port) async => pythonListener,
      isSelfInstance: (PortListenerInfo _) => false,
    );
    await tester.pumpAndSettle();

    final FilledButton confirmButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, t.yomitan_port_kill_confirm),
    );
    confirmButton.onPressed!();
    await tester.pumpAndSettle();

    final PortKillDecision decision = await decisionFuture;
    expect(decision.kind, PortKillDecisionKind.confirmed);
    expect(decision.listener!.pid, 188544);
  });

  testWidgets('确认期间占用者换人（PID 变化）→ listenerChanged 放弃杀',
      (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    int finderCalls = 0;
    final Future<PortKillDecision> decisionFuture = decidePortKill(
      context,
      port: 19633,
      findListener: (int port) async {
        finderCalls++;
        return finderCalls == 1
            ? pythonListener
            : const PortListenerInfo(pid: 4242, processName: 'node.exe');
      },
      isSelfInstance: (PortListenerInfo _) => false,
    );
    await tester.pumpAndSettle();

    final FilledButton confirmButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, t.yomitan_port_kill_confirm),
    );
    confirmButton.onPressed!();
    await tester.pumpAndSettle();

    final PortKillDecision decision = await decisionFuture;
    expect(decision.kind, PortKillDecisionKind.listenerChanged);
    expect(decision.listener!.pid, 4242);
    expect(finderCalls, 2);
  });
}
