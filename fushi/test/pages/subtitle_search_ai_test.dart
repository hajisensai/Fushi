// 字幕搜索面板的 AI 辅助：未指派提供商时一个 AI 按钮都不出现；假 client 回一份排列后
// 列表按它重排、推荐条目带「AI 推荐」徽章、备注进副标题。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_chat_client.dart';
import 'package:fushi/src/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/jimaku_subtitle_dialog.dart';

class _Source extends VideoSubtitleCandidate {
  _Source(String name)
    : super(
        providerId: 'jimaku',
        remoteId: name,
        fileName: name,
        language: 'ja',
        providerPriority: 10,
        releaseName: 'Show (Jimaku)',
        collectionId: '9',
        collectionLabel: 'Show (Jimaku)',
      );
}

const List<String> _names = <String>[
  '[A] Show - 01.ass',
  '[B] Show - 01.ass',
  '[C] Show - 01.ass',
];

List<JimakuCandidate> _candidates() => <JimakuCandidate>[
  for (final String name in _names)
    JimakuCandidate(
      entryName: 'Show (Jimaku)',
      name: name,
      source: _Source(name),
    ),
];

AiProviderConfig _provider() => AiProviderConfig(
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

Widget _host({
  required String saveDirectory,
  AiProviderConfig? provider,
  AiChatClient Function()? clientFactory,
}) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: JimakuSubtitleDialog(
        initialQuery: 'Show',
        initialApiKey: 'key',
        onApiKeyChanged: (String _) async {},
        saveDirectory: saveDirectory,
        resolveAiProvider: provider == null ? null : () => provider,
        aiClientFactory: clientFactory,
        debugInitialCandidates: _candidates(),
      ),
    ),
  ),
);

Future<void> _pump(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('fushi_sub_ai'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  testWidgets('未指派提供商时不显示任何 AI 按钮', (WidgetTester tester) async {
    await _pump(tester, _host(saveDirectory: tempDir.path));
    expect(
      find.byKey(const ValueKey<String>('jimaku-ai-expand')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('jimaku-ai-rank')), findsNothing);
    expect(find.text(t.video_search_ai_recommended), findsNothing);
  });

  testWidgets('假 client 回排列 → 列表按 AI 顺序重排、推荐徽章与备注出现', (
    WidgetTester tester,
  ) async {
    int requests = 0;
    await _pump(
      tester,
      _host(
        saveDirectory: tempDir.path,
        provider: _provider(),
        clientFactory: () => AiChatClient(
          client: MockClient((http.Request request) async {
            requests++;
            return _openAiReply(
              '{"order":[2,0,1],"recommended":2,"notes":{"2":"同发布组时轴"}}',
            );
          }),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey<String>('jimaku-ai-expand')),
      findsOneWidget,
    );
    final Finder rank = find.byKey(const ValueKey<String>('jimaku-ai-rank'));
    expect(rank, findsOneWidget);

    await tester.tap(rank);
    await tester.pumpAndSettle();

    expect(requests, 1);
    expect(
      find.byKey(const ValueKey<String>('jimaku-ai-ranked')),
      findsOneWidget,
    );
    final List<String> shown = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((ListTile tile) => (tile.title! as Text).data!)
        .toList();
    expect(shown, <String>[_names[2], _names[0], _names[1]]);
    expect(
      find.byKey(ValueKey<String>('jimaku-ai-pick-${_names[2]}')),
      findsOneWidget,
    );
    expect(find.textContaining('同发布组时轴'), findsOneWidget);
  });
}
