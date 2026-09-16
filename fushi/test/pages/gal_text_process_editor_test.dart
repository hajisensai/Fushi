// galgame 文本处理可视化编辑页的行为守卫。
//
// 这页的全部价值在两条纪律上，所以用例也围着它们转：
// ① **草稿态**——改了不保存就一个字节都不落盘（落盘回调零次）；
// ② **活预览**——预览渲染的是 `GalTextProcessPipeline.run` 的逐步留痕，改样例/加步骤
//    立刻跟着变（与 hook 热路径共用同一份实现，预览和真实入库文本不可能分叉）。
// AI 路径只打假 http.Client，不打真网；没配提供商时必须**一个请求都不发**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/mining/galgame_text_process.dart';
import 'package:fushi/src/pages/implementations/gal_text_process_editor_page.dart';
import 'package:fushi/utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/source_guard.dart';

/// 页面在 >=820 宽走左右分栏、控件列固定 340；窄屏降级布局会把用例挤到要滚动才点得到，
/// 所以统一先放大逻辑窗口，再 addTearDown 还原，不泄漏给同进程其它测试。
void _useWideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 落盘回调的记录器：调用次数与最后一次的管线。
class _SaveRecorder {
  final List<GalTextProcessPipeline> saved = <GalTextProcessPipeline>[];

  void call(GalTextProcessPipeline pipeline) => saved.add(pipeline);
}

/// 把页面推进真实 Navigator（生产路径恒是 push 出来的独立路由，`_pop` 依赖这一点）。
Future<void> _pumpEditor(
  WidgetTester tester, {
  required _SaveRecorder recorder,
  GalTextProcessPipeline initialPipeline = const GalTextProcessPipeline(),
  String latestSample = '',
  AiProviderConfig? provider,
  AiChatClient Function()? aiClientFactory,
}) async {
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) {
          hostContext = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );
  unawaitedPush(
    hostContext,
    GalTextProcessEditorPage(
      initialPipeline: initialPipeline,
      onSave: recorder.call,
      latestSample: () => latestSample,
      resolveAiProvider: () => provider,
      aiClientFactory: aiClientFactory,
    ),
  );
  await tester.pumpAndSettle();
}

void unawaitedPush(BuildContext context, Widget page) {
  Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => page));
}

/// 经「添加步骤」对话框加一种处理项（走真实用户路径，不直接改 State）。
Future<void> _addStep(WidgetTester tester, GalTextProcessKind kind) async {
  await tester.tap(find.byKey(const ValueKey<String>('gtp-add-step')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey<String>('gtp-add-${kind.storageKey}')));
  await tester.pumpAndSettle();
}

AiProviderConfig _usableProvider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

/// OpenAI 兼容形状的假回复。
http.Response _openAiReply(String content) => http.Response(
  jsonEncode(<String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{'content': content},
      },
    ],
  }),
  200,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  testWidgets('加一个步骤后，预览逐步卡片里出现这一步', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(tester, recorder: recorder);

    expect(find.byKey(const ValueKey<String>('gtp-empty')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('gtp-trace-filterDigits')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-sample-field')),
      'あ123い',
    );
    await tester.pump();
    await _addStep(tester, GalTextProcessKind.filterDigits);

    // 逐步留痕卡按 step.id 建 key，加了哪一步预览就多哪一张。
    expect(
      find.byKey(const ValueKey<String>('gtp-trace-filterDigits')),
      findsOneWidget,
    );
    // 结果是真跑了管线的输出，不是把样例原样贴回来。
    final Text result = tester.widget<Text>(
      find.byKey(const ValueKey<String>('gtp-result-text')),
    );
    expect(result.data, 'あい');
  });

  testWidgets('改样例文本，预览结果跟着变', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(
      tester,
      recorder: recorder,
      initialPipeline: const GalTextProcessPipeline(
        steps: <GalTextProcessStep>[
          GalTextProcessStep(
            id: 'filterDigits',
            kind: GalTextProcessKind.filterDigits,
          ),
        ],
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-sample-field')),
      '9あ9',
    );
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('gtp-result-text')))
          .data,
      'あ',
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-sample-field')),
      'テスト42',
    );
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('gtp-result-text')))
          .data,
      'テスト',
    );
  });

  testWidgets('点保存才落盘，落下去的是草稿里的那条管线', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(tester, recorder: recorder);

    await _addStep(tester, GalTextProcessKind.stripCurlyBraces);
    expect(recorder.saved, isEmpty, reason: '加步骤本身不落盘');

    await tester.tap(find.byKey(const ValueKey<String>('gtp-save')));
    await tester.pumpAndSettle();

    expect(recorder.saved, hasLength(1));
    expect(
      recorder.saved.single.steps.single.kind,
      GalTextProcessKind.stripCurlyBraces,
    );
  });

  testWidgets('改了草稿但不点保存 → 落盘回调零次', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(tester, recorder: recorder);

    await _addStep(tester, GalTextProcessKind.filterDigits);
    await _addStep(tester, GalTextProcessKind.normalizeWidth);
    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-sample-field')),
      'ＡＢ12',
    );
    await tester.pump();

    expect(recorder.saved, isEmpty);
  });

  testWidgets('没配 AI 提供商时提示去设置，且一个请求都不发', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    int requests = 0;
    await _pumpEditor(
      tester,
      recorder: recorder,
      aiClientFactory: () => AiChatClient(
        client: MockClient((http.Request request) async {
          requests += 1;
          return _openAiReply('{}');
        }),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-ai-request')),
      '把数字去掉',
    );
    await tester.tap(find.byKey(const ValueKey<String>('gtp-ai-generate')));
    await tester.pumpAndSettle();

    expect(requests, 0);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('gtp-ai-message')))
          .data,
      t.game_text_process_ai_no_provider,
    );
  });

  testWidgets('AI 返回的步骤只追加进草稿，不直接落盘', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(
      tester,
      recorder: recorder,
      provider: _usableProvider(),
      aiClientFactory: () => AiChatClient(
        client: MockClient(
          (http.Request request) async => _openAiReply(
            '{"explanation":"去掉半角数字",'
            '"steps":[{"kind":"filterDigits"}]}',
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-sample-field')),
      'あ7',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-ai-request')),
      '把数字去掉',
    );
    await tester.tap(find.byKey(const ValueKey<String>('gtp-ai-generate')));
    await tester.pumpAndSettle();

    // 进了草稿：右侧多一条步骤、左侧多一张留痕卡、结果已按新管线重算。
    expect(
      find.byKey(const ValueKey<String>('gtp-step-filterDigits')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('gtp-trace-filterDigits')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('gtp-result-text')))
          .data,
      'あ',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('gtp-ai-explanation')),
          )
          .data,
      '去掉半角数字',
    );
    // 关键纪律：AI 生成不是一条第二落盘路径。
    expect(recorder.saved, isEmpty);
  });

  testWidgets('自动去重与注音风险各自弹出对应提示', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(tester, recorder: recorder);

    expect(
      find.byKey(const ValueKey<String>('gtp-fold-warning')),
      findsNothing,
    );
    await _addStep(tester, GalTextProcessKind.dedupeChars);
    expect(
      find.byKey(const ValueKey<String>('gtp-fold-warning')),
      findsOneWidget,
    );

    expect(
      find.byKey(const ValueKey<String>('gtp-ruby-warning')),
      findsNothing,
    );
    await _addStep(tester, GalTextProcessKind.stripAngleBrackets);
    expect(
      find.byKey(const ValueKey<String>('gtp-ruby-warning')),
      findsOneWidget,
    );
  });

  testWidgets('正则写坏时就地标红，且不会把这一步塞进热路径的坏状态', (WidgetTester tester) async {
    _useWideWindow(tester);
    final _SaveRecorder recorder = _SaveRecorder();
    await _pumpEditor(tester, recorder: recorder);

    await _addStep(tester, GalTextProcessKind.replace);
    expect(
      find.byKey(const ValueKey<String>('gtp-step-pattern-invalid-replace')),
      findsNothing,
      reason: '刚加的空模式不是「写错了」，是「还没写」',
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('gtp-step-pattern-replace')),
      '[',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('gtp-step-pattern-invalid-replace')),
      findsOneWidget,
    );
  });

  test('本页不得使用 SDK 的 ReorderableListView / ReorderableGridView', () {
    // BUG-778：SDK 的重排拖拽代理不认祖先 `Transform.scale`（FushiAppUiScale 的整体
    // 缩放），「界面大小」非 100% 时浮层漂移。全仓守卫在
    // test/widgets/reorderable_scale_safety_guard_test.dart，这里只钉本页——新页最容易
    // 顺手写成 SDK 组件，而那条全仓守卫按目录枚举跑，定向测试挑不到它。
    final File page = File(
      'lib/src/pages/implementations/gal_text_process_editor_page.dart',
    );
    expect(page.existsSync(), isTrue, reason: '测试须从 fushi/ 下运行');
    final String source = maskComments(page.readAsStringSync());
    expect(
      RegExp(
        r'(?<![\w.])Reorderable(ListView|GridView)\s*(\.\s*\w+\s*)?\(',
      ).hasMatch(source),
      isFalse,
    );
    // 正向：确实用了消缩放的自实现件。
    expect(source, contains('FushiReorderableColumn('));
  });
}
