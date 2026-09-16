// Lapis 可视化编辑器「让 AI 帮忙」区的行为守卫。
//
// AI 路径只打假 http.Client，不打真网；没配提供商时必须**一个请求都不发**；
// 拿到结果只进编辑器草稿（可视化规则 + 自由 CSS），保存按钮亮起但不自动保存，
// 更不会推到 Anki。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi/src/anki/lapis_style_editor_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'lapis_style_editor_harness.dart';

AiProviderConfig _usableProvider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

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

Future<LapisVisualEditorResult?> _pumpAndRunAi(
  WidgetTester tester, {
  required AiProviderConfig? provider,
  required AiChatClient Function() aiClientFactory,
  String initialCustomCss = '',
  bool save = false,
}) async {
  useWideWindow(tester);
  late BuildContext hostContext;
  LapisVisualEditorResult? result;
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
  final Future<void> popped = Navigator.of(hostContext)
      .push<LapisVisualEditorResult>(
        MaterialPageRoute<LapisVisualEditorResult>(
          builder: (_) => LapisStyleEditorPage(
            initialCustomCss: initialCustomCss,
            fontScalePercent: 100,
            previewBuilder: (_, __, ___) => const SizedBox.expand(),
            resolveAiProvider: () => provider,
            aiClientFactory: aiClientFactory,
          ),
        ),
      )
      .then((LapisVisualEditorResult? value) => result = value);
  await tester.pumpAndSettle();

  final Finder request = find.byKey(const ValueKey<String>('lapis-ai-request'));
  await tester.ensureVisible(request);
  await tester.pumpAndSettle();
  await tester.enterText(request, '例句放大');
  await tester.tap(find.byKey(const ValueKey<String>('lapis-ai-generate')));
  await tester.pumpAndSettle();

  if (!save) {
    return null;
  }
  await tester.tap(find.byIcon(Icons.save_outlined));
  await tester.pumpAndSettle();
  await popped;
  return result;
}

void main() {
  testWidgets('没配 AI 提供商时提示去设置，且一个请求都不发', (WidgetTester tester) async {
    int requests = 0;
    await _pumpAndRunAi(
      tester,
      provider: null,
      aiClientFactory: () => AiChatClient(
        client: MockClient((http.Request request) async {
          requests += 1;
          return _openAiReply('{}');
        }),
      ),
    );

    expect(requests, 0);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey<String>('lapis-ai-message')))
          .data,
      t.ai_assist_no_provider,
    );
    // 什么都没改，保存按钮保持灰。
    final FilledButton saveButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.byIcon(Icons.save_outlined),
        matching: find.byType(FilledButton),
      ),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('假 client 返回 JSON → 规则与 CSS 进草稿，保存后回传', (
    WidgetTester tester,
  ) async {
    final LapisVisualEditorResult? result = await _pumpAndRunAi(
      tester,
      provider: _usableProvider(),
      initialCustomCss: '.card { color: teal; }',
      aiClientFactory: () => AiChatClient(
        client: MockClient(
          (http.Request request) async => _openAiReply(
            '{"explanation":"例句放大加粗",'
            '"rules":[{"field":"sentence","fontScalePercent":130,"bold":true}],'
            '"css":".def-info { display: none !important; }\\n'
            'body { background: black; }"}',
          ),
        ),
      ),
      save: true,
    );

    expect(result, isNotNull);
    final LapisVisualStyleSheet sheet = splitLapisVisualStyleSheet(
      result!.customCss,
    );
    final LapisVisualRule sentence = sheet.rules[LapisVisualField.sentence]!;
    expect(sentence.fontScalePercent, 130);
    expect(sentence.bold, isTrue);
    expect(sheet.freeformCss, startsWith('.card { color: teal; }'));
    expect(sheet.freeformCss, contains('\n\n.def-info {'));
    expect(sheet.freeformCss, isNot(contains('body')));
  });
}
