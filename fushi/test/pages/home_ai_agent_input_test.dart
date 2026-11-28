// 首页 AI 助手块的真输入框：回车（文本框的 send 动作）把这句话作为 initialPrompt
// 交给 openAiAgent；框持焦时打字不被首页 / 全局快捷键解析；浮层对话区就绪后把
// initialPrompt 当第一句话发出且只发一次。
//
// 焦点驱动：Tab 把焦点送进输入框，按键（含回车）一律走 sendKeyEvent；软键盘的
// 「发送」另走 text input 的 send 动作。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_conversation_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/pages/implementations/home_ai_agent_panel.dart';
import 'package:fushi/src/shortcuts/text_field_key_ownership.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme() => buildFushiThemeData(
  scheme: buildFushiColorScheme(
    seedColor: kFushiDefaultSeed,
    brightness: Brightness.light,
  ),
  glassDesign: false,
  textTheme: FushiTypeScale.buildTextTheme(const TextStyle()),
).copyWith(platform: TargetPlatform.windows);

/// 记下 [HomeAiAgentOpener] 的每次调用（值 = initialPrompt）。[opened] = 浮层
/// 是否真的开了（false 模拟没指派提供商、只引导去设置）。
class _OpenerSpy {
  _OpenerSpy({this.opened = true});

  final bool opened;
  final List<String?> prompts = <String?>[];

  Future<bool> call(BuildContext context, {String? initialPrompt}) async {
    prompts.add(initialPrompt);
    return opened;
  }
}

/// 外层模拟首页整页 key sink：记下冒泡上来的每个按下沿，以及此刻判据是否认为
/// 它归文本框。
class _SinkLog {
  final List<(LogicalKeyboardKey, bool)> keys = <(LogicalKeyboardKey, bool)>[];
}

Future<void> _pumpPanel(
  WidgetTester tester,
  _OpenerSpy spy,
  _SinkLog log,
) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: Scaffold(
        // 与真首页一样，整页 key sink 自己持焦（HomePage 的 `_keyboardFocusNode`）：
        // 不持焦的话初始主焦点停在路由 FocusScope 上，按键根本不经过这里，
        // 「未持焦时裸字母归快捷键层」无从观察。skipTraversal 让 Tab 直接进块内。
        body: Focus(
          autofocus: true,
          skipTraversal: true,
          onKeyEvent: (FocusNode _, KeyEvent event) {
            if (event is KeyDownEvent) {
              log.keys.add((
                event.logicalKey,
                keyTypesIntoFocusedTextField(event),
              ));
            }
            return KeyEventResult.ignored;
          },
          child: Center(
            child: SizedBox(
              width: 600,
              child: HomeAiAgentPanel(opener: spy.call),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _RecordingController extends ChangeNotifier
    implements AiAgentConversationController {
  final List<String> sent = <String>[];

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
  bool get running => false;
  @override
  bool get awaitingConfirm => false;
  @override
  bool get awaitingChoice => false;
  @override
  void answerConfirm(bool approved, {String? entryId}) {}
  @override
  void answerChoice(String? id, {String? entryId}) {}
  @override
  bool get acceptsImages => false;
  @override
  Future<void> send(
    String text, {
    AgentUiContext? context,
    List<AiChatImage> images = const <AiChatImage>[],
  }) async {
    sent.add(text);
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

Finder get _field => find.descendant(
  of: find.byKey(const ValueKey<String>('home-ai-agent-panel-field')),
  matching: find.byType(EditableText),
);

bool _fieldFocused(WidgetTester tester) =>
    tester.widget<EditableText>(_field).focusNode.hasFocus;

/// 按 Tab 把焦点走进输入框（块本身也是焦点目标，可能先落在块上）。
Future<void> _tabIntoField(WidgetTester tester) async {
  for (int i = 0; i < 4 && !_fieldFocused(tester); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(_fieldFocused(tester), isTrue);
}

void main() {
  testWidgets('Tab 进输入框 → 打字 → 回车：openAiAgent 收到 initialPrompt 并清空输入', (
    WidgetTester tester,
  ) async {
    final _OpenerSpy spy = _OpenerSpy();
    final _SinkLog log = _SinkLog();
    await _pumpPanel(tester, spy, log);

    await _tabIntoField(tester);

    await tester.enterText(_field, '  帮我把这本书加进追踪  ');
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('home-ai-agent-panel-send')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(spy.prompts, <String?>['帮我把这本书加进追踪']);
    expect(tester.widget<EditableText>(_field).controller.text, isEmpty);
    expect(_fieldFocused(tester), isFalse);
  });

  testWidgets('空着回车：只打开浮层，不带 initialPrompt', (WidgetTester tester) async {
    final _OpenerSpy spy = _OpenerSpy();
    await _pumpPanel(tester, spy, _SinkLog());

    await _tabIntoField(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(spy.prompts, <String?>[null]);
  });

  testWidgets('浮层没开（没指派提供商）：那句话原样还回输入框，不丢', (WidgetTester tester) async {
    final _OpenerSpy spy = _OpenerSpy(opened: false);
    await _pumpPanel(tester, spy, _SinkLog());

    await _tabIntoField(tester);
    await tester.enterText(_field, '整理一下书架');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(spy.prompts, <String?>['整理一下书架']);
    expect(tester.widget<EditableText>(_field).controller.text, '整理一下书架');
  });

  testWidgets('软键盘「发送」动作同样带 initialPrompt', (WidgetTester tester) async {
    final _OpenerSpy spy = _OpenerSpy();
    await _pumpPanel(tester, spy, _SinkLog());

    await _tabIntoField(tester);
    await tester.enterText(_field, 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(spy.prompts, <String?>['hello']);
  });

  testWidgets('输入框持焦：可打印字符归文本框，Ctrl 组合 / Esc 仍归快捷键层', (
    WidgetTester tester,
  ) async {
    final _SinkLog log = _SinkLog();
    final _OpenerSpy spy = _OpenerSpy();
    await _pumpPanel(tester, spy, log);

    // 未持焦：裸字母不归任何文本框。
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    expect(log.keys.last, (LogicalKeyboardKey.keyN, false));

    await _tabIntoField(tester);
    log.keys.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    final Map<LogicalKeyboardKey, bool> owned = <LogicalKeyboardKey, bool>{
      for (final (LogicalKeyboardKey key, bool typed) in log.keys) key: typed,
    };
    expect(owned[LogicalKeyboardKey.keyN], isTrue);
    expect(owned[LogicalKeyboardKey.slash], isTrue);
    expect(owned[LogicalKeyboardKey.keyJ], isFalse);
    expect(owned[LogicalKeyboardKey.escape], isFalse);
    // 空格不激活外层整块；回车由输入框认领为提交，只开一次浮层（外层整块的
    // 激活不会再叠一次）。
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(spy.prompts, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(spy.prompts, <String?>[null]);
  });

  test('可打印字符判据：控制字符不算', () {
    expect(isPrintableKeyCharacter('a'), isTrue);
    expect(isPrintableKeyCharacter('あ'), isTrue);
    expect(isPrintableKeyCharacter(' '), isTrue);
    expect(isPrintableKeyCharacter(null), isFalse);
    expect(isPrintableKeyCharacter(''), isFalse);
    expect(isPrintableKeyCharacter('\r'), isFalse);
    expect(isPrintableKeyCharacter('\t'), isFalse);
    expect(isPrintableKeyCharacter('\u001b'), isFalse);
    expect(isPrintableKeyCharacter('\u007f'), isFalse);
  });

  test('AiAgentInitialPrompt：去空白、空串为 null、只取一次', () {
    expect(AiAgentInitialPrompt.of(null), isNull);
    expect(AiAgentInitialPrompt.of('   '), isNull);
    final AiAgentInitialPrompt prompt = AiAgentInitialPrompt.of('  hi  ')!;
    expect(prompt.take(), 'hi');
    expect(prompt.take(), isNull);
  });

  testWidgets('浮层对话区挂上树后把 initialPrompt 发出，重建不重发', (WidgetTester tester) async {
    final _RecordingController controller = _RecordingController();
    final AiAgentInitialPrompt prompt = AiAgentInitialPrompt.of('打开设置')!;
    Widget app(Key key) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme().copyWith(platform: TargetPlatform.android),
      home: Scaffold(
        body: SizedBox(
          height: 900,
          child: AiAgentConversation(
            key: key,
            controller: controller,
            initialPrompt: prompt,
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(const ValueKey<int>(1)));
    await tester.pump();
    await tester.pump();
    expect(controller.sent, <String>['打开设置']);

    // 换执行端时对话区以新的 key 重建：同一个 initialPrompt 不会再发。
    await tester.pumpWidget(app(const ValueKey<int>(2)));
    await tester.pump();
    await tester.pump();
    expect(controller.sent, <String>['打开设置']);
  });
}
