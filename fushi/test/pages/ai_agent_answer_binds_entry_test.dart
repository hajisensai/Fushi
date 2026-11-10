// BUG-4282：确认 / 候选卡片的按钮必须把**自己那张卡片**的 id 交给作答接口。
//
// 本机 AiAgentController 在 entryId 为 null 时直接放行：对卡片 A 晚到的重复点击会
// 把下一张确认卡 B 同意掉。控制器层与远端会话的测试都绕过了页面，这里守住页面接线。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:material_ui/material_ui.dart';

class _RecordingController extends ChangeNotifier
    implements AiAgentConversationController {
  _RecordingController(this.entries);

  @override
  final List<AgentEntry> entries;

  final List<(bool, String?)> confirms = <(bool, String?)>[];
  final List<(String?, String?)> choices = <(String?, String?)>[];

  @override
  int get undoableCount => 0;
  @override
  int get totalTokens => 0;
  @override
  AiChatUsage get usage => const AiChatUsage();
  @override
  Map<String, double> get cost => const <String, double>{};
  @override
  bool get running => true;
  @override
  bool get awaitingConfirm => true;
  @override
  bool get awaitingChoice => true;
  @override
  void answerConfirm(bool approved, {String? entryId}) =>
      confirms.add((approved, entryId));
  @override
  void answerChoice(String? id, {String? entryId}) =>
      choices.add((id, entryId));
  @override
  bool get acceptsImages => false;
  @override
  Future<void> send(
    String text, {
    AgentUiContext? context,
    List<AiChatImage> images = const <AiChatImage>[],
  }) async {}
  @override
  Future<AgentUndoResult> undoEntry(String entryId) =>
      throw UnimplementedError();
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

// 直接构造：fromJson 会把存档里的「待答」读成已中断（见 ai_agent_interrupted_entries_test）。
List<AgentEntry> _pendingCards() => <AgentEntry>[
  AgentEntry(
    id: 'confirm-7',
    kind: AgentEntryKind.confirm,
    createdAt: 1,
    toolName: 'video.subtitle.generate',
    arguments: const <String, Object?>{'bookUid': 'video/x'},
    status: AgentEntryStatus.pending,
    risk: AgentToolRisk.write,
  ),
  AgentEntry(
    id: 'choice-9',
    kind: AgentEntryKind.choice,
    createdAt: 2,
    text: 'Which subtitle?',
    options: const <AgentChoiceOption>[
      AgentChoiceOption(id: 'a', label: 'A.srt'),
    ],
    status: AgentEntryStatus.pending,
  ),
];

Future<void> _pump(WidgetTester tester, _RecordingController controller) async {
  final ThemeData base = buildFushiThemeData(
    scheme: buildFushiColorScheme(
      seedColor: kFushiDefaultSeed,
      brightness: Brightness.light,
    ),
    designSystem: FushiDesignSystem.auto,
    glassDesign: false,
    textTheme: FushiTypeScale.buildTextTheme(const TextStyle()),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(platform: TargetPlatform.android),
      builder: (BuildContext context, Widget? app) =>
          FushiFocusRoot(child: app!),
      home: Scaffold(
        body: SizedBox(
          height: 900,
          child: AiAgentConversation(controller: controller),
        ),
      ),
    ),
  );
  // 运行中有进度动画，不能 pumpAndSettle。
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('确认 / 候选卡片的按钮把自己的卡片 id 交给作答接口', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.reset);

    final _RecordingController controller = _RecordingController(
      _pendingCards(),
    );
    await _pump(tester, controller);
    expect(tester.takeException(), isNull);

    for (final String key in <String>[
      'ai-agent-confirm-approve',
      'ai-agent-confirm-decline',
      'ai-agent-choice-a',
      'ai-agent-choice-cancel',
    ]) {
      final Finder button = find.byKey(ValueKey<String>(key));
      expect(button, findsOneWidget, reason: key);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
    }

    expect(controller.confirms, <(bool, String?)>[
      (true, 'confirm-7'),
      (false, 'confirm-7'),
    ]);
    expect(controller.choices, <(String?, String?)>[
      ('a', 'choice-9'),
      (null, 'choice-9'),
    ]);
  });
}
