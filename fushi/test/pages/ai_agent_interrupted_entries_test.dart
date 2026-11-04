// 反馈 qg_L2sVx3p：一轮跑到一半（等确认卡片时）存档落盘、进程没了，读回的会话里
// 那一步显示成空白的「失败：」、确认卡片显示成用户从没点过的「已拒绝」。
//
// 断言：存档读回的在途工具条目显示「已中断」，没作答的确认卡片 / 候选卡片显示
// 「未作答：中断了」，不再冒充失败原因为空的失败、也不冒充用户的拒绝。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:material_ui/material_ui.dart';

class _RestoredController extends ChangeNotifier
    implements AiAgentConversationController {
  _RestoredController(this.entries);

  @override
  final List<AgentEntry> entries;

  @override
  int get undoableCount => 0;
  @override
  int get totalTokens => 0;
  @override
  AiChatUsage get usage => const AiChatUsage();
  @override
  Map<String, double> get cost => const <String, double>{};
  @override
  bool get running => false;
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

/// 存档里的样子：工具条目还在跑、确认卡片 / 候选卡片还在等作答。
List<AgentEntry> _restoredMidTurn() => <AgentEntry>[
  for (final Map<String, Object?> json in <Map<String, Object?>>[
    <String, Object?>{
      'id': 's-1',
      'kind': 'user',
      'createdAt': 1,
      'text': 'Fill the subtitles',
      'status': 'none',
    },
    <String, Object?>{
      'id': 's-2',
      'kind': 'toolCall',
      'createdAt': 2,
      'toolName': 'video.subtitle.generate',
      'status': 'running',
      'risk': 'irreversible',
    },
    <String, Object?>{
      'id': 's-3',
      'kind': 'confirm',
      'createdAt': 3,
      'toolName': 'video.subtitle.generate',
      'arguments': <String, Object?>{'bookUid': 'video/x'},
      'status': 'pending',
      'risk': 'irreversible',
    },
    <String, Object?>{
      'id': 's-4',
      'kind': 'choice',
      'createdAt': 4,
      'text': 'Which subtitle?',
      'options': <Object?>[
        <String, Object?>{'id': 'a', 'label': 'A.srt'},
      ],
      'status': 'pending',
    },
  ])
    AgentEntry.fromJson(json),
];

Future<void> _pump(WidgetTester tester, _RestoredController controller) async {
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
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'restored mid-turn entries say interrupted, not failed/declined',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1000);
      addTearDown(tester.view.reset);

      await _pump(tester, _RestoredController(_restoredMidTurn()));
      expect(tester.takeException(), isNull);

      expect(find.text(t.ai_agent_tool_interrupted), findsOneWidget);
      expect(
        find.text(t.ai_agent_confirm_interrupted),
        findsNWidgets(2),
        reason: '没作答的确认卡片与候选卡片',
      );
      expect(find.text(t.ai_agent_tool_failed(code: '')), findsNothing);
      expect(find.text(t.ai_agent_confirm_declined), findsNothing);
      expect(find.text(t.ai_agent_choice_cancel), findsNothing);
    },
  );
}
