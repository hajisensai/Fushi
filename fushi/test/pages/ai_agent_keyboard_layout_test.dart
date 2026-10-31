// 横屏手机 + 软键盘：浮层里的 AI 助手必须还看得见输入框和对话列表。
//
// 现象（用户截图）：横屏播视频时点「问 AI」，输入框自动聚焦弹出键盘，浮动面板被
// 压成 ~130dp 的一条，标题栏 + 上下文 chip 把高度吃光，对话列表高度为 0、输入框被
// 裁掉，既不能输入也不能滚动。
//
// 断言：键盘上方的浮层里，输入框完整可见、对话列表仍有可读高度。
// 设了 `FUSHI_PREVIEW_OUT=<目录>` 还会写 PNG（`FUSHI_PREVIEW_SUFFIX` 给 before / after）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;

import 'package:flutter/rendering.dart';
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

final String? _outDir = Platform.environment['FUSHI_PREVIEW_OUT'];
String get _suffix => Platform.environment['FUSHI_PREVIEW_SUFFIX'] ?? 'shot';

const String _latinFamily = 'FushiPreview';

class _FakeController extends ChangeNotifier
    implements AiAgentConversationController {
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
}

void main() {
  setUpAll(() async {
    if (_outDir == null || _outDir!.isEmpty) return;
    final FontLoader latin = FontLoader(_latinFamily);
    final String root =
        Platform.environment['FLUTTER_ROOT'] ?? 'D:/flutter_sdk/flutter_3.47.6';
    for (final String w in <String>['Regular', 'Medium', 'Bold']) {
      final File f = File(
        '$root/bin/cache/artifacts/material_fonts/Roboto-$w.ttf',
      );
      if (f.existsSync()) {
        latin.addFont(
          Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())),
        );
      }
    }
    await latin.load();
    for (final (String family, String path) in <(String, String)>[
      ('FushiSymbols', 'assets/icon_fonts/FushiSymbolsRounded.ttf'),
      ('FushiSymbolsFilled', 'assets/icon_fonts/FushiSymbolsRoundedFilled.ttf'),
    ]) {
      if (File(path).existsSync()) {
        await (FontLoader(family)..addFont(
              Future<ByteData>.value(
                ByteData.sublistView(File(path).readAsBytesSync()),
              ),
            ))
            .load();
      }
    }
  });

  testWidgets('landscape phone + keyboard: input and transcript stay visible', (
    WidgetTester tester,
  ) async {
    const double dpr = 2.75;
    const Size logical = Size(800, 360);
    const double keyboard = 200;
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = logical * dpr;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboard * dpr);
    addTearDown(tester.view.reset);

    final _FakeController controller = _FakeController();
    const Key boundaryKey = ValueKey<String>('preview-boundary');
    final ThemeData base = buildFushiThemeData(
      scheme: buildFushiColorScheme(
        seedColor: kFushiDefaultSeed,
        brightness: Brightness.light,
      ),
      designSystem: FushiDesignSystem.auto,
      glassDesign: false,
      textTheme: FushiTypeScale.buildTextTheme(
        const TextStyle(fontFamily: _latinFamily),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: base.copyWith(platform: TargetPlatform.android),
        builder: (BuildContext context, Widget? app) => RepaintBoundary(
          key: boundaryKey,
          child: FushiFocusRoot(child: app!),
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            backgroundColor: const Color(0xFF000000),
            body: Center(
              child: TextButton(
                onPressed: () => adaptiveModalSheet<void>(
                  context: context,
                  expandable: true,
                  builder: (BuildContext sheetContext) => SizedBox(
                    // 与 openAiAgent 里一致：按整窗高度的 55%。
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

    if (_outDir != null && _outDir!.isNotEmpty) {
      final RenderRepaintBoundary boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final ui.Image image = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: dpr),
      ))!;
      final ByteData? data = await tester.runAsync<ByteData?>(
        () => image.toByteData(format: ui.ImageByteFormat.png),
      );
      image.dispose();
      final Directory out = Directory(_outDir!)..createSync(recursive: true);
      File(
        '${out.path}/ai_panel_landscape_keyboard_$_suffix.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
    }

    final Finder input = find.byKey(const ValueKey<String>('ai-agent-input'));
    expect(input, findsOneWidget);
    final Rect inputRect = tester.getRect(input);
    expect(
      inputRect.bottom,
      lessThanOrEqualTo(logical.height - keyboard + 0.5),
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
}
