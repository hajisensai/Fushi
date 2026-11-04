// BUG-4067：AI 助手界面上的「本地 AI / 远端 AI」切换按钮——只在能切（本机配了 AI、
// 又有已配对的执行设备）时出现；一轮跑着时不可点；浮层紧凑顶栏与整页页头各一个。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:material_ui/material_ui.dart';

class _FakeController extends ChangeNotifier
    implements AiAgentConversationController {
  bool _running = false;

  @override
  bool get running => _running;
  set running(bool value) {
    _running = value;
    notifyListeners();
  }

  @override
  List<AgentEntry> get entries => const <AgentEntry>[];
  @override
  int get undoableCount => 0;
  @override
  int get totalTokens => 0;
  @override
  AiChatUsage get usage => const AiChatUsage();
  @override
  Map<String, double> get cost => const <String, double>{};
  @override
  bool get awaitingConfirm => false;
  @override
  bool get awaitingChoice => false;
  @override
  void answerConfirm(bool approved) {}
  @override
  void answerChoice(String? id) {}
  @override
  bool get acceptsImages => false;
  @override
  Future<void> send(
    String text, {
    AgentUiContext? context,
    List<AiChatImage> images = const <AiChatImage>[],
  }) async {}
  @override
  Future<AgentUndoResult> undoEntry(String entryId) async =>
      const AgentUndoResult(AgentUndoStatus.notUndoable);
  @override
  Future<List<AgentUndoResult>> undoAll() async => const <AgentUndoResult>[];
  @override
  void cancel() {}
  @override
  Future<void> newSession() async {}
  @override
  String? get executorLabel => null;
  @override
  AiAgentSessionLibrary? get sessionLibrary => null;
}

void main() {
  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget home, {
    required bool apple,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme(apple: apple),
        builder: (BuildContext context, Widget? child) =>
            FushiGlassScope(child: child!),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// MD3 走 `Tooltip`，Apple（玻璃）走 `FushiTooltip`。
  Finder tooltip(String message) => find.byWidgetPredicate(
    (Widget w) =>
        (w is Tooltip && w.message == message) ||
        (w is FushiTooltip && w.message == message),
  );

  // 一轮跑着时有进度动画，pumpAndSettle 等不到静止：按固定时长推帧。
  Future<void> settleRunning(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 500));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds：浮层顶栏——能切才出按钮，跑着时不可点', (WidgetTester tester) async {
      final _FakeController controller = _FakeController();
      addTearDown(controller.dispose);
      await pump(
        tester,
        Scaffold(
          body: AiAgentConversation(controller: controller, compact: true),
        ),
        apple: apple,
      );
      expect(find.byKey(kAiAgentExecutorSwitchKey), findsNothing);

      int switched = 0;
      await pump(
        tester,
        Scaffold(
          body: AiAgentConversation(
            controller: controller,
            compact: true,
            switchExecutorTooltip: 'Use the AI on PC',
            onSwitchExecutor: () => switched++,
          ),
        ),
        apple: apple,
      );
      expect(find.byKey(kAiAgentExecutorSwitchKey), findsOneWidget);
      expect(tooltip('Use the AI on PC'), findsOneWidget);
      await tester.tap(find.byKey(kAiAgentExecutorSwitchKey));
      await tester.pumpAndSettle();
      expect(switched, 1);

      controller.running = true;
      await settleRunning(tester);
      await tester.tap(
        find.byKey(kAiAgentExecutorSwitchKey),
        warnIfMissed: false,
      );
      await settleRunning(tester);
      expect(switched, 1, reason: '一轮跑着时不切');
      controller.running = false;
      await tester.pumpAndSettle();
    });

    testWidgets('$ds：整页页头的切换按钮', (WidgetTester tester) async {
      final _FakeController controller = _FakeController();
      addTearDown(controller.dispose);
      int switched = 0;
      await pump(
        tester,
        AiAgentPage(
          controller: controller,
          switchExecutorTooltip: "Use this device's AI",
          onSwitchExecutor: () => switched++,
        ),
        apple: apple,
      );
      expect(find.byKey(kAiAgentExecutorSwitchKey), findsOneWidget);
      await tester.tap(find.byKey(kAiAgentExecutorSwitchKey));
      await tester.pumpAndSettle();
      expect(switched, 1);

      controller.running = true;
      await settleRunning(tester);
      await tester.tap(
        find.byKey(kAiAgentExecutorSwitchKey),
        warnIfMissed: false,
      );
      await settleRunning(tester);
      expect(switched, 1);
      controller.running = false;
      await tester.pumpAndSettle();
    });
  }
}
