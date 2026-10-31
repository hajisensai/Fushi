// 横屏手机 + 软键盘：AI 助手浮层的输入框与对话区必须保持可见。
//
// 现象（用户截图）：横屏播视频时点「问 AI」，输入框自动聚焦弹出键盘，浮动面板被
// 压成 ~130dp 的一条，标题栏 + 上下文 chip 把高度吃光，对话列表高度为 0、输入框被
// 裁掉，既不能输入也不能滚动。
//
// 断言：
// - 键盘上方的浮层里，输入框完整可见、对话列表仍有可读高度；
// - 紧凑排版仍能看到并点掉页面上下文（点掉后发送不再带上下文）；
// - 键盘弹起切进紧凑排版时输入框不被重建、焦点不丢。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:material_ui/material_ui.dart';

class _FakeController extends ChangeNotifier
    implements AiAgentConversationController {
  /// 每次 [send] 收到的上下文（null = 没带上下文）。
  final List<AgentUiContext?> sentContexts = <AgentUiContext?>[];

  @override
  final List<AgentEntry> entries = <AgentEntry>[
    AgentEntry(
      id: 'u1',
      kind: AgentEntryKind.user,
      createdAt: 1,
      text: 'Who is the lead in this episode?',
    ),
    AgentEntry(
      id: 'a1',
      kind: AgentEntryKind.assistant,
      createdAt: 2,
      text: 'The lead is played by the actor shown in the cast list.',
    ),
  ];

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
  }) async {
    sentContexts.add(context);
  }

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

const Size _landscape = Size(800, 360);
const double _keyboard = 200;

const ValueKey<String> _inputKey = ValueKey<String>('ai-agent-input');
const ValueKey<String> _chipKey = ValueKey<String>('ai-agent-context-chip');
const ValueKey<String> _inlineKey = ValueKey<String>(
  'ai-agent-inline-attachments',
);

void _setView(WidgetTester tester, Size logical, {double keyboard = 0}) {
  const double dpr = 2.75;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
}

Future<void> _openPanel(WidgetTester tester, _FakeController controller) async {
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
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => adaptiveModalSheet<void>(
                context: context,
                expandable: true,
                builder: (BuildContext sheetContext) => SizedBox(
                  height: MediaQuery.sizeOf(sheetContext).height * 0.55,
                  child: AiAgentConversation(
                    controller: controller,
                    uiContext: const AgentUiContext(
                      scene: 'video',
                      itemTitle: 'Against the Current S01E13 Episode 13',
                    ),
                    compact: true,
                    onExpand: () {},
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool _chipInline() => find
    .descendant(of: find.byKey(_inlineKey), matching: find.byKey(_chipKey))
    .evaluate()
    .isNotEmpty;

void main() {
  testWidgets('landscape phone + keyboard: input and transcript stay visible', (
    WidgetTester tester,
  ) async {
    _setView(tester, _landscape, keyboard: _keyboard);
    addTearDown(tester.view.reset);

    await _openPanel(tester, _FakeController());
    expect(tester.takeException(), isNull);

    final Finder input = find.byKey(_inputKey);
    expect(input, findsOneWidget);
    final Rect inputRect = tester.getRect(input);
    expect(
      inputRect.bottom,
      lessThanOrEqualTo(_landscape.height - _keyboard + 0.5),
      reason: 'input must sit above the keyboard',
    );
    expect(inputRect.height, greaterThan(20), reason: 'input is not clipped');
    expect(inputRect.top, greaterThanOrEqualTo(0));

    final Rect transcript = tester.getRect(
      find.byKey(const ValueKey<String>('ai-agent-transcript')),
    );
    expect(
      transcript.height,
      greaterThanOrEqualTo(40),
      reason: 'conversation list must keep a readable height',
    );
  });

  testWidgets(
    'tight mode keeps a removable context chip in the input row; removing '
    'it drops the context from the next message',
    (WidgetTester tester) async {
      _setView(tester, _landscape, keyboard: _keyboard);
      addTearDown(tester.view.reset);

      final _FakeController controller = _FakeController();
      await _openPanel(tester, controller);
      expect(tester.takeException(), isNull);

      // 上下文 chip 仍在，收进了输入行，且与输入框同一行、都在键盘上方。
      expect(find.byKey(_chipKey), findsOneWidget);
      expect(_chipInline(), isTrue);
      final Rect chip = tester.getRect(find.byKey(_chipKey));
      final Rect input = tester.getRect(find.byKey(_inputKey));
      expect(chip.right, lessThanOrEqualTo(input.left + 0.5));
      expect(chip.bottom, lessThanOrEqualTo(_landscape.height - _keyboard));
      expect(chip.top, greaterThanOrEqualTo(input.top - 24));
      // 输入框变窄后提示语不折行撑高输入栏（否则对话区被挤掉）。
      final Rect send = tester.getRect(
        find.byKey(const ValueKey<String>('ai-agent-send')),
      );
      expect(input.height, lessThanOrEqualTo(send.height + 4));
      // 长标题被截断，chip 不超过输入行宽度的上限（删除键始终在 chip 内可见）。
      final Rect row = tester.getRect(find.byKey(_inlineKey));
      expect(row.width, lessThan(_landscape.width * 0.5));
      expect(find.byKey(_chipKey).hitTestable(), findsOneWidget);

      // 先发一条：带着上下文。
      await tester.enterText(find.byKey(_inputKey), 'first');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(controller.sentContexts, hasLength(1));
      expect(
        controller.sentContexts.single?.itemTitle,
        'Against the Current S01E13 Episode 13',
      );

      // 点掉 chip 的删除键：chip 消失，下一条不再带上下文。
      final Rect chipNow = tester.getRect(find.byKey(_chipKey));
      await tester.tapAt(chipNow.centerRight - const Offset(14, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(_chipKey), findsNothing);

      await tester.enterText(find.byKey(_inputKey), 'second');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(controller.sentContexts, hasLength(2));
      expect(controller.sentContexts.last, isNull);
    },
  );

  testWidgets('roomy panel shows the context chip above the input row', (
    WidgetTester tester,
  ) async {
    _setView(tester, const Size(800, 900));
    addTearDown(tester.view.reset);

    await _openPanel(tester, _FakeController());
    expect(find.byKey(_chipKey), findsOneWidget);
    expect(find.byKey(_inlineKey), findsNothing);
    expect(
      tester.getRect(find.byKey(_chipKey)).bottom,
      lessThanOrEqualTo(tester.getRect(find.byKey(_inputKey)).top + 0.5),
    );
  });

  testWidgets('keyboard switching into tight mode keeps the input focused', (
    WidgetTester tester,
  ) async {
    _setView(tester, const Size(800, 900));
    addTearDown(tester.view.reset);

    await _openPanel(tester, _FakeController());
    expect(find.byKey(_inlineKey), findsNothing);
    final Finder editable = find.descendant(
      of: find.byKey(_inputKey),
      matching: find.byType(EditableText),
    );
    await tester.showKeyboard(find.byKey(_inputKey));
    await tester.pump();
    final EditableTextState before = tester.state<EditableTextState>(editable);
    expect(before.widget.focusNode.hasFocus, isTrue);

    _setView(tester, _landscape, keyboard: _keyboard);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_chipInline(), isTrue, reason: 'switched into tight mode');

    final EditableTextState after = tester.state<EditableTextState>(editable);
    expect(identical(after, before), isTrue, reason: 'input not rebuilt');
    expect(after.widget.focusNode.hasFocus, isTrue, reason: 'focus kept');
  });
}
